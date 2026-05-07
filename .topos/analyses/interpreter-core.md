# nanoclj-zig Interpreter Core — Technical Analysis

## 1. Value Representation: NaN-Boxing

nanoclj-zig uses **NaN-boxed 64-bit values** (`Value` is a `packed struct { bits: u64 }`). IEEE 754 quiet NaNs have spare bits; the interpreter exploits this to encode seven value types in a single 64-bit word with zero indirection for primitives.

### Layout

```
Plain f64:    any bit pattern that is NOT a quiet NaN with our marker
Tagged value: bits 63..52 = 0x7FF8 | tag   (quiet NaN + 3-bit tag in bits 50..48)
              bits 47..0  = payload (pointer, interned-string ID, or inline integer)
```

The constant `QNAN = 0x7FF8_0000_0000_0000` marks the quiet-NaN prefix. Tags occupy 3 bits at position 48–50; the low 48 bits carry the payload.

### Tag Enum (`Tag`, u3)

| Tag | Value | Payload |
|-----|-------|---------|
| `nil` | 0 | always 0 |
| `boolean` | 1 | 0 = false, 1 = true |
| `integer` | 2 | i48 (sign-extended via `@bitCast`) |
| `symbol` | 3 | u48 interned string ID |
| `keyword` | 4 | u48 interned string ID |
| `string` | 5 | u48 interned string ID |
| `object` | 6 | u48 pointer to heap `Obj` |
| `_reserved` | 7 | unused |

**Key design choices:**
- Symbols, keywords, and strings are all interned — the payload is an index into `GC.strings[]`, not a pointer. This makes equality checks O(1) (integer comparison).
- Integers are 48-bit signed, giving ±140 trillion range without heap allocation.
- Tag checking uses a branchless pattern: `(bits & mask) == expected_pattern` in `isTag()`.
- `isTruthy()` follows Clojure semantics: only `nil` and `false` are falsy.

### Heap Object System (`ObjKind`, `Obj`, `ObjData`)

When `Tag == .object`, the payload is a pointer to an `Obj` struct:

```zig
pub const Obj = struct {
    kind: ObjKind,
    marked: bool = false,        // GC mark bit
    is_transient: bool = false,  // mutable transient mode
    meta: ?*Obj = null,          // optional metadata map
    data: ObjData,               // tagged union of all heap types
};
```

`ObjKind` (u8 enum, 22 variants):

| Kind | Description |
|------|-------------|
| `list` | Clojure list (array-backed) |
| `vector` | Clojure vector (array-backed) |
| `map` | Hash map (parallel key/val arrays) |
| `set` | Hash set |
| `function` | Tree-walk interpreted fn (params + body + env) |
| `macro_fn` | Macro (same shape as function) |
| `atom` | Mutable reference with optional validator |
| `bc_closure` | Bytecode VM closure (FuncDef + upvalues) |
| `builtin_ref` | Native Zig function pointer + name |
| `lazy_seq` | Thunk-based lazy sequence with memoization |
| `partial_fn` | Partial application capture |
| `multimethod` | `defmulti` dispatch fn + method table |
| `protocol` | `defprotocol` method sigs + type→impl dispatch |
| `dense_f64` | Neanderthal-compatible contiguous f64 buffer + stride |
| `trace` | Anglican-compatible weighted execution trace |
| `rational` | Exact rational (GCD-normalized, denominator > 0) |
| `color` | First-class OKLAB color value (4×f32) |
| `channel` | CSP channel (core.async-style) |
| `agent` | Clojure agent with mailbox |
| `file_handle` | POSIX fd wrapper |
| `bytes` | Raw mutable byte vector |
| `mmap_view` | Memory-mapped read-only file view |

`ObjData` is a Zig `union` over all 22 variants, each containing the type-specific fields (e.g., `list` holds an `ArrayListUnmanaged(Value)`, `bc_closure` holds a `Closure` with `def: *const FuncDef` and `upvalues: []Value`).

---

## 2. Reader Pipeline

**File:** `src/reader.zig` (~960 lines)

The `Reader` struct is a recursive-descent S-expression parser:

```
Text → Reader.readForm() → Value (NaN-boxed AST)
```

### Structure

