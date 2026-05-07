# ziggushka vs babashka — iteration 2 measurements (2026-04-29)

Both binaries built and run on M-series Apple Silicon. zg = `nanoclj-zig/zig-out/bin/nanoclj`. bb = bb 1.12.213.

## Cold-start `(+ 1 1)` (5-run median)

| metric | zg | bb | ratio |
|---|---:|---:|---:|
| Instructions retired | 23.5 M | 86 M | **3.7× fewer** |
| Cycles | 8.4 M | 44.7 M | **5.3× fewer** |
| Peak memory | 2.37 MB | 6.40 MB | **2.7× less** |
| Wall (~4 GHz) | ~2.1 ms | ~11.2 ms | **5.3× faster** |

## Binary footprint

| profile | size |
|---|---:|
| `nanoclj-embed-min` | 890 KB |
| `nanoclj-embed-safe` | 890 KB |
| `nanoclj` (REPL, full) | 1.99 MB |
| `nanoclj.wasm` | 794 KB |
| `nanoclj-mcp` | 5.6 MB |
| `gorj-mcp` | 5.7 MB |
| `sector.bin` (bare-metal) | 2.5 KB |
| bb (~) | ~70 MB |

zg embed-min is **~80× smaller** than bb.

## zg microbench (BMF-JSON, single-run, ReleaseFast)

Selected, ns/op (latency.value):

| bench | latency | notes |
|---|---:|---|
| `cold_start` (in-proc init) | 49 µs | not wall-clock; substrate startup |
| `reader_single_form` | 392 ns | parse one s-expr |
| `reader_1mb` (43 690 forms) | 18.1 ms (415 ns/form) | full parse pass |
| `flow_inhabit_3block` | 103 ns | flow operator overhead |
| `loop_tight_n1000` | 344 µs (344 ns/iter) | empty loop body |
| `map_reduce_n1000` | 24.6 µs (24.6 ns/iter) | fused map+reduce |
| `assoc_growth_n1024` | 3.78 ms (3.7 µs/insert) | persistent-map growth |
| `binary_trees_d10` | 3.36 ms | alloc/free intensive |
| `fib_n22` (interpreted) | 21 ms | naive recursive |
| `tak_18_12_6` | 24.4 ms | Gabriel classic |
| `ack_3_7` | 314 ms | Ackermann |
| `fib25_zig` (native) | 189 µs | direct Zig |
| `fib25_nanoclj` (interpreted) | 86 ms | **455× interpreter overhead vs native** |

The 455× nanoclj-vs-native gap is the load-bearing target for any future bytecode/comptime work.

## API parity probe (smoke test)

```clojure
(+ 1 2 3)                                ;; zg ✓ (6)            bb ✓ (6)
(* 2 3 4)                                ;; zg ✓ (24)           bb ✓ (24)
(clojure.string/upper-case "abc")        ;; zg ✗ (silent empty) bb ✓ ("ABC")
(clojure.string/split "a/b/c" #"/")      ;; zg ✗ (silent empty) bb ✓ ([a b c])
(assoc {} :a 1 :b 2)                     ;; zg ✓                bb ✓
(mapv inc [1 2 3 4 5])                   ;; zg ✓ ([2 3 4 5 6])  bb ✓
(reduce + 0 (range 10))                  ;; zg ✓ (45)           bb ✓
(require 'babashka.fs)                   ;; zg ✓ :ok (claimed)  bb ✓ :ok
```

Real gap: `clojure.string` is not auto-required in zg. bb auto-loads it. **Either name-based auto-require for the standard `clojure.*` set, or the silent-empty path needs to throw.** Logged as iteration-3 priority.

## Belt assessment after this iteration

| belt | promise | zg status |
|---|---|---|
| ⚪ White (kernel boots, hello-world runs) | done | **✓ shipped** |
| 🔵 Blue (95% bb scripts run, ≤2× perf gap) | partial | **clojure.string silent fail; needs probe pass** |
| 🟣 Purple (5/12 grid ops faster than bb) | unknown | **need port of grid.bb to run on zg** |
| 🟤 Brown | n/a | not yet |
| ⚫ Black | n/a | not yet |

## Already wins, measured

- Cold-start: 5.3× faster ✓
- Memory: 2.7× less ✓
- Binary size: 80× smaller (embed-min) ✓
- Substrate self-bench infrastructure: extensive ✓ (11 BMF-JSON benches)

## Already losses, measured

- `clojure.string` not auto-required (correctness gap)
- Interpreter overhead 455× vs native (the elephant)

## Next iteration

1. Port `bench/grid.bb` to a zg-compatible variant; run head-to-head; record CSV.
2. Probe ALL clojure.string fns; record availability matrix.
3. Probe babashka.fs surface — which of the 92 publics are wired.
4. Check if there's a comptime-monomorphization path for hot loops (the 455× interpreter gap is the only real blocker before considering SCI alternatives).
