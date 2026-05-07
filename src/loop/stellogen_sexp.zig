//! Stellogen S-expression serialization — wire format for OCaml↔Zig handoff.
//!
//! Wire format (compatible with OCaml Sexplib):
//!   Ray:   (var NAME)  |  (var NAME INDEX)  |  (func POLARITY NAME child...)
//!   Ban:   (ineq ray ray)  |  (incomp ray ray)
//!   Star:  (star MARK (rays ray...) (bans ban...))
//!   Constellation:  (constellation star...)
//!   TOFU envelope:  (tofu SEED INDEX HEX (constellation ...))
//!
//! Color-aware mode: polarity preserved as +/-/~
//! Color-unaware mode: all polarities emitted as ~ (null)

const std = @import("std");
const sg = @import("stellogen.zig");
const Ray = sg.Ray;
const Star = sg.Star;
const Ban = sg.Ban;
const Polarity = sg.Polarity;
const Constellation = sg.Constellation;

pub const SerializeMode = enum {
    color_aware,
    color_unaware,
};

pub const TofuEnvelope = struct {
    seed: u64,
    index: u16,
    hex: [7]u8, // "#RRGGBB"
    constellation: []const u8, // serialized inner
};

// ═══════════════════════════════════════════════════════════════════════
// SERIALIZE — Zig constellation → s-expression string
// ═══════════════════════════════════════════════════════════════════════

pub fn serializeRay(writer: anytype, ray: Ray, mode: SerializeMode) !void {
    switch (ray) {
        .variable => |v| {
            try writer.writeAll("(var ");
            try writer.writeAll(v.name);
            if (v.index) |idx| {
                try writer.print(" {d}", .{idx});
            }
            try writer.writeByte(')');
        },
        .func => |f| {
            try writer.writeAll("(func ");
            const pol_char: u8 = switch (mode) {
                .color_aware => switch (f.polarity) {
                    .pos => '+',
                    .neg => '-',
                    .null_ => '~',
                },
                .color_unaware => '~',
            };
            try writer.writeByte(pol_char);
            try writer.writeByte(' ');
            try writer.writeAll(f.name);
            for (f.children) |c| {
                try writer.writeByte(' ');
                try serializeRay(writer, c, mode);
            }
            try writer.writeByte(')');
        },
    }
}

pub fn serializeBan(writer: anytype, ban: Ban, mode: SerializeMode) !void {
    switch (ban) {
        .ineq => |pair| {
            try writer.writeAll("(ineq ");
            try serializeRay(writer, pair[0], mode);
            try writer.writeByte(' ');
            try serializeRay(writer, pair[1], mode);
            try writer.writeByte(')');
        },
        .incomp => |pair| {
            try writer.writeAll("(incomp ");
            try serializeRay(writer, pair[0], mode);
            try writer.writeByte(' ');
            try serializeRay(writer, pair[1], mode);
            try writer.writeByte(')');
        },
    }
}

pub fn serializeStar(writer: anytype, star: Star, mode: SerializeMode) !void {
    try writer.writeAll("(star ");
    try writer.writeAll(switch (star.mark) {
        .state => "state",
        .action => "action",
    });
    try writer.writeAll(" (rays");
    for (star.rays) |r| {
        try writer.writeByte(' ');
        try serializeRay(writer, r, mode);
    }
    try writer.writeByte(')');
    if (star.bans.len > 0) {
        try writer.writeAll(" (bans");
        for (star.bans) |b| {
            try writer.writeByte(' ');
            try serializeBan(writer, b, mode);
        }
        try writer.writeByte(')');
    }
    try writer.writeByte(')');
}

pub fn serializeConstellation(writer: anytype, c: *const Constellation, mode: SerializeMode) !void {
    try writer.writeAll("(constellation");
    for (c.stars.items) |s| {
        try writer.writeByte(' ');
        try serializeStar(writer, s, mode);
    }
    try writer.writeByte(')');
}

/// Wrap a serialized constellation in a TOFU envelope with Gay identity.
pub fn serializeTofu(writer: anytype, c: *const Constellation, mode: SerializeMode, seed: u64, index: u16, hex: []const u8) !void {
    try writer.writeAll("(tofu ");
    try writer.print("{d} {d} ", .{ seed, index });
    try writer.writeAll(hex);
    try writer.writeByte(' ');
    try serializeConstellation(writer, c, mode);
    try writer.writeByte(')');
}

