# modules/home-manager.nix
{
  config,
  lib,
  ...
}: let
  cfg = config.programs.skills-deployer;

  skillType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional deployed skill directory name override";
      };
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to deploy this skill";
      };
      source = lib.mkOption {
        type = lib.types.path;
        description = "Nix store path to source tree";
      };
      subdir = lib.mkOption {
        type = lib.types.str;
        description = "Relative subdirectory within source";
      };
      targetDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Target directory relative to $HOME";
      };
      targetDirs = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = "Target directories relative to $HOME (mutually exclusive with targetDir)";
      };
    };
  };

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

  getTargetPath = skillName: targetDir: "${targetDir}/${skillName}";
  getSourcePath = skill: "${skill.source}/${skill.subdir}";
  getResolvedSkillName = skillName: skill:
    if skill.name != null
    then skill.name
    else skillName;

  getDirs = skill:
    if skill.targetDirs != null
    then skill.targetDirs
    else if skill.targetDir != null
    then [skill.targetDir]
    else [cfg.defaultTargetDir];

  validateSkill = skillName: skill: let
    hasTargetDir = skill.targetDir != null;
    hasTargetDirs = skill.targetDirs != null;
    hasExplicitName = skill.name != null;
    explicitName =
      if hasExplicitName
      then skill.name
      else "";
    dirs =
      if hasTargetDirs
      then skill.targetDirs
      else [];
    normalized = map normalizePath dirs;
  in [
    {
      assertion = !(hasTargetDir && hasTargetDirs);
      message = "skills-deployer: skill '${skillName}' sets both 'targetDir' and 'targetDirs'. Use one or the other.";
    }
    {
      assertion = (!hasTargetDirs) || (builtins.length dirs > 0);
      message = "skills-deployer: skill '${skillName}' has empty 'targetDirs' list. Provide at least one directory.";
    }
    {
      assertion = (!hasTargetDirs) || (builtins.all (dir: builtins.stringLength dir > 0) dirs);
      message = "skills-deployer: skill '${skillName}' targetDirs entry cannot be empty.";
    }
    {
      assertion = (!hasTargetDirs) || (builtins.all (dir: !(lib.hasPrefix "/" dir)) dirs);
      message = "skills-deployer: skill '${skillName}' targetDirs entry must be relative.";
    }
    {
      assertion = (!hasTargetDirs) || (builtins.all (dir: !(lib.hasInfix ".." dir)) dirs);
      message = "skills-deployer: skill '${skillName}' targetDirs entry contains '..', which is forbidden.";
    }
    {
      assertion = (!hasTargetDirs) || (builtins.length normalized == builtins.length (lib.unique normalized));
      message = "skills-deployer: skill '${skillName}' has duplicate entries in 'targetDirs'. Each target directory must be unique.";
    }
    {
      assertion = (!hasExplicitName) || (builtins.stringLength explicitName > 0);
      message = "skills-deployer: skill '${skillName}' has invalid 'name'. It cannot be empty.";
    }
    {
      assertion = (!hasExplicitName) || ((explicitName != ".") && (explicitName != ".."));
      message = "skills-deployer: skill '${skillName}' has invalid 'name'. '.' and '..' are forbidden.";
    }
    {
      assertion = (!hasExplicitName) || !(lib.hasInfix "/" explicitName);
      message = "skills-deployer: skill '${skillName}' has invalid 'name'. '/' is forbidden.";
    }
    {
      assertion = (!hasExplicitName) || !(lib.hasInfix "@@" explicitName);
      message = "skills-deployer: skill '${skillName}' has invalid 'name'. '@@' is forbidden.";
    }
  ];

  allSkillAssertions =
    lib.flatten (lib.mapAttrsToList validateSkill cfg.skills);

  enabledSkillDestinationPaths = lib.flatten (
    lib.mapAttrsToList
    (skillName: skill:
      if skill.enable
      then let
        resolvedName = getResolvedSkillName skillName skill;
        normalizedDirs = map normalizePath (getDirs skill);
      in
        map (dir: getTargetPath resolvedName dir) normalizedDirs
      else [])
    cfg.skills
  );

  enabledSkillDestinationCollisionAssertion = {
    assertion = builtins.length enabledSkillDestinationPaths == builtins.length (lib.unique enabledSkillDestinationPaths);
    message = "skills-deployer: enabled skills resolve to duplicate destination paths. Each '<targetDir>/<name>' destination must be unique.";
  };

  allAssertions = allSkillAssertions ++ [enabledSkillDestinationCollisionAssertion];

  skillToAttrs = resolvedName: sourcePath: targetDirs: let
    targetPath = dir: getTargetPath resolvedName dir;
    skillNameValuePair = dir:
      lib.attrsets.nameValuePair (targetPath dir) {
        source = sourcePath;
      };
  in
    builtins.listToAttrs (map skillNameValuePair targetDirs);

  deployedSkillsAttrs =
    lib.attrsets.concatMapAttrs
    (skillName: skill:
      if skill.enable
      then let
        dirs = getDirs skill;
        resolvedName = getResolvedSkillName skillName skill;
        normalizedDirs = map normalizePath dirs;
      in
        skillToAttrs resolvedName (getSourcePath skill) normalizedDirs
      else {})
    cfg.skills;
in {
  options.programs.skills-deployer = {
    enable = lib.mkEnableOption "skills-deployer";

    defaultTargetDir = lib.mkOption {
      type = lib.types.str;
      default = ".agents/skills";
      description = "Default parent directory for skills";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf skillType;
      default = {};
      description = "Skills to deploy, keyed by name";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = allAssertions;
    home.file = deployedSkillsAttrs;
  };
}
