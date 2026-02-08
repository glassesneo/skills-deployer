# skills-deployer

A Nix flake library that deploys agent skill directories into consumer projects. Skills are declared as an attrset in your `flake.nix`, sourced from arbitrary flake inputs, and materialized into a local directory tree via `nix run .#deploy-skills`.

## Quick Start

Add this flake as an input and declare your skills:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    skills-deployer.url = "github:glassesneo/skills-deployer";

    # Skill sources -- any flake or path
    my-skills-repo.url = "github:your-org/agent-skills";
    my-skills-repo.flake = false;

    community-skills.url = "github:community/ai-skills-collection";
    community-skills.flake = false;
  };

  outputs = { self, nixpkgs, skills-deployer, my-skills-repo, community-skills, ... }:
    let
      eachSystem = f: nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed (system: f {
        inherit system;
        pkgs = nixpkgs.legacyPackages.${system};
      });
    in {
      apps = eachSystem ({ system, pkgs }: {
        deploy-skills = skills-deployer.lib.mkDeploySkills pkgs {
            # Global defaults
            defaultMode = "symlink";        # or "copy"
            defaultTargetDir = ".agents/skills";

            skills = {
              # Skill name = destination directory name
              code-review = {
                source = my-skills-repo;     # Nix store path
                subdir = "skills/code-review"; # Required: path within source
              };

              debugging = {
                source = my-skills-repo;
                subdir = "skills/debugging";
                mode = "copy";                # Override: copy for this skill
              };

              ui-patterns = {
                source = community-skills;
                subdir = "patterns/ui";
                targetDirs = [".agents/skills" ".claude/skills"]; # Deploy to multiple targets
              };
            };
          };
      });
    };
}
```

## Usage

```bash
# Deploy all skills
nix run .#deploy-skills

# Preview changes (CI drift detection)
nix run .#deploy-skills -- --dry-run
```

## Configuration Reference

### `mkDeploySkills` signature

```nix
mkDeploySkills pkgs {
  skills = { ... };
  defaultMode = "symlink";       # optional
  defaultTargetDir = ".agents/skills"; # optional
}
```

### First argument (`pkgs`)

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `pkgs` | Nixpkgs set | Yes | -- | Nixpkgs package set for the target system |

### Second argument (configuration attrset)

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `skills` | `AttrSet<String, SkillSpec>` | Yes | -- | Skills to deploy, keyed by destination name |
| `defaultMode` | `"symlink"` or `"copy"` | No | `"symlink"` | Default deployment mode |
| `defaultTargetDir` | `String` | No | `".agents/skills"` | Default parent directory for skills |

### `SkillSpec` attributes

| Attribute | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `source` | `Path` or `Derivation` | Yes | -- | Nix store path to source tree |
| `subdir` | `String` | Yes | -- | Relative subdirectory within source; must not contain `..` or start with `/` |
| `mode` | `"symlink"` or `"copy"` | No | Uses `defaultMode` | Per-skill mode override |
| `targetDir` | `String` | No | Uses `defaultTargetDir` | Per-skill target directory override |
| `targetDirs` | `List<String>` | No | `null` | Deploy to multiple directories; mutually exclusive with `targetDir` |

## Deployment Modes

### `symlink` (default)

Individual files are symlinked from the Nix store into the target directory. The skill directory itself is a real directory (to allow the marker file), but each file inside is a symlink. Symlinked skills are immutable (Nix store is read-only).

### `copy`

Files are copied from the Nix store into the target directory. The skill is fully independent of the Nix store after deployment and can be locally edited.

 Use `copy` for skills you want to customize locally. Use `symlink` for shared/immutable skills where you want to save disk space and ensure consistency.

## Multi-Target Deployment

Deploy a single skill to multiple directories with `targetDirs`:

```nix
skills = {
  code-review = {
    source = my-skills-repo;
    subdir = "skills/code-review";
    targetDirs = [".agents/skills" ".claude/skills"];
  };
};
```

This deploys `code-review` to both `.agents/skills/code-review/` and `.claude/skills/code-review/`. Each target is tracked independently — adding or removing a directory from the list only affects that specific target.

`targetDirs` and `targetDir` are mutually exclusive. For per-target customization (different modes or names), declare separate skill entries:

```nix
skills = {
  code-review-agents = {
    source = my-skills-repo;
    subdir = "skills/code-review";
    mode = "symlink";
    targetDir = ".agents/skills";
  };
  code-review-claude = {
    source = my-skills-repo;
    subdir = "skills/code-review";
    mode = "copy";
    targetDir = ".claude/skills";
  };
};
```

> **Note on manifest internals**: When `targetDirs` is used, manifest entries are keyed as `<name>@@<targetDir>`. The Bash script uses the entry's `name` field (not the manifest key) to determine the deployment destination directory. Manually-crafted manifests with `@@` keys but different `name` values will deploy to the `name` location, not the location implied by the key.


## Marker Files

Each deployed skill directory contains a `.skills-deployer-managed` file (single-line JSON):

```json
{"version":"1","skillName":"code-review","mode":"symlink","sourcePath":"/nix/store/abc123-source/skills/code-review","deployedAt":"2026-02-07T20:14:00Z"}
```

This marker is used for:
- **Idempotency**: If `mode` and `sourcePath` match the manifest, the skill is skipped.
- **Conflict detection**: If a target directory exists without a marker, deployment fails with remediation instructions.
- **Mode change detection**: If the mode changes, the skill is atomically replaced.

## CI Integration

Use `--dry-run` in CI to detect drift. It exits 0 when everything is up-to-date and 1 when changes are pending:

```yaml
# GitHub Actions
- name: Check skills are up-to-date
  run: nix run .#deploy-skills -- --dry-run
```

## Exit Codes

| Code | Condition |
|------|-----------|
| 0 | Success (deploy completed or dry-run up-to-date) |
| 1 | Dry-run detected pending changes |
| 2 | Unknown CLI argument |
| 3 | Not in project root (no `flake.nix` in CWD) |
| 4 | Internal error (manifest not found) |
| 5 | Validation failure (missing `SKILL.md`, bad source path) |
| 6 | Unmanaged conflict at target path |

## Requirements

- Nix with flakes enabled
- Each skill source directory must contain a `SKILL.md` file
- Run from the project root (directory containing `flake.nix`)
- Non-flake skill source repos must set `flake = false` in the input declaration

## Running Tests

```bash
# Via Nix
nix run .#test

# Directly
bash tests/run-tests.bash
```
