# tests/ — Test Suite

`run-tests.bash` is a TAP-format test suite. Run via `nix run .#test`
or directly: `bash tests/run-tests.bash` (requires `jq` on PATH).

## Conventions

- Test functions: `test_TNN_descriptive_name()` (e.g., `test_T01_create_copy_single`).
- Test IDs may contain intentional gaps after consolidation. New tests should use the next available TNN.
- Each test creates a temp workdir via `mktemp -d` and cleans up with `trap 'rm -rf "$workdir"' RETURN`.
- Tests requiring `nix eval --impure` are skipped when impure eval is unavailable (for example, inside Nix sandboxed builds) — this is expected.

## Fixtures

- `fixtures/valid-skill/` — `sub-a/` (SKILL.md, prompt.txt, .hidden-config) and `sub-b/` (SKILL.md only).
- `fixtures/empty-skill/` — No SKILL.md (used for validation failure tests).
- Never modify existing fixtures without updating all tests that reference them.

## Multi-Target Tests

- Multi-target tests (T25–T30, T33–T35) use hand-crafted manifests with `@@` keys to simulate Nix-side expansion.
- Nix eval-time `targetDirs` validation is consolidated in matrix test `T31`; expansion semantics remain in `T32`.
- Runtime name override + disabled cleanup safety contracts are covered in `T69`, `T72`, `T73`, and `T77`.
- Name/enable eval semantics for `mkDeploySkills` are covered in `T60`–`T64`, `T87`, and `T89`.

## Rules

- **IMPORTANT**: Register every new test with `run_test test_TNN_...` at the bottom of the file.
- Use harness assertions (`assert_eq`, `assert_file_exists`, etc.) — not raw `test` or `[`.
- Every new feature or bug fix in `scripts/` or `lib/` must have a corresponding test here.

## Home Manager Module Tests

- Home Manager module tests use IDs `T42`–`T52`, `T78`–`T80`, `T85`–`T86`, and `T93`.
- Use `eval_hm_module` for these tests; it stubs both `options.home.file` and `options.assertions`, then fails eval when any assertion is false before returning `home.file` JSON.
- These tests are eval-only; do not use `home-manager switch` in test coverage.
- `nix eval --impure` is required for `eval_hm_module`; skipping in sandboxed/non-impure environments is expected.
- Methodology: evaluate `modules/home-manager.nix` with `lib.evalModules` plus an inline stub to validate option behavior and `home.file` mapping output without Home Manager activation.
- Coverage split:
  - `T42`–`T47`: successful mapping behavior (disabled/empty/default/custom/override cases)
  - `T48`–`T50`: required-option and base type-validation failures
  - `T51`: successful multi-target `targetDirs` mapping into multiple `home.file` entries
  - `T52`: matrix coverage for `targetDir`/`targetDirs` invariants and normalization-based duplicate rejection
  - `T78`–`T79`: explicit/default `name` resolution in generated `home.file` keys
  - `T80`: matrix coverage for explicit invalid `name` values (`""`, `.`, `..`, `/`, `@@`)
  - `T85`–`T86`, `T93`: per-skill `enable=false` omission and destination collision rejection (including canonicalized targetDir forms)
