# shellcheck shell=bash disable=SC2016
# A template: Nix fills in each @…@ with a store path from this topic's row
# in ../default.nix before the check runs this file.
# SC2016 is off: the single-quoted code is for the zsh under test to expand.
#
# claude.bash: what a launch does to the profile and the project, the
# connection and microVM pickers, the reviews, the session tools, and ca.

# leader-aliases separates a row's fields with a no-break space.
sep=$(printf '\302\240')

# Bundled mode: this bundle has no .claude, so a claude profile comes from
# the claude wrapper's, with this OS's sandbox overlay merged in and its
# commands linked; an overlay that does not merge refuses the launch instead.
os=$(uname -s | tr '[:upper:]' '[:lower:]')
provision='. @zsh@/.config/shell/functions/claude.bash; __claude_instance=1; __claude_provision_config'
if PATH=@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$provision" &&
  [ "$(@jq@/bin/jq -c .sandbox "$HOME/.claude-1/settings.json")" \
    = "$(@jq@/bin/jq -c .sandbox "@claude@/.claude/settings.$os.json")" ] &&
  [ -f "$HOME/.claude-1/commands/x.md" ] &&
  [ -f "$HOME/.claude-1/commands/r.md" ]; then
  ok "bundled mode provisions the claude profile with the $os sandbox overlay and the /x and /r commands"
else
  fail "bundled mode does not provision the claude profile with its sandbox overlay and the /x and /r commands"
fi
# PERMEANCE_STRICT=0: the launcher's strict check would refuse this tree,
# which has no .config, before zsh ran; the message pins the refusal on
# the merge.
mkdir -p "$TMPDIR/tree/.claude"
echo '{}' >"$TMPDIR/tree/.claude/settings.json"
echo 'not json' >"$TMPDIR/tree/.claude/settings.$os.json"
if refusal=$(PATH=@jq@/bin:$PATH PERMEANCE_ROOT=$TMPDIR/tree PERMEANCE_STRICT=0 @zsh@/bin/zsh -f -c "$provision" 2>&1); then
  fail "a sandbox overlay that does not merge still provisions the claude profile"
else
  case "$refusal" in
    *"could not merge"*) ok "a sandbox overlay that does not merge refuses the launch" ;;
    *) fail "the claude profile was refused before the overlay merge: $refusal" ;;
  esac
fi

# A launch makes the profile and drops a session's stray local
# settings without printing a line. In a full start, aliases.sh (read
# before the function files) has mkdir and mv add --verbose, and zsh
# expands an alias in a function as it reads it, so claude.bash runs
# them through command: a fresh profile has its directories made, and
# the project's settings.local.json loses its hooks.
mkdir -p "$HOME/quiet/.claude"
echo '{"permissions":{},"hooks":{}}' >"$HOME/quiet/.claude/settings.local.json"
quiet='{ __claude_instance=7; __claude_prepare_profile && __claude_scrub_project; } > "$HOME/quiet.out" 2>/dev/null'
if (cd "$HOME/quiet" && PATH=@jq@/bin:$PATH @zsh@/bin/zsh -i -c "$quiet" >/dev/null 2>&1) &&
  [ -d "$HOME/.claude-7/.uv-tools" ] && [ ! -s "$HOME/quiet.out" ] &&
  [ "$(@jq@/bin/jq -c . "$HOME/quiet/.claude/settings.local.json")" = '{"permissions":{}}' ]; then
  ok "a launch makes the claude profile's directories and drops a session's stray local settings without printing a line"
else
  fail "a launch prints mkdir's or mv's --verbose lines as it makes the claude profile's directories or drops a session's stray local settings: $(cat "$HOME/quiet.out")"
fi

# The connection picker (leader cc) launches a plain session plus what
# was picked: a credential as the launcher's opt-in flag, an MCP plugin
# on top of the default ones. A stand-in fzf picks jira, figma-mcp and
# google-workspace-mcp, whose token store needs the launcher's opt-in.
connect='. @zsh@/.config/shell/functions/claude.bash
  fzf() { printf "jira\nfigma-mcp\ngoogle-workspace-mcp\n"; }
  __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
  __claude_connect'
