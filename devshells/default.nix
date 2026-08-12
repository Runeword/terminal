{
  pkgs,
  astGrepShell,
  lefthook,
}:
# Composition point for the dev shell. Each owned sub-shell exposes its helper
# commands as `{ name; usage ? name; doc; text; }` records via `passthru.helpers`;
# this file collects them, renders the `h` help print from that single source, and
# runs it on shell entry. Adding a helper anywhere therefore documents it in `h`
# by construction — the list can't drift out of sync with what's on PATH.
let
  inherit (pkgs) lib;

  terminal = import ./terminal.nix { inherit pkgs; };
  languages = import ./languages.nix { inherit pkgs; };
  infra = import ./infra.nix { inherit pkgs; };
  lefthookShell = import ./lefthook.nix { inherit pkgs lefthook; };

  ownedShells = [
    terminal
    languages
    infra
  ];

  helpers = lib.concatMap (s: s.helpers or [ ]) ownedShells ++ [
    {
      name = "h";
      doc = "show this help";
    }
  ];

  helpLine = h: "${lib.escapeShellArg (h.usage or h.name)} ${lib.escapeShellArg h.doc}";
  h = pkgs.writeShellScriptBin "h" ''
    printf '%-20s %s\n' \
    ${lib.concatMapStringsSep " \\\n" helpLine helpers}
  '';
in
pkgs.mkShell {
  packages = [ h ];
  inputsFrom = ownedShells ++ [
    astGrepShell
    lefthookShell
  ];
  shellHook = "h";
  # Exposed for `checks.unit-tests` (lib/tests-unit.nix) to assert the registry.
  passthru.helpers = helpers;
}
