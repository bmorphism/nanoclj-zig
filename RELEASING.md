# Releasing nanoclj-zig

Three distribution paths are wired up:

## 1. GitHub Releases (binary tarballs)

Trigger by pushing a `v*` tag:

```bash
git tag -a v0.1.0 -m "first release"
git push origin v0.1.0
```

`.github/workflows/release.yml` builds on `ubuntu-latest` and
`macos-latest`, runs `zig fmt --check`, `zig build -Doptimize=ReleaseSafe`
and the full test suite, then attaches:

- `nanoclj-{linux-x86_64,darwin-arm64}` — main interpreter
- `nanoclj-mcp-*` — MCP server
- `gorj-mcp-*` — gorj MCP variant
- `nanoclj-strip-*` — minimal/stripped (~2MB)
- `nanoclj-*.wasm` — WASM build
- `SHA256SUMS-*` — checksums

## 2. Nix flake (source build, hermetic)

```bash
nix build github:plurigrid/nanoclj-zig
./result/bin/nanoclj
```

The flake (`flake.nix`) pins to the unstable nixpkgs `zig` to match what
CI uses. Outputs:

- `packages.default` — full build with all 4 main binaries
- `apps.default` — runs `nanoclj`
- `devShells.default` — shell with zig + git, suitable for `nix develop`

Building locally requires `../zig-syrup` as a sibling (the build pulls
syrup as a module via build.zig).

## 3. Flox environment + build

```bash
cd nanoclj-zig
flox activate           # installs zig + git, sets aliases
zig build               # local build, zig-out/bin/*
flox build nanoclj-zig  # flox-native, $out/bin/*
flox publish nanoclj-zig
```

Manifest at `.flox/env/manifest.toml` includes a `[build.nanoclj-zig]`
recipe matching the binaries the GH Actions release attaches.

## Toolchain note

CI uses `mlugg/setup-zig@v2` with `version: 0.16.0`. Local development
should use the same final 0.16.0 release, either from the wrapper at
`scripts/zig` or from `NANOCLJ_ZIG_016_DIR`.

Do not use pre-release snapshots for release checks. The final
0.16.0 compiler is the compatibility floor for CI, Flox, and local
wrapper-driven builds.

The Nix and Flox paths rely on each system's `pkgs.zig` / `flox install zig`
only when that package resolves to the final 0.16.0 release or newer.