- **State:** `src: []const u8`, `pos: usize`, `gc: *GC`, `depth: u32`, `line/col` tracking, `file_id` for source locations.
- **Depth limit:** `MAX_READ_DEPTH = 256` (CVE-3 fix) — prevents stack overflow on deeply nested input.
- **Source locations:** `attachLoc()` stores `SourceLoc` (line, col, file_id) as metadata on heap objects.

### Dispatch (`readForm`)

The reader dispatches on the first character:

| Char | Handler | Output |
|------|---------|--------|
| `(` | `readList` | list Obj |
| `[` | `readVector` | vector Obj |
| `{` | `readMap` | map Obj |
| `'` | `readWrapped("quote")` | `(quote x)` list |
| `` ` `` | `readWrapped("quasiquote")` | `(quasiquote x)` |
| `~` / `~@` | `readWrapped("unquote"/"splice-unquote")` | unquote forms |
| `@` | `readWrapped("deref")` | `(deref x)` |
| `\` | `readCharLiteral` | character literal |
| `^` | `readMeta` | metadata attachment |
| `#` | `readDispatch` | dispatch macros (`#{}`, `#()`, `#?`, etc.) |
| `"` | `readString` | interned string Value |
| `:` | `readKeyword` | keyword Value |
| `;` | skip-to-EOL comment | recursive readForm |
| other | `readAtom` | number, symbol, `nil`, `true`, `false` |

### Reader conditionals

The reader supports `#?(:clj ...)` and `#?@(...)` via skip-sentinel and splice-sentinel markers. Non-matching branches produce a `__reader_skip__` sentinel symbol; matching `#?@` branches produce splice-sentinel lists that are flattened into the parent collection.

### Output

The reader produces the **same Value type used at runtime** — lists, vectors, maps, symbols, keywords, integers, strings. There is no separate AST type; the Clojure "code is data" philosophy applies directly.

---

## 3. Compiler + Bytecode VM

### Compiler (`src/compiler.zig`, ~1700 lines)

**Strategy:** Single-pass, register-allocating compiler. Walks the parsed AST (Values) and emits 32-bit instructions.

**Register allocation:** Monotonic counter — each new temporary or local gets the next register. Simple but correct (max 255 registers per function).

**Key structures:**
- `Compiler` holds: `code` (instruction list), `constants`, `defs` (sub-FuncDefs for nested `fn*`), `upvalues`, `locals[256]`, and parent pointer for nested compilation.
- `Local`: `{ name: []const u8, reg: u8 }` — maps names to registers.
- `Upvalue`: `{ name, source: UpvalueSource }` — captures variables from enclosing scopes.

**Upvalue resolution:** Multi-level — `resolveUpvalue` walks the parent compiler chain recursively. Each intermediate compiler adds its own upvalue entry, creating a chain: `register → parent_upvalue → grandparent_upvalue → ...`

**Compilation of special forms:**
- `quote`: emit `load_const`
- `if`: emit condition, `jump_if_not` over then-branch, optional `jump` over else-branch
- `let*`: allocate registers for bindings, compile body
- `fn*`: create child `Compiler`, compile body, produce `FuncDef`, emit `closure` instruction
- `loop`/`recur`: `loop_entry` marks the loop head instruction index; `recur` emits moves + `jump` back
- `do`: compile expressions sequentially, last in tail position
- Tail calls: `compileTail` sets `in_tail = true`; function calls in tail position emit `tail_call` instead of `call`

**Output:** `FuncDef` (bytecode + constants + sub-defs + arity + upvalue_sources).

### Bytecode VM (`src/bytecode.zig`, ~820 lines)

**Instruction format:** 32-bit fixed-width (Janet/Lua-style):
```
OP(8) | A(8) | B(8) | C(8)    — 3-arg (ABC format)
OP(8) | A(8) | E(16)          — 2-arg (AE format, E = extended)
OP(8) | D(24)                 — 1-arg (D format, signed/unsigned)
```

**Opcode set (28 instructions):**

