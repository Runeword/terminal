{ lefthook, pkgs }:
with lefthook.lib;
mkShell {
  inherit pkgs;
  modules = [
    auto-msg
    format-nix
    format-shell
    format-toml
    format-yaml
    lint-shell
  ];
}
