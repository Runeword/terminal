# Test-builder library.
#
# `tests.smoke` builds a `pkgs.runCommand` derivation that runs a small bash
# harness providing:
#   - `ok "<msg>"`   : record a passing assertion
#   - `fail "<msg>"` : record a failing assertion (continues; non-zero exit at end)
#   - $HOME pointing at a writable tmpdir (the Nix sandbox sets HOME=/homeless-shelter)
#
# Smoke tests run during `nix flake check`; they cannot reach the network and
# only see the wrapper's own /nix/store output (dev-mode symlinks to a working
# tree are unreachable in the sandbox).
{ pkgs }:
{
  smoke =
    {
      name,
      description,
      script,
    }:
    pkgs.runCommand "smoke-${name}"
      {
        meta.description = description;
      }
      ''
        failed=0
        fail() { echo "  FAIL: $1"; failed=1; }
        ok()   { echo "  OK: $1"; }

        # The Nix sandbox sets HOME=/homeless-shelter (unwritable). Tools that
        # touch XDG paths (zsh, bash, nvim, claude, …) need a writable HOME.
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"

        ${script}

        if [ "$failed" -ne 0 ]; then exit 1; fi
        touch $out
      '';
}
