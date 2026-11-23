# shellcheck shell=bash disable=SC2016
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
# SC2016 is off: the single-quoted code is for the zsh under test to expand.
#
# claude.bash: what each chord hands claude-launch (the claude package's
# launch, which prepares the profile and confines claude, and tests that
# itself), the window it opens, which stays open when claude-launch refuses,
# the reviews, the session tools, and ca.

# leader-aliases separates a row's fields with a no-break space.
sep=$(printf '\302\240')
launch=@claude@/bin/claude-launch

# A stand-in claude-launch, first on PATH where a test runs a launch: it
# saves the argv and environment it was handed to $HOME/stub/out, and fails
# with its refusal when an argument says fail.
mkdir -p "$HOME/stub/bin"
cat >"$HOME/stub/bin/claude-launch" <<'EOF'
#!/bin/sh
mkdir -p "$HOME/stub/out"
printf '%s\n' "$@" >"$HOME/stub/out/argv"
env >"$HOME/stub/out/env"
for a; do
  if [ "$a" = fail ]; then
    echo "claude: refused" >&2
    exit 3
  fi
done
EOF
chmod +x "$HOME/stub/bin/claude-launch"
# launched SCRIPT [NAME=VALUE...]: runs SCRIPT in zsh, outside tmux, so a
# launch is eval'd here, with the stand-in claude-launch and the claude
# package's claude-plugins on PATH.
launched() {
  local script=$1
  shift
  rm -rf "$HOME/stub/out"
  env -u TMUX PATH="$HOME/stub/bin:@claude@/bin:$PATH" "$@" @zsh@/bin/zsh -f -c "$script"
}
# handed NAME=VALUE...: the stand-in claude-launch's environment had each.
handed() {
  local kv
  for kv; do
    grep -qxF -- "$kv" "$HOME/stub/out/env" || return 1
  done
}

# A plain launch (leader c) hands claude-launch the profile, ~/.claude-<n>,
# and claude's arguments as typed, and no plugin list, so claude-launch
# loads its default ones; the command names claude-launch by full path, as
# a tmux pane, which has the tmux server's PATH, needs it.
plain='. @zsh@/.config/shell/functions/claude.bash
  __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
  __claude 2 --resume "a b"'
if [ "$(PATH=@claude@/bin:$PATH @zsh@/bin/zsh -f -c "$plain")" = "CLAUDE_CONFIG_DIR=\$HOME/.claude-2 $launch --resume a\\ b " ]; then
  ok "a plain launch hands claude-launch, by full path, the profile and claude's arguments as typed, and leaves the plugins to its defaults"
else
  fail "a plain launch hands claude-launch: $(PATH=@claude@/bin:$PATH @zsh@/bin/zsh -f -c "$plain")"
fi
missing='. @zsh@/.config/shell/functions/claude.bash
  __claude_run() { echo ran; }
  __claude'
case "$(@zsh@/bin/zsh -f -c "$missing" 2>&1)" in
  *ran*) fail "a launch ran without claude-launch on PATH" ;;
  *"claude-launch not found on PATH"*) ok "without claude-launch on PATH, a launch says so and runs nothing" ;;
  *) fail "without claude-launch on PATH, a launch does not say why it runs nothing" ;;
esac

# A launch runs in a pane, whose environment is the tmux server's, not this
# shell's: so the command carries a credential opt-in, the network filter's
# extra hosts, CLAUDE_SANDBOX=0 and a live config tree, as this shell has
# them, the credentials first, where claude-sessions' backup reads them.
carried='. @zsh@/.config/shell/functions/claude.bash
  CLAUDE_SANDBOX_ALLOW_GH=1 CLAUDE_SANDBOX_NET_ALLOW="a.example *.b.example" CLAUDE_SANDBOX=0 CLAUDE_SOURCES_ROOT=/live __claude
  print -r -- "$__CLAUDE_CMD" >"$HOME/stub/cmd"'
