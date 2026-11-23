# The claude wrapper, from github:Runeword/claude (its wrapper.nix, with its
# config, sources/.claude, bundled). Built here with this terminal's git behind
# the git shim, so claude's git commands load the bundled git config as the
# shell's do, and with this repository's lefthook hooks, whose formatters
# claude-format then finds on claude's PATH in a session started outside the
# dev shell. Its smoke test is the claude flake's own, run on this build; the
# sandbox test dry-runs the claude-sandbox launchers the terminal ships
# (packages/default.nix) against this tree, which is what they bind and pin on
# the host.
{
  pkgs,
  permeance,
  git,
  # github:Runeword/claude's wrapper builder.
  mkClaude,
  # github:Runeword/claude-sandbox's packages for this system.
  claudeSandbox,
}:

let
  claude = mkClaude {
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit git;
    lefthookHooks = import ../devshells/lefthook-hooks.nix;
  };
  # Stand-in bwrap for the sandbox launcher's dry run: prints the argv it was
  # handed, one per line, and saves the environment it inherited to $BWRAP_ENV.
  fakeBwrap = pkgs.writeShellScript "bwrap" ''
    printf '%s\n' "$@"
    env >"$BWRAP_ENV"
  '';
  # Stand-in `pass` for the launcher dry runs: only claude's own entries decrypt,
  # so a launcher that read the alias's JIRA_API_TOKEN entry would hand over
  # nothing.
  fakePass = pkgs.writeShellScript "pass" ''
    case "$*" in
      "show claude/jira-token") echo fake-jira-token ;;
      "show claude/firebase-sa-key") echo '{"private_key": "fake-sa-key", "client_email": "sa@fake"}' ;;
    esac
  '';
  # Stand-in `claude` for the macOS launcher's dry run: saves the argv and
  # environment it was handed to $CLAUDE_OUT, with the key it can read and the
  # configstore firebase-tools would use (XDG_CONFIG_HOME, else ~/.config).
  fakeClaude = pkgs.writeShellScript "claude" ''
    printf '%s\n' "$@" >"$CLAUDE_OUT/argv"
    env >"$CLAUDE_OUT/env"
    cat "$GOOGLE_APPLICATION_CREDENTIALS" >"$CLAUDE_OUT/key"
    ls -A "''${XDG_CONFIG_HOME:-$HOME/.config}/configstore" >"$CLAUDE_OUT/configstore"
  '';
