{ mkSystemBuild }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.terminal;
  build = mkSystemBuild pkgs.stdenv.hostPlatform.system;
in
{
  options.programs.terminal = {
    enable = lib.mkEnableOption "terminal configuration";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The terminal package to use. Automatically set based on configPath.";
    };

    configPath = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to terminal config directory. If null, uses bundled config.";
      example = "\${config.home.homeDirectory}/terminal/config";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.terminal.package = lib.mkDefault (
      if cfg.configPath != null then
        build.mkTerminal { configPath = cfg.configPath; }
      else
        build.mkTerminal { }
    );
    home.packages = [ cfg.package ];
  };
}
