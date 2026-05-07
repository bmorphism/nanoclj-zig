//! Stellogen — polarity-driven constellation resolution for the loop cycle.
//!
//! Mirrors stellogen-upstream's OCaml types (constellation.ml, expression.ml)
//! as Zig-native structures:
//!
//!   Polarity  : Pos (+1) | Neg (-1) | Null (0)   — GF(3) charges
//!   Ray       : Var(name) | Func(polarity, name, children)
//!   Star      : { rays: []Ray, mark: State|Action }
//!   Constellation : []Star
//!
//! Resolution engine: compatible rays (same name, Pos↔Neg) unify via
//! Robinson's algorithm; the resulting substitution is applied to the
//! entire constellation. Iterate until fixpoint.
//!
//! Bridge to inet.zig: Polarity.trit() matches CellKind trit charges
//! (gamma=+1, delta=-1, epsilon=0).
//!
//! Registered as Skills in the SDF registry so the nanoclj REPL can
//! invoke resolution directly: (stellogen-fire), (stellogen-exec).

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// POLARITY — the GF(3) charge on every symbol
// ═══════════════════════════════════════════════════════════════════════

pub const Polarity = enum(i8) {
    pos = 1,
    neg = -1,
    null_ = 0,

    pub fn trit(self: Polarity) i8 {
        return @intFromEnum(self);
    }

    /// Pos↔Neg interact; Null↔Null interact; nothing else does.
    pub fn compatible(a: Polarity, b: Polarity) bool {
        return switch (a) {
            .pos => b == .neg,
            .neg => b == .pos,
            .null_ => b == .null_,
        };
    }

    pub fn fromChar(c: u8) Polarity {
        return switch (c) {
            '+' => .pos,
            '-' => .neg,
            else => .null_,
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════
// RAY — polarized first-order term (tree)
// ═══════════════════════════════════════════════════════════════════════

pub const Ray = union(enum) {
    /// Variable: unifies with anything.
    variable: VarId,
    /// Function symbol: polarity + name + children (0-arity = constant).
    func: FuncNode,

    pub const VarId = struct {
        name: []const u8,
        index: ?u16 = null,

        pub fn eql(a: VarId, b: VarId) bool {
            if (a.index != b.index) return false;
            return std.mem.eql(u8, a.name, b.name);
        }
    };

    pub const FuncNode = struct {
        polarity: Polarity,
        name: []const u8,
        children: []const Ray,
    };

    pub fn isVar(self: Ray) bool {
        return self == .variable;
    }

    pub fn eql(a: Ray, b: Ray) bool {
        switch (a) {
            .variable => |va| switch (b) {
                .variable => |vb| return va.eql(vb),
                .func => return false,
            },
            .func => |fa| switch (b) {
                .variable => return false,
                .func => |fb| {
                    if (fa.polarity != fb.polarity) return false;
                    if (!std.mem.eql(u8, fa.name, fb.name)) return false;
                    if (fa.children.len != fb.children.len) return false;
                    for (fa.children, fb.children) |ca, cb| {
                        if (!ca.eql(cb)) return false;
                    }
                    return true;
                },
            },
        }
    }

    /// Two rays are compatible iff they are both funcs, same name,
    /// opposite polarity, and same arity.
    pub fn compatibleWith(a: Ray, b: Ray) bool {
        const fa = switch (a) {
            .func => |f| f,
            .variable => return false,
        };
        const fb = switch (b) {
            .func => |f| f,
            .variable => return false,
        };
        return std.mem.eql(u8, fa.name, fb.name) and
            Polarity.compatible(fa.polarity, fb.polarity) and
            fa.children.len == fb.children.len;
    }
};

// ═══════════════════════════════════════════════════════════════════════
// SUBSTITUTION — variable→ray bindings from unification
// ═══════════════════════════════════════════════════════════════════════

pub const Binding = struct {
    var_id: Ray.VarId,
    term: Ray,
};

pub const Substitution = struct {
    bindings: std.ArrayListUnmanaged(Binding),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Substitution {
        return .{
            .bindings = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Substitution) void {
        self.bindings.deinit(self.allocator);
    }

    pub fn bind(self: *Substitution, v: Ray.VarId, t: Ray) !void {
        try self.bindings.append(self.allocator, .{ .var_id = v, .term = t });
    }

    pub fn lookup(self: *const Substitution, v: Ray.VarId) ?Ray {
        for (self.bindings.items) |b| {
            if (b.var_id.eql(v)) return b.term;
        }
        return null;
    }

    /// Apply substitution to a ray (walk). Non-allocating fast path when
    /// no child changes; allocates via the Substitution's own allocator
    /// when Func children are rewritten (deep penetration).
    pub fn apply(self: *const Substitution, ray: Ray) Ray {
        switch (ray) {
            .variable => |v| {
                if (self.lookup(v)) |bound| return self.apply(bound);
                return ray;
            },
            .func => |f| {
                // Fast path: check if any child would change.
                var changed = false;
                for (f.children) |c| {
                    const applied = self.apply(c);
                    if (!applied.eql(c)) {
                        changed = true;
                        break;
                    }
                }
                if (!changed) return ray;
                // Deep penetration: allocate new children with substitution applied.
                const new_children = self.allocator.alloc(Ray, f.children.len) catch return ray;
                for (f.children, 0..) |c, i| {
                    new_children[i] = self.apply(c);
                }
                return .{ .func = .{
                    .polarity = f.polarity,
                    .name = f.name,
                    .children = new_children,
                } };
            },
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════
// UNIFICATION — Robinson's algorithm on rays
// ═══════════════════════════════════════════════════════════════════════

pub const UnifyError = error{
    OccursCheck,
    Clash,
    OutOfMemory,
};

/// Unify two rays. Returns a substitution or an error.
pub fn unify(allocator: std.mem.Allocator, a: Ray, b: Ray) UnifyError!Substitution {
    var sub = Substitution.init(allocator);
    errdefer sub.deinit();
    try unifyRec(&sub, a, b);
    return sub;
}

fn unifyRec(sub: *Substitution, a: Ray, b: Ray) UnifyError!void {
    const wa = sub.apply(a);
    const wb = sub.apply(b);

    switch (wa) {
        .variable => |va| switch (wb) {
            .variable => |vb| {
                if (!va.eql(vb)) try sub.bind(va, wb);
            },
            .func => {
                if (occursIn(va, wb)) return error.OccursCheck;
                try sub.bind(va, wb);
            },
        },
        .func => |fa| switch (wb) {
            .variable => |vb| {
                if (occursIn(vb, wa)) return error.OccursCheck;
                try sub.bind(vb, wa);
            },
            .func => |fb| {
                if (!std.mem.eql(u8, fa.name, fb.name)) return error.Clash;
                if (fa.children.len != fb.children.len) return error.Clash;
                for (fa.children, fb.children) |ca, cb| {
                    try unifyRec(sub, ca, cb);
                }
            },
        },
    }
}

fn occursIn(v: Ray.VarId, ray: Ray) bool {
    switch (ray) {
        .variable => |vb| return v.eql(vb),
        .func => |f| {
            for (f.children) |c| {
                if (occursIn(v, c)) return true;
            }
            return false;
        },
    }
}

// ═══════════════════════════════════════════════════════════════════════
// STAR & CONSTELLATION — marked collections of rays
// ═══════════════════════════════════════════════════════════════════════

pub const Mark = enum {
    state,
    action,
};

// ═══════════════════════════════════════════════════════════════════════
// BAN — inequality constraints between rays (stellogen-upstream ban.ml)
// ═══════════════════════════════════════════════════════════════════════

pub const Ban = union(enum) {
    /// r1 != r2 — inequality after substitution
    ineq: [2]Ray,
    /// r1 ≁ r2 — structural incompatibility (cannot unify at all)
    incomp: [2]Ray,

    pub fn lhs(self: Ban) Ray {
        return switch (self) {
            .ineq => |pair| pair[0],
            .incomp => |pair| pair[0],
        };
    }

    pub fn rhs(self: Ban) Ray {
        return switch (self) {
            .ineq => |pair| pair[1],
            .incomp => |pair| pair[1],
        };
    }

    /// Apply a substitution to both sides.
    pub fn applySub(self: Ban, sub: *const Substitution) Ban {
        return switch (self) {
            .ineq => |pair| .{ .ineq = .{ sub.apply(pair[0]), sub.apply(pair[1]) } },
            .incomp => |pair| .{ .incomp = .{ sub.apply(pair[0]), sub.apply(pair[1]) } },
        };
    }

    /// Check if this ban is violated: ineq violated iff both sides equal,
    /// incomp violated iff both sides can unify.
    pub fn violated(self: Ban, allocator: std.mem.Allocator) bool {
        return switch (self) {
            .ineq => |pair| pair[0].eql(pair[1]),
            .incomp => |pair| {
                var sub = unify(allocator, pair[0], pair[1]) catch return false;
                sub.deinit();
                return true;
            },
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════
// VARIABLE MANAGEMENT — fresh vars, normalization, index replacement
// ═══════════════════════════════════════════════════════════════════════

pub const VarCounter = struct {
    next: u16 = 0,

    pub fn fresh(self: *VarCounter, base: []const u8) Ray.VarId {
        const idx = self.next;
        self.next += 1;
        return .{ .name = base, .index = idx };
    }

    pub fn freshRay(self: *VarCounter, base: []const u8) Ray {
        return .{ .variable = self.fresh(base) };
    }
};

/// Collect all variable ids in a ray (pre-order traversal).
pub fn collectVars(ray: Ray, out: *std.ArrayListUnmanaged(Ray.VarId), allocator: std.mem.Allocator) !void {
    switch (ray) {
        .variable => |v| {
            for (out.items) |existing| {
                if (existing.eql(v)) return;
            }
            try out.append(allocator, v);
        },
        .func => |f| {
            for (f.children) |c| try collectVars(c, out, allocator);
        },
    }
}

/// Replace all variable indices in a ray using a fresh counter.
/// Returns a substitution mapping old vars to fresh ones.
pub fn freshenRay(ray: Ray, counter: *VarCounter, allocator: std.mem.Allocator) !struct { ray: Ray, sub: Substitution } {
    var vars = std.ArrayListUnmanaged(Ray.VarId).empty;
    defer vars.deinit(allocator);
    try collectVars(ray, &vars, allocator);

    var sub = Substitution.init(allocator);
    for (vars.items) |v| {
        const fv = counter.fresh(v.name);
        try sub.bind(v, .{ .variable = fv });
    }
    return .{ .ray = sub.apply(ray), .sub = sub };
}

// ═══════════════════════════════════════════════════════════════════════
// P2: STACK NOTATION <f a b> — applicative form building
// ═══════════════════════════════════════════════════════════════════════

/// Stack notation: <f a b> builds Func(f.polarity, f.name, [a, b]).
/// If head is already a Func, appends args to existing children.
/// If head is a Var, wraps as Func(null, "%apply", [head, args...]).
pub fn stackApply(head: Ray, args: []const Ray, allocator: std.mem.Allocator) !Ray {
    switch (head) {
        .func => |f| {
            const new_children = try allocator.alloc(Ray, f.children.len + args.len);
            @memcpy(new_children[0..f.children.len], f.children);
            @memcpy(new_children[f.children.len..], args);
            return .{ .func = .{
                .name = f.name,
                .polarity = f.polarity,
                .children = new_children,
            } };
        },
        .variable => {
            const all = try allocator.alloc(Ray, 1 + args.len);
            all[0] = head;
            @memcpy(all[1..], args);
            return .{ .func = .{
                .name = "%apply",
                .polarity = .null_,
                .children = all,
            } };
        },
    }
}

// ═══════════════════════════════════════════════════════════════════════
// P2: EXPLICIT SUBSTITUTION [$x:=t] — rewriting directive
// ═══════════════════════════════════════════════════════════════════════

/// Apply an explicit substitution to a ray: walk the tree, replace vars.
pub fn applyExplicitSubst(ray: Ray, bindings: []const Binding, allocator: std.mem.Allocator) Ray {
    var sub = Substitution{
        .bindings = std.ArrayListUnmanaged(Binding).fromOwnedSlice(
            @constCast(bindings),
        ),
        .allocator = allocator,
    };
    // Don't deinit — caller owns the bindings slice.
    return sub.apply(ray);
}

/// Apply explicit substitution to every ray in a star, producing a new star.
pub fn applyExplicitSubstStar(star: Star, bindings: []const Binding, allocator: std.mem.Allocator) !Star {
    const new_rays = try allocator.alloc(Ray, star.rays.len);
    for (star.rays, 0..) |r, i| {
        new_rays[i] = applyExplicitSubst(r, bindings, allocator);
    }
    const new_bans = try allocator.alloc(Ban, star.bans.len);
    for (star.bans, 0..) |b, i| {
        new_bans[i] = switch (b) {
            .ineq => |pair| .{ .ineq = .{
                applyExplicitSubst(pair[0], bindings, allocator),
                applyExplicitSubst(pair[1], bindings, allocator),
            } },
            .incomp => |pair| .{ .incomp = .{
                applyExplicitSubst(pair[0], bindings, allocator),
                applyExplicitSubst(pair[1], bindings, allocator),
            } },
        };
    }
    return .{ .rays = new_rays, .bans = new_bans, .mark = star.mark };
}

/// Apply explicit substitution to every star in a constellation.
pub fn applyExplicitSubstConstellation(c: *Constellation, bindings: []const Binding) !void {
    for (c.stars.items, 0..) |star, i| {
        c.stars.items[i] = try applyExplicitSubstStar(star, bindings, c.allocator);
    }
}

pub const Star = struct {
    rays: []const Ray,
    bans: []const Ban = &.{},
    mark: Mark,

    pub fn tritSum(self: *const Star) i8 {
        var sum: i16 = 0;
        for (self.rays) |r| {
            switch (r) {
                .func => |f| sum += f.polarity.trit(),
                .variable => {},
            }
        }
        return @intCast(@mod(sum + 300, 3));
    }

    /// Check if all bans are satisfied (none violated).
    pub fn bansCoherent(self: *const Star, allocator: std.mem.Allocator) bool {
        for (self.bans) |b| {
            if (b.violated(allocator)) return false;
        }
        return true;
    }
};

pub const Constellation = struct {
    stars: std.ArrayListUnmanaged(Star),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Constellation {
        return .{
            .stars = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Constellation) void {
        self.stars.deinit(self.allocator);
    }

    pub fn addStar(self: *Constellation, star: Star) !void {
        try self.stars.append(self.allocator, star);
    }

    pub fn stateCount(self: *const Constellation) usize {
        var n: usize = 0;
        for (self.stars.items) |s| {
            if (s.mark == .state) n += 1;
        }
        return n;
    }

    pub fn actionCount(self: *const Constellation) usize {
        var n: usize = 0;
        for (self.stars.items) |s| {
            if (s.mark == .action) n += 1;
        }
        return n;
    }

    /// GF(3) trit sum over all stars.
    pub fn tritSum(self: *const Constellation) i8 {
        var sum: i16 = 0;
        for (self.stars.items) |s| {
            sum += s.tritSum();
        }
        return @intCast(@mod(sum + 300, 3));
    }
};

// ═══════════════════════════════════════════════════════════════════════
// FIRE — single resolution step
// ═══════════════════════════════════════════════════════════════════════

/// Result of a single fire step.
pub const FireResult = struct {
    fired: bool,
    state_idx: ?usize = null,
    action_idx: ?usize = null,
    state_ray_idx: ?usize = null,
    action_ray_idx: ?usize = null,
};

/// Attempt one resolution step: find a compatible ray pair between any
/// State star and any Action star, unify, and return the result.
/// Does NOT mutate the constellation (caller applies substitution).
pub fn fire(c: *const Constellation, allocator: std.mem.Allocator) !FireResult {
    for (c.stars.items, 0..) |si, si_idx| {
        if (si.mark != .state) continue;
        for (si.rays, 0..) |sr, sr_idx| {
            for (c.stars.items, 0..) |aj, aj_idx| {
                if (aj.mark != .action) continue;
                for (aj.rays, 0..) |ar, ar_idx| {
                    if (sr.compatibleWith(ar)) {
                        // Try to unify children pairwise
                        var can_unify = true;
                        const sf = switch (sr) {
                            .func => |f| f,
                            .variable => continue,
                        };
                        const af = switch (ar) {
                            .func => |f| f,
                            .variable => continue,
                        };
                        var sub = Substitution.init(allocator);
                        defer sub.deinit();
                        for (sf.children, af.children) |sc, ac| {
                            unifyRec(&sub, sc, ac) catch {
                                can_unify = false;
                                break;
                            };
                        }
                        if (can_unify) {
                            return .{
                                .fired = true,
                                .state_idx = si_idx,
                                .action_idx = aj_idx,
                                .state_ray_idx = sr_idx,
                                .action_ray_idx = ar_idx,
                            };
                        }
                    }
                }
            }
        }
    }
    return .{ .fired = false };
}

/// Count how many fire steps are possible (interaction count).
pub fn interactionCount(c: *const Constellation, allocator: std.mem.Allocator) !usize {
    var count: usize = 0;
    for (c.stars.items) |si| {
        if (si.mark != .state) continue;
        for (si.rays) |sr| {
            for (c.stars.items) |aj| {
                if (aj.mark != .action) continue;
                for (aj.rays) |ar| {
                    if (sr.compatibleWith(ar)) {
                        const sf = switch (sr) {
                            .func => |f| f,
                            .variable => continue,
                        };
                        const af = switch (ar) {
                            .func => |f| f,
                            .variable => continue,
                        };
                        var sub = Substitution.init(allocator);
                        defer sub.deinit();
                        var ok = true;
                        for (sf.children, af.children) |sc, ac| {
                            unifyRec(&sub, sc, ac) catch {
                                ok = false;
                                break;
                            };
                        }
                        if (ok) count += 1;
                    }
                }
            }
        }
    }
    return count;
}

// ═══════════════════════════════════════════════════════════════════════
// EXEC — iterate fire until fixpoint (no interactions remain)
// ═══════════════════════════════════════════════════════════════════════

pub const ExecResult = struct {
    steps: usize,
    fixpoint: bool,
};

/// Run resolution until fixpoint or fuel exhausted.
pub fn exec(c: *const Constellation, allocator: std.mem.Allocator, max_steps: usize) !ExecResult {
    var steps: usize = 0;
    while (steps < max_steps) {
        const result = try fire(c, allocator);
        if (!result.fired) return .{ .steps = steps, .fixpoint = true };
        steps += 1;
    }
    return .{ .steps = steps, .fixpoint = false };
}

// ═══════════════════════════════════════════════════════════════════════
// MATCHABLE UNIFY — polarity-ignoring unification (for env lookup)
// ═══════════════════════════════════════════════════════════════════════

/// Unify two rays ignoring polarity (for pattern matching / env lookup).
pub fn unifyMatchable(allocator: std.mem.Allocator, a: Ray, b: Ray) UnifyError!Substitution {
    var sub = Substitution.init(allocator);
    errdefer sub.deinit();
    try unifyMatchableRec(&sub, a, b);
    return sub;
}

fn unifyMatchableRec(sub: *Substitution, a: Ray, b: Ray) UnifyError!void {
    const wa = sub.apply(a);
    const wb = sub.apply(b);

    switch (wa) {
        .variable => |va| switch (wb) {
            .variable => |vb| {
                if (!va.eql(vb)) try sub.bind(va, wb);
            },
            .func => {
                if (occursIn(va, wb)) return error.OccursCheck;
                try sub.bind(va, wb);
            },
        },
        .func => |fa| switch (wb) {
            .variable => |vb| {
                if (occursIn(vb, wa)) return error.OccursCheck;
                try sub.bind(vb, wa);
            },
            .func => |fb| {
                // Polarity IGNORED — only name and arity must match
                if (!std.mem.eql(u8, fa.name, fb.name)) return error.Clash;
                if (fa.children.len != fb.children.len) return error.Clash;
                for (fa.children, fb.children) |ca, cb| {
                    try unifyMatchableRec(sub, ca, cb);
                }
            },
        },
    }
}

// ═══════════════════════════════════════════════════════════════════════
// FUSION — queue-based executor (mirrors OCaml stellogen_executor)
// ═══════════════════════════════════════════════════════════════════════

pub const FusionCandidate = struct {
    state_idx: usize,
    action_idx: usize,
    state_ray_idx: usize,
    action_ray_idx: usize,
};

pub const FusionResult = struct {
    merged_star: Star,
    consumed_bans: []const Ban,
};

pub const ExecConfig = struct {
    linear: bool = false,
    max_steps: usize = 100,
    on_event: ?*const fn (ExecEvent) void = null,
};

pub const ExecEvent = union(enum) {
    fire_step: struct { candidate: FusionCandidate, step: usize },
    fixpoint: struct { steps: usize },
    fuel_exhausted: struct { steps: usize },
    ban_violation: struct { candidate: FusionCandidate },
};

/// Find all valid fusion candidates in a constellation.
pub fn findFusionCandidates(c: *const Constellation, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(FusionCandidate) {
    var out = std.ArrayListUnmanaged(FusionCandidate).empty;
    for (c.stars.items, 0..) |si, si_idx| {
        if (si.mark != .state) continue;
        for (si.rays, 0..) |sr, sr_idx| {
            for (c.stars.items, 0..) |aj, aj_idx| {
                if (aj.mark != .action) continue;
                for (aj.rays, 0..) |ar, ar_idx| {
                    if (sr.compatibleWith(ar)) {
                        const sf = switch (sr) {
                            .func => |f| f,
                            .variable => continue,
                        };
                        const af = switch (ar) {
                            .func => |f| f,
                            .variable => continue,
                        };
                        var sub = Substitution.init(allocator);
                        defer sub.deinit();
                        var ok = true;
                        for (sf.children, af.children) |sc, ac| {
                            unifyRec(&sub, sc, ac) catch {
                                ok = false;
                                break;
                            };
                        }
                        if (ok) {
                            try out.append(allocator, .{
                                .state_idx = si_idx,
                                .action_idx = aj_idx,
                                .state_ray_idx = sr_idx,
                                .action_ray_idx = ar_idx,
                            });
                        }
                    }
                }
            }
        }
    }
    return out;
}

/// Apply a substitution to every ray in every star of a constellation (in-place).
fn applySubToConstellation(c: *Constellation, sub: *const Substitution) void {
    for (c.stars.items, 0..) |star, si| {
        const new_rays = c.allocator.alloc(Ray, star.rays.len) catch continue;
        for (star.rays, 0..) |r, ri| {
            new_rays[ri] = sub.apply(r);
        }
        // Apply sub to bans as well.
        const new_bans = c.allocator.alloc(Ban, star.bans.len) catch {
            c.stars.items[si].rays = new_rays;
            continue;
        };
        for (star.bans, 0..) |b, bi| {
            new_bans[bi] = b.applySub(sub);
        }
        c.stars.items[si].rays = new_rays;
        c.stars.items[si].bans = new_bans;
    }
}

/// Merge two stars at a fusion point: combine rays (excluding the matched pair),
/// apply substitution theta, merge bans, and return the fused star.
fn performFusion(
    allocator: std.mem.Allocator,
    state: Star,
    action: Star,
    state_ray_idx: usize,
    action_ray_idx: usize,
    theta: *const Substitution,
) !Star {
    // Collect all rays except the matched pair, apply theta.
    const total = (state.rays.len - 1) + (action.rays.len - 1);
    const merged_rays = try allocator.alloc(Ray, total);
    var idx: usize = 0;
    for (state.rays, 0..) |r, i| {
        if (i == state_ray_idx) continue;
        merged_rays[idx] = theta.apply(r);
        idx += 1;
    }
    for (action.rays, 0..) |r, i| {
        if (i == action_ray_idx) continue;
        merged_rays[idx] = theta.apply(r);
        idx += 1;
    }
    // Merge bans, apply theta.
    const merged_bans = try allocator.alloc(Ban, state.bans.len + action.bans.len);
    for (state.bans, 0..) |b, i| {
        merged_bans[i] = b.applySub(theta);
    }
    for (action.bans, 0..) |b, i| {
        merged_bans[state.bans.len + i] = b.applySub(theta);
    }
    return .{
        .rays = merged_rays,
        .bans = merged_bans,
        .mark = .state, // fused result becomes a state star
    };
}

/// Queue-based exec: find candidates, pick first, fuse, repeat.
/// Performs actual fusion: unifies matched rays, applies theta to the
/// constellation, merges remaining rays, checks bans, removes empty stars.
pub fn execQueue(c: *Constellation, allocator: std.mem.Allocator, config: ExecConfig) !ExecResult {
    var steps: usize = 0;
    while (steps < config.max_steps) {
        var candidates = try findFusionCandidates(c, allocator);
        defer candidates.deinit(allocator);
        if (candidates.items.len == 0) {
            if (config.on_event) |cb| cb(.{ .fixpoint = .{ .steps = steps } });
            return .{ .steps = steps, .fixpoint = true };
        }
        const cand = candidates.items[0];
        if (config.on_event) |cb| cb(.{ .fire_step = .{ .candidate = cand, .step = steps } });

        // Compute full unification for the matched ray pair.
        const state_star = c.stars.items[cand.state_idx];
        const action_star = c.stars.items[cand.action_idx];
        const sr = state_star.rays[cand.state_ray_idx];
        const ar = action_star.rays[cand.action_ray_idx];

        var theta = unify(allocator, sr, ar) catch {
            // Shouldn't happen (candidate was validated), but be safe.
            steps += 1;
            continue;
        };
        defer theta.deinit();

        // Perform fusion: merge remaining rays under theta.
        const fused = performFusion(
            allocator,
            state_star,
            action_star,
            cand.state_ray_idx,
            cand.action_ray_idx,
            &theta,
        ) catch {
            steps += 1;
            continue;
        };

        // Check bans on fused star — if violated, free and skip this candidate.
        if (!fused.bansCoherent(allocator)) {
            if (config.on_event) |cb| cb(.{ .ban_violation = .{ .candidate = cand } });
            allocator.free(fused.rays);
            allocator.free(fused.bans);
            steps += 1;
            continue;
        }

        // Remove the two consumed stars (higher index first to avoid shift).
        const hi = @max(cand.state_idx, cand.action_idx);
        const lo = @min(cand.state_idx, cand.action_idx);
        _ = c.stars.orderedRemove(hi);
        _ = c.stars.orderedRemove(lo);

        // Add the fused star (unless it has zero rays — empty star is discarded).
        if (fused.rays.len > 0) {
            try c.addStar(fused);
        }

        // Apply theta to the entire remaining constellation (global substitution).
        applySubToConstellation(c, &theta);

        // In linear mode, we already removed the action star above.
        // Filter out any stars that became empty after substitution.
        var write: usize = 0;
        for (c.stars.items) |s| {
            if (s.rays.len > 0) {
                c.stars.items[write] = s;
                write += 1;
            }
        }
        c.stars.shrinkRetainingCapacity(write);

        steps += 1;
    }
    if (config.on_event) |cb| cb(.{ .fuel_exhausted = .{ .steps = steps } });
    return .{ .steps = steps, .fixpoint = false };
}

// ═══════════════════════════════════════════════════════════════════════
// CONSTRUCTORS — convenience builders (mirror OCaml constellation.ml)
// ═══════════════════════════════════════════════════════════════════════

pub fn makeVar(name: []const u8) Ray {
    return .{ .variable = .{ .name = name } };
}

pub fn makeConst(pol: Polarity, name: []const u8) Ray {
    return .{ .func = .{ .polarity = pol, .name = name, .children = &.{} } };
}

pub fn makePosConst(name: []const u8) Ray {
    return makeConst(.pos, name);
}

pub fn makeNegConst(name: []const u8) Ray {
    return makeConst(.neg, name);
}

pub fn makeNullConst(name: []const u8) Ray {
    return makeConst(.null_, name);
}

pub fn makeFunc(pol: Polarity, name: []const u8, children: []const Ray) Ray {
    return .{ .func = .{ .polarity = pol, .name = name, .children = children } };
}

// ═══════════════════════════════════════════════════════════════════════
// CONSTELLATION EQUALITY — structural comparison for fixpoint detection
// ═══════════════════════════════════════════════════════════════════════

pub fn constellationEql(a: *const Constellation, b: *const Constellation) bool {
    if (a.stars.items.len != b.stars.items.len) return false;
    for (a.stars.items, b.stars.items) |sa, sb| {
        if (sa.mark != sb.mark) return false;
        if (sa.rays.len != sb.rays.len) return false;
        for (sa.rays, sb.rays) |ra, rb| {
            if (!ra.eql(rb)) return false;
        }
        if (sa.bans.len != sb.bans.len) return false;
        for (sa.bans, sb.bans) |ba, bb| {
            if (!banEql(ba, bb)) return false;
        }
    }
    return true;
}

fn banEql(a: Ban, b: Ban) bool {
    switch (a) {
        .ineq => |ai| switch (b) {
            .ineq => |bi| return ai[0].eql(bi[0]) and ai[1].eql(bi[1]),
            .incomp => return false,
        },
        .incomp => |ai| switch (b) {
            .incomp => |bi| return ai[0].eql(bi[0]) and ai[1].eql(bi[1]),
            .ineq => return false,
        },
    }
}

// ═══════════════════════════════════════════════════════════════════════
// PROCESS — iterative exec until fixpoint or step limit (P1)
// ═══════════════════════════════════════════════════════════════════════

pub const ProcessConfig = struct {
    max_steps: usize = 100,
    linear: bool = false,
};

pub const ProcessResult = struct {
    steps: usize,
    fixpoint: bool,
};

/// Iteratively exec a constellation until fixpoint (no change after exec)
/// or step limit is reached. Mirrors OCaml `Process` variant.
pub fn process(c: *Constellation, allocator: std.mem.Allocator, config: ProcessConfig) !ProcessResult {
    var step: usize = 0;
    while (step < config.max_steps) {
        // Snapshot current state for comparison.
        var snapshot = Constellation.init(allocator);
        for (c.stars.items) |s| {
            try snapshot.addStar(s);
        }

        // Run one exec cycle.
        _ = try execQueue(c, allocator, .{
            .max_steps = 1,
            .linear = config.linear,
        });

        // Compare: if constellation didn't change, fixpoint reached.
        if (constellationEql(c, &snapshot)) {
            return .{ .steps = step, .fixpoint = true };
        }
        step += 1;
    }
    return .{ .steps = step, .fixpoint = false };
}

// ═══════════════════════════════════════════════════════════════════════
// FILE LOADER — pluggable import for Use (P1)
// ═══════════════════════════════════════════════════════════════════════

pub const FileLoaderError = error{
    FileNotFound,
    ParseError,
    OutOfMemory,
};

/// A file loader returns a constellation parsed from the given path.
/// The default loader returns an empty constellation.
pub const FileLoader = *const fn (path: []const u8, allocator: std.mem.Allocator) FileLoaderError!Constellation;

pub fn defaultLoader(_: []const u8, allocator: std.mem.Allocator) FileLoaderError!Constellation {
    return Constellation.init(allocator);
}

/// Load a file via the given loader, merge its stars into the target constellation.
pub fn useImport(target: *Constellation, path: []const u8, allocator: std.mem.Allocator, loader: FileLoader) !void {
    var imported = try loader(path, allocator);
    for (imported.stars.items) |s| {
        try target.addStar(s);
    }
    _ = &imported;
}

// ═══════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════

test "Polarity.trit matches GF(3) charges" {
    try std.testing.expectEqual(@as(i8, 1), Polarity.pos.trit());
    try std.testing.expectEqual(@as(i8, -1), Polarity.neg.trit());
    try std.testing.expectEqual(@as(i8, 0), Polarity.null_.trit());
}

test "Polarity.compatible: Pos↔Neg, Null↔Null, nothing else" {
    try std.testing.expect(Polarity.compatible(.pos, .neg));
    try std.testing.expect(Polarity.compatible(.neg, .pos));
    try std.testing.expect(Polarity.compatible(.null_, .null_));
    try std.testing.expect(!Polarity.compatible(.pos, .pos));
    try std.testing.expect(!Polarity.compatible(.neg, .neg));
    try std.testing.expect(!Polarity.compatible(.pos, .null_));
    try std.testing.expect(!Polarity.compatible(.null_, .pos));
}

test "Ray.eql: variables" {
    const a = makeVar("X");
    const b = makeVar("X");
    const c = makeVar("Y");
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "Ray.eql: constants" {
    const a = makePosConst("hello");
    const b = makePosConst("hello");
    const c = makeNegConst("hello");
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c)); // different polarity
}

test "Ray.compatibleWith: pos↔neg same name" {
    const a = makePosConst("msg");
    const b = makeNegConst("msg");
    const c = makePosConst("msg");
    const d = makePosConst("other");
    try std.testing.expect(a.compatibleWith(b));
    try std.testing.expect(b.compatibleWith(a));
    try std.testing.expect(!a.compatibleWith(c)); // same polarity
    try std.testing.expect(!a.compatibleWith(d)); // different name
}

test "Ray.compatibleWith: variables never compatible" {
    const v = makeVar("X");
    const f = makePosConst("msg");
    try std.testing.expect(!v.compatibleWith(f));
    try std.testing.expect(!f.compatibleWith(v));
}

test "unify: two variables" {
    var sub = try unify(std.testing.allocator, makeVar("X"), makeVar("Y"));
    defer sub.deinit();
    try std.testing.expectEqual(@as(usize, 1), sub.bindings.items.len);
}

test "unify: var with constant" {
    var sub = try unify(std.testing.allocator, makeVar("X"), makePosConst("a"));
    defer sub.deinit();
    const bound = sub.lookup(.{ .name = "X" }) orelse return error.TestExpectedNonNull;
    try std.testing.expect(bound.eql(makePosConst("a")));
}

test "unify: identical constants" {
    var sub = try unify(std.testing.allocator, makePosConst("a"), makePosConst("a"));
    defer sub.deinit();
    try std.testing.expectEqual(@as(usize, 0), sub.bindings.items.len);
}

test "unify: clash on different names" {
    try std.testing.expectError(
        error.Clash,
        unify(std.testing.allocator, makePosConst("a"), makePosConst("b")),
    );
}

test "unify: func with children" {
    const children_a = [_]Ray{makeVar("X")};
    const children_b = [_]Ray{makePosConst("val")};
    const a = makeFunc(.pos, "f", &children_a);
    const b = makeFunc(.pos, "f", &children_b);
    var sub = try unify(std.testing.allocator, a, b);
    defer sub.deinit();
    const bound = sub.lookup(.{ .name = "X" }) orelse return error.TestExpectedNonNull;
    try std.testing.expect(bound.eql(makePosConst("val")));
}

test "Star.tritSum: balanced star" {
    const rays = [_]Ray{ makePosConst("a"), makeNegConst("b"), makeNullConst("c") };
    const star = Star{ .rays = &rays, .mark = .state };
    // +1 + (-1) + 0 = 0 mod 3
    try std.testing.expectEqual(@as(i8, 0), star.tritSum());
}

test "Constellation: add stars and count" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const state_rays = [_]Ray{makePosConst("req")};
    const action_rays = [_]Ray{makeNegConst("req")};
    try c.addStar(.{ .rays = &state_rays, .mark = .state });
    try c.addStar(.{ .rays = &action_rays, .mark = .action });

    try std.testing.expectEqual(@as(usize, 1), c.stateCount());
    try std.testing.expectEqual(@as(usize, 1), c.actionCount());
}

test "fire: detects compatible pair" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const state_rays = [_]Ray{makePosConst("msg")};
    const action_rays = [_]Ray{makeNegConst("msg")};
    try c.addStar(.{ .rays = &state_rays, .mark = .state });
    try c.addStar(.{ .rays = &action_rays, .mark = .action });

    const result = try fire(&c, std.testing.allocator);
    try std.testing.expect(result.fired);
    try std.testing.expectEqual(@as(usize, 0), result.state_idx.?);
    try std.testing.expectEqual(@as(usize, 1), result.action_idx.?);
}

test "fire: no interaction when polarities don't match" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const s_rays = [_]Ray{makePosConst("msg")};
    const a_rays = [_]Ray{makePosConst("msg")}; // same polarity → no interaction
    try c.addStar(.{ .rays = &s_rays, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });

    const result = try fire(&c, std.testing.allocator);
    try std.testing.expect(!result.fired);
}

test "fire: unification with variables" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const children_s = [_]Ray{makePosConst("hello")};
    const children_a = [_]Ray{makeVar("X")};
    const s_rays = [_]Ray{makeFunc(.pos, "send", &children_s)};
    const a_rays = [_]Ray{makeFunc(.neg, "send", &children_a)};
    try c.addStar(.{ .rays = &s_rays, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });

    const result = try fire(&c, std.testing.allocator);
    try std.testing.expect(result.fired);
}

test "exec: fixpoint on empty constellation" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const result = try exec(&c, std.testing.allocator, 10);
    try std.testing.expect(result.fixpoint);
    try std.testing.expectEqual(@as(usize, 0), result.steps);
}

test "interactionCount: counts all compatible pairs" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const s_rays = [_]Ray{ makePosConst("a"), makePosConst("b") };
    const a_rays = [_]Ray{ makeNegConst("a"), makeNegConst("b") };
    try c.addStar(.{ .rays = &s_rays, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });

    const count = try interactionCount(&c, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "GF(3) conservation: pos + neg + null = 0 mod 3" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const balanced = [_]Ray{ makePosConst("x"), makeNegConst("y"), makeNullConst("z") };
    try c.addStar(.{ .rays = &balanced, .mark = .state });
    try std.testing.expectEqual(@as(i8, 0), c.tritSum());
}

test "Polarity.fromChar parses +/-/other" {
    try std.testing.expectEqual(Polarity.pos, Polarity.fromChar('+'));
    try std.testing.expectEqual(Polarity.neg, Polarity.fromChar('-'));
    try std.testing.expectEqual(Polarity.null_, Polarity.fromChar('~'));
    try std.testing.expectEqual(Polarity.null_, Polarity.fromChar('a'));
}

test "makeFunc preserves children" {
    const children = [_]Ray{ makeVar("X"), makePosConst("a") };
    const f = makeFunc(.neg, "apply", &children);
    switch (f) {
        .func => |fn_| {
            try std.testing.expectEqual(@as(usize, 2), fn_.children.len);
            try std.testing.expectEqual(Polarity.neg, fn_.polarity);
        },
        .variable => return error.TestUnexpectedResult,
    }
}

// ═══════════════════ Ban tests ═══════════════════════════════════════

test "Ban.ineq: not violated when sides differ" {
    const b = Ban{ .ineq = .{ makePosConst("a"), makePosConst("b") } };
    try std.testing.expect(!b.violated(std.testing.allocator));
}

test "Ban.ineq: violated when sides equal" {
    const b = Ban{ .ineq = .{ makePosConst("a"), makePosConst("a") } };
    try std.testing.expect(b.violated(std.testing.allocator));
}

test "Ban.incomp: violated when sides unifiable" {
    const b = Ban{ .incomp = .{ makeVar("X"), makePosConst("a") } };
    try std.testing.expect(b.violated(std.testing.allocator));
}

test "Ban.incomp: not violated when sides clash" {
    const b = Ban{ .incomp = .{ makePosConst("a"), makePosConst("b") } };
    try std.testing.expect(!b.violated(std.testing.allocator));
}

test "Ban.applySub: substitution threads through" {
    var sub = Substitution.init(std.testing.allocator);
    defer sub.deinit();
    try sub.bind(.{ .name = "X" }, makePosConst("a"));
    const b = Ban{ .ineq = .{ makeVar("X"), makePosConst("b") } };
    const applied = b.applySub(&sub);
    try std.testing.expect(applied.lhs().eql(makePosConst("a")));
    try std.testing.expect(applied.rhs().eql(makePosConst("b")));
}

test "Star.bansCoherent: no bans always coherent" {
    const rays = [_]Ray{makePosConst("x")};
    const star = Star{ .rays = &rays, .mark = .state };
    try std.testing.expect(star.bansCoherent(std.testing.allocator));
}

test "Star.bansCoherent: ineq ban satisfied" {
    const rays = [_]Ray{makePosConst("x")};
    const bans = [_]Ban{.{ .ineq = .{ makePosConst("a"), makePosConst("b") } }};
    const star = Star{ .rays = &rays, .bans = &bans, .mark = .state };
    try std.testing.expect(star.bansCoherent(std.testing.allocator));
}

test "Star.bansCoherent: ineq ban violated" {
    const rays = [_]Ray{makePosConst("x")};
    const bans = [_]Ban{.{ .ineq = .{ makePosConst("a"), makePosConst("a") } }};
    const star = Star{ .rays = &rays, .bans = &bans, .mark = .state };
    try std.testing.expect(!star.bansCoherent(std.testing.allocator));
}

// ═══════════════════ Variable management tests ═══════════════════════

test "VarCounter.fresh: monotonic indices" {
    var counter = VarCounter{};
    const v0 = counter.fresh("X");
    const v1 = counter.fresh("X");
    try std.testing.expectEqual(@as(u16, 0), v0.index.?);
    try std.testing.expectEqual(@as(u16, 1), v1.index.?);
    try std.testing.expect(std.mem.eql(u8, v0.name, v1.name));
}

test "collectVars: finds unique variables" {
    const children = [_]Ray{ makeVar("X"), makeVar("Y"), makeVar("X") };
    const term = makeFunc(.pos, "f", &children);
    var out = std.ArrayListUnmanaged(Ray.VarId).empty;
    defer out.deinit(std.testing.allocator);
    try collectVars(term, &out, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // X, Y (X deduped)
}

// ═══════════════════ Matchable unify tests ═══════════════════════════

test "unifyMatchable: ignores polarity" {
    // Normal unify would fail (pos vs pos same polarity → not compatible for resolution)
    // but matchable unify only checks name + arity, ignoring polarity
    var sub = try unifyMatchable(std.testing.allocator, makePosConst("a"), makeNegConst("a"));
    defer sub.deinit();
    // Should succeed with empty substitution (same name, 0-arity)
    try std.testing.expectEqual(@as(usize, 0), sub.bindings.items.len);
}

test "unifyMatchable: still clashes on different names" {
    try std.testing.expectError(
        error.Clash,
        unifyMatchable(std.testing.allocator, makePosConst("a"), makePosConst("b")),
    );
}

test "unifyMatchable: binds variables across polarities" {
    const children_a = [_]Ray{makeVar("X")};
    const children_b = [_]Ray{makePosConst("val")};
    const a = makeFunc(.pos, "f", &children_a);
    const b = makeFunc(.neg, "f", &children_b); // opposite polarity
    var sub = try unifyMatchable(std.testing.allocator, a, b);
    defer sub.deinit();
    const bound = sub.lookup(.{ .name = "X" }) orelse return error.TestExpectedNonNull;
    try std.testing.expect(bound.eql(makePosConst("val")));
}

// ═══════════════════ Fusion candidate tests ══════════════════════════

test "findFusionCandidates: finds compatible pairs" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const s_rays = [_]Ray{ makePosConst("a"), makePosConst("b") };
    const a_rays = [_]Ray{ makeNegConst("a"), makeNegConst("b") };
    try c.addStar(.{ .rays = &s_rays, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });

    var candidates = try findFusionCandidates(&c, std.testing.allocator);
    defer candidates.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), candidates.items.len);
}

test "findFusionCandidates: empty on no interactions" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const s_rays = [_]Ray{makePosConst("a")};
    const a_rays = [_]Ray{makePosConst("a")}; // same polarity
    try c.addStar(.{ .rays = &s_rays, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });

    var candidates = try findFusionCandidates(&c, std.testing.allocator);
    defer candidates.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), candidates.items.len);
}

test "execQueue: fixpoint on empty constellation" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const result = try execQueue(&c, std.testing.allocator, .{ .max_steps = 10 });
    try std.testing.expect(result.fixpoint);
    try std.testing.expectEqual(@as(usize, 0), result.steps);
}

