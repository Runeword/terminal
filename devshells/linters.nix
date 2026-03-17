{ pkgs }:
pkgs.mkShell {
  buildInputs = [
    pkgs.nixfmt-rfc-style
    pkgs.shfmt
    pkgs.shellharden
    pkgs.shellcheck
    pkgs.taplo
  ];
}
