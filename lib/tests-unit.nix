# nix-unit-shaped invariants for the flake outputs.
#
# Each attribute is `{ expr = ...; expected = ...; }` per
# https://nix-community.github.io/nix-unit/. Run via `checks.<system>.nix-unit`
# (which invokes `nix-unit --flake .#tests.<system>`).
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
