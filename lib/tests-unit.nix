# Pure-eval invariants for the terminal flake's wrappers.
#
# Each attribute is `{ expr = ...; expected = ...; }` and is consumed by
# `pkgs.lib.runTests`, surfaced as `checks.<system>.unit-tests`. Only
# attributes whose names start with `test` are picked up.
{
  lib,
  wrappers,
}:
{
  testAllWrappersHaveSmoke = {
    expr = lib.all (w: w ? passthru.tests.smoke) (lib.attrValues wrappers);
    expected = true;
  };
}
