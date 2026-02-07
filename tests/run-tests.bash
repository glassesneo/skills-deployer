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
# T25: multi_target_basic
# ================================================================
test_T25_multi_target_basic() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  cat > "$workdir/manifest.json" <<EOF
{
  "my-skill@@.agents/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-skill"
  },
  "my-skill@@.claude/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF

  local exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_file_exists "$workdir/.agents/skills/my-skill/SKILL.md"
  assert_file_exists "$workdir/.claude/skills/my-skill/SKILL.md"
  assert_file_exists "$workdir/.agents/skills/my-skill/$MARKER_FILENAME"
  assert_file_exists "$workdir/.claude/skills/my-skill/$MARKER_FILENAME"
}

# ================================================================
# T26: multi_target_idempotent
# ================================================================
test_T26_multi_target_idempotent() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  cat > "$workdir/manifest.json" <<EOF
{
  "my-skill@@.agents/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-skill"
  },
  "my-skill@@.claude/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF

  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null
  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json") || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_contains "$output" "0 skill(s) deployed" "nothing deployed on rerun"
}

# ================================================================
# T27: multi_target_incremental_add
# ================================================================
test_T27_multi_target_incremental_add() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  # First: deploy to two dirs
  cat > "$workdir/manifest.json" <<EOF
{
  "my-skill@@.agents/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-skill"
  },
  "my-skill@@.claude/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null

  # Second: add a third target dir
  cat > "$workdir/manifest.json" <<EOF
{
  "my-skill@@.agents/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-skill"
  },
  "my-skill@@.claude/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-skill"
  },
  "my-skill@@.opencode/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".opencode/skills",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json") || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_contains "$output" "1 skill(s) deployed, 2 skipped" "only new target deployed"
  assert_file_exists "$workdir/.opencode/skills/my-skill/SKILL.md"
}

# ================================================================
# T28: multi_target_dry_run
# ================================================================
test_T28_multi_target_dry_run() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  cat > "$workdir/manifest.json" <<EOF
{
  "my-skill@@.agents/skills": {
    "name": "my-skill",
    "mode": "symlink",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-skill"
  },
  "my-skill@@.claude/skills": {
    "name": "my-skill",
    "mode": "symlink",
    "subdir": "sub-a",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json" --dry-run) || exit_code=$?

  assert_eq "$exit_code" 1 "exit code should be 1 (changes pending)"
  assert_contains "$output" "2 change(s) would be applied" "two targets pending"
  # Verify no files created
  assert_not_exists "$workdir/.agents/skills/my-skill"
  assert_not_exists "$workdir/.claude/skills/my-skill"
}

# ================================================================
# T29: multi_target_mixed_with_single
# ================================================================
test_T29_multi_target_mixed_with_single() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-a"
  cp -R "$FIXTURES_DIR/valid-skill/sub-b" "$workdir/source-b"

  cat > "$workdir/manifest.json" <<EOF
{
  "multi-skill@@.agents/skills": {
    "name": "multi-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-a"
  },
  "multi-skill@@.claude/skills": {
    "name": "multi-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-a"
  },
  "single-skill": {
    "name": "single-skill",
    "mode": "symlink",
    "subdir": "sub-b",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-b"
  }
}
EOF

  local exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_file_exists "$workdir/.agents/skills/multi-skill/SKILL.md"
  assert_file_exists "$workdir/.claude/skills/multi-skill/SKILL.md"
  assert_file_exists "$workdir/.agents/skills/single-skill/SKILL.md"
  assert_not_symlink "$workdir/.agents/skills/multi-skill/SKILL.md"
  assert_symlink "$workdir/.agents/skills/single-skill/SKILL.md"
}

# ================================================================
# T30: multi_target_marker_name
# ================================================================
test_T30_multi_target_marker_name() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  cat > "$workdir/manifest.json" <<EOF
{
  "my-skill@@.agents/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-skill"
  },
  "my-skill@@.claude/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF

  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null

  local marker_name_agents marker_name_claude
  marker_name_agents=$(jq -r '.skillName' "$workdir/.agents/skills/my-skill/$MARKER_FILENAME")
  marker_name_claude=$(jq -r '.skillName' "$workdir/.claude/skills/my-skill/$MARKER_FILENAME")

  assert_eq "$marker_name_agents" "my-skill" "agents marker skillName"
  assert_eq "$marker_name_claude" "my-skill" "claude marker skillName"
}

# ================================================================
# T31: nix_targetdirs_mutual_exclusion
# ================================================================
test_T31_nix_targetdirs_mutual_exclusion() {
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
            subdir = "tests/fixtures/valid-skill/sub-a";
            targetDir = ".agents/skills";
            targetDirs = [".agents/skills" ".claude/skills"];
          };
        };
      };
    in builtins.toJSON drv.drvAttrs
  ' 2>&1) || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should have failed for mutual exclusion\n" >&2
    return 1
  fi
  assert_contains "$output" "both" "should mention both targetDir and targetDirs"
}

