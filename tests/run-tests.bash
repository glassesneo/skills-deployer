#!/usr/bin/env bash
# Test harness for deploy-skills.bash
# Covers runtime, eval-time, and Home Manager module behavior.
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

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then return 0; fi
  printf "    ASSERT FAILED: output unexpectedly contains '%s' %s\n" "$needle" "$msg" >&2
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
if ! nix eval --impure --raw --expr '"1"' >/dev/null 2>&1; then
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
run_deploy_capture() {
  local workdir="$1" manifest="$2"
  shift 2
  local exit_code=0
  (cd "$workdir" && MANIFEST_PATH="$manifest" bash "$DEPLOY_SCRIPT" "$@" 2>&1) || exit_code=$?
  return "$exit_code"
}

run_deploy_capture_with_disabled() {
  local workdir="$1" manifest="$2" disabled_manifest="$3"
  shift 3
  local exit_code=0
  (cd "$workdir" && MANIFEST_PATH="$manifest" DISABLED_MANIFEST_PATH="$disabled_manifest" bash "$DEPLOY_SCRIPT" "$@" 2>&1) || exit_code=$?
  return "$exit_code"
}

eval_hm_module() {
  local programs_config="$1"
  local nix_expr

  # Safe eval-only approximation: this stub matches the option shape needed by
  # the module without depending on full Home Manager runtime integration.
  nix_expr=$(cat <<EOF
let
  pkgs = import <nixpkgs> {};
  lib = pkgs.lib;
  evaled =
    (lib.evalModules {
      modules = [
        ${REPO_ROOT}/modules/home-manager.nix
        ({ lib, ... }: {
          options.assertions = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options.assertion = lib.mkOption {
                type = lib.types.bool;
                description = "Whether this assertion passed";
              };
              options.message = lib.mkOption {
                type = lib.types.str;
                description = "Assertion failure message";
              };
            });
            default = [];
          };
          options.home.file = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options.source = lib.mkOption {
                type = lib.types.path;
                description = "Path to source file or directory";
              };
              options.text = lib.mkOption {
                type = lib.types.str;
                description = "Inline content as string";
                default = "";
              };
            });
            default = {};
          };
          config.home.file = {};
        })
        ({ ... }: {
          programs.skills-deployer = ${programs_config};
        })
      ];
    }).config;
  failedAssertions = builtins.filter (a: !a.assertion) evaled.assertions;
in
if failedAssertions != []
then builtins.throw (builtins.concatStringsSep "\n" (map (a: a.message) failedAssertions))
else evaled.home.file
EOF
  )

  nix eval --impure --json --expr "$nix_expr"
}

strip_nix_search_path_warnings() {
  local input="$1"
  local line
  local filtered=""

  while IFS= read -r line; do
    if [[ "$line" == warning:\ Nix\ search\ path* ]]; then
      continue
    fi
    if [[ -n "$filtered" ]]; then
      filtered+=$'\n'
    fi
    filtered+="$line"
  done <<< "$input"

  printf "%s" "$filtered"
}

assert_nix_eval_fails_raw() {
  local case_name="$1" expr="$2"
  shift 2
  local output exit_code=0
  output=$(nix eval --impure --raw --expr "$expr" 2>&1) || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should fail (%s)\n" "$case_name" >&2
    return 1
  fi

  local needle
  for needle in "$@"; do
    assert_contains "$output" "$needle" "[$case_name]"
  done
}

assert_mkdeployskills_fails() {
  local case_name="$1" skills_block="$2"
  shift 2
  local expr
  expr=$(cat <<EOF
let
  pkgs = import <nixpkgs> {};
  mkDeploySkills = import ${REPO_ROOT}/lib/mkDeploySkills.nix;
  drv = mkDeploySkills {
    inherit pkgs;
    skills = {
${skills_block}
    };
  };
in builtins.toJSON drv.drvAttrs
EOF
)

  assert_nix_eval_fails_raw "$case_name" "$expr" "$@"
}

assert_hm_eval_fails() {
  local case_name="$1" programs_config="$2"
  shift 2
  local output exit_code=0
  output=$(eval_hm_module "$programs_config" 2>&1) || exit_code=$?
  output=$(strip_nix_search_path_warnings "$output")

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: hm module eval should fail (%s)\n" "$case_name" >&2
    return 1
  fi

  local needle
  for needle in "$@"; do
    assert_contains "$output" "$needle" "[$case_name]"
  done
}

