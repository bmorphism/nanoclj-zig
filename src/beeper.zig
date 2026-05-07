//! beeper.zig — nanoclj-zig native Beeper Desktop API client
//!
//! Self-hosted via gorj pattern: each API endpoint is a nanoclj builtin
//! that composes zero-copy Syrup serialization, OKLAB color identity,
//! and Bumpus time-travel sheaves over message history.
//!
//! Design:
//!   - Every API call gets an index-addressed version ID (SplitMix64)
//!   - Every chat/contact gets a deterministic OKLAB color from ID hash
//!   - Message history forms a presheaf on time categories (SplitTree)
//!   - Serialization: Syrup (zero-copy via syrup_bridge), not JSON
//!   - HTTP: localhost:23373 (Beeper Desktop local API)
//!   - Builtins follow (args, gc, env, resources) → Value signature
//!
//! API surface (from beeper-cli Go reference):
//!   Messages: send, edit, list, search, delete, react
//!   Chats:    create, get, list, search, archive, reminder
//!   Accounts: list, contacts/search
//!   Assets:   upload, upload-base64, download
//!   Search:   global
//!   Focus:    bring app to front

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const substrate = @import("substrate.zig");
const syrup_bridge = @import("syrup_bridge.zig");
const colorspace = @import("colorspace.zig");
const bumpus = @import("marsaglia_bumpus.zig");
const compat = @import("compat.zig");

// ============================================================================
// CONFIGURATION
// ============================================================================

const BEEPER_HOST = "localhost";
const BEEPER_PORT: u16 = 23373;
const MAX_RESPONSE: usize = 1024 * 1024; // 1 MiB

// ============================================================================
// TIME-TRAVEL: Presheaf on Time Categories via SplitTree
// ============================================================================

// A MessageNode in the time-travel sheaf. Each message gets a SplitTree node
// so we can:
//   1. Fork history at any point (left/right children)
//   2. Glue local sections back via sheaf consistency (XOR fingerprints)
//   3. Query FPT-bounded subhistories via adhesion width
pub const TimeNode = struct {
    tree: bumpus.SplitTree,
    timestamp_ms: i64,
    chat_id_hash: u64,
    message_version: u64,

    pub fn init(seed: u64, depth: u8, timestamp_ms: i64, chat_id: []const u8) TimeNode {
        var id_hash: u64 = substrate.GOLDEN;
        for (chat_id) |byte| {
            id_hash = substrate.mix64(id_hash ^ @as(u64, byte));
        }
        const tree = bumpus.SplitTree.init(seed ^ id_hash, depth);
        return .{
            .tree = tree,
            .timestamp_ms = timestamp_ms,
            .chat_id_hash = id_hash,
            .message_version = tree.fingerprint,
        };
    }

    pub fn fork(self: TimeNode) struct { past: TimeNode, future: TimeNode } {
        const children = self.tree.split();
        return .{
            .past = .{
                .tree = children.left,
                .timestamp_ms = self.timestamp_ms,
                .chat_id_hash = self.chat_id_hash,
                .message_version = children.left.fingerprint,
            },
            .future = .{
                .tree = children.right,
                .timestamp_ms = self.timestamp_ms,
                .chat_id_hash = self.chat_id_hash,
                .message_version = children.right.fingerprint,
            },
        };
    }
};

// Timeline: a sequence of TimeNodes forming a presheaf section.
// Restriction maps are SplitTree.split — going from coarser to finer time.
// Gluing condition: leaf XOR is deterministic (Bumpus sheaf gluing test).
pub const Timeline = struct {
    root_seed: u64,
    nodes: [256]TimeNode,
    len: usize,

    pub fn init(seed: u64) Timeline {
        return .{
            .root_seed = seed,
            .nodes = undefined,
            .len = 0,
        };
    }

    pub fn append(self: *Timeline, timestamp_ms: i64, chat_id: []const u8) ?*TimeNode {
        if (self.len >= 256) return null;
        const depth: u8 = @intCast(@min(self.len, 255));
        self.nodes[self.len] = TimeNode.init(
            self.root_seed +% @as(u64, self.len) *% substrate.GOLDEN,
            depth,
            timestamp_ms,
            chat_id,
        );
        const node = &self.nodes[self.len];
        self.len += 1;
        return node;
    }

    pub fn gluingFingerprint(self: *const Timeline) u64 {
        if (self.len == 0) return 0;
        var fp: u64 = 0;
        for (0..self.len) |i| {
            fp ^= self.nodes[i].message_version;
        }
        return fp;
    }
};

