# agent-o-nanoclj — current state analysis

> Snapshot: 2026-04-25. Source of truth: `src/loop.zig` + `src/loop/*.zig`.

## 1. The 10-rung architecture

The agent-o-nanoclj feedback loop is organized as 10 numbered rungs, each adding one layer of capability. Rungs compose vertically — higher rungs consume lower ones — and every rung lives in its own `src/loop/<name>.zig` file.

| Rung | Module         | Primitive added                                      |
|------|---------------|------------------------------------------------------|
| 1    | `agent.zig`    | **Agent** — named unit of computation: `(name, id, AgentFn, state?, trace_slot?)`. Stateless invocation path for testing. |
| 2    | `trace.zig`    | **TraceStore** — append-only event log. `TraceEvent` records `(invoke_id, step, agent_id, input, output?, ts_mono, tags)`. Monotonic ids, per-invocation step numbering, subscriber callbacks. Pipe-delimited JSONL persistence. |
| 3    | `topology.zig` | **Topology** — mutable DAG of Agents + Edges. `invoke(topo, trace, start, input)` runs synchronous DFS, records every step. Cycle detection caps at depth 1024. |
| 4    | `eval.zig`     | **Evaluator** — individual (`Value → f32`), comparative (`(Value, Value) → Preference`), summary (`[]Value → f32`). Produces a **Verdict** (tagged union, see §7). Runners: `scoreOne`, `scorePair`, `scoreMany`, `tryAny`. |
| 5    | `experiment.zig` / `dataset.zig` | **Experiment** — topology + dataset + evaluators + start agent. `run()` invokes once per example, applies evaluators, returns a **Report** with per-example verdicts and aggregate pass/fail counts. |
| 6    | `checkpoint.zig` | **Checkpoint** — unified save/restore across trace + action log + telemetry. Framed as `# loop-checkpoint v1` sections. Individual rung JSONL encoders are composed under one write/load surface. |
| 7    | `feedback.zig` | **Feedback-loop closure** — `cycleUntil(experiment, target, revise, stop, max_iters)` iterates run → aggregate verdicts → revise agent state → loop. Also `cycleUntilMulti` (multiple targets) and `cycleUntilFixedPoint`. CycleResult carries `passRateTrajectory()`, `lastDelta()`, `isDiverging(window)`. |
| 8    | `tool.zig`     | **Tool + ToolRegistry** — named side-effect-free functions (`Value → Value`) registered in a mutable registry. Agents can call tools via `registry.call(name, input)`. |
| 9    | `action.zig`   | **Action + ActionLog** — hooks that run post-invocation for telemetry/dataset capture/webhooks. Each produces an `ActionResult` recorded in an append-only log. `runActionsOnInvocation` maps actions over a trace. |
| 10   | `telemetry.zig`| **TelemetrySink** — named time-series of `Sample{ts_ns, value, tags}`. `record()`, `aggregate(window)`, `aggregateAll()`. Convenience ingesters for Verdicts and RunInfo. JSONL persistence. |

**Cross-cutting extensions** (not numbered):
- **Gradient** (`gradient.zig`) — F_coplay via finite-difference ∂pass_rate/∂state.
- **Cycle combinator** (`cycle.zig`) — unified `Step × Stop × Frontier → Trajectory` (§6.3).
- **Curricula** (`curricula.zig`) — concrete curricula landing on the combinator stack.
- **Skill registry** (`skill.zig` + `builtins.zig` + `bench_skills.zig` + `parallel_skills.zig`) — SDF-style Clojure-callable extension surface.

## 2. Functorial framing: F_play, F_witness, F_coplay

The loop comment header declares the categorical structure:

```
F_play   : Topology → Trace               (invoke / Rung 3)
F_witness: Trace    → Verdict / pass-rate  (eval, experiment / Rungs 4–5)
F_coplay : ∇(rate)  → Topology'           (gradient + revise / Rung 7 + gradient)
```

**GF(3) closure**: `F_coplay ∘ F_witness ∘ F_play : Topology → Topology'`.

- **F_play** is `topology.invoke()` — takes a Topology + input, produces a Trace.
- **F_witness** is `experiment.run()` → `eval.scoreOne/scorePair/scoreMany` — takes Traces, produces Verdicts and a Report with a pass rate.
- **F_coplay** is realized two ways:
  1. **ReviseFn** (hand-coded): `(prior_state, verdicts) → new_state` in `feedback.cycleUntil`.
  2. **Gradient** (auto-derived): 1-sided finite difference `∂pass_rate/∂state ≈ L(s+1) − L(s)` in `gradient.traceGradient`, followed by `state += round(lr * partial)` in `gradient.cycleByGradient`. Gradient norm convergence checks included.