assert_hm_single_skill_fails() {
  local case_name="$1" skill_block="$2"
  shift 2
  local programs_config
  programs_config=$(cat <<EOF
{
  enable = true;
  skills = {
    skill-a = {
      source = ${FIXTURES_DIR}/valid-skill;
      subdir = "sub-a";
${skill_block}
    };
  };
}
EOF
)

  assert_hm_eval_fails "$case_name" "$programs_config" "$@"
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
  assert_contains "$output" "0 change(s) applied" "nothing deployed on rerun"
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
            source = '"$REPO_ROOT"'/tests/fixtures/valid-skill;
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
            source = '"$REPO_ROOT"'/tests/fixtures/valid-skill;
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
  cp -R "$FIXTURES_DIR/valid-skill" "$workdir/source-skill"

  cat > "$workdir/deploy-drv.nix" <<EOF
let
  pkgs = import <nixpkgs> {};
  mkDeploySkills = import "$REPO_ROOT/lib/mkDeploySkills.nix";
in mkDeploySkills {
  inherit pkgs;
  skills = {
    my-skill = {
      source = "$workdir/source-skill";
      subdir = "sub-a";
    };
  };
}
EOF

  local deploy_drv_path program_path output exit_code=0
  deploy_drv_path=$(nix build --impure --no-link --print-out-paths --file "$workdir/deploy-drv.nix") || exit_code=$?
  assert_eq "$exit_code" 0 "nix build should realize deploy-skills derivation"

  program_path="$deploy_drv_path/bin/deploy-skills"
  assert_file_exists "$program_path"

  exit_code=0
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
  assert_contains "$output" "0 change(s) applied" "nothing deployed on rerun"
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
# T31: nix_targetdirs_validation_matrix
# ================================================================
test_T31_nix_targetdirs_validation_matrix() {
  assert_mkdeployskills_fails "targetDir + targetDirs are mutually exclusive" '
      bad-skill = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        targetDir = ".agents/skills";
        targetDirs = [".agents/skills" ".claude/skills"];
      };
  ' "both" "targetDirs"

  assert_mkdeployskills_fails "targetDirs rejects empty list" '
      bad-skill = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        targetDirs = [];
      };
  ' "empty"

  assert_mkdeployskills_fails "targetDirs rejects absolute path entries" '
      bad-skill = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        targetDirs = ["/etc/skills"];
      };
  ' "must be relative"

  assert_mkdeployskills_fails "targetDirs rejects traversal entries" '
      bad-skill = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        targetDirs = ["../escape/skills"];
      };
  ' "forbidden"

  assert_mkdeployskills_fails "targetDirs rejects empty elements" '
      bad-skill = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        targetDirs = [""];
      };
  ' "cannot be empty"

  assert_mkdeployskills_fails "targetDirs rejects normalized duplicates" '
      my-skill = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        targetDirs = [".agents/skills" "./.agents/skills" ".agents/skills/"];
      };
  ' "duplicate entries"

  assert_mkdeployskills_fails "targetDir rejects list values" '
      bad-skill = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        targetDir = [".agents/skills" ".claude/skills"];
      };
  ' "invalid type" "targetDirs"

  assert_mkdeployskills_fails "targetDirs rejects string values" '
      bad-skill = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        targetDirs = ".agents/skills";
      };
  ' "invalid type" "targetDir"
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
            source = '"$REPO_ROOT"'/tests/fixtures/valid-skill;
            subdir = "sub-a";
            targetDirs = [".agents/skills" ".claude/skills"];
          };
        };
      };
      manifest = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile drv.passthru.manifestPath));
    in manifest
  ') || exit_code=$?

  assert_eq "$exit_code" 0 "nix eval should succeed for targetDirs"

  # Verify manifest has correct @@-keyed entries
  local key1_exists key2_exists
  key1_exists=$(echo "$output" | jq 'has("my-skill@@.agents/skills")')
  key2_exists=$(echo "$output" | jq 'has("my-skill@@.claude/skills")')
  assert_eq "$key1_exists" "true" "manifest should have my-skill@@.agents/skills key"
  assert_eq "$key2_exists" "true" "manifest should have my-skill@@.claude/skills key"

  # Verify entry fields for agents target
  local agents_name agents_targetdir
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

  # Verify both entries have sourcePath ending in /sub-a
  local agents_source claude_source agents_ends_with_sub_a=false claude_ends_with_sub_a=false
  agents_source=$(echo "$output" | jq -r '.["my-skill@@.agents/skills"].sourcePath')
  claude_source=$(echo "$output" | jq -r '.["my-skill@@.claude/skills"].sourcePath')
  if [[ "$agents_source" == */sub-a ]]; then
    agents_ends_with_sub_a=true
  fi
  if [[ "$claude_source" == */sub-a ]]; then
    claude_ends_with_sub_a=true
  fi
  assert_eq "$agents_ends_with_sub_a" "true" "agents sourcePath should end with /sub-a"
  assert_eq "$claude_ends_with_sub_a" "true" "claude sourcePath should end with /sub-a"
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
  assert_contains "$output" "1 change(s) applied" "one target should be updated"
  assert_contains "$output" "1 deploy entry(ies) skipped" "one target should be skipped"
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
          "foo@@.agents/skills" = {
            source = '"$REPO_ROOT"'/tests/fixtures/valid-skill;
            subdir = "sub-a";
            targetDir = ".claude/skills";
          };
        };
      };
    in builtins.toJSON drv.drvAttrs
  ' 2>&1) || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should have failed for reserved @@ key usage\n" >&2
    return 1
  fi
  assert_contains "$output" "cannot contain '@@'" "should mention reserved @@ separator"
}

# ================================================================
# T42: hm_disabled_empty
# ================================================================
test_T42_hm_disabled_empty() {
  local output exit_code=0
  output=$(eval_hm_module '{
    enable = false;
  }') || exit_code=$?

  assert_eq "$exit_code" 0 "hm module eval should succeed when disabled"

  local count
  count=$(echo "$output" | jq 'keys | length')
  assert_eq "$count" "0" "home.file should be empty when disabled"
}

# ================================================================
# T43: hm_enabled_empty_skills
# ================================================================
test_T43_hm_enabled_empty_skills() {
  local output exit_code=0
  output=$(eval_hm_module '{
    enable = true;
    skills = {};
  }') || exit_code=$?

  assert_eq "$exit_code" 0 "hm module eval should succeed with empty skills"

  local count
  count=$(echo "$output" | jq 'keys | length')
  assert_eq "$count" "0" "home.file should be empty with empty skills"
}

# ================================================================
# T44: hm_single_skill_default_target
# ================================================================
test_T44_hm_single_skill_default_target() {
  local output exit_code=0
  output=$(eval_hm_module "{
    enable = true;
    skills = {
      skill-a = {
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-a\";
      };
    };
  }") || exit_code=$?

  assert_eq "$exit_code" 0 "hm module eval should succeed for single skill"

  local key_exists source_path ends_with_sub_a=false
  key_exists=$(echo "$output" | jq 'has(".agents/skills/skill-a")')
  assert_eq "$key_exists" "true" "home.file should contain default target key"

  source_path=$(echo "$output" | jq -r '.[".agents/skills/skill-a"].source')
  if [[ "$source_path" == */sub-a ]]; then
    ends_with_sub_a=true
  fi
  assert_eq "$ends_with_sub_a" "true" "source path should end with /sub-a"
}