in
claude.overrideAttrs (prev: {
  passthru = prev.passthru // {
    tests = prev.passthru.tests // {
      sandbox = permeance.tests.mkSmoke {
        name = "claude-sandbox";
        description = "The sandbox launcher pins the host-executed config this tree's .claude/sandbox-pins names and exports the jira token behind a network filter, and the macOS launcher hands over the jira token and firebase key";
        script =
          # The bubblewrap launcher is Linux-only (macOS uses Claude Code's
          # built-in Seatbelt), and its claude-seccomp-bpf helper cgo-links
          # libseccomp, which does not evaluate on aarch64-darwin. Gate its dry
          # run to Linux; the macOS launcher's below runs on every platform.
          pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            # The bubblewrap launcher cannot run for real here (no user namespaces
            # in the build sandbox), but its policy is an argv. Run it against a
            # writable copy of the sources tree with a stand-in `bwrap` that prints
            # the arguments it was handed, and assert that the host-executed config
            # sources/.claude/sandbox-pins names comes out pinned read-only, with
            # each parent bound first as an anchor (a directory that merely
            # contains a pin can be renamed from under it).
            tree="$TMPDIR/tree"
            cp -r ${../sources} "$tree"
            chmod -R u+w "$tree"
            repo="$TMPDIR/repo"
            mkdir -p "$repo/.git" "$repo/.claude/skills" "$TMPDIR/fakebin"
            : > "$repo/.git/config"
            : > "$repo/.claude/settings.local.json"
            ln -s ${fakeBwrap} "$TMPDIR/fakebin/bwrap"
            # The same run opts into jira, with a fake pass and the session's config.
            ln -s ${fakePass} "$TMPDIR/fakebin/pass"
            mkdir -p "$HOME/.config/.jira"
            : > "$HOME/.config/.jira/claude.yml"
            argv="$TMPDIR/bwrap-argv"
            if ! (
              cd "$repo" \
                && PATH="$TMPDIR/fakebin:${claudeSandbox.default}/bin:$PATH" \
                  PERMEANCE_TREE="$tree" \
                  CLAUDE_SANDBOX_ALLOW_JIRA=1 \
                  BWRAP_ENV="$TMPDIR/bwrap-env" \
                  claude-sandbox claude --version \
                  > "$argv" 2> "$TMPDIR/launcher.err"
            ); then
              fail "launcher did not reach bwrap: $(cat "$TMPDIR/launcher.err")"
            fi
            # One argument per line; fold each bind into "op src dst" so a pin is
            # one greppable line, and its line number is its position in the order
            # bwrap applies mounts.
            awk '$0 == "--bind" || $0 == "--ro-bind" { op = $0; getline s; getline d; print op, s, d }' \
              "$argv" > "$TMPDIR/mounts"
            at() { grep -n -Fx -- "$1" "$TMPDIR/mounts" | head -1 | cut -d: -f1 || true; }
            pinned() {
              if [ -n "$(at "--ro-bind $1 $1")" ]; then
                ok "pinned read-only: $1"
              else
                fail "not pinned read-only: $1"
              fi
            }
            writable() {
              if [ -z "$(at "--ro-bind $1 $1")" ]; then
                ok "left writable: $1"
              else
                fail "pinned, but must stay writable: $1"
              fi
            }
            # $1 is the anchor directory, $2 a pin beneath it: the anchor must be
            # bound read-write onto itself before the pin.
            anchored() {
              a=$(at "--bind $1 $1")
              p=$(at "--ro-bind $2 $2")
              if [ -n "$a" ] && [ -n "$p" ] && [ "$a" -lt "$p" ]; then
                ok "anchored before its pin: $1"
              else
                fail "anchor missing or bound after its pin: $1 (pin $2)"
              fi
            }
            for p in .claude .config/zsh .config/bash .config/shell/xdg.sh \
              .config/shell/variables.sh .config/shell/aliases.sh .config/shell/functions \
              .config/shell/leader.conf .config/git .config/delta .config/direnv; do
              pinned "$tree/$p"
            done
            anchored "$tree" "$tree/.claude"
            anchored "$tree/.config" "$tree/.config/zsh"
            anchored "$tree/.config/shell" "$tree/.config/shell/functions"
            anchored "$repo/.git" "$repo/.git/hooks"
            anchored "$repo/.git" "$repo/.git/config"
            anchored "$repo/.claude" "$repo/.claude/skills"
            writable "$repo/.claude/settings.local.json"
            writable "$tree/.config/shell/scripts"
            writable "$tree/.config/tmux"
            if grep -q 'absent, so not locked' "$TMPDIR/launcher.err"; then
              fail "a pin target is missing from the tree: $(grep 'absent, so not locked' "$TMPDIR/launcher.err")"
            else
              ok "every pin target present in the tree"
            fi
            # CLAUDE_SANDBOX_ALLOW_JIRA=1: the token comes from claude's own pass
            # entry (fakePass decrypts only claude's), reaches bwrap through its
            # environment, never its argv (readable through /proc), and
            # JIRA_CONFIG_FILE points jira-cli at the session's own config.
            if grep -qx 'JIRA_API_TOKEN=fake-jira-token' "$TMPDIR/bwrap-env" \
              && ! grep -q fake-jira-token "$argv" \
              && grep -A1 -x JIRA_CONFIG_FILE "$argv" | grep -qx "$HOME/.config/.jira/claude.yml"; then
              ok "jira token from its own pass entry, exported to bwrap, not in its argv"
            else
              fail "jira token not handed over through the environment: $(grep ALLOW_JIRA "$TMPDIR/launcher.err")"
            fi
            # A credential session gets no network of its own: bwrap unshares it,
            # the proxy variables point at the in-namespace bridge, and claude runs
            # behind that bridge (the launcher refuses to start if the host-side
            # filter didn't).
            if grep -qx -- --unshare-net "$argv" \
              && grep -A1 -x HTTPS_PROXY "$argv" | grep -qx http://127.0.0.1:3128 \
              && sed -n '/^--$/{n;p;q}' "$argv" | grep -qx claude-egress-proxy; then
              ok "credential session: network unshared, egress through the filter"
            else
              fail "credential session network not filtered: $(grep -i network "$TMPDIR/launcher.err")"
            fi
          ''
          # The macOS launcher is plain bash, so its dry run works on every platform.
          + ''
            # claude-macos.bash for jira + firebase, with a personal `firebase login`
            # planted in ~/.config/configstore: claude gets the jira token and the SA
            # key (not in its argv, which `ps` shows), and firebase-tools a
            # configstore without that login. Output goes to files: the launcher
            # leaves a watcher behind, which must not hold the build log open.
            mac="$TMPDIR/mac"
            mkdir -p "$mac/bin" "$mac/out" "$HOME/.config/configstore" "$HOME/.config/.jira"
            : > "$HOME/.config/.jira/claude.yml"
            echo '{"user": "personal"}' > "$HOME/.config/configstore/firebase-tools.json"
            ln -s ${fakePass} "$mac/bin/pass"
            ln -s ${fakeClaude} "$mac/bin/claude"
            PATH="$mac/bin:$PATH" TMPDIR="$mac" CLAUDE_OUT="$mac/out" \
              CLAUDE_SANDBOX_ALLOW_JIRA=1 CLAUDE_SANDBOX_ALLOW_FIREBASE=1 \
              ${claudeSandbox.claude-macos}/bin/claude-macos claude --version \
              > "$mac/stdout" 2> "$mac/err" || true
            if grep -qx 'JIRA_API_TOKEN=fake-jira-token' "$mac/out/env" \
              && grep -qx "JIRA_CONFIG_FILE=$HOME/.config/.jira/claude.yml" "$mac/out/env" \
              && grep -q fake-sa-key "$mac/out/key" \
              && ! grep -q fake-sa-key "$mac/out/argv" \
              && [ "$(head -1 "$mac/out/argv")" = --add-dir ] \
              && [ -f "$mac/out/configstore" ] && [ ! -s "$mac/out/configstore" ]; then
              ok "macOS launcher hands claude the jira token and SA key, not the firebase login"
            else
              fail "macOS launcher did not hand over the credentials: $(cat "$mac/err")"
            fi
          '';
      };
    };
  };
})
