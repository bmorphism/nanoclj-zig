# Goals

## North Star

Provide a small Zig-hosted Clojure interpreter with explicit fuel, NaN-boxed
values, and interaction-net-friendly semantics.

## Near-Term Goals

- Keep the evaluator bounded, inspectable, and testable under fuel limits.
- Stabilize the value representation and interop boundary.
- Preserve examples that demonstrate CLI use, dependency use, and format triads.
- Coordinate syntax changes with `tree-sitter-nanoclj-zig`.

## Next Expansion

Make the interpreter a reliable embedded scripting kernel for agent tools:
small enough to audit, expressive enough for local transformations, and strict
enough to avoid unbounded agent-side computation.

## GF(3) Check

- MINUS: eliminate unbounded eval paths and representation ambiguity.
- ERGODIC: maintain stable CLI and dependency integration.
- PLUS: add forms only when parser, tests, and examples move together.



<!-- plurigrid-recency:start -->
## Plurigrid Recency Update

Date: 2026-05-07

- Repo: `nanoclj-zig`
- Created: `2026-04-03T23:22:58Z`
- Pushed: `2026-04-25T07:29:09Z`
- Updated: `2026-04-25T07:29:13Z`
- Inclusion: created in 2026.
- Current role: syntax, terminal, and parser substrate.

Story update: this repo now participates in the March-May 2026 recency mesh.
Keep its next delta tied to a visible command, artifact, or interface boundary
so the org-level story remains replayable instead of merely narrated.
<!-- plurigrid-recency:end -->
