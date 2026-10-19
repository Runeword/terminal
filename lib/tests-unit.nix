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
  # `dev` rebuilds when its bakedSources change (devshells/terminal.nix). One
  # that no longer exists, e.g. after a move, would stop triggering rebuilds
  # silently. Lists the missing ones.
  testDevBakedSourcesExist = {
    expr = lib.filter (path: !builtins.pathExists (../. + "/${path}")) (
      lib.concatMap (helper: helper.bakedSources or [ ]) devShellHelpers
    );
    expected = [ ];
  };
  # dev and bdl open the window outside direnv's environment (devshells/
  # terminal.nix): one that inherits it loses the build's tools on its first cd
  # out of the repo. Lists the ones that are missing or don't.
  testTerminalHelpersLeaveDirenv = {
    expr =
      let
        leavesDirenv =
          name:
          lib.any (
            helper: helper.name == name && lib.hasInfix "/bin/direnv exec / " helper.text
          ) devShellHelpers;
      in
      lib.filter (name: !leavesDirenv name) [
        "dev"
        "bdl"
      ];
    expected = [ ];
  };
  # infra/ manages no GitHub secret: OpenTofu writes a managed value to
  # terraform.tfstate in plaintext, and the state goes wherever infra/ is copied
  # (infra/README.md, "Actions & Dependabot secrets"). Lists the .tf files that
  # declare one.
  testInfraManagesNoSecrets = {
    expr =
      let
        declaresSecret =
          file:
          lib.any (
            line: builtins.match ''[[:space:]]*resource[[:space:]]+"github_[a-z_]*secret".*'' line != null
          ) (lib.splitString "\n" (builtins.readFile (../infra + "/${file}")));
      in
      lib.filter declaresSecret (
        lib.filter (lib.hasSuffix ".tf") (lib.attrNames (builtins.readDir ../infra))
      );
    expected = [ ];
  };
}
