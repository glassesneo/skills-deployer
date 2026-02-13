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
#   name       : String | null        # Per-skill deployed directory name; null -> use attr key
#   enable     : Bool                 # Per-skill enable flag; omitted -> true
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

  assertExplicitNameType = skillAttrName: value:
    assert lib.assertMsg (value == null || builtins.isString value)
    "skills-deployer: skill '${skillAttrName}' has 'name' with invalid type. Expected string or null, got ${builtins.typeOf value}."; value;

  assertExplicitNameValid = skillAttrName: deployedName:
    assert lib.assertMsg (builtins.stringLength deployedName > 0)
    "skills-deployer: skill '${skillAttrName}' has explicit 'name' that is empty. Provide a non-empty deployed name.";
    assert lib.assertMsg (deployedName != "." && deployedName != "..")
    "skills-deployer: skill '${skillAttrName}' has explicit 'name' '${deployedName}', which is forbidden.";
    assert lib.assertMsg (!(lib.hasInfix "/" deployedName))
    "skills-deployer: skill '${skillAttrName}' has explicit 'name' '${deployedName}' containing '/', which is forbidden.";
    assert lib.assertMsg (!(lib.hasInfix "@@" deployedName))
    "skills-deployer: skill '${skillAttrName}' has explicit 'name' '${deployedName}' containing '@@', which is forbidden."; deployedName;

  assertEnableType = skillAttrName: value:
    assert lib.assertMsg (builtins.isBool value)
    "skills-deployer: skill '${skillAttrName}' has 'enable' with invalid type. Expected bool, got ${builtins.typeOf value}."; value;

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

  # Normalize directory path for destination/key comparison.
  # Canonicalization rules:
  # - collapse repeated leading "./"
  # - strip all trailing "/"
  # - preserve "." semantics (".", "./", "././", ".///" => ".")
  normalizePath = directoryPath: let
    stripLeadingDotPrefixes = value:
      if value == "." || value == "./"
      then "."
      else if lib.hasPrefix "./" value
      then stripLeadingDotPrefixes (builtins.substring 2 ((builtins.stringLength value) - 2) value)
      else value;

    stripTrailingSlashes = value:
      if value == "."
      then "."
      else if lib.hasSuffix "/" value
      then stripTrailingSlashes (lib.removeSuffix "/" value)
      else value;
  in
    stripTrailingSlashes (stripLeadingDotPrefixes directoryPath);

  # --- Build manifest entries ---
  # Expand a single SkillSpec into a compiled representation used for
  # enabled manifest entries and disabled cleanup payload.
  resolveSkill = skillAttrName: spec: let
    checkSkillNameValid = assertSkillNameValid skillAttrName;
    explicitName =
      if spec ? name
      then spec.name
      else null;
    checkExplicitNameType = assertExplicitNameType skillAttrName explicitName;
    resolvedName =
      if explicitName != null
      then assertExplicitNameValid skillAttrName explicitName
      else skillAttrName;
    enabled =
      if spec ? enable
      then assertEnableType skillAttrName spec.enable
      else true;
    checkTargetDirsMutualExclusion = assertTargetDirsMutualExclusion skillAttrName spec;
    checkTargetDirType = assertTargetDirType skillAttrName (
      if spec ? targetDir
      then spec.targetDir
      else null
    );
    checkTargetDirsType = assertTargetDirsType skillAttrName (
      if spec ? targetDirs
      then spec.targetDirs
      else null
    );
    requiredSource = assert lib.assertMsg (builtins.hasAttr "source" spec)
    "skills-deployer: skill '${skillAttrName}' is missing required field 'source'.";
      spec.source;
    requiredSubdir = assert lib.assertMsg (builtins.hasAttr "subdir" spec)
    "skills-deployer: skill '${skillAttrName}' is missing required field 'subdir'.";
      spec.subdir;
    mode = assertMode skillAttrName (
      if (spec ? mode) && spec.mode != null
      then spec.mode
      else defaultMode
    );
    subdir = assertSubdir skillAttrName requiredSubdir;
    resolvedSource = "${requiredSource}/${subdir}";

    hasTargetDirs = (spec ? targetDirs) && spec.targetDirs != null;
    targetDirsList =
      if hasTargetDirs
      then map (assertTargetDirRelative skillAttrName) (assertTargetDirsNoDuplicates skillAttrName (assertTargetDirsNonEmpty skillAttrName spec.targetDirs))
      else [
        (
          if (spec ? targetDir) && spec.targetDir != null
          then spec.targetDir
          else defaultTargetDir
        )
      ];
    normalizedTargetDirs = map normalizePath targetDirsList;

    # Force evaluation of all validator bindings (Nix is lazy; seq ensures assertions fire)
    _ = builtins.seq checkSkillNameValid (
      builtins.seq checkExplicitNameType (
        builtins.seq checkTargetDirsMutualExclusion (
          builtins.seq checkTargetDirType (
            builtins.seq checkTargetDirsType true
          )
        )
      )
    );

    mkEntry = dir: {
      name = resolvedName;
      inherit mode subdir;
      targetDir = dir;
      sourcePath = resolvedSource;
    };

    # ALWAYS use @@-keyed format when targetDirs is used, even for single element.
    # Plain name keys are only used for targetDir (singular) or default.
    mkKey = dir: let
      normalizedDir = normalizePath dir;
    in
      if hasTargetDirs
      then "${skillAttrName}@@${normalizedDir}"
      else skillAttrName;

    destinationPaths = map (dir: "${dir}/${resolvedName}") normalizedTargetDirs;
    forceFullValidation = builtins.seq mode (builtins.seq subdir (builtins.seq requiredSource true));
  in
    builtins.seq _ (builtins.seq forceFullValidation {
      inherit enabled destinationPaths;
      entries = builtins.listToAttrs (map (dir: {
          name = mkKey dir;
          value = mkEntry dir;
        })
        normalizedTargetDirs);
      disabledEntry = {
        name = resolvedName;
        targetDirs = normalizedTargetDirs;
      };
    });

  findDuplicates = list: let
    uniqueValues = lib.unique list;
  in
    builtins.filter (value: lib.count (item: item == value) list > 1) uniqueValues;

  compiledSkills = lib.mapAttrs resolveSkill skills;

  enabledSkills = lib.filterAttrs (_: compiled: compiled.enabled) compiledSkills;
  disabledSkills = lib.filterAttrs (_: compiled: !compiled.enabled) compiledSkills;

  enabledDestinations = builtins.concatLists (lib.mapAttrsToList (_: compiled: compiled.destinationPaths) enabledSkills);
  disabledDestinations = builtins.concatLists (lib.mapAttrsToList (_: compiled: compiled.destinationPaths) disabledSkills);

  duplicateEnabledDestinations = findDuplicates enabledDestinations;
  overlappingDestinations = lib.intersectLists (lib.unique enabledDestinations) (lib.unique disabledDestinations);

  assertEnabledDestinationUniqueness = assert lib.assertMsg (builtins.length duplicateEnabledDestinations == 0)
  ''
    skills-deployer: enabled skills resolve to colliding destinations.
    Collisions: ${builtins.concatStringsSep ", " duplicateEnabledDestinations}.
    Each enabled destination '<targetDir>/<name>' must be unique.
  ''; true;

  assertEnabledDisabledDestinationDisjoint = assert lib.assertMsg (builtins.length overlappingDestinations == 0)
  ''
    skills-deployer: enabled and disabled skills overlap on destination(s).
    Overlap: ${builtins.concatStringsSep ", " overlappingDestinations}.
    A destination cannot be both enabled and disabled in one evaluation.
  ''; true;

  # Merge with collision detection: ensure no two skills produce the same manifest key
  manifestEntries = let
    mergeOne = acc: skillAttrName: compiled: let
      expanded = compiled.entries;
      newKeys = builtins.attrNames expanded;
    in
      if builtins.any (key: acc ? key) newKeys
      then
        throw ''
          skills-deployer: skill '${skillAttrName}' produces manifest key(s) that collide with existing entries.
          Collision detected: ${builtins.concatStringsSep ", " (builtins.filter (key: acc ? key) newKeys)}.
          Consider renaming the skill or avoiding '@@' in skill names.
        ''
      else acc // expanded;
  in
    builtins.seq assertEnabledDestinationUniqueness (
      builtins.seq assertEnabledDisabledDestinationDisjoint (
        lib.foldlAttrs mergeOne {} enabledSkills
      )
    );

  disabledManifestEntries = lib.mapAttrsToList (_: compiled: compiled.disabledEntry) disabledSkills;

  manifestJSON =
    pkgs.writeText "skills-manifest.json"
    (builtins.toJSON manifestEntries);

  disabledManifestJSON =
    pkgs.writeText "skills-disabled-manifest.json"
    (builtins.toJSON disabledManifestEntries);

  deployScript = builtins.readFile ../scripts/deploy-skills.bash;
in let
  drv = pkgs.writeShellApplication {
    name = "deploy-skills";
    runtimeInputs = [pkgs.jq pkgs.coreutils];
    text = ''
      MANIFEST_PATH="${manifestJSON}"
      DISABLED_MANIFEST_PATH="${disabledManifestJSON}"
      ${deployScript}
    '';
  };
in
  drv
  // {
    passthru = {
      manifestPath = manifestJSON;
      disabledManifestPath = disabledManifestJSON;
    };
  }