| Category | Opcodes |
|----------|---------|
| Control flow (5) | `ret`, `ret_nil`, `jump`, `jump_if`, `jump_if_not` |
| Constants & moves (5) | `load_nil`, `load_true`, `load_false`, `load_int`, `load_const` |
| Arithmetic (6) | `add`, `sub`, `mul`, `div`, `quot`, `rem` |
| Comparison (3) | `eq`, `lt`, `lte` |
| Function calls (3) | `call`, `tail_call`, `closure` |
| Data movement (2) | `move`, `get_upvalue` |
| Globals (2) | `get_global`, `set_global` |
| List operations (6) | `cons`, `first`, `rest`, `make_list`, `count`, `nth` |

**VM state:**
- `stack: [256 * 64]Value` — 256 registers × 64 frames max (statically allocated)
- `frames: [64]CallFrame` — each frame has `closure`, `ip`, `base` register offset, `ret_dest`
- `globals: StringHashMap(Value)` — global variable store
- `fuel: u64` — every instruction costs 1 fuel tick

**Execution loop:** `execute()` runs a tight `while (true)` loop, fetching and dispatching instructions via a `switch(op)`. Key behaviors:
- **Arithmetic** promotes int→f64 when operands are mixed.
- **`call`** pushes a new `CallFrame`; dispatches to either `bc_closure` or `builtin_ref`.
- **`tail_call`** reuses the current frame (overwrites registers at `base`, resets `ip` to 0) — this is the TCO mechanism.
- **`closure`** captures upvalues at runtime by copying from the enclosing frame's registers or upvalue slots.

### Closure representation

```zig
pub const Closure = struct {
    def: *const FuncDef,     // shared bytecode (immutable)
    upvalues: []Value,       // instance-specific captured values
};
```

Closures reference a shared `FuncDef` (code + constants + sub-defs) and own their upvalue array. Multiple closures from the same `fn*` share the `FuncDef` but have independent upvalue snapshots.

---

## 4. Eval Paths

nanoclj-zig has **three distinct eval paths**, arranged from most complete to most principled:

### 4a. Tree-Walk Eval (`src/eval.zig`, ~1870 lines)

The **unbounded, full-featured** interpreter. Walks the AST directly without compilation.

- Handles **all Clojure special forms** (~50): `def`, `let*`, `if`, `do`, `fn*`, `defn`, `defmacro`, `loop`/`recur`, `try`/`catch`/`throw`, `for`, `doseq`, `dotimes`, `case`, `cond`, threading macros (`->`, `->>`, `some->`, `as->`), `binding`, `with-redefs`, `defmulti`/`defmethod`, `defprotocol`/`extend-type`, `defrecord`, `ns`, color operations, and more.
- **Dynamic bindings:** A process-wide `dynamic_stack` (ArrayListUnmanaged of `DynFrame`) provides dynamic scope for `^:dynamic` vars. Lookup walks the stack top-down.
- **Macro expansion:** If the head of a list resolves to a `macro_fn`, unevaluated args are passed to the macro, and the result is re-evaluated.
- **Recur:** Implemented via a sentinel error (`error.RecurCalled`) and a global `recur_args` buffer.
- **Pluralism:** `pluralIsTruthy()` supports classical, intuitionistic, and paraconsistent truth modes via the `pluralism` module.
- Uses **unmetered resources** (`Resources.unmetered()`) — fuel is effectively infinite.

### 4b. Denotational Semantics (`src/transclusion.zig`, ~450 lines)

The **meaning function ⟦·⟧** — a fuel-bounded denotational eval.

- Returns `Domain = Value ∪ {⊥, error(e)}` — a proper monadic semantic domain with `pure`, `bind`, and `fail`.
- `BottomReason`: `fuel_exhausted`, `depth_exceeded`, `read_depth_exceeded`, `divergent`.
- `ErrorKind`: 11 semantic error types (type_error, arity_error, unbound_symbol, etc.).
- Handles core special forms: `quote`, `def`, `let*`, `if`, `do`, `fn*`.
- Delegates to builtins via `lookupBuiltin`.
- Every step consumes fuel via `res.tick()` and tracks depth via `res.descend()`/`res.ascend()`.

### 4c. Operational Semantics (`src/transduction.zig`, ~1330 lines)

The **fuel-bounded operational eval** — mirrors the denotational layer but handles more forms.

