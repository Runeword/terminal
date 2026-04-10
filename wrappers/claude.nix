{
  pkgs,
  files,
  lefthook,
}:

let
  firefoxMcp = import ../packages/custom/firefox-mcp.nix { inherit pkgs; };
  mobileMcp = import ../packages/custom/mobile-mcp.nix { inherit pkgs; };

  mcpPlugin = pkgs.runCommand "mcp-plugin" { } ''
    mkdir -p $out/.claude-plugin
    cat > $out/.claude-plugin/plugin.json <<MANIFEST
    {
      "name": "mcp-servers",
      "description": "MCP servers",
      "version": "1.0.0"
    }
    MANIFEST
    cat > $out/.mcp.json <<MCP
    {
      "mcpServers": {
        "firefox-devtools": {
          "command": "${firefoxMcp}/bin/firefox-devtools-mcp",
          "args": ["--connect-existing"]
        },
        "firefox-headless": {
          "command": "${firefoxMcp}/bin/firefox-devtools-mcp",
          "args": ["--headless", "--firefox-path", "${pkgs.firefox-devedition}/bin/firefox-devedition"]
        },
        "mobile": {
          "command": "${mobileMcp}/bin/mcp-server-mobile",
          "args": []
        },
        "nixos": {
          "command": "${pkgs.mcp-nixos}/bin/mcp-nixos",
          "args": []
        }
      }
    }
    MCP
  '';

  typescriptLspPlugin = pkgs.runCommand "typescript-lsp-plugin" { } ''
    mkdir -p $out/.claude-plugin
    cat > $out/.claude-plugin/plugin.json <<MANIFEST
    {
      "name": "typescript-lsp",
      "description": "TypeScript/JavaScript language server for enhanced code intelligence",
      "version": "1.0.0"
    }
    MANIFEST
    cat > $out/.lsp.json <<LSP
    {
      "typescript": {
        "command": "${pkgs.typescript-language-server}/bin/typescript-language-server",
        "args": ["--stdio"],
        "extensionToLanguage": {
          ".ts": "typescript",
          ".tsx": "typescriptreact",
          ".js": "javascript",
          ".jsx": "javascriptreact",
          ".mts": "typescript",
          ".cts": "typescript",
          ".mjs": "javascript",
          ".cjs": "javascript"
        }
      }
    }
    LSP
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

    ln -s ${mcpPlugin} $out/.claude/plugins/mcp
    ln -s ${typescriptLspPlugin} $out/.claude/plugins/lsp

    wrapProgram $out/bin/claude \
      --set __CLAUDE_NIX "$out/.claude" \
      --run '
        cfg="''${CLAUDE_CONFIG_DIR:-''${XDG_CONFIG_HOME:-$HOME/.config}/claude}"
        mkdir -p "$cfg"
        ln -sfn "$__CLAUDE_NIX/rules" "$cfg/rules"
        ln -sf "$__CLAUDE_NIX/settings.json" "$cfg/settings.json"
        export CLAUDE_CONFIG_DIR="$cfg"
      ' \
      --unset TMUX
  '';
}