test "execQueue: fuses and reaches fixpoint" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const s_rays = [_]Ray{makePosConst("msg")};
    const a_rays = [_]Ray{makeNegConst("msg")};
    try c.addStar(.{ .rays = &s_rays, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });

    const result = try execQueue(&c, std.testing.allocator, .{ .max_steps = 5 });
    // After real fusion: +msg and -msg annihilate, fused star has 0 rays → removed.
    // Constellation is empty → fixpoint at step 1.
    try std.testing.expectEqual(@as(usize, 1), result.steps);
    try std.testing.expect(result.fixpoint);
    try std.testing.expectEqual(@as(usize, 0), c.stars.items.len);
}

test "execQueue: event callback fires" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const result = try execQueue(&c, std.testing.allocator, .{ .max_steps = 10 });
    try std.testing.expect(result.fixpoint);
}

// ── Deeper edge-case tests ──

test "unify: nested func trees" {
    const children_a = [_]Ray{makeVar("X")};
    const children_b = [_]Ray{makePosConst("inner")};
    const outer_a = [_]Ray{Ray{ .func = .{ .polarity = .pos, .name = "f", .children = &children_a } }};
    const outer_b = [_]Ray{Ray{ .func = .{ .polarity = .pos, .name = "f", .children = &children_b } }};
    const a = Ray{ .func = .{ .polarity = .pos, .name = "g", .children = &outer_a } };
    const b = Ray{ .func = .{ .polarity = .pos, .name = "g", .children = &outer_b } };
    var sub = try unify(std.testing.allocator, a, b);
    defer sub.deinit();
    const bound = sub.lookup(.{ .name = "X" });
    try std.testing.expect(bound != null);
    try std.testing.expect(bound.?.eql(makePosConst("inner")));
}

