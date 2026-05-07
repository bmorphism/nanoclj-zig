# Format Triad

nanoclj-zig should not make one format carry every job. The sharper split is:

```
colon config (+1) -> csexp-like tree (0) -> Syrup wire (-1)
```

The trit sum is zero, so the path is balanced: authorable configuration creates options, a neutral tree form stabilizes shape, and canonical Syrup collapses the result into typed bytes.

## Current Anchors

| Trit | Layer | Role | Code anchor |
|---:|---|---|---|
| +1 | colon config | human/agent authoring surface for tools, sessions, and options | `src/bencode.zig` already parses length-prefixed atoms |
| 0 | csexp-like tree | neutral shape carrier for inspection, diffs, and deterministic lowering | `src/csexp.zig`, `src/reader.zig`, `src/printer.zig`, and the bencode scanner primitives |
| -1 | Syrup wire | canonical typed wire/storage form for MCP, Braid, signing, and capability transport | `src/syrup_bridge.zig`, `src/lokke_bridge.zig`, `src/braid.zig`, `src/gorj_bridge.zig` |

## Existing Split

`src/syrup_bridge.zig` is the compact MCP/Braid lane. It intentionally accepts lossy Clojure collapses such as keyword-to-symbol and vector-to-list when the caller only needs ordinary wire framing.

`src/lokke_bridge.zig` is the higher-fidelity Clojure lane. It uses tagged Syrup records for values such as keywords, vectors, and lists, and it fails loudly where a real session context is needed.

`src/gorj_bridge.zig` already highlights the performance win: `(gorj-encode val)` returns raw Syrup bytes as a string, and `(gorj-decode bytes)` consumes raw Syrup bytes. That keeps the bridge out of the old bytes-to-hex-to-bytes loop.

`src/braid.zig` already makes the wire boundary concrete with `Content-Type: application/syrup` and GF(3)-tracked version patches.

## Upgrade Path

1. Keep `src/csexp.zig` as the neutral tree module.
2. Reuse the colon length-prefix scanner shape from `src/bencode.zig`, but keep the module independent from nREPL bencode semantics.
3. Add a single lowering path: config atoms -> csexp tree -> Syrup value.
4. Keep `syrup_bridge.zig` compact and document its lossy profile.
5. Move lossless Clojure round-trips through `lokke_bridge.zig`.
6. Expose one diagnostic builtin, for example `(gorj-format-triad x)`, returning the printed tree shape, Syrup byte length, lane name, and trit sum.

## Tests To Add

- `gorj-encode`/`gorj-decode` round-trips raw bytes without hex expansion.
- csexp parsing preserves nested list and atom shape before the Syrup boundary.
- map key reorderings produce the same canonical Syrup bytes.
- the declared format trits stay `(+1 0 -1)`, with sum `0 mod 3`.

## Rule

csexp-like trees may inspect and stabilize shape; Syrup alone is the canonical boundary.