// ============================================================================
// CONTACT COLOR: Deterministic OKLAB from ID via SplitMix64
// ============================================================================

pub fn contactColor(id: []const u8) colorspace.Color {
    var seed: u64 = substrate.GOLDEN;
    for (id) |byte| {
        seed = substrate.mix64(seed ^ @as(u64, byte));
    }
    // Map seed to OKLAB via golden angle in a-b chroma plane
    const hue_raw: f32 = @floatFromInt(seed & 0xFFFF);
    const hue = hue_raw / 65536.0 * 360.0;
    const rad = hue * std.math.pi / 180.0;
    const chroma: f32 = 0.12;
    return .{
        .L = 0.65,
        .a = chroma * @cos(rad),
        .b = chroma * @sin(rad),
        .alpha = 1.0,
    };
}

pub fn colorToHex(c: colorspace.Color) [7]u8 {
    // OKLAB → sRGB approximation (simplified for hex output)
    const r_lin = c.L + 0.3963377774 * c.a + 0.2158037573 * c.b;
    const g_lin = c.L - 0.1055613458 * c.a - 0.0638541728 * c.b;
    const b_lin = c.L - 0.0894841775 * c.a - 1.2914855480 * c.b;

    const r: u8 = @intFromFloat(std.math.clamp(r_lin * 255.0, 0.0, 255.0));
    const g: u8 = @intFromFloat(std.math.clamp(g_lin * 255.0, 0.0, 255.0));
    const b: u8 = @intFromFloat(std.math.clamp(b_lin * 255.0, 0.0, 255.0));

    var buf: [7]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch {};
    return buf;
}

// ============================================================================
// VERSION TRACKING: Index-addressed via gorj_bridge pattern
// ============================================================================

var beeper_root_seed: u64 = substrate.CANONICAL_SEED;
var beeper_invocation: u64 = 0;
var beeper_trit_acc: i32 = 0;

pub fn initBeeperSession(seed: u64) void {
    beeper_root_seed = seed;
    beeper_invocation = 0;
    beeper_trit_acc = 0;
}

inline fn nextVersionId(endpoint: []const u8) u64 {
    var h = substrate.mix64(beeper_root_seed +% beeper_invocation *% substrate.GOLDEN);
    for (endpoint) |byte| {
        h = substrate.mix64(h ^ @as(u64, byte));
    }
    beeper_invocation += 1;
    // Trit: -1, 0, +1 cycling by position
    const trit: i32 = @as(i32, @intCast(beeper_invocation % 3)) - 1;
    beeper_trit_acc += trit;
    return h;
}

// ============================================================================
// HTTP TRANSPORT (localhost exception for Beeper Desktop)
// ============================================================================

const HttpMethod = enum { GET, POST, PUT, DELETE };

fn methodStr(m: HttpMethod) []const u8 {
    return switch (m) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
    };
}

fn httpRequest(
    alloc: std.mem.Allocator,
    method: HttpMethod,
    path: []const u8,
    token: []const u8,
    body: ?[]const u8,
) ![]const u8 {
    // Zig 0.16.0 removed std.net at the top level (moved to std.Io.net with a
    // different surface) and removed several free fns.  Stub out for now;
    // beeper functionality isn't on the embed-min path.  TODO: port to
    // std.Io.net when its API stabilizes.
    _ = alloc;
    _ = method;
    _ = path;
    _ = token;
    _ = body;
    return error.NetworkUnavailable;
}

// Original httpRequest body removed (Zig 0.16.0 std.net API drift).
// Reference path: getAddressList → tcpConnectToAddress → bufPrint headers
// → write → read → split on \r\n\r\n → return body slice.
// Restore once std.Io.net stabilizes.

// ============================================================================
// SYRUP SERIALIZATION LAYER (zero-copy message encoding)
// ============================================================================