test "unify: arity mismatch fails" {
    const children_a = [_]Ray{ makeVar("X"), makeVar("Y") };
    const children_b = [_]Ray{makePosConst("only")};
    const a = Ray{ .func = .{ .polarity = .pos, .name = "f", .children = &children_a } };
    const b = Ray{ .func = .{ .polarity = .pos, .name = "f", .children = &children_b } };
    const result = unify(std.testing.allocator, a, b);
    try std.testing.expectError(error.Clash, result);
}

test "unify: name mismatch on func fails" {
    const a = makePosConst("alpha");
    const b = Ray{ .func = .{ .polarity = .pos, .name = "beta", .children = &.{} } };
    const result = unify(std.testing.allocator, a, b);
    try std.testing.expectError(error.Clash, result);
}

test "Substitution.apply: shallow substitution on variable" {
    var sub = Substitution.init(std.testing.allocator);
    defer sub.deinit();
    try sub.bind(.{ .name = "X" }, makePosConst("val"));
    const result = sub.apply(makeVar("X"));
    try std.testing.expect(result.eql(makePosConst("val")));
}

test "Substitution.apply: constant passes through" {
    var sub = Substitution.init(std.testing.allocator);
    defer sub.deinit();
    try sub.bind(.{ .name = "X" }, makePosConst("val"));
    const result = sub.apply(makePosConst("untouched"));
    try std.testing.expect(result.eql(makePosConst("untouched")));
}

