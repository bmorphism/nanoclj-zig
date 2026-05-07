# nanoclj-zig Advanced Subsystems — Technical Analysis

> Generated 2026-04-25. Source: `src/*.zig` first 100–200 lines per module.

---

## 1. miniKanren — Relational Logic Programming

**Source:** `src/kanren.zig` (1037 lines)

### Core Model

Logic variables (lvars) are represented as keywords `:_0`, `:_1`, … via a global counter. Substitutions are flat vectors of `[lvar, val, lvar, val, …]` pairs — a persistent-map-by-convention structure that supports immutable extension.

### Unification

Robinson's algorithm with **occurs check**. Walk chains resolve lvar→lvar bindings recursively. `unify(u, v, σ)` walks both terms, then:

- Same bits → return σ unchanged
- One lvar → extend substitution (after occurs check)
- Both lists/vectors → element-wise recursive unification
- Both ints/strings/keywords → structural equality check
- Otherwise → fail (return null)

Deep walk (`walkDeep`) recursively walks nested lists, vectors, and maps.

### Goal Types & Builtins

| Builtin | Signature | Description |
|---------|-----------|-------------|
| `(lvar)` | `→ :_N` | Fresh logic variable |
| `(lvar? x)` | `→ bool` | Logic variable predicate |
| `(unify a b σ)` | `→ σ' \| nil` | Unification with occurs check |
| `(walk* val σ)` | `→ val'` | Deep substitution walk |

`run*`, `fresh`, and `conde` are built on top of these primitives (remaining ~800 lines of kanren.zig). Goals are functions `σ → Stream(σ)`.

---

## 2. Interaction Nets — Optimal Reduction

**Source:** `src/inet.zig` (560 lines), `src/inet_compile.zig` (458 lines)

### Cell Types (Lafont's Interaction Combinators + Extensions)

| Cell | Symbol | Charge (GF(3)) | Role |
|------|--------|-----------------|------|
| γ (gamma) | Constructor | +1 | Builds values, fan-in |
| δ (delta) | Duplicator | −1 | Copies values, fan-out |
| ε (epsilon) | Eraser | 0 | Garbage collects, annihilates |
| ι (iota) | Identity | 0 | Wire passthrough (administrative) |
| σ (sup) | Superposition | 0 | Holds then/else branches for `if` |
| ν (num_op) | Numeric | 0 | Arithmetic operator cell |

### Wire Model

A **Port** is `(cell_index: u16, port_number: u8)` where port 0 is the **principal port**. A **Wire** connects two ports. An **active pair** is a wire connecting two principal ports of live cells — computation happens exclusively at active pairs.

### GF(3) Conservation

Every reduction step conserves trit sum modulo 3 across the net. γ=+1, δ=−1, ε=0. The `tritSumMod3()` method on `Net` computes the global invariant. This is the computational analogue of Noether's theorem.

### Visualization

Cells are colored using the **plastic angle** (ρ² ≈ 205.14°) for port/arity dispersion and the **golden angle** (≈ 137.51°) for depth dispersion, producing optimal 2D scatter in interaction-net diagrams.

### Lambda-to-Inet Compilation (Lamping's Algorithm)

`inet_compile.zig` implements the Lamping compilation scheme:

| Source | Net encoding |
|--------|-------------|
| Literal `v` | γ cell, arity 0, payload v |
| `(fn* [x] M)` | γ cell: aux[0] = binder port, aux[1] = body net |
| `(f arg)` | γ cell: aux[0] = func net, aux[1] = arg net |
| Symbol `x` (1 use) | Wire to binder port |
| Symbol `x` (N uses) | δ duplicator fan-out from binder |
| Unused param `x` | ε eraser on binder port |
| `(if c t e)` | σ (superposition) cell: cond meets σ, selects branch |
| Vector `[a b c]` | γ cell arity N, elements at aux ports |

Scoped variable tracking counts uses per binding to decide between direct wiring, δ-duplication, and ε-erasure.

---

## 3. Datalog — Bottom-Up Query Engine