fn encodeMessageSyrup(gc: *GC, alloc: std.mem.Allocator, chat_id: []const u8, text: []const u8, version_id: u64) ![]const u8 {
    const chat_val = Value.makeString(try gc.internString(chat_id));
    const text_val = Value.makeString(try gc.internString(text));
    const ver_val = Value.makeInt(@bitCast(@as(u48, @truncate(version_id))));

    const obj = try gc.allocObj(.map);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("chat-id")));
    try obj.data.map.vals.append(gc.allocator, chat_val);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("text")));
    try obj.data.map.vals.append(gc.allocator, text_val);
    try obj.data.map.keys.append(gc.allocator, Value.makeKeyword(try gc.internString("version")));
    try obj.data.map.vals.append(gc.allocator, ver_val);

    return syrup_bridge.encode_to_bytes(Value.makeObj(obj), gc, alloc);
}

// ============================================================================
// NANOCLJ BUILTIN FUNCTIONS
// ============================================================================

fn kw(gc: *GC, s: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(s));
}

fn addKV(obj: *value.Obj, gc: *GC, key: []const u8, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try kw(gc, key));
    try obj.data.map.vals.append(gc.allocator, val);
}

fn getToken(gc: *GC) ?[]const u8 {
    // Try env var first
    // Zig 0.16.0: std.process.getEnvVarOwned removed; use libc getenv.
    // Gated on non-WASM since WASM-freestanding doesn't link libc.
    if (@import("builtin").target.cpu.arch == .wasm32) return null;
    const raw = std.c.getenv("BEEPER_ACCESS_TOKEN") orelse return null;
    const len = std.mem.len(raw);
    return gc.allocator.dupe(u8, raw[0..len]) catch null;
}

// (beeper-init seed) → {:status :ok, :seed <seed>}
pub fn beeperInitFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    const seed: u64 = if (args.len >= 1 and args[0].isInt())
        @bitCast(@as(i64, args[0].asInt()))
    else
        substrate.CANONICAL_SEED;
    initBeeperSession(seed);
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "status", Value.makeKeyword(try gc.internString("ok")));
    try addKV(obj, gc, "seed", Value.makeInt(@bitCast(@as(u48, @truncate(seed)))));
    return Value.makeObj(obj);
}

// (beeper-send chat-id text) → {:version <id>, :trit <t>, :syrup <bytes>, :color <hex>}
pub fn beeperSendFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isString() or !args[1].isString()) return error.TypeError;

    const chat_id = gc.getString(args[0].asStringId());
    const text = gc.getString(args[1].asStringId());
    const token = getToken(gc) orelse return error.MissingToken;

    const version_id = nextVersionId("send");
    const trit: i32 = @as(i32, @intCast(beeper_invocation % 3)) - 1;

    // Syrup-encode the message (zero-copy)
    const syrup_bytes = encodeMessageSyrup(gc, gc.allocator, chat_id, text, version_id) catch
        return error.EncodingError;

    // Build JSON body for HTTP (Beeper API expects JSON)
    var json_buf: [4096]u8 = undefined;
    const json_body = std.fmt.bufPrint(&json_buf, "{{\"text\":\"{s}\"}}", .{text}) catch
        return error.Overflow;

    const path = std.fmt.allocPrint(gc.allocator, "/api/chats/{s}/messages", .{chat_id}) catch
        return error.OutOfMemory;

    // HTTP request to Beeper Desktop
    const resp = httpRequest(gc.allocator, .POST, path, token, json_body) catch |err| {
        const obj = try gc.allocObj(.map);
        try addKV(obj, gc, "error", Value.makeString(try gc.internString(@errorName(err))));
        try addKV(obj, gc, "version", Value.makeInt(@bitCast(@as(u48, @truncate(version_id)))));
        return Value.makeObj(obj);
    };

    // Contact color
    const color = contactColor(chat_id);
    const hex = colorToHex(color);

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "version", Value.makeInt(@bitCast(@as(u48, @truncate(version_id)))));
    try addKV(obj, gc, "trit", Value.makeInt(trit));
    try addKV(obj, gc, "syrup-len", Value.makeInt(@intCast(syrup_bytes.len)));
    try addKV(obj, gc, "color", Value.makeString(try gc.internString(&hex)));
    try addKV(obj, gc, "response", Value.makeString(try gc.internString(resp)));
    return Value.makeObj(obj);
}

