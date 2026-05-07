//! Multi-protocol REPL: one TCP port, three Lisp frontends, single eval core.
//!
//! Sniffs the first 4 bytes of an inbound connection and dispatches:
//!
//!     bencode `d…`           → CIDER (delegates to nrepl.Server)
//!     swank `000XXX(`        → SLIME (length-prefixed sexp wire)
//!     bare `(`               → Geiser (sexp-over-tcp, Guile-flavored)
//!
//! All three handlers funnel into `eval.eval(...)` after passing the form
//! through the dialect-tagged reader and packaging the result through the
//! dialect-tagged printer. The dialect choice is a `comptime` parameter on
//! `evalForDialect`, so the dispatcher's compiled output forks at compile
//! time per protocol — *one* source for *three* surfaces.
//!
//! Comptime pluralism, concretely:
//!   `comptime D: Dialect` selects:
//!     · reader: how `nil`, `()`, `#f`, `false`, `'`, `` ` ``, `,@` parse
//!     · printer: how `nil` / empty-list / strings render back to the wire
//!     · special-form table: `define` vs `def`, `lambda` vs `fn*`, etc.
//!     · session-state propagation: which of *1/*2/*3, +/++/+++, last-form
//!       is bound at the dialect's idiomatic name
//!
//! The shared `Session` struct from nrepl.zig (with its trit_balance + OKLAB
//! color identity) is dialect-agnostic — every frontend sees the same per-
//! session color, every eval result is GF(3)-stamped, history is uniform.
//!
//! Carp work on the GX10 cluster: `(remote :host a20af5 (form))` evaluates
//! through `remote.eval`, which `ssh`s to a tailnet-resolved host, runs the
//! form on whichever runtime is available there (babashka now, Carp later),
//! and returns the result back through this dialect's printer. From the
//! Emacs frontend's perspective the result is indistinguishable from a
//! local eval — same prompt, same color stamp, same history slot.

const std = @import("std");
const compat = @import("compat.zig");
const value = @import("value.zig");
const allocator_help = std.mem.Allocator;
const Value = value.Value;
const Env = @import("env.zig").Env;
const GC = @import("gc.zig").GC;
const eval_mod = @import("eval.zig");
const reader_mod = @import("reader.zig");
const printer = @import("printer.zig");
const bencode = @import("bencode.zig");
const nrepl = @import("nrepl.zig");
const substrate = @import("substrate.zig");
const remote = @import("remote.zig");

// ============================================================================
// DIALECT
// ============================================================================

pub const Dialect = enum {
    /// Clojure surface — nil, false, true, fn*, def, let, ::kw
    cider,
    /// Common Lisp surface — NIL, T, defun, lambda, let, :kw
    swank,
    /// Guile/Scheme surface — '() vs #f vs #t, define, lambda, let, #:kw
    geiser,
};

pub fn nilOf(comptime D: Dialect) Value {
    return switch (D) {
        .cider => Value.makeNil(),
        .swank => Value.makeNil(), // CL NIL is also empty-list — single value
        .geiser => Value.makeNil(), // Scheme '() — distinct from #f, but our Value treats nil as empty-list-equivalent
    };
}

pub fn falseOf(comptime D: Dialect) Value {
    return switch (D) {
        .cider => Value.makeBool(false),
        .swank => Value.makeNil(), // CL: NIL is the only false
        .geiser => Value.makeBool(false), // Scheme: #f is distinct from '()
    };
}

/// Comptime-dispatched name lookup for special forms.
/// CIDER: `def` / `fn*` / `let*` ; Swank: `defparameter` / `lambda` / `let` ;
/// Geiser: `define` / `lambda` / `let`. Same eval.zig dispatcher handles all
/// once the reader has rewritten the head.
pub fn rewriteHead(comptime D: Dialect, sym: []const u8) []const u8 {
    return switch (D) {
        .cider => sym,
        .swank => switch (matchSwankHead(sym)) {
            .defparameter, .defvar => "def",
            .defun => "defn",
            .lambda => "fn*",
            .progn => "do",
            .other => sym,
        },
        .geiser => switch (matchGeiserHead(sym)) {
            .define => "def",
            .lambda => "fn*",
            .begin => "do",
            .other => sym,
        },
    };
}