# ================================================================
# T45: hm_multiple_skills_merge
# ================================================================
test_T45_hm_multiple_skills_merge() {
  local output exit_code=0
  output=$(eval_hm_module "{
    enable = true;
    skills = {
      skill-a = {
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-a\";
      };
      skill-b = {
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-b\";
      };
    };
  }") || exit_code=$?

  assert_eq "$exit_code" 0 "hm module eval should succeed for multiple skills"

  local count key_a_exists key_b_exists
  count=$(echo "$output" | jq 'keys | length')
  key_a_exists=$(echo "$output" | jq 'has(".agents/skills/skill-a")')
  key_b_exists=$(echo "$output" | jq 'has(".agents/skills/skill-b")')

  assert_eq "$count" "2" "home.file should contain two entries"
  assert_eq "$key_a_exists" "true" "home.file should contain skill-a key"
  assert_eq "$key_b_exists" "true" "home.file should contain skill-b key"
}

# ================================================================
# T46: hm_custom_default_targetdir
# ================================================================
test_T46_hm_custom_default_targetdir() {
  local output exit_code=0
  output=$(eval_hm_module "{
    enable = true;
    defaultTargetDir = \".claude/skills\";
    skills = {
      skill-a = {
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-a\";
      };
    };
  }") || exit_code=$?

  assert_eq "$exit_code" 0 "hm module eval should succeed with custom defaultTargetDir"

  local key_exists
  key_exists=$(echo "$output" | jq 'has(".claude/skills/skill-a")')
  assert_eq "$key_exists" "true" "home.file should use custom default targetDir"
}

# ================================================================
# T47: hm_per_skill_targetdir_override
# ================================================================
test_T47_hm_per_skill_targetdir_override() {
  local output exit_code=0
  output=$(eval_hm_module "{
    enable = true;
    defaultTargetDir = \".agents/skills\";
    skills = {
      skill-a = {
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-a\";
      };
      skill-b = {
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-b\";
        targetDir = \".claude/skills\";
      };
    };
  }") || exit_code=$?

  assert_eq "$exit_code" 0 "hm module eval should succeed with per-skill override"

  local count key_default_exists key_override_exists
  count=$(echo "$output" | jq 'keys | length')
  key_default_exists=$(echo "$output" | jq 'has(".agents/skills/skill-a")')
  key_override_exists=$(echo "$output" | jq 'has(".claude/skills/skill-b")')

  assert_eq "$count" "2" "home.file should contain exactly two entries"
  assert_eq "$key_default_exists" "true" "home.file should contain default target entry"
  assert_eq "$key_override_exists" "true" "home.file should contain override target entry"
}

# ================================================================
# T48: hm_missing_source_fails
# ================================================================
test_T48_hm_missing_source_fails() {
  local output exit_code=0
  output=$(eval_hm_module '{
    enable = true;
    skills = {
      skill-a = {
        subdir = "sub-a";
      };
    };
  }' 2>&1) || exit_code=$?
  output=$(strip_nix_search_path_warnings "$output")

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: hm module eval should fail when source is missing\n" >&2
    return 1
  fi
  assert_contains "$output" "source" "error should mention missing source"
  assert_contains "$output" "no value defined" "error should indicate missing required option"
}

# ================================================================
# T49: hm_missing_subdir_fails
# ================================================================
test_T49_hm_missing_subdir_fails() {
  local output exit_code=0
  output=$(eval_hm_module "{
    enable = true;
    skills = {
      skill-a = {
        source = ${FIXTURES_DIR}/valid-skill;
      };
    };
  }" 2>&1) || exit_code=$?
  output=$(strip_nix_search_path_warnings "$output")

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: hm module eval should fail when subdir is missing\n" >&2
    return 1
  fi
  assert_contains "$output" "subdir" "error should mention missing subdir"
  assert_contains "$output" "no value defined" "error should indicate missing required option"
}

# ================================================================
# T50: hm_source_wrong_type_fails
# ================================================================
test_T50_hm_source_wrong_type_fails() {
  local output exit_code=0
  output=$(eval_hm_module '{
    enable = true;
    skills = {
      skill-a = {
        source = "string";
        subdir = "sub-a";
      };
    };
  }' 2>&1) || exit_code=$?
  output=$(strip_nix_search_path_warnings "$output")

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: hm module eval should fail for source wrong type\n" >&2
    return 1
  fi
  assert_contains "$output" "source" "error should mention source"
  assert_contains "$output" "path" "error should mention path type"
}