// (beeper-messages chat-id) → {:messages [...], :version <id>, :timeline-fp <u64>}
pub fn beeperMessagesFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1 or !args[0].isString()) return error.ArityError;
    const chat_id = gc.getString(args[0].asStringId());
    const token = getToken(gc) orelse return error.MissingToken;

    const version_id = nextVersionId("messages");
    const path = std.fmt.allocPrint(gc.allocator, "/api/chats/{s}/messages", .{chat_id}) catch
        return error.OutOfMemory;

    const resp = httpRequest(gc.allocator, .GET, path, token, null) catch |err| {
        const obj = try gc.allocObj(.map);
        try addKV(obj, gc, "error", Value.makeString(try gc.internString(@errorName(err))));
        return Value.makeObj(obj);
    };

    // Time-travel: create timeline node for this fetch
    var tl = Timeline.init(beeper_root_seed);
    const ms350: i64 = if (@import("builtin").target.cpu.arch == .wasm32) 0 else blk: {
        var ts350: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts350);
        break :blk @as(i64, ts350.sec) * 1000 + @divTrunc(@as(i64, ts350.nsec), 1_000_000);
    };
    _ = tl.append(ms350, chat_id);
    const gluing_fp = tl.gluingFingerprint();

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "response", Value.makeString(try gc.internString(resp)));
    try addKV(obj, gc, "version", Value.makeInt(@bitCast(@as(u48, @truncate(version_id)))));
    try addKV(obj, gc, "timeline-fp", Value.makeInt(@bitCast(@as(u48, @truncate(gluing_fp)))));
    return Value.makeObj(obj);
}

// (beeper-chats) → {:chats [...], :version <id>}
pub fn beeperChatsFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    _ = args;
    const token = getToken(gc) orelse return error.MissingToken;
    const version_id = nextVersionId("chats");

    const resp = httpRequest(gc.allocator, .GET, "/api/chats", token, null) catch |err| {
        const obj = try gc.allocObj(.map);
        try addKV(obj, gc, "error", Value.makeString(try gc.internString(@errorName(err))));
        return Value.makeObj(obj);
    };

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "response", Value.makeString(try gc.internString(resp)));
    try addKV(obj, gc, "version", Value.makeInt(@bitCast(@as(u48, @truncate(version_id)))));
    return Value.makeObj(obj);
}

// (beeper-chat chat-id) → {:chat {...}, :color <hex>}
pub fn beeperChatFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1 or !args[0].isString()) return error.ArityError;
    const chat_id = gc.getString(args[0].asStringId());
    const token = getToken(gc) orelse return error.MissingToken;

    const version_id = nextVersionId("chat");
    const path = std.fmt.allocPrint(gc.allocator, "/api/chats/{s}", .{chat_id}) catch
        return error.OutOfMemory;

    const resp = httpRequest(gc.allocator, .GET, path, token, null) catch |err| {
        const obj = try gc.allocObj(.map);
        try addKV(obj, gc, "error", Value.makeString(try gc.internString(@errorName(err))));
        return Value.makeObj(obj);
    };

    const color = contactColor(chat_id);
    const hex = colorToHex(color);

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "response", Value.makeString(try gc.internString(resp)));
    try addKV(obj, gc, "version", Value.makeInt(@bitCast(@as(u48, @truncate(version_id)))));
    try addKV(obj, gc, "color", Value.makeString(try gc.internString(&hex)));
    return Value.makeObj(obj);
}

// (beeper-search query) → {:results [...], :version <id>}
pub fn beeperSearchFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1 or !args[0].isString()) return error.ArityError;
    const query = gc.getString(args[0].asStringId());
    const token = getToken(gc) orelse return error.MissingToken;

    const version_id = nextVersionId("search");

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/api/search?q={s}", .{query}) catch
        return error.Overflow;

    const resp = httpRequest(gc.allocator, .GET, path, token, null) catch |err| {
        const obj = try gc.allocObj(.map);
        try addKV(obj, gc, "error", Value.makeString(try gc.internString(@errorName(err))));
        return Value.makeObj(obj);
    };

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "response", Value.makeString(try gc.internString(resp)));
    try addKV(obj, gc, "version", Value.makeInt(@bitCast(@as(u48, @truncate(version_id)))));
    return Value.makeObj(obj);
}

