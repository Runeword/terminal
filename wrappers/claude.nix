{ pkgs, files }:

let
  firefoxMcp = import ../packages/custom/firefox-mcp.nix { inherit pkgs; };
in
pkgs.symlinkJoin {
  name = "claude-with-config";
  paths = [ pkgs.claude-code ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${files.sync "claude/rules" ".claude/rules"}
    ${files.sync "claude/hooks" ".claude/hooks"}
    ${files.sync "claude/settings.json" ".claude/settings.json"}

    wrapProgram $out/bin/claude \
      --set __CLAUDE_NIX "$out/.claude" \
      --run '
        cfg="''${CLAUDE_CONFIG_DIR:-''${XDG_CONFIG_HOME:-$HOME/.config}/claude}"
        mkdir -p "$cfg"
        ln -sfn "$__CLAUDE_NIX/rules" "$cfg/rules"
        ln -sf "$__CLAUDE_NIX/settings.json" "$cfg/settings.json"
        export CLAUDE_CONFIG_DIR="$cfg"
      ' \
      --unset TMUX \
      --prefix PATH : ${pkgs.lib.makeBinPath [ firefoxMcp ]}
  '';
}