case "$(CLAUDE_SANDBOX=0 PATH=@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$connect")" in
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
printf '#!/bin/sh\n[ "$1" = --check-cwd ]\n' >"$HOME/vm/bin/claude-vm"
chmod +x "$HOME/vm/bin/claude-vm"
vm='. @zsh@/.config/shell/functions/claude.bash
  __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
  __claude_vm'
case "$(CLAUDE_SANDBOX=0 PATH=$HOME/vm/bin:@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$vm")" in
  "CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-vm-1 $HOME/vm/bin/claude-vm claude "*)
    if [ -f "$HOME/.claude-vm-1/settings.json" ]; then
      ok "the microVM chord launches claude through claude-vm, with a provisioned profile of its own"
    else
      fail "the microVM chord's profile was not provisioned"
    fi
    ;;
  *) fail "the microVM chord does not launch claude through claude-vm with its own profile" ;;
esac
vmconnect='. @zsh@/.config/shell/functions/claude.bash
  fzf() { printf "gh\njira\nfirebase\n"; }
  __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
  __claude_vm_connect'
case "$(PATH=$HOME/vm/bin:@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$vmconnect")" in
  "CLAUDE_SANDBOX_ALLOW_GH=1 CLAUDE_SANDBOX_ALLOW_FIREBASE=1 CLAUDE_SANDBOX_ALLOW_JIRA=1 CLAUDE_CODE_SYNTAX_HIGHLIGHT=false CLAUDE_CONFIG_DIR=\$HOME/.claude-vm-1 $HOME/vm/bin/claude-vm claude "*)
    ok "the microVM connection picker launches gh, jira and firebase through claude-vm, their flags carried"
    ;;
  *) fail "the microVM connection picker does not launch gh, jira and firebase through claude-vm" ;;
esac
vmfigma='. @zsh@/.config/shell/functions/claude.bash
  fzf() { printf "figma-mcp\n"; }
  __claude_run() { printf "%s\n" "$__CLAUDE_CMD"; }
  __claude_vm_connect'
refusal=$(PATH=$HOME/vm/bin:@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$vmfigma" 2>&1)
case "$refusal" in
  *"claude-vm claude"*) fail "the microVM connection picker launched figma-mcp, whose key the VM would hold" ;;
  *"does not carry figma-mcp"*) ok "the microVM connection picker refuses figma-mcp, whose key the VM would hold" ;;
  *) fail "the microVM connection picker does not say why it refuses figma-mcp: $refusal" ;;
esac
refusal=$(PATH=@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$vm" 2>&1)
case "$refusal" in
  *"claude-vm not found on PATH"*) ok "the microVM chord refuses to launch without claude-vm" ;;
  *) fail "the microVM chord does not refuse without claude-vm: $refusal" ;;
esac

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
case "$(TMUX=x CLAUDE_SANDBOX=0 PATH=@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$review")" in
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
vmreview='. @zsh@/.config/shell/functions/claude.bash
  git() { case $1 in rev-parse) pwd ;; clone) mkdir -p "${@[-1]}" ;; esac; }
  __claude_run() { printf "%s|%s|%s|%s|%s|%s\n" "$TMUX" "$CLAUDE_VM_CREDENTIAL_PASS" "${PERMEANCE_ROOT-unset}" "$PERMEANCE_TREE" "$PWD" "$__CLAUDE_CMD"; }
  export PERMEANCE_ROOT=/live
  __claude_vm_review low src/'
case "$(TMUX=x XDG_CACHE_HOME=$HOME/cache PATH=$HOME/vm/bin:@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$vmreview")" in
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
case "$(CLAUDE_SANDBOX=0 PATH=$HOME/sessions/bin:@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$fork")" in
  *" --resume a --fork-session  --allow-dangerously-skip-permissions") ok "the fork picker resumes the picked session as a fork" ;;
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
# restore it opens no picker. The profile the three sessions share is
# made ready once, before any of them starts: a stand-in jq counts the
# merges of its sandbox overlay. A stand-in claude-sessions lists two
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
  jq() { [[ " $* " == *settings.*.json* ]] && echo x >> "$HOME/restore/merges"; command jq "$@"; }
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
  echo "merges $(grep -c x "$HOME/restore/merges")"
  touch "$HOME/restore/none"; rm "$HOME/restore/fzf"
  TMUX=x __claude_sessions_restore 2>/dev/null
  [ -e "$HOME/restore/fzf" ] && echo "a picker with no backup"
  for d in $HOME/restore/run/claude-restore.*(N); do echo "left $d"; done'
