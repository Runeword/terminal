{ pkgs }:
{
  devshellsDir,
  extraArgs ? { },
  shellHook ? "",
  ...
}@args:
let
  extraShells =
    if builtins.pathExists devshellsDir then
      let
        entries = builtins.readDir devshellsDir;
        nixFiles = builtins.filter (name: builtins.match ".*\\.nix" name != null) (
          builtins.attrNames entries
        );
      in
      map (
        name:
        let
          fn = import (devshellsDir + "/${name}");
          accepted = builtins.functionArgs fn;
          allArgs = {
            inherit pkgs;
          }
          // extraArgs;
        in
        fn (builtins.intersectAttrs accepted allArgs)
      ) nixFiles
    else
      [ ];

  extraHooks = builtins.concatStringsSep "\n" (
    builtins.filter (h: h != "") (map (s: s.shellHook or "") extraShells)
  );

  mkShellArgs = builtins.removeAttrs args [
    "devshellsDir"
    "extraArgs"
    "shellHook"
  ];
in
pkgs.mkShell (
  mkShellArgs
  // {
    inputsFrom = (mkShellArgs.inputsFrom or [ ]) ++ extraShells;
    shellHook = ''
      ${shellHook}
      ${extraHooks}
    '';
  }
)
