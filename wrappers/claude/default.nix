{
  pkgs,
  files,
}:

let
  plugins = import ./plugins.nix { inherit pkgs; };
  claudeStatusline = import ../../packages/custom/claude-statusline { inherit pkgs; };

  tools = [
    claudeStatusline
    pkgs.nixfmt
    pkgs.shfmt
    pkgs.go
    pkgs.taplo
  ];
in
pkgs.symlinkJoin {
  name = "claude-with-config";
  paths = [ pkgs.claude-code ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    ${files.sync "claude/rules" "rules"}
    ${files.sync "claude/settings.json" "settings.json"}
    ${files.sync "claude/hooks/format.sh" "bin/claude-format"}

    ln -s ${plugins} $out/plugins

    wrapProgram $out/bin/claude \
      --set NIX_OUT_CLAUDE "$out" \
      --prefix PATH : "$out/bin:${pkgs.lib.makeBinPath tools}" \
      --add-flags "--settings $out/settings.json --setting-sources project,local" \
      --unset TMUX
  '';
}
