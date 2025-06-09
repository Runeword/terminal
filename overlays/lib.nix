{ rootStr, self }:

final: prev: {
  lib = prev.lib // {
    mkLink = sourceStr: targetStr: ''
      mkdir -p $(dirname $out/${prev.lib.escapeShellArg targetStr})
      ln -sf ${prev.lib.escapeShellArg (rootStr + "/" + sourceStr)} $out/${prev.lib.escapeShellArg targetStr}
    '';

    mkCopy = sourcePath: targetStr: ''
      mkdir -p $(dirname $out/${prev.lib.escapeShellArg targetStr})
      cp -r ${prev.lib.escapeShellArg (prev.lib.cleanSource sourcePath)} $out/${prev.lib.escapeShellArg targetStr}
    '';

    # mkFile =
    #   rootPath: source: target:
    #   if builtins.hasAttr "rev" self then
    #     final.lib.mkCopy (rootPath + source) target
    #   else
    #     final.lib.mkLink source target;
  };
}