test "Substitution.apply: unbound var passes through" {
    var sub = Substitution.init(std.testing.allocator);
    defer sub.deinit();
    const v = makeVar("Z");
    const result = sub.apply(v);
    try std.testing.expect(result.eql(v));
}

test "Star.tritSum: action star with pos+neg" {
    const rays = [_]Ray{ makePosConst("a"), makeNegConst("b") };
    const s = Star{ .rays = &rays, .mark = .action, .bans = &.{} };
    const sum = s.tritSum();
    // pos=1, neg=-1, sum=0
    try std.testing.expectEqual(@as(i32, 0), sum);
}

test "Star.tritSum: all null rays" {
    const rays = [_]Ray{ makeNullConst("x"), makeNullConst("y"), makeNullConst("z") };
    const s = Star{ .rays = &rays, .mark = .state, .bans = &.{} };
    try std.testing.expectEqual(@as(i32, 0), s.tritSum());
}

test "Ban.ineq: both variables, no sub → not violated" {
    const b = Ban{ .ineq = .{ makeVar("X"), makeVar("Y") } };
    try std.testing.expect(!b.violated(std.testing.allocator));
}

test "Ban.incomp: identical constants → violated" {
    const b = Ban{ .incomp = .{ makePosConst("same"), makePosConst("same") } };
    try std.testing.expect(b.violated(std.testing.allocator));
}

