{ pkgs, rootPath }:

{
  # Build a derivation containing the listed entries as symlinks under their
  # target paths. Each entry is { source, target }:
  #   source - path relative to rootPath, OR an absolute path string for
  #            external sources (e.g. "${pkgs.tmuxPlugins.resurrect}/share/...")
  #   target - path under $out (e.g. ".config/zsh")
  #
  # rootPath may be a Nix path (bundled mode - sub-paths interpolate as proper
  # store references so the source propagates into downstream closures) or a
  # plain string (dev mode - symlinks point at the live filesystem; --impure
  # required).
  #
  # Nix path literals (e.g. ./foo) are rejected: `toString` of a path produces
  # an absolute string, which would silently bypass the dev-mode rootPath swap.
  mkConfig =
    name: entries:
    pkgs.linkFarm name (
      map (entry: {
        name = entry.target;
        path =
          if builtins.isPath entry.source then
            throw "mkConfig: `source` must be a string, not a Nix path (target=${entry.target})"
          else if pkgs.lib.hasPrefix "/" entry.source then
            entry.source
          else if builtins.isPath rootPath then
            rootPath + "/${entry.source}"
          else
            "${rootPath}/${entry.source}";
      }) entries
    );
}