case "$(CLAUDE_SANDBOX=0 XDG_RUNTIME_DIR=$HOME/restore/run PATH=$HOME/restore/bin:@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$restore" | tr '\n' '#')" in
  "backup#-d|-t|=work:|-c|$HOME/proj|CLAUDE_SANDBOX_ALLOW_GH=1 CLAUDE_SANDBOX_ALLOW_JIRA=1 CLAUDE_SANDBOX_NET_ALLOW=x.example "*"/nix-lsp --plugin-dir "*"/figma-mcp "*" --resume a  --allow-dangerously-skip-permissions|#claude: resumed A in $HOME/proj#new-session|-d|-s|gone|-x|120|-y|40|-c|$HOME/proj2|CLAUDE_CODE_SYNTAX_HIGHLIGHT=false "*" claude  --allowedTools "*" --resume b  --allow-dangerously-skip-permissions|#claude: resumed B in $HOME/proj2#-d|-c|$HOME/proj3|CLAUDE_CODE_SYNTAX_HIGHLIGHT=false "*" claude  --allowedTools "*" --resume c  --allow-dangerously-skip-permissions|#claude: resumed C in $HOME/proj3#renumber#listed new#old#merges 1#")
    ok "the session backup's restore picks in one fzf run by claude-sessions restore on a state dir it removes, makes the sessions' profile ready once, and resumes each picked session with its connections and plugins, in its directory and tmux session, which it makes again once it is gone, and opens no picker with no backup"
    ;;
  *) fail "the session backup's restore does not pick in one fzf run by claude-sessions restore, or does not resume the sessions picked as they were started" ;;
esac

# A launch drops what a session can leave for the next one to run: MCP
# servers in the profile's .claude.json, and the local settings claude
# does not write itself (hooks here), keeping its permission rules.
mkdir -p "$HOME/proj/.claude"
echo '{"mcpServers":{"a":{}},"projects":{"/p":{"mcpServers":{"b":{}}}}}' >"$HOME/.claude-1/.claude.json"
echo '{"hooks":{},"permissions":{"allow":["Bash(ls)"],"defaultMode":"bypassPermissions"}}' >"$HOME/proj/.claude/settings.local.json"
launch='. @zsh@/.config/shell/functions/claude.bash
  __claude_run() { :; }
  __claude'