launched "$carried"
if handed CLAUDE_SANDBOX_ALLOW_GH=1 "CLAUDE_SANDBOX_NET_ALLOW=a.example *.b.example" CLAUDE_SANDBOX=0 \
  CLAUDE_SOURCES_ROOT=/live "CLAUDE_CONFIG_DIR=$HOME/.claude-1" &&
  ! grep -q '^CLAUDE_PLUGINS=' "$HOME/stub/out/env" &&
  case $(cat "$HOME/stub/cmd") in "CLAUDE_SANDBOX_ALLOW_GH=1 CLAUDE_SANDBOX_NET_ALLOW="*) true ;; *) false ;; esac then
  ok "a launch carries its credential, extra hosts, CLAUDE_SANDBOX=0 and live tree to claude-launch, the credential first"
else
  fail "a launch does not carry what this shell set to claude-launch: $(cat "$HOME/stub/cmd")"
fi

# bash-language-server runs shellcheck on stdin from the project root,
# where it never finds .config/shell/.shellcheckrc, so the claude
# wrapper's shell-lsp plugin passes the checks that file disables itself.
disabled=$(sed -n 's/^disable=//p' @zsh@/.config/shell/.shellcheckrc | sort | paste -sd, -)
excluded=$(@jq@/bin/jq -r '.shell.env.SHELLCHECK_OPTS // "" | ltrimstr("--exclude=") | split(",") | sort | join(",")' @claude@/.claude/plugins/shell-lsp/.lsp.json)
if [ -n "$disabled" ] && [ "$excluded" = "$disabled" ]; then
  ok "the claude wrapper's shell-lsp skips the checks .shellcheckrc disables: $excluded"
else
  fail "the claude wrapper's shell-lsp skips '$excluded', .shellcheckrc disables '$disabled'"
fi

# The connection picker (leader cc) launches a plain session plus what
# was picked: a credential as its opt-in, an MCP plugin on top of the
# default ones, which claude-plugins names. A stand-in fzf picks jira,
# figma-mcp and google-workspace-mcp.
connect='. @zsh@/.config/shell/functions/claude.bash
  fzf() { printf "jira\nfigma-mcp\ngoogle-workspace-mcp\n"; }
  __claude_connect'
launched "$connect"
if handed CLAUDE_SANDBOX_ALLOW_JIRA=1 \
  "CLAUDE_PLUGINS=$(@claude@/bin/claude-plugins --default | tr '\n' ' ')figma-mcp google-workspace-mcp" &&
  ! grep -q '^CLAUDE_SANDBOX_ALLOW_GH=1' "$HOME/stub/out/env"; then
  ok "the connection picker launches jira, figma-mcp and google-workspace-mcp on top of the default plugins"
else
  fail "the connection picker does not launch what was picked: $(grep '^CLAUDE_' "$HOME/stub/out/env" | tr '\n' ' ')"
fi
# The plugin picker (leader cpl) loads exactly what was picked.
picked='. @zsh@/.config/shell/functions/claude.bash
  fzf() { printf "nix-mcp\nmemory-gate\n"; }
  __claude_plugins'
launched "$picked"
if handed "CLAUDE_PLUGINS=nix-mcp memory-gate"; then
  ok "the plugin picker loads exactly the plugins picked"
else
  fail "the plugin picker does not load exactly what was picked"
fi

# The microVM chord (leader cv) launches the same session in claude-vm, with
# a profile of its own, ~/.claude-vm-N, since claude-vm refuses one holding a
# login; CLAUDE_SANDBOX=0 does not unwrap it, which claude-launch sees to. Its
# connection picker (leader cvc) carries gh, jira and firebase as well:
# claude-vm keeps their credentials on the host.
vm='. @zsh@/.config/shell/functions/claude.bash
  __claude_vm'
launched "$vm"
if handed CLAUDE_LAUNCH_VM=1 "CLAUDE_CONFIG_DIR=$HOME/.claude-vm-1"; then
  ok "the microVM chord launches in claude-vm, with a profile of its own"