// ═══════════════════════════════════════════════════════════════════════
// DESERIALIZE — s-expression string → Zig constellation (minimal parser)
// ═══════════════════════════════════════════════════════════════════════

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidPolarity,
    InvalidMark,
    InvalidBanKind,
    OutOfMemory,
};

const Token = union(enum) {
    open_paren,
    close_paren,
    atom: []const u8,
};

fn tokenize(input: []const u8, out: *std.ArrayListUnmanaged(Token), allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < input.len) {
        switch (input[i]) {
            '(' => {
                try out.append(allocator, .open_paren);
                i += 1;
            },
            ')' => {
                try out.append(allocator, .close_paren);
                i += 1;
            },
            ' ', '\t', '\n', '\r' => i += 1,
            else => {
                const start = i;
                while (i < input.len and input[i] != '(' and input[i] != ')' and input[i] != ' ' and input[i] != '\t' and input[i] != '\n') {
                    i += 1;
                }
                try out.append(allocator, .{ .atom = input[start..i] });
            },
        }
    }
}

const Parser = struct {
    tokens: []const Token,
    pos: usize = 0,

    fn peek(self: *Parser) ?Token {
        if (self.pos >= self.tokens.len) return null;
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) !Token {
        if (self.pos >= self.tokens.len) return ParseError.UnexpectedEof;
        const t = self.tokens[self.pos];
        self.pos += 1;
        return t;
    }

    fn expectOpen(self: *Parser) !void {
        const t = try self.advance();
        if (t != .open_paren) return ParseError.UnexpectedToken;
    }

    fn expectClose(self: *Parser) !void {
        const t = try self.advance();
        if (t != .close_paren) return ParseError.UnexpectedToken;
    }

    fn expectAtom(self: *Parser) ![]const u8 {
        const t = try self.advance();
        return switch (t) {
            .atom => |a| a,
            else => ParseError.UnexpectedToken,
        };
    }

    fn parseRay(self: *Parser) !Ray {
        try self.expectOpen();
        const kind = try self.expectAtom();
        if (std.mem.eql(u8, kind, "var")) {
            const name = try self.expectAtom();
            // Optional index
            const next = self.peek() orelse return ParseError.UnexpectedEof;
            if (next == .close_paren) {
                try self.expectClose();
                return .{ .variable = .{ .name = name } };
            }
            const idx_str = try self.expectAtom();
            const idx = std.fmt.parseInt(u16, idx_str, 10) catch return ParseError.UnexpectedToken;
            try self.expectClose();
            return .{ .variable = .{ .name = name, .index = idx } };
        } else if (std.mem.eql(u8, kind, "func")) {
            const pol_str = try self.expectAtom();
            const pol: Polarity = if (pol_str.len == 1) switch (pol_str[0]) {
                '+' => .pos,
                '-' => .neg,
                '~' => .null_,
                else => return ParseError.InvalidPolarity,
            } else return ParseError.InvalidPolarity;
            const name = try self.expectAtom();
            // Children until close paren
            var children = std.ArrayListUnmanaged(Ray).empty;
            while (true) {
                const next = self.peek() orelse return ParseError.UnexpectedEof;
                if (next == .close_paren) break;
                const child = try self.parseRay();
                try children.append(std.heap.page_allocator, child);
            }
            try self.expectClose();
            return .{ .func = .{
                .polarity = pol,
                .name = name,
                .children = children.items,
            } };
        } else return ParseError.UnexpectedToken;
    }

    fn parseBan(self: *Parser) !Ban {
        try self.expectOpen();
        const kind = try self.expectAtom();
        const r1 = try self.parseRay();
        const r2 = try self.parseRay();
        try self.expectClose();
        if (std.mem.eql(u8, kind, "ineq")) {
            return .{ .ineq = .{ r1, r2 } };
        } else if (std.mem.eql(u8, kind, "incomp")) {
            return .{ .incomp = .{ r1, r2 } };
        } else return ParseError.InvalidBanKind;
    }

    fn parseStar(self: *Parser) !Star {
        try self.expectOpen();
        const star_kw = try self.expectAtom();
        if (!std.mem.eql(u8, star_kw, "star")) return ParseError.UnexpectedToken;
        const mark_str = try self.expectAtom();
        const mark: sg.Mark = if (std.mem.eql(u8, mark_str, "state")) .state else if (std.mem.eql(u8, mark_str, "action")) .action else return ParseError.InvalidMark;

        // (rays ...)
        try self.expectOpen();
        const rays_kw = try self.expectAtom();
        if (!std.mem.eql(u8, rays_kw, "rays")) return ParseError.UnexpectedToken;
        var rays = std.ArrayListUnmanaged(Ray).empty;
        while (true) {
            const next = self.peek() orelse return ParseError.UnexpectedEof;
            if (next == .close_paren) break;
            try rays.append(std.heap.page_allocator, try self.parseRay());
        }
        try self.expectClose();

        // Optional (bans ...)
        var bans = std.ArrayListUnmanaged(Ban).empty;
        const next = self.peek() orelse return ParseError.UnexpectedEof;
        if (next == .open_paren) {
            // Peek ahead to see if it's "(bans"
            const saved = self.pos;
            try self.expectOpen();
            const maybe_bans = try self.expectAtom();
            if (std.mem.eql(u8, maybe_bans, "bans")) {
                while (true) {
                    const bn = self.peek() orelse return ParseError.UnexpectedEof;
                    if (bn == .close_paren) break;
                    try bans.append(std.heap.page_allocator, try self.parseBan());
                }
                try self.expectClose();
            } else {
                self.pos = saved; // rewind
            }
        }

        try self.expectClose();
        return .{ .rays = rays.items, .bans = bans.items, .mark = mark };
    }

    fn parseConstellation(self: *Parser, allocator: std.mem.Allocator) !Constellation {
        try self.expectOpen();
        const kw = try self.expectAtom();
        if (!std.mem.eql(u8, kw, "constellation")) return ParseError.UnexpectedToken;
        var c = Constellation.init(allocator);
        while (true) {
            const next = self.peek() orelse return ParseError.UnexpectedEof;
            if (next == .close_paren) break;
            const star = try self.parseStar();
            try c.addStar(star);
        }
        try self.expectClose();
        return c;
    }
};

