#!/usr/bin/env bash
# Test harness for deploy-skills.bash
# Implements the full 22-test matrix from the plan.
# Output: TAP-like format. Exit 0 if all pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$SCRIPT_DIR/..}"
DEPLOY_SCRIPT="$REPO_ROOT/scripts/deploy-skills.bash"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"

# -- Test harness ------------------------------------------------
PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  if [[ "$actual" == "$expected" ]]; then return 0; fi
  printf "    ASSERT FAILED: expected '%s', got '%s' %s\n" "$expected" "$actual" "$msg" >&2
  return 1
}

assert_file_exists() {
  [[ -f "$1" ]] || { printf "    ASSERT FAILED: file not found: %s\n" "$1" >&2; return 1; }
}

assert_dir_exists() {
  [[ -d "$1" ]] || { printf "    ASSERT FAILED: directory not found: %s\n" "$1" >&2; return 1; }
}

assert_symlink() {
  [[ -L "$1" ]] || { printf "    ASSERT FAILED: not a symlink: %s\n" "$1" >&2; return 1; }
}

assert_not_symlink() {
  [[ ! -L "$1" ]] || { printf "    ASSERT FAILED: should not be a symlink: %s\n" "$1" >&2; return 1; }
}

assert_not_exists() {
  [[ ! -e "$1" ]] || { printf "    ASSERT FAILED: should not exist: %s\n" "$1" >&2; return 1; }
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then return 0; fi
  printf "    ASSERT FAILED: output does not contain '%s' %s\n" "$needle" "$msg" >&2
  return 1
}

assert_file_content_eq() {
  local filepath="$1" expected="$2" msg="${3:-}"
  local actual
  actual=$(cat "$filepath")
  if [[ "$actual" == "$expected" ]]; then return 0; fi
  printf "    ASSERT FAILED: file content mismatch for %s. Expected '%s', got '%s' %s\n" "$filepath" "$expected" "$actual" "$msg" >&2
  return 1
}

run_test() {
  local name="$1"
  TOTAL=$((TOTAL + 1))
  local output=""
  if output=$("$name" 2>&1); then
    PASS=$((PASS + 1))
    printf "ok %d - %s\n" "$TOTAL" "$name"
  else
    FAIL=$((FAIL + 1))
    printf "not ok %d - %s\n" "$TOTAL" "$name"
    if [[ -n "$output" ]]; then
      printf "%s\n" "$output" | sed 's/^/    # /'
    fi
  fi
}

skip_test() {
  local name="$1" reason="$2"
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  printf "ok %d - %s # SKIP %s\n" "$TOTAL" "$name" "$reason"
}

# Detect Nix build sandbox: NIX_BUILD_TOP is set inside nix-build/nix flake check
IN_NIX_SANDBOX="${NIX_BUILD_TOP:-}"
NIX_EVAL_AVAILABLE=true
if ! nix eval --impure --raw --expr '1' >/dev/null 2>&1; then
  NIX_EVAL_AVAILABLE=false
fi

# -- Helper: create a manifest JSON for a single skill -----------
make_manifest() {
  # Usage: make_manifest skill_name source_path mode target_dir subdir
  local name="$1" source_path="$2" mode="$3" target_dir="$4" subdir="$5"
  cat <<EOF
{
  "$name": {
    "name": "$name",
    "mode": "$mode",
    "subdir": "$subdir",
    "targetDir": "$target_dir",
    "sourcePath": "$source_path"
  }
}
EOF
}

# -- Helper: run deploy script in a workdir ---------------------
run_deploy() {
  local workdir="$1" manifest="$2"
  shift 2
  local exit_code=0
  (cd "$workdir" && MANIFEST_PATH="$manifest" bash "$DEPLOY_SCRIPT" "$@") || exit_code=$?
  return "$exit_code"
}

run_deploy_capture() {
  local workdir="$1" manifest="$2"
  shift 2
  local exit_code=0
  (cd "$workdir" && MANIFEST_PATH="$manifest" bash "$DEPLOY_SCRIPT" "$@" 2>&1) || exit_code=$?
  return "$exit_code"
}

