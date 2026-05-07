//! Monoidal diagram kernel for nanoclj-zig.
//!
//! This is a common substrate for graphical monoidal languages:
//! string diagrams, signal flow graphs, tensor networks, open games,
//! and ZX-style spider calculi. The first slice keeps the runtime
//! representation simple: Clojure maps and vectors in, Zig validation
//! and normalization out.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const Obj = value.Obj;
const GC = @import("gc.zig").GC;
const Env = @import("env.zig").Env;
const Resources = @import("transitivity.zig").Resources;
const semantics = @import("semantics.zig");

pub const DiagramError = error{
    ArityError,
    TypeError,
    InvalidDiagram,
    DomainMismatch,
};

const DiagramKind = enum {
    id,
    box,
    spider,
    swap,
    seq,
    tensor,
};

const Analysis = struct {
    kind: DiagramKind,
    normalized: Value,
    dom: std.ArrayListUnmanaged(Value) = .empty,
    cod: std.ArrayListUnmanaged(Value) = .empty,
    nodes: usize = 0,
    depth: usize = 0,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        self.dom.deinit(allocator);
        self.cod.deinit(allocator);
    }
};

fn kw(gc: *GC, s: []const u8) !Value {
    return Value.makeKeyword(try gc.internString(s));
}

fn addKV(obj: *Obj, gc: *GC, key: []const u8, val: Value) !void {
    try obj.data.map.keys.append(gc.allocator, try kw(gc, key));
    try obj.data.map.vals.append(gc.allocator, val);
}

fn mapGetByKeyword(map_obj: *Obj, gc: *GC, key: []const u8) ?Value {
    if (map_obj.kind != .map) return null;
    for (map_obj.data.map.keys.items, 0..) |k, i| {
        if (k.isKeyword() and std.mem.eql(u8, gc.getString(k.asKeywordId()), key)) {
            return map_obj.data.map.vals.items[i];
        }
    }
    return null;
}

fn valueName(val: Value, gc: *GC) ?[]const u8 {
    if (val.isKeyword()) return gc.getString(val.asKeywordId());
    if (val.isString()) return gc.getString(val.asStringId());
    if (val.isSymbol()) return gc.getString(val.asSymbolId());
    return null;
}

fn parseKind(tag_val: Value, gc: *GC) ?DiagramKind {
    const name = valueName(tag_val, gc) orelse return null;
    if (std.mem.eql(u8, name, "id")) return .id;
    if (std.mem.eql(u8, name, "box")) return .box;
    if (std.mem.eql(u8, name, "generator")) return .box;
    if (std.mem.eql(u8, name, "spider")) return .spider;
    if (std.mem.eql(u8, name, "swap")) return .swap;
    if (std.mem.eql(u8, name, "seq")) return .seq;
    if (std.mem.eql(u8, name, "tensor")) return .tensor;
    return null;
}

fn kindName(kind: DiagramKind) []const u8 {
    return switch (kind) {
        .id => "id",
        .box => "box",
        .spider => "spider",
        .swap => "swap",
        .seq => "seq",
        .tensor => "tensor",
    };
}

fn seqItems(val: Value) ?[]const Value {
    if (val.isNil()) return &[_]Value{};
    if (!val.isObj()) return null;
    const obj = val.asObj();
    return switch (obj.kind) {
        .vector => obj.data.vector.items.items,
        .list => obj.data.list.items.items,
        else => null,
    };
}

fn copySeq(dest: *std.ArrayListUnmanaged(Value), allocator: std.mem.Allocator, vals: []const Value) !void {
    try dest.appendSlice(allocator, vals);
}

fn sameInterface(a: []const Value, b: []const Value, gc: *GC) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| {
        if (!semantics.structuralEq(av, bv, gc)) return false;
    }
    return true;
}

fn vectorValue(gc: *GC, vals: []const Value) !Value {
    const vec = try gc.allocObj(.vector);
    try vec.data.vector.items.appendSlice(gc.allocator, vals);
    return Value.makeObj(vec);
}

fn maybeAttachAttrs(obj: *Obj, gc: *GC, attrs: ?Value) !void {
    if (attrs) |v| try addKV(obj, gc, "attrs", v);
}

fn makeIdDiagram(gc: *GC, wires: []const Value) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "tag", try kw(gc, "id"));
    try addKV(obj, gc, "wires", try vectorValue(gc, wires));
    return Value.makeObj(obj);
}