pub fn parseConstellationSexp(input: []const u8, allocator: std.mem.Allocator) !Constellation {
    var tokens = std.ArrayListUnmanaged(Token).empty;
    defer tokens.deinit(allocator);
    try tokenize(input, &tokens, allocator);
    var parser = Parser{ .tokens = tokens.items };
    return parser.parseConstellation(allocator);
}

/// Parse a TOFU envelope, returning seed, index, hex, and the inner constellation.
pub fn parseTofuSexp(input: []const u8, allocator: std.mem.Allocator) !struct {
    seed: u64,
    index: u16,
    hex: []const u8,
    constellation: Constellation,
} {
    var tokens = std.ArrayListUnmanaged(Token).empty;
    defer tokens.deinit(allocator);
    try tokenize(input, &tokens, allocator);
    var parser = Parser{ .tokens = tokens.items };

    try parser.expectOpen();
    const kw = try parser.expectAtom();
    if (!std.mem.eql(u8, kw, "tofu")) return ParseError.UnexpectedToken;
    const seed_str = try parser.expectAtom();
    const seed = std.fmt.parseInt(u64, seed_str, 10) catch return ParseError.UnexpectedToken;
    const idx_str = try parser.expectAtom();
    const idx = std.fmt.parseInt(u16, idx_str, 10) catch return ParseError.UnexpectedToken;
    const hex = try parser.expectAtom();
    const c = try parser.parseConstellation(allocator);
    try parser.expectClose();
    return .{ .seed = seed, .index = idx, .hex = hex, .constellation = c };
}

// ═══════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════

// ── Basic round-trips ──