The composition closes the world: a single nanoclj process iterates topology → trace → verdict → revise → topology'.

## 3. Skill registry

**Shape**: `Skill = { name: []const u8, doc: []const u8, body: SkillFn }` where `SkillFn` is the standard nanoclj builtin signature `(args, gc, env, res) → !Value`.

**Registration**: Each `src/loop/*.zig` submodule that wants REPL exposure declares `pub const skills: []const Skill = &.{…}`. The umbrella `loop.zig` folds them at comptime:

```zig
pub const skills: []const Skill = skill.combine(
    skill.combine(&builtins.skills, &bench_skills.skills),
    &parallel_skills.skills,
);
```

**Operations**:
- `combine(a, b)` — comptime monoid sum (slice concatenation). Associative.
- `lookup(skills, name)` — O(n) linear scan by name. Returns `?*const Skill`.

**SDF properties** (per Sussman & Hanson):
- Generic dispatch on name (predicate dispatch).
- Egalitarian data — Skills are first-class structs, sliceable/filterable.
- Combinator-closed — `combine` is a fold; adding a submodule adds one term.
- Layered — `doc` rides along as an attribute layer.

**Current skill sources**:
- `builtins.zig` — 2 skills: `loop-version`, `loop-test-count`.
- `bench_skills.zig` — 9 skills in 3 embarrassment triads (fib25 alloc, reader alloc ratio, tight loop ns/iter) under GF(3) triadic-load protocol.
- `parallel_skills.zig` — 3 skills: cross-runtime comparison (nano-vs-bb ratio, installed runtimes, jank status).

**Total registered skills**: 14 (2 + 9 + 3).

## 4. Curricula

All curricula live in `curricula.zig` and use `Step.custom` or `Step.peer_pool` from the cycle combinator. Each is self-contained — no edits to `feedback.zig`, `cycle.zig`, or `experiment.zig` required.

### 4.1 Law-merged Nash

- **Anchor**: `goblins-adapter/propagator-nash.scm:140` — `merge-with-law: Merge × Law → Merge'`.
- **Setup**: N agents each carry an i48 state projected to a GF(3) trit via `stateToTrit(state)` (state mod 3 mapped to {-1, 0, +1}).
- **Step body** (`lawMergeStep`): collects every agent's trit, checks GF(3) closure (sum ≡ 0 mod 3). If violated, nudges the last agent's state by +1. Guaranteed to converge within ≤2 nudges for 3 agents.
- **Fixed point**: when all trits sum to 0 mod 3, the step is a no-op.

### 4.2 Solo-MAGICORE

- **Reference**: Kumar et al. 2024, "MAGICORE: Multi-Agent Iteration for Coarse-to-fine Refinement".
- **Setup**: Solver/Reviewer/Refiner triad. Solver state is an i48 interpreted as a 5-digit "reasoning chain". PRM (process reward model) scores each digit as `digit/9.0`.
- **Verdict variant**: `Verdict.vector` — per-step f32 scores. `primaryScore()` returns the mean, but the refiner reads the raw vector for step-wise repair.
- **Step body** (`magicoreRefineStep`): finds the worst-scoring digit, bumps its place value by +1. Converges when all digits ≥ 7 (score ≥ 7/9 ≈ 0.78).

### 4.3 Evaluator-Optimizer

- **Pattern**: mirrors mcp-agent / PraisonAI optimizer.
- **Verdict variant**: `Verdict.record { score: f32, feedback: []const u8 }`. The feedback string carries directional information a pure scalar can't: "raise", "OK", or "lower" (overshoot recovery).
- **Step body** (`evalOptimizerStep`): reads the last output, computes a normalized score, dispatches on the feedback string. "raise" → state += 5, "lower" → state -= 5, "OK" → no-op.
- **Tests**: both under-shoot (seed=0, converge to ≥95) and overshoot (seed=110, walk down to OK band [95, 105)).

### 4.4 ProTeGi-coplay

- **Reference**: Pryzant et al. 2023 (arXiv:2305.03495), "Automatic Prompt Optimization with 'Gradient Descent' and Beam Search".
- **Verdict variant**: `Verdict.semantic { gradient: []const u8 }` — natural-language gradient. `passes()` returns true unconditionally (the gradient string is the revision direction).
- **Step**: `Step.peer_pool` — 1-step beam search. 4 peers (inc_lo +1, inc_hi +10, dec_lo -1, overshoot +25). Each constructs a Verdict.semantic, applies its delta. The pool snapshot/restore mechanism evaluates each peer, keeps the highest-scoring.
- **Missing vs full ProTeGi**: no LLM-generated gradients, no persistent beam across iterations, no bandit selection (strict argmax).

## 5. Cycle combinator (§6.3)

