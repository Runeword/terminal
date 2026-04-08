{
  pkgs,
  files,
  lefthook,
}:

let
  firefoxMcp = import ../packages/custom/firefox-mcp.nix { inherit pkgs; };

  firefoxMcpPlugin = pkgs.runCommand "firefox-mcp-plugin" { } ''
    mkdir -p $out/.claude-plugin
    cat > $out/.claude-plugin/plugin.json <<MANIFEST
    {
      "name": "firefox-mcp",
      "description": "Firefox DevTools MCP server",
      "version": "${firefoxMcp.version}"
    }
    MANIFEST
    cat > $out/.mcp.json <<MCP
    {
      "mcpServers": {
        "firefox-devtools": {
          "command": "${firefoxMcp}/bin/firefox-devtools-mcp",
          "args": ["--headless"]
        }
      }
    }
    MCP
  '';

  formatHook = pkgs.writeScript "format.sh" ''
    #!/bin/sh
    file=$(jq -r '.tool_input.file_path')
    [ -f "$file" ] || exit 0
    case "$file" in
      *.go) sh ${lefthook}/scripts/format-go.sh "$file" ;;
      *.lua) sh ${lefthook}/scripts/format-lua.sh "$file" ;;
      *.nix) sh ${lefthook}/scripts/format-nix.sh "$file" ;;
      *.sh) sh ${lefthook}/scripts/format-shell.sh "$file" ;;
      *.toml) sh ${lefthook}/scripts/format-toml.sh "$file" ;;
      *.yml | *.yaml) sh ${lefthook}/scripts/format-yaml.sh "$file" ;;
    esac
  '';
in
pkgs.symlinkJoin {
  name = "claude-with-config";
  paths = [ pkgs.claude-code ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${files.sync "claude/rules" ".claude/rules"}
    ${files.sync "claude/settings.json" ".claude/settings.json"}

    mkdir -p $out/.claude/hooks
    cp ${formatHook} $out/.claude/hooks/format.sh

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
      --append-flags '--plugin-dir ${firefoxMcpPlugin}'
  '';
}
