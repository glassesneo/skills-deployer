# skills-deployer

Nix flake library + Bash runtime that deploys agent skill directories.
See @README.md for full usage and API reference.

## Build & Run
- Enter dev shell: `nix develop`
- Run tests: `nix run .#test` (or `bash tests/run-tests.bash` with jq on PATH)
- Check all platforms: `nix flake check`
- Runtime consumer usage: `nix run .#deploy-skills` (available in projects that call `lib.mkDeploySkills`)
- Home Manager consumer usage: import `homeManagerModules.skills-deployer` and configure `programs.skills-deployer`

## Commit Workflow
- **IMPORTANT**: Always run `nix run .#test` before committing. No failing tests; documented skips are acceptable.
- **IMPORTANT**: Run `shellcheck scripts/deploy-skills.bash` before committing Bash changes.
- Preserve existing Nix formatting style. Avoid mass reformats.

## Coding Standards
- Nix: 2-space indent, `let ... in` on separate lines. Match surrounding code style.
- Bash: `set -euo pipefail` as first non-comment line. `UPPER_CASE` for constants/globals, `lower_case` for locals.
- Shell scripts must pass `shellcheck` with zero warnings (targeted disables like `SC2154` are acceptable).

## Architecture
- `lib/` — Runtime Nix API: eval-time config compilation and validation. Public API: `lib.mkDeploySkills`.
- `scripts/` — Bash runtime deployment engine inlined into a Nix wrapper at build time.
- `modules/` — Home Manager module API (`programs.skills-deployer`) that compiles config into `home.file` entries.
- `tests/` — TAP-style Bash test suite with fixture-based integration tests and eval-time module tests.

## Testing Notes
- Runtime deployment behavior is covered by script/integration tests.
- Home Manager module behavior is covered by eval-only tests (`eval_hm_module`) and does not run `home-manager switch`.

## License
MIT. See @LICENSE.