fn makeBoxDiagram(gc: *GC, name: Value, dom: []const Value, cod: []const Value, attrs: ?Value) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "tag", try kw(gc, "box"));
    try addKV(obj, gc, "name", name);
    try addKV(obj, gc, "dom", try vectorValue(gc, dom));
    try addKV(obj, gc, "cod", try vectorValue(gc, cod));
    try maybeAttachAttrs(obj, gc, attrs);
    return Value.makeObj(obj);
}

fn makeSpiderDiagram(gc: *GC, wire: Value, ins: i48, outs: i48, attrs: ?Value) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "tag", try kw(gc, "spider"));
    try addKV(obj, gc, "wire", wire);
    try addKV(obj, gc, "ins", Value.makeInt(ins));
    try addKV(obj, gc, "outs", Value.makeInt(outs));
    try maybeAttachAttrs(obj, gc, attrs);
    return Value.makeObj(obj);
}

fn makeSwapDiagram(gc: *GC, left: []const Value, right: []const Value) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "tag", try kw(gc, "swap"));
    try addKV(obj, gc, "left", try vectorValue(gc, left));
    try addKV(obj, gc, "right", try vectorValue(gc, right));
    return Value.makeObj(obj);
}

fn makeCompositeDiagram(gc: *GC, kind: DiagramKind, parts: []const Value, collapse_singleton: bool) !Value {
    if (collapse_singleton and parts.len == 1) return parts[0];
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "tag", try kw(gc, kindName(kind)));
    try addKV(obj, gc, "parts", try vectorValue(gc, parts));
    return Value.makeObj(obj);
}

fn appendFlattenedPart(dest: *std.ArrayListUnmanaged(Value), gc: *GC, expected: DiagramKind, analysis: Analysis) !void {
    if (analysis.kind != expected or !analysis.normalized.isObj()) {
        try dest.append(gc.allocator, analysis.normalized);
        return;
    }
    const obj = analysis.normalized.asObj();
    if (obj.kind != .map) {
        try dest.append(gc.allocator, analysis.normalized);
        return;
    }
    const parts_val = mapGetByKeyword(obj, gc, "parts") orelse {
        try dest.append(gc.allocator, analysis.normalized);
        return;
    };
    const parts = seqItems(parts_val) orelse {
        try dest.append(gc.allocator, analysis.normalized);
        return;
    };
    try dest.appendSlice(gc.allocator, parts);
}

fn analyzeComposite(kind: DiagramKind, parts_val: Value, gc: *GC) anyerror!Analysis {
    const parts = seqItems(parts_val) orelse return error.TypeError;
    if (parts.len == 0) return error.InvalidDiagram;

    var flat_parts: std.ArrayListUnmanaged(Value) = .empty;
    defer flat_parts.deinit(gc.allocator);

    var dom: std.ArrayListUnmanaged(Value) = .empty;
    errdefer dom.deinit(gc.allocator);
    var cod: std.ArrayListUnmanaged(Value) = .empty;
    errdefer cod.deinit(gc.allocator);

    var total_nodes: usize = 0;
    var max_depth: usize = 0;
    var first = true;
    var only_kind: DiagramKind = kind;

    for (parts) |part| {
        var child = try analyzeDiagram(part, gc);
        defer child.deinit(gc.allocator);

        try appendFlattenedPart(&flat_parts, gc, kind, child);
        total_nodes += child.nodes;
        if (child.depth > max_depth) max_depth = child.depth;

        if (first) {
            only_kind = child.kind;
            try copySeq(&dom, gc.allocator, child.dom.items);
            try copySeq(&cod, gc.allocator, child.cod.items);
            first = false;
            continue;
        }

        switch (kind) {
            .seq => {
                if (!sameInterface(cod.items, child.dom.items, gc)) {
                    return error.DomainMismatch;
                }
                cod.clearRetainingCapacity();
                try copySeq(&cod, gc.allocator, child.cod.items);
            },
            .tensor => {
                try copySeq(&dom, gc.allocator, child.dom.items);
                try copySeq(&cod, gc.allocator, child.cod.items);
            },
            else => return error.InvalidDiagram,
        }
    }

    const collapse = flat_parts.items.len == 1;
    const normalized = try makeCompositeDiagram(gc, kind, flat_parts.items, true);
    return .{
        .kind = if (collapse) only_kind else kind,
        .normalized = normalized,
        .dom = dom,
        .cod = cod,
        .nodes = total_nodes,
        .depth = if (collapse) max_depth else max_depth + 1,
    };
}