- Uses **integer-keyed special form dispatch** (pre-interned symbol IDs) for performance — avoids string comparisons on the hot path.
- Handles: `quote`, `def`, `let*`/`let`, `if`, `do`, `fn*`/`fn`, `peval`, `defn`, `deftest`, `testing`, `defmacro`, `defmulti`, `defmethod`, `loop`/`recur`, `try`/`catch`, `ns`, threading macros, and more.
- **`peval`** (parallel eval): a special form unique to the bounded path.
- Recur is implemented via thread-local `recur_pending`/`recur_args`/`recur_count` state (separate from eval.zig's mechanism).

### How Resources Work (`src/transitivity.zig`)

The `Resources` struct is the "immune system" — threaded through all bounded eval paths:

```zig
pub const Resources = struct {
    fuel: u64,              // decremented each step
    depth: u32,             // current eval nesting
    limits: Limits,         // configurable caps
    trit_balance: i8,       // GF(3) conservation accumulator
    buddy_events: u32,      // monotonic propagator counter
    truth_mode: TruthMode,  // classical/intuitionistic/paraconsistent
};
```

**`Limits`** (configurable caps):
- `max_depth: 1024`, `max_read_depth: 256`, `max_fuel: 10B`
- `max_string_len: 1MB`, `max_collection_size: 100K`, `max_interned_strings: 100K`
- `max_live_objects: 1M`, `max_env_depth: 512`

**Fuel cost:** Non-uniform — `tick()` consults a depth-based cost LUT from `gay_skills.depth_fuel_lut[]`. Deeper eval frames cost more fuel, preventing adversarial nesting.

**Fork/Join:** `Resources.fork(n)` splits fuel equally among n children (adiabatic — no overhead). `join()` merges steps, unused fuel, and trit balance back, with a 1-fuel-per-child join cost.

---

## 5. Garbage Collection

**File:** `src/gc.zig` (~362 lines)

### Algorithm: Mark-Sweep

The GC is a straightforward **mark-sweep collector** with a worklist-based mark phase.

### GC State

```zig
pub const GC = struct {
    allocator: std.mem.Allocator,
    objects: ArrayListUnmanaged(*Obj),       // all live heap objects
    roots: ArrayListUnmanaged(*Value),       // GC roots
    strings: ArrayListUnmanaged([]const u8), // interned string table
    string_index: StringHashMapUnmanaged(u48), // string→ID reverse lookup
    envs: ArrayListUnmanaged(*Env),          // tracked child environments
    func_defs: ArrayListUnmanaged(*FuncDef), // tracked bytecode FuncDefs
    bytes_allocated: usize,
    next_gc: usize = 1MB,                   // threshold for next collection
};
```

### Mark Phase (`mark`)

Uses a **worklist** (not recursion) — avoids stack overflow on deep object graphs:

1. Start with root objects; mark and enqueue.
2. While worklist non-empty, pop an object and enqueue all Value references it contains:
   - `list/vector/set`: iterate items
   - `map`: iterate keys and vals
   - `function/macro_fn`: iterate params, body, and env
   - `atom`: mark val
   - `lazy_seq`: mark thunk and cached value
   - `partial_fn`: mark func and bound_args
   - `multimethod`: mark dispatch_fn, methods, default_method
   - `protocol`: mark impl functions
   - `channel`: mark buffer and pending puts
   - `agent`: mark state, validator, error_state, error_handler, mailbox
   - `trace`: mark site_values
   - `dense_f64`, `rational`, `color`, `file_handle`, `bytes`, `mmap_view`: no Value refs
3. Metadata (`obj.meta`) is also marked and enqueued.
4. Environments are marked by walking the parent chain and marking all bound values.

### Sweep Phase (`collect`)

1. Walk `objects` array; any unmarked object is freed via `freeObj` (which deinits internal allocations per kind) and swap-removed from the list. Marked objects have their mark bit cleared.
2. Walk `envs` array; any unmarked, non-root env is freed and swap-removed.

### Object Freeing (`freeObj`)

Per-kind cleanup: deinit internal ArrayLists, free upvalue arrays, free dense_f64 owned buffers, close file handles, unmap mmap views, etc. Then `allocator.destroy(obj)`.

### String Interning

- `internString(s)` deduplicates: if already interned, returns existing ID. Otherwise, copies the string and assigns a monotonic ID.
- `getString(id)` returns the string by ID.
- The string table is **not garbage collected** — interned strings live for the lifetime of the GC.

### FuncDef Tracking

Top-level `FuncDef` trees (from the compiler) are registered via `trackFuncDef` and freed recursively on `gc.deinit()` via `freeFuncDefTree`.

---

## 6. Persistent Data Structures

### Persistent Vector (`src/persistent_vector.zig`, ~339 lines)

**Algorithm:** 32-way trie (Bagwell HAMT), matching Clojure's `PersistentVector`.

- **Branching factor:** 32 (`BITS = 5`, `WIDTH = 32`)
- **Node:** `children: [32]?*Node`, `values: [32]Value`, `ref_count: u32`
- **Tail optimization:** The last ≤32 elements live in a flat `tail` array on the vector struct, avoiding a trie walk for the most common operation (append).

**Operations:**
- `nth(i)`: O(log₃₂ n) — check tail first, then walk trie
- `conj(val)`: O(~1) amortized — add to tail; when tail full, push tail into trie and start new tail
- `assocN(i, val)`: O(log₃₂ n) — path-copy from root to modified leaf

**Structural sharing:** Modifications copy only the path from root to the affected leaf; all other nodes are shared between the old and new vector.

### Persistent Map (`src/persistent_map.zig`, ~422 lines)

**Algorithm:** Hash Array Mapped Trie (HAMT) with bitmap compression.

- **Branching factor:** 32 (5 bits per trie level)
- **Hash function:** `Wyhash` with type-dependent seeds (0 for keyword, 1 for symbol, 2 for int, 3 for string, 4 for color, 5 for channel identity)
- **Node types:**
  - `BranchNode`: `bitmap: u32` + compressed `children` array (popcount-indexed)
  - `leaf`: single `Entry { key, val }`
  - `CollisionNode`: array of entries sharing the same hash

**Operations:**
- `get(key)`: O(log₃₂ n) — walk trie using hash bits
- `assoc(key, val)`: O(log₃₂ n) — path-copy, returns new map
- `dissoc(key)`: O(log₃₂ n) — path-copy with removal

**Structural sharing:** Only the path from root to the modified entry is copied; siblings are shared.

---

## 7. Core Builtins

**File:** `src/core.zig` (~5825 lines)

### Registration

Builtins are registered in `initCore(env, gc)` via a large tuple literal:

```zig
const builtins = .{
    .{ "+", &add }, .{ "-", &sub }, .{ "*", &mul }, ...
};
```

Each entry maps a string name to a `BuiltinFn`:
```zig
pub const BuiltinFn = *const fn (args: []Value, gc: *GC, env: *Env, res: *Resources) anyerror!Value;
```

These are stored in a `StringHashMap(BuiltinFn)` (`builtin_table`), and additionally each is registered as a symbol→sentinel in the environment (intercepted during `apply`).

### Count

**~404 builtin functions** registered in the main tuple, plus additional builtins from imported modules (inet, channel, nrepl, loop, etc.).

### Naming Convention

Follows Clojure conventions:
- Predicates: `nil?`, `number?`, `string?`, `empty?`, `set?`, `zero?`
- Mutating: `jepsen/nemesis!`, `jepsen/record!`, `jepsen/reset!`, `set-logic!`
- Namespaced: `jepsen/gen`, `jepsen/check`, slash-separated pseudo-namespaces
- Arithmetic: `+`, `-`, `*`, `/`, `mod`, `inc`, `dec`
- Collection: `first`, `rest`, `cons`, `conj`, `assoc`, `get`, `nth`, `count`, `into`
- Higher-order: `map`, `filter`, `reduce`, `apply`, `take`, `drop`

### Module Imports

`core.zig` imports ~40 specialized modules including: `substrate`, `gay_skills`, `inet_builtins`, `http_fetch`, `kanren` (miniKanren), `regex`, `pluralism`, `church_turing`, `hyperdoctrine`, `open_game`, `tower`, `decomp`, `channel`, `nrepl`, `loop`, and more.

### WASM Support

OS-dependent builtins are stubbed for WASM targets via conditional compilation:
```zig
const tree_vfs = if (is_wasm) @import("tree_vfs_stub.zig") else @import("tree_vfs.zig");
```

---

## 8. Lexical Scoping (`src/env.zig`)

The `Env` struct implements a **parent-chain** lexical environment:

```zig
pub const Env = struct {
    parent: ?*Env,
    bindings: StringHashMap(Value),    // string-keyed
    id_bindings: AutoHashMapUnmanaged(u48, Value), // integer-keyed fast path
    dynamic_ids: AutoHashMapUnmanaged(u48, void),  // ^:dynamic markers
    small_ids/small_vals/small_len: ...  // inline array for ≤8 bindings
};
```

**Optimizations:**
- **Small-env fast path:** Functions with ≤8 params use a stack-allocated array (`small_ids/small_vals`) instead of hash maps — avoids heap allocation for the common case.
- **Integer-keyed lookup:** `getById(u48)` / `setById(u48)` uses interned symbol IDs, avoiding string hashing on the hot path.
- **`SmallEnv`:** A separate `SmallEnv` struct for non-variadic calls with ≤8 params — fully stack-allocated, O(n) linear scan but n≤8 beats hash map overhead.

**Dynamic vars:** `isDynamic(id)` walks the parent chain checking `dynamic_ids`. The eval layer maintains a separate `dynamic_stack` for `binding` form semantics.

---

## 9. Value Printing (`src/printer.zig`)

The `printer` module serializes Values back to Clojure-readable text via `prStr(val, gc, readably)`. It handles all 22 ObjKind variants with appropriate formatting:

- Lists: `(...)`, Vectors: `[...]`, Maps: `{k v, ...}`, Sets: `#{...}`
- Functions: `#<fn name>`, Macros: `#<macro>`, BC closures: `#<bc-fn>`
- Builtins: `#<builtin name>`, Lazy seqs: `#<lazy-seq>`
- Rationals: `n/d` (or just `n` when denominator is 1)
- Colors: ANSI true-color swatch + `#color[L a b alpha]`
- Channels: `#channel[status buf=n cap=m]`
- Dense vectors: `#<dense-f64 [1.0 2.0 ...]>`
- Traces: `#<trace sites=n w=w>`
- Bytes: hex dump preview, Mmap: `#<mmap status len>`

String readability: when `readably = true`, strings are escaped (`\"`, `\\`, `\n`, `\t`) and quoted.

---

## 10. Key Invariants

### GF(3) Conservation

The interpreter tracks a **GF(3) trit balance** across evaluation via `Resources.trit_balance`. Each value can be assigned a trit phase (+1, 0, −1) via `valueTrit()` / `tritPhase()`. The `accumulateTrit()` method accumulates balance modulo 3. `isConserved()` checks that the balance returns to 0. This provides a conservation law: well-formed computations should preserve the trit balance, analogous to charge conservation in physics.

### Fuel Termination

Every bounded eval path (`transduction.evalBounded`, `transclusion.denote`) is **guaranteed to terminate** via the fuel mechanism:
- `Resources.tick()` decrements fuel; returns `error.FuelExhausted` at 0.
- `Resources.descend()` checks depth against `max_depth`.
- Fuel cost is **depth-dependent** (via LUT), so adversarial deep nesting exhausts fuel faster.
- Default limit: 10 billion ticks — sufficient for any reasonable computation but finite.

### Denotational = Operational Agreement

The architecture explicitly separates three eval paths with the intent that they agree on well-formed inputs:
- **Denotational** (`transclusion.denote`): defines the meaning ⟦e⟧ρ
- **Operational** (`transduction.evalBounded`): defines how e evaluates step-by-step
- **Unbounded** (`eval.eval`): the full-featured path

The bounded paths share the `Domain` result type and `Resources` tracking, and the `checkSoundness` function in `transitivity.zig` provides machinery to verify agreement between them. The `semantics.zig` re-exports all three layers for backward compatibility.

### Reader Safety

- Max nesting depth 256 (CVE-3 fix)
- Skip/splice sentinels prevent injection of reader-conditional artifacts into runtime
- Source location tracking for error reporting
