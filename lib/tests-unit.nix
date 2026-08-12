# Pure-eval invariants for the terminal flake's wrappers.
#
# Each attribute is `{ expr = ...; expected = ...; }` and is consumed by
# `pkgs.lib.runTests`, surfaced as `checks.<system>.unit-tests`. Only
# attributes whose names start with `test` are picked up.
{
  lib,
  wrappers,
  terminal,
  devShellHelpers,
}:
{
  testAllWrappersHaveSmoke = {
    expr = lib.all (w: w ? passthru.tests.smoke) (lib.attrValues wrappers);
    expected = true;
  };
  # alacritty is built via mkTerminal, not part of the wrappers attrset, so the
  # invariant above can't see it — assert its smoke test separately.
  testTerminalHasSmoke = {
    expr = terminal ? passthru.tests.smoke;
    expected = true;
  };
  # The `h` help print (devshells/default.nix) is generated from every owned
  # sub-shell's helper registry. Two structural guards on that assembly:
  # no command is documented twice, and a helper defined in a sub-shell other
  # than where `h` is rendered (infra.nix) is actually picked up — i.e. the
  # anti-drift mechanism works across files.
  testDevShellHelperNamesUnique = {
    expr =
      let
        names = map (helper: helper.name) devShellHelpers;
      in
      lib.length names == lib.length (lib.unique names);
    expected = true;
  };
  testDevShellDocumentsInfra = {
    expr = lib.any (helper: helper.name == "infra") devShellHelpers;
    expected = true;
  };
}