fn analyzeDiagram(diag: Value, gc: *GC) anyerror!Analysis {
    if (!diag.isObj()) return error.TypeError;
    const obj = diag.asObj();
    if (obj.kind != .map) return error.TypeError;

    const tag_val = mapGetByKeyword(obj, gc, "tag") orelse return error.InvalidDiagram;
    const kind = parseKind(tag_val, gc) orelse return error.InvalidDiagram;

    switch (kind) {
        .id => {
            const wires_val = mapGetByKeyword(obj, gc, "wires") orelse return error.InvalidDiagram;
            const wires = seqItems(wires_val) orelse return error.TypeError;
            var dom: std.ArrayListUnmanaged(Value) = .empty;
            errdefer dom.deinit(gc.allocator);
            var cod: std.ArrayListUnmanaged(Value) = .empty;
            errdefer cod.deinit(gc.allocator);
            try copySeq(&dom, gc.allocator, wires);
            try copySeq(&cod, gc.allocator, wires);
            return .{
                .kind = .id,
                .normalized = try makeIdDiagram(gc, wires),
                .dom = dom,
                .cod = cod,
                .nodes = 1,
                .depth = 1,
            };
        },
        .box => {
            const name = mapGetByKeyword(obj, gc, "name") orelse return error.InvalidDiagram;
            const dom_val = mapGetByKeyword(obj, gc, "dom") orelse return error.InvalidDiagram;
            const cod_val = mapGetByKeyword(obj, gc, "cod") orelse return error.InvalidDiagram;
            const dom_items = seqItems(dom_val) orelse return error.TypeError;
            const cod_items = seqItems(cod_val) orelse return error.TypeError;
            var dom: std.ArrayListUnmanaged(Value) = .empty;
            errdefer dom.deinit(gc.allocator);
            var cod: std.ArrayListUnmanaged(Value) = .empty;
            errdefer cod.deinit(gc.allocator);
            try copySeq(&dom, gc.allocator, dom_items);
            try copySeq(&cod, gc.allocator, cod_items);
            return .{
                .kind = .box,
                .normalized = try makeBoxDiagram(gc, name, dom_items, cod_items, mapGetByKeyword(obj, gc, "attrs")),
                .dom = dom,
                .cod = cod,
                .nodes = 1,
                .depth = 1,
            };
        },
        .spider => {
            const wire = mapGetByKeyword(obj, gc, "wire") orelse return error.InvalidDiagram;
            const ins_val = mapGetByKeyword(obj, gc, "ins") orelse return error.InvalidDiagram;
            const outs_val = mapGetByKeyword(obj, gc, "outs") orelse return error.InvalidDiagram;
            if (!ins_val.isInt() or !outs_val.isInt()) return error.TypeError;
            const ins = ins_val.asInt();
            const outs = outs_val.asInt();
            if (ins < 0 or outs < 0) return error.InvalidDiagram;

            var dom: std.ArrayListUnmanaged(Value) = .empty;
            errdefer dom.deinit(gc.allocator);
            var cod: std.ArrayListUnmanaged(Value) = .empty;
            errdefer cod.deinit(gc.allocator);

            var i: i48 = 0;
            while (i < ins) : (i += 1) try dom.append(gc.allocator, wire);
            i = 0;
            while (i < outs) : (i += 1) try cod.append(gc.allocator, wire);

            return .{
                .kind = .spider,
                .normalized = try makeSpiderDiagram(gc, wire, ins, outs, mapGetByKeyword(obj, gc, "attrs")),
                .dom = dom,
                .cod = cod,
                .nodes = 1,
                .depth = 1,
            };
        },
        .swap => {
            const left_val = mapGetByKeyword(obj, gc, "left") orelse return error.InvalidDiagram;
            const right_val = mapGetByKeyword(obj, gc, "right") orelse return error.InvalidDiagram;
            const left = seqItems(left_val) orelse return error.TypeError;
            const right = seqItems(right_val) orelse return error.TypeError;

            var dom: std.ArrayListUnmanaged(Value) = .empty;
            errdefer dom.deinit(gc.allocator);
            var cod: std.ArrayListUnmanaged(Value) = .empty;
            errdefer cod.deinit(gc.allocator);
            try copySeq(&dom, gc.allocator, left);
            try copySeq(&dom, gc.allocator, right);
            try copySeq(&cod, gc.allocator, right);
            try copySeq(&cod, gc.allocator, left);

            return .{
                .kind = .swap,
                .normalized = try makeSwapDiagram(gc, left, right),
                .dom = dom,
                .cod = cod,
                .nodes = 1,
                .depth = 1,
            };
        },
        .seq => {
            const parts_val = mapGetByKeyword(obj, gc, "parts") orelse return error.InvalidDiagram;
            return analyzeComposite(.seq, parts_val, gc);
        },
        .tensor => {
            const parts_val = mapGetByKeyword(obj, gc, "parts") orelse return error.InvalidDiagram;
            return analyzeComposite(.tensor, parts_val, gc);
        },
    }
}

