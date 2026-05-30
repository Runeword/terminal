{ flake }:
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
      description = "The terminal package to use.";
    };

    configPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to a live working-tree of the terminal's sources/ directory.
        When set, the alacritty binary is wrapped to set $PERMEANCE_ROOT
        as a default (via --set-default semantics — pre-existing values
        in the env still win), and the same value is exported into the
        home-manager session for shell-launched tools. This means
        graphical launches (WM keybindings, .desktop entries, systemd
        user units) and shell launches all see PERMEANCE_ROOT without
        depending on session-env propagation. The path is resolved at
        runtime, so it does not need to exist at module evaluation time
        and is compatible with pure-eval mode.
      '';
      example = "\${config.home.homeDirectory}/terminal/sources";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.terminal.package = lib.mkDefault (
      let
        bareTerminal = flake.lib.mkTerminal {
          inherit (pkgs.stdenv.hostPlatform) system;
        };
      in
      # When configPath is null, the bare flake terminal is enough — it falls
      # back to its bundled $out at exec time. When configPath is set, wrap
      # the alacritty binary with --set-default PERMEANCE_ROOT so WM-launched
      # alacritty (which doesn't inherit home.sessionVariables) still picks
      # up the live working tree. --set-default preserves runtime overrides:
      # `PERMEANCE_ROOT=/other/path alacritty` still wins.
      if cfg.configPath == null then
        bareTerminal
      else
        pkgs.symlinkJoin {
          name = "${bareTerminal.name}-permeance-bound";
          paths = [ bareTerminal ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            wrapProgram $out/bin/alacritty \
              --set-default PERMEANCE_ROOT ${lib.escapeShellArg cfg.configPath}
          '';
        }
    );
    home.sessionVariables = lib.mkIf (cfg.configPath != null) {
      PERMEANCE_ROOT = cfg.configPath;
    };
    home.packages = [ cfg.package ];
  };
}
