{
  description = "Agent skills deployer - Nix flake library";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    eachSystem = f:
      nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed (system:
        f {
          inherit system;
          pkgs = nixpkgs.legacyPackages.${system};
        });
  in {
    lib = import ./lib;
    homeManagerModules.skills-deployer = import ./modules/home-manager.nix;

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