else
  fail "the microVM chord does not launch in claude-vm with its own profile"
fi
vmconnect='. @zsh@/.config/shell/functions/claude.bash
  fzf() { printf "gh\njira\nfirebase\n"; }
  __claude_vm_connect'
launched "$vmconnect"
if handed CLAUDE_LAUNCH_VM=1 CLAUDE_SANDBOX_ALLOW_GH=1 CLAUDE_SANDBOX_ALLOW_JIRA=1 CLAUDE_SANDBOX_ALLOW_FIREBASE=1; then
  ok "the microVM connection picker launches gh, jira and firebase in claude-vm, their flags carried"
else
  fail "the microVM connection picker does not launch gh, jira and firebase in claude-vm"
fi

# A window claude-launch fails in stays open until a key is pressed, so its
# refusal can be read; one it ran in closes as any other. The window sets
# that on its own pane before claude-launch runs, so a detached window, as
# the restore makes, gets it too, and this shell's own pane stays as it is.
# A real tmux server, and the stand-in claude-launch, which fails when
# asked to.
export TMUX_TMPDIR=$TMPDIR/tmux
mkdir -p "$TMUX_TMPDIR"
@tmux@/bin/tmux -L claude -f /dev/null new-session -d -s s -x 80 -y 24 'sleep 120'
socket=$(@tmux@/bin/tmux -L claude display-message -p '#{socket_path}')
windows='. @zsh@/.config/shell/functions/claude.bash
  __claude fail
  __claude
  __claude_sessions_reopen fail 1 "$HOME" - - - -'
TMUX="$socket,0,0" PATH="$HOME/stub/bin:@tmux@/bin:$PATH" @zsh@/bin/zsh -f -c "$windows" 2>"$TMPDIR/windows.err"
sleep 1
panes=$(@tmux@/bin/tmux -L claude list-panes -a -F '#{pane_dead}:#{pane_dead_status}:#{remain-on-exit}' | sort | tr '\n' ' ')
@tmux@/bin/tmux -L claude kill-server
if [ "$panes" = "0::off 1:3:failed-key 1:3:failed-key " ]; then
  ok "a window claude-launch fails in stays open for its refusal, detached or not, and one it ran in closes"
else
  fail "the windows claude-launch ran in are '$panes': $(cat "$TMPDIR/windows.err")"
fi

# The review paid by the API credits (__claude_review) runs claude in
# this pane, since a tmux window would start without the key, hands it
# the key in its environment, and launches it with Read as its only
# tool and the repository's settings ignored. Stand-ins for git and pass
# give it a change to review and a key.
review='. @zsh@/.config/shell/functions/claude.bash
  git() { case $1 in rev-parse) [ "$2" = --show-toplevel ] && pwd || return 1 ;; diff) echo change ;; esac; }
  pass() { echo sk-test; }
  __claude_run() { printf "%s|%s|%s\n" "$TMUX" "$ANTHROPIC_API_KEY" "$__CLAUDE_CMD"; }
  __claude_review'
case "$(TMUX=x CLAUDE_SANDBOX=0 PATH=@claude@/bin:@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$review")" in
  "|sk-test|"*" -p --bare --tools Read --setting-sources user --strict-mcp-config --add-dir "*)
    ok "the review runs claude in this pane, with its key in the environment and Read as its only tool"
    ;;
  *) fail "the review does not run claude Read-only, in this pane, with its key in the environment" ;;
esac