`cycle(allocator, experiment, step, stop, frontier, max_iters) → Trajectory`

**Step** axis (how the topology mutates between iterations):
| Variant       | Description |
|--------------|-------------|
| `.revise`     | Per-target `ReviseFn` applied to latest verdicts. Wraps `cycleUntilMulti`/`cycleUntilFixedPoint`. |
| `.gradient`   | Finite-difference descent. `traceGradient` computes ∂rate/∂state per named agent; step applies `state += round(lr * partial)`. Optional norm_tol gate. |
| `.custom`     | Caller-supplied closure `(*Experiment, *const Report) → void`. Used by all curricula. |
| `.peer_pool`  | 1-step beam search: snapshot agent state, evaluate each `PeerFn`, keep highest-scoring peer's mutation. |

**Stop** axis (when to halt):
| Variant       | Description |
|--------------|-------------|
| `.iters`      | After exactly N iterations. |
| `.fixed_point`| Revise makes no state changes (meaningful with `.revise`). |
| `.pass_rate`  | Report pass rate ≥ threshold. |
| `.custom`     | Caller-supplied `StopFn`. |

**Frontier**: today only `frontier == 1` is supported; ≥2 reserved for persistent beam search.

**Trajectory**: owned slice of per-iteration Reports. Provides `last()`, `passRate()`, `deinit()`.

## 6. Gradient system (F_coplay)

`gradient.zig` realizes F_coplay as finite-difference descent:

- `traceGradient(allocator, experiment, targets) → []Gradient` — computes `∂pass_rate/∂state` for each named agent. 1-sided δ=+1 perturbation: `partial = rate(s+1) − rate(s)`. Each call costs `1 + |targets|` experiment runs.
- `cycleByGradient(allocator, experiment, targets, lr, norm_tol, max_iters) → GradientCycleResult` — iterative descent. Each iteration: compute gradient, apply `state += round(lr * partial)`, record report. Stops when L1 gradient norm < `norm_tol` or `max_iters` elapsed.
- `GradientCycleResult` carries `gradientNorm()` (L1 norm of final gradient) to confirm convergence.
- `cycleByGradient` is also folded into the cycle combinator as `Step.gradient`.

## 7. Verdict tagged-union variants

The `Verdict` union carries the evaluator name in every variant. Dispatch methods `name()`, `primaryScore()`, `passes(threshold)` work across all variants.

| Variant     | Payload                              | primaryScore()           | passes(threshold)          | First exercised by |
|-------------|--------------------------------------|--------------------------|----------------------------|--------------------|
| `.scalar`   | `score: f32`                         | `score`                  | `score > threshold`        | Rung 4 evaluators  |
| `.trit`     | `trit: i2` (GF(3) gate)             | `@floatFromInt(trit)`    | `trit > threshold`         | Rung 5             |
| `.vector`   | `steps: []const f32` (PRM)           | mean of steps            | `mean > threshold`         | Solo-MAGICORE      |
| `.record`   | `score: f32, feedback: []const u8`   | `score`                  | `score > threshold`        | Evaluator-Optimizer|
| `.semantic`  | `gradient: []const u8`              | `0.0` (no scalar)        | always `true`              | ProTeGi-coplay     |

## 8. Test coverage

**Test count (self-reported in builtins.zig)**: 83 loop unit tests.

**Tests per file** (top-10 by `rg -c 'test "'`):

| File                    | Tests |
|------------------------|-------|
| `loop/curricula.zig`   | 20    |
| `loop/eval.zig`        | 16    |
| `loop/trace.zig`       | 14    |
| `loop/topology.zig`    | ~8    |
| `loop/feedback.zig`    | ~8    |
| `loop/cycle.zig`       | ~6    |
| `loop/agent.zig`       | 6     |
| `loop/skill.zig`       | 5     |
| `loop/world_test.zig`  | 2     |

**`world_test.zig` — integration test** (2 tests, 269 lines):

1. **"world composes: 10 rungs through one scenario"** — end-to-end: registers 2 tools (Rung 8), builds a 2-agent topology (Rung 3), creates a dataset (Rung 5a), wires an Experiment with evaluator (Rung 4), runs `cycleUntilFixedPoint` (Rung 7), for each completed invocation runs a telemetry Action (Rung 9) that feeds a TelemetrySink (Rung 10). Asserts convergence, cycle metrics, telemetry aggregates, action log, and trace records all agree.

2. **"world survives: dump → reload → query loaded invariants"** — serializes trace store, action log, and telemetry via individual JSONL encoders; reloads into fresh structs in a simulated "process B"; asserts query-equivalence (event counts, aggregates, resume invariants).

Both tests prove that the 10 rungs compose end-to-end — exactly the inter-rung interface invariants that per-rung unit tests can miss.
