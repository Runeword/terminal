{ pkgs, ast-grep-skill }:
pkgs.mkShell {
  shellHook = ''
    mkdir -p .claude/skills
    ln -sfn ${ast-grep-skill}/ast-grep/skills/ast-grep .claude/skills/ast-grep
  '';
}
