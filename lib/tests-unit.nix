# Pure-eval invariants for the terminal flake's wrappers.
#
# Each attribute is `{ expr = ...; expected = ...; }` and is consumed by
# `pkgs.lib.runTests`, surfaced as `checks.<system>.unit-tests`. Only
# attributes whose names start with `test` are picked up.
{
  lib,
  wrappers,
  terminal,
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
}
