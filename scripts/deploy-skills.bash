# MANIFEST_PATH is injected by Nix wrapper above this point.
# shellcheck disable=SC2154  # MANIFEST_PATH is set by the Nix wrapper

set -euo pipefail

# -- Constants ---------------------------------------------------
MARKER_FILENAME=".skills-deployer-managed"
MARKER_VERSION="1"
DRY_RUN=false
ACTIONS_PLANNED=0
ACTIONS_EXECUTED=0
ERRORS=()

# -- Color helpers (respect NO_COLOR) ---------------------------
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

info()  { printf "%s[info]%s  %s\n" "$BLUE" "$NC" "$1"; }
ok()    { printf "%s[ok]%s    %s\n" "$GREEN" "$NC" "$1"; }
warn()  { printf "%s[warn]%s  %s\n" "$YELLOW" "$NC" "$1"; }
die()   { printf "%s[error]%s %s\n" "$RED" "$NC" "$1" >&2; exit "${2:-1}"; }
skip()  { printf "%s[skip]%s  %s\n" "$YELLOW" "$NC" "$1"; }

# -- Argument parsing --------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --help|-h)
      echo "Usage: deploy-skills [--dry-run]"
      echo ""
      echo "Deploy agent skills to the project."
      echo ""
      echo "Options:"
      echo "  --dry-run  Show what would be done without making changes."
      echo "             Exits 0 if already up-to-date, 1 if changes needed."
      exit 0
      ;;
    *) die "Unknown argument: $arg" 2 ;;
  esac
done

# -- Project root assertion --------------------------------------
if [[ ! -f "flake.nix" ]]; then
  die "Not in project root (flake.nix not found). Run from the directory containing your flake.nix." 3
fi

# -- Read manifest -----------------------------------------------
if [[ ! -f "$MANIFEST_PATH" ]]; then
  die "Internal error: manifest not found at $MANIFEST_PATH" 4
fi
MANIFEST=$(cat "$MANIFEST_PATH")
SKILL_NAMES=$(echo "$MANIFEST" | jq -r 'keys[]' | sort)

if [[ -z "$SKILL_NAMES" ]]; then
  info "No skills configured. Nothing to do."
  exit 0
fi

# -- Validate all skills before any writes -----------------------
info "Validating skills..."
while IFS= read -r SKILL_NAME; do
  SOURCE_PATH=$(echo "$MANIFEST" | jq -r --arg s "$SKILL_NAME" '.[$s].sourcePath')
  SUBDIR=$(echo "$MANIFEST" | jq -r --arg s "$SKILL_NAME" '.[$s].subdir')

  if [[ ! -d "$SOURCE_PATH" ]]; then
    ERRORS+=("Skill '$SKILL_NAME': source directory does not exist: $SOURCE_PATH (subdir: $SUBDIR)")
    continue
  fi

  if [[ ! -f "$SOURCE_PATH/SKILL.md" ]]; then
    ERRORS+=("Skill '$SKILL_NAME': SKILL.md not found in $SOURCE_PATH. Every skill must contain a SKILL.md file.")
  fi
done <<< "$SKILL_NAMES"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  printf "%s[error]%s Validation failed:\n" "$RED" "$NC" >&2
  for err in "${ERRORS[@]}"; do
    printf "  - %s\n" "$err" >&2
  done
  exit 5
fi
ok "All skills validated."

# -- Plan actions ------------------------------------------------
declare -A ACTION_MAP  # SKILL_NAME -> action
declare -A ACTION_DESC # SKILL_NAME -> human description

while IFS= read -r SKILL_NAME; do
  SOURCE_PATH=$(echo "$MANIFEST" | jq -r --arg s "$SKILL_NAME" '.[$s].sourcePath')
  MODE=$(echo "$MANIFEST" | jq -r --arg s "$SKILL_NAME" '.[$s].mode')
  TARGET_DIR=$(echo "$MANIFEST" | jq -r --arg s "$SKILL_NAME" '.[$s].targetDir')
  DEST="$TARGET_DIR/$SKILL_NAME"

  if [[ ! -e "$DEST" ]]; then
    ACTION_MAP[$SKILL_NAME]="create"
    ACTION_DESC[$SKILL_NAME]="$MODE $SOURCE_PATH -> $DEST"
    ACTIONS_PLANNED=$((ACTIONS_PLANNED + 1))
    continue
  fi

  MARKER_FILE="$DEST/$MARKER_FILENAME"
  if [[ ! -f "$MARKER_FILE" ]]; then
    die "Conflict: '$DEST' exists but is not managed by skills-deployer (no $MARKER_FILENAME found).
  Remediation: Either remove '$DEST' manually, or add a '$MARKER_FILENAME' file if you want skills-deployer to manage it." 6
  fi

  CURRENT_MODE=$(jq -r '.mode // empty' "$MARKER_FILE" 2>/dev/null || echo "")
  CURRENT_SOURCE=$(jq -r '.sourcePath // empty' "$MARKER_FILE" 2>/dev/null || echo "")

  if [[ "$CURRENT_MODE" == "$MODE" && "$CURRENT_SOURCE" == "$SOURCE_PATH" ]]; then
    ACTION_MAP[$SKILL_NAME]="skip"
    ACTION_DESC[$SKILL_NAME]="up-to-date ($MODE)"
    continue
  fi

  if [[ "$CURRENT_MODE" != "$MODE" ]]; then
    ACTION_MAP[$SKILL_NAME]="replace-mode"
    ACTION_DESC[$SKILL_NAME]="mode change $CURRENT_MODE -> $MODE for $DEST"
  else
    ACTION_MAP[$SKILL_NAME]="update"
    ACTION_DESC[$SKILL_NAME]="update source $DEST"
  fi
  ACTIONS_PLANNED=$((ACTIONS_PLANNED + 1))
