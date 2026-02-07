{
  description = "Agent skills deployer - Nix flake library";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    eachSystem = f:
      nixpkgs.lib.genAttrs supportedSystems (system:
        f {
          inherit system;
          pkgs = nixpkgs.legacyPackages.${system};
        });
  in {
    lib = import ./lib;

    # Self-test app (uses fixtures)
    apps = eachSystem ({pkgs, ...}: {
      test = let
        src = self;
      in {
        type = "app";
        program = "${pkgs.writeShellApplication {
          name = "run-tests";
          runtimeInputs = [pkgs.jq pkgs.coreutils pkgs.nix];
          excludeShellChecks = ["SC2329"];
          text = ''
            export REPO_ROOT="${src}"
            bash "${src}/tests/run-tests.bash"
          '';
        }}/bin/run-tests";
      };
    });

    checks = eachSystem ({pkgs, ...}: {
      tests =
        pkgs.runCommand "skills-deployer-tests" {
          nativeBuildInputs = [pkgs.jq pkgs.coreutils pkgs.bash pkgs.nix];
          src = self;
        } ''
          export REPO_ROOT="$src"
          # nix eval needs a writable home for cache
          export HOME="$(mktemp -d)"
          bash "$src/tests/run-tests.bash"
          touch "$out"
        '';
    });

    devShells = eachSystem ({pkgs, ...}: {
      default = pkgs.mkShell {
        packages = [pkgs.jq pkgs.shellcheck pkgs.bash];
      };
    });
  };
}
