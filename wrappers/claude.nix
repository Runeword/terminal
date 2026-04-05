{ pkgs, files }:

let
  firefoxMcp = import ../packages/custom/firefox-mcp.nix { inherit pkgs; };
in
pkgs.symlinkJoin {
  name = "claude-with-config";
  paths = [ pkgs.claude-code ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${files.sync "claude/rules" ".claude-static/rules"}
    ${files.sync "claude/settings.json" ".claude-static/settings.json"}

    wrapProgram $out/bin/claude \
      --set __CLAUDE_STATIC "$out/.claude-static" \
      --run '
        _cfg="''${CLAUDE_CONFIG_DIR:-''${XDG_CONFIG_HOME:-$HOME/.config}/claude}"
        mkdir -p "$_cfg"
        ln -sfn "$__CLAUDE_STATIC/rules" "$_cfg/rules"
        ln -sf "$__CLAUDE_STATIC/settings.json" "$_cfg/settings.json"
        export CLAUDE_CONFIG_DIR="$_cfg"
        unset __CLAUDE_STATIC
      ' \
      --prefix PATH : ${pkgs.lib.makeBinPath [ firefoxMcp ]}
  '';
}
