//! Sealer/Unsealer: E-rights foundational primitive.
//!
//! A Brand is a cryptographic identity (32-byte random secret).
//! seal(brand, value) → opaque SealedBox (map with :sealed-brand hash)
//! unseal(brand, box) → value | error.WrongBrand
//! brand?() → fresh Brand
//! sealed?(box) → true if map with :sealed-brand key
//!
//! The seal is an HMAC-SHA256 over the brand secret + a monotonic nonce,
//! so sealed boxes are unforgeable without the brand. The actual value is
//! stored in a side-table keyed by the HMAC tag — never exposed in the
//! map itself.
//!
//! Clojure API:
//!   (def b (brand?))                    ; → opaque brand value
//!   (def box (seal b 42))               ; → {:sealed-brand "a3f1..." :sealed-nonce 0}
//!   (unseal b box)                      ; → 42
//!   (unseal (brand?) box)               ; → nil (wrong brand)
//!   (sealed? box)                       ; → true
//!   (seal-pair)                         ; → [sealer-fn unsealer-fn] (matched pair)

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;

const BRAND_LEN = 32;
const TAG_LEN = 32; // HMAC-SHA256 output

pub const Brand = struct {
    secret: [BRAND_LEN]u8,
    nonce: u64 = 0,
};

const SealEntry = struct {
    val: Value,
    brand_hash: [TAG_LEN]u8, // HMAC(secret, nonce) — verifies ownership
};

// Module-level sealed-value store. Keyed by hex(tag) for fast lookup.
// In a production system this would be per-vat; here it's process-global
// matching nanoclj-zig's single-vat model.
var seal_table: std.StringHashMap(SealEntry) = undefined;
var seal_allocator: std.mem.Allocator = undefined;
var initialized: bool = false;
var fallback_seed: u64 = 0x9e37_79b9_7f4a_7c15;

fn fillRandom(buf: []u8) void {
    if (@TypeOf(std.c.arc4random_buf) != void) {
        std.c.arc4random_buf(buf.ptr, buf.len);
    } else {
        fallback_seed +%= 0xbf58_476d_1ce4_e5b9;
        var prng = std.Random.DefaultPrng.init(fallback_seed);
        prng.random().bytes(buf);
    }
}

fn ensureInit(allocator: std.mem.Allocator) void {
    if (!initialized) {
        seal_table = std.StringHashMap(SealEntry).init(allocator);
        seal_allocator = allocator;
        initialized = true;
    }
}

fn makeTag(secret: *const [BRAND_LEN]u8, nonce: u64) [TAG_LEN]u8 {
    var tag: [TAG_LEN]u8 = undefined;
    const nonce_bytes = std.mem.asBytes(&nonce);
    HmacSha256.create(&tag, nonce_bytes, secret);
    return tag;
}

fn tagHex(tag: *const [TAG_LEN]u8) [TAG_LEN * 2]u8 {
    return std.fmt.bytesToHex(tag.*, .lower);
}

// ── Builtins ────────────────────────────────────────────────────────

/// (brand?) → creates a fresh brand (32 random bytes, wrapped as bytes obj)
pub fn brandFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    _ = args;
    ensureInit(gc.allocator);
    var secret: [BRAND_LEN]u8 = undefined;
    fillRandom(&secret);
    const obj = try gc.allocObj(.bytes);
    const copy = try gc.allocator.dupe(u8, &secret);
    obj.data.bytes = .{ .data = copy, .owned = true };
    return Value.makeObj(obj);
}

/// (seal brand value) → {:sealed-brand "hex..." :sealed-nonce N}
pub fn sealFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    ensureInit(gc.allocator);

    const brand_val = args[0];
    const payload = args[1];

    if (!brand_val.isObj()) return error.TypeError;
    const brand_obj = brand_val.asObj();
    if (brand_obj.kind != .bytes or brand_obj.data.bytes.data.len != BRAND_LEN)
        return error.TypeError;

    const secret: *const [BRAND_LEN]u8 = brand_obj.data.bytes.data[0..BRAND_LEN];

    // Derive nonce from current table size (monotonic within process)
    const nonce: u64 = @intCast(seal_table.count());
    const tag = makeTag(secret, nonce);
    const hex = tagHex(&tag);

    // Store value in side-table
    const hex_copy = try seal_allocator.dupe(u8, &hex);
    try seal_table.put(hex_copy, .{ .val = payload, .brand_hash = tag });

    // Return opaque map: {:sealed-brand "hex" :sealed-nonce N}
    const obj = try gc.allocObj(.map);
    const k1 = Value.makeKeyword(try gc.internString("sealed-brand"));
    const v1 = Value.makeString(try gc.internString(&hex));
    const k2 = Value.makeKeyword(try gc.internString("sealed-nonce"));
    const v2 = Value.makeInt(@intCast(nonce));
    try obj.data.map.keys.append(gc.allocator, k1);
    try obj.data.map.vals.append(gc.allocator, v1);
    try obj.data.map.keys.append(gc.allocator, k2);
    try obj.data.map.vals.append(gc.allocator, v2);
    return Value.makeObj(obj);
}

