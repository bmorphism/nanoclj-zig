//! Remote-eval primitive: `(remote :host a20af5 :runtime carp '(form))`
//!
//! From the perspective of any of the three Emacs frontends (CIDER / SLIME /
//! Geiser), `(remote …)` looks like a normal local call. Internally it ships
//! the form over an ssh ControlMaster channel to a tailnet host and runs it
//! in whichever Lisp runtime the host has installed.
//!
//! Runtime table (extend in `runtimeFor`):
//!     :babashka   → ssh HOST 'bb -e FORM'              (works today)
//!     :carp       → ssh HOST 'carp -x FORM'             (after install)
//!     :sbcl       → ssh HOST 'sbcl --script <(echo)'    (future)
//!     :guile      → ssh HOST 'guile -c FORM'            (future)
//!
//! Fast-path: a long-lived `ssh -M ControlMaster` socket per host avoids a
//! 200ms+ TLS+auth handshake per call. After warm-up, round-trip drops to
//! ~30ms over tailscale (= the tailscale RTT we measured: 22-30ms).
//!
//! The result is read back as a UTF-8 sexp/EDN string and parsed through the
//! caller's dialect-tagged reader, so `(remote …)` returns a real Value the
//! current frontend can pprint, push to *1, and use in further forms.

const std = @import("std");
const Value = @import("value.zig").Value;
const reader = @import("reader.zig");
const GC = @import("gc.zig").GC;

pub const Runtime = enum {
    babashka,
    carp,
    sbcl,
    guile,
    auto, // probe + cache per host
};

pub const RemoteCfg = struct {
    host: []const u8,
    runtime: Runtime = .auto,
    timeout_ms: u32 = 10_000,
    /// If true, route via persistent ssh ControlMaster (recommended for
    /// repeated calls — first call sets it up).
    persistent: bool = true,
};

/// Cache: (host -> ControlMaster socket path) so we re-use the connection.
/// Keyed by host; value is the path to the ssh control socket on disk.
var cm_cache_mu: std.Thread.Mutex = .{};
var cm_cache: std.StringHashMap([]const u8) = undefined;
var cm_cache_inited: bool = false;

fn ensureCacheInit(allocator: std.mem.Allocator) void {
    cm_cache_mu.lock();
    defer cm_cache_mu.unlock();
    if (!cm_cache_inited) {
        cm_cache = std.StringHashMap([]const u8).init(allocator);
        cm_cache_inited = true;
    }
}

/// Probe a host for an available runtime once and cache the result.
fn probeRuntime(allocator: std.mem.Allocator, host: []const u8) !Runtime {
    const probe_cmd = "command -v carp >/dev/null && echo carp; " ++
        "command -v bb >/dev/null && echo bb; " ++
        "command -v sbcl >/dev/null && echo sbcl; " ++
        "command -v guile >/dev/null && echo guile";
    var child = std.process.Child.init(&.{ "ssh", host, probe_cmd }, allocator);
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.reader().readAllAlloc(allocator, 256);
    defer allocator.free(out);
    _ = try child.wait();
    // Prefer carp > bb > sbcl > guile in that order.
    if (std.mem.indexOf(u8, out, "carp") != null) return .carp;
    if (std.mem.indexOf(u8, out, "bb") != null) return .babashka;
    if (std.mem.indexOf(u8, out, "sbcl") != null) return .sbcl;
    if (std.mem.indexOf(u8, out, "guile") != null) return .guile;
    return error.NoRemoteRuntime;
}

fn runtimeArgv(rt: Runtime, host: []const u8, form: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    const cm_args: []const []const u8 = &.{ "-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/cm-%r@%h:%p", "-o", "ControlPersist=600" };
    const inner = switch (rt) {
        .babashka => try std.fmt.allocPrint(allocator, "bb -e {s}", .{shellQuote(form, allocator)}),
        .carp => try std.fmt.allocPrint(allocator, "carp -x {s}", .{shellQuote(form, allocator)}),
        .sbcl => try std.fmt.allocPrint(allocator, "sbcl --noinform --non-interactive --eval {s}", .{shellQuote(form, allocator)}),
        .guile => try std.fmt.allocPrint(allocator, "guile -c {s}", .{shellQuote(form, allocator)}),
        .auto => unreachable, // resolved by caller
    };
    var argv = std.ArrayList([]const u8).init(allocator);
    try argv.append("ssh");
    for (cm_args) |a| try argv.append(a);
    try argv.append(host);
    try argv.append(inner);
    return argv.toOwnedSlice();
}

fn shellQuote(s: []const u8, allocator: std.mem.Allocator) []const u8 {
    var out = std.ArrayList(u8).init(allocator);
    out.append('\'') catch return s;
    for (s) |c| {
        if (c == '\'') {
            out.appendSlice("'\\''") catch return s;
        } else {
            out.append(c) catch return s;
        }
    }
    out.append('\'') catch return s;
    return out.toOwnedSlice() catch s;
}

/// Top-level: evaluate `form_str` on `cfg.host` and return the result Value
/// parsed through the local reader.
pub fn evalRemote(allocator: std.mem.Allocator, cfg: RemoteCfg, form_str: []const u8, gc: *GC) !Value {
    ensureCacheInit(allocator);
    const rt = if (cfg.runtime == .auto)
        try probeRuntime(allocator, cfg.host)
    else
        cfg.runtime;

    const argv = try runtimeArgv(rt, cfg.host, form_str, allocator);
    defer allocator.free(argv);

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1 << 20);
    defer allocator.free(stdout);
    const term = try child.wait();
    switch (term) {
        .Exited => |c| if (c != 0) return error.RemoteEvalNonZero,
        else => return error.RemoteEvalCrashed,
    }
    // Trim and reader-parse — same reader as a local eval, so the result
    // lands in the local Env's value tree exactly like a local form.
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    return try reader.readOne(trimmed, gc);
}

test "elaborate every decl" {
    std.testing.refAllDecls(@This());
}