# ================================================================
# T01: create_copy_single
# ================================================================
test_T01_create_copy_single() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  make_manifest "my-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json") || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_file_exists "$workdir/.agents/skills/my-skill/SKILL.md"
  assert_file_exists "$workdir/.agents/skills/my-skill/prompt.txt"
  assert_file_exists "$workdir/.agents/skills/my-skill/$MARKER_FILENAME"
  # Verify it's a copy, not a symlink
  assert_not_symlink "$workdir/.agents/skills/my-skill/SKILL.md"
}

# ================================================================
# T02: create_symlink_single
# ================================================================
test_T02_create_symlink_single() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  make_manifest "my-skill" "$workdir/source-skill" "symlink" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json") || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_file_exists "$workdir/.agents/skills/my-skill/SKILL.md"
  assert_symlink "$workdir/.agents/skills/my-skill/SKILL.md"
  assert_symlink "$workdir/.agents/skills/my-skill/prompt.txt"
  assert_file_exists "$workdir/.agents/skills/my-skill/$MARKER_FILENAME"
}

# ================================================================
# T03: create_multiple
# ================================================================
test_T03_create_multiple() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-a"
  cp -R "$FIXTURES_DIR/valid-skill/sub-b" "$workdir/source-b"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-c"

  cat > "$workdir/manifest.json" <<EOF
{
  "skill-a": {
    "name": "skill-a",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-a"
  },
  "skill-b": {
    "name": "skill-b",
    "mode": "symlink",
    "subdir": "sub-b",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-b"
  },
  "skill-c": {
    "name": "skill-c",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-c"
  }
}
EOF

  local exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_file_exists "$workdir/.agents/skills/skill-a/SKILL.md"
  assert_file_exists "$workdir/.agents/skills/skill-b/SKILL.md"
  assert_file_exists "$workdir/.agents/skills/skill-c/SKILL.md"
  assert_not_symlink "$workdir/.agents/skills/skill-a/SKILL.md"
  assert_symlink "$workdir/.agents/skills/skill-b/SKILL.md"
  assert_not_symlink "$workdir/.agents/skills/skill-c/SKILL.md"
}

# ================================================================
# T04: idempotent_rerun
# ================================================================
test_T04_idempotent_rerun() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  make_manifest "my-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  # First run
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null

  # Second run
  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json") || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_contains "$output" "up-to-date" "should skip"
  assert_contains "$output" "0 skill(s) deployed" "nothing deployed on rerun"
}

# ================================================================
# T05: mode_change_copy_to_symlink
# ================================================================
test_T05_mode_change_copy_to_symlink() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  # Deploy as copy first
  make_manifest "my-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null

  assert_not_symlink "$workdir/.agents/skills/my-skill/SKILL.md"

  # Change to symlink
  make_manifest "my-skill" "$workdir/source-skill" "symlink" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  local exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_symlink "$workdir/.agents/skills/my-skill/SKILL.md"
  # Verify marker updated
  local marker_mode
  marker_mode=$(jq -r '.mode' "$workdir/.agents/skills/my-skill/$MARKER_FILENAME")
  assert_eq "$marker_mode" "symlink" "marker mode updated"
}

# ================================================================
# T06: mode_change_symlink_to_copy
# ================================================================
test_T06_mode_change_symlink_to_copy() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  # Deploy as symlink first
  make_manifest "my-skill" "$workdir/source-skill" "symlink" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null

  assert_symlink "$workdir/.agents/skills/my-skill/SKILL.md"

  # Change to copy
  make_manifest "my-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  local exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_not_symlink "$workdir/.agents/skills/my-skill/SKILL.md"
  local marker_mode
  marker_mode=$(jq -r '.mode' "$workdir/.agents/skills/my-skill/$MARKER_FILENAME")
  assert_eq "$marker_mode" "copy" "marker mode updated"
}

# ================================================================
# T07: source_update
# ================================================================
test_T07_source_update() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-v1"

  make_manifest "my-skill" "$workdir/source-v1" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null

  # Create a new source version
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-v2"
  echo "updated content" > "$workdir/source-v2/prompt.txt"

  make_manifest "my-skill" "$workdir/source-v2" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  local exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  # Verify marker updated with new source
  local marker_source
  marker_source=$(jq -r '.sourcePath' "$workdir/.agents/skills/my-skill/$MARKER_FILENAME")
  assert_eq "$marker_source" "$workdir/source-v2" "marker source updated"
}

