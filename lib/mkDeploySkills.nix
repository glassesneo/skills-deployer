# mkDeploySkills :: {
#   pkgs           : Nixpkgs package set
#   skills         : AttrSet<SkillName, SkillSpec>
#   defaultMode    : "symlink" | "copy"          (default: "symlink")
#   defaultTargetDir : String                     (default: ".agents/skills")
# } -> Derivation
#
# SkillSpec :: {
#   source     : Path | Derivation    # Nix store path to the source repo/tree
#   subdir     : String               # Subdirectory within source containing the skill
#   mode       : "symlink" | "copy" | null  # Per-skill override; null -> use defaultMode
#   targetDir  : String | null        # Per-skill override; null -> use defaultTargetDir
#   targetDirs : List<String> | null  # Deploy to multiple dirs; null -> not used
#   # Constraint: targetDir and targetDirs are mutually exclusive.
#   # When targetDirs is set, one manifest entry per dir is produced, keyed "<name>@@<dir>".
#   # When targetDirs has exactly 1 element, the @@-keyed format is still used.
# }
{
  pkgs,
  skills, # AttrSet<String, SkillSpec>
  defaultMode ? "symlink",
  defaultTargetDir ? ".agents/skills",
}: let
  lib = pkgs.lib;

  # --- Schema validation (eval-time) ---
  validModes = ["symlink" "copy"];

  assertMode = name: mode:
    assert lib.assertMsg (builtins.elem mode validModes)
    "skills-deployer: skill '${name}' has invalid mode '${mode}'. Must be one of: ${builtins.concatStringsSep ", " validModes}."; mode;

  assertSubdir = name: subdir:
    assert lib.assertMsg (!(lib.hasPrefix "/" subdir))
    "skills-deployer: skill '${name}' subdir must be relative, got '${subdir}'.";
    assert lib.assertMsg (!(lib.hasInfix ".." subdir))
    "skills-deployer: skill '${name}' subdir contains '..', which is forbidden."; subdir;

  assertSkillNameValid = name:
    assert lib.assertMsg (!(lib.hasInfix "@@" name))
    "skills-deployer: skill name '${name}' cannot contain '@@' (reserved for multi-target key generation)."; name;

  assertTargetDirsMutualExclusion = name: spec:
    assert lib.assertMsg
    (!((spec ? targetDir && spec.targetDir != null) && (spec ? targetDirs && spec.targetDirs != null)))
    "skills-deployer: skill '${name}' sets both 'targetDir' and 'targetDirs'. Use one or the other."; true;

  assertTargetDirsNonEmpty = name: dirs:
    assert lib.assertMsg (builtins.length dirs > 0)
    "skills-deployer: skill '${name}' has empty 'targetDirs' list. Provide at least one directory."; dirs;

  assertTargetDirsNoDuplicates = name: dirs: let
    normalized = map normalizePath dirs;
  in
    assert lib.assertMsg (builtins.length normalized == builtins.length (lib.unique normalized))
    "skills-deployer: skill '${name}' has duplicate entries in 'targetDirs'. Each target directory must be unique."; dirs;

  assertTargetDirRelative = name: dir:
    assert lib.assertMsg (builtins.stringLength dir > 0)
    "skills-deployer: skill '${name}' targetDirs entry cannot be empty.";
    assert lib.assertMsg (!(lib.hasPrefix "/" dir))
    "skills-deployer: skill '${name}' targetDirs entry must be relative, got '${dir}'.";
    assert lib.assertMsg (!(lib.hasInfix ".." dir))
    "skills-deployer: skill '${name}' targetDirs entry contains '..', which is forbidden."; dir;

  assertTargetDirType = name: value:
    assert lib.assertMsg (value == null || builtins.isString value)
    "skills-deployer: skill '${name}' has 'targetDir' with invalid type. Expected string or null, got ${builtins.typeOf value}. If you meant to specify multiple target directories, use 'targetDirs' (plural) instead."; value;

  assertTargetDirsType = name: value:
    assert lib.assertMsg (value == null || builtins.isList value)
    "skills-deployer: skill '${name}' has 'targetDirs' with invalid type. Expected list or null, got ${builtins.typeOf value}. If you meant to specify a single target directory, use 'targetDir' (singular) instead."; value;

  # Normalize directory path: trim trailing slashes and leading ./ (for deduplication comparison)
  normalizePath = path: let
    trimmedSlashes = lib.removeSuffix "/" (lib.removeSuffix "/" path);
    trimmedDot =
      if lib.hasPrefix "./" trimmedSlashes
      then builtins.substring 2 (builtins.stringLength trimmedSlashes) trimmedSlashes
      else trimmedSlashes;
  in
    trimmedDot;

  # --- Build manifest entries ---
  # Expand a single SkillSpec into one or more manifest entries.
  # Returns: AttrSet<ManifestKey, ManifestEntry>
  expandSkill = name: spec: let
    checkSkillNameValid = assertSkillNameValid name;
    checkTargetDirsMutualExclusion = assertTargetDirsMutualExclusion name spec;
    checkTargetDirType = assertTargetDirType name (if spec ? targetDir then spec.targetDir else null);
    checkTargetDirsType = assertTargetDirsType name (if spec ? targetDirs then spec.targetDirs else null);
    mode = assertMode name (
      if (spec ? mode) && spec.mode != null
      then spec.mode
      else defaultMode
    );
    subdir = assertSubdir name spec.subdir;
    resolvedSource = "${spec.source}/${subdir}";

    hasTargetDirs = (spec ? targetDirs) && spec.targetDirs != null;
    targetDirsList =
      if hasTargetDirs
      then map (assertTargetDirRelative name) (assertTargetDirsNoDuplicates name (assertTargetDirsNonEmpty name spec.targetDirs))
      else [
        (
          if (spec ? targetDir) && spec.targetDir != null
          then spec.targetDir
          else defaultTargetDir
        )
      ];

    # Force evaluation of all validator bindings (Nix is lazy; seq ensures assertions fire)
    _ = builtins.seq checkSkillNameValid (
          builtins.seq checkTargetDirsMutualExclusion (
            builtins.seq checkTargetDirType (
                  builtins.seq checkTargetDirsType true)));

    mkEntry = dir: {
      inherit name mode subdir;
      targetDir = dir;
      sourcePath = resolvedSource;
    };

    # ALWAYS use @@-keyed format when targetDirs is used, even for single element.
    # Plain name keys are only used for targetDir (singular) or default.
    mkKey = dir: let
      normalizedDir = normalizePath dir;
    in
      if hasTargetDirs
      then "${name}@@${normalizedDir}"
      else name;
  in
    builtins.seq _ (builtins.listToAttrs (map (dir: {
        name = mkKey dir;
        value = mkEntry dir;
      })
      targetDirsList));

  # Merge with collision detection: ensure no two skills produce the same manifest key
  manifestEntries = let
    mergeOne = acc: name: spec: let
      expanded = expandSkill name spec;
      newKeys = builtins.attrNames expanded;
    in
      if builtins.any (key: acc ? key) newKeys
      then
        throw ''
          skills-deployer: skill '${name}' produces manifest key(s) that collide with existing entries.
          Collision detected: ${builtins.concatStringsSep ", " (builtins.filter (key: acc ? key) newKeys)}.
          Consider renaming the skill or avoiding '@@' in skill names.
        ''
      else acc // expanded;
  in
    lib.foldlAttrs mergeOne {} skills;

  manifestJSON =
    pkgs.writeText "skills-manifest.json"
    (builtins.toJSON manifestEntries);

  deployScript = builtins.readFile ../scripts/deploy-skills.bash;
in let
  drv = pkgs.writeShellApplication {
    name = "deploy-skills";
    runtimeInputs = [pkgs.jq pkgs.coreutils];
    text = ''
      MANIFEST_PATH="${manifestJSON}"
      ${deployScript}
    '';
  };
in
  drv // {passthru = {manifestPath = manifestJSON;};}