# ================================================================
# T31b: nix_targetdirs_empty
# ================================================================
test_T31b_nix_targetdirs_empty() {
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
            subdir = "tests/fixtures/valid-skill/sub-a";
            targetDirs = [];
          };
        };
      };
    in builtins.toJSON drv.drvAttrs
  ' 2>&1) || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should have failed for empty targetDirs\n" >&2
    return 1
  fi
  assert_contains "$output" "empty" "should mention empty targetDirs"
}

# ================================================================
# T31c: nix_targetdirs_absolute_path
# ================================================================
test_T31c_nix_targetdirs_absolute_path() {
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
            subdir = "tests/fixtures/valid-skill/sub-a";
            targetDirs = ["/etc/skills"];
          };
        };
      };
    in builtins.toJSON drv.drvAttrs
  ' 2>&1) || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should have failed for absolute targetDirs entry\n" >&2
    return 1
  fi
  assert_contains "$output" "must be relative" "should mention must be relative"
}

# ================================================================
# T31d: nix_targetdirs_dotdot
# ================================================================
test_T31d_nix_targetdirs_dotdot() {
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
            subdir = "tests/fixtures/valid-skill/sub-a";
            targetDirs = ["../escape/skills"];
          };
        };
      };
    in builtins.toJSON drv.drvAttrs
  ' 2>&1) || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should have failed for targetDirs entry with ..\n" >&2
    return 1
  fi
  assert_contains "$output" "forbidden" "should mention forbidden"
}

# ================================================================
# T32: nix_targetdirs_expansion
# ================================================================
test_T32_nix_targetdirs_expansion() {
  local output exit_code=0
  output=$(nix eval --impure --json --expr '
    let
      pkgs = import <nixpkgs> {};
      mkDeploySkills = import '"$REPO_ROOT"'/lib/mkDeploySkills.nix;
      drv = mkDeploySkills {
        inherit pkgs;
        skills = {
          my-skill = {
            source = '"$REPO_ROOT"';
            subdir = "tests/fixtures/valid-skill/sub-a";
            targetDirs = [".agents/skills" ".claude/skills"];
          };
        };
      };
      manifest = builtins.fromJSON (builtins.readFile "${drv.passthru.manifestPath}");
    in manifest
  ' 2>&1) || exit_code=$?

  assert_eq "$exit_code" 0 "nix eval should succeed for targetDirs"

  # Verify manifest has correct @@-keyed entries
  local key1_exists key2_exists
  key1_exists=$(echo "$output" | jq 'has("my-skill@@.agents/skills")')
  key2_exists=$(echo "$output" | jq 'has("my-skill@@.claude/skills")')
  assert_eq "$key1_exists" "true" "manifest should have my-skill@@.agents/skills key"
  assert_eq "$key2_exists" "true" "manifest should have my-skill@@.claude/skills key"

  # Verify entry fields for agents target
  local agents_name agents_targetdir agents_sourcepath
  agents_name=$(echo "$output" | jq -r '.["my-skill@@.agents/skills"].name')
  agents_targetdir=$(echo "$output" | jq -r '.["my-skill@@.agents/skills"].targetDir')
  assert_eq "$agents_name" "my-skill" "agents entry name"
  assert_eq "$agents_targetdir" ".agents/skills" "agents entry targetDir"

  # Verify entry fields for claude target
  local claude_name claude_targetdir
  claude_name=$(echo "$output" | jq -r '.["my-skill@@.claude/skills"].name')
  claude_targetdir=$(echo "$output" | jq -r '.["my-skill@@.claude/skills"].targetDir')
  assert_eq "$claude_name" "my-skill" "claude entry name"
  assert_eq "$claude_targetdir" ".claude/skills" "claude entry targetDir"

  # Verify both entries have sourcePath set
  local agents_source claude_source
  agents_source=$(echo "$output" | jq -r '.["my-skill@@.agents/skills"].sourcePath')
  claude_source=$(echo "$output" | jq -r '.["my-skill@@.claude/skills"].sourcePath')
  assert_contains "$agents_source" "tests/fixtures/valid-skill/sub-a" "agents sourcePath"
  assert_contains "$claude_source" "tests/fixtures/valid-skill/sub-a" "claude sourcePath"
}

# ================================================================
# T33: multi_target_single_entry
# ================================================================
test_T33_multi_target_single_entry() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  # Simulates Nix expansion of targetDirs = [".agents/skills"] (single element, still uses @@)
  cat > "$workdir/manifest.json" <<EOF
{
  "my-skill@@.agents/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF

  local exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  # Verify skill deployed using entry name, not manifest key
  assert_file_exists "$workdir/.agents/skills/my-skill/SKILL.md"
  assert_file_exists "$workdir/.agents/skills/my-skill/$MARKER_FILENAME"
  # Verify NO directory with @@-keyed name was created
  assert_not_exists "$workdir/.agents/skills/my-skill@@.agents/skills"

  local marker_name
  marker_name=$(jq -r '.skillName' "$workdir/.agents/skills/my-skill/$MARKER_FILENAME")
  assert_eq "$marker_name" "my-skill" "marker skillName should be plain name"
}

# ================================================================
# T34: multi_target_mode_drift
# ================================================================
test_T34_multi_target_mode_drift() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  # Deploy both as copy
  cat > "$workdir/manifest.json" <<EOF
{
  "my-skill@@.agents/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-skill"
  },
  "my-skill@@.claude/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null

  # Record claude marker's deployedAt before second run
  local claude_deployed_at_before
  claude_deployed_at_before=$(jq -r '.deployedAt' "$workdir/.claude/skills/my-skill/$MARKER_FILENAME")

  # Change agents to symlink, keep claude as copy
  cat > "$workdir/manifest.json" <<EOF
{
  "my-skill@@.agents/skills": {
    "name": "my-skill",
    "mode": "symlink",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-skill"
  },
  "my-skill@@.claude/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json") || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  # Agents should now be symlink
  assert_symlink "$workdir/.agents/skills/my-skill/SKILL.md"
  local agents_mode
  agents_mode=$(jq -r '.mode' "$workdir/.agents/skills/my-skill/$MARKER_FILENAME")
  assert_eq "$agents_mode" "symlink" "agents mode should be symlink"

  # Claude should still be copy, unchanged
  assert_not_symlink "$workdir/.claude/skills/my-skill/SKILL.md"
  local claude_mode claude_deployed_at_after
  claude_mode=$(jq -r '.mode' "$workdir/.claude/skills/my-skill/$MARKER_FILENAME")
  claude_deployed_at_after=$(jq -r '.deployedAt' "$workdir/.claude/skills/my-skill/$MARKER_FILENAME")
  assert_eq "$claude_mode" "copy" "claude mode should still be copy"
  assert_eq "$claude_deployed_at_after" "$claude_deployed_at_before" "claude should not have been re-deployed"

  # Output should show 1 deployed, 1 skipped
  assert_contains "$output" "1 skill(s) deployed, 1 skipped" "one updated, one skipped"
}

