# lib/ — Nix API

Public API: `default.nix` exposes `mkDeploySkillsDrv` and `mkDeploySkills`.
Core logic: `mkDeploySkills.nix` compiles skill config into a deploy-skills wrapper.

## Contracts

- `mkDeploySkills.nix` takes `{ pkgs, skills, defaultMode ? "symlink", defaultTargetDir ? ".agents/skills" }`.
- Every SkillSpec requires `source` (Path) and `subdir` (String). Optional: `mode`, `targetDir`, `targetDirs`.
- `targetDirs` (list) and `targetDir` (string) are mutually exclusive. `targetDirs` expands to N manifest entries keyed `<name>@@<dir>`.
- Duplicate entries in `targetDirs` are rejected at eval time.
- Static schema validation (mode values, subdir traversal, absolute paths) uses Nix `assert` at eval time.

## Rules

- **IMPORTANT**: Never remove or rename public attributes in `default.nix` — consumers depend on `lib.mkDeploySkills` and `lib.mkDeploySkillsDrv`.
- Add new schema validations as `assert` expressions in `mkDeploySkills.nix`.
- Keep the type signature comment at the top of `mkDeploySkills.nix` in sync with actual parameters.
- Deploy script is inlined via `builtins.readFile ../scripts/deploy-skills.bash` — do not add Nix string interpolation to the Bash source.