// (beeper-accounts) → {:accounts [...]}
pub fn beeperAccountsFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    _ = args;
    const token = getToken(gc) orelse return error.MissingToken;
    const version_id = nextVersionId("accounts");

    const resp = httpRequest(gc.allocator, .GET, "/api/accounts", token, null) catch |err| {
        const obj = try gc.allocObj(.map);
        try addKV(obj, gc, "error", Value.makeString(try gc.internString(@errorName(err))));
        return Value.makeObj(obj);
    };

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "response", Value.makeString(try gc.internString(resp)));
    try addKV(obj, gc, "version", Value.makeInt(@bitCast(@as(u48, @truncate(version_id)))));
    return Value.makeObj(obj);
}

// (beeper-contacts account-id query) → {:contacts [...]}
pub fn beeperContactsFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 2) return error.ArityError;
    if (!args[0].isString() or !args[1].isString()) return error.TypeError;

    const account_id = gc.getString(args[0].asStringId());
    const query = gc.getString(args[1].asStringId());
    const token = getToken(gc) orelse return error.MissingToken;

    const version_id = nextVersionId("contacts");
    const path = std.fmt.allocPrint(gc.allocator, "/api/accounts/{s}/contacts/search?q={s}", .{ account_id, query }) catch
        return error.OutOfMemory;

    const resp = httpRequest(gc.allocator, .GET, path, token, null) catch |err| {
        const obj = try gc.allocObj(.map);
        try addKV(obj, gc, "error", Value.makeString(try gc.internString(@errorName(err))));
        return Value.makeObj(obj);
    };

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "response", Value.makeString(try gc.internString(resp)));
    try addKV(obj, gc, "version", Value.makeInt(@bitCast(@as(u48, @truncate(version_id)))));
    return Value.makeObj(obj);
}

// (beeper-edit chat-id message-id text) → {:version <id>}
pub fn beeperEditFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 3) return error.ArityError;
    if (!args[0].isString() or !args[1].isString() or !args[2].isString()) return error.TypeError;

    const chat_id = gc.getString(args[0].asStringId());
    const message_id = gc.getString(args[1].asStringId());
    const text = gc.getString(args[2].asStringId());
    const token = getToken(gc) orelse return error.MissingToken;

    const version_id = nextVersionId("edit");
    const path = std.fmt.allocPrint(gc.allocator, "/api/chats/{s}/messages/{s}", .{ chat_id, message_id }) catch
        return error.OutOfMemory;

    var json_buf: [4096]u8 = undefined;
    const json_body = std.fmt.bufPrint(&json_buf, "{{\"text\":\"{s}\"}}", .{text}) catch
        return error.Overflow;

    const resp = httpRequest(gc.allocator, .PUT, path, token, json_body) catch |err| {
        const obj = try gc.allocObj(.map);
        try addKV(obj, gc, "error", Value.makeString(try gc.internString(@errorName(err))));
        return Value.makeObj(obj);
    };

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "response", Value.makeString(try gc.internString(resp)));
    try addKV(obj, gc, "version", Value.makeInt(@bitCast(@as(u48, @truncate(version_id)))));
    return Value.makeObj(obj);
}

// (beeper-archive chat-id) → {:version <id>}
pub fn beeperArchiveFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1 or !args[0].isString()) return error.ArityError;
    const chat_id = gc.getString(args[0].asStringId());
    const token = getToken(gc) orelse return error.MissingToken;

    const unarchive = args.len >= 2 and args[1].isBool() and args[1].asBool();
    const version_id = nextVersionId("archive");
    const path = std.fmt.allocPrint(gc.allocator, "/api/chats/{s}/archive", .{chat_id}) catch
        return error.OutOfMemory;

    const method: HttpMethod = if (unarchive) .DELETE else .POST;
    const resp = httpRequest(gc.allocator, method, path, token, null) catch |err| {
        const obj = try gc.allocObj(.map);
        try addKV(obj, gc, "error", Value.makeString(try gc.internString(@errorName(err))));
        return Value.makeObj(obj);
    };

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "response", Value.makeString(try gc.internString(resp)));
    try addKV(obj, gc, "version", Value.makeInt(@bitCast(@as(u48, @truncate(version_id)))));
    return Value.makeObj(obj);
}