# ================================================================
# T35: multi_target_source_drift
# ================================================================
test_T35_multi_target_source_drift() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-v1"

  # Deploy v1 to both
  cat > "$workdir/manifest.json" <<EOF
{
  "my-skill@@.agents/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-v1"
  },
  "my-skill@@.claude/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-v1"
  }
}
EOF
  run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null

  # Create v2 source
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-v2"
  echo "v2 content" > "$workdir/source-v2/prompt.txt"

  # Deploy v2 to both
  cat > "$workdir/manifest.json" <<EOF
{
  "my-skill@@.agents/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-v2"
  },
  "my-skill@@.claude/skills": {
    "name": "my-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-v2"
  }
}
EOF

  local output exit_code=0
  output=$(run_deploy_capture "$workdir" "$workdir/manifest.json") || exit_code=$?

  assert_eq "$exit_code" 0 "exit code"
  assert_contains "$output" "2 skill(s) deployed, 0 skipped" "both targets updated"

  # Verify both markers point to v2
  local agents_source claude_source
  agents_source=$(jq -r '.sourcePath' "$workdir/.agents/skills/my-skill/$MARKER_FILENAME")
  claude_source=$(jq -r '.sourcePath' "$workdir/.claude/skills/my-skill/$MARKER_FILENAME")
  assert_eq "$agents_source" "$workdir/source-v2" "agents source updated to v2"
  assert_eq "$claude_source" "$workdir/source-v2" "claude source updated to v2"
}

