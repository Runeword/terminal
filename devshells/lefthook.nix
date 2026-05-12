{ lefthook, pkgs }:
with lefthook.lib;
mkShell {
  inherit pkgs;
  modules = [
    auto-msg
    format-go
    format-nix
    format-shell
    format-toml
    format-yaml
    lint-go
    lint-nix
    lint-shell
    security-gitleaks
  ];
}
