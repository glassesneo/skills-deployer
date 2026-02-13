# tests/ — Test Suite

`run-tests.bash` is a TAP-format test suite. Run via `nix run .#test`
or directly: `bash tests/run-tests.bash` (requires `jq` on PATH).

## Conventions

- Test functions use semantic category prefixes:
  - `test_runtime_*` — Runtime deployment (single-target)
  - `test_runtime_multi_*` — Runtime deployment (multi-target)
  - `test_nix_*` — Nix eval-time validation
  - `test_hm_*` — Home Manager module
- Each test creates a temp workdir via `mktemp -d` and cleans up with `trap 'rm -rf "$workdir"' RETURN`.
- Tests requiring `nix eval --impure` are skipped when impure eval is unavailable (for example, inside Nix sandboxed builds) — this is expected.

## Fixtures

- `fixtures/valid-skill/` — `sub-a/` (SKILL.md, prompt.txt, .hidden-config) and `sub-b/` (SKILL.md only).
- `fixtures/empty-skill/` — No SKILL.md (used for validation failure tests).
- Never modify existing fixtures without updating all tests that reference them.

## Multi-Target Tests

- Multi-target tests (`test_runtime_multi_*`) use hand-crafted manifests with `@@` keys to simulate Nix-side expansion.
- Nix eval-time `targetDirs` validation is consolidated in `test_nix_targetdirs_validation_matrix`; expansion semantics remain in `test_nix_targetdirs_expansion`.
- Runtime name override + disabled cleanup safety contracts are covered in `test_runtime_name_override_paths_and_markers`, `test_runtime_cleanup_remove_dryrun_and_noop_contracts`, `test_runtime_cleanup_skip_safety_contracts`, and `test_runtime_lifecycle_enable_disable_reenable`.
- Name/enable eval semantics for `mkDeploySkills` are covered in `test_nix_name_override_reflected_in_manifest`, `test_nix_enable_false_reflected_in_disabled_payload`, `test_nix_enabled_destination_collision_fails`, `test_nix_enabled_disabled_destination_overlap_fails`, `test_nix_explicit_name_validation_matrix`, `test_nix_canonicalized_destination_conflict_matrix`, and `test_nix_disabled_skill_validation_matrix`.

## Rules

- **IMPORTANT**: Register every new test with `run_test test_<category>_...` in the appropriate category section at the bottom of the file.
- Use harness assertions (`assert_eq`, `assert_file_exists`, etc.) — not raw `test` or `[`.
- Every new feature or bug fix in `scripts/` or `lib/` must have a corresponding test here.
- Name new tests with the appropriate category prefix based on what they test:
  - Runtime deployment behavior → `test_runtime_*`
  - Multi-target deployment → `test_runtime_multi_*`
  - Nix eval-time validation → `test_nix_*`
  - Home Manager module → `test_hm_*`

## Home Manager Module Tests

- Home Manager module tests use the `test_hm_*` prefix.
- Use `eval_hm_module` for these tests; it stubs both `options.home.file` and `options.assertions`, then fails eval when any assertion is false before returning `home.file` JSON.
- These tests are eval-only; do not use `home-manager switch` in test coverage.
- `nix eval --impure` is required for `eval_hm_module`; skipping in sandboxed/non-impure environments is expected.
- Methodology: evaluate `modules/home-manager.nix` with `lib.evalModules` plus an inline stub to validate option behavior and `home.file` mapping output without Home Manager activation.
- Coverage includes:
  - Successful mapping behavior (disabled/empty/default/custom/override cases)
  - Required-option and base type-validation failures
  - Successful multi-target `targetDirs` mapping into multiple `home.file` entries
  - Matrix coverage for `targetDir`/`targetDirs` invariants and normalization-based duplicate rejection
  - Explicit/default `name` resolution in generated `home.file` keys
  - Matrix coverage for explicit invalid `name` values (`""`, `.`, `..`, `/`, `@@`)
  - Per-skill `enable=false` omission and destination collision rejection (including canonicalized targetDir forms)