# ================================================================
# T08: dry_run_no_changes
# ================================================================
test_T08_dry_run_no_changes() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  make_manifest "my-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  # Deploy first
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null

  # Dry run - should show no changes
  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json" --dry-run) || exit_code=$?

  assert_eq "$exit_code" 0 "exit code should be 0 when up-to-date"
  assert_contains "$output" "up-to-date" "should say up-to-date"
}

# ================================================================
# T09: dry_run_with_changes
# ================================================================
test_T09_dry_run_with_changes() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  make_manifest "my-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json" --dry-run) || exit_code=$?

  assert_eq "$exit_code" 1 "exit code should be 1 when changes pending"
  assert_contains "$output" "CREATE" "should show CREATE action"
  assert_contains "$output" "change(s) would be applied" "should warn about changes"
  # Verify no files were created
  assert_not_exists "$workdir/.agents/skills/my-skill"
}

# ================================================================
# T10: validation_missing_skillmd
# ================================================================
test_T10_validation_missing_skillmd() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/empty-skill" "$workdir/source-skill"

  make_manifest "bad-skill" "$workdir/source-skill" "copy" ".agents/skills" "empty-skill" \
    > "$workdir/manifest.json"

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json") || exit_code=$?

  assert_eq "$exit_code" 5 "exit code should be 5 for validation failure"
  assert_contains "$output" "SKILL.md not found" "should mention SKILL.md"
  assert_contains "$output" "bad-skill" "should name the skill"
}

# ================================================================
# T11: validation_subdir_traversal (Nix eval-time)
# Skipped in runtime tests -- this is a Nix eval assertion.
# We test it by invoking nix eval directly.
# ================================================================
test_T11_validation_subdir_traversal() {
  local exit_code=0
  local output
  output=$(nix eval --impure --raw --expr '
    let
      pkgs = import <nixpkgs> {};
      mkDeploySkills = import '"$REPO_ROOT"'/lib/mkDeploySkills.nix;
      drv = mkDeploySkills {
        inherit pkgs;
        skills = {
          bad-skill = {
            source = ./. ;
            subdir = "../etc";
          };
        };
      };
    in builtins.toJSON drv.drvAttrs
  ' 2>&1) || exit_code=$?

  # Should fail (non-zero exit)
  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should have failed for subdir with '..'\n" >&2
    return 1
  fi
  assert_contains "$output" "forbidden" "should mention forbidden in error"
}

# ================================================================
# T12: validation_absolute_subdir (Nix eval-time)
# ================================================================
test_T12_validation_absolute_subdir() {
  local exit_code=0
  local output
  output=$(nix eval --impure --raw --expr '
    let
      pkgs = import <nixpkgs> {};
      mkDeploySkills = import '"$REPO_ROOT"'/lib/mkDeploySkills.nix;
      drv = mkDeploySkills {
        inherit pkgs;
        skills = {
          bad-skill = {
            source = ./. ;
            subdir = "/etc";
          };
        };
      };
    in builtins.toJSON drv.drvAttrs
  ' 2>&1) || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should have failed for absolute subdir\n" >&2
    return 1
  fi
  assert_contains "$output" "must be relative" "should mention 'must be relative' in error"
}

# ================================================================
# T13: conflict_unmanaged
# ================================================================
test_T13_conflict_unmanaged() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  # Pre-create the target without a marker
  mkdir -p "$workdir/.agents/skills/my-skill"
  echo "user content" > "$workdir/.agents/skills/my-skill/something.txt"

  make_manifest "my-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json") || exit_code=$?

  assert_eq "$exit_code" 6 "exit code should be 6 for conflict"
  assert_contains "$output" "Conflict" "should say Conflict"
  assert_contains "$output" "Remediation" "should provide remediation"
}

# ================================================================
# T14: not_project_root
# ================================================================
test_T14_not_project_root() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  # Intentionally do NOT create flake.nix
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  make_manifest "my-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json") || exit_code=$?

  assert_eq "$exit_code" 3 "exit code should be 3 for missing flake.nix"
  assert_contains "$output" "flake.nix not found" "should mention flake.nix"
}

# ================================================================
# T15: custom_target_dir
# ================================================================
test_T15_custom_target_dir() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  make_manifest "my-skill" "$workdir/source-skill" "copy" ".claude/skills" "sub-a" \
    > "$workdir/manifest.json"

  local exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_file_exists "$workdir/.claude/skills/my-skill/SKILL.md"
  assert_file_exists "$workdir/.claude/skills/my-skill/$MARKER_FILENAME"
}

