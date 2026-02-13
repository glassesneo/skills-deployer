# tests/ — Test Suite

`run-tests.bash` is a TAP-format test suite. Run via `nix run .#test`
or directly: `bash tests/run-tests.bash` (requires `jq` on PATH).

## Conventions

- Test functions: `test_TNN_descriptive_name()` (e.g., `test_T01_create_copy_single`).
- Numbering is sequential. New tests get the next available TNN number.
- Each test creates a temp workdir via `mktemp -d` and cleans up with `trap 'rm -rf' RETURN`.
- Tests requiring `nix eval --impure` are skipped in sandbox environments — this is expected.

## Fixtures

- `fixtures/valid-skill/` — `sub-a/` (SKILL.md, prompt.txt, .hidden-config) and `sub-b/` (SKILL.md only).
- `fixtures/empty-skill/` — No SKILL.md (used for validation failure tests).
- Never modify existing fixtures without updating all tests that reference them.

## Multi-Target Tests

- Multi-target tests (T25–T30, T33–T35) use hand-crafted manifests with `@@` keys to simulate Nix-side expansion.
- Nix eval-time tests (T31, T31b–T31d, T32) validate `targetDirs` expansion, mutual exclusion, and path validation.

## Rules

- **IMPORTANT**: Register every new test with `run_test test_TNN_...` at the bottom of the file.
- Use harness assertions (`assert_eq`, `assert_file_exists`, etc.) — not raw `test` or `[`.
- Every new feature or bug fix in `scripts/` or `lib/` must have a corresponding test here.

## Home Manager Module Tests

- Home Manager module tests use IDs `T42`–`T59`.
- Use `eval_hm_module` for these tests; it stubs both `options.home.file` and `options.assertions`, then fails eval when any assertion is false before returning `home.file` JSON.
- These tests are eval-only; do not use `home-manager switch` in test coverage.
- `nix eval --impure` is required for `eval_hm_module`; skipping in sandboxed/non-impure environments is expected.
- Methodology: evaluate `modules/home-manager.nix` with `lib.evalModules` plus an inline stub to validate option behavior and `home.file` mapping output without Home Manager activation.