**Source:** `src/datalog.zig` (905 lines)

### Representation

- **Facts:** Interned `u32` triples `(relation, arg1, arg2)` with a trit tag: +1 (derived), 0 (unknown), −1 (negated). FactSet is a fixed-capacity array (MAX_FACTS=4096).
- **Rules:** Horn clauses `head :- body1, body2, …` with up to 8 body atoms, each optionally negated.
- **Terms:** Either a constant (interned id) or a variable (distinguished by `is_var` flag).
- **StringPool:** Intern table mapping strings to `u32` ids (MAX_STRINGS=1024).

### Query Evaluation

**Semi-naive bottom-up evaluation:** each iteration only joins against facts newly derived in the previous iteration, avoiding redundant re-derivation.

**Stratified negation:** Rules are partitioned into strata (MAX_STRATA=16) by negation dependency. Each stratum is evaluated bottom-up to fixpoint before the next begins. Negation-as-failure is only applied to complete strata.

### GF(3) Conservation

`tritSum()` on `FactSet` computes the sum of all fact trits. The engine maintains `GF(3) conservation: sum of trits across all facts in a stratum ≡ 0 (mod 3)`.

### Substitution

A fixed-capacity (MAX_BINDINGS=32) binding map for variable→constant, supporting clone and agreement checks.

---

## 4. Open Games — Compositional Game Theory

**Source:** `src/open_game.zig` (1690 lines)

### Architecture

Builds on the monoidal diagram kernel (`monoidal_diagram.zig`). Open-game constructors lower to ordinary diagram boxes. The substrate stays plain: diagrams are maps/vectors, not specialized objects.

### Scan Analysis

A `Scan` struct catalogs diagram structure before execution:

- **World / Coworld / Closure boxes** — topological closure checks
- **Decision / Nature / Stochastic boxes** — strategic surface
- **Forward / Backward function boxes** — lens components
- **Payoff / Discount boxes** — utility specification
- **ContextAd layers** — contextual autodifferentiation depth

A diagram is **semantically closed** when it has world, coworld, closure, and contextad layers plus agreement.

### Engine Selection

Default primary engine: `"inet-batch"` with companion engines `"thread-peval"`, `"kanren-search"`, `"propagator-fixpoint"`. A seeded execution context drives normalization.

### Best-Response Diagnostics

`evaluate` performs best-response analysis when explicit payoff tables are present:
- `DecisionSpec`: captures player, action space, payoff table, observation space, epsilon (tolerance)
- `DecisionDiagnostic`: per-decision equilibrium/profitable/missing-payoff status
- `DiagnosticsSummary`: aggregate equilibrium check across all decisions

Falls back to structural closure checks when payoff tables are absent.

---

## 5. Polynomial Functors — World-Constructor Kernel

**Source:** `src/flow.zig` (1072 lines), `src/flow_value.zig` (203 lines)

### Poly Type (Spivak/Niu Category)

A polynomial `p = Σ_{i ∈ I} y^{A_i}` as a tagged union:

| Variant | Polynomial | Positions | Directions |
|---------|-----------|-----------|------------|
| `.zero` | 0 | 0 | — |
| `.one` | 1 | 1 | 0 |
| `.y` | y | 1 | 1 |
| `.monomial(n)` | y^n | 1 | n |

`PolyMorphism`: forward-on-positions `φ₁: I_src → I_dst` + backward-on-directions `φ♯(i_src, a_dst) → a_src`.

### Block, Connection, Flow

- **Block(V):** Parameterized by value type V. Body variants: `seed` (static), `compute` (pure function), `compute_ctx` (closure carrying context), `terminal` (exit). Each block derives its polynomial: seed→1, terminal→y, compute→y^|in_ports|.
- **Connection:** `{src, dst, port}` — resolves to a PolyMorphism fragment (the contravariant lens half of Spivak/Niu "wire" morphism).
- **FlowSpec / Flow:** A spec is blocks + connections + exit id. `Flow(V).inhabit` is the **pump loop**: pump blocks until stable, fuel-bounded. First-nonempty scan replaces `alts!`.