fn errorLabel(err: anyerror) []const u8 {
    return switch (err) {
        error.ArityError => "arity-error",
        error.TypeError => "type-error",
        error.InvalidDiagram => "invalid-diagram",
        error.DomainMismatch => "domain-mismatch",
        else => "diagram-error",
    };
}

fn summaryFromAnalysis(analysis: Analysis, gc: *GC) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "ok", Value.makeBool(true));
    try addKV(obj, gc, "kind", try kw(gc, kindName(analysis.kind)));
    try addKV(obj, gc, "dom", try vectorValue(gc, analysis.dom.items));
    try addKV(obj, gc, "cod", try vectorValue(gc, analysis.cod.items));
    try addKV(obj, gc, "nodes", Value.makeInt(@intCast(analysis.nodes)));
    try addKV(obj, gc, "depth", Value.makeInt(@intCast(analysis.depth)));
    try addKV(obj, gc, "normalized", analysis.normalized);
    return Value.makeObj(obj);
}

fn errorSummary(gc: *GC, err: anyerror) !Value {
    const obj = try gc.allocObj(.map);
    try addKV(obj, gc, "ok", Value.makeBool(false));
    try addKV(obj, gc, "error", Value.makeString(try gc.internString(errorLabel(err))));
    return Value.makeObj(obj);
}

pub fn diagramIdFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const wires = seqItems(args[0]) orelse return error.TypeError;
    return makeIdDiagram(gc, wires);
}

pub fn diagramBoxFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3 and args.len != 4) return error.ArityError;
    const dom = seqItems(args[1]) orelse return error.TypeError;
    const cod = seqItems(args[2]) orelse return error.TypeError;
    const attrs: ?Value = if (args.len == 4) args[3] else null;
    return makeBoxDiagram(gc, args[0], dom, cod, attrs);
}

pub fn diagramSpiderFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 3 and args.len != 4) return error.ArityError;
    if (!args[1].isInt() or !args[2].isInt()) return error.TypeError;
    const attrs: ?Value = if (args.len == 4) args[3] else null;
    return makeSpiderDiagram(gc, args[0], args[1].asInt(), args[2].asInt(), attrs);
}

pub fn diagramSwapFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 2) return error.ArityError;
    const left = seqItems(args[0]) orelse return error.TypeError;
    const right = seqItems(args[1]) orelse return error.TypeError;
    return makeSwapDiagram(gc, left, right);
}

pub fn diagramSeqFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    return makeCompositeDiagram(gc, .seq, args, false);
}

pub fn diagramTensorFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len == 0) return error.ArityError;
    return makeCompositeDiagram(gc, .tensor, args, false);
}

pub fn diagramNormalizeFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    var analysis = try analyzeDiagram(args[0], gc);
    defer analysis.deinit(gc.allocator);
    return analysis.normalized;
}

pub fn diagramWellTypedFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    var analysis = analyzeDiagram(args[0], gc) catch return Value.makeBool(false);
    defer analysis.deinit(gc.allocator);
    return Value.makeBool(true);
}

pub fn diagramSummaryFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    var analysis = analyzeDiagram(args[0], gc) catch |err| return errorSummary(gc, err);
    defer analysis.deinit(gc.allocator);
    return summaryFromAnalysis(analysis, gc);
}

// ============================================================================
// RECURSIVE ASCII RENDERER
// ============================================================================
//
// Two-pass-fused: each `renderBlock` call descends into children, returning a
// fully-rendered `Block` (grid + port positions). Composition stitches the
// children's grids onto a parent grid in row-major order, drawing connecting
// wire segments at port positions.
//
// Bounded recursion: a depth counter caps descent to keep render cost linear
// in the analyzed diagram's depth (already validated by `analyzeDiagram`).

const RenderError = error{
    InvalidDiagram,
    TypeError,
    OutOfMemory,
    Utf8CannotEncodeSurrogateHalf,
    CodepointTooLarge,
};