test "serialize/parse round-trip: simple constellation" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const s_rays = [_]Ray{ sg.makePosConst("msg"), sg.makeVar("X") };
    const a_rays = [_]Ray{sg.makeNegConst("msg")};
    try c.addStar(.{ .rays = &s_rays, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();

    try std.testing.expectEqual(@as(usize, 2), c2.stars.items.len);
    try std.testing.expectEqual(sg.Mark.state, c2.stars.items[0].mark);
    try std.testing.expectEqual(sg.Mark.action, c2.stars.items[1].mark);
}

test "serialize color-unaware: polarities stripped to null" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{sg.makePosConst("hello")};
    try c.addStar(.{ .rays = &rays, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_unaware);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "~ hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "+ hello") == null);
}

test "serialize/parse: bans preserved" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{sg.makePosConst("x")};
    const bans = [_]Ban{.{ .ineq = .{ sg.makeVar("A"), sg.makePosConst("b") } }};
    try c.addStar(.{ .rays = &rays, .bans = &bans, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();

    try std.testing.expectEqual(@as(usize, 1), c2.stars.items[0].bans.len);
}

test "TOFU envelope round-trip" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{sg.makePosConst("tofu-test")};
    try c.addStar(.{ .rays = &rays, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeTofu(&buf.writer, &c, .color_aware, 31337, 1, "#3AF4CB");

    const parsed = try parseTofuSexp(buf.written(), alloc);
    var c2 = parsed.constellation;
    defer c2.deinit();

    try std.testing.expectEqual(@as(u64, 31337), parsed.seed);
    try std.testing.expectEqual(@as(u16, 1), parsed.index);
    try std.testing.expect(std.mem.eql(u8, "#3AF4CB", parsed.hex));
    try std.testing.expectEqual(@as(usize, 1), c2.stars.items.len);
}

test "color-aware vs color-unaware: different serializations" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{ sg.makePosConst("a"), sg.makeNegConst("b") };
    try c.addStar(.{ .rays = &rays, .mark = .action });

    var aware_buf: std.Io.Writer.Allocating = .init(alloc);
    defer aware_buf.deinit();
    try serializeConstellation(&aware_buf.writer, &c, .color_aware);

    var unaware_buf: std.Io.Writer.Allocating = .init(alloc);
    defer unaware_buf.deinit();
    try serializeConstellation(&unaware_buf.writer, &c, .color_unaware);

    try std.testing.expect(!std.mem.eql(u8, aware_buf.written(), unaware_buf.written()));

    var c2 = try parseConstellationSexp(unaware_buf.written(), alloc);
    defer c2.deinit();
    for (c2.stars.items[0].rays) |r| {
        switch (r) {
            .func => |f| try std.testing.expectEqual(Polarity.null_, f.polarity),
            .variable => {},
        }
    }
}

// ── Empty / degenerate cases ──

test "empty constellation round-trip" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    try std.testing.expect(std.mem.eql(u8, "(constellation)", buf.written()));

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();
    try std.testing.expectEqual(@as(usize, 0), c2.stars.items.len);
}

test "star with no bans: no bans section emitted" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{sg.makePosConst("x")};
    try c.addStar(.{ .rays = &rays, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(bans") == null);
}

// ── Variable serialization ──

test "variable with index round-trip" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{.{ .variable = .{ .name = "X", .index = 42 } }};
    try c.addStar(.{ .rays = &rays, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(var X 42)") != null);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();
    const r = c2.stars.items[0].rays[0];
    switch (r) {
        .variable => |v| {
            try std.testing.expect(std.mem.eql(u8, "X", v.name));
            try std.testing.expectEqual(@as(u16, 42), v.index.?);
        },
        else => return error.UnexpectedToken,
    }
}

test "variable without index round-trip" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{sg.makeVar("Y")};
    try c.addStar(.{ .rays = &rays, .mark = .action });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(var Y)") != null);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();
    const r = c2.stars.items[0].rays[0];
    switch (r) {
        .variable => |v| {
            try std.testing.expect(std.mem.eql(u8, "Y", v.name));
            try std.testing.expect(v.index == null);
        },
        else => return error.UnexpectedToken,
    }
}

// ── All three polarities ──

test "all polarity values round-trip color-aware" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{
        sg.makePosConst("pos"),
        sg.makeNegConst("neg"),
        sg.Ray{ .func = .{ .polarity = .null_, .name = "nul", .children = &.{} } },
    };
    try c.addStar(.{ .rays = &rays, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(func + pos)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(func - neg)") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(func ~ nul)") != null);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();
    const parsed_rays = c2.stars.items[0].rays;
    try std.testing.expectEqual(Polarity.pos, parsed_rays[0].func.polarity);
    try std.testing.expectEqual(Polarity.neg, parsed_rays[1].func.polarity);
    try std.testing.expectEqual(Polarity.null_, parsed_rays[2].func.polarity);
}

// ── Ban variants ──

test "incomp ban round-trip" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{sg.makePosConst("p")};
    const bans = [_]Ban{.{ .incomp = .{ sg.makeVar("X"), sg.makeVar("Y") } }};
    try c.addStar(.{ .rays = &rays, .bans = &bans, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(incomp") != null);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();
    switch (c2.stars.items[0].bans[0]) {
        .incomp => {},
        else => return error.InvalidBanKind,
    }
}

test "multiple bans on one star" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{sg.makePosConst("multi")};
    const bans = [_]Ban{
        .{ .ineq = .{ sg.makeVar("A"), sg.makePosConst("x") } },
        .{ .incomp = .{ sg.makeVar("B"), sg.makeVar("C") } },
        .{ .ineq = .{ sg.makePosConst("d"), sg.makeNegConst("e") } },
    };
    try c.addStar(.{ .rays = &rays, .bans = &bans, .mark = .action });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();
    try std.testing.expectEqual(@as(usize, 3), c2.stars.items[0].bans.len);
}

// ── Multi-star constellations ──

test "many stars round-trip" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const rays = [_]Ray{sg.makePosConst("r")};
        const mark: sg.Mark = if (i % 2 == 0) .state else .action;
        try c.addStar(.{ .rays = &rays, .mark = mark });
    }

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();
    try std.testing.expectEqual(@as(usize, 10), c2.stars.items.len);
    try std.testing.expectEqual(sg.Mark.state, c2.stars.items[0].mark);
    try std.testing.expectEqual(sg.Mark.action, c2.stars.items[1].mark);
}

// ── TOFU envelope edge cases ──

test "TOFU with large seed and max index" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{sg.makePosConst("big")};
    try c.addStar(.{ .rays = &rays, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeTofu(&buf.writer, &c, .color_aware, std.math.maxInt(u64), 65535, "#FFFFFF");

    const parsed = try parseTofuSexp(buf.written(), alloc);
    var c2 = parsed.constellation;
    defer c2.deinit();

    try std.testing.expectEqual(std.math.maxInt(u64), parsed.seed);
    try std.testing.expectEqual(@as(u16, 65535), parsed.index);
    try std.testing.expect(std.mem.eql(u8, "#FFFFFF", parsed.hex));
}

test "TOFU color-unaware strips polarities inside envelope" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{ sg.makePosConst("a"), sg.makeNegConst("b") };
    try c.addStar(.{ .rays = &rays, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeTofu(&buf.writer, &c, .color_unaware, 1, 1, "#000000");

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(func +") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(func -") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(func ~") != null);
}

// ── Idempotency: serialize → parse → serialize produces same bytes ──

test "double round-trip idempotency" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const rays = [_]Ray{ sg.makePosConst("hello"), sg.makeVar("X"), sg.makeNegConst("world") };
    const bans = [_]Ban{.{ .ineq = .{ sg.makeVar("X"), sg.makePosConst("hello") } }};
    try c.addStar(.{ .rays = &rays, .bans = &bans, .mark = .state });
    try c.addStar(.{ .rays = &[_]Ray{sg.makeNegConst("reply")}, .mark = .action });

    // First round
    var buf1: std.Io.Writer.Allocating = .init(alloc);
    defer buf1.deinit();
    try serializeConstellation(&buf1.writer, &c, .color_aware);

    // Parse and re-serialize
    var c2 = try parseConstellationSexp(buf1.written(), alloc);
    defer c2.deinit();

    var buf2: std.Io.Writer.Allocating = .init(alloc);
    defer buf2.deinit();
    try serializeConstellation(&buf2.writer, &c2, .color_aware);

    try std.testing.expect(std.mem.eql(u8, buf1.written(), buf2.written()));
}

// ═══════════════════════════════════════════════════════════════════════
// Phase 3: adversarial parsing, nested funcs, integration
// ═══════════════════════════════════════════════════════════════════════

test "parse error: empty input" {
    const result = parseConstellationSexp("", std.testing.allocator);
    try std.testing.expectError(ParseError.UnexpectedEof, result);
}

test "parse error: missing closing paren" {
    const result = parseConstellationSexp("(constellation (star state (rays)", std.testing.allocator);
    try std.testing.expectError(ParseError.UnexpectedEof, result);
}

test "parse error: unknown keyword instead of constellation" {
    const result = parseConstellationSexp("(foobar)", std.testing.allocator);
    try std.testing.expectError(ParseError.UnexpectedToken, result);
}

test "parse error: invalid polarity character" {
    const result = parseConstellationSexp("(constellation (star state (rays (func ! bad))))", std.testing.allocator);
    try std.testing.expectError(ParseError.InvalidPolarity, result);
}

test "parse error: invalid mark" {
    const result = parseConstellationSexp("(constellation (star foobar (rays)))", std.testing.allocator);
    try std.testing.expectError(ParseError.InvalidMark, result);
}

test "parse error: invalid ban kind" {
    const result = parseConstellationSexp("(constellation (star state (rays) (bans (bogus (var X) (var Y)))))", std.testing.allocator);
    try std.testing.expectError(ParseError.InvalidBanKind, result);
}

test "func with children: serialize and parse round-trip" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    const inner_children = [_]Ray{sg.makePosConst("leaf")};
    const inner = sg.makeFunc(.pos, "g", &inner_children);
    const outer_children = [_]Ray{ inner, sg.makeVar("X") };
    const outer = sg.makeFunc(.neg, "f", &outer_children);
    const rays = [_]Ray{outer};
    try c.addStar(.{ .rays = &rays, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();

    try std.testing.expectEqual(@as(usize, 1), c2.stars.items.len);
    try std.testing.expectEqual(@as(usize, 1), c2.stars.items[0].rays.len);
    const parsed_ray = c2.stars.items[0].rays[0];
    switch (parsed_ray) {
        .func => |f| {
            try std.testing.expectEqualStrings("f", f.name);
            try std.testing.expectEqual(@as(usize, 2), f.children.len);
        },
        .variable => return error.TestUnexpectedResult,
    }
}

test "TOFU with seed=0: edge case" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();
    const rays = [_]Ray{sg.makePosConst("zero")};
    try c.addStar(.{ .rays = &rays, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeTofu(&buf.writer, &c, .color_aware, 0, 0, "#000000");

    const parsed = try parseTofuSexp(buf.written(), alloc);
    var c2 = parsed.constellation;
    defer c2.deinit();
    try std.testing.expectEqual(@as(u64, 0), parsed.seed);
    try std.testing.expectEqual(@as(u16, 0), parsed.index);
    try std.testing.expectEqualStrings("#000000", parsed.hex);
}

test "cross-module: serialize → parse → fire integration" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();
    const s_rays = [_]Ray{sg.makePosConst("ping")};
    const a_rays = [_]Ray{sg.makeNegConst("ping")};
    try c.addStar(.{ .rays = &s_rays, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });

    // Serialize to sexp
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    // Parse back
    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();

    // Verify the parsed constellation can fire
    const result = try sg.fire(&c2, alloc);
    try std.testing.expect(result.fired);
    try std.testing.expectEqual(@as(usize, 0), result.state_idx.?);
    try std.testing.expectEqual(@as(usize, 1), result.action_idx.?);
}

test "cross-module: serialize → parse → exec round-trip" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();
    const s1 = [_]Ray{sg.makePosConst("msg")};
    const a1 = [_]Ray{sg.makeNegConst("msg")};
    try c.addStar(.{ .rays = &s1, .mark = .state });
    try c.addStar(.{ .rays = &a1, .mark = .action });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();

    const result = try sg.exec(&c2, alloc, 10);
    try std.testing.expectEqual(@as(usize, 10), result.steps);
    try std.testing.expect(!result.fixpoint);
}

test "many stars: state and action counts preserved through sexp" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();
    const r1 = [_]Ray{sg.makePosConst("a")};
    const r2 = [_]Ray{sg.makeNegConst("b")};
    const r3 = [_]Ray{sg.makeNullConst("c")};
    try c.addStar(.{ .rays = &r1, .mark = .state });
    try c.addStar(.{ .rays = &r2, .mark = .action });
    try c.addStar(.{ .rays = &r3, .mark = .state });
    try c.addStar(.{ .rays = &r1, .mark = .action });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();

    try std.testing.expectEqual(c.stateCount(), c2.stateCount());
    try std.testing.expectEqual(c.actionCount(), c2.actionCount());
    try std.testing.expectEqual(c.tritSum(), c2.tritSum());
}

// ═══════════════════════════════════════════════════════════════════════
// Phase 4: deeper round-trips, Ban serialization, color modes, stress
// ═══════════════════════════════════════════════════════════════════════

test "color-unaware mode: polarities stripped to ~" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();
    const rays = [_]Ray{ sg.makePosConst("a"), sg.makeNegConst("b") };
    try c.addStar(.{ .rays = &rays, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_unaware);

    // Should contain ~ instead of + or -
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(func + ") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(func - ") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(func ~ ") != null);
}

test "variable with index: serialize and parse round-trip" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();
    const v = Ray{ .variable = .{ .name = "X", .index = 42 } };
    const rays = [_]Ray{v};
    try c.addStar(.{ .rays = &rays, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    // Should contain "42"
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "42") != null);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();
    try std.testing.expectEqual(@as(usize, 1), c2.stars.items.len);
    const parsed = c2.stars.items[0].rays[0];
    switch (parsed) {
        .variable => |vid| {
            try std.testing.expectEqualStrings("X", vid.name);
            try std.testing.expectEqual(@as(?u16, 42), vid.index);
        },
        .func => return error.TestUnexpectedResult,
    }
}

test "star with bans: ineq round-trip" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();
    const bans = [_]sg.Ban{.{ .ineq = .{ sg.makeVar("X"), sg.makePosConst("a") } }};
    const rays = [_]Ray{sg.makePosConst("hello")};
    try c.addStar(.{ .rays = &rays, .bans = &bans, .mark = .action });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(ineq") != null);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();
    try std.testing.expectEqual(@as(usize, 1), c2.stars.items[0].bans.len);
}

test "star with bans: incomp round-trip" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();
    const bans = [_]sg.Ban{.{ .incomp = .{ sg.makePosConst("a"), sg.makePosConst("b") } }};
    const rays = [_]Ray{sg.makeNegConst("x")};
    try c.addStar(.{ .rays = &rays, .bans = &bans, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "(incomp") != null);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();
    try std.testing.expectEqual(@as(usize, 1), c2.stars.items[0].bans.len);
}

test "TOFU: full round-trip with non-trivial constellation" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();
    const r1 = [_]Ray{ sg.makePosConst("msg"), sg.makeVar("X") };
    const r2 = [_]Ray{sg.makeNegConst("ack")};
    try c.addStar(.{ .rays = &r1, .mark = .state });
    try c.addStar(.{ .rays = &r2, .mark = .action });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeTofu(&buf.writer, &c, .color_aware, 12345, 7, "#A855F7");

    const parsed = try parseTofuSexp(buf.written(), alloc);
    var c2 = parsed.constellation;
    defer c2.deinit();
    try std.testing.expectEqual(@as(u64, 12345), parsed.seed);
    try std.testing.expectEqual(@as(u16, 7), parsed.index);
    try std.testing.expectEqualStrings("#A855F7", parsed.hex);
    try std.testing.expectEqual(@as(usize, 2), c2.stars.items.len);
    try std.testing.expectEqual(c.stateCount(), c2.stateCount());
    try std.testing.expectEqual(c.actionCount(), c2.actionCount());
}

