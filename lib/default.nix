{
  mkDeploySkillsDrv = import ./mkDeploySkills.nix;
  mkDeploySkills = pkgs: args: {
    type = "app";
    program = "${import ./mkDeploySkills.nix ({inherit pkgs;} // args)}/bin/deploy-skills";
  };
}
