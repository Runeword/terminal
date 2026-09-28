{
  pkgs,
  files,
  permeance,
  git,
}:

let
  claudeStatusline = import ../packages/claude/statusline { inherit pkgs; };
  claudeSessionStatus = import ../packages/claude/session-status { inherit pkgs; };
  claudeDocsGuard = import ../packages/claude/docs-guard { inherit pkgs; };
  claudeContext = import ../packages/claude/context { inherit pkgs; };
  gitAllowlistHook = import ../packages/git/allowlist-hook { inherit pkgs; };
  # Used only by the smoke test below, which dry-runs the sandbox launcher: it
  # fails closed without these on PATH. They reach the host PATH through
  # packages/custom.nix, never claude's own.
  claudeCwdGate = import ../packages/claude/cwd-gate { inherit pkgs; };
  claudeSeccompBpf = import ../packages/claude/seccomp-bpf { inherit pkgs; };
  claudeSshSanitize = import ../packages/claude/ssh-sanitize { inherit pkgs; };
  # Stand-in bwrap for that dry run: prints the argv it was handed, one per line.
  fakeBwrap = pkgs.writeShellScript "bwrap" ''
    printf '%s\n' "$@"
  '';
  # Point the shim at the wrapped git so config (excludesFile, pager, includes,
  # GIT_CONFIG_GLOBAL) applies whether git is invoked from claude or from the
  # interactive shell. The allowlist check still runs first on the same argv.
  gitShim = import ../packages/git/shim {
    inherit pkgs;
    realGit = "${git}/bin/git";
  };
  firefoxMcpPkg = import ../packages/firefox-mcp.nix { inherit pkgs; };

  tools = [
    claudeStatusline
    claudeSessionStatus
    claudeDocsGuard
    claudeContext
    gitAllowlistHook
    pkgs.nixfmt
    pkgs.shfmt
    pkgs.go
    pkgs.taplo
    pkgs.rtk
    pkgs.nil
    pkgs.typescript-language-server
    pkgs.gopls
    pkgs.bash-language-server
    pkgs.yaml-language-server
    pkgs.terraform-ls
    pkgs.marksman
    pkgs.vscode-langservers-extracted
    pkgs.shellcheck
    pkgs.firefox-devedition
    # firebase CLI on claude's PATH so sessions can run `firebase …`. Already in
    # packages/commons.nix for the interactive shell (usually inherited here too),
    # but listed explicitly so availability doesn't depend on the caller's PATH.
    # Auth is a scoped service account, not your personal `firebase login`:
    # CLAUDE_SANDBOX_ALLOW_FIREBASE=1 (leader alias `cf`, wired through claude.bash)
    # makes claude-sandbox.bash read the least-privilege SA key from `pass`
    # (entry firebase/sa-key) and mount it read-only as Application Default
    # Credentials for that session; ~/.config/configstore stays masked.
    pkgs.firebase-tools
    # Runtimes for MCP servers launched from a plugin .mcp.json rather than being
    # Nix-packaged: nodejs/npx for figma-mcp; uv/uvx + python for the pure-Python
    # servers (nix-mcp, aws-api-mcp, google-workspace-mcp). uvx fetches the pinned
    # server from PyPI at run time (cached under $CLAUDE_CONFIG_DIR); python312 with
    # UV_PYTHON_PREFERENCE=only-system avoids a managed-Python download and gives
    # broad wheel coverage. firefox-mcp stays Nix-packaged because it also needs
    # a sidecar binary on PATH (geckodriver).
    pkgs.nodejs
    pkgs.uv
    pkgs.python312
    firefoxMcpPkg
  ]
  # Deps for claude's built-in `/sandbox` on Linux (Seatbelt is built in on macOS).
  # Recent claude-code turns that sandbox ON by default when these sit on PATH; it
  # can't nest inside the bubblewrap jail (claude-sandbox.bash passes
  # --disable-userns), so sources/.claude/settings.linux.json switches it back off
  # at user scope. Kept on PATH so /sandbox (project-local scope, above user) can
  # still opt an unsandboxed (CLAUDE_SANDBOX=0) session back in.
  ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
    pkgs.bubblewrap
    pkgs.socat
  ];

  config = files.mkConfig "claude-config" [
    ".claude/rules"
    ".claude/plugins"
    ".claude/settings.json"
    ".claude/git-allowlist.toml"

    # Renamed and installed under bin/ so it's PATH-resolvable from
    # settings.json hooks (which invoke it as `claude-format`).
    {
      source = ".claude/hooks/format.sh";
      target = "bin/claude-format";
    }
  ];

  # claude's PATH, ahead of the inherited one (@OUT@ is the launcher's own $out).
  # gitShim ships a binary named `git`. It is injected only into claude's own
  # PATH (and inherited by its subprocesses: bash, Python, Make, …), not merged
  # into $out/bin, so the user's interactive shell still sees the wrapped git.
  # Prefixed first so it wins over git-with-config within claude's process
  # tree. The shim enforces the same allowlist policy as git-allowlist-hook,
  # then exec's the real git.
  pathPrefix = [
    "${gitShim}/bin"
    "@OUT@/bin"
    "${pkgs.lib.makeBinPath tools}"
  ];

  self = pkgs.symlinkJoin {
    name = "claude-with-config";
    paths = [
      pkgs.claude-code
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "claude";
      inherit pathPrefix;
      configEnv = {
        CLAUDE_GIT_ALLOWLIST_CONFIG = ".claude/git-allowlist.toml";
      };
      staticEnv = {
        RTK_TELEMETRY_DISABLED = "1";
      };
      unsetEnv = [ "TMUX" ];
      flags = [
        "--settings"
        "$PERMEANCE_ROOT/.claude/settings.json"
        "--setting-sources"
        "user,project,local"
      ];
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "claude";
      description = "Verify claude binary executes, settings.json commands resolve, the status line renders, and the sandbox launcher pins the host-executed config";
      script = ''
        # claude-code does not expose a config-loading probe that works in a
        # sandbox without auth/network. This only verifies the wrapper's binary
        # executes — config-loading is exercised at runtime, not here.
        if ${self}/bin/claude --version > /dev/null 2>&1; then
          ok "binary executes"
        else
          fail "binary failed to execute"
        fi

        # settings.json names the status line and hooks by bare command, so each
        # must resolve on claude's PATH; at runtime a missing one fails silently
        # (the status line just goes blank).
        claudePath=${
          pkgs.lib.concatMapStringsSep ":" (builtins.replaceStrings [ "@OUT@" ] [ "${self}" ]) pathPrefix
        }
        settings=${self}/.claude/settings.json
        for cmd in $(${pkgs.jq}/bin/jq -r '[.statusLine.command] + [.hooks[][].hooks[] | .command // empty] | .[] | split(" ")[0]' "$settings" | sort -u); do
          if PATH="$claudePath" command -v "$cmd" > /dev/null; then
            ok "on claude's PATH: $cmd"
          else
            fail "settings.json command not on claude's PATH: $cmd"
          fi
        done

        # Run the status line the way Claude Code does (sh -c, claude's PATH) on
        # a fixed payload. No rate_limits, so the line doesn't depend on the clock.
        payload='{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"used_percentage":42,"current_usage":{"input_tokens":2000,"output_tokens":1500,"cache_creation_input_tokens":8000,"cache_read_input_tokens":120000}},"prompt_cache":{"ttl":"1h"},"cost":{"total_cost_usd":1.5}}'
        want='ctx ━━─── 42%  $1.50 +0.13  Opus 5.5  ↓2.0k ↑1.5k W8.0k R120k =132k'
        line=$(printf '%s' "$payload" \
          | COLUMNS=200 PATH="$claudePath" ${pkgs.runtimeShell} -c "$(${pkgs.jq}/bin/jq -r .statusLine.command "$settings")")
        if [ "$line" = "$want" ]; then
          ok "status line renders a sample payload"
        else
          fail "status line rendered: $line"
        fi
      ''
      # The bubblewrap launcher is Linux-only (macOS uses Claude Code's built-in
      # Seatbelt), and its claude-seccomp-bpf helper cgo-links libseccomp, which
      # does not evaluate on aarch64-darwin. Gate the launcher dry-run to Linux;
      # the binary/settings/status-line checks above still run on every platform.
      + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
        # The bubblewrap launcher cannot run for real here (no user namespaces
        # in the build sandbox), but its policy is an argv. Run it against a
        # writable copy of the sources tree with a stand-in `bwrap` that prints
        # the arguments it was handed, and assert that the host-executed config
        # comes out pinned read-only, with each parent bound first as an anchor
        # (a directory that merely contains a pin can be renamed from under it).
        tree="$TMPDIR/tree"
        cp -r ${../sources} "$tree"
        chmod -R u+w "$tree"
        repo="$TMPDIR/repo"
        mkdir -p "$repo/.git" "$repo/.claude/skills" "$TMPDIR/fakebin"
        : > "$repo/.git/config"
        : > "$repo/.claude/settings.local.json"
        ln -s ${fakeBwrap} "$TMPDIR/fakebin/bwrap"
        argv="$TMPDIR/bwrap-argv"
        if ! (
          cd "$repo" \
            && PATH="$TMPDIR/fakebin:${
              pkgs.lib.makeBinPath [
                claudeCwdGate
                claudeSeccompBpf
                claudeSshSanitize
              ]
            }:$PATH" \
              PERMEANCE_TREE="$tree" \
              bash "$tree/.config/shell/scripts/claude-sandbox.bash" claude --version \
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
          .config/shell/leader.toml \
          .config/shell/scripts/claude-sandbox.bash .config/git .config/direnv; do
          pinned "$tree/$p"
        done
        anchored "$tree" "$tree/.claude"
        anchored "$tree/.config" "$tree/.config/zsh"
        anchored "$tree/.config/shell" "$tree/.config/shell/functions"
        anchored "$tree/.config/shell/scripts" "$tree/.config/shell/scripts/claude-sandbox.bash"
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
      '';
    };
  };
in
self