test "color-unaware mode: parse back gives all null_ polarity" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();
    const rays = [_]Ray{sg.makePosConst("a")};
    try c.addStar(.{ .rays = &rays, .mark = .state });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_unaware);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();
    const parsed_ray = c2.stars.items[0].rays[0];
    switch (parsed_ray) {
        .func => |f| try std.testing.expectEqual(sg.Polarity.null_, f.polarity),
        .variable => return error.TestUnexpectedResult,
    }
}

test "stress: 20-star constellation round-trip preserves structure" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();

    // Build 20 stars alternating state/action with varying content
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const mark: sg.Mark = if (i % 2 == 0) .state else .action;
        const pol: sg.Polarity = if (i % 3 == 0) .pos else if (i % 3 == 1) .neg else .null_;
        const r = [_]Ray{sg.makeConst(pol, "sym")};
        try c.addStar(.{ .rays = &r, .mark = mark });
    }

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();
    try std.testing.expectEqual(@as(usize, 20), c2.stars.items.len);
    try std.testing.expectEqual(c.stateCount(), c2.stateCount());
    try std.testing.expectEqual(c.actionCount(), c2.actionCount());
    try std.testing.expectEqual(c.tritSum(), c2.tritSum());
}

test "cross-module: serialize→parse→findFusionCandidates" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();
    const s1 = [_]Ray{sg.makePosConst("x")};
    const s2 = [_]Ray{sg.makePosConst("y")};
    const a1 = [_]Ray{sg.makeNegConst("x")};
    try c.addStar(.{ .rays = &s1, .mark = .state });
    try c.addStar(.{ .rays = &s2, .mark = .state });
    try c.addStar(.{ .rays = &a1, .mark = .action });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeConstellation(&buf.writer, &c, .color_aware);

    var c2 = try parseConstellationSexp(buf.written(), alloc);
    defer c2.deinit();

    var cands = try sg.findFusionCandidates(&c2, alloc);
    defer cands.deinit(alloc);
    // Only s1↔a1 should match (x↔x), not s2↔a1 (y↔x)
    try std.testing.expectEqual(@as(usize, 1), cands.items.len);
}