test "Ban.incomp: different names → not violated" {
    const b = Ban{ .incomp = .{ makePosConst("a"), makePosConst("b") } };
    try std.testing.expect(!b.violated(std.testing.allocator));
}

test "freshenRay: renames variables with fresh indices" {
    var vc = VarCounter{};
    const result = try freshenRay(makeVar("X"), &vc, std.testing.allocator);
    var sub = result.sub;
    defer sub.deinit();
    switch (result.ray) {
        .variable => |v| {
            try std.testing.expect(std.mem.eql(u8, "X", v.name));
            try std.testing.expect(v.index != null);
            try std.testing.expectEqual(@as(u16, 0), v.index.?);
        },
        else => unreachable,
    }
}

test "freshenRay: constants unchanged" {
    var vc = VarCounter{};
    const original = makePosConst("hello");
    const result = try freshenRay(original, &vc, std.testing.allocator);
    var sub = result.sub;
    defer sub.deinit();
    try std.testing.expect(result.ray.eql(original));
}

test "collectVars: empty on constants-only" {
    var out: std.ArrayListUnmanaged(Ray.VarId) = .empty;
    defer out.deinit(std.testing.allocator);
    try collectVars(makePosConst("a"), &out, std.testing.allocator);
    try collectVars(makeNegConst("b"), &out, std.testing.allocator);
    try collectVars(makeNullConst("c"), &out, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "collectVars: deduplicates repeated variables" {
    const children = [_]Ray{ makeVar("X"), makePosConst("a"), makeVar("X"), makeVar("Y") };
    const term = Ray{ .func = .{ .polarity = .pos, .name = "wrap", .children = &children } };
    var out: std.ArrayListUnmanaged(Ray.VarId) = .empty;
    defer out.deinit(std.testing.allocator);
    try collectVars(term, &out, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}

test "findFusionCandidates: null polarity pairs" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const s_rays = [_]Ray{makeNullConst("x")};
    const a_rays = [_]Ray{makeNullConst("x")};
    try c.addStar(.{ .rays = &s_rays, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });
    var candidates = try findFusionCandidates(&c, std.testing.allocator);
    defer candidates.deinit(std.testing.allocator);
    // null↔null is compatible
    try std.testing.expect(candidates.items.len > 0);
}

test "findFusionCandidates: same-mark stars don't fuse" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const r1 = [_]Ray{makePosConst("a")};
    const r2 = [_]Ray{makeNegConst("a")};
    try c.addStar(.{ .rays = &r1, .mark = .state });
    try c.addStar(.{ .rays = &r2, .mark = .state }); // both state
    var candidates = try findFusionCandidates(&c, std.testing.allocator);
    defer candidates.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), candidates.items.len);
}

test "Polarity.compatible: exhaustive pairs" {
    try std.testing.expect(Polarity.compatible(.pos, .neg));
    try std.testing.expect(Polarity.compatible(.neg, .pos));
    try std.testing.expect(Polarity.compatible(.null_, .null_));
    try std.testing.expect(!Polarity.compatible(.pos, .pos));
    try std.testing.expect(!Polarity.compatible(.neg, .neg));
    try std.testing.expect(!Polarity.compatible(.pos, .null_));
    try std.testing.expect(!Polarity.compatible(.null_, .pos));
    try std.testing.expect(!Polarity.compatible(.neg, .null_));
    try std.testing.expect(!Polarity.compatible(.null_, .neg));
}

test "execQueue: max_steps=1 fuses single pair" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const s_rays = [_]Ray{makePosConst("msg")};
    const a_rays = [_]Ray{makeNegConst("msg")};
    try c.addStar(.{ .rays = &s_rays, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });

    const result = try execQueue(&c, std.testing.allocator, .{ .max_steps = 1 });
    // Single-ray pair: fuses in 1 step, empty constellation → but we also hit max_steps.
    // The fusion happens on step 0 (steps increments after), loop checks steps < 1 → exits.
    try std.testing.expectEqual(@as(usize, 1), result.steps);
}

test "execQueue: linear flag is accepted" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();

    const result = try execQueue(&c, std.testing.allocator, .{ .max_steps = 10, .linear = true });
    try std.testing.expect(result.fixpoint);
}

// ═══════════════════════════════════════════════════════════════════════
// Phase 3: deeper edge cases, invariants, integration
// ═══════════════════════════════════════════════════════════════════════

test "unify: occurs check prevents infinite type" {
    const a = makeVar("X");
    const children = [_]Ray{makeVar("X")};
    const b = makeFunc(.null_, "f", &children);
    const err = unify(std.testing.allocator, a, b);
    try std.testing.expectError(error.OccursCheck, err);
}

test "unify: deeply nested func tree (3 levels)" {
    const inner_children = [_]Ray{makePosConst("leaf")};
    const inner = makeFunc(.pos, "g", &inner_children);
    const mid_children = [_]Ray{inner};
    const mid = makeFunc(.neg, "f", &mid_children);
    const var_tree_children = [_]Ray{makeVar("X")};
    const var_tree = makeFunc(.neg, "f", &var_tree_children);

    var sub = try unify(std.testing.allocator, mid, var_tree);
    defer sub.deinit();
    const bound = sub.apply(makeVar("X"));
    switch (bound) {
        .func => |f| {
            try std.testing.expectEqualStrings("g", f.name);
            try std.testing.expectEqual(@as(usize, 1), f.children.len);
        },
        .variable => return error.TestUnexpectedResult,
    }
}

test "unify: symmetric — var=const same as const=var" {
    var sub1 = try unify(std.testing.allocator, makeVar("X"), makePosConst("a"));
    defer sub1.deinit();
    var sub2 = try unify(std.testing.allocator, makePosConst("a"), makeVar("X"));
    defer sub2.deinit();
    try std.testing.expect(sub1.apply(makeVar("X")).eql(sub2.apply(makeVar("X"))));
}

test "Star: empty rays → tritSum = 0" {
    const s = Star{ .rays = &.{}, .mark = .state };
    try std.testing.expectEqual(@as(i8, 0), s.tritSum());
}

test "Constellation: stateCount and actionCount" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const r = [_]Ray{makePosConst("x")};
    try c.addStar(.{ .rays = &r, .mark = .state });
    try c.addStar(.{ .rays = &r, .mark = .action });
    try c.addStar(.{ .rays = &r, .mark = .state });
    try c.addStar(.{ .rays = &r, .mark = .action });
    try c.addStar(.{ .rays = &r, .mark = .state });
    try std.testing.expectEqual(@as(usize, 3), c.stateCount());
    try std.testing.expectEqual(@as(usize, 2), c.actionCount());
}