// (beeper-focus) → {:status :ok}
pub fn beeperFocusFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    _ = args;
    const token = getToken(gc) orelse return error.MissingToken;
    const version_id = nextVersionId("focus");

    _ = httpRequest(gc.allocator, .POST, "/api/focus", token, null) catch |err| {
        const obj = try gc.allocObj(.map);
        try addKV(obj, gc, "error", Value.makeString(try gc.internString(@errorName(err))));
        return Value.makeObj(obj);
    };

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "status", Value.makeKeyword(try gc.internString("ok")));
    try addKV(obj, gc, "version", Value.makeInt(@bitCast(@as(u48, @truncate(version_id)))));
    return Value.makeObj(obj);
}

// (beeper-color id) → {:hex "#AABBCC", :oklab {:L 0.65, :a 0.03, :b -0.05}}
pub fn beeperColorFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 1 or !args[0].isString()) return error.ArityError;
    const id = gc.getString(args[0].asStringId());

    const color = contactColor(id);
    const hex = colorToHex(color);

    const lab = try gc.allocObj(.map);
    try addKV(lab, gc, "L", Value.makeFloat(color.L));
    try addKV(lab, gc, "a", Value.makeFloat(color.a));
    try addKV(lab, gc, "b", Value.makeFloat(color.b));

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "hex", Value.makeString(try gc.internString(&hex)));
    try addKV(obj, gc, "oklab", Value.makeObj(lab));
    return Value.makeObj(obj);
}

// (beeper-timeline seed chat-id n) → {:nodes [...], :gluing-fp <u64>}
pub fn beeperTimelineFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len < 3) return error.ArityError;
    if (!args[0].isInt() or !args[1].isString() or !args[2].isInt()) return error.TypeError;

    const seed: u64 = @bitCast(@as(i64, args[0].asInt()));
    const chat_id = gc.getString(args[1].asStringId());
    const n: usize = @intCast(@as(u64, @bitCast(@as(i64, args[2].asInt()))) & 0xFF);

    var tl = Timeline.init(seed);
    // Zig 0.16.0: std.time.milliTimestamp removed; use libc clock_gettime.
    // Gated on non-WASM (WASM-freestanding has no libc).
    const now: i64 = if (@import("builtin").target.cpu.arch == .wasm32) 0 else blk: {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        break :blk @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    };
    for (0..n) |i| {
        _ = tl.append(now + @as(i64, @intCast(i)) * 1000, chat_id);
    }

    const nodes_obj = try gc.allocObj(.vector);
    for (0..tl.len) |i| {
        const node_map = try gc.allocObj(.map);
        try addKV(node_map, gc, "depth", Value.makeInt(@intCast(tl.nodes[i].tree.depth)));
        try addKV(node_map, gc, "fingerprint", Value.makeInt(@bitCast(@as(u48, @truncate(tl.nodes[i].message_version)))));
        try addKV(node_map, gc, "timestamp", Value.makeInt(@intCast(@as(u48, @truncate(@as(u64, @bitCast(tl.nodes[i].timestamp_ms)))))));
        try nodes_obj.data.vector.items.append(gc.allocator, Value.makeObj(node_map));
    }

    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "nodes", Value.makeObj(nodes_obj));
    try addKV(obj, gc, "gluing-fp", Value.makeInt(@bitCast(@as(u48, @truncate(tl.gluingFingerprint())))));
    try addKV(obj, gc, "len", Value.makeInt(@intCast(tl.len)));
    return Value.makeObj(obj);
}