### GF(3) Conservation Law

`Law(V)` is a generic conservation law: `check`, `compose`, `identity`. `Gf3.law` is the concrete GF(3) instance: `check` verifies sum ≡ 0 (mod 3), `compose` is modular addition.

### Rama-Style Partitioners

`Partitioner(V)` routes values to one of N branches — the Poly interpretation is `y^1 → Σ_{i<N} y^{A_i}`.

### Clojure ↔ Zig Bridge (flow_value.zig)

`ClojureCompute(V)` wraps a nanoclj `Value` function as a `flow.Block(V).ComputeCtx`:
- `from_v: V → Value` and `to_v: Value → V` coercion function pointers
- `callErased` converts inputs, dispatches through `eval.apply`, unboxes the result
- Stock coercions for `i64` and `f64` provided
- Extensive teleportation tests verify `V → Value → V` roundtrips

---

## 6. Church-Turing / Computable Sets

**Source:** `src/church_turing.zig` (862 lines), `src/computable_sets.zig` (1949 lines)

### Church-Turing Module

Models the Church-Turing thesis as **ill-posed** — it collapses intensional differences to a single extensional bit. Three evaluation substrates compute the same functions but differ on every intensional dimension:

| Property | Tree-Walk | Bytecode VM | Interaction Net |
|----------|-----------|-------------|-----------------|
| Fuel cost | O(n·d) | O(n) | O(n/sharing) |
| Trit conserved | No | No | Yes (GF(3)) |
| Parallelism | None | None | Inherent |
| Sharing | None | None | Optimal |
| Self-reducible | No | No | Yes (Lafont) |

`Observation` struct captures: result, fuel_spent, trit_balance, steps, depth_seen, substrate_name. Functions `observeTreeWalk`, `observeBytecodeVM`, `observeInet` run the same expression through each substrate. `illPosedFn` is the Clojure builtin that packages all three observations.

### Computable Sets Module

- **ComputableSetKind:** evens, odds, primes, squares, multiples, complement, union, intersection, symmetric_diff, custom
- **Built-in characteristic functions:** `isEven`, `isOdd`, `isPrime`, `isSquare`, `isMultipleOf` — all total, always halt
- **Natural density approximation:** `|S ∩ [0,n)| / n`
- **Many-one reductions** `A ≤_m B`: computable function f such that `x ∈ A ⟺ f(x) ∈ B`, with `verifyReduction` checking up to a bound
- **ReductionKind:** `to_evens`, `to_squares`, `identity`, `composed` (transitivity)
- **Weihrauch degrees** and **guideline auditor** (claims requiring HALT-hard problems flagged as dishonest)
- References: quantum channel capacity undecidability (2601.22471), AI alignment undecidability via Rice, Brattka-Rauzy computable bases, Dagstuhl Weihrauch lattice

---

## 7. Build Targets

### MCP Tool Server (`src/mcp_tool.zig`, 597 lines)

Hardcoded MCP server over JSON-RPC 2.0 on stdio. Exposes tools: `nanoclj_eval`, `nanoclj_color_at`, `nanoclj_bci_read`, `nanoclj_brainfloj_read`, `nanoclj_substrate`, `nanoclj_traverse`. Protocol version `2024-11-05`. Uses SplitMix64 for trit + color derivation. Persistent global GC/Env state across calls.

### gorj-MCP Server (`src/gorj_mcp.zig`, 1704 lines)

**Self-hosting** MCP server: tool definitions are nanoclj Clojure forms compiled to bytecode, dispatched through the nanoclj runtime. The Zig layer is only JSON-RPC envelope + stdio transport.

- Tool dispatch: `tools/call → (gorj-mcp-dispatch name args-map) → nanoclj eval → JSON-RPC response`
- Prelude tools: `gorj_eval`, `gorj_pipe`, `gorj_encode`, `gorj_decode`, `gorj_version`, `gorj_tools`, `gorj_trit_tick`, `gorj_color`, `gorj_substrate`, `gorj_compile`
- Protocol version `2025-11-05`, server version `0.3.0`
- **MCP Tasks** (2025-11-25 spec): async long-running eval with TaskState (working/completed/failed), task registry (64 slots)

