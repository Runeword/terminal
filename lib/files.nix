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
      normalize =
        entry:
        if builtins.isString entry then
          {
            source = entry;
            target = entry;
          }
        else if builtins.isAttrs entry then
          if builtins.hasAttr "source" entry && builtins.hasAttr "target" entry then
            entry
          else
            throw "mkConfig: each entry must be a string or { source, target } attrset; got attrset with fields [${toString (builtins.attrNames entry)}]"
        else
          throw "mkConfig: each entry must be a string or { source, target } attrset; got ${builtins.typeOf entry}";

      resolveSource =
        entry:
        if builtins.isPath entry.source then
          throw "mkConfig: `source` must be a string, not a Nix path (target=${entry.target})"
        else if pkgs.lib.hasPrefix "/" entry.source then
          entry.source
        else if builtins.isPath rootPath then
          rootPath + "/${entry.source}"
        else
          "${rootPath}/${entry.source}";
    in
    pkgs.linkFarm name (
      map (entry: {
        name = entry.target;
        path = resolveSource entry;
      }) (map normalize entries)
    );
}