// (beeper-spi-audit seed) → full SPI audit of beeper session RNG
pub fn beeperSpiAuditFn(args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value {
    return bumpus.spiAuditFn(args, gc, env, res);
}

// ============================================================================
// SKILL TABLE (gorj pattern: each tool is a nanoclj builtin)
// ============================================================================

pub const skill_table = .{
    .{ "beeper-init", &beeperInitFn },
    .{ "beeper-send", &beeperSendFn },
    .{ "beeper-messages", &beeperMessagesFn },
    .{ "beeper-chats", &beeperChatsFn },
    .{ "beeper-chat", &beeperChatFn },
    .{ "beeper-search", &beeperSearchFn },
    .{ "beeper-accounts", &beeperAccountsFn },
    .{ "beeper-contacts", &beeperContactsFn },
    .{ "beeper-edit", &beeperEditFn },
    .{ "beeper-archive", &beeperArchiveFn },
    .{ "beeper-focus", &beeperFocusFn },
    .{ "beeper-color", &beeperColorFn },
    .{ "beeper-timeline", &beeperTimelineFn },
    .{ "beeper-spi-audit", &beeperSpiAuditFn },
};

// ============================================================================
// MCP TOOL DESCRIPTORS (for gorj_mcp dispatch)
// ============================================================================

pub const mcp_tools = [_]struct { name: []const u8, description: []const u8, params: []const u8 }{
    .{ .name = "beeper_init", .description = "Initialize beeper session with seed", .params = "{\"seed\":\"integer\"}" },
    .{ .name = "beeper_send", .description = "Send message to chat", .params = "{\"chat_id\":\"string\",\"text\":\"string\"}" },
    .{ .name = "beeper_messages", .description = "List messages in chat", .params = "{\"chat_id\":\"string\"}" },
    .{ .name = "beeper_chats", .description = "List all chats", .params = "{}" },
    .{ .name = "beeper_chat", .description = "Get chat details with OKLAB color", .params = "{\"chat_id\":\"string\"}" },
    .{ .name = "beeper_search", .description = "Global search", .params = "{\"query\":\"string\"}" },
    .{ .name = "beeper_accounts", .description = "List connected accounts", .params = "{}" },
    .{ .name = "beeper_contacts", .description = "Search contacts on account", .params = "{\"account_id\":\"string\",\"query\":\"string\"}" },
    .{ .name = "beeper_edit", .description = "Edit a message", .params = "{\"chat_id\":\"string\",\"message_id\":\"string\",\"text\":\"string\"}" },
    .{ .name = "beeper_archive", .description = "Archive/unarchive chat", .params = "{\"chat_id\":\"string\",\"unarchive\":\"boolean\"}" },
    .{ .name = "beeper_focus", .description = "Bring Beeper to front", .params = "{}" },
    .{ .name = "beeper_color", .description = "Get deterministic OKLAB color for ID", .params = "{\"id\":\"string\"}" },
    .{ .name = "beeper_timeline", .description = "Generate Bumpus time-travel timeline", .params = "{\"seed\":\"integer\",\"chat_id\":\"string\",\"n\":\"integer\"}" },
    .{ .name = "beeper_spi_audit", .description = "SPI audit of session RNG", .params = "{\"seed\":\"integer\"}" },
};

// ============================================================================
// TESTS
// ============================================================================

test "contact color deterministic" {
    const c1 = contactColor("greenteatree01");
    const c2 = contactColor("greenteatree01");
    try std.testing.expectEqual(c1.L, c2.L);
    try std.testing.expectEqual(c1.a, c2.a);
    try std.testing.expectEqual(c1.b, c2.b);
    // Different ID → different color
    const c3 = contactColor("bmorphism");
    try std.testing.expect(c1.a != c3.a or c1.b != c3.b);
}

test "contact color hex format" {
    const c = contactColor("test-user");
    const hex = colorToHex(c);
    try std.testing.expectEqual(@as(u8, '#'), hex[0]);
}

test "timeline deterministic gluing" {
    var tl1 = Timeline.init(1069);
    _ = tl1.append(1000, "!chat:test");
    _ = tl1.append(2000, "!chat:test");
    var tl2 = Timeline.init(1069);
    _ = tl2.append(1000, "!chat:test");
    _ = tl2.append(2000, "!chat:test");
    try std.testing.expectEqual(tl1.gluingFingerprint(), tl2.gluingFingerprint());
    try std.testing.expect(tl1.gluingFingerprint() != 0);
}

test "timeline fork preserves structure" {
    const node = TimeNode.init(1069, 0, 1000, "!chat:test");
    const forked = node.fork();
    try std.testing.expect(forked.past.message_version != forked.future.message_version);
    try std.testing.expectEqual(forked.past.chat_id_hash, forked.future.chat_id_hash);
}

test "version id advances" {
    initBeeperSession(42);
    const v1 = nextVersionId("test");
    const v2 = nextVersionId("test");
    try std.testing.expect(v1 != v2);
}

test "beeper init builtin" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    var resources = Resources.initDefault();

    var args = [_]Value{Value.makeInt(1069)};
    const result = try beeperInitFn(&args, &gc, &env, &resources);
    try std.testing.expect(result.isObj());
}