### WASM Entry Point (`src/wasm_main.zig`, 138 lines)

Exports for browser/JS host:

| Export | Description |
|--------|-------------|
| `nanoclj_init()` | Initialize GC, env, core builtins |
| `nanoclj_eval(ptr, len)` | Evaluate Clojure source, return result ptr+len |
| `nanoclj_alloc(len)` | Allocate in WASM linear memory |
| `nanoclj_free(ptr, len)` | Free previously allocated bytes |
| `nanoclj_result_len()` | Length of last eval result |

Fuel-bounded evaluation with structured error messages. Captures `println` side-effects via WASM output buffer.

### SectorClojure Boot Image (`src/sector_boot.zig`, 531 lines)

Freestanding x86 Lisp bootable from BIOS, inspired by SectorLisp. Two-stage design:

- **Stage 1:** 512-byte boot sector (inline `int $0x10` / `int $0x16` BIOS calls), loads stage 2
- **Stage 2:** Zig freestanding 32-bit Lisp with eval/apply/read/print/GC

Memory layout (real mode, 64KB):
```
0x0000–0x7BFF  Cons cells (grow upward)
0x7C00–0x7DFF  Boot sector code (512 bytes)
0x7E00–0x7FFF  Stage 2 code
0x8000–0x9FFF  Atom interning table
0xA000–0xBFFF  Input buffer / scratch
0xF000–0xFFFF  Stack (grows down)
```

Primitives: McCarthy core (cons/car/cdr/atom?/eq) + Clojure minimum (def/if/do) + arithmetic + I/O. Build: `zig build sector`, test: `qemu-system-i386 -fda sector.img -nographic`.

---

## 8. Concurrency

### Atoms (via `value.zig` ObjKind.atom)

Standard Clojure atoms: `(atom x)`, `(deref a)` / `@a`, `(swap! a f)`, `(reset! a v)`, `(compare-and-set! a old new)`.

### Refs + dosync (`src/refs_agents.zig`, ~200 lines)

Single-threaded semantic parity (no real STM):

- Refs are atoms tagged with `{:ref true}` metadata — reuses `ObjKind.atom`, `deref`/`@` works unchanged
- `(ref init)` → create a ref
- `(alter r f & args)` → apply `(f @r & args)` and stage the result; **must** be inside `dosync`
- `dosync` body: `beginTransaction()` sets a module-local `in_transaction` flag, snapshots each touched ref, commits proposed values on success (`commitTransaction`), aborts and discards on error (`abortTransaction`)
- `commute` aliases `alter`; `send-off` aliases `send` in single-threaded mode
- Upgrade path: `in_transaction` is module-local, ready for `threadlocal` promotion

### Agents (via `core.zig`)

`(agent init)`, `(send a f & args)`, `(deref a)`. Share the atom layout with `{:agent true}` metadata.

### CSP Channels (`src/channel.zig`, ~200 lines)

core.async-style channels:

| Builtin | Description |
|---------|-------------|
| `(chan)` / `(chan n)` | Unbuffered / buffered channel |
| `(chan! ch val)` | Blocking put (immediate if buffer allows) |
| `(<! ch)` | Blocking take |
| `(close! ch)` | Close channel |
| `(closed? ch)` | Closed predicate |
| `(chan-count ch)` | Items buffered + pending |
| `(offer! ch val)` | Non-blocking put → true/false |
| `(poll! ch)` | Non-blocking take → value/nil |

`ChannelData` has a buffer (`ArrayListUnmanaged(Value)`), capacity (0 = unbuffered rendezvous), closed flag, and pending-puts queue. In single-threaded mode, blocking = fuel exhaustion; unbuffered channels require a pending taker.

---

## 9. Color System

### OKLAB Colorspace (`src/colorspace.zig`, 540 lines)

