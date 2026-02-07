# mkDeploySkills :: {
#   pkgs           : Nixpkgs package set
#   skills         : AttrSet<SkillName, SkillSpec>
#   defaultMode    : "symlink" | "copy"          (default: "symlink")
#   defaultTargetDir : String                     (default: ".agents/skills")
# } -> Derivation
#
# SkillSpec :: {
#   source    : Path | Derivation    # Nix store path to the source repo/tree
#   subdir    : String               # Subdirectory within source containing the skill
#   mode      : "symlink" | "copy" | null  # Per-skill override; null -> use defaultMode
#   targetDir : String | null        # Per-skill override; null -> use defaultTargetDir
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
    "skills-deployer: skill '${name}' has invalid mode '${mode}'. Must be one of: ${builtins.concatStringsSep ", " validModes}.";
      mode;

  assertSubdir = name: subdir:
    assert lib.assertMsg (!(lib.hasPrefix "/" subdir))
    "skills-deployer: skill '${name}' subdir must be relative, got '${subdir}'.";
      assert lib.assertMsg (!(lib.hasInfix ".." subdir))
      "skills-deployer: skill '${name}' subdir contains '..', which is forbidden.";
        subdir;

  # --- Build manifest entries ---
  manifestEntries =
    lib.mapAttrs (name: spec: let
      mode = assertMode name (if (spec ? mode) && spec.mode != null then spec.mode else defaultMode);
      subdir = assertSubdir name spec.subdir;
      targetDir = if (spec ? targetDir) && spec.targetDir != null then spec.targetDir else defaultTargetDir;
      resolvedSource = "${spec.source}/${subdir}";
    in {
      inherit name mode subdir targetDir;
      sourcePath = resolvedSource;
    })
    skills;

  manifestJSON =
    pkgs.writeText "skills-manifest.json"
    (builtins.toJSON manifestEntries);

  deployScript = builtins.readFile ../scripts/deploy-skills.bash;
in
  pkgs.writeShellApplication {
    name = "deploy-skills";
    runtimeInputs = [pkgs.jq pkgs.coreutils];
    text = ''
      MANIFEST_PATH="${manifestJSON}"
      ${deployScript}
    '';
  }