# ================================================================
# T51: hm_targetdirs_multi_target
# ================================================================
test_T51_hm_targetdirs_multi_target() {
  local output exit_code=0
  output=$(eval_hm_module "{
    enable = true;
    skills = {
      skill-a = {
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-a\";
        targetDirs = [\".agents/skills\" \".claude/skills\"];
      };
    };
  }") || exit_code=$?

  assert_eq "$exit_code" 0 "hm module eval should succeed for targetDirs"

  local count key_a_exists key_b_exists
  count=$(echo "$output" | jq 'keys | length')
  key_a_exists=$(echo "$output" | jq 'has(".agents/skills/skill-a")')
  key_b_exists=$(echo "$output" | jq 'has(".claude/skills/skill-a")')

  assert_eq "$count" "2" "home.file should contain two target entries for one skill"
  assert_eq "$key_a_exists" "true" "home.file should contain first target entry"
  assert_eq "$key_b_exists" "true" "home.file should contain second target entry"
}

# ================================================================
# T52: hm_targetdir_targetdirs_validation_matrix
# ================================================================
test_T52_hm_targetdir_targetdirs_validation_matrix() {
  assert_hm_single_skill_fails "targetDir rejects list values" '      targetDir = ["list"];' "targetDir" "type"
  assert_hm_single_skill_fails "targetDirs rejects string values" '      targetDirs = ".agents/skills";' "targetDirs" "list"
  assert_hm_single_skill_fails "targetDir + targetDirs are mutually exclusive" '
      targetDir = ".agents/skills";
      targetDirs = [".claude/skills"];
  ' "both" "targetDirs"
  assert_hm_single_skill_fails "targetDirs rejects empty list" '      targetDirs = [];' "empty" "targetDirs"
  assert_hm_single_skill_fails "targetDirs rejects absolute entries" '      targetDirs = ["/etc/skills"];' "targetDirs" "relative"
  assert_hm_single_skill_fails "targetDirs rejects traversal entries" '      targetDirs = ["../escape"];' "targetDirs" "forbidden"
  assert_hm_single_skill_fails "targetDirs rejects empty entries" '      targetDirs = [""];' "targetDirs" "cannot be empty"
  assert_hm_single_skill_fails "targetDirs rejects normalized duplicates" '      targetDirs = [".agents/skills" "./.agents/skills" ".agents/skills/"];' "targetDirs" "duplicate"
}

# ================================================================
# T60: nix_name_override_reflected_in_manifest
# ================================================================
test_T60_nix_name_override_reflected_in_manifest() {
  local output exit_code=0
  output=$(nix eval --impure --json --expr '
    let
      pkgs = import <nixpkgs> {};
      mkDeploySkills = import '"$REPO_ROOT"'/lib/mkDeploySkills.nix;
      drv = mkDeploySkills {
        inherit pkgs;
        skills = {
          original = {
            source = '"$REPO_ROOT"'/tests/fixtures/valid-skill;
            subdir = "sub-a";
            name = "renamed-skill";
          };
        };
      };
      manifest = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile drv.passthru.manifestPath));
    in manifest
  ') || exit_code=$?

  assert_eq "$exit_code" 0 "nix eval should succeed"

  local manifest_name
  manifest_name=$(echo "$output" | jq -r '.["original"].name')
  assert_eq "$manifest_name" "renamed-skill" "manifest should use explicit name override"
}

# ================================================================
# T61: nix_enable_false_reflected_in_disabled_payload
# ================================================================
test_T61_nix_enable_false_reflected_in_disabled_payload() {
  local output exit_code=0
  output=$(nix eval --impure --json --expr '
    let
      pkgs = import <nixpkgs> {};
      mkDeploySkills = import '"$REPO_ROOT"'/lib/mkDeploySkills.nix;
      drv = mkDeploySkills {
        inherit pkgs;
        skills = {
          "enabled-skill" = {
            source = '"$REPO_ROOT"'/tests/fixtures/valid-skill;
            subdir = "sub-a";
          };
          "disabled-skill" = {
            source = '"$REPO_ROOT"'/tests/fixtures/valid-skill;
            subdir = "sub-a";
            name = "disabled-renamed";
            enable = false;
          };
        };
      };
      manifest = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile drv.passthru.manifestPath));
      disabled = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile drv.passthru.disabledManifestPath));
    in {
      inherit manifest disabled;
    }
  ') || exit_code=$?

  assert_eq "$exit_code" 0 "nix eval should succeed"

  local enabled_present disabled_present disabled_len disabled_name disabled_target
  enabled_present=$(echo "$output" | jq '.manifest | has("enabled-skill")')
  disabled_present=$(echo "$output" | jq '.manifest | has("disabled-skill")')
  disabled_len=$(echo "$output" | jq '.disabled | length')
  disabled_name=$(echo "$output" | jq -r '.disabled[0].name')
  disabled_target=$(echo "$output" | jq -r '.disabled[0].targetDirs[0]')

  assert_eq "$enabled_present" "true" "enabled entry should stay in manifest"
  assert_eq "$disabled_present" "false" "disabled entry should be omitted from enabled manifest"
  assert_eq "$disabled_len" "1" "disabled payload should include one entry"
  assert_eq "$disabled_name" "disabled-renamed" "disabled payload should use resolved name"
  assert_eq "$disabled_target" ".agents/skills" "disabled payload should include target dir"
}

# ================================================================
# T62: nix_enabled_destination_collision_fails
# ================================================================
test_T62_nix_enabled_destination_collision_fails() {
  local output exit_code=0
  output=$(nix eval --impure --raw --expr '
    let
      pkgs = import <nixpkgs> {};
      mkDeploySkills = import '"$REPO_ROOT"'/lib/mkDeploySkills.nix;
      drv = mkDeploySkills {
        inherit pkgs;
        skills = {
          first = {
            source = '"$REPO_ROOT"'/tests/fixtures/valid-skill;
            subdir = "sub-a";
            name = "same-dest";
          };
          second = {
            source = '"$REPO_ROOT"'/tests/fixtures/valid-skill;
            subdir = "sub-a";
            name = "same-dest";
          };
        };
      };
    in builtins.toJSON drv.drvAttrs
  ' 2>&1) || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should fail for enabled destination collision\n" >&2
    return 1
  fi
  assert_contains "$output" "colliding destinations" "should mention destination collision"
  assert_contains "$output" "Each enabled destination" "should provide actionable remediation"
}

# ================================================================
# T63: nix_enabled_disabled_destination_overlap_fails
# ================================================================
test_T63_nix_enabled_disabled_destination_overlap_fails() {
  local output exit_code=0
  output=$(nix eval --impure --raw --expr '
    let
      pkgs = import <nixpkgs> {};
      mkDeploySkills = import '"$REPO_ROOT"'/lib/mkDeploySkills.nix;
      drv = mkDeploySkills {
        inherit pkgs;
        skills = {
          active = {
            source = '"$REPO_ROOT"'/tests/fixtures/valid-skill;
            subdir = "sub-a";
            name = "shared-dest";
          };
          inactive = {
            source = '"$REPO_ROOT"'/tests/fixtures/valid-skill;
            subdir = "sub-a";
            name = "shared-dest";
            enable = false;
          };
        };
      };
    in builtins.toJSON drv.drvAttrs
  ' 2>&1) || exit_code=$?

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: nix eval should fail for enabled/disabled overlap\n" >&2
    return 1
  fi
  assert_contains "$output" "enabled and disabled skills overlap" "should mention overlap"
  assert_contains "$output" "cannot be both enabled and disabled" "should provide actionable remediation"
}

# ================================================================
# T64: nix_explicit_name_validation_matrix
# ================================================================
test_T64_nix_explicit_name_validation_matrix() {
  assert_mkdeployskills_fails "explicit name cannot be empty" '
      bad = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        name = "";
      };
  ' "explicit 'name'" "empty"

  assert_mkdeployskills_fails "explicit name cannot be '.'" '
      bad = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        name = ".";
      };
  ' "explicit 'name' '.'" "forbidden"

  assert_mkdeployskills_fails "explicit name cannot be '..'" '
      bad = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        name = "..";
      };
  ' "explicit 'name' '..'" "forbidden"

  assert_mkdeployskills_fails "explicit name cannot contain '/'" '
      bad = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        name = "bad/name";
      };
  ' "explicit 'name' 'bad/name'" "containing '/'"

  assert_mkdeployskills_fails "explicit name cannot contain @@" '
      bad = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        name = "bad@@name";
      };
  ' "explicit 'name' 'bad@@name'" "containing '@@'"
}