const RENDER_MAX_DEPTH: u32 = 64;

const Block = struct {
    width: u32,
    height: u32,
    /// height * width codepoints, row-major. ' ' (0x20) means blank.
    grid: []u21,
    /// x-coordinate of each input wire at the top edge (length = dom.len).
    in_ports: []u32,
    /// x-coordinate of each output wire at the bottom edge (length = cod.len).
    out_ports: []u32,

    fn cellAt(self: *Block, x: u32, y: u32) *u21 {
        return &self.grid[y * self.width + x];
    }

    fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        allocator.free(self.grid);
        allocator.free(self.in_ports);
        allocator.free(self.out_ports);
    }
};

fn allocGrid(allocator: std.mem.Allocator, width: u32, height: u32) ![]u21 {
    const grid = try allocator.alloc(u21, @as(usize, width) * @as(usize, height));
    @memset(grid, ' ');
    return grid;
}

fn nameLenFromValue(name: Value, gc: *GC) u32 {
    const s = valueName(name, gc) orelse return 1;
    return @intCast(s.len);
}

fn writeName(grid: []u21, width: u32, row: u32, col: u32, name: Value, gc: *GC) void {
    const s = valueName(name, gc) orelse return;
    for (s, 0..) |c, i| {
        const x = col + @as(u32, @intCast(i));
        if (x >= width) break;
        grid[row * width + x] = c;
    }
}

fn renderBox(obj: *Obj, gc: *GC, allocator: std.mem.Allocator) RenderError!Block {
    const name = mapGetByKeyword(obj, gc, "name") orelse return error.InvalidDiagram;
    const dom_val = mapGetByKeyword(obj, gc, "dom") orelse return error.InvalidDiagram;
    const cod_val = mapGetByKeyword(obj, gc, "cod") orelse return error.InvalidDiagram;
    const dom_items = seqItems(dom_val) orelse return error.TypeError;
    const cod_items = seqItems(cod_val) orelse return error.TypeError;

    const n_in: u32 = @intCast(dom_items.len);
    const n_out: u32 = @intCast(cod_items.len);
    const max_ports = @max(n_in, n_out);
    const port_width: u32 = if (max_ports == 0) 0 else max_ports * 2 - 1;
    const inner_w = @max(nameLenFromValue(name, gc), port_width);
    const w = inner_w + 4;
    const h: u32 = 3; // [in-stub, trapezoid, out-stub]

    const grid = try allocGrid(allocator, w, h);
    errdefer allocator.free(grid);

    // White trapezoid row: ◁══ label ══▷
    grid[1 * w + 0] = '◁';
    grid[1 * w + (w - 1)] = '▷';
    var x: u32 = 1;
    while (x < w - 1) : (x += 1) grid[1 * w + x] = '═';
    const label_start = 2 + (inner_w - nameLenFromValue(name, gc)) / 2;
    writeName(grid, w, 1, label_start, name, gc);

    // Port stubs (row 0 above trapezoid, row 2 below trapezoid).
    const ins = try allocator.alloc(u32, n_in);
    errdefer allocator.free(ins);
    const outs = try allocator.alloc(u32, n_out);
    errdefer allocator.free(outs);

    var i: u32 = 0;
    while (i < n_in) : (i += 1) {
        const px = 2 + (if (n_in == 1) inner_w / 2 else (i * (inner_w - 1)) / (n_in - 1));
        ins[i] = px;
        grid[0 * w + px] = '│';
    }
    i = 0;
    while (i < n_out) : (i += 1) {
        const px = 2 + (if (n_out == 1) inner_w / 2 else (i * (inner_w - 1)) / (n_out - 1));
        outs[i] = px;
        grid[2 * w + px] = '│';
    }

    return .{ .width = w, .height = h, .grid = grid, .in_ports = ins, .out_ports = outs };
}

fn renderId(obj: *Obj, gc: *GC, allocator: std.mem.Allocator) RenderError!Block {
    const wires_val = mapGetByKeyword(obj, gc, "wires") orelse return error.InvalidDiagram;
    const wires = seqItems(wires_val) orelse return error.TypeError;
    const n: u32 = @intCast(wires.len);
    const w = if (n == 0) 1 else (n * 2 - 1);
    const grid = try allocGrid(allocator, w, 1);
    errdefer allocator.free(grid);

    const ins = try allocator.alloc(u32, n);
    errdefer allocator.free(ins);
    const outs = try allocator.alloc(u32, n);
    errdefer allocator.free(outs);

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const px = i * 2;
        ins[i] = px;
        outs[i] = px;
        grid[px] = '│';
    }
    return .{ .width = w, .height = 1, .grid = grid, .in_ports = ins, .out_ports = outs };
}