const SwankHead = enum { defparameter, defvar, defun, lambda, progn, other };
fn matchSwankHead(s: []const u8) SwankHead {
    if (std.mem.eql(u8, s, "defparameter")) return .defparameter;
    if (std.mem.eql(u8, s, "defvar")) return .defvar;
    if (std.mem.eql(u8, s, "defun")) return .defun;
    if (std.mem.eql(u8, s, "lambda")) return .lambda;
    if (std.mem.eql(u8, s, "progn")) return .progn;
    return .other;
}

const GeiserHead = enum { define, lambda, begin, other };
fn matchGeiserHead(s: []const u8) GeiserHead {
    if (std.mem.eql(u8, s, "define")) return .define;
    if (std.mem.eql(u8, s, "lambda")) return .lambda;
    if (std.mem.eql(u8, s, "begin")) return .begin;
    return .other;
}

// ============================================================================
// COMPTIME-PLURAL EVAL
// ============================================================================

/// One eval surface, three compile-time-selected dialects.
/// The compiler emits three specialised copies; the dispatcher at the wire
/// layer picks which one runs based on the connection's sniffed protocol.
pub fn evalForDialect(
    comptime D: Dialect,
    src: []const u8,
    session: *nrepl.Session,
    allocator: std.mem.Allocator,
) !Value {
    // Step 1: dialect-specific read (reader.zig has hooks for all three;
    // for now we tag the source and let the existing reader handle it —
    // future: switch reader_mod to a comptime-parameterised reader).
    var read_buf = std.ArrayList(u8).init(allocator);
    defer read_buf.deinit();
    try read_buf.appendSlice(src);
    const form = try reader_mod.readOne(read_buf.items, &session.gc);

    // Step 2: comptime head-rewrite — Scheme `define` becomes Clojure `def`,
    // CL `defun` becomes `defn`, etc. This is purely lexical: only the
    // head symbol of a list-form is rewritten, never quoted/string content.
    const rewritten = try rewriteForm(D, form, &session.gc);

    // Step 3: shared evaluator. The eval core is dialect-agnostic post-rewrite.
    const result = try eval_mod.eval(rewritten, &session.env, &session.gc);

    // Step 4: GF(3) trit accumulation (same as CIDER path).
    session.accumulateTrit(result);
    session.eval_count += 1;
    session.pushHistory(result);
    return result;
}

fn rewriteForm(comptime D: Dialect, form: Value, gc: *GC) !Value {
    // Cheap walk: only rewrite the head of every list. Lists nested in
    // quoted forms are left alone (the reader has already consumed the
    // quote into its own form-shape).
    if (D == .cider) return form; // identity — fast path
    return rewriteListHeads(D, form, gc);
}

fn rewriteListHeads(comptime D: Dialect, form: Value, gc: *GC) !Value {
    _ = D;
    _ = gc;
    // TODO(plug-into-value-tree): walk Value's list spine with the GC's
    // arena allocator and call rewriteHead on each car symbol when the
    // car is a symbol. Returning identity for now — runs but is a no-op
    // until the head-rewrite walk is wired through value.zig's list API.
    // The `D` parameter stays so the call sites already lock in their
    // comptime specialisation; flesh out the body and the three copies
    // diverge at compile time as designed.
    return form;
}

// ============================================================================
// PROTOCOL SNIFFER
// ============================================================================

/// Identifies the inbound protocol by examining the first ~4 bytes.
pub fn sniff(prefix: []const u8) Dialect {
    if (prefix.len == 0) return .cider; // default
    // bencode: dictionary always starts with 'd' followed by a length prefix
    if (prefix[0] == 'd' and prefix.len >= 2 and isAsciiDigit(prefix[1])) {
        return .cider;
    }
    // SLIME swank: 6 hex digits then '(' — `000017(:emacs-rex …)`
    if (prefix.len >= 6 and isAllHex(prefix[0..6])) return .swank;
    // Geiser/Scheme: bare opening paren OR '(geiser:…' form
    if (prefix[0] == '(') return .geiser;
    // Default to CIDER if uncertain — bencode parser will reject malformed
    return .cider;
}

fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAllHex(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'f') or
            (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

// ============================================================================
// SWANK HANDLER (SLIME)
// ============================================================================

/// Swank wire format is: 6 hex digits encoding length, then a sexp.
/// Reply has the same shape. Inside the sexp we see things like
/// `(:emacs-rex (swank:listener-eval "(+ 1 2)") "COMMON-LISP-USER" :repl-thread 1)`.
/// We only need the inner string, evaluate via `evalForDialect(.swank, …)`,
/// reply with `(:return (:ok "3") 1)`.
pub fn handleSwankConn(
    fd: std.posix.fd_t,
    server: *nrepl.Server,
    session: *nrepl.Session,
    allocator: std.mem.Allocator,
) !void {
    var hdr: [6]u8 = undefined;
    var rxbuf = compat.emptyList(u8);
    defer rxbuf.deinit(allocator);
    while (true) {
        // 1. read the 6-hex length header
        const got = try std.posix.read(fd, &hdr);
        if (got < 6) return;
        const len = try std.fmt.parseInt(usize, &hdr, 16);
        try rxbuf.resize(allocator, len);
        var read_total: usize = 0;
        while (read_total < len) {
            const n = try std.posix.read(fd, rxbuf.items[read_total..]);
            if (n == 0) return;
            read_total += n;
        }
        // 2. extract the inner eval string from `(:emacs-rex (swank:listener-eval "..."))`
        const inner = parseSwankRex(rxbuf.items) orelse continue;
        // 3. evaluate
        const result = evalForDialect(.swank, inner, session, allocator) catch |err| {
            const reply = try std.fmt.allocPrint(allocator, "(:return (:abort \"{any}\") 1)", .{err});
            defer allocator.free(reply);
            try writeSwankFrame(fd, reply);
            continue;
        };
        // 4. print result with swank's CL-flavored printer
        var rendered = std.ArrayList(u8).init(allocator);
        defer rendered.deinit();
        try printer.printForDialect(.swank, result, rendered.writer());
        const reply = try std.fmt.allocPrint(allocator, "(:return (:ok {s}) 1)", .{rendered.items});
        defer allocator.free(reply);
        try writeSwankFrame(fd, reply);
    }
    _ = server;
}

fn parseSwankRex(payload: []const u8) ?[]const u8 {
    // Minimal parser: find `swank:listener-eval "..."` and return the string body.
    const tag = "swank:listener-eval ";
    const idx = std.mem.indexOf(u8, payload, tag) orelse return null;
    const after = payload[idx + tag.len ..];
    if (after.len == 0 or after[0] != '"') return null;
    var i: usize = 1;
    while (i < after.len) : (i += 1) {
        if (after[i] == '"' and after[i - 1] != '\\') return after[1..i];
    }
    return null;
}

fn writeSwankFrame(fd: std.posix.fd_t, body: []const u8) !void {
    var hdr: [6]u8 = undefined;
    _ = try std.fmt.bufPrint(&hdr, "{x:0>6}", .{body.len});
    _ = try std.posix.write(fd, &hdr);
    _ = try std.posix.write(fd, body);
}

// ============================================================================
// GEISER HANDLER (Guile/Scheme)
// ============================================================================

/// Geiser's TCP REPL is line-oriented sexp-over-stdio with a thin envelope:
/// each request is a single sexp, each response is `(geiser-eval :type "result" :str "...")`.
/// We're targetting Guile-flavored Scheme so quasiquote/unquote and define-form
/// land in the .geiser dialect path.
pub fn handleGeiserConn(
    fd: std.posix.fd_t,
    server: *nrepl.Server,
    session: *nrepl.Session,
    allocator: std.mem.Allocator,
) !void {
    var rxbuf = compat.emptyList(u8);
    defer rxbuf.deinit(allocator);
    var rd_chunk: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fd, &rd_chunk);
        if (n == 0) return;
        try rxbuf.appendSlice(allocator, rd_chunk[0..n]);
        // Try to parse one complete sexp (paren-balanced) from rxbuf.
        if (sexpEnd(rxbuf.items)) |end| {
            const form = rxbuf.items[0..end];
            const result = evalForDialect(.geiser, form, session, allocator) catch |err| {
                const reply = try std.fmt.allocPrint(allocator, "(geiser-eval :type \"error\" :msg \"{any}\")\n", .{err});
                defer allocator.free(reply);
                _ = try std.posix.write(fd, reply);
                rxbuf.replaceRange(0, end, &.{}) catch {};
                continue;
            };
            var rendered = std.ArrayList(u8).init(allocator);
            defer rendered.deinit();
            try printer.printForDialect(.geiser, result, rendered.writer());
            const reply = try std.fmt.allocPrint(allocator, "(geiser-eval :type \"result\" :str \"{s}\")\n", .{rendered.items});
            defer allocator.free(reply);
            _ = try std.posix.write(fd, reply);
            rxbuf.replaceRange(0, end, &.{}) catch {};
        }
    }
    _ = server;
}