test "cross-module: TOFU serialize → parse → unify through parsed data" {
    const alloc = std.testing.allocator;
    var c = Constellation.init(alloc);
    defer c.deinit();
    const c1 = [_]Ray{sg.makeVar("X")};
    const s_rays = [_]Ray{sg.makeFunc(.pos, "f", &c1)};
    const a_c1 = [_]Ray{sg.makePosConst("hello")};
    const a_rays = [_]Ray{sg.makeFunc(.neg, "f", &a_c1)};
    try c.addStar(.{ .rays = &s_rays, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try serializeTofu(&buf.writer, &c, .color_aware, 999, 1, "#FF0000");

    const parsed = try parseTofuSexp(buf.written(), alloc);
    var c2 = parsed.constellation;
    defer c2.deinit();

    // The parsed constellation should fire (f(X) pos ↔ f(hello) neg)
    const result = try sg.fire(&c2, alloc);
    try std.testing.expect(result.fired);
}

// ── Cross-implementation test vectors (same strings OCaml produces) ──

test "cross-impl: annihilation" {
    const alloc = std.testing.allocator;
    const sexp = "(constellation (star action (rays (func + a))) (star state (rays (func - a))))";
    var c = try parseConstellationSexp(sexp, alloc);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 2), c.stars.items.len);
    try std.testing.expectEqual(sg.Mark.action, c.stars.items[0].mark);
    try std.testing.expectEqual(sg.Mark.state, c.stars.items[1].mark);
}