fn renderStub(obj: *Obj, gc: *GC, allocator: std.mem.Allocator, label: []const u8) RenderError!Block {
    _ = obj;
    _ = gc;
    const w: u32 = @intCast(label.len + 2);
    const grid = try allocGrid(allocator, w, 3);
    errdefer allocator.free(grid);
    grid[0 * w + (w / 2)] = '│';
    grid[1 * w + 0] = '<';
    for (label, 0..) |c, i| grid[1 * w + 1 + @as(u32, @intCast(i))] = c;
    grid[1 * w + (w - 1)] = '>';
    grid[2 * w + (w / 2)] = '│';
    const ins = try allocator.alloc(u32, 1);
    errdefer allocator.free(ins);
    const outs = try allocator.alloc(u32, 1);
    errdefer allocator.free(outs);
    ins[0] = w / 2;
    outs[0] = w / 2;
    return .{ .width = w, .height = 3, .grid = grid, .in_ports = ins, .out_ports = outs };
}

fn renderSeq(obj: *Obj, gc: *GC, allocator: std.mem.Allocator, depth: u32) RenderError!Block {
    const parts_val = mapGetByKeyword(obj, gc, "parts") orelse return error.InvalidDiagram;
    const parts = seqItems(parts_val) orelse return error.TypeError;
    if (parts.len == 0) return error.InvalidDiagram;

    var children: std.ArrayListUnmanaged(Block) = .empty;
    defer {
        for (children.items) |*c| c.deinit(allocator);
        children.deinit(allocator);
    }
    var max_w: u32 = 0;
    var total_h: u32 = 0;
    for (parts) |p| {
        const child = try renderBlock(p, gc, allocator, depth + 1);
        try children.append(allocator, child);
        max_w = @max(max_w, child.width);
        total_h += child.height;
    }
    // 1-row gap between adjacent children for connecting wires
    const gap_count: u32 = @intCast(children.items.len - 1);
    const out_w = max_w;
    const out_h = total_h + gap_count;

    const grid = try allocGrid(allocator, out_w, out_h);
    errdefer allocator.free(grid);

    // Stamp each child centered horizontally
    var y: u32 = 0;
    var prev_out_ports_abs: ?[]const u32 = null;
    var prev_y_bottom: u32 = 0;
    for (children.items) |child| {
        const x_off: u32 = (out_w - child.width) / 2;
        var ry: u32 = 0;
        while (ry < child.height) : (ry += 1) {
            var rx: u32 = 0;
            while (rx < child.width) : (rx += 1) {
                grid[(y + ry) * out_w + (x_off + rx)] = child.grid[ry * child.width + rx];
            }
        }
        // Draw connecting wires from prev's out_ports (last row above gap)
        if (prev_out_ports_abs) |prev| {
            const gap_y = prev_y_bottom; // single gap row
            // crude: draw vertical bars at each prev port and child input port; if they differ, leave them
            for (prev) |px| grid[gap_y * out_w + px] = '│';
            for (child.in_ports) |cx| grid[gap_y * out_w + (x_off + cx)] = '│';
        }
        // Save output ports in absolute coords for next iter
        const abs_outs = try allocator.alloc(u32, child.out_ports.len);
        for (child.out_ports, 0..) |op, i| abs_outs[i] = x_off + op;
        // Free previous
        if (prev_out_ports_abs) |prev| allocator.free(prev);
        prev_out_ports_abs = abs_outs;

        y += child.height;
        prev_y_bottom = y;
        // Skip the gap row except for the last child
        if (y < out_h) y += 1;
    }
    if (prev_out_ports_abs) |prev| allocator.free(prev);

    // Top in_ports = first child's in_ports shifted by its x_off
    const first = &children.items[0];
    const first_xoff: u32 = (out_w - first.width) / 2;
    const ins = try allocator.alloc(u32, first.in_ports.len);
    errdefer allocator.free(ins);
    for (first.in_ports, 0..) |p, i| ins[i] = first_xoff + p;

    // Bottom out_ports = last child's out_ports shifted
    const last = &children.items[children.items.len - 1];
    const last_xoff: u32 = (out_w - last.width) / 2;
    const outs = try allocator.alloc(u32, last.out_ports.len);
    errdefer allocator.free(outs);
    for (last.out_ports, 0..) |p, i| outs[i] = last_xoff + p;

    return .{ .width = out_w, .height = out_h, .grid = grid, .in_ports = ins, .out_ports = outs };
}

