{
  pkgs,
  files,
}:

let
  plugins = import ./plugins.nix { inherit pkgs; };

  formatters = with pkgs; [
    nixfmt
    shfmt
    go
    taplo
  ];
in
pkgs.symlinkJoin {
  name = "claude-with-config";
  paths = [ pkgs.claude-code ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    mkdir -p $out/hooks

    ${files.sync "claude/rules" "rules"}
    ${files.sync "claude/settings.json" "settings.json"}
    ${files.sync "claude/statusline.sh" "statusline.sh"}
    ${files.sync "claude/hooks/format.sh" "hooks/format.sh"}

    ln -s ${plugins} $out/plugins

    wrapProgram $out/bin/claude \
      --set NIX_OUT_CLAUDE "$out" \
      --prefix PATH : "${pkgs.lib.makeBinPath formatters}" \
      --run '${files.runtimeLink "claude" [ "settings.json" ]}' \
      --unset TMUX
  '';
}