test "Constellation: tritSum over multiple stars" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const pos_r = [_]Ray{makePosConst("a")};
    const neg_r = [_]Ray{makeNegConst("b")};
    const null_r = [_]Ray{makeNullConst("c")};
    try c.addStar(.{ .rays = &pos_r, .mark = .state });
    try c.addStar(.{ .rays = &neg_r, .mark = .action });
    try c.addStar(.{ .rays = &null_r, .mark = .state });
    // +1 + -1 + 0 = 0, mod 3 = 0
    try std.testing.expectEqual(@as(i8, 0), c.tritSum());
}

test "fire: multiple compatible pairs picks first" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const s1 = [_]Ray{makePosConst("msg")};
    const s2 = [_]Ray{makePosConst("ping")};
    const a1 = [_]Ray{makeNegConst("msg")};
    const a2 = [_]Ray{makeNegConst("ping")};
    try c.addStar(.{ .rays = &s1, .mark = .state });
    try c.addStar(.{ .rays = &s2, .mark = .state });
    try c.addStar(.{ .rays = &a1, .mark = .action });
    try c.addStar(.{ .rays = &a2, .mark = .action });
    const result = try fire(&c, std.testing.allocator);
    try std.testing.expect(result.fired);
    // First state (idx=0) with first action (idx=2)
    try std.testing.expectEqual(@as(usize, 0), result.state_idx.?);
    try std.testing.expectEqual(@as(usize, 2), result.action_idx.?);
}

test "interactionCount: multiple overlapping pairs" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const s1 = [_]Ray{makePosConst("x")};
    const a1 = [_]Ray{makeNegConst("x")};
    try c.addStar(.{ .rays = &s1, .mark = .state });
    try c.addStar(.{ .rays = &s1, .mark = .state });
    try c.addStar(.{ .rays = &a1, .mark = .action });
    // 2 states × 1 action = 2 interactions
    const n = try interactionCount(&c, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "exec: fixpoint on no-interaction constellation" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const r1 = [_]Ray{makePosConst("a")};
    const r2 = [_]Ray{makePosConst("b")};
    try c.addStar(.{ .rays = &r1, .mark = .state });
    try c.addStar(.{ .rays = &r2, .mark = .state }); // no action stars
    const result = try exec(&c, std.testing.allocator, 50);
    try std.testing.expect(result.fixpoint);
    try std.testing.expectEqual(@as(usize, 0), result.steps);
}

test "exec: fuel exhausted on always-interacting pair" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const s = [_]Ray{makePosConst("loop")};
    const a = [_]Ray{makeNegConst("loop")};
    try c.addStar(.{ .rays = &s, .mark = .state });
    try c.addStar(.{ .rays = &a, .mark = .action });
    const result = try exec(&c, std.testing.allocator, 5);
    try std.testing.expect(!result.fixpoint);
    try std.testing.expectEqual(@as(usize, 5), result.steps);
}

test "Ban.ineq: after sub makes sides equal → violated" {
    const b = Ban{ .ineq = .{ makeVar("X"), makePosConst("a") } };
    var sub = Substitution.init(std.testing.allocator);
    defer sub.deinit();
    try sub.bind(.{ .name = "X" }, makePosConst("a"));
    const b2 = b.applySub(&sub);
    try std.testing.expect(b2.violated(std.testing.allocator));
}

test "Ban.ineq: after sub sides still differ → not violated" {
    const b = Ban{ .ineq = .{ makeVar("X"), makePosConst("a") } };
    var sub = Substitution.init(std.testing.allocator);
    defer sub.deinit();
    try sub.bind(.{ .name = "X" }, makePosConst("b"));
    const b2 = b.applySub(&sub);
    try std.testing.expect(!b2.violated(std.testing.allocator));
}

test "VarCounter: indices are unique and contiguous" {
    var vc = VarCounter{};
    const a = vc.fresh("v");
    const b = vc.fresh("v");
    const c_var = vc.fresh("w");
    try std.testing.expectEqual(@as(u16, 0), a.index.?);
    try std.testing.expectEqual(@as(u16, 1), b.index.?);
    try std.testing.expectEqual(@as(u16, 2), c_var.index.?);
    try std.testing.expectEqualStrings("w", c_var.name);
}

test "collectVars: nested func tree finds deep variables" {
    const inner = [_]Ray{makeVar("Y")};
    const outer = [_]Ray{makeFunc(.pos, "g", &inner)};
    const tree = makeFunc(.neg, "f", &outer);
    var out = std.ArrayListUnmanaged(Ray.VarId).empty;
    defer out.deinit(std.testing.allocator);
    try collectVars(tree, &out, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("Y", out.items[0].name);
}

test "unifyMatchable: different polarities, same name → succeeds" {
    const a = makePosConst("test");
    const b = makeNegConst("test");
    var sub = try unifyMatchable(std.testing.allocator, a, b);
    defer sub.deinit();
    // Should succeed because matchable ignores polarity
}

test "Star.bansCoherent: ban violated by equal constants" {
    const b = [_]Ban{.{ .ineq = .{ makePosConst("same"), makePosConst("same") } }};
    const rays = [_]Ray{makePosConst("x")};
    const s = Star{ .rays = &rays, .bans = &b, .mark = .state };
    try std.testing.expect(!s.bansCoherent(std.testing.allocator));
}

test "execQueue: multi-ray fusion preserves remaining rays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var c = Constellation.init(alloc);
    // State: [+ev, +remain_s], Action: [-ev, +remain_a]
    // +ev/-ev fuse; fused star gets [+remain_s, +remain_a]
    const s = [_]Ray{ makePosConst("ev"), makePosConst("remain_s") };
    const a = [_]Ray{ makeNegConst("ev"), makePosConst("remain_a") };
    try c.addStar(.{ .rays = &s, .mark = .state });
    try c.addStar(.{ .rays = &a, .mark = .action });

    const result = try execQueue(&c, alloc, .{ .max_steps = 3 });
    // One fusion step, then fixpoint (no more state↔action interactions).
    try std.testing.expectEqual(@as(usize, 1), result.steps);
    try std.testing.expect(result.fixpoint);
    // Fused star should have 2 remaining rays.
    try std.testing.expectEqual(@as(usize, 1), c.stars.items.len);
    try std.testing.expectEqual(@as(usize, 2), c.stars.items[0].rays.len);
}

// ═══════════════════════════════════════════════════════════════════════
// Phase 4: deeper edge cases, invariants, error paths
// ═══════════════════════════════════════════════════════════════════════

test "Polarity.fromChar: explicit mapping" {
    try std.testing.expectEqual(Polarity.pos, Polarity.fromChar('+'));
    try std.testing.expectEqual(Polarity.neg, Polarity.fromChar('-'));
    try std.testing.expectEqual(Polarity.null_, Polarity.fromChar('~'));
    try std.testing.expectEqual(Polarity.null_, Polarity.fromChar('?')); // fallback
    try std.testing.expectEqual(Polarity.null_, Polarity.fromChar(0)); // zero byte
}

test "Ray.VarId.eql: indexed vs non-indexed" {
    const plain: Ray.VarId = .{ .name = "X" };
    const idx0: Ray.VarId = .{ .name = "X", .index = 0 };
    const idx1: Ray.VarId = .{ .name = "X", .index = 1 };
    try std.testing.expect(!plain.eql(idx0)); // null != 0
    try std.testing.expect(!idx0.eql(idx1)); // 0 != 1
    try std.testing.expect(idx0.eql(idx0));
    try std.testing.expect(plain.eql(plain));
}

test "Ray.eql: func with children vs without" {
    const leaf = makePosConst("a");
    const children = [_]Ray{leaf};
    const with_child = makeFunc(.pos, "f", &children);
    const no_child = makePosConst("f"); // 0-arity
    try std.testing.expect(!with_child.eql(no_child));
}

test "Ray.compatibleWith: same arity required" {
    const children_a = [_]Ray{makeVar("X")};
    const children_b = [_]Ray{ makeVar("X"), makeVar("Y") };
    const a = makeFunc(.pos, "f", &children_a);
    const b = makeFunc(.neg, "f", &children_b);
    try std.testing.expect(!a.compatibleWith(b)); // arity 1 vs 2
}

test "Ray.compatibleWith: variables are never compatible" {
    const v1 = makeVar("X");
    const v2 = makeVar("Y");
    const c = makePosConst("a");
    try std.testing.expect(!v1.compatibleWith(v2));
    try std.testing.expect(!v1.compatibleWith(c));
    try std.testing.expect(!c.compatibleWith(v1));
}

test "Substitution: lookup returns null for unbound var" {
    var sub = Substitution.init(std.testing.allocator);
    defer sub.deinit();
    try std.testing.expectEqual(@as(?Ray, null), sub.lookup(.{ .name = "X" }));
}

test "Substitution: chained binding walk" {
    var sub = Substitution.init(std.testing.allocator);
    defer sub.deinit();
    try sub.bind(.{ .name = "X" }, makeVar("Y"));
    try sub.bind(.{ .name = "Y" }, makePosConst("final"));
    // X → Y → final
    const result = sub.apply(makeVar("X"));
    try std.testing.expect(result.eql(makePosConst("final")));
}

test "unify: clash on different names (func vs func)" {
    const a = makePosConst("alpha");
    const b = makePosConst("beta");
    try std.testing.expectError(error.Clash, unify(std.testing.allocator, a, b));
}

test "unify: clash on different arities" {
    const c1 = [_]Ray{makeVar("X")};
    const c2 = [_]Ray{ makeVar("X"), makeVar("Y") };
    const a = makeFunc(.pos, "f", &c1);
    const b = makeFunc(.pos, "f", &c2);
    try std.testing.expectError(error.Clash, unify(std.testing.allocator, a, b));
}

test "unify: two distinct variables bind to each other" {
    var sub = try unify(std.testing.allocator, makeVar("X"), makeVar("Y"));
    defer sub.deinit();
    // After unification, applying sub to X should give Y (or vice versa)
    const rx = sub.apply(makeVar("X"));
    const ry = sub.apply(makeVar("Y"));
    try std.testing.expect(rx.eql(ry));
}

test "unify: func with var children — cross-binding" {
    const c_a = [_]Ray{makeVar("X")};
    const c_b = [_]Ray{makePosConst("val")};
    const a = makeFunc(.pos, "f", &c_a);
    const b = makeFunc(.pos, "f", &c_b);
    var sub = try unify(std.testing.allocator, a, b);
    defer sub.deinit();
    try std.testing.expect(sub.apply(makeVar("X")).eql(makePosConst("val")));
}

test "occursIn: variable not in constant → false" {
    try std.testing.expect(!occursIn(.{ .name = "X" }, makePosConst("a")));
}

test "occursIn: variable in deeply nested tree → true" {
    const leaf = [_]Ray{makeVar("X")};
    const inner = [_]Ray{makeFunc(.pos, "g", &leaf)};
    const tree = makeFunc(.neg, "f", &inner);
    try std.testing.expect(occursIn(.{ .name = "X" }, tree));
}

test "Ban.incomp: violated when sides can unify" {
    const b = Ban{ .incomp = .{ makeVar("X"), makePosConst("a") } };
    try std.testing.expect(b.violated(std.testing.allocator));
}

test "Ban.incomp: not violated when sides cannot unify" {
    const b = Ban{ .incomp = .{ makePosConst("a"), makePosConst("b") } };
    try std.testing.expect(!b.violated(std.testing.allocator));
}