# ================================================================
# T69: runtime_name_override_paths_and_markers
# ================================================================
test_T69_runtime_name_override_paths_and_markers() {
  run_single_target_case() {
    local workdir
    workdir=$(mktemp -d)
    trap "rm -rf \"$workdir\"" RETURN

    touch "$workdir/flake.nix"
    cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

    cat > "$workdir/manifest.json" <<EOF
{
  "original-skill": {
    "name": "renamed-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF

    local exit_code=0
    run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?
    assert_eq "$exit_code" 0 "single-target name override deploy should succeed"
    assert_dir_exists "$workdir/.agents/skills/renamed-skill"
    assert_not_exists "$workdir/.agents/skills/original-skill"

    local marker_name
    marker_name=$(jq -r '.skillName' "$workdir/.agents/skills/renamed-skill/$MARKER_FILENAME")
    assert_eq "$marker_name" "renamed-skill" "marker skillName should use resolved single-target name"
  }

  run_multi_target_case() {
    local workdir
    workdir=$(mktemp -d)
    trap "rm -rf \"$workdir\"" RETURN

    touch "$workdir/flake.nix"
    cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

    cat > "$workdir/manifest.json" <<EOF
{
  "skill-id@@.agents/skills": {
    "name": "shared-renamed",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-skill"
  },
  "skill-id@@.claude/skills": {
    "name": "shared-renamed",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".claude/skills",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF

    local exit_code=0
    run_deploy_capture "$workdir" "$workdir/manifest.json" > /dev/null || exit_code=$?

    assert_eq "$exit_code" 0 "multi-target name override deploy should succeed"
    assert_file_exists "$workdir/.agents/skills/shared-renamed/SKILL.md"
    assert_file_exists "$workdir/.claude/skills/shared-renamed/SKILL.md"
    assert_not_exists "$workdir/.agents/skills/skill-id"
    assert_not_exists "$workdir/.claude/skills/skill-id"
  }

  run_single_target_case
  run_multi_target_case
}

# ================================================================
# T72: runtime_cleanup_remove_dryrun_and_noop_contracts
# ================================================================
test_T72_runtime_cleanup_remove_dryrun_and_noop_contracts() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  make_manifest "legacy-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
    > "$workdir/manifest-enabled.json"
  run_deploy_capture "$workdir" "$workdir/manifest-enabled.json" > /dev/null
  assert_dir_exists "$workdir/.agents/skills/legacy-skill"

  echo '{}' > "$workdir/manifest-empty.json"

  cat > "$workdir/disabled-legacy.json" <<EOF
[
  {
    "name": "legacy-skill",
    "targetDirs": [".agents/skills"]
  }
]
EOF

  local output exit_code=0
  output=$(run_deploy_capture_with_disabled "$workdir" "$workdir/manifest-empty.json" "$workdir/disabled-legacy.json" --dry-run) || exit_code=$?
  assert_eq "$exit_code" 1 "dry-run should return 1 when cleanup would remove managed destination"
  assert_contains "$output" "REMOVE .agents/skills/legacy-skill" "dry-run should report REMOVE action"
  assert_dir_exists "$workdir/.agents/skills/legacy-skill"

  exit_code=0
  output=$(run_deploy_capture_with_disabled "$workdir" "$workdir/manifest-empty.json" "$workdir/disabled-legacy.json") || exit_code=$?
  assert_eq "$exit_code" 0 "cleanup run should remove managed disabled destination"
  assert_not_exists "$workdir/.agents/skills/legacy-skill"
  assert_contains "$output" "removed disabled destination" "cleanup should report successful removal"

  cat > "$workdir/disabled-ghost.json" <<EOF
[
  {
    "name": "ghost-skill",
    "targetDirs": [".agents/skills"]
  }
]
EOF

  exit_code=0
  output=$(run_deploy_capture_with_disabled "$workdir" "$workdir/manifest-empty.json" "$workdir/disabled-ghost.json") || exit_code=$?
  assert_eq "$exit_code" 0 "cleanup run should no-op for missing disabled destination"
  assert_contains "$output" "0 change(s) applied" "missing disabled destination should not count as a change"
  assert_not_contains "$output" "removed disabled destination" "no-op run should not report removals"
}

# ================================================================
# T73: runtime_cleanup_skip_safety_contracts
# ================================================================
test_T73_runtime_cleanup_skip_safety_contracts() {
  run_unmanaged_and_marker_mismatch_case() {
    local workdir
    workdir=$(mktemp -d)
    trap "rm -rf \"$workdir\"" RETURN

    touch "$workdir/flake.nix"
    echo '{}' > "$workdir/manifest-empty.json"

    mkdir -p "$workdir/.agents/skills/unmanaged-skill"
    echo "user content" > "$workdir/.agents/skills/unmanaged-skill/local.txt"

    mkdir -p "$workdir/.claude/skills/expected-skill"
    cat > "$workdir/.claude/skills/expected-skill/$MARKER_FILENAME" <<EOF
{"version":"1","skillName":"other-skill","mode":"copy","sourcePath":"/tmp/source","deployedAt":"2026-02-01T00:00:00Z"}
EOF

    cat > "$workdir/disabled-skip-checks.json" <<EOF
[
  {
    "name": "unmanaged-skill",
    "targetDirs": [".agents/skills"]
  },
  {
    "name": "expected-skill",
    "targetDirs": [".claude/skills"]
  }
]
EOF

    local output exit_code=0
    output=$(run_deploy_capture_with_disabled "$workdir" "$workdir/manifest-empty.json" "$workdir/disabled-skip-checks.json") || exit_code=$?
    assert_eq "$exit_code" 0 "cleanup run should not fail when unmanaged/marker mismatch destinations are present"
    assert_contains "$output" "Skipping cleanup for unmanaged path '.agents/skills/unmanaged-skill'" "unmanaged destination should be preserved"
    assert_contains "$output" "marker skillName 'other-skill' does not match expected 'expected-skill'" "marker mismatch should be preserved"
    assert_dir_exists "$workdir/.agents/skills/unmanaged-skill"
    assert_dir_exists "$workdir/.claude/skills/expected-skill"
  }

  run_enabled_destination_skip_case() {
    local workdir
    workdir=$(mktemp -d)
    trap "rm -rf \"$workdir\"" RETURN

    touch "$workdir/flake.nix"
    cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"
    make_manifest "shared-skill" "$workdir/source-skill" "copy" ".agents/skills" "sub-a" \
      > "$workdir/manifest-enabled.json"

    cat > "$workdir/disabled-enabled-same-destination.json" <<EOF
[
  {
    "name": "shared-skill",
    "targetDirs": [".agents/skills"]
  }
]
EOF

    local output exit_code=0
    output=$(run_deploy_capture_with_disabled "$workdir" "$workdir/manifest-enabled.json" "$workdir/disabled-enabled-same-destination.json") || exit_code=$?
    assert_eq "$exit_code" 0 "cleanup should skip destinations that are enabled in the same run"
    assert_contains "$output" "Skipping disabled cleanup for '.agents/skills/shared-skill' because it is enabled in this run." "enabled destination should be protected from cleanup"
    assert_dir_exists "$workdir/.agents/skills/shared-skill"
  }

  run_canonicalized_enabled_destination_skip_case() {
    local workdir
    workdir=$(mktemp -d)
    trap "rm -rf \"$workdir\"" RETURN

    touch "$workdir/flake.nix"
    cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

    cat > "$workdir/manifest-canonical-enabled.json" <<EOF
{
  "canonical-skill": {
    "name": "canonical-skill",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": "./.agents/skills/",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF

    cat > "$workdir/disabled-manifest.json" <<EOF
[
  {
    "name": "canonical-skill",
    "targetDirs": ["././.agents/skills///"]
  }
]
EOF

    local output exit_code=0
    output=$(run_deploy_capture_with_disabled "$workdir" "$workdir/manifest-canonical-enabled.json" "$workdir/disabled-manifest.json") || exit_code=$?
    assert_eq "$exit_code" 0 "cleanup should skip canonicalized equivalent enabled destination"
    assert_contains "$output" "Skipping disabled cleanup for '.agents/skills/canonical-skill' because it is enabled in this run." "canonical equivalent enabled destination should be protected"
    assert_dir_exists "$workdir/.agents/skills/canonical-skill"
  }

  run_unmanaged_and_marker_mismatch_case
  run_enabled_destination_skip_case
  run_canonicalized_enabled_destination_skip_case
}

# ================================================================
# T77: runtime_lifecycle_enable_disable_reenable
# ================================================================
test_T77_runtime_lifecycle_enable_disable_reenable() {
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  touch "$workdir/flake.nix"
  cp -R "$FIXTURES_DIR/valid-skill/sub-a" "$workdir/source-skill"

  cat > "$workdir/manifest-enabled.json" <<EOF
{
  "lifecycle-skill": {
    "name": "lifecycle-renamed",
    "mode": "copy",
    "subdir": "sub-a",
    "targetDir": ".agents/skills",
    "sourcePath": "$workdir/source-skill"
  }
}
EOF
  echo '{}' > "$workdir/manifest-empty.json"
  cat > "$workdir/disabled-manifest.json" <<EOF
[
  {
    "name": "lifecycle-renamed",
    "targetDirs": [".agents/skills"]
  }
]
EOF

  local exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest-enabled.json" > /dev/null || exit_code=$?
  assert_eq "$exit_code" 0 "initial enable run should succeed"
  assert_dir_exists "$workdir/.agents/skills/lifecycle-renamed"

  exit_code=0
  run_deploy_capture_with_disabled "$workdir" "$workdir/manifest-empty.json" "$workdir/disabled-manifest.json" > /dev/null || exit_code=$?
  assert_eq "$exit_code" 0 "disable cleanup run should succeed"
  assert_not_exists "$workdir/.agents/skills/lifecycle-renamed"

  exit_code=0
  run_deploy_capture "$workdir" "$workdir/manifest-enabled.json" > /dev/null || exit_code=$?
  assert_eq "$exit_code" 0 "re-enable run should succeed"
  assert_dir_exists "$workdir/.agents/skills/lifecycle-renamed"

  local marker_name
  marker_name=$(jq -r '.skillName' "$workdir/.agents/skills/lifecycle-renamed/$MARKER_FILENAME")
  assert_eq "$marker_name" "lifecycle-renamed" "marker should use resolved name after re-enable"
}

# ================================================================
# T78: hm_name_override_changes_home_file_key
# ================================================================
test_T78_hm_name_override_changes_home_file_key() {
  local output exit_code=0
  output=$(eval_hm_module "{
    enable = true;
    skills = {
      skill-a = {
        name = \"renamed-skill\";
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-a\";
      };
    };
  }") || exit_code=$?

  assert_eq "$exit_code" 0 "hm module eval should succeed for explicit name override"

  local renamed_exists default_exists
  renamed_exists=$(echo "$output" | jq 'has(".agents/skills/renamed-skill")')
  default_exists=$(echo "$output" | jq 'has(".agents/skills/skill-a")')

  assert_eq "$renamed_exists" "true" "home.file should use overridden name"
  assert_eq "$default_exists" "false" "home.file should not use attr key when name override is set"
}

# ================================================================
# T79: hm_default_name_path_when_name_omitted
# ================================================================
test_T79_hm_default_name_path_when_name_omitted() {
  local output exit_code=0
  output=$(eval_hm_module "{
    enable = true;
    skills = {
      skill-a = {
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-a\";
      };
      skill-b = {
        name = \"renamed-b\";
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-b\";
      };
    };
  }") || exit_code=$?

  assert_eq "$exit_code" 0 "hm module eval should succeed with mixed named/unnamed skills"

  local default_exists renamed_exists count
  default_exists=$(echo "$output" | jq 'has(".agents/skills/skill-a")')
  renamed_exists=$(echo "$output" | jq 'has(".agents/skills/renamed-b")')
  count=$(echo "$output" | jq 'keys | length')

  assert_eq "$default_exists" "true" "name omitted should default to attr key"
  assert_eq "$renamed_exists" "true" "explicit name should still be honored"
  assert_eq "$count" "2" "home.file should contain two entries"
}

# ================================================================
# T80: hm_invalid_name_validation_matrix
# ================================================================
test_T80_hm_invalid_name_validation_matrix() {
  assert_hm_single_skill_fails "explicit HM name cannot be empty" '      name = "";' "invalid 'name'" "cannot be empty"
  assert_hm_single_skill_fails "explicit HM name cannot be '.'" '      name = ".";' "invalid 'name'" "forbidden"
  assert_hm_single_skill_fails "explicit HM name cannot be '..'" '      name = "..";' "invalid 'name'" "forbidden"
  assert_hm_single_skill_fails "explicit HM name cannot contain '/'" '      name = "bad/name";' "invalid 'name'" "'/' is forbidden"
  assert_hm_single_skill_fails "explicit HM name cannot contain @@" '      name = "bad@@name";' "invalid 'name'" "'@@' is forbidden"
}

# ================================================================
# T85: hm_per_skill_enable_false_omits_entry
# ================================================================
test_T85_hm_per_skill_enable_false_omits_entry() {
  local output exit_code=0
  output=$(eval_hm_module "{
    enable = true;
    skills = {
      disabled-skill = {
        enable = false;
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-a\";
      };
      enabled-skill = {
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-b\";
      };
    };
  }") || exit_code=$?

  assert_eq "$exit_code" 0 "hm module eval should succeed with per-skill enable=false"

  local disabled_exists enabled_exists count
  disabled_exists=$(echo "$output" | jq 'has(".agents/skills/disabled-skill")')
  enabled_exists=$(echo "$output" | jq 'has(".agents/skills/enabled-skill")')
  count=$(echo "$output" | jq 'keys | length')

  assert_eq "$disabled_exists" "false" "disabled per-skill entry should be omitted"
  assert_eq "$enabled_exists" "true" "other enabled entries should remain"
  assert_eq "$count" "1" "home.file should only include enabled entries"
}

# ================================================================
# T86: hm_enabled_destination_collision_fails
# ================================================================
test_T86_hm_enabled_destination_collision_fails() {
  local output exit_code=0
  output=$(eval_hm_module "{
    enable = true;
    skills = {
      first = {
        name = \"same-destination\";
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-a\";
      };
      second = {
        name = \"same-destination\";
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-b\";
      };
    };
  }" 2>&1) || exit_code=$?
  output=$(strip_nix_search_path_warnings "$output")

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: hm module eval should fail for enabled destination collision\n" >&2
    return 1
  fi
  assert_contains "$output" "duplicate destination paths" "error should mention destination collision"
  assert_contains "$output" "<targetDir>/<name>" "error should include actionable remediation"
}

# ================================================================
# T87: nix_canonicalized_destination_conflict_matrix
# ================================================================
test_T87_nix_canonicalized_destination_conflict_matrix() {
  assert_mkdeployskills_fails "enabled destination collision after canonicalization" '
      first = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        targetDir = "././.agents/skills/";
        name = "same-destination";
      };
      second = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-b";
        targetDir = ".agents/skills///";
        name = "same-destination";
      };
  ' "colliding destinations"

  assert_mkdeployskills_fails "enabled and disabled overlap after canonicalization" '
      active = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        targetDir = "././.agents/skills/";
        name = "shared-dest";
      };
      inactive = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        targetDir = ".agents/skills///";
        name = "shared-dest";
        enable = false;
      };
  ' "enabled and disabled skills overlap"
}

# ================================================================
# T89: nix_disabled_skill_validation_matrix
# ================================================================
test_T89_nix_disabled_skill_validation_matrix() {
  assert_mkdeployskills_fails "disabled skill still validates mode" '
      bad-disabled = {
        source = ./.;
        subdir = "tests/fixtures/valid-skill/sub-a";
        mode = "invalid-mode";
        enable = false;
      };
  ' "invalid mode"

  assert_mkdeployskills_fails "disabled skill still validates subdir" '
      bad-disabled = {
        source = ./.;
        subdir = "../escape";
        enable = false;
      };
  ' "forbidden"

  assert_mkdeployskills_fails "disabled skill still validates required fields" '
      bad-disabled = {
        source = ./.;
        enable = false;
      };
  ' "missing required field 'subdir'"
}

# ================================================================
# T93: hm_enabled_destination_collision_canonicalized_dirs_fails
# ================================================================
test_T93_hm_enabled_destination_collision_canonicalized_dirs_fails() {
  local output exit_code=0
  output=$(eval_hm_module "{
    enable = true;
    skills = {
      first = {
        name = \"same-destination\";
        targetDir = \"././.agents/skills/\";
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-a\";
      };
      second = {
        name = \"same-destination\";
        targetDir = \".agents/skills///\";
        source = ${FIXTURES_DIR}/valid-skill;
        subdir = \"sub-b\";
      };
    };
  }" 2>&1) || exit_code=$?
  output=$(strip_nix_search_path_warnings "$output")

  if [[ "$exit_code" -eq 0 ]]; then
    printf "    ASSERT FAILED: hm module eval should fail for canonicalized destination collision\n" >&2
    return 1
  fi
  assert_contains "$output" "duplicate destination paths" "error should mention destination collision"
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
  skip_test test_T31_nix_targetdirs_validation_matrix "requires nix eval --impure"
  skip_test test_T32_nix_targetdirs_expansion "requires nix eval --impure"
else
  run_test test_T31_nix_targetdirs_validation_matrix
  run_test test_T32_nix_targetdirs_expansion
fi
run_test test_T33_multi_target_single_entry
run_test test_T34_multi_target_mode_drift
run_test test_T35_multi_target_source_drift
if [[ -n "$IN_NIX_SANDBOX" || "$NIX_EVAL_AVAILABLE" != "true" ]]; then
  skip_test test_T36_nix_skill_name_with_at_signs "requires nix eval --impure"
  skip_test test_T37_nix_manifest_key_collision "requires nix eval --impure"
else
  run_test test_T36_nix_skill_name_with_at_signs
  run_test test_T37_nix_manifest_key_collision
fi
if [[ -n "$IN_NIX_SANDBOX" || "$NIX_EVAL_AVAILABLE" != "true" ]]; then
  skip_test test_T42_hm_disabled_empty "requires nix eval --impure"
  skip_test test_T43_hm_enabled_empty_skills "requires nix eval --impure"
  skip_test test_T44_hm_single_skill_default_target "requires nix eval --impure"
  skip_test test_T45_hm_multiple_skills_merge "requires nix eval --impure"
  skip_test test_T46_hm_custom_default_targetdir "requires nix eval --impure"
  skip_test test_T47_hm_per_skill_targetdir_override "requires nix eval --impure"
  skip_test test_T48_hm_missing_source_fails "requires nix eval --impure"
  skip_test test_T49_hm_missing_subdir_fails "requires nix eval --impure"
  skip_test test_T50_hm_source_wrong_type_fails "requires nix eval --impure"
  skip_test test_T51_hm_targetdirs_multi_target "requires nix eval --impure"
  skip_test test_T52_hm_targetdir_targetdirs_validation_matrix "requires nix eval --impure"
  skip_test test_T60_nix_name_override_reflected_in_manifest "requires nix eval --impure"
  skip_test test_T61_nix_enable_false_reflected_in_disabled_payload "requires nix eval --impure"
  skip_test test_T62_nix_enabled_destination_collision_fails "requires nix eval --impure"
  skip_test test_T63_nix_enabled_disabled_destination_overlap_fails "requires nix eval --impure"
  skip_test test_T64_nix_explicit_name_validation_matrix "requires nix eval --impure"
  skip_test test_T87_nix_canonicalized_destination_conflict_matrix "requires nix eval --impure"
  skip_test test_T89_nix_disabled_skill_validation_matrix "requires nix eval --impure"
else
  run_test test_T42_hm_disabled_empty
  run_test test_T43_hm_enabled_empty_skills
  run_test test_T44_hm_single_skill_default_target
  run_test test_T45_hm_multiple_skills_merge
  run_test test_T46_hm_custom_default_targetdir
  run_test test_T47_hm_per_skill_targetdir_override
  run_test test_T48_hm_missing_source_fails
  run_test test_T49_hm_missing_subdir_fails
  run_test test_T50_hm_source_wrong_type_fails
  run_test test_T51_hm_targetdirs_multi_target
  run_test test_T52_hm_targetdir_targetdirs_validation_matrix
  run_test test_T60_nix_name_override_reflected_in_manifest
  run_test test_T61_nix_enable_false_reflected_in_disabled_payload
  run_test test_T62_nix_enabled_destination_collision_fails
  run_test test_T63_nix_enabled_disabled_destination_overlap_fails
  run_test test_T64_nix_explicit_name_validation_matrix
  run_test test_T87_nix_canonicalized_destination_conflict_matrix
  run_test test_T89_nix_disabled_skill_validation_matrix
fi

run_test test_T69_runtime_name_override_paths_and_markers
run_test test_T72_runtime_cleanup_remove_dryrun_and_noop_contracts
run_test test_T73_runtime_cleanup_skip_safety_contracts
run_test test_T77_runtime_lifecycle_enable_disable_reenable

if [[ -n "$IN_NIX_SANDBOX" || "$NIX_EVAL_AVAILABLE" != "true" ]]; then
  skip_test test_T78_hm_name_override_changes_home_file_key "requires nix eval --impure"
  skip_test test_T79_hm_default_name_path_when_name_omitted "requires nix eval --impure"
  skip_test test_T80_hm_invalid_name_validation_matrix "requires nix eval --impure"
  skip_test test_T85_hm_per_skill_enable_false_omits_entry "requires nix eval --impure"
  skip_test test_T86_hm_enabled_destination_collision_fails "requires nix eval --impure"
  skip_test test_T93_hm_enabled_destination_collision_canonicalized_dirs_fails "requires nix eval --impure"
else
  run_test test_T78_hm_name_override_changes_home_file_key
  run_test test_T79_hm_default_name_path_when_name_omitted
  run_test test_T80_hm_invalid_name_validation_matrix
  run_test test_T85_hm_per_skill_enable_false_omits_entry
  run_test test_T86_hm_enabled_destination_collision_fails
  run_test test_T93_hm_enabled_destination_collision_canonicalized_dirs_fails
fi

echo ""
echo "1..$TOTAL"
echo "# pass $PASS"
echo "# fail $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
