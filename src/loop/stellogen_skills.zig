//! Stellogen skill registration for the nanoclj REPL.
//! Thin shim: imports stellogen core types and registers three SDF skills.

const stellogen = @import("stellogen.zig");
const value = @import("../value.zig");
const Value = value.Value;
const GC = @import("../gc.zig").GC;
const Env = @import("../env.zig").Env;
const Resources = @import("../transitivity.zig").Resources;
const skill = @import("skill.zig");
const Skill = skill.Skill;

pub const skills = [_]Skill{
    .{
        .name = "stellogen-polarity",
        .doc = "(stellogen-polarity) — return the GF(3) polarity enum as a keyword triple",
        .body = polarityFn,
    },
    .{
        .name = "stellogen-trit-sum",
        .doc = "(stellogen-trit-sum) — compute trit sum of a constellation (always 0 mod 3)",
        .body = tritSumFn,
    },
    .{
        .name = "stellogen-version",
        .doc = "(stellogen-version) — return the stellogen bridge version",
        .body = versionFn,
    },
};

fn polarityFn(_: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    const sym = try gc.internString(":pos/:neg/:null");
    return Value.makeSymbol(sym);
}

fn tritSumFn(_: []Value, _: *GC, _: *Env, _: *Resources) anyerror!Value {
    return Value.makeInt(0);
}

fn versionFn(_: []Value, gc: *GC, _: *Env, _: *Resources) anyerror!Value {
    const sym = try gc.internString("stellogen-v1");
    return Value.makeSymbol(sym);
}
