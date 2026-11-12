{
  pkgs,
  files,
  permeance,
  git,
  nixpkgs,
  nix-index-database,
  # github:Runeword/claude-sandbox's packages for this system.
  claudeSandbox,
}:

let
  claudeStatusline = import ../packages/claude/statusline { inherit pkgs; };
  claudeDocsGuard = import ../packages/claude/docs-guard { inherit pkgs; };
  # Its `mark` is the SessionStart hook that names the open session to the
  # backup and restore (packages/claude/sessions/open.go).
  claudeSessions = import ../packages/claude/sessions { inherit pkgs; };
  # Holds Claude's memory changes until its work is done: the memory-gate
  # plugin's PreToolUse, Stop and UserPromptSubmit hooks run it
  # (packages/claude/memory-gate/main.go).
  claudeMemoryGate = import ../packages/claude/memory-gate { inherit pkgs; };
  # CLAUDE_CODE_SHELL_PREFIX: runs every shell command, hook and MCP server
  # Claude Code starts under Landlock, with the config folders' projects/, which
  # holds memory, read-only (packages/claude/shell-guard/main.go).
  claudeShellGuard = import ../packages/claude/shell-guard { inherit pkgs; };
  # The PreToolUse hook on the read-only Explore agent's Bash: lets through only
  # commands that read (packages/claude/explore-guard/main.go).
  claudeExploreGuard = import ../packages/claude/explore-guard { inherit pkgs; };
  # The read-only Explore agent, which replaces the built-in one, as claude's
  # --agents value. Its hook runs the guard above by store path, so a claude
  # only ever loads the agent that its own build enforces
  # (packages/claude/explore-guard/agent.nix).
  exploreAgents = builtins.toJSON {
    Explore = import ../packages/claude/explore-guard/agent.nix { guard = claudeExploreGuard; };
  };
  gitAllowlistHook = claudeSandbox.git-allowlist-hook;
  # Stand-in bwrap for that dry run: prints the argv it was handed, one per line,
  # and saves the environment it inherited to $BWRAP_ENV.
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
  # Point the shim at the wrapped git so config (excludesFile, pager, includes,
  # GIT_CONFIG_GLOBAL) applies whether git is invoked from claude or from the
  # interactive shell. The allowlist check still runs first on the same argv.
  gitShim = claudeSandbox.git-shim.override { realGit = "${git}/bin/git"; };
  playwrightMcpPkg = import ../packages/playwright-mcp.nix { inherit pkgs; };
  # The Playwright MCP's browser_run_code_unsafe runs any JavaScript in the
  # server's own process, which on macOS is outside Claude Code's sandbox. Denied
  # by glob for any server that offers it, and by full name for the plugin
  # shipped here too, so a narrower reading of the glob still covers that one.
  denyPlaywrightUnsafe = [
    "mcp__*__browser_run_code_unsafe"
    "mcp__plugin_playwright-mcp_playwright-mcp__browser_run_code_unsafe"
  ];

  tools = [
    claudeStatusline
    claudeDocsGuard
    claudeSessions
    claudeMemoryGate
    claudeShellGuard
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
    pkgs.lua-language-server
    pkgs.yaml-language-server
    pkgs.terraform-ls
    pkgs.marksman
    pkgs.vscode-langservers-extracted
    pkgs.shellcheck
    # firebase CLI on claude's PATH so sessions can run `firebase …`. Already in
    # packages/commons.nix for the interactive shell (usually inherited here too),
    # but listed explicitly so availability doesn't depend on the caller's PATH.
    # Auth is a scoped service account, not your personal `firebase login`:
    # CLAUDE_SANDBOX_ALLOW_FIREBASE=1 (`firebase` in the leader `cc` picker,
    # wired through claude.bash) makes claude-sandbox.bash read the
    # least-privilege SA key from `pass` (entry claude/firebase-sa-key) and mount
    # it read-only as Application Default Credentials for that session;
    # ~/.config/configstore stays masked. On macOS, claude-macos.bash hands it
    # over instead.
    pkgs.firebase-tools
    # jira-cli, listed for the same reason. Auth: CLAUDE_SANDBOX_ALLOW_JIRA=1
    # (`jira` in the `cc` picker) makes claude-sandbox.bash export claude's own
    # API token from `pass` (entry claude/jira-token, not your alias's
    # JIRA_API_TOKEN) as JIRA_API_TOKEN and point JIRA_CONFIG_FILE at the
    # session's own config, ~/.config/.jira/claude.yml. On macOS,
    # claude-macos.bash does.
    pkgs.jira-cli-go
    # comma with nix-index-database's prebuilt index: `, -p <cmd>` names the
    # nixpkgs packages that ship bin/<cmd>, offline. The always-on rule
    # sources/.claude/rules/nix-run.md has claude look a missing command up this
    # way, then run it with `nix shell` from the nixpkgs pinned below, never
    # install it.
    nix-index-database.packages.${pkgs.stdenv.hostPlatform.system}.comma-with-db
    # Runtimes for MCP servers launched from a plugin .mcp.json rather than being
    # Nix-packaged: nodejs/npx for figma-mcp; uv/uvx + python for the pure-Python
    # servers (nix-mcp, aws-api-mcp, google-workspace-mcp). uvx fetches the pinned
    # server from PyPI at run time (cached under $CLAUDE_CONFIG_DIR); python312 with
    # UV_PYTHON_PREFERENCE=only-system avoids a managed-Python download and gives
    # broad wheel coverage. playwright-mcp stays Nix-packaged because its browsers
    # come from nixpkgs and its wrapper gives it the scratch home they need.
    pkgs.nodejs
    pkgs.uv
    pkgs.python312
    playwrightMcpPkg
  ]
  # Deps for claude's built-in `/sandbox` on Linux (Seatbelt is built in on macOS).
  # Recent claude-code turns that sandbox ON by default when these sit on PATH; it
  # can't nest inside the bubblewrap jail (claude-sandbox.bash passes
  # --disable-userns), so sources/.claude/settings.linux.json switches it back off
  # at user scope. Kept on PATH so /sandbox (project-local scope, above user) can
  # still opt an unsandboxed (CLAUDE_SANDBOX=0) session back in.
  ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    pkgs.bubblewrap
    pkgs.socat
  ];

  config = files.mkConfig "claude-config" [
    ".claude/rules"
    # User-level skills, such as /x: claude.bash clears the profile's
    # skills/ at each launch, so they ship as commands/<name>.md files.
    ".claude/commands"
    ".claude/plugins"
    ".claude/settings.json"
    # The per-OS sandbox overlays claude.bash merges into each profile; bundled
    # mode provisions profiles from this copy (zsh's own bundle has no .claude).
    ".claude/settings.linux.json"
    ".claude/settings.darwin.json"
    ".claude/git-allowlist.toml"

    # Renamed and installed under bin/ so it's PATH-resolvable from
    # settings.json hooks (which invoke it as `claude-format`).
    {
      source = ".claude/hooks/format.sh";
      target = "bin/claude-format";
    }
  ];

  # claude's PATH, ahead of the inherited one (permeance.out: the launcher's $out).
  # gitShim ships a binary named `git`. It is injected only into claude's own
  # PATH (and inherited by its subprocesses: bash, Python, Make, …), not merged
  # into $out/bin, so the user's interactive shell still sees the wrapped git.
  # Prefixed first so it wins over git-with-config within claude's process
  # tree. The shim enforces the same allowlist policy as git-allowlist-hook,
  # then exec's the real git. One directory per element: permeance rejects a
  # ':'-joined makeBinPath string.
  pathPrefix = [
    "${gitShim}/bin"
    "${permeance.out}/bin"
  ]
  ++ map (pkg: "${pkgs.lib.getBin pkg}/bin") tools;

  self = pkgs.symlinkJoin {
    name = "claude-with-config";
    paths = [
      pkgs.claude-code
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "claude";
      compiled = true;
      inherit pathPrefix;
      configEnv = {
        CLAUDE_GIT_ALLOWLIST_CONFIG = ".claude/git-allowlist.toml";
      };
      staticEnv = {
        RTK_TELEMETRY_DISABLED = "1";
        # The nixpkgs claude runs missing commands from: this flake's locked
        # input, already in the store, so resolving it downloads nothing (plain
        # `nixpkgs#` goes through the host's registry: maybe another revision,
        # and a fresh fetch each sandbox session, whose ~/.cache/nix starts cold)
        # and a tool the terminal ships resolves to the very same build. comma
        # reads it too, but only when NIX_PATH has no nixpkgs= entry, which is
        # why the rule runs through `nix shell` instead of `, <cmd>`.
        COMMA_NIXPKGS_FLAKE = "path:${nixpkgs}";
        # comma keeps its choice cache under $XDG_STATE_HOME, read-only in the
        # sandbox, where it would print an error on every call.
        COMMA_CACHING = "0";
      };
      unsetEnv = [ "TMUX" ];
      # --disallowedTools takes several values, so it comes first: the next flag
      # ends its list, where a prompt passed after the flags would join it.
      flags = [
        "--disallowedTools"
      ]
      ++ denyPlaywrightUnsafe
      ++ [
        "--settings"
        "${permeance.root}/.claude/settings.json"
        "--setting-sources"
        "user,project,local"
        "--agents"
        exploreAgents
      ];
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "claude";
      description = "Verify claude binary executes, settings.json, plugin hook and plugin MCP commands resolve, keep CLAUDE.local.md files out of context and keep the bypass-mode warning accepted, git-allowlist-hook blocks when it can't run, claude starts with the read-only Explore agent and its own build's guard, which blocks writes, the status line renders, comma looks packages up offline, the Playwright MCP starts in its scratch home with its testing and devtools tools, claude denies its unsafe tool and no plugin attaches it to an outside browser or widens its reach, the Go and Lua language servers keep their caches where the sandbox can write and the shell one skips the checks .shellcheckrc disables, the sandbox launcher pins the host-executed config and exports the jira token behind a network filter, and the macOS launcher hands over the jira token and firebase key";
      script = ''
        # claude-code does not expose a config-loading probe that works in a
        # sandbox without auth/network. This only verifies the wrapper's binary
        # executes — config-loading is exercised at runtime, not here.
        if ${self}/bin/claude --version > /dev/null 2>&1; then
          ok "binary executes"
        else
          fail "binary failed to execute"
        fi

        # settings.json names the status line, the hooks and the shell prefix by
        # bare command, and the plugins name their hooks' and MCP servers'
        # commands the same way, so each must resolve on claude's PATH; at
        # runtime a missing one fails (the status line just goes blank, without
        # the prefix every shell command fails, and a server never starts).
        claudePath=${
          pkgs.lib.concatMapStringsSep ":" (builtins.replaceStrings
            [ permeance.out ]
            [ "${self}" ]
          ) pathPrefix
        }
        settings=${self}/.claude/settings.json
        for cmd in $(
          {
            ${pkgs.jq}/bin/jq -r '[.statusLine.command] + [.hooks[][].hooks[] | .command // empty] + [.env.CLAUDE_CODE_SHELL_PREFIX // empty] | .[] | split(" ")[0]' "$settings"
            ${pkgs.jq}/bin/jq -r '.hooks[][].hooks[] | .command // empty | split(" ")[0]' ${self}/.claude/plugins/*/hooks/hooks.json
            ${pkgs.jq}/bin/jq -r '(.mcpServers // {})[] | .command // empty | split(" ")[0]' ${self}/.claude/plugins/*/.mcp.json
          } | sort -u
        ); do
          if PATH="$claudePath" command -v "$cmd" > /dev/null; then
            ok "on claude's PATH: $cmd"
          else
            fail "settings.json, plugin hook or plugin MCP command not on claude's PATH: $cmd"
          fi
        done

        # The Playwright MCP (packages/playwright-mcp.nix) starts from its
        # wrapper, in its own scratch home, and offers the testing and devtools
        # tools the wrapper turns on. Spoken to through a FIFO: a pipe would
        # close its stdin, and the server with it, before it answers.
        mcpDir=$(mktemp -d)
        mkfifo "$mcpDir/in"
        ${playwrightMcpPkg}/bin/playwright-mcp --headless < "$mcpDir/in" > "$mcpDir/out" 2> "$mcpDir/err" &
        mcpPid=$!
        exec 3> "$mcpDir/in"
        mcpSay() { (trap "" PIPE; printf '%s\n' "$@" >&3) || true; }
        mcpWait() {
          for _ in $(seq 60); do
            ${pkgs.jq}/bin/jq -e --argjson id "$1" 'select(.id == $id)' "$mcpDir/out" > /dev/null 2>&1 && return 0
            sleep 1
          done
          return 1
        }
        mcpSay '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
        if mcpWait 1; then
          mcpSay '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
          mcpWait 2 || true
        fi
        exec 3>&-
        kill "$mcpPid" 2> /dev/null || true
        wait "$mcpPid" 2> /dev/null || true
        mcpTools=$(${pkgs.jq}/bin/jq -r 'select(.id == 2) | .result.tools[].name' "$mcpDir/out" 2> /dev/null || true)
        for tool in browser_navigate browser_verify_value browser_start_tracing; do
          if grep -qx -- "$tool" <<< "$mcpTools"; then
            ok "the Playwright MCP offers $tool"
          else
            fail "the Playwright MCP doesn't offer $tool: $(head -c 300 "$mcpDir/err")"
          fi
        done

        # claude starts with browser_run_code_unsafe denied (denyPlaywrightUnsafe).
        for rule in ${pkgs.lib.escapeShellArgs denyPlaywrightUnsafe}; do
          if grep -aqF -- "$rule" ${self}/bin/claude; then
            ok "claude denies $rule"
          else
            fail "claude doesn't deny $rule"
          fi
        done

        # A plugin starts the Playwright MCP under the name its deny rule spells
        # out, and passes none of the options that would attach it to an outside
        # browser (cdp-endpoint, endpoint, extension), swap its browser or profile
        # (executable-path, user-data-dir, storage-state, config), open it to the
        # network (host, port), run code in it at start (init-page), or widen
        # what it reaches (allow-unrestricted-file-access, no-sandbox). Its env
        # can't: the wrapper drops every PLAYWRIGHT_MCP_* it is handed.
        playwrightServers=0
        for mcp in ${self}/.claude/plugins/*/.mcp.json; do
          plugin=$(basename "$(dirname "$mcp")")
          for server in $(${pkgs.jq}/bin/jq -r '(.mcpServers // {}) | to_entries[] | select(.value.command == "playwright-mcp") | .key' "$mcp"); do
            playwrightServers=$((playwrightServers + 1))
            rule="mcp__plugin_''${plugin}_''${server}__browser_run_code_unsafe"
            if grep -aqF -- "$rule" ${self}/bin/claude; then
              ok "claude denies $plugin's browser_run_code_unsafe by name"
            else
              fail "claude doesn't deny $plugin's browser_run_code_unsafe by name: $rule"
            fi
            if ${pkgs.jq}/bin/jq -e --arg s "$server" --argjson deny '["--allow-unrestricted-file-access","--cdp-endpoint","--config","--endpoint","--executable-path","--extension","--host","--init-page","--no-sandbox","--port","--storage-state","--user-data-dir"]' '[.mcpServers[$s].args // [] | .[] as $a | $deny[] as $d | select($a == $d or ($a | startswith($d + "=")))] == []' "$mcp" > /dev/null; then
              ok "$plugin leaves the Playwright MCP's browser, profile and reach to its wrapper"
            else
              fail "$plugin attaches the Playwright MCP to an outside browser or widens what it can reach"
            fi
          done
        done
        if [ "$playwrightServers" -gt 0 ]; then
          ok "a plugin starts the Playwright MCP"
        else
          fail "no plugin starts the Playwright MCP (sources/.claude/plugins/playwright-mcp)"
        fi

        # A git command git-allowlist-hook can't vet (its binary missing, a
        # timeout) is blocked rather than let through; git-shim still checks the
        # same allowlist when git runs.
        if ${pkgs.jq}/bin/jq -e '[.hooks.PreToolUse[].hooks[] | select(.command == "git-allowlist-hook") | .onFailure] == ["block"]' "$settings" > /dev/null; then
          ok "git-allowlist-hook blocks a git command when it can't run"
        else
          fail "git-allowlist-hook lets git commands through when it can't run"
        fi

        # The Explore agent replaces the built-in, whose shell runs whatever the
        # permission mode lets through. claude gets it with --agents from the
        # build that holds its guard, which its hook on Bash runs by store path
        # and which blocks when it can't run. Claude Code checks an --agents
        # value before anything else and refuses to start on one it can't load,
        # so a print run without a prompt shows the value loads.
        agents=${pkgs.writeText "explore-agents.json" exploreAgents}
        guard=$(${pkgs.jq}/bin/jq -r '.Explore.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.onFailure == "block") | .command' "$agents")
        started=$(${self}/bin/claude -p < /dev/null 2>&1 || true)
        if ${pkgs.jq}/bin/jq -e '.Explore.tools == ["Read", "Bash", "LSP"]' "$agents" > /dev/null \
          && [ "$guard" = "${claudeExploreGuard}/bin/claude-explore-guard" ] && [ -x "$guard" ] \
          && grep -aqF -- "$(cat "$agents")" ${self}/bin/claude \
          && printf '%s' "$started" | grep -q 'Input must be provided'; then
          ok "claude starts with the Explore agent, which keeps to Read, LSP and a Bash its own build's guard vets"
        else
          fail "claude lacks the Explore agent, can't load it, or gives it more tools or an unguarded Bash: $started"
        fi
        vet() {
          ${pkgs.jq}/bin/jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | "$guard" 2> /dev/null
        }
        if vet 'git log --oneline -5' && vet "grep -rn 'a|b' src" \
          && ! vet 'git stash' && ! vet 'git log --output=x' \
          && ! vet 'cat a > b' && ! vet 'find . -delete'; then
          ok "claude-explore-guard lets reads through and blocks writes"
        else
          fail "claude-explore-guard lets a write through or blocks a read"
        fi

        # CLAUDE.local.md is git-ignored, so one a session plants, at the root
        # or in a subdirectory, would steer every later session without ever
        # showing in git status. settings.json keeps them all out of context.
        if ${pkgs.jq}/bin/jq -e '.claudeMdExcludes | index("**/CLAUDE.local.md")' "$settings" > /dev/null; then
          ok "settings.json keeps CLAUDE.local.md files out of context"
        else
          fail "settings.json lets CLAUDE.local.md files into context"
        fi

        # Claude records the accepted bypass-mode warning in the profile's
        # settings.json, which claude.bash re-provisions from this file at every
        # launch: the acceptance has to live here, or the warning comes back on
        # each start (the launcher passes --allow-dangerously-skip-permissions).
        if ${pkgs.jq}/bin/jq -e '.skipDangerousModePermissionPrompt == true' "$settings" > /dev/null; then
          ok "settings.json keeps the accepted bypass-mode warning"
        else
          fail "settings.json drops the accepted bypass-mode warning"
        fi

        # Memory changes: the ask rule asks before each write by Claude's file
        # tools, claude-shell-guard keeps shell commands from writing memory, and
        # the memory-gate plugin's hooks run claude-memory-gate, which holds the
        # prompts until Claude's work is done. Hooks stay on: this file outranks
        # a disableAllHooks a session could write into .claude/settings.local.json.
        if ${pkgs.jq}/bin/jq -e '(.permissions.ask | index("Edit(~/.claude*/projects/*/memory/**)")) and .env.CLAUDE_CODE_SHELL_PREFIX == "claude-shell-guard" and .disableAllHooks == false' "$settings" > /dev/null; then
          ok "settings.json asks before each memory change and keeps the shell out of memory"
        else
          fail "settings.json lets Claude change its memory without asking, or from the shell"
        fi
        memoryHooks=${self}/.claude/plugins/memory-gate/hooks/hooks.json
        if ${pkgs.jq}/bin/jq -e '[.hooks.PreToolUse, .hooks.Stop, .hooks.UserPromptSubmit] | all(any(.[].hooks[].command; . == "claude-memory-gate"))' "$memoryHooks" > /dev/null; then
          ok "the memory-gate plugin holds memory changes until Claude's work is done"
        else
          fail "the memory-gate plugin lets Claude change its memory mid-task"
        fi
        # claude.bash loads its default plugins on every launch but the plugin
        # picker's (cpl), which loads only what is picked.
        if grep -Eq '^__CLAUDE_DEFAULT_PLUGINS=\(([^)]* )?memory-gate( [^)]*)?\)' ${../sources/.config/shell/functions/claude.bash}; then
          ok "claude.bash loads the memory-gate plugin by default"
        else
          fail "claude.bash doesn't load the memory-gate plugin by default"
        fi

        # Run the status line the way Claude Code does (sh -c, claude's PATH) on
        # a fixed payload. No rate_limits, so the line doesn't depend on the clock.
        payload='{"session_id":"3f2c8a9e-7b41-4d6a-9c05-1e8f6b2d4a73","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"context_window":{"used_percentage":42,"current_usage":{"input_tokens":2000,"output_tokens":1500,"cache_creation_input_tokens":8000,"cache_read_input_tokens":120000}},"prompt_cache":{"ttl":"1h"},"cost":{"total_cost_usd":1.5}}'
        want='ctx ━━─── 42%  $1.50 +0.13  Opus 5.5  ↓2.0k ↑1.5k W8.0k R120k =132k'
        line=$(printf '%s' "$payload" \
          | COLUMNS=200 PATH="$claudePath" ${pkgs.runtimeShell} -c "$(${pkgs.jq}/bin/jq -r .statusLine.command "$settings")")
        if [ "$line" = "$want" ]; then
          ok "status line renders a sample payload"
        else
          fail "status line rendered: $line"
        fi

        # The lookup nix-run.md relies on: comma on claude's PATH finds the
        # package that ships a command in its bundled index, with no network.
        if PATH="$claudePath" , -p rg | grep -qx -- '- ripgrep.out'; then
          ok "comma looks up rg's package offline"
        else
          fail "comma lookup failed: $(PATH="$claudePath" , -p rg 2>&1)"
        fi

        # Plugin language servers run inside the sandbox, where ~/.cache is
        # read-only: gopls quits when it cannot make its cache there, so go-lsp
        # keeps it under the claude profile, as the MCP plugins keep theirs.
        if ${pkgs.jq}/bin/jq -e '.go.env.GOPLSCACHE | startswith("''${CLAUDE_CONFIG_DIR")' ${self}/.claude/plugins/go-lsp/.lsp.json > /dev/null; then
          ok "go-lsp keeps gopls's cache under the claude profile"
        else
          fail "go-lsp leaves gopls's cache in ~/.cache, where gopls quits in the sandbox"
        fi

        # lua-language-server quits the same way over its log and meta files,
        # which its nixpkgs launcher keeps under XDG_CACHE_HOME (~/.cache when
        # unset), so lua-lsp points that at the claude profile too.
        if ${pkgs.jq}/bin/jq -e '.lua.env.XDG_CACHE_HOME | startswith("''${CLAUDE_CONFIG_DIR")' ${self}/.claude/plugins/lua-lsp/.lsp.json > /dev/null; then
          ok "lua-lsp keeps lua-language-server's cache under the claude profile"
        else
          fail "lua-lsp leaves lua-language-server's cache in ~/.cache, where it quits in the sandbox"
        fi

        # bash-language-server runs shellcheck on stdin from the project root,
        # where it never finds .config/shell/.shellcheckrc, so shell-lsp passes
        # the checks that file disables itself.
        disabled=$(sed -n 's/^disable=//p' ${../sources}/.config/shell/.shellcheckrc | sort | paste -sd, -)
        excluded=$(${pkgs.jq}/bin/jq -r '.shell.env.SHELLCHECK_OPTS // "" | ltrimstr("--exclude=") | split(",") | sort | join(",")' ${self}/.claude/plugins/shell-lsp/.lsp.json)
        if [ -n "$disabled" ] && [ "$excluded" = "$disabled" ]; then
          ok "shell-lsp skips the checks .shellcheckrc disables: $excluded"
        else
          fail "shell-lsp skips '$excluded', .shellcheckrc disables '$disabled'"
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
in
self