# The review in the microVM (__claude_vm_review) hands /code-review its
# arguments and Bash, in this pane, through claude-vm with the Console
# key's pass entry, on a clone under the cache rather than the
# repository, and with the bundles rather than the live trees, the
# terminal's and claude's. A stand-in git makes the clone.
vmreview='. @zsh@/.config/shell/functions/claude.bash
  git() { case $1 in rev-parse) pwd ;; clone) mkdir -p "${@[-1]}" ;; esac; }
  __claude_run() { printf "%s|%s|%s|%s|%s|%s|%s\n" "$TMUX" "$CLAUDE_VM_CREDENTIAL_PASS" "${PERMEANCE_ROOT-unset}" "${CLAUDE_SOURCES_ROOT-unset}" "$PERMEANCE_TREE" "$PWD" "$__CLAUDE_CMD"; }
  export PERMEANCE_ROOT=/live CLAUDE_SOURCES_ROOT=/live-claude
  __claude_vm_review low src/'
case "$(TMUX=x XDG_CACHE_HOME=$HOME/cache PATH=@claude@/bin:@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$vmreview")" in
  "|claude/anthropic-api-key|unset|unset|/nix/store/"*"|$HOME/cache/claude-review."*"|CLAUDE_CONFIG_DIR=\$HOME/.claude-vm-1 CLAUDE_LAUNCH_VM=1 $launch -p --allowedTools Bash --no-session-persistence --max-budget-usd 5 /code-review\ low\ src/ ")
    ok "the microVM review runs /code-review with Bash on a clone, in this pane, with the Console key's entry and without the live tree"
    ;;
  *) fail "the microVM review does not run /code-review on a clone with the Console key's entry and without the live tree" ;;
esac

# The review in an OpenShell sandbox (__claude_openshell_review) hands
# openshell-nix's claude-review the claude command: the model and the effort
# its two pickers chose, then the arguments it was given, so a --model typed
# in the alias comes last and wins, and the request after --. A stand-in fzf
# picks claude-sonnet-5-5 from the models and high from the efforts, and a
# stand-in nix prints each argument in brackets, so the request shows as one.
osreview='. @zsh@/.config/shell/functions/claude.bash
  fzf() { while IFS= read -r l; do case $l in claude-sonnet-5-5|high) echo "$l" ;; esac; done; }
  nix() { printf "[%s]" "$@"; }
  __claude_openshell_review --model claude-opus-5-5 -- "-v look for bugs"'
case "$(@zsh@/bin/zsh -f -c "$osreview")" in
  "[run][--refresh][git+ssh://git@github.com/Runeword/openshell-nix#claude-review][--][env][CLAUDE_CODE_AMBER_ASTROLABE=1][claude][-p][--model][claude-sonnet-5-5][--effort][high][--max-budget-usd][20][--permission-mode][dontAsk][--tools][Read,Grep,Glob,Agent][--model][claude-opus-5-5][--][-v look for bugs]")
    ok "the OpenShell review hands claude-review the picked model and effort, then the alias's flags, then the request after --"
    ;;
  *) fail "the OpenShell review does not hand claude-review the picked model and effort, the alias's flags and the request after --" ;;
esac
# Escape in either picker starts no review: a stand-in fzf picks a model,
# then leaves the effort picker with escape's status, 130.
osescape='. @zsh@/.config/shell/functions/claude.bash
  fzf() { while IFS= read -r l; do [ "$l" = claude-opus-5-5 ] && { echo "$l"; return 0; }; done; return 130; }
  nix() { echo started; }
  __claude_openshell_review -- "look for bugs"'
if [ -z "$(@zsh@/bin/zsh -f -c "$osescape")" ]; then
  ok "escape in the OpenShell review's effort picker starts no review"
else
  fail "the OpenShell review starts after escape in its effort picker"
fi

# The openshell chords (leader co*, eval rows) put a nix run line on the
# prompt: from the checkout in ~/openshell-nix, at its main branch, where
# there is one, or else from GitHub; and nothing, with a message, when
# OPENSHELL_NIX names no checkout, so the chord runs nothing.
mkdir -p "$TMPDIR/oshome/openshell-nix/.git" "$TMPDIR/nohome"
oschord='. @zsh@/.config/shell/functions/claude.bash
  __claude_openshell claude-sandbox "-- --name <name> --upload ."'
