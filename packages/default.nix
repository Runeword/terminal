{
  pkgs,
  # github:Runeword/claude's packages for this system.
  claudePackages,
}:
import ./commons.nix { inherit pkgs; }
++ import ./custom.nix { inherit pkgs; }
# github:Runeword/claude's claude-sessions, which lists, previews and erases
# Claude Code sessions (Claude Code can't delete one), and backs up the open
# ones. Backs the session pickers behind the cs and cx leader aliases, and the
# backup and its restore behind css and csr
# (sources/.config/shell/functions/claude.bash). Here so it lands in
# packages.tools and is on the interactive PATH inside the terminal, where those
# functions and their fzf previews invoke it by bare name. The claude wrapper
# carries the same build on claude's PATH, for its SessionStart hook.
++ [ claudePackages.claude-sessions ]
++ (
  if pkgs.stdenv.hostPlatform.isDarwin then
    import ./darwin.nix { inherit pkgs; }
  else
    import ./linux.nix { inherit pkgs; }
)