# ================================================================
# T16: per_skill_target_override
# ================================================================
test_T16_per_skill_target_override() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-a"
  cp -R "$FIXTURES_DIR/valid-skill/sub-b" "$workdir/source-b"

  cat > "$workdir/manifest.json" <<EOF
{
  "skill-a": {
    "name": "skill-a",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-a"
  },
  "skill-b": {
    "name": "skill-b",
    "mode": "copy",
    "subdir": "sub-b",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-b"
  }
}
EOF

  local exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_file_exists "$workdir/.agents/skills/skill-a/SKILL.md"
  assert_file_exists "$workdir/.claude/skills/skill-b/SKILL.md"
}

# ================================================================
# T17: unknown_arg
# ================================================================
test_T17_unknown_arg() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  make_manifest "my-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json" --foo) || exit_code=$?

  assert_eq "$exit_code" 2 "exit code should be 2 for unknown arg"
  assert_contains "$output" "Unknown argument" "should mention unknown argument"
}

# ================================================================
# T18: help_flag
# ================================================================
test_T18_help_flag() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  make_manifest "my-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json" --help) || exit_code=$?

  assert_eq "$exit_code" 0 "exit code should be 0"
  assert_contains "$output" "Usage:" "should show usage"
  assert_contains "$output" "--dry-run" "should mention --dry-run"
}

# ================================================================
# T19: marker_content
# ================================================================
test_T19_marker_content() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  make_manifest "my-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null

  local marker="$workdir/.agents/skills/my-skill/$MARKER_FILENAME"
  assert_file_exists "$marker"

  local version skill_name mode source_path deployed_at
  version=$(jq -r '.version' "$marker")
  skill_name=$(jq -r '.skillName' "$marker")
  mode=$(jq -r '.mode' "$marker")
  source_path=$(jq -r '.sourcePath' "$marker")
  deployed_at=$(jq -r '.deployedAt' "$marker")

  assert_eq "$version" "1" "version"
  assert_eq "$skill_name" "my-skill" "skillName"
  assert_eq "$mode" "copy" "mode"
  assert_eq "$source_path" "$workdir/source-skill" "sourcePath"
  # deployedAt should match ISO 8601 pattern
  if [[ ! "$deployed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    printf "    ASSERT FAILED: deployedAt '%s' does not match ISO 8601 pattern\n" "$deployed_at" >&2
    return 1
  fi
}

# ================================================================
# T20: no_skills_configured
# ================================================================
test_T20_no_skills_configured() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  echo '{}' > "$workdir/manifest.json"

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json") || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_contains "$output" "No skills configured" "should say no skills"
}

# ================================================================
# T21: symlink_hidden_files
# ================================================================
test_T21_symlink_hidden_files() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  make_manifest "my-skill" "$workdir/source-skill" "symlink" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"

  local exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  # .hidden-config from the fixture should be symlinked
  assert_symlink "$workdir/.agents/skills/my-skill/.hidden-config"
  # Verify content is accessible through symlink
  local content
  content=$(cat "$workdir/.agents/skills/my-skill/.hidden-config")
  assert_contains "$content" "hidden config content" "hidden file content"
}

# ================================================================
# T22: atomic_replace_no_partial
# ================================================================
test_T22_atomic_replace_no_partial() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-v1"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-v2"
  echo "v2 content" > "$workdir/source-v2/extra.txt"

  # Deploy v1
  make_manifest "my-skill" "$workdir/source-v1" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null

  # Deploy v2 (triggers atomic replace)
  make_manifest "my-skill" "$workdir/source-v2" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest.json"
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null

  # Verify: no tmp or old directories remain
  assert_not_exists "$workdir/.agents/skills/my-skill.skills-deployer-tmp"
  assert_not_exists "$workdir/.agents/skills/my-skill.skills-deployer-old"

  # Verify: skill is in v2 state
  assert_file_exists "$workdir/.agents/skills/my-skill/SKILL.md"
  assert_file_exists "$workdir/.agents/skills/my-skill/$MARKER_FILENAME"
  local marker_source
  marker_source=$(jq -r '.sourcePath' "$workdir/.agents/skills/my-skill/$MARKER_FILENAME")
  assert_eq "$marker_source" "$workdir/source-v2" "marker points to v2"
}