test "cross-impl: variable prop" {
    const alloc = std.testing.allocator;
    const sexp = "(constellation (star state (rays (func + f (var X)))) (star action (rays (func - f (func ~ hello)))))";
    var c = try parseConstellationSexp(sexp, alloc);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 2), c.stars.items.len);
    const ray0 = c.stars.items[0].rays[0];
    try std.testing.expectEqual(sg.Ray.func, std.meta.activeTag(ray0));
    try std.testing.expectEqualStrings("f", ray0.func.name);
}

test "cross-impl: nested func" {
    const alloc = std.testing.allocator;
    const sexp = "(constellation (star state (rays (func ~ outer (func + inner (var Y 3))))))";
    var c = try parseConstellationSexp(sexp, alloc);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 1), c.stars.items.len);
    const outer = c.stars.items[0].rays[0];
    try std.testing.expectEqualStrings("outer", outer.func.name);
    const inner = outer.func.children[0];
    try std.testing.expectEqualStrings("inner", inner.func.name);
    const y = inner.func.children[0];
    try std.testing.expectEqual(sg.Ray.variable, std.meta.activeTag(y));
    try std.testing.expectEqualStrings("Y", y.variable.name);
    try std.testing.expectEqual(@as(?u16, 3), y.variable.index);
}

test "cross-impl: tofu envelope" {
    const alloc = std.testing.allocator;
    const sexp = "(tofu 42 1 #A855F7 (constellation (star state (rays (func ~ id)))))";
    const parsed = try parseTofuSexp(sexp, alloc);
    var c = parsed.constellation;
    defer c.deinit();
    try std.testing.expectEqual(@as(u64, 42), parsed.seed);
    try std.testing.expectEqual(@as(u64, 1), parsed.index);
    try std.testing.expectEqualStrings("#A855F7", parsed.hex);
    try std.testing.expectEqual(@as(usize, 1), c.stars.items.len);
}

