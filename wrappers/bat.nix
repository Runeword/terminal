{
  pkgs,
  files,
  permeance,
  configPath,
}:

let
  inherit (pkgs) lib;

  config = files.mkConfig "bat-config" [ ".config/bat" ];

  # Theme names bat will expose are the *.tmTheme filename stems under themes/
  # (bat keys on the filename, not the <key>name</key> inside the file). Derive
  # them from the bundled tree so the smoke test guards every theme that ships
  # — dropping a new *.tmTheme needs no test edit.
  themesDir = configPath + "/.config/bat/themes";
  themeNames =
    if builtins.pathExists themesDir then
      map (lib.removeSuffix ".tmTheme") (
        builtins.filter (lib.hasSuffix ".tmTheme") (builtins.attrNames (builtins.readDir themesDir))
      )
    else
      [ ];

  # bat loads custom themes (the bundled sources/.config/bat/themes/*.tmTheme,
  # e.g. `monochrome`) only from its compiled binary cache, normally produced
  # by a manual, stateful `bat cache --build` into ~/.cache/bat. Build that
  # cache here, version-matched to this exact bat, so the theme resolves on
  # first use with no out-of-band step. Without it bat warns "Unknown theme
  # 'monochrome', using default" and silently falls back. Omitting --blank
  # appends the custom themes to bat's built-in set rather than replacing it;
  # the missing syntaxes/ dir just leaves the default syntax set in place.
  themeCache = pkgs.runCommand "bat-theme-cache" { nativeBuildInputs = [ pkgs.bat ]; } ''
    export HOME="$TMPDIR"
    mkdir -p "$out/.cache/bat"
    bat cache --build \
      --source ${config}/.config/bat \
      --target "$out/.cache/bat"
  '';

  self = pkgs.symlinkJoin {
    name = "bat-with-config";
    paths = [
      pkgs.bat
      config
      themeCache
    ];
    postBuild = permeance.installLauncher {
      binName = "bat";
      configEnv = {
        BAT_CONFIG_PATH = ".config/bat/config";
      };
      staticEnv = {
        # Point at the build-time cache above (@OUT@ is the wrapper's own out,
        # so this stays a fixed, version-matched store artifact in both bundled
        # and dev modes — theme edits take effect on rebuild, like any compiled
        # asset, while the config file itself still follows $PERMEANCE_ROOT).
        BAT_CACHE_PATH = "@OUT@/.cache/bat";
      };
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "bat";
      description = "Verify bat finds its bundled config and custom themes";
      script = ''
        bat_config=$(${self}/bin/bat --config-file 2>/dev/null)
        case "$bat_config" in
          ${self}/*)
            ok "bundled config file points to wrapper ($bat_config)" ;;
          *)
            fail "config file is '$bat_config', expected path under '${self}/'" ;;
        esac

        # Every bundled theme must resolve from the build-time cache without a
        # manual `bat cache --build`: assert each lists and renders cleanly.
        ${lib.concatMapStringsSep "\n" (name: ''
          if ${self}/bin/bat --list-themes 2>/dev/null | grep -qxF ${lib.escapeShellArg name}; then
            ok ${lib.escapeShellArg "theme '${name}' registered in build-time cache"}
          else
            fail ${lib.escapeShellArg "theme '${name}' missing from --list-themes (cache not built?)"}
          fi

          theme_err=$(printf 'x\n' | ${self}/bin/bat --plain --color=always --theme=${lib.escapeShellArg name} 2>&1 >/dev/null)
          case "$theme_err" in
            *"Unknown theme"*)
              fail ${lib.escapeShellArg "theme '${name}' fell back to default"}": $theme_err" ;;
            *)
              ok ${lib.escapeShellArg "theme '${name}' applied with no fallback warning"} ;;
          esac
        '') themeNames}
      '';
    };
  };
in
self