case "$(HOME=$TMPDIR/oshome @zsh@/bin/zsh -f -c "$oschord")" in
  "nix run 'git+file://$TMPDIR/oshome/openshell-nix?ref=main#claude-sandbox' -- --name <name> --upload . ")
    ok "an openshell chord runs the checkout in ~/openshell-nix, at its main branch"
    ;;
  *) fail "an openshell chord does not run the checkout in ~/openshell-nix at its main branch" ;;
esac
case "$(HOME=$TMPDIR/nohome @zsh@/bin/zsh -f -c "$oschord")" in
  "nix run 'git+ssh://git@github.com/Runeword/openshell-nix#claude-sandbox' -- --name <name> --upload . ")
    ok "without a checkout in ~/openshell-nix, an openshell chord runs GitHub's"
    ;;
  *) fail "without a checkout in ~/openshell-nix, an openshell chord does not run GitHub's" ;;
esac
if osnone=$(HOME=$TMPDIR/oshome OPENSHELL_NIX=$TMPDIR/nowhere @zsh@/bin/zsh -f -c "$oschord" 2>&1); then
  fail "an openshell chord prints a line to run when OPENSHELL_NIX names no checkout"
else
  case "$osnone" in
    "claude: OPENSHELL_NIX is $TMPDIR/nowhere, which holds no git checkout")
      ok "an openshell chord prints nothing to run, and says why, when OPENSHELL_NIX names no checkout"
      ;;
    *) fail "an openshell chord does not say that OPENSHELL_NIX names no checkout: $osnone" ;;
  esac
fi

# The session eraser (leader cx) hands every marked session to one
# `claude-sessions rm -ask`, which asks about them all at once. A
# stand-in fzf, given --multi, marks every row and presses enter: it
# runs the become() bound to enter on their ids.
mkdir -p "$HOME/sessions/bin"
printf '#!/bin/sh\nif [ "$1" = list ]; then printf "a\\tA\\nb\\tB\\n"; else echo "$*"; fi\n' \
  >"$HOME/sessions/bin/claude-sessions"
chmod +x "$HOME/sessions/bin/claude-sessions"
erase='. @zsh@/.config/shell/functions/claude.bash
  fzf() { for o; do case $o in --multi) m=1 ;; --bind=enter:become*) c=$o ;; esac; done
    [ "$m" ] || return 1; c=${c#*"become("}; c=${c%")"}; eval "${c/"{+1}"/$(cut -f1 | tr "\n" " ")}"; }
  __claude_sessions_rm'
if [ "$(PATH=$HOME/sessions/bin:$PATH @zsh@/bin/zsh -f -c "$erase")" = "rm -ask a b" ]; then
  ok "the session eraser hands claude-sessions rm every marked session at once"
else
  fail "the session eraser does not hand claude-sessions rm the marked sessions"
fi

# The fork picker (leader cf) resumes the picked session under a new
# session ID: a stand-in fzf picks session a.
fork='. @zsh@/.config/shell/functions/claude.bash
  fzf() { echo a; }
  __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
  __claude_sessions_fork'
case "$(CLAUDE_SANDBOX=0 PATH=$HOME/sessions/bin:@claude@/bin:@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$fork")" in
  *"$launch --resume a --fork-session ") ok "the fork picker resumes the picked session as a fork" ;;
  *) fail "the fork picker does not fork the picked session" ;;
esac

