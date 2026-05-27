{ pkgs, rootPath }:

{
  # Build a derivation containing the listed entries as symlinks under their
  # target paths. Each entry is either:
  #   - a string "X" - shorthand for { source = "X"; target = "X"; }. The
  #     source tree under rootPath mirrors the target tree, so a single string
  #     names both (e.g. ".config/git/config" lives at sources/.config/git/config
  #     and lands at $out/.config/git/config).
  #   - an attrset { source, target } for entries where source and target
  #     differ — e.g. an absolute source (tmux-resurrect from nixpkgs) or a
  #     renamed target (claude hooks installed under bin/).
  #
  # In both forms:
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
    let
      resolvePath =
        source:
        # source is an absolute path
        if pkgs.lib.hasPrefix "/" source then
          source
        # rootPath is a Nix path literal (bundled mode)
        else if builtins.isPath rootPath then
          rootPath + "/${source}"
        # rootPath is a string (dev mode)
        else
          "${rootPath}/${source}";

      toLinkFarmEntry =
        rawEntry:
        if builtins.isString rawEntry then
          {
            name = rawEntry;
            path = resolvePath rawEntry;
          }
        else if
          rawEntry ? source
          && rawEntry ? target
          && builtins.isString rawEntry.source
          && builtins.isString rawEntry.target
        then
          {
            name = rawEntry.target;
            path = resolvePath rawEntry.source;
          }
        else
          throw "mkConfig: each entry must be a string or { source, target } attrset; got ${builtins.typeOf rawEntry}";
    in
    pkgs.linkFarm name (map toLinkFarmEntry entries);
}
