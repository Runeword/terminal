{ pkgs }:
{
  imports ? [ ],
  extraArgs ? { },
  shellHook ? "",
  ...
}@args:
let
  allArgs = {
    inherit pkgs;
  }
  // extraArgs;

  importFile =
    path:
    let
      fn = import path;
      accepted = builtins.functionArgs fn;
    in
    fn (builtins.intersectAttrs accepted allArgs);

  resolveImport =
    entry:
    if builtins.isAttrs entry then
      [ entry ]
    else
      let
        type = builtins.readFileType entry;
      in
      if type == "directory" then
        let
          entries = builtins.readDir entry;
          nixFiles = builtins.filter (name: builtins.match ".*\\.nix" name != null) (
            builtins.attrNames entries
          );
        in
        map (name: importFile (entry + "/${name}")) nixFiles
      else
        [ (importFile entry) ];

  extraShells = builtins.concatMap resolveImport imports;

  extraHooks = builtins.concatStringsSep "\n" (
    builtins.filter (h: h != "") (map (s: s.shellHook or "") extraShells)
  );

  mkShellArgs = builtins.removeAttrs args [
    "imports"
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