First-class perceptually uniform colors:

```zig
pub const Color = struct {
    L: f32,  // lightness [0,1]
    a: f32,  // green-red [-0.5, 0.5]
    b: f32,  // blue-yellow [-0.5, 0.5]
    alpha: f32,  // binding opacity [0,1]
};
```

Operations: `distance` (Euclidean in OKLAB), `blend` (linear interpolation), `complement` (180° a-b rotation + lightness inversion), `analogous` (arbitrary angle rotation in a-b plane), `triadic` (three colors 120° apart).

**Plastic spiral generation:** `plasticRotate(depth, branch)` uses golden angle for depth dispersion and plastic angle (ρ² ≈ 205.14°) for branch dispersion — optimal for tree/interaction-net structures. `plasticSpiral(n)` generates n optimally-spaced colors.

### Chromatic Propagators (`src/chromatic_propagator.zig`, 299 lines)

Propagator cells with color identity (matching `Gay.jl`'s `chromatic_propagator.jl`):

- **ChromaticCell:** `name_hash`, `content` (nothing/value/contradiction), `value_bits`, `color` (substrate.Color), `color_seed`
- `tell(val)` — Sussman-style propagator tell: nothing→value, value+agree→value, value+disagree→contradiction
- **Trit from color:** Red-dominant = −1 (validator), Green-dominant = 0 (coordinator), Blue-dominant = +1 (generator)
- **GF(3) conservation:** `conservedCombine` for color pairs; trit sum mod 3 is the correct law (not XOR, which is GF(2))
- **ChromaticEnv:** 64-cell propagator network with seed, step counter, and constraint propagation

---

## 10. Bridges

### Juvix Bridge (`src/juvix_bridge.zig`, 1137 lines)

Structural bridge to Juvix's ADT space — does **not** assume an in-process Juvix evaluator. Provides a canonical tagged-term encoding:

- Every nanoclj Value is encoded as a map with `{:juvix/tag :kind, :value v}`
- Tags: `:unit`, `:bool`, `:int`, `:double`, `:string`, `:symbol`, `:opaque`
- Nested structures (lists, vectors, maps) are recursively encoded
- `isEncodedTerm` checks for the `:juvix/tag` key
- Opaque wrapping via `makeOpaqueKind` for non-representable types

### Syrup Codec

Referenced in the Juvix bridge context. Syrup is a Spritely/Goblins-family serialization format. The bridge handles encoding/decoding between nanoclj values and the Syrup wire format for inter-system communication.

---

## 11. Substrate Utilities

**Source:** `src/substrate.zig` (581 lines)

### SplitMix64 PRNG

Constants: `GOLDEN = 0x9e3779b97f4a7c15`, `MIX1`, `MIX2`, `CANONICAL_SEED = 1069`. Core functions: `mix64(z)`, `splitmix_next(state)`.

### Splittable PRNG (Steele/Lea/Flood)

`SplitRng` struct with `(seed, gamma)` where gamma is odd with good bit distribution:

- `next()` — advance seed by gamma, return mixed value
- `split()` — fork into two independent deterministic streams
- `nextTrit()` — unconstrained ergodic trit (−1, 0, +1)
- `nextBalancedTriple()` — **conserved** triple: exactly one of each {−1, 0, +1}, sum always 0 mod 3
- `nextInt()`, `nextBounded(n)` — bounded integer generation

The split semantics enable deterministic forking: `split(world_seed)` → left=test stream, right=live stream, both traceable.

### Transduction (`src/transduction.zig`, 1330 lines)

The fuel-bounded operational evaluator — the "signal transformation" layer:

- Special form dispatch by interned `u48` ids (avoids string comparisons): `quote`, `def`, `let*`, `if`, `do`, `fn*`, `peval`, `defn`
- `evalBounded(val, env, gc, res) → Domain` — every eval step consumes fuel and tracks depth
- Recur signal via thread-local state (`recur_pending`, `recur_args`)
- Domain = `value | bottom(fuel_exhausted | depth_exceeded | divergent) | err(kind)`