(cd "$HOME/proj" && CLAUDE_SANDBOX=0 PATH=@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$launch" 2>/dev/null)
if [ "$(@jq@/bin/jq -c '[.mcpServers, .projects."/p".mcpServers]' "$HOME/.claude-1/.claude.json")" = '[{},{}]' ] &&
  [ "$(@jq@/bin/jq -c . "$HOME/proj/.claude/settings.local.json")" = '{"permissions":{"allow":["Bash(ls)"]}}' ]; then
  ok "a launch drops the MCP servers and local settings a session planted, keeping claude's permission rules"
else
  fail "a launch keeps what a session planted for the next one"
fi

# The same launch removes the user-level instructions a session can
# plant in its profile, which load into every later session: what
# sources/.claude does not provide, and skills/ whole (claude downloads
# its synced ones again at start).
p=$HOME/.claude-1
mkdir -p "$p/agents" "$p/skills/x" && : >"$p/agents/a.md" && : >"$p/CLAUDE.md" && : >"$p/skills/x/SKILL.md"
(cd "$HOME/proj" && CLAUDE_SANDBOX=0 PATH=@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$launch" 2>/dev/null)
if [ ! -e "$p/agents" ] && [ ! -e "$p/CLAUDE.md" ] && [ ! -e "$p/skills" ] && [ -L "$p/rules" ]; then
  ok "a launch removes the agents, CLAUDE.md and skills a session planted in its profile"
else
  fail "a launch keeps instructions a session planted in its profile"
fi

# A launch writes the profile's settings.json, sources' with this OS's
# overlay, only when it says something else, and then in place: the
# sandbox pins that very file in every running session, and replacing
# it would drop the pin. Made read-only, the file is left alone, so the
# launch wrote nothing; a session's edit is undone in the same file;
# and a symlink a session left there is removed, not written through.
# The launch also drops the plugins a session can leave in the profile,
# which load at the next start: those in plugins/synced, and those
# installed, saying which.
# shellcheck disable=SC2012 # it reads an inode number, not a file name
inode() { ls -i "$1" | awk '{ print $1 }'; }
want=$(@jq@/bin/jq -S -s '.[0] * .[1]' @claude@/.claude/settings.json "@claude@/.claude/settings.$os.json")
first=$(inode "$p/settings.json") untouched=
chmod 444 "$p/settings.json"
(cd "$HOME/proj" && CLAUDE_SANDBOX=0 PATH=@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$launch" 2>/dev/null) && untouched=1
chmod 644 "$p/settings.json"
echo '{"hooks":{"Stop":[]}}' >"$p/settings.json"
(cd "$HOME/proj" && CLAUDE_SANDBOX=0 PATH=@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$launch" 2>/dev/null)
undone=$(inode "$p/settings.json")
echo kept >"$HOME/other.json"
rm "$p/settings.json" && ln -s "$HOME/other.json" "$p/settings.json"
mkdir -p "$p/plugins/synced/bucket/planted"
echo '{"version":2,"plugins":{"planted@market":[{}]}}' >"$p/plugins/installed_plugins.json"
said=$(cd "$HOME/proj" && CLAUDE_SANDBOX=0 PATH=@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$launch" 2>&1 >/dev/null)
if [ "${untouched:-}" = 1 ] && [ "$undone" = "$first" ] &&
  [ -f "$p/settings.json" ] && [ ! -L "$p/settings.json" ] &&
  [ "$(@jq@/bin/jq -S . "$p/settings.json")" = "$want" ] && [ "$(cat "$HOME/other.json")" = kept ] &&
  [ ! -e "$p/plugins/synced" ] &&
  [ "$(@jq@/bin/jq -c .plugins "$p/plugins/installed_plugins.json")" = '{}' ] &&
  case "$said" in *"removed the plugins planted@market"*) true ;; *) false ;; esac then
  ok "a launch writes the profile's settings only when they differ, in place, replaces a link a session left there, and drops the plugins a session synced or installed in the profile"
else
  fail "a launch replaces or rewrites the profile's settings when it need not, writes through a link a session left there, or keeps plugins a session left in the profile: $said"
fi

# A launch runs claude under flock, which locks a file of the launch's
# own for as long as claude runs, and names the file to claude, whose
# SessionStart hook writes the session's id into it (claude-sessions
# mark): a stand-in claude finds the file it was named, in the profile,
# locked. flock execs into claude rather than wait as its parent, which
# tmux would name the window after: the stand-in claude runs as the very
# process a stand-in flock recorded.
mkdir -p "$HOME/lock/bin"
printf '#!/bin/sh\necho $$ > "$HOME/lock/pid"\nexec @utilLinux@/bin/flock "$@"\n' >"$HOME/lock/bin/flock"
printf '#!/bin/sh\ncase $CLAUDE_SESSIONS_OPEN in "$HOME"/.claude-1/open-sessions/?*) ;; *) exit ;; esac\n[ "$(cat "$HOME/lock/pid")" = $$ ] && printf "exec "\nflock -n "$CLAUDE_SESSIONS_OPEN" true || echo held\n' \
  >"$HOME/lock/bin/claude"
chmod +x "$HOME/lock/bin/claude" "$HOME/lock/bin/flock"
locked='. @zsh@/.config/shell/functions/claude.bash
  __claude'
if [ "$(cd "$HOME/proj" && CLAUDE_SANDBOX=0 PATH=$HOME/lock/bin:@utilLinux@/bin:@jq@/bin:$PATH @zsh@/bin/zsh -f -c "$locked" 2>/dev/null)" = "exec held" ]; then
  ok "a launch runs claude in flock's place, under a lock on a file of its own, which it names to claude"
else
  fail "a launch does not run claude in flock's place, under a lock on a file it names to claude"
fi

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