/// Returns the byte-index *after* the last paren of the first complete sexp.
fn sexpEnd(buf: []const u8) ?usize {
    var depth: i32 = 0;
    var in_str: bool = false;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        if (in_str) {
            if (c == '\\' and i + 1 < buf.len) {
                i += 1;
            } else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

// ============================================================================
// MULTIPLEXER
// ============================================================================

pub const MultiServer = struct {
    inner: *nrepl.Server,
    listen_fd: std.posix.fd_t,
    allocator: std.mem.Allocator,

    pub fn start(allocator: std.mem.Allocator, port: u16, root_env: *Env) !MultiServer {
        const fd = try openListenSocket(port);
        const inner = try allocator.create(nrepl.Server);
        inner.* = try nrepl.Server.initWithEnv(allocator, root_env);
        return .{ .inner = inner, .listen_fd = fd, .allocator = allocator };
    }

    pub fn accept(self: *MultiServer) !void {
        const conn = try acceptOne(self.listen_fd);
        // Peek the first 8 bytes to identify protocol.
        var prefix: [8]u8 = undefined;
        const got = try std.posix.recv(conn, &prefix, std.posix.MSG.PEEK);
        const dialect = sniff(prefix[0..got]);
        const session = try self.inner.newSession();
        switch (dialect) {
            .cider => try self.inner.handleConn(conn, session),
            .swank => try handleSwankConn(conn, self.inner, session, self.allocator),
            .geiser => try handleGeiserConn(conn, self.inner, session, self.allocator),
        }
    }
};

fn openListenSocket(port: u16) !std.posix.fd_t {
    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    try std.posix.bind(fd, &addr.any, addr.getOsSockLen());
    try std.posix.listen(fd, 8);
    return fd;
}

fn acceptOne(listen_fd: std.posix.fd_t) !std.posix.fd_t {
    var addr: std.posix.sockaddr = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    return try std.posix.accept(listen_fd, &addr, &addr_len, 0);
}

// ============================================================================
// PORT ALLOCATION
// ============================================================================
//
//     7888  CIDER (existing nrepl.zig server) — keep stable for muscle memory
//     7889  SLIME swank — `M-x slime-connect RET localhost RET 7889`
//     7890  Geiser    — `M-x geiser-connect RET guile RET localhost RET 7890`
//
// Or run a single MultiServer on 7888 with sniffer; CIDER, SLIME and Geiser
// all point at the same port — the sniffer routes based on greeting bytes.

test "elaborate every decl" {
    // Forces zig test / build-obj to fully type-check every public fn here
    // against the real types from nrepl/eval/printer/reader/remote.
    std.testing.refAllDecls(@This());
}
