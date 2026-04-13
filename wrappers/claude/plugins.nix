{ pkgs }:

let
  firefoxMcpPkg = import ../../packages/custom/firefox-mcp.nix { inherit pkgs; };
  mobileMcpPkg = import ../../packages/custom/mobile-mcp.nix { inherit pkgs; };

  mkMcpPlugin =
    name: description: server:
    pkgs.runCommand "${name}-plugin" { } ''
      mkdir -p $out/.claude-plugin
      cat > $out/.claude-plugin/plugin.json <<MANIFEST
      {
        "name": "${name}",
        "description": "${description}",
        "version": "1.0.0"
      }
      MANIFEST
      cat > $out/.mcp.json <<MCP
      {
        "mcpServers": {
          "${name}": ${builtins.toJSON server}
        }
      }
      MCP
    '';

  firefoxMcp = mkMcpPlugin "firefox-mcp" "Firefox DevTools MCP server" {
    command = "${firefoxMcpPkg}/bin/firefox-devtools-mcp";
    args = [ "--connect-existing" ];
  };

  firefoxMcpHeadless = mkMcpPlugin "firefox-mcp-headless" "Headless Firefox MCP server" {
    command = "${firefoxMcpPkg}/bin/firefox-devtools-mcp";
    args = [
      "--headless"
      "--firefox-path"
      "${pkgs.firefox-devedition}/bin/firefox-devedition"
    ];
  };

  mobileMcp = mkMcpPlugin "mobile-mcp" "Mobile device MCP server" {
    command = "${mobileMcpPkg}/bin/mcp-server-mobile";
  };

  nixMcp = mkMcpPlugin "nix-mcp" "NixOS MCP server" {
    command = "${pkgs.mcp-nixos}/bin/mcp-nixos";
  };

  nixLsp = pkgs.runCommand "nix-lsp-plugin" { } ''
    mkdir -p $out/.claude-plugin
    cat > $out/.claude-plugin/plugin.json <<MANIFEST
    {
      "name": "nix-lsp",
      "description": "Nix language server for enhanced code intelligence",
      "version": "1.0.0"
    }
    MANIFEST
    cat > $out/.lsp.json <<LSP
    {
      "nix": {
        "command": "${pkgs.nil}/bin/nil",
        "extensionToLanguage": {
          ".nix": "nix"
        }
      }
    }
    LSP
  '';

  typescriptLsp = pkgs.runCommand "typescript-lsp-plugin" { } ''
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
in
pkgs.runCommand "claude-plugins" { } ''
  mkdir -p $out
  ln -s ${firefoxMcp} $out/firefox-mcp
  ln -s ${firefoxMcpHeadless} $out/firefox-mcp-headless
  ln -s ${mobileMcp} $out/mobile-mcp
  ln -s ${nixMcp} $out/nix-mcp
  ln -s ${nixLsp} $out/nix-lsp
  ln -s ${typescriptLsp} $out/typescript-lsp
''