test "cross-impl: bans" {
    const alloc = std.testing.allocator;
    const sexp = "(constellation (star state (rays (func + a) (func - b)) (bans (ineq (func + a) (func - b)))))";
    var c = try parseConstellationSexp(sexp, alloc);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 1), c.stars.items.len);
    try std.testing.expectEqual(@as(usize, 2), c.stars.items[0].rays.len);
    try std.testing.expectEqual(@as(usize, 1), c.stars.items[0].bans.len);
    try std.testing.expectEqual(sg.Ban.ineq, std.meta.activeTag(c.stars.items[0].bans[0]));
}

test "cross-impl: roundtrip idempotent" {
    const alloc = std.testing.allocator;
    const vectors = [_][]const u8{
        "(constellation)",
        "(constellation (star state (rays (func ~ a))))",
        "(constellation (star action (rays (func + x) (func - y))) (star state (rays (var Z))))",
    };
    for (vectors) |sexp| {
        var c = try parseConstellationSexp(sexp, alloc);
        defer c.deinit();
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();
        try serializeConstellation(&buf.writer, &c, .color_aware);
        var c2 = try parseConstellationSexp(buf.written(), alloc);
        defer c2.deinit();
        var buf2: std.Io.Writer.Allocating = .init(alloc);
        defer buf2.deinit();
        try serializeConstellation(&buf2.writer, &c2, .color_aware);
        try std.testing.expectEqualStrings(buf.written(), buf2.written());
    }
}
