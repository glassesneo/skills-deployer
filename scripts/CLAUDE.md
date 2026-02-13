# scripts/ — Bash Runtime Engine

`deploy-skills.bash` is the runtime deployment engine for `lib.mkDeploySkills`.
It is inlined into a Nix wrapper via `builtins.readFile` in `lib/mkDeploySkills.nix`.

## Interface Boundaries

- This script is part of the runtime app path (`nix run .#deploy-skills`).
- Home Manager module path (`homeManagerModules.skills-deployer`) does not execute this script.
- Declarative Home Manager deployment is produced through `programs.skills-deployer` -> `home.file` mappings.

## Shell Conventions

- First non-comment line must be `set -euo pipefail`.
- Constants/globals: `UPPER_CASE`. Local variables: `lower_case` with `local` keyword.
- Respect `NO_COLOR` env var for terminal output.

## Exit Codes (frozen contract — do not renumber)

- 0: Success / dry-run up-to-date  · 1: Dry-run pending changes
- 2: Unknown CLI argument  · 3: Not in project root
- 4: Internal error (manifest missing)  · 5: Validation failure  · 6: Unmanaged conflict

## Rules

- **IMPORTANT**: `MANIFEST_PATH` is injected by the Nix wrapper. Never hardcode manifest paths.
- Validate all skills before writing any files (fail-fast pattern).
- Use `atomic_replace()` for updates — never leave partial state on disk.
- `ENTRY_NAME` (from manifest entry's `name` field) is used for filesystem paths and marker writes. `SKILL_NAME` (manifest key) is used for ACTION_MAP lookups and log output. For existing single-target manifests, ENTRY_NAME == SKILL_NAME.
