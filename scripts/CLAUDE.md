# scripts/ — Bash Runtime Engine

`deploy-skills.bash` is the deployment engine. It is inlined into a Nix wrapper
via `builtins.readFile` in `lib/mkDeploySkills.nix` — it is not executed directly.

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