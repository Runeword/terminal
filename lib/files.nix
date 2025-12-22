{ pkgs, rootPath }:

rec {
  link = sourceStr: targetStr: ''
    mkdir -p $(dirname $out/${pkgs.lib.escapeShellArg targetStr})
    ln -sf ${
      pkgs.lib.escapeShellArg (rootPath + "/" + sourceStr)
    } $out/${pkgs.lib.escapeShellArg targetStr}
  '';

  copy = sourcePath: targetStr: ''
    mkdir -p $(dirname $out/${pkgs.lib.escapeShellArg targetStr})
    cp -r ${pkgs.lib.escapeShellArg (pkgs.lib.cleanSource sourcePath)} $out/${pkgs.lib.escapeShellArg targetStr}
  '';

  sync =
    sourceStr: targetStr:
    if !pkgs.lib.hasPrefix "/nix/store" rootPath then
      link sourceStr targetStr
    else
      copy "${rootPath}/${sourceStr}" targetStr;
}
