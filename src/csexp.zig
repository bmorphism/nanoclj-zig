//! csexp.zig — neutral canonical S-expression tree.
//!
//! This is the middle lane in the format triad:
//!
//!   colon config (+1) -> csexp-like tree (0) -> Syrup wire (-1)
//!
//! It deliberately knows nothing about nanoclj Value semantics or Syrup tags.
//! Its job is shape: length-prefixed atoms, parenthesized lists, deterministic
//! parsing, and canonical re-emission.

const std = @import("std");

pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,
};

pub const format_triad = [_]Trit{ .plus, .zero, .minus };

pub fn triadSum() i32 {
    var sum: i32 = 0;
    for (format_triad) |t| sum += @intFromEnum(t);
    return sum;
}

pub fn triadBalanced() bool {
    return @mod(triadSum(), 3) == 0;
}

pub const Node = union(enum) {
    atom: []const u8,
    list: []Node,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .atom => {},
            .list => |items| {
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            },
        }
        self.* = .{ .atom = "" };
    }
};

pub const ParseError = error{
    UnexpectedEnd,
    InvalidFormat,
    Overflow,
    OutOfMemory,
    TrailingData,
};

pub const ParseResult = struct {
    node: Node,
    consumed: usize,
};

pub fn parse(input: []const u8, allocator: std.mem.Allocator) ParseError!Node {
    var result = try parseAt(input, skipSpace(input, 0), allocator);
    const end = skipSpace(input, result.consumed);
    if (end != input.len) {
        result.node.deinit(allocator);
        return error.TrailingData;
    }
    return result.node;
}

fn parseAt(input: []const u8, start: usize, allocator: std.mem.Allocator) ParseError!ParseResult {
    const pos = skipSpace(input, start);
    if (pos >= input.len) return error.UnexpectedEnd;
    return switch (input[pos]) {
        '(' => parseList(input, pos, allocator),
        '0'...'9' => parseAtom(input, pos),
        else => error.InvalidFormat,
    };
}

fn parseAtom(input: []const u8, start: usize) ParseError!ParseResult {
    var colon = start;
    while (colon < input.len and input[colon] != ':') : (colon += 1) {
        if (!isDigit(input[colon])) return error.InvalidFormat;
    }
    if (colon >= input.len) return error.UnexpectedEnd;
    if (colon == start) return error.InvalidFormat;

    const len = std.fmt.parseInt(usize, input[start..colon], 10) catch |err| switch (err) {
        error.Overflow => return error.Overflow,
        else => return error.InvalidFormat,
    };
    const body_start = colon + 1;
    const body_end = body_start + len;
    if (body_end < body_start) return error.Overflow;
    if (body_end > input.len) return error.UnexpectedEnd;

    return .{
        .node = .{ .atom = input[body_start..body_end] },
        .consumed = body_end,
    };
}

fn parseList(input: []const u8, start: usize, allocator: std.mem.Allocator) ParseError!ParseResult {
    var items: std.ArrayListUnmanaged(Node) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    var pos = start + 1;
    while (true) {
        pos = skipSpace(input, pos);
        if (pos >= input.len) return error.UnexpectedEnd;
        if (input[pos] == ')') {
            return .{
                .node = .{ .list = try items.toOwnedSlice(allocator) },
                .consumed = pos + 1,
            };
        }

        var child = try parseAt(input, pos, allocator);
        items.append(allocator, child.node) catch |err| {
            child.node.deinit(allocator);
            return err;
        };
        pos = child.consumed;
    }
}

pub fn encode(node: Node, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    var tmp: [32]u8 = undefined;
    switch (node) {
        .atom => |bytes| {
            const hdr = try std.fmt.bufPrint(&tmp, "{d}:", .{bytes.len});
            try out.appendSlice(allocator, hdr);
            try out.appendSlice(allocator, bytes);
        },
        .list => |items| {
            try out.append(allocator, '(');
            for (items) |item| try encode(item, out, allocator);
            try out.append(allocator, ')');
        },
    }
}

pub fn encodeAlloc(node: Node, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try encode(node, &out, allocator);
    return try out.toOwnedSlice(allocator);
}

fn skipSpace(input: []const u8, start: usize) usize {
    var pos = start;
    while (pos < input.len and isSpace(input[pos])) : (pos += 1) {}
    return pos;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

test "csexp parses length-prefixed atom" {
    var node = try parse("5:hello", std.testing.allocator);
    defer node.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello", node.atom);
}

test "csexp parses nested lists" {
    var node = try parse("(3:cmd(4:eval3:foo)0:)", std.testing.allocator);
    defer node.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), node.list.len);
    try std.testing.expectEqualStrings("cmd", node.list[0].atom);
    try std.testing.expectEqual(@as(usize, 2), node.list[1].list.len);
    try std.testing.expectEqualStrings("eval", node.list[1].list[0].atom);
    try std.testing.expectEqualStrings("foo", node.list[1].list[1].atom);
    try std.testing.expectEqualStrings("", node.list[2].atom);
}

test "csexp encoder canonicalizes reader whitespace" {
    var node = try parse("(3:foo  (3:bar 0:)  )", std.testing.allocator);
    defer node.deinit(std.testing.allocator);

    const encoded = try encodeAlloc(node, std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("(3:foo(3:bar0:))", encoded);
}

test "csexp rejects trailing data" {
    try std.testing.expectError(error.TrailingData, parse("3:foo3:bar", std.testing.allocator));
}

test "csexp empty list is canonical" {
    var node = try parse("()", std.testing.allocator);
    defer node.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), node.list.len);
    const encoded = try encodeAlloc(node, std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("()", encoded);
}

test "format triad is GF(3) balanced" {
    try std.testing.expectEqual(@as(i32, 0), triadSum());
    try std.testing.expect(triadBalanced());
}
