{ pkgs }:
pkgs.mkShell {
  buildInputs = [
    pkgs.lefthook
    pkgs.nixfmt
    pkgs.shfmt
    pkgs.shellharden
    pkgs.shellcheck
    pkgs.taplo
    pkgs.yamlfmt
  ];
  shellHook = ''
    lefthook install
  '';
}