# ================================================================
# T36: nix_skill_name_with_at_signs
# ================================================================
test_T36_nix_skill_name_with_at_signs() {
  local exit_code=0
  local output
  output=$(nix eval --impure --raw --expr '
    let
      pkgs = import <nixpkgs> {};
      mkDeploySkills = import '"$REPO_ROOT"'/lib/mkDeploySkills.nix;
      drv = mkDeploySkills {
        inherit pkgs;
        skills = {
          bad-skill@@name = {
            source = ./. ;
            subdir = "tests/fixtures/valid-skill/sub-a";
          };
        };
      };
    in builtins.toJSON drv.drvAttrs
  ' 2>&1) || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should have failed for skill name containing @@\n" >&2
    return 1
  fi
  assert_contains "$output" "@@" "should mention @@ in error"
}

# ================================================================
# T37: nix_manifest_key_collision
# ================================================================
test_T37_nix_manifest_key_collision() {
  local exit_code=0
  local output
  output=$(nix eval --impure --raw --expr '
    let
      pkgs = import <nixpkgs> {};
      mkDeploySkills = import '"$REPO_ROOT"'/lib/mkDeploySkills.nix;
      drv = mkDeploySkills {
        inherit pkgs;
        skills = {
          foo = {
            source = ./. ;
            subdir = "tests/fixtures/valid-skill/sub-a";
            targetDir = ".agents/skills";
          };
          foo@@.agents/skills = {
            source = ./. ;
            subdir = "tests/fixtures/valid-skill/sub-a";
            targetDir = ".claude/skills";
          };
        };
      };
    in builtins.toJSON drv.drvAttrs
  ' 2>&1) || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should have failed for manifest key collision\n" >&2
    return 1
  fi
  assert_contains "$output" "Collision detected" "should mention Collision detected"
}

# ================================================================
# T38: nix_targetdirs_empty_element
# ================================================================
test_T38_nix_targetdirs_empty_element() {
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
            subdir = "tests/fixtures/valid-skill/sub-a";
            targetDirs = [""];
          };
        };
      };
    in builtins.toJSON drv.drvAttrs
  ' 2>&1) || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should have failed for empty targetDirs element\n" >&2
    return 1
  fi
  assert_contains "$output" "cannot be empty" "should mention cannot be empty"
}

# ================================================================
# T39: nix_targetdirs_path_normalization
# ================================================================
test_T39_nix_targetdirs_path_normalization() {
  local output exit_code=0
  output=$(nix eval --impure --raw --expr '
    let
      pkgs = import <nixpkgs> {};
      mkDeploySkills = import '"$REPO_ROOT"'/lib/mkDeploySkills.nix;
      drv = mkDeploySkills {
        inherit pkgs;
        skills = {
          my-skill = {
            source = '"$REPO_ROOT"';
            subdir = "tests/fixtures/valid-skill/sub-a";
            targetDirs = [".agents/skills" "./.agents/skills" ".agents/skills/"];
          };
        };
      };
      manifest = builtins.fromJSON (builtins.readFile "${drv.passthru.manifestPath}");
    in builtins.attrNames manifest
  ' 2>&1) || exit_code=$?

  assert_eq "$exit_code" 0 "nix eval should detect duplicates after normalization"
  # Should only have one entry since all paths normalize to the same value
  local count
  count=$(echo "$output" | wc -l | tr -d ' ')
  assert_eq "$count" "1" "should have only one manifest entry after normalization, got $count"
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
run_test test_T25_multi_target_basic
run_test test_T26_multi_target_idempotent
run_test test_T27_multi_target_incremental_add
run_test test_T28_multi_target_dry_run
run_test test_T29_multi_target_mixed_with_single
run_test test_T30_multi_target_marker_name
if [[ -n "$IN_NIX_SANDBOX" || "$NIX_EVAL_AVAILABLE" != "true" ]]; then
  skip_test test_T31_nix_targetdirs_mutual_exclusion "requires nix eval --impure"
  skip_test test_T31b_nix_targetdirs_empty "requires nix eval --impure"
  skip_test test_T31c_nix_targetdirs_absolute_path "requires nix eval --impure"
  skip_test test_T31d_nix_targetdirs_dotdot "requires nix eval --impure"
  skip_test test_T32_nix_targetdirs_expansion "requires nix eval --impure"
else
  run_test test_T31_nix_targetdirs_mutual_exclusion
  run_test test_T31b_nix_targetdirs_empty
  run_test test_T31c_nix_targetdirs_absolute_path
  run_test test_T31d_nix_targetdirs_dotdot
  run_test test_T32_nix_targetdirs_expansion
fi
run_test test_T33_multi_target_single_entry
run_test test_T34_multi_target_mode_drift
run_test test_T35_multi_target_source_drift
if [[ -n "$IN_NIX_SANDBOX" || "$NIX_EVAL_AVAILABLE" != "true" ]]; then
  skip_test test_T36_nix_skill_name_with_at_signs "requires nix eval --impure"
  skip_test test_T37_nix_manifest_key_collision "requires nix eval --impure"
  skip_test test_T38_nix_targetdirs_empty_element "requires nix eval --impure"
  skip_test test_T39_nix_targetdirs_path_normalization "requires nix eval --impure"
else
  run_test test_T36_nix_skill_name_with_at_signs
  run_test test_T37_nix_manifest_key_collision
  run_test test_T38_nix_targetdirs_empty_element
  run_test test_T39_nix_targetdirs_path_normalization
fi

echo ""
echo "1..$TOTAL"
echo "# pass $PASS"
echo "# fail $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
