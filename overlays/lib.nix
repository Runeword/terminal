{ configPath, defaultConfigRoot }:

final: prev:
let
  useLink = configPath != null;
  configRoot = if configPath != null then configPath else defaultConfigRoot;
in
{
  lib = prev.lib // {
    mkLink = sourceStr: targetStr: ''
      mkdir -p $(dirname $out/${prev.lib.escapeShellArg targetStr})
      ln -sf ${
        prev.lib.escapeShellArg (configRoot + "/" + sourceStr)
      } $out/${prev.lib.escapeShellArg targetStr}
    '';

    mkCopy = sourcePath: targetStr: ''
      mkdir -p $(dirname $out/${prev.lib.escapeShellArg targetStr})
      cp -r ${prev.lib.escapeShellArg (prev.lib.cleanSource sourcePath)} $out/${prev.lib.escapeShellArg targetStr}
    '';

    mkConfig =
      path: target:
      if useLink then final.lib.mkLink path target else final.lib.mkCopy "${configRoot}/${path}" target;
  };
}
