{ pkgs, lefthook }:
lefthook.lib.${pkgs.stdenv.hostPlatform.system}.mkShell {
  hooks = {
    format-go.enable = true;
    lint-go.enable = true;
    format-nix.enable = true;
    lint-nix.enable = true;
    format-shell.enable = true;
    lint-shell.enable = true;
    format-toml.enable = true;
    format-yaml.enable = true;
    format-opentofu.enable = true;
    lint-opentofu.enable = true;
    security-gitleaks.enable = true;
    auto-commit.enable = true;
  };
}