# ================================================================
# T23: symlink_no_dotfiles (regression: no bogus .* symlink)
# ================================================================
test_T23_symlink_no_dotfiles() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  # Create a skill source with NO hidden files
  cp -R "$FIXTURES_DIR/valid-skill/sub-b" "$workdir/source-skill"

  make_manifest "my-skill" "$workdir/source-skill" "symlink" ".agents/skills" "sub-b" \
    > "$workdir/manifest.json"

  local exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_file_exists "$workdir/.agents/skills/my-skill/SKILL.md"
  assert_symlink "$workdir/.agents/skills/my-skill/SKILL.md"
  # There should be NO bogus ".*" literal symlink
  assert_not_exists "$workdir/.agents/skills/my-skill/.*"
  # Count entries: should only be SKILL.md + marker
  local entry_count
  entry_count=$(find "$workdir/.agents/skills/my-skill" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
  assert_eq "$entry_count" "2" "should only have SKILL.md + marker, got $entry_count entries"
}

# ================================================================
# T24: default_mode_implicit_symlink (mkDeploySkills default)
# ================================================================
test_T24_default_mode_implicit_symlink() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  cat > "$workdir/program-path.nix" <<EOF
let
  pkgs = import <nixpkgs> {};
  lib = import "$REPO_ROOT/lib";
  app = lib.mkDeploySkills pkgs {
    skills = {
      my-skill = {
        source = "$workdir/source-skill";
        subdir = "sub-a";
      };
    };
  };
in app.program
EOF

  local program_path output exit_code=0
  program_path=$(nix eval --impure --raw --file "$workdir/program-path.nix" 2>&1) || exit_code=$?
  assert_eq "$exit_code" 0 "nix eval should produce deploy-skills program path"

  output=$(cd "$workdir" && "$program_path" 2>&1) || exit_code=$?
  assert_eq "$exit_code" 0 "deploy should succeed when default mode is omitted"
  assert_contains "$output" "created (symlink)" "should create using symlink mode"

  assert_file_exists "$workdir/.agents/skills/my-skill/SKILL.md"
  assert_symlink "$workdir/.agents/skills/my-skill/SKILL.md"

  local marker_mode
  marker_mode=$(jq -r '.mode' "$workdir/.agents/skills/my-skill/$MARKER_FILENAME")
  assert_eq "$marker_mode" "symlink" "marker mode should match implicit default"
}

# ================================================================
# Run all tests
# ================================================================
MARKER_FILENAME=".skills-deployer-managed"

echo "TAP version 13"

run_test test_T01_create_copy_single
run_test test_T02_create_symlink_single
run_test test_T03_create_multiple
run_test test_T04_idempotent_rerun
run_test test_T05_mode_change_copy_to_symlink
run_test test_T06_mode_change_symlink_to_copy
run_test test_T07_source_update
run_test test_T08_dry_run_no_changes
run_test test_T09_dry_run_with_changes
run_test test_T10_validation_missing_skillmd
if [[ -n "$IN_NIX_SANDBOX" || "$NIX_EVAL_AVAILABLE" != "true" ]]; then
  skip_test test_T11_validation_subdir_traversal "requires nix eval --impure (unavailable in this environment)"
  skip_test test_T12_validation_absolute_subdir "requires nix eval --impure (unavailable in this environment)"
  skip_test test_T24_default_mode_implicit_symlink "requires nix eval --impure (unavailable in this environment)"
else
  run_test test_T11_validation_subdir_traversal
  run_test test_T12_validation_absolute_subdir
  run_test test_T24_default_mode_implicit_symlink
fi
run_test test_T13_conflict_unmanaged
run_test test_T14_not_project_root
run_test test_T15_custom_target_dir
run_test test_T16_per_skill_target_override
run_test test_T17_unknown_arg
run_test test_T18_help_flag
run_test test_T19_marker_content
run_test test_T20_no_skills_configured
run_test test_T21_symlink_hidden_files
run_test test_T22_atomic_replace_no_partial
run_test test_T23_symlink_no_dotfiles

echo ""
echo "1..$TOTAL"
echo "# pass $PASS"
echo "# fail $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