test "Star.tritSum: mixed polarities cancel correctly" {
    const rays = [_]Ray{ makePosConst("a"), makeNegConst("b"), makePosConst("c") };
    const s = Star{ .rays = &rays, .mark = .state };
    // +1 + -1 + +1 = +1, mod 3 = 1
    try std.testing.expectEqual(@as(i8, 1), s.tritSum());
}

test "Star.bansCoherent: no bans → always coherent" {
    const rays = [_]Ray{makePosConst("x")};
    const s = Star{ .rays = &rays, .mark = .state };
    try std.testing.expect(s.bansCoherent(std.testing.allocator));
}

test "Star.bansCoherent: incomp ban satisfied" {
    const b = [_]Ban{.{ .incomp = .{ makePosConst("a"), makePosConst("b") } }};
    const rays = [_]Ray{makePosConst("x")};
    const s = Star{ .rays = &rays, .bans = &b, .mark = .state };
    try std.testing.expect(s.bansCoherent(std.testing.allocator));
}

test "freshenRay: produces fresh variable indices" {
    var vc = VarCounter{};
    const original = makeVar("X");
    const result = try freshenRay(original, &vc, std.testing.allocator);
    var sub = result.sub;
    defer sub.deinit();
    // The fresh var should have index 0 (first call)
    const freshened = result.ray;
    switch (freshened) {
        .variable => |v| {
            try std.testing.expectEqualStrings("X", v.name);
            try std.testing.expectEqual(@as(?u16, 0), v.index);
        },
        .func => return error.TestUnexpectedResult,
    }
}

test "freshenRay: two calls produce different indices" {
    var vc = VarCounter{};
    const r1 = try freshenRay(makeVar("X"), &vc, std.testing.allocator);
    var s1 = r1.sub;
    defer s1.deinit();
    const r2 = try freshenRay(makeVar("X"), &vc, std.testing.allocator);
    var s2 = r2.sub;
    defer s2.deinit();
    try std.testing.expect(!r1.ray.eql(r2.ray)); // different indices
}

test "findFusionCandidates: returns multiple candidates" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const s = [_]Ray{makePosConst("x")};
    const a = [_]Ray{makeNegConst("x")};
    try c.addStar(.{ .rays = &s, .mark = .state });
    try c.addStar(.{ .rays = &s, .mark = .state });
    try c.addStar(.{ .rays = &a, .mark = .action });
    var cands = try findFusionCandidates(&c, std.testing.allocator);
    defer cands.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), cands.items.len);
}

test "findFusionCandidates: empty when no interactions" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const s = [_]Ray{makePosConst("x")};
    try c.addStar(.{ .rays = &s, .mark = .state });
    try c.addStar(.{ .rays = &s, .mark = .state }); // no action stars
    var cands = try findFusionCandidates(&c, std.testing.allocator);
    defer cands.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cands.items.len);
}

test "execQueue: fixpoint when no interactions" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const s = [_]Ray{makePosConst("lonely")};
    try c.addStar(.{ .rays = &s, .mark = .state });
    const result = try execQueue(&c, std.testing.allocator, .{ .max_steps = 100 });
    try std.testing.expect(result.fixpoint);
    try std.testing.expectEqual(@as(usize, 0), result.steps);
}

test "execQueue: event callback counts fire+fixpoint events" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const s = [_]Ray{makePosConst("ev")};
    const a = [_]Ray{makeNegConst("ev")};
    try c.addStar(.{ .rays = &s, .mark = .state });
    try c.addStar(.{ .rays = &a, .mark = .action });

    const S = struct {
        var count: usize = 0;
        fn handler(_: ExecEvent) void {
            count += 1;
        }
    };
    S.count = 0;
    const result = try execQueue(&c, std.testing.allocator, .{
        .max_steps = 10,
        .on_event = &S.handler,
    });
    // Real fusion: +ev/-ev annihilate → 1 fire_step + 1 fixpoint = 2 events.
    try std.testing.expectEqual(@as(usize, 1), result.steps);
    try std.testing.expect(result.fixpoint);
    try std.testing.expectEqual(@as(usize, 2), S.count);
}

test "interactionCount: zero for action-only constellation" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    const a = [_]Ray{makeNegConst("x")};
    try c.addStar(.{ .rays = &a, .mark = .action });
    try c.addStar(.{ .rays = &a, .mark = .action });
    const n = try interactionCount(&c, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "Constellation: empty constellation invariants" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.stateCount());
    try std.testing.expectEqual(@as(usize, 0), c.actionCount());
    try std.testing.expectEqual(@as(i8, 0), c.tritSum());
}

test "Constellation: GF(3) tritSum conservation — balanced" {
    var c = Constellation.init(std.testing.allocator);
    defer c.deinit();
    // +1 + -1 + 0 = 0
    const r1 = [_]Ray{makePosConst("a")};
    const r2 = [_]Ray{makeNegConst("b")};
    const r3 = [_]Ray{makeNullConst("c")};
    try c.addStar(.{ .rays = &r1, .mark = .state });
    try c.addStar(.{ .rays = &r2, .mark = .action });
    try c.addStar(.{ .rays = &r3, .mark = .state });
    try std.testing.expectEqual(@as(i8, 0), c.tritSum());
}

test "collectVars: no duplicates even with repeated vars" {
    const rays = [_]Ray{ makeVar("X"), makeVar("X"), makeVar("Y") };
    const tree = makeFunc(.pos, "f", &rays);
    var out = std.ArrayListUnmanaged(Ray.VarId).empty;
    defer out.deinit(std.testing.allocator);
    try collectVars(tree, &out, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // X and Y only
}

test "unifyMatchable: same-polarity same-name → succeeds" {
    const a = makePosConst("test");
    const b = makePosConst("test");
    var sub = try unifyMatchable(std.testing.allocator, a, b);
    defer sub.deinit();
    try std.testing.expectEqual(@as(usize, 0), sub.bindings.items.len); // no bindings needed
}

test "unifyMatchable: different names → Clash" {
    try std.testing.expectError(error.Clash, unifyMatchable(std.testing.allocator, makePosConst("a"), makePosConst("b")));
}

test "unifyMatchable: var binds to func ignoring polarity" {
    var sub = try unifyMatchable(std.testing.allocator, makeVar("X"), makeNegConst("val"));
    defer sub.deinit();
    const bound = sub.apply(makeVar("X"));
    switch (bound) {
        .func => |f| try std.testing.expectEqualStrings("val", f.name),
        .variable => return error.TestUnexpectedResult,
    }
}

// ═══════════════════════════════════════════════════════════════════════
// P0 FIX VERIFICATION TESTS — deep substitution + real fusion
// ═══════════════════════════════════════════════════════════════════════

test "Substitution.apply: deep penetration into Func children" {
    // Use arena to handle allocations from apply's deep penetration.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var sub = Substitution.init(alloc);
    try sub.bind(.{ .name = "X" }, makePosConst("hello"));

    const inner = [_]Ray{makeVar("X")};
    const tree = makeFunc(.pos, "g", &inner);
    const result = sub.apply(tree);
    switch (result) {
        .func => |f| {
            try std.testing.expectEqual(@as(usize, 1), f.children.len);
            switch (f.children[0]) {
                .func => |child| try std.testing.expectEqualStrings("hello", child.name),
                .variable => return error.TestUnexpectedResult,
            }
        },
        .variable => return error.TestUnexpectedResult,
    }
}

test "Substitution.apply: doubly-nested penetration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var sub = Substitution.init(alloc);
    try sub.bind(.{ .name = "Y" }, makeNegConst("deep"));

    const leaf = [_]Ray{makeVar("Y")};
    const mid = [_]Ray{makeFunc(.pos, "g", &leaf)};
    const tree = makeFunc(.pos, "h", &mid);
    const result = sub.apply(tree);
    switch (result) {
        .func => |h| {
            switch (h.children[0]) {
                .func => |g| {
                    switch (g.children[0]) {
                        .func => |d| try std.testing.expectEqualStrings("deep", d.name),
                        .variable => return error.TestUnexpectedResult,
                    }
                },
                .variable => return error.TestUnexpectedResult,
            }
        },
        .variable => return error.TestUnexpectedResult,
    }
}

test "execQueue: fusion with variable binding propagates globally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var c = Constellation.init(alloc);

    const s1_children = [_]Ray{makeVar("X")};
    const s1_rays = [_]Ray{makeFunc(.pos, "f", &s1_children)};
    const a_children = [_]Ray{makePosConst("hello")};
    const a_rays = [_]Ray{makeFunc(.neg, "f", &a_children)};
    const s2_children = [_]Ray{makeVar("X")};
    const s2_rays = [_]Ray{makeFunc(.pos, "g", &s2_children)};

    try c.addStar(.{ .rays = &s1_rays, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });
    try c.addStar(.{ .rays = &s2_rays, .mark = .state });

    const result = try execQueue(&c, alloc, .{ .max_steps = 10 });
    try std.testing.expect(result.fixpoint);
    try std.testing.expectEqual(@as(usize, 1), c.stars.items.len);
    const remaining = c.stars.items[0];
    try std.testing.expectEqual(@as(usize, 1), remaining.rays.len);
    switch (remaining.rays[0]) {
        .func => |f| {
            try std.testing.expectEqualStrings("g", f.name);
            try std.testing.expectEqual(@as(usize, 1), f.children.len);
            switch (f.children[0]) {
                .func => |child| try std.testing.expectEqualStrings("hello", child.name),
                .variable => return error.TestUnexpectedResult,
            }
        },
        .variable => return error.TestUnexpectedResult,
    }
}

test "execQueue: two-step chain fusion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var c = Constellation.init(alloc);

    const s_rays = [_]Ray{ makePosConst("a"), makeFunc(.pos, "b", &[_]Ray{makeVar("X")}) };
    const a1_rays = [_]Ray{makeNegConst("a")};
    const a2_rays = [_]Ray{makeFunc(.neg, "b", &[_]Ray{makePosConst("world")})};

    try c.addStar(.{ .rays = &s_rays, .mark = .state });
    try c.addStar(.{ .rays = &a1_rays, .mark = .action });
    try c.addStar(.{ .rays = &a2_rays, .mark = .action });

    const result = try execQueue(&c, alloc, .{ .max_steps = 10 });
    try std.testing.expect(result.fixpoint);
    try std.testing.expectEqual(@as(usize, 2), result.steps);
    try std.testing.expectEqual(@as(usize, 0), c.stars.items.len);
}

test "execQueue: ban violation prevents fusion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var c = Constellation.init(alloc);

    const s_children = [_]Ray{makeVar("X")};
    const s_rays = [_]Ray{makeFunc(.pos, "f", &s_children)};
    const bans = [_]Ban{.{ .ineq = .{ makeVar("X"), makePosConst("hello") } }};
    const a_children = [_]Ray{makePosConst("hello")};
    const a_rays = [_]Ray{makeFunc(.neg, "f", &a_children)};

    try c.addStar(.{ .rays = &s_rays, .bans = &bans, .mark = .state });
    try c.addStar(.{ .rays = &a_rays, .mark = .action });

    const result = try execQueue(&c, alloc, .{ .max_steps = 5 });
    try std.testing.expect(!result.fixpoint);
    try std.testing.expectEqual(@as(usize, 5), result.steps);
    try std.testing.expectEqual(@as(usize, 2), c.stars.items.len);
}