# The backup (leader css) is claude-sessions backup; its restore (leader
# csr) picks backups, and sessions of theirs, in one fzf that selects
# as ga's does, its binds and preview running claude-sessions restore
# against a state directory of its own in the runtime dir, which it
# removes once done. It resumes each session picked as __claude
# started it, from its directory, in a window of the tmux session it
# was in, which it makes again at the current window's size once it is
# gone, then closes the gaps in the session numbers; with no backup to
# restore it opens no picker. A stand-in claude-sessions lists two
# backups into the directory start is handed, and picked three
# sessions for that directory: one with gh, jira, extra hosts and
# figma-mcp in session work, a plain one in session gone, and one in
# no session; a stand-in fzf records what it reads and the binds and
# preview it is handed, a stand-in tmux refuses to make session work
# again, knows a 120x40 window and prints the windows and sessions it
# is asked for, and a
# stand-in renumbering says when it runs. The aliases load first, as in
# .zshrc, since they expand inside the functions: cd there is __cd,
# which takes no --.
mkdir -p "$HOME/restore/bin" "$HOME/restore/run" "$HOME/proj" "$HOME/proj2" "$HOME/proj3"
printf 'a\t1\t%s\tgh,jira\tx.example\tnix-lsp,figma-mcp\twork\tA\nb\t1\t%s\t-\t-\t-\tgone\tB\nc\t1\t%s\t-\t-\t-\t-\tC\n' \
  "$HOME/proj" "$HOME/proj2" "$HOME/proj3" >"$HOME/restore/rows"
printf '#!/bin/sh\ncase $1-$2 in restore-start) [ -e "$HOME/restore/none" ] && exit 1; echo "$3" > "$HOME/restore/dir"; printf "new\\nold\\n" > "$3/backups" ;; restore-picked) [ "$3" = "$(cat "$HOME/restore/dir")" ] && cat "$HOME/restore/rows" ;; *) echo "$*" ;; esac\n' \
  >"$HOME/restore/bin/claude-sessions"
chmod +x "$HOME/restore/bin/claude-sessions"
restore='. @zsh@/.config/shell/aliases.sh; . @zsh@/.config/shell/functions/cd.sh
  . @zsh@/.config/shell/functions/git.bash; . @zsh@/.config/shell/functions/claude.bash
  fzf() { cat > "$HOME/restore/listed"; printf "%s\n" "$@" > "$HOME/restore/fzf"; }
  tmux() { case $1 in display-message) echo "120 40" ;; new-window) shift; printf "%s|" "$@"; echo ;; new-session) [ "$4" = work ] && return 1; printf "%s|" "$@"; echo ;; esac; }
  __tmux_renumber_sessions() { echo renumber; }
  __claude_sessions_save
  TMUX=x __claude_sessions_restore
  sd=$(<"$HOME/restore/dir") f=$(<"$HOME/restore/fzf")
  [[ $sd == "$HOME/restore/run/claude-restore."* && ! -e $sd ]] || echo "state dir $sd"
  for k in enter right left esc; do
    [[ $f == *"${k}:transform(claude-sessions restore key "?"$sd"?" $k {n} {+n})"* ]] || echo "no $k bind"
  done
  [[ $f == *"load:transform(claude-sessions restore load "?"$sd"?")"* ]] || echo "no load bind"
  [[ $f == *"claude-sessions restore show "?"$sd"?" {n}"* ]] || echo "no preview"
  echo "listed $(<"$HOME/restore/listed")"
  touch "$HOME/restore/none"; rm "$HOME/restore/fzf"
  TMUX=x __claude_sessions_restore 2>/dev/null
  [ -e "$HOME/restore/fzf" ] && echo "a picker with no backup"
  for d in $HOME/restore/run/claude-restore.*(N); do echo "left $d"; done'
