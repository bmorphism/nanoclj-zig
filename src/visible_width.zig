// OSC 8 hyperlink-aware string width.
//
// Mirrors joker v1.7.1 commit 964c013 (2026-04-25): the first Lisp/Scheme/
// Clojure runtime to compute print-table column widths after stripping OSC 8
// escape sequences. Joker's regex was:
//
//     #"\x1b\]8;[^\x07\x1b]*(\x07|\x1b\\)"
//
// Translated to a hand-written scanner here so we have no regex dependency.
// OSC 8 frame: `ESC ] 8 ; <params> ; <URI> ST <text> ESC ] 8 ; ; ST`
// where ST is BEL (0x07) or ESC \ (0x1B 0x5C).
//
// `visibleWidth` counts UTF-8 codepoints (one cell per rune); SGR/CSI colour
// sequences are intentionally NOT stripped here — that lives in `color_strip`.
// Compose the two when both kinds of escape may be present.

const std = @import("std");

/// Returns the visible width of `s` after stripping OSC 8 hyperlink frames.
///
/// Mirrors joker's regex `#"\x1b\]8;[^\x07\x1b]*(\x07|\x1b\\)"`: an OSC 8 frame
/// is consumed ONLY when a terminator (BEL or ESC\) is found before EOS. An
/// unterminated `ESC ] 8 ;` is treated as visible bytes — this is what joker
/// does (its regex simply doesn't match), and the cross-runtime corpus pins
/// this behavior.
pub fn visibleWidth(s: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        // OSC 8 opening: ESC ] 8 ;
        if (i + 3 < s.len and
            s[i] == 0x1B and s[i + 1] == ']' and
            s[i + 2] == '8' and s[i + 3] == ';')
        {
            // Probe for a terminator before committing to consume the frame.
            var j = i + 4;
            var consumed: ?usize = null;
            while (j < s.len) {
                if (s[j] == 0x07) {
                    consumed = j + 1;
                    break;
                }
                if (s[j] == 0x1B and j + 1 < s.len and s[j + 1] == '\\') {
                    consumed = j + 2;
                    break;
                }
                j += 1;
            }
            if (consumed) |end| {
                i = end;
                continue;
            }
            // Unterminated: fall through to count bytes one at a time.
        }
        // UTF-8: count one column per leading byte (continuation bytes 10xxxxxx skipped)
        if (s[i] & 0xC0 != 0x80) width += 1;
        i += 1;
    }
    return width;
}

/// Allocates a copy of `s` right-padded with ASCII spaces to `target` visible
/// columns. If the visible width already meets or exceeds `target`, returns a
/// plain dupe. Caller owns the returned slice.
pub fn padToVisibleWidth(allocator: std.mem.Allocator, s: []const u8, target: usize) ![]u8 {
    const w = visibleWidth(s);
    if (w >= target) return allocator.dupe(u8, s);
    const pad = target - w;
    var out = try allocator.alloc(u8, s.len + pad);
    @memcpy(out[0..s.len], s);
    @memset(out[s.len..], ' ');
    return out;
}

/// Convenience: build an OSC 8 hyperlink. Caller owns the returned slice.
/// Format: ESC ] 8 ; ; <uri> BEL <label> ESC ] 8 ; ; BEL
pub fn osc8Link(allocator: std.mem.Allocator, uri: []const u8, label: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "\x1b]8;;{s}\x07{s}\x1b]8;;\x07",
        .{ uri, label },
    );
}

// ---------- tests ----------

test "plain ASCII" {
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("hello"));
}

test "empty" {
    try std.testing.expectEqual(@as(usize, 0), visibleWidth(""));
}

test "OSC 8 with BEL terminator" {
    // ESC ] 8 ; ; URI BEL clickable ESC ] 8 ; ; BEL  -> visible width 9
    const s = "\x1b]8;;file:///tmp/foo\x07clickable\x1b]8;;\x07";
    try std.testing.expectEqual(@as(usize, 9), visibleWidth(s));
}

test "OSC 8 with ST terminator" {
    const s = "\x1b]8;;file:///x\x1b\\link\x1b]8;;\x1b\\";
    try std.testing.expectEqual(@as(usize, 4), visibleWidth(s));
}

test "OSC 8 with id parameter" {
    const s = "\x1b]8;id=link1;https://example.com\x07click\x1b]8;;\x07";
    try std.testing.expectEqual(@as(usize, 5), visibleWidth(s));
}

test "OSC 8 mixed with surrounding text" {
    // "before " (7) + "link" (4) + " after" (6) = 17
    const s = "before \x1b]8;;file:///x\x07link\x1b]8;;\x07 after";
    try std.testing.expectEqual(@as(usize, 17), visibleWidth(s));
}