test "execQueue: multi-ray fusion preserves remaining rays (arena)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var c = Constellation.init(alloc);
    const s = [_]Ray{ makePosConst("ev"), makePosConst("remain_s") };
    const a = [_]Ray{ makeNegConst("ev"), makePosConst("remain_a") };
    try c.addStar(.{ .rays = &s, .mark = .state });
    try c.addStar(.{ .rays = &a, .mark = .action });

    const result = try execQueue(&c, alloc, .{ .max_steps = 3 });
    try std.testing.expectEqual(@as(usize, 1), result.steps);
    try std.testing.expect(result.fixpoint);
    try std.testing.expectEqual(@as(usize, 1), c.stars.items.len);
    try std.testing.expectEqual(@as(usize, 2), c.stars.items[0].rays.len);
}

// ═══════════════════════════════════════════════════════════════════════
// P1: PROCESS TESTS
// ═══════════════════════════════════════════════════════════════════════

test "constellationEql: identical constellations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var a = Constellation.init(alloc);
    var b = Constellation.init(alloc);
    const rays = [_]Ray{makePosConst("x")};
    try a.addStar(.{ .rays = &rays, .mark = .action });
    try b.addStar(.{ .rays = &rays, .mark = .action });
    try std.testing.expect(constellationEql(&a, &b));
}

test "constellationEql: different constellations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var a = Constellation.init(alloc);
    var b = Constellation.init(alloc);
    const rays_a = [_]Ray{makePosConst("x")};
    const rays_b = [_]Ray{makePosConst("y")};
    try a.addStar(.{ .rays = &rays_a, .mark = .action });
    try b.addStar(.{ .rays = &rays_b, .mark = .action });
    try std.testing.expect(!constellationEql(&a, &b));
}

test "process: fixpoint on stable constellation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var c = Constellation.init(alloc);
    const rays = [_]Ray{makePosConst("stable")};
    try c.addStar(.{ .rays = &rays, .mark = .action });

    const result = try process(&c, alloc, .{ .max_steps = 5 });
    try std.testing.expect(result.fixpoint);
    try std.testing.expectEqual(@as(usize, 0), result.steps);
    try std.testing.expectEqual(@as(usize, 1), c.stars.items.len);
}

test "process: annihilation reaches fixpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var c = Constellation.init(alloc);
    const s = [_]Ray{makePosConst("a")};
    const a = [_]Ray{makeNegConst("a")};
    try c.addStar(.{ .rays = &s, .mark = .state });
    try c.addStar(.{ .rays = &a, .mark = .action });

    const result = try process(&c, alloc, .{ .max_steps = 10 });
    try std.testing.expect(result.fixpoint);
    try std.testing.expectEqual(@as(usize, 0), c.stars.items.len);
}

test "process: step limit reached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var c = Constellation.init(alloc);
    const s = [_]Ray{makePosConst("a")};
    try c.addStar(.{ .rays = &s, .mark = .state });

    const result = try process(&c, alloc, .{ .max_steps = 1 });
    try std.testing.expect(result.fixpoint);
    try std.testing.expectEqual(@as(usize, 0), result.steps);
}

// ═══════════════════════════════════════════════════════════════════════
// P1: FILE LOADER / USE IMPORT TESTS
// ═══════════════════════════════════════════════════════════════════════

test "defaultLoader: returns empty constellation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const c = try defaultLoader("nonexistent.sg", alloc);
    try std.testing.expectEqual(@as(usize, 0), c.stars.items.len);
}

test "useImport: merges imported stars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var target = Constellation.init(alloc);
    const existing = [_]Ray{makePosConst("local")};
    try target.addStar(.{ .rays = &existing, .mark = .action });

    const customLoader = struct {
        fn load(_: []const u8, a: std.mem.Allocator) FileLoaderError!Constellation {
            var imported = Constellation.init(a);
            const rays = [_]Ray{makePosConst("imported")};
            imported.addStar(.{ .rays = &rays, .mark = .action }) catch return FileLoaderError.OutOfMemory;
            return imported;
        }
    }.load;

    try useImport(&target, "test.sg", alloc, customLoader);
    try std.testing.expectEqual(@as(usize, 2), target.stars.items.len);
}

test "useImport: default loader adds nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var target = Constellation.init(alloc);
    const existing = [_]Ray{makePosConst("local")};
    try target.addStar(.{ .rays = &existing, .mark = .action });

    try useImport(&target, "empty.sg", alloc, defaultLoader);
    try std.testing.expectEqual(@as(usize, 1), target.stars.items.len);
}

// ═══════════════════════════════════════════════════════════════════════
// P2 TESTS: Stack notation + Explicit substitution
// ═══════════════════════════════════════════════════════════════════════

test "stackApply: func head appends args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const head = makePosConst("f");
    const args = [_]Ray{ makePosConst("a"), makePosConst("b") };
    const result = try stackApply(head, &args, alloc);
    try std.testing.expectEqualStrings("f", result.func.name);
    try std.testing.expectEqual(Polarity.pos, result.func.polarity);
    try std.testing.expectEqual(@as(usize, 2), result.func.children.len);
    try std.testing.expectEqualStrings("a", result.func.children[0].func.name);
    try std.testing.expectEqualStrings("b", result.func.children[1].func.name);
}

test "stackApply: func head with existing children appends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const existing = [_]Ray{makePosConst("x")};
    const head = makeFunc(.neg, "g", &existing);
    const args = [_]Ray{makePosConst("y")};
    const result = try stackApply(head, &args, alloc);
    try std.testing.expectEqualStrings("g", result.func.name);
    try std.testing.expectEqual(Polarity.neg, result.func.polarity);
    try std.testing.expectEqual(@as(usize, 2), result.func.children.len);
    try std.testing.expectEqualStrings("x", result.func.children[0].func.name);
    try std.testing.expectEqualStrings("y", result.func.children[1].func.name);
}

test "stackApply: var head wraps in %apply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const head = makeVar("X");
    const args = [_]Ray{ makePosConst("a"), makePosConst("b") };
    const result = try stackApply(head, &args, alloc);
    try std.testing.expectEqualStrings("%apply", result.func.name);
    try std.testing.expectEqual(Polarity.null_, result.func.polarity);
    try std.testing.expectEqual(@as(usize, 3), result.func.children.len);
    try std.testing.expectEqualStrings("X", result.func.children[0].variable.name);
    try std.testing.expectEqualStrings("a", result.func.children[1].func.name);
    try std.testing.expectEqualStrings("b", result.func.children[2].func.name);
}

test "stackApply: single arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const head = makeNullConst("h");
    const args = [_]Ray{makeVar("Z")};
    const result = try stackApply(head, &args, alloc);
    try std.testing.expectEqualStrings("h", result.func.name);
    try std.testing.expectEqual(@as(usize, 1), result.func.children.len);
    try std.testing.expectEqualStrings("Z", result.func.children[0].variable.name);
}

test "applyExplicitSubst: basic variable replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ray = makeVar("X");
    var bindings = [_]Binding{.{ .var_id = .{ .name = "X" }, .term = makePosConst("hello") }};
    const result = applyExplicitSubst(ray, &bindings, alloc);
    try std.testing.expectEqualStrings("hello", result.func.name);
    try std.testing.expectEqual(Polarity.pos, result.func.polarity);
}

test "applyExplicitSubst: no match leaves var unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ray = makeVar("Y");
    var bindings = [_]Binding{.{ .var_id = .{ .name = "X" }, .term = makePosConst("hello") }};
    const result = applyExplicitSubst(ray, &bindings, alloc);
    try std.testing.expectEqualStrings("Y", result.variable.name);
}

test "applyExplicitSubst: deep penetration into func children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const children = [_]Ray{ makeVar("X"), makePosConst("keep") };
    const ray = makeFunc(.pos, "wrapper", &children);
    var bindings = [_]Binding{.{ .var_id = .{ .name = "X" }, .term = makeNegConst("replaced") }};
    const result = applyExplicitSubst(ray, &bindings, alloc);
    try std.testing.expectEqualStrings("wrapper", result.func.name);
    try std.testing.expectEqualStrings("replaced", result.func.children[0].func.name);
    try std.testing.expectEqualStrings("keep", result.func.children[1].func.name);
}

test "applyExplicitSubst: multiple bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const children = [_]Ray{ makeVar("X"), makeVar("Y") };
    const ray = makeFunc(.pos, "pair", &children);
    var bindings = [_]Binding{
        .{ .var_id = .{ .name = "X" }, .term = makePosConst("one") },
        .{ .var_id = .{ .name = "Y" }, .term = makePosConst("two") },
    };
    const result = applyExplicitSubst(ray, &bindings, alloc);
    try std.testing.expectEqualStrings("one", result.func.children[0].func.name);
    try std.testing.expectEqualStrings("two", result.func.children[1].func.name);
}

test "applyExplicitSubstStar: substitutes across all rays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const rays = [_]Ray{ makeVar("X"), makePosConst("lit"), makeVar("X") };
    const star = Star{ .rays = &rays, .mark = .action };
    var bindings = [_]Binding{.{ .var_id = .{ .name = "X" }, .term = makeNegConst("val") }};
    const result = try applyExplicitSubstStar(star, &bindings, alloc);
    try std.testing.expectEqual(@as(usize, 3), result.rays.len);
    try std.testing.expectEqualStrings("val", result.rays[0].func.name);
    try std.testing.expectEqualStrings("lit", result.rays[1].func.name);
    try std.testing.expectEqualStrings("val", result.rays[2].func.name);
    try std.testing.expectEqual(Mark.action, result.mark);
}

test "applyExplicitSubstConstellation: substitutes across all stars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var c = Constellation.init(alloc);
    const rays1 = [_]Ray{makeVar("A")};
    const rays2 = [_]Ray{ makePosConst("fixed"), makeVar("A") };
    try c.addStar(.{ .rays = &rays1, .mark = .action });
    try c.addStar(.{ .rays = &rays2, .mark = .state });

    var bindings = [_]Binding{.{ .var_id = .{ .name = "A" }, .term = makePosConst("replaced") }};
    try applyExplicitSubstConstellation(&c, &bindings);

    try std.testing.expectEqualStrings("replaced", c.stars.items[0].rays[0].func.name);
    try std.testing.expectEqualStrings("fixed", c.stars.items[1].rays[0].func.name);
    try std.testing.expectEqualStrings("replaced", c.stars.items[1].rays[1].func.name);
}

test "stackApply + applyExplicitSubst combo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build <f X> then substitute X := hello
    const head = makePosConst("f");
    const args = [_]Ray{makeVar("X")};
    const stacked = try stackApply(head, &args, alloc);
    var bindings = [_]Binding{.{ .var_id = .{ .name = "X" }, .term = makePosConst("hello") }};
    const result = applyExplicitSubst(stacked, &bindings, alloc);
    try std.testing.expectEqualStrings("f", result.func.name);
    try std.testing.expectEqual(@as(usize, 1), result.func.children.len);
    try std.testing.expectEqualStrings("hello", result.func.children[0].func.name);
}
