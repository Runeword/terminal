# Pure-eval invariants for the terminal flake's wrappers.
#
# Each attribute is `{ expr = ...; expected = ...; }` and is consumed by
# `pkgs.lib.runTests`, surfaced as `checks.<system>.unit-tests`. Only
# attributes whose names start with `test` are picked up.
{
  lib,
  isLinux,
  wrappers,
  terminal,
  tools,
  claudeMicrovm,
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
  # claude-microvm's macOS claude-vm boots an aarch64-linux guest, which a Mac
  # builds only through a Linux builder, and GitHub's macOS runners can't run
  # one: outside Linux, the tools leave it out (packages/default.nix).
  testClaudeVmOnLinuxOnly = {
    expr = isLinux || !(lib.elem (claudeMicrovm.default or null) tools);
    expected = true;
  };
  # The `h` help print (devshells/default.nix) is generated from every owned
  # sub-shell's helper registry: no command is documented twice. That a helper
  # defined in another sub-shell is picked up at all, testTerminalHelpersLeaveDirenv
  # asserts below for terminal.nix's dev and bdl.
  testDevShellHelperNamesUnique = {
    expr =
      let
        names = map (helper: helper.name) devShellHelpers;
      in
      lib.length names == lib.length (lib.unique names);
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
}
