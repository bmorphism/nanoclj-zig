{
  description = "nanoclj-zig — Zig implementation of Clojure with the agent-o-nanoclj feedback-loop runtime";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Keep this aligned with CI: final Zig 0.16.0 is the release floor.
        zigPkg = pkgs.zig_0_16;

        # Build assumes plurigrid/zig-syrup is already checked out as a
        # sibling directory (matches the CI workflow). Nix-side: callers
        # set `ZIG_SYRUP_PATH` or fetch via fetchFromGitHub.
        nanoclj-zig = pkgs.stdenv.mkDerivation {
          pname = "nanoclj-zig";
          version =
            if self ? rev then builtins.substring 0 7 self.rev else "dev";
          src = self;

          nativeBuildInputs = [ zigPkg ];

          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-cache
            zig build -Doptimize=ReleaseSafe
          '';

          installPhase = ''
            mkdir -p $out/bin
            install -Dm755 zig-out/bin/nanoclj          $out/bin/nanoclj
            install -Dm755 zig-out/bin/nanoclj-mcp      $out/bin/nanoclj-mcp
            install -Dm755 zig-out/bin/gorj-mcp         $out/bin/gorj-mcp
            install -Dm755 zig-out/bin/nanoclj-strip    $out/bin/nanoclj-strip
          '';

          meta = with pkgs.lib; {
            description = "Zig implementation of Clojure (with agent-o-nanoclj feedback-loop runtime)";
            homepage = "https://github.com/plurigrid/nanoclj-zig";
            license = licenses.mit;
            platforms = platforms.unix;
          };
        };
      in {
        packages = {
          default = nanoclj-zig;
          nanoclj-zig = nanoclj-zig;
        };

        apps.default = {
          type = "app";
          program = "${nanoclj-zig}/bin/nanoclj";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [ zigPkg ];
          shellHook = ''
            echo "nanoclj-zig dev shell — zig $(${zigPkg}/bin/zig version)"
            echo "build: zig build"
            echo "test:  zig build test --summary all"
            echo "loop:  zig build loop-test --summary all"
          '';
        };
      });
}
