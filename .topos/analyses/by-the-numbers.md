# nanoclj-zig — by-the-numbers snapshot

> Generated: 2026-04-25.

## Codebase size

| Area                  | Lines   | Files |
|-----------------------|---------|-------|
| `src/*.zig` (top-level) | 53,496 | —     |
| `src/loop/*.zig`       | 6,126  | —     |
| **Total src/**         | **59,622** | **120** |
| `test/*.clj` (Clojure) | 828    | 7     |
| `examples/*.clj`       | —      | 15    |
| `docs/*.md`            | —      | 12    |

## Largest files (top-level `src/*.zig`)

| File                  | Lines |
|-----------------------|-------|
| `core.zig`            | 5,824 |
| `computable_sets.zig` | 1,948 |
| `eval.zig`            | 1,873 |
| `compiler.zig`        | 1,707 |
| `gorj_mcp.zig`        | 1,703 |
| `open_game.zig`       | 1,689 |
| `sector.zig`          | 1,516 |
| `transduction.zig`    | 1,329 |
| `juvix_bridge.zig`    | 1,136 |
| `flow.zig`            | 1,071 |
| `skill_inet.zig`      | 1,055 |
| `kanren.zig`          | 1,036 |
| `main.zig`            | 997   |
| `reader.zig`          | 958   |
| `datalog.zig`         | 904   |
| `nrepl.zig`           | 874   |
| `church_turing.zig`   | 861   |
| `bytecode.zig`        | 820   |
| `decomp.zig`          | 798   |

## Loop subsystem (`src/loop/*.zig`)

| File                    | Lines |
|------------------------|-------|
| `curricula.zig`        | 716   |
| `feedback.zig`         | 676   |
| `cycle.zig`            | 668   |
| `trace.zig`            | 577   |
| `action.zig`           | 423   |
| `eval.zig`             | 409   |
| `telemetry.zig`        | 382   |
| `gradient.zig`         | 311   |
| `experiment.zig`       | 311   |
| `topology.zig`         | 308   |
| `world_test.zig`       | 269   |
| `bench_skills.zig`     | 224   |
| `checkpoint.zig`       | 207   |
| `tool.zig`             | 131   |
| **Total loop**         | **6,126** |

## Activity

| Metric                          | Value                        |
|---------------------------------|------------------------------|
| Total commits                   | 223                          |
| First commit                    | 2026-04-03 13:50:17 -0700   |
| Latest commit                   | 2026-04-25 00:29:02 -0700   |
| Project age                     | ~22 days                     |
| Commits last 5 days (since 4/20)| 45                           |
| Average pace (overall)          | ~10 commits/day              |
| Recent pace (last 5 days)       | 9 commits/day                |

## Contributors

| Commits | Author                                              |
|---------|-----------------------------------------------------|
| 218     | freemorphism+github@gmail.com                       |
| 2       | freemorphism@gmail.com                               |
| 1       | monaduck1069@users.noreply.github.com               |
| 1       | 93168455+zubyul@users.noreply.github.com            |
| 1       | 157643399+danielesiegel@users.noreply.github.com    |

Effectively a single-author project (220/223 commits = 98.7%).

## Test coverage (Zig tests per file, top-10)

| File                      | Test count |
|--------------------------|------------|
| `compiler.zig`           | 46         |
| `loop/curricula.zig`     | 20         |
| `reader.zig`             | 19         |
| `flow.zig`               | 19         |
| `regex.zig`              | 16         |
| `loop/eval.zig`          | 16         |
| `time_units.zig`         | 15         |
| `spi_bus.zig`            | 15         |
| `loop/trace.zig`         | 14         |
| `pluralism.zig`          | 13         |

Loop subsystem self-reports **83 tests** via `(loop-test-count)`.

## Clojure test files

| File                   | Lines |
|-----------------------|-------|
| `test/edge-cases.clj`  | 255   |
| `test/test_core.clj`   | 144   |
| `test/test_advanced.clj`| 112  |
| `test/regression_69_r3.clj`| 102 |
| `test/regression_69_r2.clj`| 98 |
| `test/regression_69.clj`| 94   |
| `test/bench.clj`       | 23    |
| **Total**              | **828** |

## TODOs / FIXMEs / HACKs

| File                 | Count |
|---------------------|-------|
| `spi.zig`           | 2     |
| `sector_boot.zig`   | 2     |
| `llm.zig`           | 2     |
| `tree_vfs.zig`      | 1     |
| `substrate.zig`     | 1     |
| `nrepl.zig`         | 1     |
| `gorj_mcp.zig`      | 1     |
| **Total**           | **10** |

Very low TODO debt — 10 markers across the entire codebase.

## Summary

- **~60K lines of Zig** across 120 files in 22 days = ~2,700 lines/day.
- **Loop subsystem**: 6,126 lines (10.3% of codebase), 83 tests, 4 curricula.
- **Single-author velocity**: 223 commits in 22 days ≈ 10 commits/day.
- **Minimal tech debt markers**: 10 TODOs/FIXMEs/HACKs.