fn renderTensor(obj: *Obj, gc: *GC, allocator: std.mem.Allocator, depth: u32) RenderError!Block {
    const parts_val = mapGetByKeyword(obj, gc, "parts") orelse return error.InvalidDiagram;
    const parts = seqItems(parts_val) orelse return error.TypeError;
    if (parts.len == 0) return error.InvalidDiagram;

    var children: std.ArrayListUnmanaged(Block) = .empty;
    defer {
        for (children.items) |*c| c.deinit(allocator);
        children.deinit(allocator);
    }
    var total_w: u32 = 0;
    var max_h: u32 = 0;
    for (parts) |p| {
        const child = try renderBlock(p, gc, allocator, depth + 1);
        try children.append(allocator, child);
        total_w += child.width + 1; // 1-col gap between children
        max_h = @max(max_h, child.height);
    }
    if (total_w > 0) total_w -= 1; // strip trailing gap

    const grid = try allocGrid(allocator, total_w, max_h);
    errdefer allocator.free(grid);

    var n_in: usize = 0;
    var n_out: usize = 0;
    for (children.items) |c| {
        n_in += c.in_ports.len;
        n_out += c.out_ports.len;
    }
    const ins = try allocator.alloc(u32, n_in);
    errdefer allocator.free(ins);
    const outs = try allocator.alloc(u32, n_out);
    errdefer allocator.free(outs);

    var x_off: u32 = 0;
    var in_idx: usize = 0;
    var out_idx: usize = 0;
    for (children.items) |child| {
        const y_off: u32 = (max_h - child.height) / 2;
        var ry: u32 = 0;
        while (ry < child.height) : (ry += 1) {
            var rx: u32 = 0;
            while (rx < child.width) : (rx += 1) {
                grid[(y_off + ry) * total_w + (x_off + rx)] = child.grid[ry * child.width + rx];
            }
        }
        for (child.in_ports) |p| {
            ins[in_idx] = x_off + p;
            in_idx += 1;
        }
        for (child.out_ports) |p| {
            outs[out_idx] = x_off + p;
            out_idx += 1;
        }
        x_off += child.width + 1;
    }
    return .{ .width = total_w, .height = max_h, .grid = grid, .in_ports = ins, .out_ports = outs };
}

fn renderBlock(diag: Value, gc: *GC, allocator: std.mem.Allocator, depth: u32) RenderError!Block {
    if (depth > RENDER_MAX_DEPTH) return error.InvalidDiagram;
    if (!diag.isObj()) return error.TypeError;
    const obj = diag.asObj();
    if (obj.kind != .map) return error.TypeError;
    const tag_val = mapGetByKeyword(obj, gc, "tag") orelse return error.InvalidDiagram;
    const kind = parseKind(tag_val, gc) orelse return error.InvalidDiagram;
    return switch (kind) {
        .id => renderId(obj, gc, allocator),
        .box => renderBox(obj, gc, allocator),
        .spider => renderStub(obj, gc, allocator, "spider"),
        .swap => renderStub(obj, gc, allocator, "swap"),
        .seq => renderSeq(obj, gc, allocator, depth),
        .tensor => renderTensor(obj, gc, allocator, depth),
    };
}

/// Render a diagram (already produced by makeBox/makeSeq/etc.) as a UTF-8 ASCII string.
/// Returned slice is owned by `allocator`.
pub fn renderAscii(diag: Value, gc: *GC, allocator: std.mem.Allocator) ![]u8 {
    var block = try renderBlock(diag, gc, allocator, 0);
    defer block.deinit(allocator);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var utf8_buf: [4]u8 = undefined;
    var y: u32 = 0;
    while (y < block.height) : (y += 1) {
        var x: u32 = 0;
        while (x < block.width) : (x += 1) {
            const cp = block.grid[y * block.width + x];
            const n = try std.unicode.utf8Encode(cp, &utf8_buf);
            try out.appendSlice(allocator, utf8_buf[0..n]);
        }
        if (y + 1 < block.height) try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

pub fn diagramRenderAsciiFn(args: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    if (args.len != 1) return error.ArityError;
    const s = try renderAscii(args[0], gc, gc.allocator);
    defer gc.allocator.free(s);
    return Value.makeString(try gc.internString(s));
}

test "monoidal diagram: ascii renderer outputs labelled boxes for seq" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const A = try kw(&gc, "A");
    const B = try kw(&gc, "B");
    const C = try kw(&gc, "C");
    const f = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("f")), &.{A}, &.{B}, null);
    const g = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("g")), &.{B}, &.{C}, null);
    var seq_args = [_]Value{ f, g };
    const seq = try makeCompositeDiagram(&gc, .seq, seq_args[0..], false);

    const out = try renderAscii(seq, &gc, std.testing.allocator);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "f") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "g") != null);
    // Atomic skills render as white trapezoids.
    try std.testing.expect(std.mem.indexOf(u8, out, "◁") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "▷") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "═") != null);
    // Vertical wire glyph should appear (port stubs)
    try std.testing.expect(std.mem.indexOf(u8, out, "│") != null);
}