test "UTF-8 multi-byte counts one cell per rune" {
    // "café" = 4 codepoints, "é" is 2 bytes
    try std.testing.expectEqual(@as(usize, 4), visibleWidth("café"));
}

test "padToVisibleWidth handles OSC 8" {
    const a = std.testing.allocator;
    const cell = "\x1b]8;;file:///x\x07link\x1b]8;;\x07";
    const padded = try padToVisibleWidth(a, cell, 10);
    defer a.free(padded);
    // visible width of cell = 4; padded to 10 = adds 6 spaces
    try std.testing.expectEqual(@as(usize, cell.len + 6), padded.len);
    try std.testing.expectEqual(@as(usize, 10), visibleWidth(padded));
    try std.testing.expectEqualSlices(u8, "      ", padded[cell.len..]);
}

test "padToVisibleWidth returns dupe when wider than target" {
    const a = std.testing.allocator;
    const padded = try padToVisibleWidth(a, "wider-than-3", 3);
    defer a.free(padded);
    try std.testing.expectEqualSlices(u8, "wider-than-3", padded);
}

test "osc8Link round-trip" {
    const a = std.testing.allocator;
    const link = try osc8Link(a, "file:///tmp/x", "click");
    defer a.free(link);
    try std.testing.expectEqual(@as(usize, 5), visibleWidth(link));
    try std.testing.expectEqualSlices(u8, "\x1b]8;;file:///tmp/x\x07click\x1b]8;;\x07", link);
}

test "unterminated OSC 8 counts bytes (joker parity)" {
    // No terminator — joker's regex doesn't match, so all 23 bytes are
    // counted as visible. The probe-before-consume scanner mirrors that.
    const s = "\x1b]8;;no-terminator-here";
    try std.testing.expectEqual(@as(usize, 23), visibleWidth(s));
}

// ---------- corpus-driven cross-runtime parity test ----------
// Diff-empty against joker's `visible-width` (commit 964c013).
// Corpus + oracle: tests/visible_width_cases.json + tests/visible_width_oracle.bb
//   - oracle uses joker's exact regex as the reference implementation
//   - this test asserts every case agrees byte-for-byte
//   - divergences are surfaced per-case so they can be triaged

const Case = struct {
    name: []const u8,
    input_hex: []const u8,
    expected: usize,
};

const Corpus = struct {
    cases: []Case,
};

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn hexDecode(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    var out = try allocator.alloc(u8, hex.len / 2);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = try hexNibble(hex[2 * i]);
        const lo = try hexNibble(hex[2 * i + 1]);
        out[i] = (hi << 4) | lo;
    }
    return out;
}

// libc-based file slurp: Zig 0.16.0 moved fs reads behind std.Io.Dir+Io;
// brainfloj.zig already uses fopen/fread, keep tests dependency-light.
// std.c only exposes fopen/fread/fclose (no fseek/ftell on macOS), so we
// chunk-read into a grow-by-doubling buffer.
fn slurp(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return error.Overflow;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;

    const file = std.c.fopen(@ptrCast(&pbuf), "r") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);

    var cap: usize = 4096;
    var len: usize = 0;
    var out = try allocator.alloc(u8, cap);
    errdefer allocator.free(out);
    while (true) {
        if (len == cap) {
            cap *= 2;
            out = try allocator.realloc(out, cap);
        }
        const got = std.c.fread(out.ptr + len, 1, cap - len, file);
        if (got == 0) break;
        len += got;
    }
    return try allocator.realloc(out, len);
}

