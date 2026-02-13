# modules/home-manager.nix
{
  config,
  lib,
  ...
}: let
  cfg = config.programs.skills-deployer;

  skillType = lib.types.submodule {
    options = {
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
    trimmedSlashes = lib.removeSuffix "/" (lib.removeSuffix "/" directoryPath);
    trimmedDot =
      if lib.hasPrefix "./" trimmedSlashes
      then builtins.substring 2 (builtins.stringLength trimmedSlashes) trimmedSlashes
      else trimmedSlashes;
  in
    trimmedDot;

  getTargetPath = skillName: targetDir: "${targetDir}/${skillName}";
  getSourcePath = skillName: let
    skill = cfg.skills.${skillName};
  in "${skill.source}/${skill.subdir}";

  getDirs = skill:
    if skill.targetDirs != null
    then skill.targetDirs
    else if skill.targetDir != null
    then [skill.targetDir]
    else [cfg.defaultTargetDir];

  validateSkill = skillName: skill: let
    hasTargetDir = skill.targetDir != null;
    hasTargetDirs = skill.targetDirs != null;
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
  ];

  allSkillAssertions =
    lib.flatten (lib.mapAttrsToList validateSkill cfg.skills);

  skillToAttrs = skillName: targetDirs: let
    targetPath = dir: getTargetPath skillName dir;
    sourcePath = getSourcePath skillName;
    skillNameValuePair = dir:
      lib.attrsets.nameValuePair (targetPath dir) {
        source = sourcePath;
      };
  in
    builtins.listToAttrs (map skillNameValuePair targetDirs);

  deployedSkillsAttrs =
    lib.attrsets.concatMapAttrs
    (name: skill: let dirs = getDirs skill; in skillToAttrs name dirs)
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
    assertions = allSkillAssertions;
    home.file = deployedSkillsAttrs;
  };
}
