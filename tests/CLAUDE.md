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

## Rules

- **IMPORTANT**: Register every new test with `run_test test_TNN_...` at the bottom of the file.
- Use harness assertions (`assert_eq`, `assert_file_exists`, etc.) — not raw `test` or `[`.
- Every new feature or bug fix in `scripts/` or `lib/` must have a corresponding test here.