{ pkgs, files }:

let
  firefoxMcp = import ../packages/custom/firefox-mcp.nix { inherit pkgs; };
in
pkgs.symlinkJoin {
  name = "claude-with-config";
  paths = [ pkgs.claude-code ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${files.sync "claude" ".claude"}

    wrapProgram $out/bin/claude \
      --set CLAUDE_CONFIG_DIR "$out/.claude" \
      --prefix PATH : ${pkgs.lib.makeBinPath [ firefoxMcp ]}
  '';
}