done <<< "$SKILL_NAMES"

# -- Dry-run output ----------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  info "Dry-run summary:"
  echo "---"
  while IFS= read -r SKILL_NAME; do
    action="${ACTION_MAP[$SKILL_NAME]}"
    desc="${ACTION_DESC[$SKILL_NAME]}"
    case "$action" in
      skip)         printf "  %s: %s (no change)\n" "$SKILL_NAME" "$desc" ;;
      create)       printf "  %s: CREATE %s\n" "$SKILL_NAME" "$desc" ;;
      update)       printf "  %s: UPDATE %s\n" "$SKILL_NAME" "$desc" ;;
      replace-mode) printf "  %s: REPLACE %s\n" "$SKILL_NAME" "$desc" ;;
    esac
  done <<< "$SKILL_NAMES"
  echo "---"
  if [[ $ACTIONS_PLANNED -gt 0 ]]; then
    warn "$ACTIONS_PLANNED change(s) would be applied."
    exit 1
  else
    ok "Everything up-to-date. No changes needed."
    exit 0
  fi
fi

# -- Execute plan ------------------------------------------------
write_marker() {
  local dest="$1" mode="$2" source_path="$3" skill_name="$4"
  cat > "$dest/$MARKER_FILENAME" <<MARKER_EOF
{"version":"${MARKER_VERSION}","skillName":"${skill_name}","mode":"${mode}","sourcePath":"${source_path}","deployedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
MARKER_EOF
}

deploy_copy() {
  local source_path="$1" dest="$2"
  mkdir -p "$dest"
  if [[ -d "$dest" ]]; then
    find "$dest" -mindepth 1 -not -name "$MARKER_FILENAME" -delete 2>/dev/null || true
  fi
  cp -R "$source_path/." "$dest/"
}

deploy_symlink() {
  local source_path="$1" dest="$2"
  mkdir -p "$dest"
  if [[ -d "$dest" ]]; then
    find "$dest" -mindepth 1 -not -name "$MARKER_FILENAME" -delete 2>/dev/null || true
  fi
  for item in "$source_path"/*; do
    [[ -e "$item" ]] || continue
    local bname
    bname=$(basename "$item")
    ln -sf "$item" "$dest/$bname"
  done
  for item in "$source_path"/.*; do
    [[ -e "$item" ]] || continue
    local bname
    bname=$(basename "$item")
    [[ "$bname" == "." || "$bname" == ".." ]] && continue
    ln -sf "$item" "$dest/$bname"
  done
}

atomic_replace() {
  local source_path="$1" dest="$2" mode="$3" skill_name="$4"
  local tmp_dest="${dest}.skills-deployer-tmp"

  rm -rf "$tmp_dest"
  if [[ "$mode" == "copy" ]]; then
    deploy_copy "$source_path" "$tmp_dest"
  else
    deploy_symlink "$source_path" "$tmp_dest"
  fi
  write_marker "$tmp_dest" "$mode" "$source_path" "$skill_name"

  if [[ -e "$dest" ]]; then
    local old_dest="${dest}.skills-deployer-old"
    rm -rf "$old_dest"
    mv "$dest" "$old_dest"
    mv "$tmp_dest" "$dest"
    rm -rf "$old_dest"
  else
    mv "$tmp_dest" "$dest"
  fi
}

info "Deploying skills..."
while IFS= read -r SKILL_NAME; do
  action="${ACTION_MAP[$SKILL_NAME]}"
  if [[ "$action" == "skip" ]]; then
    skip "$SKILL_NAME: already up-to-date"
    continue
  fi

  SOURCE_PATH=$(echo "$MANIFEST" | jq -r --arg s "$SKILL_NAME" '.[$s].sourcePath')
  MODE=$(echo "$MANIFEST" | jq -r --arg s "$SKILL_NAME" '.[$s].mode')
  TARGET_DIR=$(echo "$MANIFEST" | jq -r --arg s "$SKILL_NAME" '.[$s].targetDir')
  DEST="$TARGET_DIR/$SKILL_NAME"

  mkdir -p "$TARGET_DIR"

  case "$action" in
    create)
      if [[ "$MODE" == "copy" ]]; then
        deploy_copy "$SOURCE_PATH" "$DEST"
      else
        deploy_symlink "$SOURCE_PATH" "$DEST"
      fi
      write_marker "$DEST" "$MODE" "$SOURCE_PATH" "$SKILL_NAME"
      ok "$SKILL_NAME: created ($MODE)"
      ;;
    update|replace-mode)
      atomic_replace "$SOURCE_PATH" "$DEST" "$MODE" "$SKILL_NAME"
      ok "$SKILL_NAME: updated ($action -> $MODE)"
      ;;
  esac
  ACTIONS_EXECUTED=$((ACTIONS_EXECUTED + 1))
done <<< "$SKILL_NAMES"

TOTAL_SKILLS=$(echo "$SKILL_NAMES" | wc -l | tr -d ' ')
SKIPPED=$((TOTAL_SKILLS - ACTIONS_EXECUTED))
echo ""
ok "Done. $ACTIONS_EXECUTED skill(s) deployed, $SKIPPED skipped."