case "$(CLAUDE_SANDBOX=0 XDG_RUNTIME_DIR=$HOME/restore/run PATH=$HOME/restore/bin:@claude@/bin:@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$restore" | tr '\n' '#')" in
  "backup#-d|-t|=work:|-c|$HOME/proj|CLAUDE_SANDBOX_ALLOW_GH=1 CLAUDE_SANDBOX_ALLOW_JIRA=1 CLAUDE_SANDBOX_NET_ALLOW=x.example CLAUDE_SANDBOX=0 CLAUDE_CONFIG_DIR=\$HOME/.claude-1 CLAUDE_PLUGINS=nix-lsp\\ figma-mcp "*" $launch --resume a |#claude: resumed A in $HOME/proj#new-session|-d|-s|gone|-x|120|-y|40|-c|$HOME/proj2|CLAUDE_SANDBOX=0 CLAUDE_CONFIG_DIR=\$HOME/.claude-1 CLAUDE_PLUGINS='' "*" $launch --resume b |#claude: resumed B in $HOME/proj2#-d|-c|$HOME/proj3|CLAUDE_SANDBOX=0 CLAUDE_CONFIG_DIR=\$HOME/.claude-1 CLAUDE_PLUGINS='' "*" $launch --resume c |#claude: resumed C in $HOME/proj3#renumber#listed new#old#")
    ok "the session backup's restore picks in one fzf run by claude-sessions restore on a state dir it removes, and resumes each picked session with its connections and plugins, in its directory and tmux session, which it makes again once it is gone, and opens no picker with no backup"
    ;;
  *) fail "the session backup's restore does not pick in one fzf run by claude-sessions restore, or does not resume the sessions picked as they were started" ;;
esac

# ca asks Claude a quick question and prints the answer in this pane:
# the question, read with vared, reaches claude on stdin as typed,
# never run or taken for an option, and claude runs as Alt+H's does,
# with no tools, nothing saved, only the user's settings and no
# CLAUDE_CONFIG_DIR, so with the host's own profile, signed in with
# pass's claude/oauth-token in its environment alone, which the shell
# never gets; an empty question sends nothing. Stand-ins: a claude that
# records what it got, pass, and a vared that types the question.
mkdir -p "$HOME/ask/bin"
printf '#!/bin/sh\necho "config=$CLAUDE_CONFIG_DIR token=$CLAUDE_CODE_OAUTH_TOKEN $*" > "$HOME/ask/args"\ncat > "$HOME/ask/stdin"\necho Use ss -tlnp.\n' >"$HOME/ask/bin/claude"
printf '#!/bin/sh\n[ "$*" = "show claude/oauth-token" ] && echo sk-ant-oat01-fake\n' >"$HOME/ask/bin/pass"
chmod +x "$HOME/ask/bin/claude" "$HOME/ask/bin/pass"
ask='path=($HOME/ask/bin $path); export CLAUDE_CONFIG_DIR=$HOME/.claude-1
  . @zsh@/.config/shell/functions/claude.bash
  vared() { typeset -g "$argv[-1]=$typed"; }
  typed= __claude_ask
  __claude_ask
  print -r -- "left=$CLAUDE_CONFIG_DIR,$CLAUDE_CODE_OAUTH_TOKEN"'
typed="-v what's on port \$(touch $HOME/asked) in \"a b\"?"
asked=$({
  typed=$typed @zsh@/bin/zsh -f -c "$ask" 2>/dev/null || :
  cat "$HOME/ask/args" "$HOME/ask/stdin" 2>/dev/null || :
} | tr '\n' '#')
if @leaderAliases@/bin/leader-aliases @zsh@/.config/shell/leader.conf |
  awk -F "$sep" '$1 ~ /^ca +$/ && $5 == "__claude_ask" && $6 == "run" { found = 1 } END { exit !found }'; then
  case "$asked" in
    "Use ss -tlnp.#left=$HOME/.claude-1,#config= token=sk-ant-oat01-fake -p "*"--tools  --strict-mcp-config --no-session-persistence --setting-sources user "*"#$typed#")
      if [ -e "$HOME/asked" ]; then
        fail "ca ran the question it was to send"
      else
        ok "ca has Claude answer a question in this pane, read as typed and sent on stdin to a claude with no tools, nothing saved, the host's profile and the token in pass, which the shell never gets, and sends nothing for an empty one"
      fi
      ;;
    *) fail "ca does not send the question as typed, on stdin, to a tool-less claude signed in with the token in pass, keeps the token in the shell, or sends an empty question: $asked" ;;
  esac
else
  fail "the bundled leader.conf does not bind ca to __claude_ask"
fi