test "corpus: diff-empty against joker oracle" {
    const a = std.testing.allocator;
    const corpus_json = slurp(a, "tests/visible_width_cases.json") catch |err| switch (err) {
        error.FileNotFound => {
            // run from a different cwd; skip rather than fail the suite
            std.debug.print("\n  (skipped: corpus file not found at cwd)\n", .{});
            return;
        },
        else => return err,
    };
    defer a.free(corpus_json);

    const parsed = try std.json.parseFromSlice(
        Corpus,
        a,
        corpus_json,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    var fails: usize = 0;
    for (parsed.value.cases) |c| {
        const bytes = try hexDecode(a, c.input_hex);
        defer a.free(bytes);
        const got = visibleWidth(bytes);
        if (got != c.expected) {
            std.debug.print(
                "\n  DIFF [{s}]: zig={d} oracle={d}",
                .{ c.name, got, c.expected },
            );
            fails += 1;
        }
    }
    if (fails > 0) {
        std.debug.print("\n  {d} corpus case(s) diverge from joker oracle\n", .{fails});
        return error.CorpusDiff;
    }
}

// ---------- 70-case adversarial corpus ----------
// Five semantics under test, each grounded in a real Clojure-family runtime:
//   expected_regex          joker / basilisp / glojure   (regex + codepoint)
//   expected_scanner        nanoclj-zig / lokke / jo_cp  (scanner + codepoint)
//   expected_byte           jank                          (regex + raw UTF-8 byte)
//   expected_jvm            clojure / bb / nbb / cherry / squint  (regex + UTF-16)
//   expected_byte_scanner   jo_clojure (byte mode)        (scanner + raw byte)
// 49/70 agree on all five. Distribution: 49 / 17 / 3 / 0 / 1 (n-distinct = 1..5).
// Case "Z: all-axes witness" produces FIVE distinct values across all profiles.

const AdvCase = struct {
    name: []const u8,
    input_hex: []const u8,
    expected_regex: usize,
    expected_scanner: usize,
    expected_byte: usize,
    expected_jvm: usize,
    expected_byte_scanner: usize,
    expected_grapheme: usize,
    expected_grapheme_scanner: usize,
};

const AdvCorpus = struct {
    cases: []AdvCase,
};

test "adversarial 82: scanner matches expected_scanner across A/B/C/D/E/G/H axes" {
    const a = std.testing.allocator;
    const corpus_json = slurp(a, "tests/visible_width_adversarial.json") catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("\n  (skipped: adversarial corpus not found at cwd)\n", .{});
            return;
        },
        else => return err,
    };
    defer a.free(corpus_json);

    const parsed = try std.json.parseFromSlice(
        AdvCorpus,
        a,
        corpus_json,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    var fails: usize = 0;
    var all7: usize = 0;
    var n5: usize = 0;
    var n7: usize = 0;
    for (parsed.value.cases) |c| {
        const bytes = try hexDecode(a, c.input_hex);
        defer a.free(bytes);
        const got = visibleWidth(bytes);
        if (got != c.expected_scanner) {
            std.debug.print(
                "\n  SCANNER FAIL [{s}]: zig={d} expected_scanner={d}",
                .{ c.name, got, c.expected_scanner },
            );
            fails += 1;
            continue;
        }
        var vals = [_]usize{
            c.expected_regex,            c.expected_scanner,      c.expected_byte,
            c.expected_jvm,              c.expected_byte_scanner, c.expected_grapheme,
            c.expected_grapheme_scanner,
        };
        std.mem.sort(usize, &vals, {}, comptime std.sort.asc(usize));
        var n: usize = 1;
        for (1..vals.len) |i| {
            if (vals[i] != vals[i - 1]) n += 1;
        }
        if (n == 1) all7 += 1;
        if (n == 5) n5 += 1;
        if (n == 7) n7 += 1;
    }
    try std.testing.expectEqual(@as(usize, 49), all7);
    try std.testing.expectEqual(@as(usize, 1), n5);
    try std.testing.expectEqual(@as(usize, 1), n7);
    if (fails > 0) return error.ScannerMismatch;
}

// ---------- Galois-rank-3 formal claim (corrected) ----------
// Original 77-case corpus admitted Galois rank 2 (basis {A,E}). K1-K5
// (variation selectors, BiDi overrides, NFC/NFD normalization) added
// 5 cases that falsify rank-2: no 2-basis distinguishes them all.
// Working 3-bases on the 82-case corpus: {A,E,G}, {C,D,G}, {C,E,G}.
// All require the grapheme axis G.
//
// This test asserts: for every (A, E, G) triple appearing in the corpus,
// the remaining profiles {B, C, D, H} are uniquely determined.
test "Galois rank 3: basis {A,E,G} determines all 7 profiles" {
    const a = std.testing.allocator;
    const corpus_json = slurp(a, "tests/visible_width_adversarial.json") catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer a.free(corpus_json);

    const parsed = try std.json.parseFromSlice(
        AdvCorpus,
        a,
        corpus_json,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const cases = parsed.value.cases;
    for (cases, 0..) |ci, i| {
        for (cases[i + 1 ..]) |cj| {
            if (ci.expected_regex == cj.expected_regex and
                ci.expected_byte_scanner == cj.expected_byte_scanner and
                ci.expected_grapheme == cj.expected_grapheme)
            {
                // (A, E, G) match → all 7 fields must match
                try std.testing.expectEqual(ci.expected_jvm, cj.expected_jvm);
                try std.testing.expectEqual(ci.expected_scanner, cj.expected_scanner);
                try std.testing.expectEqual(ci.expected_byte, cj.expected_byte);
                try std.testing.expectEqual(
                    ci.expected_grapheme_scanner,
                    cj.expected_grapheme_scanner,
                );
            }
        }
    }
}
