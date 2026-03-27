{ pkgs }:
pkgs.mkShell {
  buildInputs = [
    pkgs.lefthook
    pkgs.nixfmt-rfc-style
    pkgs.shfmt
    pkgs.shellharden
    pkgs.shellcheck
    pkgs.taplo
  ];
  shellHook = ''
    lefthook install
  '';
}
