# The read-only Explore agent, which the claude wrapper passes to every session
# with --agents (wrappers/claude.nix). It replaces Claude Code's built-in
# Explore, whose shell runs whatever the permission mode lets through, and it
# ships with its guard: its hook runs the guard of the same build by store path,
# so a claude never loads an agent that its own build doesn't enforce. An agent
# file loaded live from sources/ would change without a rebuild, apart from the
# guard it relies on.
{ guard }:

{
  description = "Fast read-only agent for exploring codebases. Use it to find files, search code and read git history without changing anything. Say how thorough to be (quick, medium or very thorough).";
  prompt = builtins.readFile ./prompt.md;
  tools = [
    "Read"
    "Bash"
    "LSP"
  ];
  model = "inherit";
  omitClaudeMd = true;
  hooks.PreToolUse = [
    {
      matcher = "Bash";
      hooks = [
        {
          type = "command";
          command = "${guard}/bin/claude-explore-guard";
          timeout = 5;
          onFailure = "block";
        }
      ];
    }
  ];
}
