{
  pkgs,
  files,
  permeance,
  claude,
}:

let
  # The leader-key picker (the .config/zsh/plugins/leader-aliases plugin)
  # renders the bundled .config/shell/leader.conf through this binary, and
  # leader-aliases-edit lines it up with it; the smoke test exercises both
  # against the wrapper's own copy of the table.
  leaderAliases = import ../packages/leader-aliases { inherit pkgs; };
  # Shift+Tab's search (.config/shell/scripts/fm_rg.sh) matches through it.
  fmQuery = import ../packages/fm-query { inherit pkgs; };
  config = files.mkConfig "zsh-config" [
    ".config/zsh"
    ".config/shell"
    ".config/readline"
    ".config/direnv"
  ];
  self = pkgs.symlinkJoin {
    name = "zsh-with-config";
    paths = [
      pkgs.zsh
      pkgs.zsh-autosuggestions
      config
    ];
    postBuild = ''
      mkdir -p $out/paths
      ln -s ${claude} $out/paths/claude

      ${permeance.installLauncher {
        binName = "zsh";
        compiled = true;
        configEnv = {
          ZDOTDIR = ".config/zsh";
          INPUTRC = ".config/readline/inputrc";
          DIRENV_CONFIG = ".config/direnv";
        };
        staticEnv = {
          NIX_OUT_SHELL = permeance.out;
        };
        flags = [ "--no-global-rcs" ];
      }}
    '';
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "zsh";
      description = "Verify zsh wrapper exec's the real binary, a login shell started through it is one, the leader table renders, gc's secret › set reads its value silently and hands it to gcloud on stdin, gc's project › set sets the project picked in fzf, yp prints and copies the current directory without a newline, hgr and ngr list every generation but the current one, na deletes every old home-manager and NixOS generation, collects the garbage and refreshes the boot menu, zr removes the directories picked in fzf from zoxide's list, ol edits the leader table in a copy that reaches it only valid and lined up, the leader picker renders once per width and edit and dispatches each kind of pick with bare redraws, off an empty prompt Space and Enter run their previous widgets in a bare zsh, the leader plugin's example table renders lined up, god/godc name and clear Go dev builds, bundled mode provisions the claude profile with its sandbox overlay and the /experts command, failing closed, the claude connection picker launches what was picked, the session eraser hands every marked session to one claude-sessions rm, the fork picker resumes the picked session as a fork, the session backup's restore resumes each picked session as it was started, in its tmux session, which it makes again at the current window's size once it is gone, a launch drops what a session planted for the next one, in the project and in its profile, a launch runs claude under a lock on a file of its own, which it names to claude, the untracked-file preview and __open_file pass paths after --, ga shows its files and hunks lists without a header, gl's file step lists a commit as tree rows with unpickable, uncounted directories and opens the picked rows' files, empty-prompt shortcuts fire only at the prompt, not on continuation lines, in select menus or in vared, the tools' completions are on fpath, __open_recent offers nvim's recent files newest first, Tab fills in a suggestion showing at the end of the line and otherwise opens the completion menu, Alt+H has Claude Haiku explain the typed line, sent as text and never when it looks like a secret, signed in with the token in pass, and Alt+Shift+H hands the command to man, Shift+Tab is bound to a search that lists a dotfile's matches as header and match rows, skips .git, and $HOME's own big trees in $HOME only, previews them without the file's escape sequences or a tree-sitter.json in tree-sitter's working directory, and opens several picks as a quickfix list with absolute paths, and hs refreshes the home-manager flake's local path: and git+file: inputs";
      script = ''
        if ${self}/bin/zsh --version > /dev/null 2>&1; then
          ok "wrapper execs real zsh"
        else
          fail "wrapper does not exec real zsh"
        fi

        # A login shell started through the wrapper is one: the compiled
        # launcher hands zsh the "-zsh" argv[0] its caller gave it, as tmux
        # gives every pane's shell (a bash launcher never sees it).
        if [ "$(exec -a -zsh ${self}/bin/zsh -c '[[ -o login ]] && print login')" = login ]; then
          ok "a login shell started through the wrapper is a login shell"
        else
          fail "the wrapper loses a login shell's -zsh"
        fi

        # A leader.conf that fails to render leaves every chord dead, so check
        # the fields the widget reads (raw command, mode) for a known chord.
        sep=$(printf '\302\240')
        if ${leaderAliases}/bin/leader-aliases ${self}/.config/shell/leader.conf \
          | awk -F "$sep" '$1 ~ /^gt +$/ && $5 == "git status" && $6 == "run" { found = 1 } END { exit !found }'; then
          ok "bundled leader.conf renders and binds gt to git status"
        else
          fail "bundled leader.conf does not render the gt chord"
        fi

        # gc's secret › set reads the value silently and hands it to gcloud on
        # stdin, so it never reaches the command line or the shell history.
        secret='. ${self}/.config/shell/functions/gcloud.bash
          gcloud() { print -r -- "$* <$(cat)>"; }
          __gcloud_secret_set name'
        if ${leaderAliases}/bin/leader-aliases ${self}/.config/shell/leader.conf \
          | awk -F "$sep" '$5 == "__gcloud_secret_set <secret>" { found = 1 } END { exit !found }' \
          && grep -q 'read -rs' ${self}/.config/shell/functions/gcloud.bash \
          && [ "$(echo s3cret | ${self}/bin/zsh -f -c "$secret" 2>/dev/null)" = "secrets versions add name --data-file=- <s3cret>" ]; then
          ok "gc's secret › set reads the value silently and hands it to gcloud on stdin"
        else
          fail "gc's secret › set echoes the value or puts it on the command line"
        fi

        # gc's project › set offers gcloud's projects in fzf and sets the
        # picked one; stand-ins list two projects and pick the second.
        project='. ${self}/.config/shell/functions/gcloud.bash
          gcloud() { [ "$1" = projects ] && print -l a-1 b-2 || print -r -- "$*"; }
          fzf() { tail -n 1; }
          __gcloud_project_set'
        if ${leaderAliases}/bin/leader-aliases ${self}/.config/shell/leader.conf \
          | awk -F "$sep" '$5 == "__gcloud_project_set" && $6 == "run" { found = 1 } END { exit !found }' \
          && [ "$(${self}/bin/zsh -f -c "$project" 2>/dev/null)" = "config set project b-2" ]; then
          ok "gc's project › set sets the project picked in fzf"
        else
          fail "gc's project › set does not set the project picked in fzf"
        fi

        # yp prints the current directory and copies it without a newline; a
        # stand-in __copy records what it was handed.
        copy='. ${self}/.config/shell/functions/utilities.sh
          __copy() { cat > "$HOME/copied"; }
          cd / && __copy_path'
        if ${leaderAliases}/bin/leader-aliases ${self}/.config/shell/leader.conf \
          | awk -F "$sep" '$1 ~ /^yp +$/ && $5 == "__copy_path" && $6 == "run" { found = 1 } END { exit !found }' \
          && [ "$(${self}/bin/zsh -f -c "$copy")" = / ] \
          && [ "$(cat "$HOME/copied"; echo .)" = /. ]; then
          ok "yp prints the current directory and copies it without a newline"
        else
          fail "yp does not print and copy the current directory as it is"
        fi

        # hgr leaves the current home-manager generation out of its list, as
        # ngr does below: home-manager refuses to remove it. A stand-in fzf
        # records the list.
        hm_generations='. ${self}/.config/shell/functions/nix.sh
          home-manager() { print -l "2026-01-02 00:00 : id 2 -> /nix/store/b (current)" "2026-01-01 00:00 : id 1 -> /nix/store/a"; }
          fzf() { cat > "$HOME/offered-hm"; }
          __home_manager_generation_remove'
        if ${leaderAliases}/bin/leader-aliases ${self}/.config/shell/leader.conf \
          | awk -F "$sep" '$1 ~ /^hgr +$/ && $5 == "__home_manager_generation_remove" && $6 == "run" { found = 1 } END { exit !found }' \
          && { ${self}/bin/zsh -f -c "$hm_generations"; [ "$(awk '{ print $5 }' "$HOME/offered-hm")" = 1 ]; }; then
          ok "hgr lists every home-manager generation but the current one"
        else
          fail "hgr lists the current home-manager generation, which home-manager refuses to remove"
        fi

        # ngr leaves the current NixOS generation out of its list: nix-env
        # refuses a list that names it and removes none of the others, so
        # select-all would remove nothing. A stand-in fzf records the list.
        nixos_generations='. ${self}/.config/shell/functions/nix.sh
          sudo() { "$@"; }
          nix-env() { print -l " 1   2026-01-01 00:00:00   " " 2   2026-01-02 00:00:00   (current)"; }
          fzf() { cat > "$HOME/offered"; }
          __nixos_generation_remove'
        if ${leaderAliases}/bin/leader-aliases ${self}/.config/shell/leader.conf \
          | awk -F "$sep" '$1 ~ /^ngr +$/ && $5 == "__nixos_generation_remove" && $6 == "run" { found = 1 } END { exit !found }' \
          && { ${self}/bin/zsh -f -c "$nixos_generations"; [ "$(awk '{ print $1 }' "$HOME/offered")" = 1 ]; }; then
          ok "ngr lists every NixOS generation but the current one"
        else
          fail "ngr lists the current NixOS generation, which nix-env refuses to delete"
        fi

        # na does hd and nd in one, then refreshes the boot menu as ngr does:
        # the home-manager profile goes first, as the user, since root's
        # nix-collect-garbage never sees it. Stand-ins print each command.
        clean_all='. ${self}/.config/shell/functions/nix.sh
          XDG_STATE_HOME=/state
          nix-env() { print -rn -- "nix-env $*; "; }
          sudo() { print -rn -- "sudo $*; "; }
          __nix_garbage_clean_all'
        cleaned="nix-env -p /state/nix/profiles/home-manager --delete-generations old; "
        cleaned+="sudo nix-collect-garbage --verbose --delete-old; "
        cleaned+="sudo /run/current-system/bin/switch-to-configuration boot; "
        if ${leaderAliases}/bin/leader-aliases ${self}/.config/shell/leader.conf \
          | awk -F "$sep" '$1 ~ /^na +$/ && $5 == "__nix_garbage_clean_all" && $6 == "run" { found = 1 } END { exit !found }' \
          && [ "$(${self}/bin/zsh -f -c "$clean_all")" = "$cleaned" ]; then
          ok "na deletes the old home-manager generations, then root's, collects the garbage and refreshes the boot menu"
        else
          fail "na does not delete the old home-manager and NixOS generations, collect the garbage and refresh the boot menu"
        fi

        # zr removes the directories picked in fzf from zoxide's list and keeps
        # the rest: a stand-in fzf picks the first and the last of three rows,
        # the first a path with a space.
        zoxide_remove='. ${self}/.config/shell/functions/zoxide.sh
          export _ZO_DATA_DIR=$HOME/zoxide
          mkdir -p "$_ZO_DATA_DIR" "$HOME/z/a" "$HOME/z/b" "$HOME/z/c d"
          zoxide add "$HOME/z/a" "$HOME/z/b" "$HOME/z/c d"
          zoxide add "$HOME/z/b" "$HOME/z/c d"
          zoxide add "$HOME/z/c d"
          fzf() { awk "NR != 2"; }
          __zoxide_remove && zoxide query --list'
        if ${leaderAliases}/bin/leader-aliases ${self}/.config/shell/leader.conf \
          | awk -F "$sep" '$1 ~ /^zr +$/ && $5 == "__zoxide_remove" && $6 == "run" { found = 1 } END { exit !found }' \
          && [ "$(PATH=${pkgs.zoxide}/bin:$PATH ${self}/bin/zsh -f -c "$zoxide_remove")" = "$HOME/z/b" ]; then
          ok "zr removes the directories picked in fzf from zoxide's list"
        else
          fail "zr does not remove the directories picked in fzf, or removes others"
        fi

        # The picker renders the table once per shell and width: a second press
        # reuses the rows, a resize or an edited table renders them again. A
        # stand-in leader-aliases counts the renders.
        mkdir -p "$HOME/leader/bin"
        cp ${self}/.config/shell/leader.conf "$HOME/leader/leader.conf"
        chmod u+w "$HOME/leader/leader.conf"
        printf '#!/bin/sh\necho >> "%s"\nexec %s "$@"\n' "$HOME/leader/renders" ${leaderAliases}/bin/leader-aliases > "$HOME/leader/bin/leader-aliases"
        chmod +x "$HOME/leader/bin/leader-aliases"
        rows='. ${self}/.config/zsh/plugins/leader-aliases/leader-aliases.plugin.zsh
          t=$HOME/leader/leader.conf
          COLUMNS=100; _leader_aliases_rows "$t"; first=$REPLY
          _leader_aliases_rows "$t"; [ "$REPLY" = "$first" ] && print same
          COLUMNS=90; _leader_aliases_rows "$t"
          print "# edited" >> "$t"; _leader_aliases_rows "$t"'
        if [ "$(PATH=$HOME/leader/bin:$PATH ${self}/bin/zsh -f -c "$rows")" = same ] \
          && [ "$(wc -l < "$HOME/leader/renders")" -eq 3 ]; then
          ok "the leader picker renders its table once, then again only after a resize or an edit"
        else
          fail "the leader picker does not reuse its rows until a resize or an edit"
        fi

        # ol (leader-aliases-edit) edits the table in a copy that reaches it only
        # valid and lined up: a stand-in editor, which takes an argument the way
        # EDITOR='code --wait' does, adds a line with an unknown mode, then,
        # reopened at that line, fixes it.
        printf '[git]\ngt  run  status  git status\n' > "$HOME/leader/edit.conf"
        printf '#!/bin/sh\n[ "$1" = -w ] || exit 1; shift\necho "$*" >> "%s"\nfor f; do :; done\ncase $1 in\n  --) echo "zz  rnu  sleep  sleep 1" >> "$f" ;;\n  +3) sed "s/ rnu / run /" "$f" > "$f.new" && cat "$f.new" > "$f" ;;\nesac\n' \
          "$HOME/leader/edits" > "$HOME/leader/bin/edit"
        chmod +x "$HOME/leader/bin/edit"
        edit='. ${self}/.config/zsh/plugins/leader-aliases/leader-aliases.plugin.zsh; leader-aliases-edit "$HOME/leader/edit.conf"'
        if echo y | EDITOR='edit -w' PATH=$HOME/leader/bin:$PATH ${self}/bin/zsh -f -c "$edit" 2>/dev/null \
          && [ "$(cat "$HOME/leader/edit.conf")" = "$(printf '[git]\ngt \trun \tstatus \tgit status\nzz \trun \tsleep  \tsleep 1')" ] \
          && [ "$(awk '{ print $1 }' "$HOME/leader/edits" | tr '\n' ' ')" = "-- +3 " ]; then
          ok "ol runs an EDITOR with arguments, reopens the table copy at a broken line and writes it back lined up"
        else
          fail "ol does not run an EDITOR with arguments, does not reopen a broken line, or writes the table back broken or unaligned"
        fi

        # The picker reads its pick without starting a process, and the widget
        # then only redraws the line: reset-prompt would re-expand the prompt,
        # rerunning starship twice, before an accepted command even starts. Nor
        # does an accepted line fetch a suggestion. A stand-in zle records the
        # widgets called; a stand-in fzf prints what fzf --print-query would,
        # the query and the chord's row. leader-aliases goes on the path inside
        # the script: zsh -i reads /etc/zshenv, and nix-darwin's (in an
        # unsandboxed build) resets PATH.
        stubs='path=(${leaderAliases}/bin $path)
          zle() { print -r -- "zle $*"; }
          pick() { print -r -- "^$1"; grep -m 1 "^$1 *$SEP"; }
          __nix_package() { print -r -- "nix $1 nixpkgs#hello"; }'
        picker() {
          SEP=$sep ${self}/bin/zsh -i -c "$stubs
            $1"'
            BUFFER= CONTEXT=start; _leader_aliases_key
            print -r -- "LBUFFER=$LBUFFER"' 2>/dev/null
        }
        picked=$(picker 'fzf() { pick gt; }')
        case "$picked" in
          *"$(printf 'zle accept-line\nzle redisplay\nLBUFFER=git status ')") ok "a run chord (gt) accepts its command, then only redraws the line" ;;
          *) fail "a run chord (gt) does not accept its command with a bare redraw: $picked" ;;
        esac
        picked=$(picker 'fzf() { pick nps; }')
        case "$picked" in
          *"$(printf 'zle redisplay\nzle accept-line\nzle redisplay\nLBUFFER=nix shell nixpkgs#hello')") ok "an eval chord (nps) runs its helper and accepts its output between bare redraws" ;;
          *) fail "an eval chord (nps) re-expands the prompt or does not accept its helper's output: $picked" ;;
        esac
        picked=$(picker 'fzf() { print -r -- "^z\ z"; return 1; }')
        case "$picked" in
          *"$(printf 'zle autosuggest-fetch\nzle redisplay\nLBUFFER=z z')") ok "a chord that matches nothing is inserted as typed, without its ^ or the backslash fzf puts before a space" ;;
          *) fail "a chord that matches nothing is not inserted as typed: $picked" ;;
        esac

        # Alt+Space (_leader_aliases_line) opens the picker on a typed line: a
        # chord holding #LINE (ls: sudo #LINE) puts its command in place of the
        # line, the cursor on the same character; any other chord, a run chord
        # (gt) too, goes in at the cursor and is not run. The buffers stand in
        # for the typed line, split at the cursor.
        typed() {
          SEP=$sep ${self}/bin/zsh -i -c "$stubs
            fzf() { pick $1; }
            BUFFER='$2$3' LBUFFER='$2' RBUFFER='$3'"'
            _leader_aliases_line
            print -r -- "[$LBUFFER|$RBUFFER]"' 2>/dev/null
        }
        picked="$(typed ls apt ' install foo')$(typed gt 'time ' "")"
        case "$picked" in
          *'[sudo apt| install foo]'*"$(printf 'zle autosuggest-fetch\nzle redisplay\n[time git status |]')") ok "on a typed line, a #LINE chord (ls) replaces the line around the cursor, and a run chord (gt) is only inserted at the cursor" ;;
          *) fail "on a typed line, a #LINE chord does not replace the line around the cursor, or a run chord is run or misplaced: $picked" ;;
        esac

        # Off an empty prompt, Space and Enter run the widgets they had before
        # the plugin was sourced, in a bare zsh with no .zshrc and no
        # zsh-autosuggestions: a stand-in zle records the widgets called on a
        # non-empty line and on an empty select prompt.
        bare='. ${self}/.config/zsh/plugins/leader-aliases/leader-aliases.plugin.zsh
          zle() { print -r -- "zle $*"; }
          BUFFER=ls CONTEXT=start WIDGET=_leader_aliases_space _leader_aliases_key
          BUFFER= CONTEXT=select WIDGET=_leader_aliases_enter _leader_aliases_key'
        if [ "$(${self}/bin/zsh -f -c "$bare" 2>&1)" = "$(printf 'zle self-insert\nzle accept-line')" ]; then
          ok "off an empty prompt, Space and Enter run their previous widgets, in a bare zsh"
        else
          fail "off an empty prompt, Space or Enter does not run its previous widget in a bare zsh"
        fi

        # The plugin's example.conf, the table it points newcomers to, renders
        # and is lined up the way -fmt writes it.
        example=${self}/.config/zsh/plugins/leader-aliases/example.conf
        if ${leaderAliases}/bin/leader-aliases "$example" > /dev/null \
          && [ "$(${leaderAliases}/bin/leader-aliases -fmt - < "$example")" = "$(cat "$example")" ]; then
          ok "the leader plugin's example.conf renders and is lined up"
        else
          fail "the leader plugin's example.conf does not render, or is not lined up"
        fi

        # godc (and gow when it stops) clears the Go dev builds that shadow the
        # Nix copies: every compiled binary in .direnv/bin, not nix-direnv's script.
        bin=$HOME/terminal/.direnv/bin
        mkdir -p "$bin"
        printf '\177ELF' > "$bin/stale"
        printf '#!/bin/sh\n' > "$bin/nix-direnv-reload"
        ${self}/bin/zsh -f -c '. ${self}/.config/shell/functions/go.bash; __go_dev clean' > /dev/null
        if [ ! -e "$bin/stale" ] && [ -e "$bin/nix-direnv-reload" ]; then
          ok "godc clears compiled dev builds and keeps nix-direnv-reload"
        else
          fail "godc does not clear exactly the compiled dev builds"
        fi

        # god names each dev build after its go.mod module, not its directory
        # (packages/git/branches builds git-branches); a stub go records it.
        mkdir -p "$HOME/terminal/packages/grp/tool" "$HOME/stub"
        printf 'module grp-tool\n' > "$HOME/terminal/packages/grp/tool/go.mod"
        printf '#!/bin/sh\n: > "$3"\n' > "$HOME/stub/go"
        chmod +x "$HOME/stub/go"
        PATH=$HOME/stub:$PATH ${self}/bin/zsh -f -c '. ${self}/.config/shell/functions/go.bash; __go_dev' > /dev/null
        if [ -e "$bin/grp-tool" ] && [ ! -e "$bin/tool" ]; then
          ok "god names dev builds after their go.mod module"
        else
          fail "god does not name dev builds after their go.mod module"
        fi

        # Bundled mode: this bundle has no .claude, so a claude profile comes from
        # the claude wrapper's, with this OS's sandbox overlay merged in and its
        # commands linked; an overlay that does not merge refuses the launch instead.
        os=$(uname -s | tr '[:upper:]' '[:lower:]')
        provision='. ${self}/.config/shell/functions/claude.bash; __claude_instance=1; __claude_provision_config'
        if PATH=${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$provision" \
          && [ "$(${pkgs.jq}/bin/jq -c .sandbox "$HOME/.claude-1/settings.json")" \
            = "$(${pkgs.jq}/bin/jq -c .sandbox ${claude}/.claude/settings.$os.json)" ] \
          && [ -f "$HOME/.claude-1/commands/experts.md" ]; then
          ok "bundled mode provisions the claude profile with the $os sandbox overlay and the /experts command"
        else
          fail "bundled mode does not provision the claude profile with its sandbox overlay and the /experts command"
        fi
        # PERMEANCE_STRICT=0: the launcher's strict check would refuse this tree,
        # which has no .config, before zsh ran; the message pins the refusal on
        # the merge.
        mkdir -p "$TMPDIR/tree/.claude"
        echo '{}' > "$TMPDIR/tree/.claude/settings.json"
        echo 'not json' > "$TMPDIR/tree/.claude/settings.$os.json"
        if refusal=$(PATH=${pkgs.jq}/bin:$PATH PERMEANCE_ROOT=$TMPDIR/tree PERMEANCE_STRICT=0 ${self}/bin/zsh -f -c "$provision" 2>&1); then
          fail "a sandbox overlay that does not merge still provisions the claude profile"
        else
          case "$refusal" in
            *"could not merge"*) ok "a sandbox overlay that does not merge refuses the launch" ;;
            *) fail "the claude profile was refused before the overlay merge: $refusal" ;;
          esac
        fi

        # The connection picker (leader cc) launches a plain session plus what
        # was picked: a credential as the launcher's opt-in flag, an MCP plugin
        # on top of the default ones. A stand-in fzf picks jira, figma-mcp and
        # google-workspace-mcp, whose token store needs the launcher's opt-in.
        connect='. ${self}/.config/shell/functions/claude.bash
          fzf() { printf "jira\nfigma-mcp\ngoogle-workspace-mcp\n"; }
          __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
          __claude_connect'
        case "$(CLAUDE_SANDBOX=0 PATH=${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$connect")" in
          "CLAUDE_SANDBOX_ALLOW_JIRA=1 CLAUDE_SANDBOX_ALLOW_GOOGLE_WORKSPACE=1 "*/nix-lsp\ *--plugin-dir\ */figma-mcp\ *--plugin-dir\ */google-workspace-mcp\ *)
            ok "the connection picker launches jira, figma-mcp and google-workspace-mcp on top of the default plugins"
            ;;
          *) fail "the connection picker does not launch what was picked" ;;
        esac

        # The microVM chord (leader cv) launches the same session through
        # claude-vm instead of claude-sandbox, after its --check-cwd gate, and
        # CLAUDE_SANDBOX=0 does not unwrap it. It runs with a profile of its
        # own, ~/.claude-vm-N, provisioned like any other, since claude-vm
        # refuses one holding a login. Its connection picker (leader cvc)
        # launches gh, jira and firebase sessions through claude-vm as well,
        # their flags carried as for claude-sandbox: claude-vm keeps their
        # credentials on the host. figma-mcp, whose key the VM would hold, or
        # no claude-vm on PATH, refuses the launch in the calling shell, before
        # a pane opens. A stand-in claude-vm passes the gate.
        mkdir -p "$HOME/vm/bin"
        printf '#!/bin/sh\n[ "$1" = --check-cwd ]\n' > "$HOME/vm/bin/claude-vm"
        chmod +x "$HOME/vm/bin/claude-vm"
        vm='. ${self}/.config/shell/functions/claude.bash
          __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
          __claude_vm'
        case "$(CLAUDE_SANDBOX=0 PATH=$HOME/vm/bin:${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$vm")" in
          "CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-vm-1 $HOME/vm/bin/claude-vm claude "*)
            if [ -f "$HOME/.claude-vm-1/settings.json" ]; then
              ok "the microVM chord launches claude through claude-vm, with a provisioned profile of its own"
            else
              fail "the microVM chord's profile was not provisioned"
            fi
            ;;
          *) fail "the microVM chord does not launch claude through claude-vm with its own profile" ;;
        esac
        vmconnect='. ${self}/.config/shell/functions/claude.bash
          fzf() { printf "gh\njira\nfirebase\n"; }
          __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
          __claude_vm_connect'
        case "$(PATH=$HOME/vm/bin:${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$vmconnect")" in
          "CLAUDE_SANDBOX_ALLOW_GH=1 CLAUDE_SANDBOX_ALLOW_FIREBASE=1 CLAUDE_SANDBOX_ALLOW_JIRA=1 CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-vm-1 $HOME/vm/bin/claude-vm claude "*)
            ok "the microVM connection picker launches gh, jira and firebase through claude-vm, their flags carried"
            ;;
          *) fail "the microVM connection picker does not launch gh, jira and firebase through claude-vm" ;;
        esac
        vmfigma='. ${self}/.config/shell/functions/claude.bash
          fzf() { printf "figma-mcp\n"; }
          __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
          __claude_vm_connect'
        refusal=$(PATH=$HOME/vm/bin:${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$vmfigma" 2>&1)
        case "$refusal" in
          *"claude-vm claude"*) fail "the microVM connection picker launched figma-mcp, whose key the VM would hold" ;;
          *"does not carry figma-mcp"*) ok "the microVM connection picker refuses figma-mcp, whose key the VM would hold" ;;
          *) fail "the microVM connection picker does not say why it refuses figma-mcp: $refusal" ;;
        esac
        refusal=$(PATH=${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$vm" 2>&1)
        case "$refusal" in
          *"claude-vm not found on PATH"*) ok "the microVM chord refuses to launch without claude-vm" ;;
          *) fail "the microVM chord does not refuse without claude-vm: $refusal" ;;
        esac

        # The review paid by the API credits (__claude_review) runs claude in
        # this pane, since a tmux window would start without the key, hands it
        # the key in its environment, and launches it with Read as its only
        # tool and the repository's settings ignored. Stand-ins for git and pass
        # give it a change to review and a key.
        review='. ${self}/.config/shell/functions/claude.bash
          git() { case $1 in rev-parse) [ "$2" = --show-toplevel ] && pwd || return 1 ;; diff) echo change ;; esac; }
          pass() { echo sk-test; }
          __claude_run() { printf "%s|%s|%s\n" "$TMUX" "$ANTHROPIC_API_KEY" "$__CLAUDE_CMD"; }
          __claude_review'
        case "$(TMUX=x CLAUDE_SANDBOX=0 PATH=${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$review")" in
          "|sk-test|"*" -p --bare --tools Read --setting-sources user --strict-mcp-config --add-dir "*)
            ok "the review runs claude in this pane, with its key in the environment and Read as its only tool"
            ;;
          *) fail "the review does not run claude Read-only, in this pane, with its key in the environment" ;;
        esac

        # The review in the microVM (__claude_vm_review) hands /code-review its
        # arguments and Bash, in this pane, through claude-vm with the Console
        # key's pass entry, on a clone under the cache rather than the
        # repository, and with the bundle rather than the live tree. A stand-in
        # git makes the clone; the stand-in claude-vm above passes the gate.
        vmreview='. ${self}/.config/shell/functions/claude.bash
          git() { case $1 in rev-parse) pwd ;; clone) mkdir -p "''${@[-1]}" ;; esac; }
          __claude_run() { printf "%s|%s|%s|%s|%s|%s\n" "$TMUX" "$CLAUDE_VM_CREDENTIAL_PASS" "''${PERMEANCE_ROOT-unset}" "$PERMEANCE_TREE" "$PWD" "$__CLAUDE_CMD"; }
          export PERMEANCE_ROOT=/live
          __claude_vm_review low src/'
        case "$(TMUX=x XDG_CACHE_HOME=$HOME/cache PATH=$HOME/vm/bin:${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$vmreview")" in
          "|claude/anthropic-api-key|unset|/nix/store/"*"|$HOME/cache/claude-review."*"/claude-vm claude "*" -p --allowedTools Bash --no-session-persistence --max-budget-usd 5 /code-review\ low\ src/  --allow-dangerously-skip-permissions")
            ok "the microVM review runs /code-review with Bash on a clone, in this pane, with the Console key's entry and without the live tree"
            ;;
          *) fail "the microVM review does not run /code-review on a clone with the Console key's entry and without the live tree" ;;
        esac

        # The session eraser (leader cx) hands every marked session to one
        # `claude-sessions rm -ask`, which asks about them all at once. A
        # stand-in fzf, given --multi, marks every row and presses enter: it
        # runs the become() bound to enter on their ids.
        mkdir -p "$HOME/sessions/bin"
        printf '#!/bin/sh\nif [ "$1" = list ]; then printf "a\\tA\\nb\\tB\\n"; else echo "$*"; fi\n' \
          > "$HOME/sessions/bin/claude-sessions"
        chmod +x "$HOME/sessions/bin/claude-sessions"
        erase='. ${self}/.config/shell/functions/claude.bash
          fzf() { for o; do case $o in --multi) m=1 ;; --bind=enter:become*) c=$o ;; esac; done
            [ "$m" ] || return 1; c=''${c#*"become("}; c=''${c%")"}; eval "''${c/"{+1}"/$(cut -f1 | tr "\n" " ")}"; }
          __claude_sessions_rm'
        if [ "$(PATH=$HOME/sessions/bin:$PATH ${self}/bin/zsh -f -c "$erase")" = "rm -ask a b" ]; then
          ok "the session eraser hands claude-sessions rm every marked session at once"
        else
          fail "the session eraser does not hand claude-sessions rm the marked sessions"
        fi

        # The fork picker (leader cf) resumes the picked session under a new
        # session ID: a stand-in fzf picks session a.
        fork='. ${self}/.config/shell/functions/claude.bash
          fzf() { echo a; }
          __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
          __claude_sessions_fork'
        case "$(CLAUDE_SANDBOX=0 PATH=$HOME/sessions/bin:${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$fork")" in
          *" --resume a --fork-session  --allow-dangerously-skip-permissions") ok "the fork picker resumes the picked session as a fork" ;;
          *) fail "the fork picker does not fork the picked session" ;;
        esac

        # The backup (leader css) is claude-sessions backup; its restore (leader
        # csr) resumes each picked session as __claude started it, from its
        # directory, in a window of the tmux session it was in, which it makes
        # again at the current window's size once it is gone, then closes the
        # gaps in the session numbers. A stand-in claude-sessions saved three
        # sessions: one with gh, jira, extra hosts and figma-mcp in session
        # work, a plain one in session gone, and one in no session; a stand-in
        # fzf picks them all, a stand-in tmux knows session work and a 120x40
        # window and prints the windows and sessions it is asked for, and a
        # stand-in renumbering says when it runs. The aliases load first, as in
        # .zshrc, since they expand inside the functions: cd there is __cd,
        # which takes no --.
        mkdir -p "$HOME/restore/bin" "$HOME/proj" "$HOME/proj2" "$HOME/proj3"
        printf 'a\t1\t%s\tgh,jira\tx.example\tnix-lsp,figma-mcp\twork\tA\tshown A\nb\t1\t%s\t-\t-\t-\tgone\tB\tshown B\nc\t1\t%s\t-\t-\t-\t-\tC\tshown C\n' \
          "$HOME/proj" "$HOME/proj2" "$HOME/proj3" > "$HOME/restore/rows"
        printf '#!/bin/sh\ncase $1 in saved) cat "$HOME/restore/rows" ;; *) echo "$*" ;; esac\n' > "$HOME/restore/bin/claude-sessions"
        chmod +x "$HOME/restore/bin/claude-sessions"
        restore='. ${self}/.config/shell/aliases.sh; . ${self}/.config/shell/functions/cd.sh
          . ${self}/.config/shell/functions/claude.bash
          fzf() { cat; }
          tmux() { case $1 in has-session) [ "$3" = "=work" ] ;; display-message) echo "120 40" ;; new-window) shift; printf "%s|" "$@"; echo ;; new-session) printf "%s|" "$@"; echo ;; esac; }
          __tmux_renumber_sessions() { echo renumber; }
          __claude_sessions_save
          TMUX=x __claude_sessions_restore'
        case "$(CLAUDE_SANDBOX=0 PATH=$HOME/restore/bin:${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$restore" | tr '\n' '#')" in
          "backup#-d|-t|=work:|-c|$HOME/proj|CLAUDE_SANDBOX_ALLOW_GH=1 CLAUDE_SANDBOX_ALLOW_JIRA=1 CLAUDE_SANDBOX_NET_ALLOW=x.example "*"/nix-lsp --plugin-dir "*"/figma-mcp "*" --resume a  --allow-dangerously-skip-permissions|#claude: resumed A in $HOME/proj#new-session|-d|-s|gone|-x|120|-y|40|-c|$HOME/proj2|CLAUDE_CODE_SYNTAX_HIGHLIGHT=false "*" claude  --allowedTools "*" --resume b  --allow-dangerously-skip-permissions|#claude: resumed B in $HOME/proj2#-d|-c|$HOME/proj3|CLAUDE_CODE_SYNTAX_HIGHLIGHT=false "*" claude  --allowedTools "*" --resume c  --allow-dangerously-skip-permissions|#claude: resumed C in $HOME/proj3#renumber#")
            ok "the session backup's restore resumes each picked session with its connections and plugins, in its directory and tmux session, which it makes again once it is gone"
            ;;
          *) fail "the session backup's restore does not resume the picked sessions as they were started" ;;
        esac

        # A launch drops what a session can leave for the next one to run: MCP
        # servers in the profile's .claude.json, and the local settings claude
        # does not write itself (hooks here), keeping its permission rules.
        mkdir -p "$HOME/proj/.claude"
        echo '{"mcpServers":{"a":{}},"projects":{"/p":{"mcpServers":{"b":{}}}}}' > "$HOME/.claude-1/.claude.json"
        echo '{"hooks":{},"permissions":{"allow":["Bash(ls)"],"defaultMode":"bypassPermissions"}}' > "$HOME/proj/.claude/settings.local.json"
        launch='. ${self}/.config/shell/functions/claude.bash
          __claude_run() { :; }
          __claude'
        (cd "$HOME/proj" && CLAUDE_SANDBOX=0 PATH=${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$launch" 2>/dev/null)
        if [ "$(${pkgs.jq}/bin/jq -c '[.mcpServers, .projects."/p".mcpServers]' "$HOME/.claude-1/.claude.json")" = '[{},{}]' ] \
          && [ "$(${pkgs.jq}/bin/jq -c . "$HOME/proj/.claude/settings.local.json")" = '{"permissions":{"allow":["Bash(ls)"]}}' ]; then
          ok "a launch drops the MCP servers and local settings a session planted, keeping claude's permission rules"
        else
          fail "a launch keeps what a session planted for the next one"
        fi

        # The same launch removes the user-level instructions a session can
        # plant in its profile, which load into every later session: what
        # sources/.claude does not provide, and skills/ whole (claude downloads
        # its synced ones again at start).
        p=$HOME/.claude-1
        mkdir -p "$p/agents" "$p/skills/x" && : > "$p/agents/a.md" && : > "$p/CLAUDE.md" && : > "$p/skills/x/SKILL.md"
        (cd "$HOME/proj" && CLAUDE_SANDBOX=0 PATH=${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$launch" 2>/dev/null)
        if [ ! -e "$p/agents" ] && [ ! -e "$p/CLAUDE.md" ] && [ ! -e "$p/skills" ] && [ -L "$p/rules" ]; then
          ok "a launch removes the agents, CLAUDE.md and skills a session planted in its profile"
        else
          fail "a launch keeps instructions a session planted in its profile"
        fi

        # A launch runs claude under flock, which locks a file of the launch's
        # own for as long as claude runs, and names the file to claude, whose
        # SessionStart hook writes the session's id into it (claude-sessions
        # mark): a stand-in claude finds the file it was named, in the profile,
        # locked. flock execs into claude rather than wait as its parent, which
        # tmux would name the window after: the stand-in claude runs as the very
        # process a stand-in flock recorded.
        mkdir -p "$HOME/lock/bin"
        printf '#!/bin/sh\necho $$ > "$HOME/lock/pid"\nexec ${pkgs.lib.getBin pkgs.util-linux}/bin/flock "$@"\n' > "$HOME/lock/bin/flock"
        printf '#!/bin/sh\ncase $CLAUDE_SESSIONS_OPEN in "$HOME"/.claude-1/open-sessions/?*) ;; *) exit ;; esac\n[ "$(cat "$HOME/lock/pid")" = $$ ] && printf "exec "\nflock -n "$CLAUDE_SESSIONS_OPEN" true || echo held\n' \
          > "$HOME/lock/bin/claude"
        chmod +x "$HOME/lock/bin/claude" "$HOME/lock/bin/flock"
        locked='. ${self}/.config/shell/functions/claude.bash
          __claude'
        if [ "$(cd "$HOME/proj" && CLAUDE_SANDBOX=0 PATH=$HOME/lock/bin:${pkgs.lib.getBin pkgs.util-linux}/bin:${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$locked" 2>/dev/null)" = "exec held" ]; then
          ok "a launch runs claude in flock's place, under a lock on a file of its own, which it names to claude"
        else
          fail "a launch does not run claude in flock's place, under a lock on a file it names to claude"
        fi

        # The untracked-file preview hands git diff its path after --: git obeys
        # an option even after its paths, so an untracked --output=flake.nix
        # would truncate flake.nix just by being shown.
        untracked='. ${self}/.config/shell/functions/git.bash
          git() { pwd; }
          __git_diff_untracked'
        case "$(${self}/bin/zsh -f -c "$untracked")" in
          *"--no-index --color=always -- /dev/null {} "*) ok "the untracked-file preview hands git diff its path after --" ;;
          *) fail "the untracked-file preview hands git diff its path where an option goes" ;;
        esac

        # ga (__git_pick_files) shows its files and hunks lists without a
        # header: fzf gets no --header, nor a GFS_HEADER_FILES or
        # GFS_HEADER_HUNKS for git-hunk-pick, which its binds run, to change
        # the header to on each switch. The picker's stdout goes nowhere, so
        # the stand-in fzf says what it was handed on stderr.
        ga='. ${self}/.config/shell/functions/git.bash
          git() { :; }; git-hunk-pick() { :; }
          fzf() { printf "%s\n" "$GFS_HEADER_FILES$GFS_HEADER_HUNKS $*" >&2; }
          __git_add'
        case "$(${self}/bin/zsh -f -c "$ga" 2>&1)" in
          *"--header="* | *"--header "*) fail "ga shows its files or hunks list under a header" ;;
          " "*"--read0 --print0"*) ok "ga shows its files and hunks lists without a header" ;;
          *) fail "ga shows its files or hunks list under a header" ;;
        esac

        # gl (__git_log) lists commits numbered from 1, right-aligned, then
        # their change, in its colour, and their author and date flush right,
        # in the row's colours: git lists each commit's files' statuses and
        # pads its subject up to column $COLUMNS - 7 less the number's width
        # (two: the stand-in rev-list counts 10 commits) of a line that starts
        # with them, awk numbers the row, adds the change (a commit that only
        # deletes files: - in bold red), drops the verb it stands for
        # (Delete) and, for a commit of the last hour (the first, two minutes
        # old, not the second), puts how long ago that was in place of its
        # date and time, the row as wide, and fzf shows the number and the
        # change first and them last, skips the number in its search, and
        # hands on the row's hash. Both steps show the
        # preview below the list, in three quarters of fzf's height, with no
        # blank line before the diff: a commit's diff alone, a file's under its
        # path. Both start with the search off, as alt-i leaves it, triggered
        # once (a second would turn the search back on), the file step before
        # it searches with !/$: turning the search off after would cancel that
        # search. The file step's j/k step between matches,
        # f12/f11 adding the 4 more steps of a 5-step move (FZF_DEFAULT_OPTS).
        # Neither binds y, which types into the query as other letters do, nor
        # a key of its own to jump to a row by its label, and neither has a
        # header. Neither cycles: there is no --cycle. The file step hands fzf the
        # commit's tree rows, searched with !/$ so that no directory's row
        # matches, and the count of its files for the info line, and the
        # editor what tree-quote makes of the row numbers fzf accepts, to open
        # in Neovim's own gl on their commit (GL_OPEN=log, GL_COMMIT): the
        # stand-ins pick the commit and a row, and say what they were asked.
        gl='. ${self}/.config/shell/functions/git.bash
          git() { case $1 in log) [ "$*" != "log --no-renames --diff-merges=first-parent --name-status --date=format-local:%y-%m-%d %H:%M --format=%x1e%an, %ad%x1f%h%x1f %<|(91,trunc)%s %x1f%h %s%x1f%at%x1f%ar" ] || printf "\36a, 26-10-25 21:42\37abc\37 Delete f \37abc Delete f\37%s\37%s\n\nD\tf\nD\tg\n\36b, 70-01-01 00:00\37def\37 x \37def x\37%s\37%s\n" $(($(date +%s) - 120)) "2 minutes ago" 0 "56 years ago" ;; rev-list) [ "$*" != "rev-list --count HEAD" ] || echo 10 ;; rev-parse) [ "$2" != --show-cdup ] || echo ../ ;; esac; }
          git-hunk-pick() { case $1 in tree) printf "%s\0" "$*" ;; paths) printf "x\0y\0" ;; tree-quote) printf "%s<%s" "$*" "$(tr "\0" ,)" ;; esac; }
          fzf() { case "$TREE_FILES $*" in *jump* | *"--bind y:"* | *"--header="* | *" --cycle"* | *"trigger(alt-i)"*"trigger(alt-i)"*) ;; "2 "*"--no-cycle "*"start:+trigger(alt-i)"*"--accept-nth={n}"*"start:+search(!/\$)"*"j:trigger(f12)+down-match,k:trigger(f11)+up-match"*"f12:down-match+down-match+down-match+down-match,f11:up-match+up-match+up-match+up-match"*"--info-command="*"show --color=always --format= "*"/^\$/d}"*"--preview-window=down,75%,"*) [ "$(tr "\0" "\n")" = "tree commit abc" ] && printf "4\0" ;; *"--no-cycle "*"start:+trigger(alt-i)"*"show --color=always --format= {3} "*"/^\$/d}"*"--preview-window=down,75%,"*"--ansi --delimiter="?"|^ *[0-9]+  --with-nth={1} {6}{3}{4}{2} --nth=2.. --accept-nth=3"*) awk -F "$(printf "\37")" -v c="$(printf "\33[1;38;2;168;77;95m-\33[0m ")" "\$1 == \" 1\" && \$2 == \"a, 2 minutes ago\" && \$6 == c && \$4 ~ /^ f {9}\$/ { h = \$3 } \$1 == \" 2\" && \$2 == \"b, 70-01-01 00:00\" { print h }" ;; esac; }
          COLUMNS=100 EDITOR=ed __git_log'
        if [ "$(${self}/bin/zsh -f -c "$gl")" = "GL_OPEN=log GL_COMMIT=abc ed -- tree-quote commit abc ../<4," ]; then
          ok "gl lists commits numbered from 1, right-aligned and unsearched, with their change next, in its colour, in place of the verb it stands for, and their author and date flush right in the row's colours, the date how long ago a commit of the last hour was made and an older one's date and time, previews each diff below its list, in three quarters of the height, a commit's alone, starts both lists with the search off, steps the file list's j/k and f12/f11 between matches, no header, no cycling and no y or jump binding of their own, lists the commit's files as tree rows, directories unpickable and uncounted, and opens the files of the rows picked in Neovim's own gl, on their commit"
        else
          fail "gl lists commits without their right-aligned number first, or searches it, or without their change in its colour in place of the verb it stands for, or without their author and date flush right in the row's colours, dates a commit of the last hour other than by how long ago it was made or an older one other than by its date and time, previews a diff beside a list or in other than three quarters of the height, or a commit's under a line, starts a list with the search on or turns the file list's off after its !/$ search, steps the file list's j/k or f12/f11 onto directories, gives a list a header, lets a list cycle, binds y or a jump in a list, or does not hand the rows fzf picks from its tree to tree-quote, or opens their files other than in Neovim's own gl, on their commit"
        fi

        # Given a commit, as Neovim's gl (gl.nvim) runs it on the one picked
        # here, gl lists that commit's files alone: the stand-in fzf picks a
        # row of them only, and another commit from a list of commits.
        glc='. ${self}/.config/shell/functions/git.bash
          git() { case $1 in log) echo commit ;; rev-parse) case $2 in --show-cdup) echo ../ ;; --verify) [ "$*" != "rev-parse --verify --quiet --short abc^{commit}" ] || echo abc ;; esac ;; esac; }
          git-hunk-pick() { case $1 in tree) printf "%s\0" "$*" ;; paths) printf "x\0" ;; tree-quote) printf "%s<%s" "$*" "$(tr "\0" ,)" ;; esac; }
          fzf() { case "$*" in *"--accept-nth={n}"*) [ "$(tr "\0" "\n")" = "tree commit abc" ] && printf "4\0" ;; *) echo def ;; esac; }
          EDITOR=ed __git_log abc'
        if [ "$(${self}/bin/zsh -f -c "$glc")" = "GL_OPEN=log GL_COMMIT=abc ed -- tree-quote commit abc ../<4," ]; then
          ok "gl given a commit (Neovim's gl, on the one picked) lists that commit's files alone"
        else
          fail "gl given a commit lists the commits first, or the files of another"
        fi

        # Commits marked with Tab (--multi): their files in one list, each
        # commit's tree under a row of its own that no search matches (!^●),
        # and tree-quote gets each commit's picks numbered from its own first
        # row, past the rows before it (the stand-in picks the second and the
        # fourth); the files open in Neovim's own gl on all of the commits
        # (GL_COMMITS), from the first file's (GL_COMMIT).
        glm='. ${self}/.config/shell/functions/git.bash
          git() { case $1 in log) [ "$2" != --no-walk ] || printf "abc\37A\ndef\37D\n" ;; rev-parse) echo ../ ;; esac; }
          git-hunk-pick() { case $1 in tree) printf "t\37%s\0" "$3" ;; paths) printf "x\0" ;; tree-quote) printf "%s<%s" "$3" "$(tr "\0" ,)" ;; esac; }
          fzf() { case "$*" in *"search(!/\$ !^●)"*) cat >/dev/null; printf "1\n3\n" ;; *--multi*) printf "abc\ndef\n" ;; esac; }
          EDITOR=ed __git_log'
        if [ "$(${self}/bin/zsh -f -c "$glm")" = "GL_OPEN=log GL_COMMIT=abc GL_COMMITS='abc def' ed -- abc<0, def<0," ]; then
          ok "gl lists the files of the commits marked with Tab in one list, a row over each commit's, and opens those picked in Neovim's own gl on all of the commits"
        else
          fail "gl takes one commit only, or lists the files of several without a row over each that no search matches, or opens them other than in Neovim's own gl on all of the commits"
        fi

        # gda, gdc and gdd (__git_diff) lay out a path's row as gl lays out a
        # commit's: numbered from 1, right-aligned, then the path's change,
        # in its colour (gdc's is the staged one: - in bold red for a deleted
        # file, ~ in bold blue for a changed one, + in bold green for a new
        # one, which git status doesn't list), and its author and date flush
        # right, at column $COLUMNS - 3: how long ago a file saved in the
        # last hour was saved, in git's words (100 seconds: 2 minutes ago),
        # an older one's date and time, and nothing for a file that is gone.
        # fzf searches the path only and prints it as is: the real fzf,
        # filtering for a 1, picks the one path with a 1 in it, not the paths
        # numbered 1 and 10, nor those dated 1970, and the stand-in quote
        # shows what it got. A stand-in git on PATH answers the git status
        # and user.name that awk asks for.
        mkdir -p "$HOME/gd/bin"
        (cd "$HOME/gd" && touch -d @0 b c d e f g h j && touch -d "@$(($(date +%s) - 100))" "i 1")
        printf '#!/bin/sh\ncase $1 in config) echo u ;; *) printf "%%s\\0" "D   a" "M  b" ;; esac\n' > "$HOME/gd/bin/git"
        chmod +x "$HOME/gd/bin/git"
        gdc='. ${self}/.config/shell/functions/git.bash
          git() { [ "$2" != --show-toplevel ] || echo "$HOME/gd"; }
          git-hunk-pick() { case $1 in paths) printf "%s\0" " a" b c d e f g h "i 1" j ;; quote) tr "\0" , ;; esac; }
          fzf() { tee "$HOME/gdc" | ${pkgs.fzf}/bin/fzf --filter=1 "$@"; }
          COLUMNS=40 EDITOR=ed __git_diff staged'
        if [ "$(PATH=$HOME/gd/bin:$PATH TZ=UTC ${self}/bin/zsh -f -c "$gdc")" = "GL_OPEN=staged ed -- i 1," ] \
          && [ "$(tr '\0\37' '\n:' < "$HOME/gdc" | sed -n '1p;2p;9p')" = "$(printf ' a:\33[1;38;2;168;77;95m-\33[0m :%29su: 1\nb:\33[1;38;2;58;93;153m~\33[0m :%14su, 70-01-01 00:00: 2\ni 1:\33[1;38;2;47;143;83m+\33[0m :%13su, 2 minutes ago: 9' "" "" "")" ]; then
          ok "gda, gdc and gdd number their paths from 1, right-aligned, show each one's change in its colour and its author and date flush right, the date how long ago a file saved in the last hour was saved and an older one's date and time, search the paths only and hand on the path picked as is"
        else
          fail "gda, gdc or gdd lists its paths without a right-aligned number, its change in its colour or its author and date flush right, dates a file saved in the last hour other than by how long ago it was saved or an older one other than by its date and time, searches more than the path or hands on more than the path picked"
        fi

        # gdd and gda open the paths picked in Neovim as gdc does, each in its
        # own picker there (gl.nvim): GL_OPEN names it by the kind of path.
        if [ "$(PATH=$HOME/gd/bin:$PATH TZ=UTC ${self}/bin/zsh -f -c "''${gdc% staged} unstaged")" = "GL_OPEN=unstaged ed -- i 1," ] \
          && [ "$(PATH=$HOME/gd/bin:$PATH TZ=UTC ${self}/bin/zsh -f -c "''${gdc% staged}")" = "GL_OPEN=changed ed -- i 1," ]; then
          ok "gdd and gda open the paths picked in Neovim's own gdd and gda (GL_OPEN=unstaged, changed)"
        else
          fail "gdd or gda opens the paths picked in Neovim without naming its own picker there (GL_OPEN=unstaged, changed)"
        fi

        # grs (__git_reset_soft) numbers its commits from 1, for HEAD,
        # right-aligned, and fzf searches past the number: the real fzf,
        # filtering for a 1, picks the one commit with a 1 in it, the 10th,
        # and grs resets 10 commits.
        grs='. ${self}/.config/shell/functions/git.bash
          git() { case $1 in log) printf "%s x\n" a b c d e f g h i && echo "j 1" ;; rev-list) [ "$4" != j..HEAD ] || echo 9 ;; esac; }
          fzf() { tee "$HOME/grs" | ${pkgs.fzf}/bin/fzf --filter=1 "$@"; }
          __git_reset_soft'
        if [ "$(${self}/bin/zsh -f -c "$grs")" = "git reset --soft HEAD~10 " ] && [ "$(sed -n '1p;10p' "$HOME/grs")" = "$(printf ' 1 a x\n10 j 1')" ]; then
          ok "grs numbers its commits from 1, for HEAD, right-aligned and unsearched, and row n resets n commits"
        else
          fail "grs lists its commits without a right-aligned number from 1, searches it, or resets other than the commits up to the row picked"
        fi

        # The other git pickers open as gl does, with the options they share
        # (_GIT_FZF_BASE, which git-branches' pickers get too, and
        # _GIT_FZF_PREVIEW_WINDOW): the search off, alt-i triggered once, the
        # cursor stopping at either end of the list, and the preview below
        # it, in three quarters of fzf's height. grs stands for them: its
        # stand-in fzf picks the commit only when asked for all of that.
        like_gl='. ${self}/.config/shell/functions/git.bash
          git() { case $1 in log) echo "abc x" ;; rev-list) echo 0 ;; esac; }
          fzf() { case "$*" in *" --cycle"* | *"trigger(alt-i)"*"trigger(alt-i)"*) ;; *"--no-cycle "*"--bind=start:+trigger(alt-i) "*"--preview-window=down,75%,border-top,"*) head -n 1 ;; esac; }
          __git_reset_soft'
        if [ "$(${self}/bin/zsh -f -c "$like_gl")" = "git reset --soft HEAD~1 " ]; then
          ok "the git pickers start with the search off, stop at either end of their list and preview below it, as gl does"
        else
          fail "a git picker starts with the search on, cycles, or previews beside its list"
        fi

        # Run from the leader (a zle widget), both of gl's steps are typed on
        # the prompt's line: fzf's prompt is the last line of the shell's, as
        # the shell drew it. Each step leaves its last frame up (--no-clear)
        # and reads its whole list before it starts (--sync), so that the line
        # doesn't go blank between frames. (The stand-ins hand on whole rows:
        # the commit the line names is one.)
        glw='. ${self}/.config/shell/functions/git.bash
          git() { [ "$1" != log ] || printf "\36abc subject\n"; }
          git-hunk-pick() { case $1 in tree) echo row ;; tree-quote) cat ;; esac; }
          fzf() { case "$*" in *"--prompt=two% --no-bold --color=query:bold --no-clear --sync"*) head -n 1 ;; esac; }
          WIDGET=leader PS1=$(print "one\ntwo%%") EDITOR=ed __git_log'
        case "$(${self}/bin/zsh -f -c "$glw")" in
          "GL_OPEN=log GL_COMMIT="*" ed -- row")
            ok "gl run from the leader takes the prompt's line for its input, without blanking it as its steps start"
            ;;
          *) fail "gl run from the leader opens its input under the prompt's line, or blanks that line as its steps start" ;;
        esac

        # __open_file hands the editor its picks after --: nvim runs a +cmd
        # argument, so a file named "+so x.vim" would source x.vim.
        mkdir -p "$HOME/pick" && : > "$HOME/pick/+so x.vim"
        printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$HOME/stub/ed" && chmod +x "$HOME/stub/ed"
        pick='. ${self}/.config/shell/functions/fm.sh
          fd() { printf "+so x.vim\0"; }
          fzf() { tr "\0" "\n"; }
          __open_file'
        if [ "$(cd "$HOME/pick" && EDITOR=$HOME/stub/ed ${self}/bin/zsh -f -c "$pick")" = "$(printf -- '--\n+so x.vim')" ]; then
          ok "__open_file hands the editor its picks after --"
        else
          fail "__open_file hands the editor its picks where an option goes"
        fi

        # __open_recent offers nvim's oldfiles newest first, read from the
        # viminfofile the nvim config keeps under $XDG_CACHE_HOME: a stand-in
        # nvim answers for that file only, a stand-in fzf picks the first line.
        touch "$HOME/a" "$HOME/b"
        recent='. ${self}/.config/shell/functions/fm.sh
          nvim() {
            if [ "$1 $2 $3" = "-es -i $XDG_CACHE_HOME/nvim/viminfo" ]; then
              printf "1: %s\n2: %s\n" "$HOME/b" "$HOME/a" > "''${4#+redir! > }"
            else
              printf "%s\n" "$*"
            fi
          }
          fzf() { head -n 1; }
          __open_recent'
        if [ "$(XDG_CACHE_HOME=$HOME/cache ${self}/bin/zsh -f -c "$recent")" = "$HOME/b" ]; then
          ok "__open_recent offers nvim's recent files newest first"
        else
          fail "__open_recent does not offer nvim's recent files newest first"
        fi

        # Shift+Space types a space, as Space does (zsh -i also prints .zshrc's
        # timing line, hence the case).
        case "$(${self}/bin/zsh -i -c 'bindkey "^[[32;2u"' 2>/dev/null)" in
          *'"^[[32;2u" " "'*) ok "the bundled .zshrc has Shift+Space type a space" ;;
          *) fail "the bundled .zshrc does not have Shift+Space type a space" ;;
        esac

        # Home/End work in Alacritty and in tmux, which send them differently.
        case "$(${self}/bin/zsh -i -c 'for k in "^[[H" "^[[1~" "^[[F" "^[[4~"; do bindkey "$k"; done' 2>/dev/null)" in
          *'"^[[H" beginning-of-line'*'"^[[1~" beginning-of-line'*'"^[[F" end-of-line'*'"^[[4~" end-of-line'*) ok "Home/End are bound as Alacritty and tmux send them" ;;
          *) fail "Home/End are unbound as Alacritty or tmux sends them" ;;
        esac

        # In every fzf picker (FZF_DEFAULT_OPTS), nothing is bound to f or y,
        # so that they type into the query with the search on or off, and no
        # key labels the rows to jump to one.
        fzf_opts=$(${self}/bin/zsh -i -c 'print -r -- "$FZF_DEFAULT_OPTS"' 2>/dev/null)
        case "$fzf_opts" in
          *jump* | *"'f:"* | *",f:"* | *"'y:"* | *",y:"*) fail "f or y does not type into every fzf picker's query, or a key labels the rows to jump to one" ;;
          *"start:unbind("*) ok "f and y type into every fzf picker's query with the search on or off, and no key labels the rows to jump to one" ;;
          *) fail "the fzf pickers' options are not set" ;;
        esac

        # With the search off, j/k move 1 row or 5: ctrl-j/k switch f12/f11,
        # which add the 4 more rows, and press j/k; from the search they turn
        # it off and unbind f12/f11, and so does every switch of the search.
        case "$fzf_opts" in
          *'+unbind(f12,f11)+trigger(j)" || echo "toggle-bind(f12,f11)+trigger(j)"'*"j:trigger(f12)+down,k:trigger(f11)+up"*"f12:down+down+down+down,f11:up+up+up+up"*"i:toggle-search+toggle-bind(j,k,g,G,i,q)+unbind(f12,f11)"*"start:unbind(j,k,g,G,i,q,f12,f11)"*) ok "with the search off, each ctrl-j/k switches j/k between 1 and 5 rows and moves one step, and the search's switches reset them to 1" ;;
          *) fail "ctrl-j/k do not switch j/k between 1 and 5 rows with the search off, or a switch of the search keeps the 5-row step" ;;
        esac

        # forgit's pickers (gkf, gbm, …) open as the git pickers do: the
        # search off, the cursor stopping at either end of the list, and the
        # preview below it.
        case "$(${self}/bin/zsh -i -c 'print -r -- "$FORGIT_FZF_DEFAULT_OPTS"' 2>/dev/null)" in
          *" --cycle"*) fail "forgit's pickers wrap around at the ends of their list" ;;
          *"--no-cycle "*"--preview-window down,75%,border-top,"*"start:+trigger(alt-i)"*) ok "forgit's pickers start with the search off, stop at either end of their list and preview below it, as the git pickers do" ;;
          *) fail "forgit's pickers start with the search on or preview beside their list" ;;
        esac

        # Shift+Tab's search (fm_rg.sh) lists dotfiles too, as the rows fm.sh's
        # binds read: a header per file, then each match; fields 2-4 are path,
        # line, H|M. It skips .git, even with a plain rg like this one.
        mkdir -p "$HOME/rg/.hidden" "$HOME/rg/.git" && printf 'x\nhello world\n' | tee "$HOME/rg/.git/config" > "$HOME/rg/.hidden/a.txt"
        rgrows() { (cd "$1" && PATH=${pkgs.ripgrep}/bin:${fmQuery}/bin:$PATH sh ${self}/.config/shell/scripts/fm_rg.sh 'hel wor' | cut -f2-4); }
        if [ "$(rgrows "$HOME/rg")" = "$(printf '.hidden/a.txt\t2\tH\n.hidden/a.txt\t2\tM')" ]; then
          ok "Shift+Tab's search lists a dotfile's match under its header, with its path and line, and skips .git"
        else
          fail "Shift+Tab's search does not list a dotfile's match as header and match rows, or lists .git"
        fi

        # In $HOME it also skips $HOME's own big trees (fm_home.ignore), whose
        # patterns rg anchors at its working directory: anywhere else they
        # would hide a project's own go/pkg.
        mkdir -p "$HOME/go/pkg" "$HOME/rg/go/pkg" && printf 'hello world\n' | tee "$HOME/go/pkg/c.txt" > "$HOME/rg/go/pkg/b.txt"
        if rgrows "$HOME/rg" | cut -f1 | grep -qx go/pkg/b.txt && ! rgrows "$HOME" | cut -f1 | grep -qx go/pkg/c.txt; then
          ok "Shift+Tab's search skips \$HOME's own go/pkg in \$HOME only, not a project's"
        else
          fail "Shift+Tab's search lists \$HOME's own go/pkg in \$HOME, or skips a project's"
        fi

        # Its preview strips a file's escape sequences (an OSC 8 link here), so
        # nothing in a searched file can drive the terminal through fzf.
        printf 'x \033]8;;http://e.x\033\\link\033]8;;\033\\ y\n' > "$HOME/esc.txt"
        if FZF_PREVIEW_LINES=10 sh ${self}/.config/shell/scripts/fm_preview.sh "$HOME/esc.txt" 1 "" | grep -q "$(printf '\033]')"; then
          fail "the search preview passes a file's escape sequences to fzf"
        else
          ok "the search preview strips a file's escape sequences"
        fi

        # It never puts the previewed file in tree-sitter's working directory,
        # where a tree-sitter.json is read as a grammar's: a stand-in
        # tree-sitter says whether it finds one there.
        mkdir -p "$HOME/ts/bin" && printf '{}\n' > "$HOME/ts/tree-sitter.json"
        printf '#!/bin/sh\n[ -e tree-sitter.json ] && echo GRAMMAR\nexit 0\n' > "$HOME/ts/bin/tree-sitter" && chmod +x "$HOME/ts/bin/tree-sitter"
        if FZF_PREVIEW_LINES=10 PATH="$HOME/ts/bin:$PATH" sh ${self}/.config/shell/scripts/fm_preview.sh "$HOME/ts/tree-sitter.json" 1 "" | grep -q GRAMMAR; then
          fail "the search preview puts a tree-sitter.json in tree-sitter's working directory"
        else
          ok "the search preview keeps the previewed file out of tree-sitter's working directory"
        fi

        # The bundled .zshrc loads and binds Shift+Tab to that search (zsh -i
        # also prints .zshrc's timing line, hence the case).
        case "$(${self}/bin/zsh -i -c 'bindkey "^[[Z"' 2>/dev/null)" in
          *'"^[[Z" __ripgrep_or_menu_'*) ok "the bundled .zshrc binds Shift+Tab to the search" ;;
          *) fail "the bundled .zshrc does not bind Shift+Tab to the search" ;;
        esac

        # On a typed line, Tab fills in a suggestion showing at the end of the
        # line; with the cursor inside the line, or no suggestion yet, it opens
        # the completion menu, and it never runs the line. Outside zle the test
        # sets the line itself, and a stand-in zle records the widgets called.
        tabs='zle() { print -r -- "zle $*"; }
          BUFFER="git sta" POSTDISPLAY=tus CURSOR=7; __tab_handler
          BUFFER="git sta" POSTDISPLAY=tus CURSOR=3; __tab_handler
          BUFFER="git sta" POSTDISPLAY= CURSOR=7; __tab_handler'
        case "$(${self}/bin/zsh -i -c "$tabs" 2>/dev/null)" in
          *"$(printf 'zle autosuggest-accept\nzle redisplay\nzle menu-select\nzle menu-select')") ok "Tab fills in a suggestion showing at the end of the line, and otherwise opens the completion menu" ;;
          *) fail "Tab does not fill in a suggestion showing at the end of the line, or does not open the completion menu otherwise" ;;
        esac

        # Alt+H asks Claude Haiku to explain the typed line: the line reaches
        # claude on stdin as text, never run, with what the shell says its
        # words are (a function's code too), and claude runs with no tools,
        # nothing saved, only the user's settings and no CLAUDE_CONFIG_DIR, so
        # with the host's own profile, signed in with pass's claude/oauth-token
        # in its environment, read with bracketed paste off so that a pasted
        # passphrase reaches gpg as is; its answer shows under the line. A
        # line that looks like it holds a secret is not sent, and Alt+Shift+H
        # is still zsh's run-help, which hands the command to man. Stand-ins:
        # a claude that records what it got, pass, a zle that prints -M
        # messages, man.
        mkdir -p "$HOME/explain/bin"
        printf '#!/bin/sh\necho "config=$CLAUDE_CONFIG_DIR token=$CLAUDE_CODE_OAUTH_TOKEN $*" > "$HOME/explain/args"\ncat > "$HOME/explain/stdin"\necho It lists commits.\n' > "$HOME/explain/bin/claude"
        printf '#!/bin/sh\n[ "$*" = "show claude/oauth-token" ] && echo sk-ant-oat01-fake\n' > "$HOME/explain/bin/pass"
        chmod +x "$HOME/explain/bin/claude" "$HOME/explain/bin/pass"
        explain='path=($HOME/explain/bin $path); export CLAUDE_CONFIG_DIR=$HOME/.claude-1
          zle() { [[ $1 != -M ]] || print -r -- "M: $argv[-1]"; }
          man() { print -r -- "man $*"; }
          bindkey "^[h"; bindkey "^[H"
          BUFFER="echo \$(touch $HOME/ran) | __copy"; __explain_line
          BUFFER="export GH_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxx"; __explain_line
          run-help rsync'
        explained=$(${self}/bin/zsh -i -c "$explain" 2>/dev/null || :; cat "$HOME/explain/args" "$HOME/explain/stdin" 2>/dev/null || :)
        case "$explained" in
          *'"^[h" __explain_line'*'"^[H" run-help'*'[?2004l'*'[?2004h'*'M: It lists commits.'*'M: Not sent: the line looks like it holds a secret.'*'man rsync'*'config= token=sk-ant-oat01-fake -p '*'--tools  --strict-mcp-config --no-session-persistence --setting-sources user '*'Command line: echo $(touch '*'/ran) | __copy'*'__copy () {'*)
            if [ -e "$HOME/ran" ]; then
              fail "Alt+H ran the typed line it was to explain"
            else
              ok "Alt+H has Claude Haiku explain the typed line, sent as text with what its words are to a claude with no tools, nothing saved, the host's profile and the token in pass, shows the answer under the line and holds back a line that looks like a secret, and Alt+Shift+H is still run-help"
            fi ;;
          *) fail "Alt+H does not send the typed line as text with what its words are to a tool-less claude, does not show the answer under the line or sends a secret, or Alt+Shift+H is no longer run-help: $explained" ;;
        esac

        # The search binds nothing to y either, so that y types into its query:
        # a stand-in fzf says whether it was handed a binding for y.
        rgy='. ${self}/.config/shell/functions/fm.sh
          fzf() { case "$*" in *"--bind y:"* | *",y:"*) echo y >&2 ;; *) echo none >&2 ;; esac; return 130; }
          __ripgrep'
        if [ "$(${self}/bin/zsh -f -c "$rgy" 2>&1)" = none ]; then
          ok "Shift+Tab's search binds nothing to y, which types into its query"
        else
          fail "Shift+Tab's search binds y, which then does not type into its query"
        fi

        # Several picks open as a quickfix list set from them as they are (nvim
        # -q would read them back through 'errorformat', which misreads many
        # lines), with absolute paths; a picked header stands for its file's
        # first match, another file's match picked or not. A runtime dir that
        # is set but missing gives way to TMPDIR.
        mkdir -p "$HOME/qf"
        rgqf='. ${self}/.config/shell/functions/fm.sh
          fzf() { printf "b.txt\tb.txt\t2\tH\n  3:x\tc.txt\t3\tM\n"; }
          __ripgrep'
        if [ "$(cd "$HOME/qf" && XDG_RUNTIME_DIR=$HOME/missing ${self}/bin/zsh -f -c "$rgqf")" = "nvim -c 'call setqflist([{\"filename\": \"$HOME/qf/b.txt\", \"lnum\": 2}, {\"filename\": \"$HOME/qf/c.txt\", \"lnum\": 3}])' -c cfirst" ]; then
          ok "Shift+Tab's search opens several picks, a header among them, as a quickfix list with absolute paths"
        else
          fail "Shift+Tab's search does not open several picks as a quickfix list set from them, with absolute paths"
        fi

        # The empty-prompt shortcuts (Shift+Delete, Esc, Shift+Esc) fire only at
        # the prompt itself, where zle sets CONTEXT to start. The line is empty
        # on a continuation line (cont), in a select menu (select) and in vared
        # (vared) too, and there they must leave it alone. Outside zle the test
        # sets CONTEXT itself; the shortcut fails on purpose, since a success
        # would run the prompt's precmd hooks.
        contexts='BUFFER=
          for CONTEXT in cont select vared start; do
            __on_empty_buffer "print EMPTY; false" "print LINE"
          done'
        case "$(${self}/bin/zsh -i -c "$contexts" 2>/dev/null | tr '\n' ' ')" in
          *"LINE LINE LINE EMPTY ") ok "the empty-prompt shortcuts fire only at the prompt, not on a continuation line, in a select menu or in vared" ;;
          *) fail "an empty-prompt shortcut fires on a continuation line, in a select menu or in vared, or not at the prompt" ;;
        esac

        # The tools' completions, which the alacritty launcher exports as one
        # directory, go on fpath.
        case "$(TERMINAL_ZSH_COMPLETIONS=/tools-completions ${self}/bin/zsh -i -c 'print -l -- $fpath' 2>/dev/null)" in
          *"/tools-completions"*) ok "the tools' completions directory is on fpath" ;;
          *) fail "the tools' completions directory is not on fpath" ;;
        esac

        # hs (__home_manager_switch) refreshes the home-manager flake's local
        # inputs before switching: path: ones and git+file: ones, never remote
        # ones. A stand-in nix answers the metadata query and prints each input
        # it is asked to update.
        printf '%s' '{"locks":{"nodes":{"root":{"inputs":{"f":"f","n":"n","t":"t"}},"f":{"locked":{"type":"git","url":"file:///f","ref":"main"}},"n":{"locked":{"type":"git","url":"https://n"}},"t":{"locked":{"type":"path","path":"/t"}}}}}' > "$HOME/hm.json"
        hmswitch='. ${self}/.config/shell/functions/nix.sh
          nix() { case "$2" in metadata) cat "$HOME/hm.json" ;; update) printf "%s\n" "$5" ;; esac; }
          home-manager() { :; }
          __home_manager_switch'
        if [ "$(PATH=${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$hmswitch")" = "$(printf 'f\nt')" ]; then
          ok "hs refreshes the home-manager flake's local path: and git+file: inputs, not remote ones"
        else
          fail "hs does not refresh exactly the home-manager flake's local inputs"
        fi
      '';
    };
  };
in
self