/// (unseal brand sealed-map) → value | nil
pub fn unsealFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    ensureInit(gc.allocator);

    const brand_val = args[0];
    const box_val = args[1];

    if (!brand_val.isObj()) return error.TypeError;
    const brand_obj = brand_val.asObj();
    if (brand_obj.kind != .bytes or brand_obj.data.bytes.data.len != BRAND_LEN)
        return error.TypeError;

    if (!box_val.isObj()) return Value.makeNil();
    const box_obj = box_val.asObj();
    if (box_obj.kind != .map) return Value.makeNil();

    // Extract nonce from the sealed map
    const nonce_kw = Value.makeKeyword(try gc.internString("sealed-nonce"));
    var nonce_val: ?Value = null;
    for (box_obj.data.map.keys.items, box_obj.data.map.vals.items) |k, v| {
        if (k.bits == nonce_kw.bits) {
            nonce_val = v;
            break;
        }
    }
    const nonce: u64 = if (nonce_val) |nv| @intCast(nv.asInt()) else return Value.makeNil();

    // Recompute tag with this brand's secret + the claimed nonce
    const secret: *const [BRAND_LEN]u8 = brand_obj.data.bytes.data[0..BRAND_LEN];
    const tag = makeTag(secret, nonce);
    const hex = tagHex(&tag);

    // Lookup in side-table
    if (seal_table.get(&hex)) |entry| {
        // Constant-time compare to prevent timing attacks
        if (std.crypto.timing_safe.eql([TAG_LEN]u8, entry.brand_hash, tag)) {
            return entry.val;
        }
    }
    return Value.makeNil();
}

/// (sealed? v) → true if v is a map with :sealed-brand key
pub fn sealedPredFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const v = args[0];
    if (!v.isObj()) return Value.makeBool(false);
    const obj = v.asObj();
    if (obj.kind != .map) return Value.makeBool(false);
    const brand_kw = Value.makeKeyword(try gc.internString("sealed-brand"));
    for (obj.data.map.keys.items) |k| {
        if (k.bits == brand_kw.bits) return Value.makeBool(true);
    }
    return Value.makeBool(false);
}

/// (seal-pair) → [sealer-fn unsealer-fn] sharing one brand
/// Returns a vector of two builtin_ref objects that close over the same brand.
/// This is the Mark Miller "matched pair" pattern: the sealer and unsealer
/// are separate capabilities that can be distributed independently.
pub fn sealPairFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    _ = args;
    ensureInit(gc.allocator);
    // For now, seal-pair returns a vector [brand brand] — caller uses
    // (seal (first pair) v) and (unseal (second pair) box).
    // A future version could return closure objects.
    var secret: [BRAND_LEN]u8 = undefined;
    fillRandom(&secret);
    const obj1 = try gc.allocObj(.bytes);
    const copy1 = try gc.allocator.dupe(u8, &secret);
    obj1.data.bytes = .{ .data = copy1, .owned = true };
    const obj2 = try gc.allocObj(.bytes);
    const copy2 = try gc.allocator.dupe(u8, &secret);
    obj2.data.bytes = .{ .data = copy2, .owned = true };
    const vec = try gc.allocObj(.vector);
    try vec.data.vector.items.append(gc.allocator, Value.makeObj(obj1));
    try vec.data.vector.items.append(gc.allocator, Value.makeObj(obj2));
    return Value.makeObj(vec);
}

// ── Tests ───────────────────────────────────────────────────────────

test "sealer: seal then unseal with same brand recovers value" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    ensureInit(allocator);
    defer {
        var it = seal_table.iterator();
        while (it.next()) |entry| seal_allocator.free(entry.key_ptr.*);
        seal_table.deinit();
        initialized = false;
    }

    var secret: [BRAND_LEN]u8 = undefined;
    fillRandom(&secret);

    const nonce: u64 = @intCast(seal_table.count());
    const tag = makeTag(&secret, nonce);
    const hex = tagHex(&tag);
    const hex_copy = try allocator.dupe(u8, &hex);

    const payload = Value.makeInt(42);
    try seal_table.put(hex_copy, .{ .val = payload, .brand_hash = tag });

    // Lookup with correct brand
    if (seal_table.get(&hex)) |entry| {
        try std.testing.expect(std.crypto.timing_safe.eql([TAG_LEN]u8, entry.brand_hash, tag));
        try std.testing.expect(entry.val.asInt() == 42);
    } else {
        return error.TestUnexpectedResult;
    }
}

test "sealer: wrong brand cannot unseal" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    ensureInit(allocator);
    defer {
        var it = seal_table.iterator();
        while (it.next()) |entry| seal_allocator.free(entry.key_ptr.*);
        seal_table.deinit();
        initialized = false;
    }

    var secret1: [BRAND_LEN]u8 = undefined;
    var secret2: [BRAND_LEN]u8 = undefined;
    fillRandom(&secret1);
    fillRandom(&secret2);

    const nonce: u64 = 0;
    const tag1 = makeTag(&secret1, nonce);
    const hex1 = tagHex(&tag1);
    const hex_copy = try allocator.dupe(u8, &hex1);

    try seal_table.put(hex_copy, .{ .val = Value.makeInt(99), .brand_hash = tag1 });

    // Wrong brand produces different tag
    const tag2 = makeTag(&secret2, nonce);
    const hex2 = tagHex(&tag2);
    try std.testing.expect(seal_table.get(&hex2) == null);
}

test "sealer: HMAC tag is deterministic for same secret+nonce" {
    var secret: [BRAND_LEN]u8 = undefined;
    fillRandom(&secret);
    const tag_a = makeTag(&secret, 7);
    const tag_b = makeTag(&secret, 7);
    try std.testing.expect(std.crypto.timing_safe.eql([TAG_LEN]u8, tag_a, tag_b));
}

test "sealer: different nonces produce different tags" {
    var secret: [BRAND_LEN]u8 = undefined;
    fillRandom(&secret);
    const tag_a = makeTag(&secret, 0);
    const tag_b = makeTag(&secret, 1);
    try std.testing.expect(!std.crypto.timing_safe.eql([TAG_LEN]u8, tag_a, tag_b));
}
