{
  pkgs,
  files,
  permeance,
  claude,
}:

let
  # The leader-key picker (.config/shell/functions/aliases.sh) renders the
  # bundled .config/shell/leader.conf through this binary, and __leader_edit
  # lines it up with it; the smoke test exercises both against the wrapper's
  # own copy of the table.
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
      description = "Verify zsh wrapper exec's the real binary, a login shell started through it is one, the leader table renders, gc's secret › set reads its value silently and hands it to gcloud on stdin, oa edits the leader table in a copy that reaches it only valid and lined up, the leader picker renders once per width and edit and dispatches each kind of pick with bare redraws, god/godc name and clear Go dev builds, bundled mode provisions the claude profile with its sandbox overlay, failing closed, the claude connection picker launches what was picked, the session eraser hands every marked session to one claude-sessions rm, the fork picker resumes the picked session as a fork, the session backup's restore resumes each picked session as it was started, in its tmux session, a launch drops what a session planted for the next one, in the project and in its profile, the untracked-file preview and __open_file pass paths after --, ga shows its files and hunks lists without a header, gl's file step lists a commit as tree rows with unpickable, uncounted directories and opens the picked rows' files, empty-prompt shortcuts leave continuation lines alone, the tools' completions are on fpath, __open_recent offers nvim's recent files newest first, Shift+Tab is bound to a search that lists a dotfile's matches as header and match rows and previews them without the file's escape sequences, and hs refreshes the home-manager flake's local path: and git+file: inputs";
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

        # The picker renders the table once per shell and width: a second press
        # reuses the rows, a resize or an edited table renders them again. A
        # stand-in leader-aliases counts the renders.
        mkdir -p "$HOME/leader/bin"
        cp ${self}/.config/shell/leader.conf "$HOME/leader/leader.conf"
        chmod u+w "$HOME/leader/leader.conf"
        printf '#!/bin/sh\necho >> "%s"\nexec %s "$@"\n' "$HOME/leader/renders" ${leaderAliases}/bin/leader-aliases > "$HOME/leader/bin/leader-aliases"
        chmod +x "$HOME/leader/bin/leader-aliases"
        rows='. ${self}/.config/shell/functions/aliases.sh
          t=$HOME/leader/leader.conf
          COLUMNS=100; __aliases_rows "$t"; first=$REPLY
          __aliases_rows "$t"; [ "$REPLY" = "$first" ] && print same
          COLUMNS=90; __aliases_rows "$t"
          print "# edited" >> "$t"; __aliases_rows "$t"'
        if [ "$(PATH=$HOME/leader/bin:$PATH ${self}/bin/zsh -f -c "$rows")" = same ] \
          && [ "$(wc -l < "$HOME/leader/renders")" -eq 3 ]; then
          ok "the leader picker renders its table once, then again only after a resize or an edit"
        else
          fail "the leader picker does not reuse its rows until a resize or an edit"
        fi

        # oa (__leader_edit) edits the table in a copy that reaches it only
        # valid and lined up: a stand-in editor adds a line with an unknown
        # mode, then, reopened at that line, fixes it.
        printf '[git]\ngt  run  status  git status\n' > "$HOME/leader/edit.conf"
        printf '#!/bin/sh\necho "$*" >> "%s"\nfor f; do :; done\ncase $1 in\n  --) echo "zz  rnu  sleep  sleep 1" >> "$f" ;;\n  +3) sed "s/ rnu / run /" "$f" > "$f.new" && cat "$f.new" > "$f" ;;\nesac\n' \
          "$HOME/leader/edits" > "$HOME/leader/bin/edit"
        chmod +x "$HOME/leader/bin/edit"
        edit='. ${self}/.config/shell/functions/aliases.sh; __leader_edit "$HOME/leader/edit.conf"'
        if echo y | EDITOR=edit PATH=$HOME/leader/bin:$PATH ${self}/bin/zsh -f -c "$edit" 2>/dev/null \
          && [ "$(cat "$HOME/leader/edit.conf")" = "$(printf '[git]\ngt \trun \tstatus \tgit status\nzz \trun \tsleep  \tsleep 1')" ] \
          && [ "$(awk '{ print $1 }' "$HOME/leader/edits" | tr '\n' ' ')" = "-- +3 " ]; then
          ok "oa reopens the table copy at a broken line and writes it back lined up"
        else
          fail "oa does not reopen a broken line, or writes the table back broken or unaligned"
        fi

        # The picker reads its pick without starting a process, and as it
        # always fails, __on_empty_buffer only redraws the line: reset-prompt
        # would re-expand the prompt, rerunning starship twice, before an
        # accepted command even starts. Nor does an accepted line fetch a
        # suggestion. A stand-in zle records the widgets called; a stand-in fzf
        # prints what fzf --print-query would, the query and the chord's row.
        # leader-aliases goes on the path inside the script: zsh -i reads
        # /etc/zshenv, and nix-darwin's (in an unsandboxed build) resets PATH.
        stubs='path=(${leaderAliases}/bin $path)
          zle() { print -r -- "zle $*"; }
          pick() { print -r -- "^$1"; grep -m 1 "^$1 *$SEP"; }
          __nix_package() { print -r -- "nix $1 nixpkgs#hello"; }'
        picker() {
          SEP=$sep ${self}/bin/zsh -i -c "$stubs
            $1"'
            BUFFER= PREBUFFER=; __on_empty_buffer __aliases :
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
        picked=$(picker 'fzf() { print -r -- "^zz"; return 1; }')
        case "$picked" in
          *"$(printf 'zle autosuggest-fetch\nzle redisplay\nLBUFFER=zz')") ok "a chord that matches nothing is inserted as typed, without its ^" ;;
          *) fail "a chord that matches nothing is not inserted as typed: $picked" ;;
        esac

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
        # the claude wrapper's, with this OS's sandbox overlay merged in; an overlay
        # that does not merge refuses the launch instead.
        os=$(uname -s | tr '[:upper:]' '[:lower:]')
        provision='. ${self}/.config/shell/functions/claude.bash; __claude_instance=1; __claude_provision_config'
        if PATH=${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$provision" \
          && [ "$(${pkgs.jq}/bin/jq -c .sandbox "$HOME/.claude-1/settings.json")" \
            = "$(${pkgs.jq}/bin/jq -c .sandbox ${claude}/.claude/settings.$os.json)" ]; then
          ok "bundled mode provisions the claude profile with the $os sandbox overlay"
        else
          fail "bundled mode does not provision the claude profile with its sandbox overlay"
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
          *" --resume a --fork-session ") ok "the fork picker resumes the picked session as a fork" ;;
          *) fail "the fork picker does not fork the picked session" ;;
        esac

        # The backup (leader cb) is claude-sessions backup; its restore (leader
        # cbr) resumes each picked session as __claude started it, from its
        # directory, in a window of the tmux session it was in while that is
        # still there. A stand-in claude-sessions saved two sessions, one with
        # gh, jira, extra hosts and figma-mcp, the other plain; a stand-in fzf
        # picks both, a stand-in tmux knows session work and prints the windows
        # it is asked for.
        mkdir -p "$HOME/restore/bin" "$HOME/proj" "$HOME/proj2"
        printf 'a\t1\t%s\tgh,jira\tx.example\tnix-lsp,figma-mcp\twork\tA\tshown A\nb\t1\t%s\t-\t-\t-\tgone\tB\tshown B\n' \
          "$HOME/proj" "$HOME/proj2" > "$HOME/restore/rows"
        printf '#!/bin/sh\ncase $1 in saved) cat "$HOME/restore/rows" ;; *) echo "$*" ;; esac\n' > "$HOME/restore/bin/claude-sessions"
        chmod +x "$HOME/restore/bin/claude-sessions"
        restore='. ${self}/.config/shell/functions/claude.bash
          fzf() { cat; }
          tmux() { case $1 in has-session) [ "$3" = "=work" ] ;; new-window) shift; printf "%s|" "$@"; echo ;; esac; }
          __claude_sessions_backup
          TMUX=x __claude_sessions_restore'
        case "$(CLAUDE_SANDBOX=0 PATH=$HOME/restore/bin:${pkgs.jq}/bin:$PATH ${self}/bin/zsh -f -c "$restore" | tr '\n' '#')" in
          "backup#-d|-t|=work:|-c|$HOME/proj|CLAUDE_SANDBOX_ALLOW_GH=1 CLAUDE_SANDBOX_ALLOW_JIRA=1 CLAUDE_SANDBOX_NET_ALLOW=x.example "*"/nix-lsp --plugin-dir "*"/figma-mcp "*" --resume a |#claude: resumed A in $HOME/proj#-d|-c|$HOME/proj2|CLAUDE_CODE_SYNTAX_HIGHLIGHT=false "*" claude  --allowedTools "*" --resume b |#claude: resumed B in $HOME/proj2#")
            ok "the session backup's restore resumes each picked session with its connections and plugins, in its directory and tmux session"
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

        # gl (__git_log) lists commits with their author and date flush right,
        # in the row's colours: git pads each subject up to column $COLUMNS - 4
        # of a line that starts with them and prints no colour codes, and fzf
        # shows them last and hands on the row's hash. Both steps show the
        # preview below the list, in three quarters of fzf's height, with no
        # blank line before the diff: a commit's diff alone, a file's under its
        # path. Both start with the search off, as alt-i leaves it, the file
        # step before it searches with !/$: turning the search off after would
        # cancel that search. The file step hands fzf the commit's tree rows,
        # searched with !/$ so that no directory's row matches, and the count
        # of its files for the info line, and the editor what tree-quote makes
        # of the row numbers fzf accepts: the stand-ins pick the commit and a
        # row, and say what they were asked.
        gl='. ${self}/.config/shell/functions/git.bash
          git() { case $1 in log) [ "$*" != "log --format=%an, %ar%x1f%h%x1f %<|(96,trunc)%s %x1f%h %s" ] || printf "a, now\37abc\37 subject \37abc subject\n" ;; rev-parse) [ "$2" != --show-cdup ] || echo ../ ;; esac; }
          git-hunk-pick() { case $1 in tree) printf "%s\0" "$*" ;; paths) printf "x\0y\0" ;; tree-quote) printf "%s<%s" "$*" "$(tr "\0" ,)" ;; esac; }
          fzf() { case "$TREE_FILES $*" in "2 "*"--accept-nth={n}"*"start:+trigger(alt-i)+search(!/\$)"*"--info-command="*"show --color=always --format= "*"/^\$/d}"*"--preview-window=down,75%,"*) [ "$(tr "\0" "\n")" = "tree commit abc" ] && printf "4\0" ;; *"show --color=always --format= {2} "*"/^\$/d}"*"--preview-window=down,75%,"*"--delimiter="?" --with-nth={2}{3}{1} --accept-nth=2"*"start:+trigger(alt-i)"*) cut -d "$(printf "\37")" -f 2 ;; esac; }
          COLUMNS=100 EDITOR=ed __git_log'
        if [ "$(${self}/bin/zsh -f -c "$gl")" = "ed -- tree-quote commit abc ../<4," ]; then
          ok "gl lists commits with their author and date flush right in the row's colours, previews each diff below its list, in three quarters of the height, a commit's alone, starts both lists with the search off, lists the commit's files as tree rows, directories unpickable and uncounted, and opens the files of the rows picked"
        else
          fail "gl lists commits without their author and date flush right in the row's colours, previews a diff beside a list or in other than three quarters of the height, or a commit's under a line, starts a list with the search on or turns the file list's off after its !/$ search, or does not hand the rows fzf picks from its tree to tree-quote"
        fi

        # Run from the leader (a zle widget), both of gl's steps are typed on
        # the prompt's line: fzf's prompt is the last line of the shell's, as
        # the shell drew it, and the file step's header goes under the input.
        # Each step leaves its last frame up (--no-clear) and reads its whole
        # list before it starts (--sync), so that the line doesn't go blank
        # between frames.
        glw='. ${self}/.config/shell/functions/git.bash
          git() { [ "$1" != log ] || echo "abc subject"; }
          git-hunk-pick() { case $1 in tree) echo row ;; tree-quote) cat ;; esac; }
          fzf() { case "$*" in *"--prompt=two% --no-bold --color=query:bold --no-header-first --no-clear --sync"*) head -n 1 ;; esac; }
          WIDGET=leader PS1=$(print "one\ntwo%%") EDITOR=ed __git_log'
        if [ "$(${self}/bin/zsh -f -c "$glw")" = "ed -- row" ]; then
          ok "gl run from the leader takes the prompt's line for its input, without blanking it as its steps start"
        else
          fail "gl run from the leader opens its input under the prompt's line, or blanks that line as its steps start"
        fi

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

        # Shift+Tab's search (fm_rg.sh) lists dotfiles too, as the rows fm.sh's
        # binds read: a header per file, then each match; fields 2-4 are path,
        # line, H|M.
        mkdir -p "$HOME/rg/.hidden" && printf 'x\nhello world\n' > "$HOME/rg/.hidden/a.txt"
        if [ "$(cd "$HOME/rg" && PATH=${pkgs.ripgrep}/bin:${fmQuery}/bin:$PATH sh ${self}/.config/shell/scripts/fm_rg.sh 'hel wor' | cut -f2-4)" = "$(printf '.hidden/a.txt\t2\tH\n.hidden/a.txt\t2\tM')" ]; then
          ok "Shift+Tab's search lists a dotfile's match under its header, with its path and line"
        else
          fail "Shift+Tab's search does not list a dotfile's match as header and match rows"
        fi

        # Its preview strips a file's escape sequences (an OSC 8 link here), so
        # nothing in a searched file can drive the terminal through fzf.
        printf 'x \033]8;;http://e.x\033\\link\033]8;;\033\\ y\n' > "$HOME/esc.txt"
        if FZF_PREVIEW_LINES=10 sh ${self}/.config/shell/scripts/fm_preview.sh "$HOME/esc.txt" 1 "" | grep -q "$(printf '\033]')"; then
          fail "the search preview passes a file's escape sequences to fzf"
        else
          ok "the search preview strips a file's escape sequences"
        fi

        # The bundled .zshrc loads and binds Shift+Tab to that search (zsh -i
        # also prints .zshrc's timing line, hence the case).
        case "$(${self}/bin/zsh -i -c 'bindkey "^[[Z"' 2>/dev/null)" in
          *'"^[[Z" __ripgrep_or_menu_'*) ok "the bundled .zshrc binds Shift+Tab to the search" ;;
          *) fail "the bundled .zshrc does not bind Shift+Tab to the search" ;;
        esac

        # A continuation line (an open quote, a loop, a heredoc) has an empty
        # BUFFER but is not an empty prompt: the shortcuts that act on one
        # (Enter's leader picker, Space, Esc, …) must leave it alone.
        case "$(${self}/bin/zsh -i -c 'BUFFER=; PREBUFFER="cat <<EOF"; __on_empty_buffer "print EMPTY" "print LINE"' 2>/dev/null)" in
          *LINE*) ok "the empty-prompt shortcuts leave a continuation line alone" ;;
          *) fail "an empty-prompt shortcut fires on a continuation line" ;;
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
