{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.terminal;
in
{
  options.programs.terminal = {
    enable = lib.mkEnableOption "terminal configuration";

    package = lib.mkOption {
      type = lib.types.package;
      default = null;
      description = "The terminal package to use. Set automatically based on configPath.";
    };

    configPath = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to terminal config directory. If null, uses bundled config.";
      example = "\${config.home.homeDirectory}/terminal/config";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
  };
}