test "monoidal diagram: ascii renderer handles tensor of two boxes" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();

    const A = try kw(&gc, "A");
    const B = try kw(&gc, "B");
    const C = try kw(&gc, "C");
    const D = try kw(&gc, "D");
    const f = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("f")), &.{A}, &.{B}, null);
    const h = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("h")), &.{C}, &.{D}, null);
    var tensor_args = [_]Value{ f, h };
    const tensor = try makeCompositeDiagram(&gc, .tensor, tensor_args[0..], false);

    const out = try renderAscii(tensor, &gc, std.testing.allocator);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "f") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "h") != null);
}

test "monoidal diagram: sequential composition normalizes and preserves interfaces" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    var resources = Resources.initDefault();

    const A = try kw(&gc, "A");
    const B = try kw(&gc, "B");
    const C = try kw(&gc, "C");
    const f = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("f")), &.{A}, &.{B}, null);
    const g = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("g")), &.{B}, &.{C}, null);
    var seq_args = [_]Value{ f, g };
    const seq = try diagramSeqFn(seq_args[0..], &gc, &env, &resources);

    var analysis = try analyzeDiagram(seq, &gc);
    defer analysis.deinit(gc.allocator);

    try std.testing.expectEqual(DiagramKind.seq, analysis.kind);
    try std.testing.expectEqual(@as(usize, 1), analysis.dom.items.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.cod.items.len);
    try std.testing.expect(semantics.structuralEq(A, analysis.dom.items[0], &gc));
    try std.testing.expect(semantics.structuralEq(C, analysis.cod.items[0], &gc));
}

test "monoidal diagram: tensor concatenates boundaries" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    var resources = Resources.initDefault();

    const A = try kw(&gc, "A");
    const B = try kw(&gc, "B");
    const C = try kw(&gc, "C");
    const D = try kw(&gc, "D");
    const f = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("f")), &.{A}, &.{B}, null);
    const g = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("g")), &.{C}, &.{D}, null);
    var tensor_args = [_]Value{ f, g };
    const tensor = try diagramTensorFn(tensor_args[0..], &gc, &env, &resources);

    var analysis = try analyzeDiagram(tensor, &gc);
    defer analysis.deinit(gc.allocator);

    try std.testing.expectEqual(DiagramKind.tensor, analysis.kind);
    try std.testing.expectEqual(@as(usize, 2), analysis.dom.items.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.cod.items.len);
    try std.testing.expect(semantics.structuralEq(A, analysis.dom.items[0], &gc));
    try std.testing.expect(semantics.structuralEq(C, analysis.dom.items[1], &gc));
    try std.testing.expect(semantics.structuralEq(B, analysis.cod.items[0], &gc));
    try std.testing.expect(semantics.structuralEq(D, analysis.cod.items[1], &gc));
}

test "monoidal diagram: invalid sequential composition is rejected" {
    var gc = GC.init(std.testing.allocator);
    defer gc.deinit();
    var env = Env.init(gc.allocator, null);
    defer env.deinit();
    var resources = Resources.initDefault();

    const A = try kw(&gc, "A");
    const B = try kw(&gc, "B");
    const C = try kw(&gc, "C");
    const D = try kw(&gc, "D");
    const f = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("f")), &.{A}, &.{B}, null);
    const g = try makeBoxDiagram(&gc, Value.makeString(try gc.internString("g")), &.{C}, &.{D}, null);
    var seq_args = [_]Value{ f, g };
    const seq = try diagramSeqFn(seq_args[0..], &gc, &env, &resources);

    try std.testing.expectError(error.DomainMismatch, analyzeDiagram(seq, &gc));
}
