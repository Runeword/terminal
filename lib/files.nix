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
  mkConfig =
    name: entries:
    pkgs.linkFarm name (
      map (e: {
        name = e.target;
        path =
          if pkgs.lib.hasPrefix "/" (toString e.source) then
            e.source
          else if builtins.isPath rootPath then
            rootPath + "/${e.source}"
          else
            "${rootPath}/${e.source}";
      }) entries
    );
}
