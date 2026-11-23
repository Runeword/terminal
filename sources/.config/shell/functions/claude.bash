#!/bin/bash
# shellcheck disable=SC2153

__CLAUDE_FZF="--reverse --no-separator --keep-right --border none --cycle --height 70% --info=inline:'' --header-first --prompt='  ' --wrap-sign='' --scheme=path"

# The terminal's part of a claude launch: which profile (the instance), which
# plugins and credentials, and which window. The launch itself is claude-launch,
# from the claude package (github:Runeword/claude's launcher/claude-launch.bash),
# in the window it opens: it prepares the profile, drops what a session planted
# there and in the project, loads the plugins and their secrets, takes the
# open-session lock claude-sessions reads, and runs claude under claude-sandbox
# (Linux), claude-macos (a macOS session holding a credential) or claude-vm,
# failing closed. Every argument is claude's; how to start it goes in its
# environment, which a `tmux new-window` pane takes from the tmux server, not
# from this shell, so __claude_build_cmd spells each part out in the command.

# Build __CLAUDE_CMD, the launch for this shell to eval, and __CLAUDE_PANE_CMD,
# the same for a new tmux window, from __claude_instance, __claude_args and what
# the caller set:
# - CLAUDE_SANDBOX_ALLOW_GH, _FIREBASE, _JIRA and CLAUDE_SANDBOX_NET_ALLOW: a
#   credential for this session (claude's own, from a claude/ entry in pass,
#   which the sandbox launchers read on the host), and its network filter's
#   extra hosts. They open the command, before anything else: claude-sessions'
#   backup reads them there (its connectionsOf, packages/sessions/backup.go).
# - CLAUDE_SANDBOX=0, CLAUDE_SOURCES_ROOT and CLAUDE_SOURCES_ROOT_IGNORE, as
#   this shell has them.
# - __CLAUDE_PLUGINS, a local of the caller's: the plugins to load, exactly;
#   unset, claude-launch's default ones.
# - __CLAUDE_LAUNCHER=claude-vm, a local of __claude_vm's: the microVM.
# __claude_args stays shell-quoted, one word per argument, so an option's value
# (--resume <id>, --model <name>) stays a word of its own. claude-launch is
# resolved here, to a full path: the pane gets the tmux server's PATH.
# What refuses a launch (the sandbox's cwd gate, a profile claude-launch didn't
# make, a plugin the config doesn't have) is said in the pane, which tmux would
# close at once: __CLAUDE_PANE_CMD keeps it open until a key is pressed when
# claude-launch fails (remain-on-exit failed-key). The pane sets that on itself
# before anything runs, so a window made detached gets it too, and the shell
# that evals __CLAUDE_CMD keeps its own pane as it is.
__claude_build_cmd() {
  local launch words="" keep="" tmux_bin sh_bin
  if ! launch=$(command -v claude-launch); then
    echo "claude: claude-launch not found on PATH; rebuild the terminal to pick it up" >&2
    return 1
  fi
  [ "${CLAUDE_SANDBOX_ALLOW_GH:-0}" = 1 ] && words="${words}CLAUDE_SANDBOX_ALLOW_GH=1 "
  [ "${CLAUDE_SANDBOX_ALLOW_FIREBASE:-0}" = 1 ] && words="${words}CLAUDE_SANDBOX_ALLOW_FIREBASE=1 "
  [ "${CLAUDE_SANDBOX_ALLOW_JIRA:-0}" = 1 ] && words="${words}CLAUDE_SANDBOX_ALLOW_JIRA=1 "
  # Quoted: it holds spaces, and `*` must not glob.
  [ -n "${CLAUDE_SANDBOX_NET_ALLOW:-}" ] && words="${words}CLAUDE_SANDBOX_NET_ALLOW=$(printf '%q' "$CLAUDE_SANDBOX_NET_ALLOW") "
  [ "${CLAUDE_SANDBOX:-1}" = 0 ] && words="${words}CLAUDE_SANDBOX=0 "
  [ -n "${CLAUDE_SOURCES_ROOT:-}" ] && words="${words}CLAUDE_SOURCES_ROOT=$(printf '%q' "$CLAUDE_SOURCES_ROOT") "
  [ -n "${CLAUDE_SOURCES_ROOT_IGNORE:-}" ] && words="${words}CLAUDE_SOURCES_ROOT_IGNORE=$(printf '%q' "$CLAUDE_SOURCES_ROOT_IGNORE") "
  words="${words}CLAUDE_CONFIG_DIR=\$HOME/$(__claude_profile) "
  [ -n "${__CLAUDE_PLUGINS+x}" ] && words="${words}CLAUDE_PLUGINS=$(printf '%q' "$__CLAUDE_PLUGINS") "
  [ "${__CLAUDE_LAUNCHER:-}" = claude-vm ] && words="${words}CLAUDE_LAUNCH_VM=1 "
  launch="$(printf '%q' "$launch") $__claude_args"
  __CLAUDE_CMD="$words$launch"
  if tmux_bin=$(command -v tmux) && sh_bin=$(command -v sh); then
    keep="$(printf '%q' "$sh_bin") -c $(printf '%q' "$(printf '%q' "$tmux_bin") set-option -p -t \"\$TMUX_PANE\" remain-on-exit failed-key 2>/dev/null; exec \"\$@\"") sh "
  fi
  __CLAUDE_PANE_CMD="$words$keep$launch"
}

# The profile a session runs with, under $HOME: .claude-N, or .claude-vm-N for
# one __claude_vm starts. claude-vm refuses a profile that holds a login, which
# the VM would read: its sessions sign in through the host's relay instead, so
# they keep a profile of their own, with no .credentials.json in it.
__claude_profile() {
  if [ "${__CLAUDE_LAUNCHER:-}" = claude-vm ]; then
    printf '.claude-vm-%s' "$__claude_instance"
  else
    printf '.claude-%s' "$__claude_instance"
  fi
}

# Read the instance, a leading number (1 unless given), and claude's arguments,
# then build the launch.
__claude_init() {
  __claude_instance=1
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    __claude_instance="$1"
    shift
  fi
  __claude_args=""
  [ "$#" -gt 0 ] && __claude_args=$(printf '%q ' "$@")
  __claude_build_cmd
}

# The plugin picker (leader cpl): a launch with exactly the plugins picked,
# among those claude-plugins lists.
__claude_init_fzf() {
  local selected __CLAUDE_PLUGINS
  selected=$(claude-plugins | eval fzf --multi "$__CLAUDE_FZF") || return 1
  __CLAUDE_PLUGINS=$(printf '%s' "$selected" | tr '\n' ' ')
  __claude_init "$@"
}

__claude_run() {
  if [ "$TMUX" != "" ]; then
    tmux new-window -a -c "#{pane_current_path}" "$__CLAUDE_PANE_CMD"
  else
    eval "$__CLAUDE_CMD"
  fi
}

__claude() {
  __claude_init "$@" || return 0
  __claude_run
}

# __claude in the microVM (leader cv): the same session, profile and plugins,
# started through claude-vm instead of claude-sandbox. A local, which
# __claude_build_cmd sees the way __claude sees __claude_connect's picks, so the
# next plain launch gets claude-sandbox again.
__claude_vm() {
  local __CLAUDE_LAUNCHER=claude-vm
  __claude "$@"
}

# A quick question (leader ca), answered in this pane. vared reads it on a line
# of its own, as text the shell never parses, so quotes, $ and ? reach claude
# as typed, and on stdin, where a leading - is not taken for an option; an
# empty question sends nothing. claude runs as Alt+H's does (.zshrc): on the
# host, with no tools, nothing saved, the host's profile and only the user's
# settings, so a repository's settings can't redirect the call, signed in with
# pass's claude/oauth-token (a token from `claude setup-token`, or a Console API
# key), which reaches this call's environment alone. Haiku at low effort, so
# the answer comes in seconds.
__claude_ask() {
  local question="" cred name rules
  vared -p 'claude › ' question || return 0
  [ -n "$question" ] || return 0
  cred=$(pass show claude/oauth-token) || return 1
  cred=${cred%%$'\n'*}
  case $cred in
    sk-ant-oat?*) name=CLAUDE_CODE_OAUTH_TOKEN ;;
    sk-ant-api?*) name=ANTHROPIC_API_KEY ;;
    *)
      echo "claude: the pass entry claude/oauth-token holds no token" >&2
      return 1
      ;;
  esac
  rules="You answer a question typed at a zsh prompt on $OSTYPE. Answer briefly, in plain text that reads well in a terminal: no Markdown, and each command on a line of its own."
  (
    unset CLAUDE_CONFIG_DIR
    export "$name=$cred"
    printf '%s\n' "$question" |
      command claude -p --safe-mode --model haiku --effort low --tools '' \
        --strict-mcp-config --no-session-persistence --setting-sources user \
        --system-prompt "$rules"
  )
}

# /review paid by the Max plan's monthly API credits, not its usage limits:
# __claude_review [low|medium|high|xhigh|max] [revision]. The credits pay for the
# Agent SDK, whose CLI is headless `claude -p`, and not for interactive Claude
# Code. The key is claude's own Console key, from pass (claude/anthropic-api-key),
# made in a workspace with a spend limit.
# The review can read files and nothing else, and the repository under review
# can't steer it (each flag checked against a hostile repo and a stand-in API):
# - --tools Read: no Bash, Edit, Write, WebFetch or WebSearch, so no command, no
#   connection and no write. Read refuses a symlink out of the repo, such as one
#   to /proc/self/environ, which holds the key.
# - --bare: no hooks, MCP servers, CLAUDE.md or skills from the repo, and no OAuth,
#   so a missing key fails rather than falling back to the Max login.
# - --setting-sources user, after the wrapper's user,project,local: the repo's
#   .claude/settings*.json is ignored. Its env can point ANTHROPIC_BASE_URL at a
#   host of its own, which then gets the key, even under --bare and untrusted.
# - --strict-mcp-config: no MCP server from anywhere.
# Your git makes the diff here, with no external diff or textconv driver, against
# revision: by default @{upstream}, so unpushed commits and uncommitted changes
# (HEAD with no upstream); untracked files aren't in it. The key reaches only this
# launch's environment, and the session gets no other credential.
# TMUX='' keeps __claude in this pane: a tmux window starts from the server's
# environment, without the key, and closes with the review. A subshell, so the cd,
# the trap and these variables end with it. --max-budget-usd stops a run at $5.
__claude_review() (
  review_level=${1:-high} review_rev=${2:-}
  case "$review_level" in
    low | medium | high | xhigh | max) ;;
    *)
      echo "usage: __claude_review [low|medium|high|xhigh|max] [revision]" >&2
      exit 2
      ;;
  esac
  review_top=$(git rev-parse --show-toplevel) || exit 1
  builtin cd "$review_top" || exit 1
  if [ -z "$review_rev" ]; then
    review_rev=HEAD
    git rev-parse --verify --quiet '@{upstream}' >/dev/null && review_rev='@{upstream}'
  fi
  review_dir=$(mktemp -d) || exit 1
  # command: aliases.sh makes rmdir --verbose, which an alias would print here.
  trap 'rm -f -- "$review_dir/changes.diff"; command rmdir -- "$review_dir"' EXIT
  git diff --no-ext-diff --no-textconv "$review_rev" >"$review_dir/changes.diff" || exit 1
  if [ ! -s "$review_dir/changes.diff" ]; then
    echo "claude: nothing to review against $review_rev" >&2
    exit 0
  fi
  review_key=$(pass show claude/anthropic-api-key) || exit 1
  review_key=${review_key%%$'\n'*}
  if [ -z "$review_key" ]; then
    echo "claude: the pass entry claude/anthropic-api-key is empty" >&2
    exit 1
  fi
  # No other credential: __claude_build_cmd and the launcher read these.
  export CLAUDE_SANDBOX_ALLOW_FIREBASE=0 CLAUDE_SANDBOX_ALLOW_JIRA=0 CLAUDE_SANDBOX_ALLOW_GH=0
  TMUX='' ANTHROPIC_API_KEY=$review_key CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    __claude -p --bare --tools Read --setting-sources user --strict-mcp-config \
    --add-dir "$review_dir" --max-budget-usd 5 "/review $review_level $review_dir/changes.diff"
)

# /code-review in the microVM, paid by the same API credits as __claude_review:
# __claude_vm_review [/code-review arguments], such as a level, a branch, a path
# or --max-findings. Claude has Bash there, so /code-review runs git, searches
# and tests itself, as in any session: the VM is the boundary, not the tools.
# - The key stays on the host. claude-vm's relay adds the Console key
#   (CLAUDE_VM_CREDENTIAL_PASS, claude/anthropic-api-key) to each API request,
#   and the guest holds a placeholder. claude -p is the Agent SDK's CLI, which
#   the credits cover.
# - The VM gets a throwaway clone, since it shares its cwd read-write: your
#   commits, your upstream's commit as the clone's upstream, and your
#   uncommitted changes to tracked files (git add -N brings a new file in). Not
#   hardlinked, so the guest can't rewrite your objects, and under
#   $XDG_CACHE_HOME, which sandboxed sessions can't write as they can /tmp: git
#   runs on the clone here.
# - PERMEANCE_TREE is the bundle and PERMEANCE_ROOT unset, so the live tree,
#   which claude-vm would share read-write, stays out, and so does any other
#   credential (the CLAUDE_SANDBOX_ALLOW_* opt-ins). CLAUDE_SOURCES_ROOT is
#   unset too, so claude's config is its bundle as well.
# - --fix, --comment and ultra are refused: the clone is thrown away, the VM has
#   no GitHub token, and ultra needs your claude.ai login. A PR number fails the
#   same way, in /code-review.
# --max-budget-usd stops claude at $5, but the guest can spend the key through
# the relay while the session lasts: the workspace's spend limit is the cap.
# TMUX='' keeps it in this pane, as in __claude_review.
__claude_vm_review() (
  for review_arg; do
    case "$review_arg" in
      --fix | --comment | ultra)
        echo "claude: __claude_vm_review reviews a throwaway clone, with no GitHub token or claude.ai login, so it can't take $review_arg" >&2
        exit 2
        ;;
    esac
  done
  review_top=$(git rev-parse --show-toplevel) || exit 1
  review_cache=${XDG_CACHE_HOME:-$HOME/.cache}
  command mkdir -p -- "$review_cache" || exit 1
  review_dir=$(mktemp -d "$review_cache/claude-review.XXXXXX") || exit 1
  # chmod first, since the guest can leave a directory unwritable.
  trap 'command chmod -R u+w -- "$review_dir" 2>/dev/null; command rm -rf -- "$review_dir"' EXIT
  review_clone=$review_dir/${review_top##*/}
  git clone --quiet --no-hardlinks -- "$review_top" "$review_clone" || exit 1
  # The clone's branch tracks origin/<branch>, which the clone made from your
  # branch itself: point it at your upstream's commit, or drop it with none.
  if review_branch=$(git -C "$review_top" symbolic-ref --quiet --short HEAD); then
    if review_up=$(git -C "$review_top" rev-parse --verify --quiet '@{upstream}'); then
      git -C "$review_clone" update-ref "refs/remotes/origin/$review_branch" "$review_up" || exit 1
    else
      git -C "$review_clone" branch --unset-upstream || exit 1
    fi
  fi
  # --default-prefix: git apply wants a/ and b/, whatever diff.mnemonicPrefix says.
  git -C "$review_top" diff --no-ext-diff --no-textconv --binary --default-prefix HEAD >"$review_dir/changes.diff" || exit 1
  if [ -s "$review_dir/changes.diff" ]; then
    git -C "$review_clone" apply --index --whitespace=nowarn "$review_dir/changes.diff" || exit 1
  fi
  builtin cd "$review_clone" || exit 1
  unset PERMEANCE_ROOT CLAUDE_SOURCES_ROOT
  TMUX='' CLAUDE_VM_CREDENTIAL_PASS=claude/anthropic-api-key CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    PERMEANCE_TREE=$NIX_OUT_SHELL \
    CLAUDE_SANDBOX_ALLOW_FIREBASE=0 CLAUDE_SANDBOX_ALLOW_JIRA=0 CLAUDE_SANDBOX_ALLOW_GH=0 \
    __claude_vm -p --allowedTools Bash --no-session-persistence --max-budget-usd 5 "/code-review $*"
)

# The openshell-nix flake that the openshell chords run (leader co*): your
# checkout in ~/openshell-nix where there is one, as its main branch has it,
# or else GitHub's, as you last pushed it. Nix reads the checkout's main again
# at each run, and with ?ref=main what is uncommitted there doesn't run; on
# GitHub it looks for a newer commit at most once an hour, unless --refresh.
# OPENSHELL_NIX names a checkout elsewhere, which must then be there, at an
# absolute path that a flake URL takes as it is: letters, digits and ._/- only.
__claude_openshell_flake() {
  local dir=${OPENSHELL_NIX:-$HOME/openshell-nix}
  if [ ! -e "$dir/.git" ]; then
    if [ -n "${OPENSHELL_NIX:-}" ]; then
      echo "claude: OPENSHELL_NIX is $OPENSHELL_NIX, which holds no git checkout" >&2
      return 1
    fi
    echo git+ssh://git@github.com/Runeword/openshell-nix
    return 0
  fi
  case "$dir" in
    [!/]* | *[!A-Za-z0-9._/-]*)
      echo "claude: $dir can't go in a flake URL as it is: it takes an absolute path of letters, digits and ._/- only" >&2
      return 1
      ;;
  esac
  echo "git+file://$dir?ref=main"
}

# What an openshell chord (its eval and eval-edit rows) puts on the prompt, so
# that the line shows which openshell-nix runs: nix run of the app the first
# argument names, default for the openshell CLI, then the second argument, the
# rest of the line as it is. The URL is quoted: zsh would take its ? for a glob.
#   __claude_openshell claude-task "-- '<task>'"
__claude_openshell() {
  local flake
  flake=$(__claude_openshell_flake) || return 1
  printf "nix run '%s#%s'%s \n" "$flake" "$1" "${2:+ $2}"
}

# The review in a throwaway OpenShell sandbox (leader cor), by openshell-nix's
# claude-review: it copies the repository you are in into the sandbox and runs
# the claude command it is handed there, as typed. Two pickers choose the
# model, then the effort: the newest model of each family, as Claude Code
# 2.1.318's model catalog names them (latest_per_family), and the five effort
# levels its --help lists, all of which that catalog lets each of the four
# take. Both lists start at the cheapest, so enter twice is the cheapest
# review, and escape in either picker starts none. The picks go first and the
# arguments after them, so a --model or --effort typed in the alias still
# wins, as Claude Code keeps a repeated flag's last value; the alias puts the
# request after --, so one that starts with - is not taken for a flag. --tools
# leaves Claude and its subagents Read, Grep, Glob and Agent: no shell, no
# edits. CLAUDE_CODE_AMBER_ASTROLABE=1 tells Claude that no one can answer its
# questions during the run. It runs the openshell-nix __claude_openshell_flake
# picks, and names it first; --refresh runs GitHub's newest rather than one
# Nix fetched in the last hour.
__claude_openshell_review() {
  local flake model effort
  flake=$(__claude_openshell_flake) || return 1
  echo "claude: openshell-nix from $flake" >&2
  model=$(printf '%s\n' claude-haiku-5-5 claude-sonnet-5-5 claude-opus-5-5 claude-fable-5-1 |
    eval fzf "$__CLAUDE_FZF" "--header='model'") || return 0
  effort=$(printf '%s\n' low medium high xhigh max |
    eval fzf "$__CLAUDE_FZF" "--header='effort'") || return 0
  nix run --refresh "${flake}#claude-review" -- \
    env CLAUDE_CODE_AMBER_ASTROLABE=1 claude -p \
    --model "$model" --effort "$effort" --max-budget-usd 20 \
    --permission-mode dontAsk --tools Read,Grep,Glob,Agent "$@"
}

__claude_plugins() {
  __claude_init_fzf "$@" || return 0
  __claude_run
}

# Pick the session's connections with fzf, then launch a normal session (default
# plugins included) with them added: one leader chord (cc) instead of one per
# credential and per combination. A connection is a credential the sandbox
# launcher hands a single session (firebase, jira, gh: the CLAUDE_SANDBOX_ALLOW_*
# flags in __claude_build_cmd) or an MCP plugin (a plugin with a .mcp.json).
# Picked with gh, firebase or jira, an MCP plugin sits behind their network
# filter too, so the hosts it calls go in CLAUDE_SANDBOX_NET_ALLOW. Takes what
# __claude takes: the instance, then claude's arguments.
__claude_connect() {
  local selected c picked=""
  selected=$(
    {
      printf '%s\n' firebase jira gh
      claude-plugins --mcp
    } | eval fzf --multi "$__CLAUDE_FZF"
  ) || return 0
  # Locals: __claude reads them (a function sees its caller's locals), and the
  # shell drops them on return, so the next plain launch gets none of them. The
  # session gets exactly what was picked: a credential sets the launcher's
  # opt-in flag, an MCP plugin joins the default plugins.
  local CLAUDE_SANDBOX_ALLOW_FIREBASE=0 CLAUDE_SANDBOX_ALLOW_JIRA=0 CLAUDE_SANDBOX_ALLOW_GH=0
  while IFS= read -r c; do
    case "$c" in
      firebase) CLAUDE_SANDBOX_ALLOW_FIREBASE=1 ;;
      jira) CLAUDE_SANDBOX_ALLOW_JIRA=1 ;;
      gh) CLAUDE_SANDBOX_ALLOW_GH=1 ;;
      ?*) picked="$picked $c" ;;
    esac
  done <<<"$selected"
  local __CLAUDE_PLUGINS
  __CLAUDE_PLUGINS="$(claude-plugins --default | tr '\n' ' ')${picked# }"
  __claude "$@"
}

# The connection picker in the microVM (leader cvc): what __claude_connect
# picks, launched through claude-vm, as __claude_vm launches a plain session.
__claude_vm_connect() {
  local __CLAUDE_LAUNCHER=claude-vm
  __claude_connect "$@"
}

__claude_debug() {
  __claude_init "$@" || return 0

  local file="/tmp/claude-debug.log"
  touch "$file"
  if [ "$TMUX" != "" ]; then
    local script="$PERMEANCE_TREE/.config/tmux/scripts/toggle-pane.sh"
    tmux run-shell "sh $script 50 tail -f $file"
    tmux swap-pane -U \; select-pane -D
  fi
  __CLAUDE_CMD="CLAUDE_CODE_DEBUG_LOG_LEVEL=verbose $__CLAUDE_CMD --debug --debug-file $file"
  eval "$__CLAUDE_CMD"
}

# claude-sessions (github:Runeword/claude's packages/sessions) reads the
# transcripts for the session pickers and backs the open sessions up; the
# terminal ships it.
__claude_sessions_on_path() {
  command -v claude-sessions >/dev/null && return 0
  echo "claude-sessions is not on PATH: rebuild, then open a new terminal" >&2
  return 1
}

# fzf over the past sessions of the current directory, each previewed as its
# conversation, for the three pickers below: the instance, then fzf options for
# eval.
__claude_sessions_fzf() {
  __claude_sessions_on_path || return 1
  (
    export CLAUDE_CONFIG_DIR="$HOME/.claude-$1"
    shift
    claude-sessions list | eval fzf "$__CLAUDE_FZF" \
      "--delimiter='\t' --with-nth=2.." \
      "--preview='claude-sessions preview {1}'" \
      "--preview-window='right,60%,border-none,wrap'" "$*"
  )
}

# Pick a past session of the current directory and resume it. The instance is
# the first argument, as for __claude.
__claude_sessions() {
  local instance=1 id
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    instance="$1"
  fi
  id=$(__claude_sessions_fzf "$instance" --accept-nth=1 "--header='enter: resume'") || return 0
  __claude "$instance" --resume "$id"
}

# Pick a past session of the current directory and fork it: claude resumes a
# copy of its conversation under a new session ID, and the original stays as it
# was, for cs to resume later. The instance is the first argument, as for
# __claude.
__claude_sessions_fork() {
  local instance=1 id
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    instance="$1"
  fi
  id=$(__claude_sessions_fzf "$instance" --accept-nth=1 "--header='enter: fork'") || return 0
  __claude "$instance" --resume "$id" --fork-session
}

# Pick past sessions of the current directory and erase them, after one y/N:
# tab marks several, enter erases the marked ones (else the one under the
# cursor). The builtin picker (cr) can't delete a session, and `claude project
# purge` wipes the whole project, its auto-memory included. fzf becomes
# `claude-sessions rm`, which reads the y/N from the terminal and leaves what
# it erased on screen. The instance is the first argument, as for __claude.
__claude_sessions_rm() {
  local instance=1
  if [ "$1" != "" ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    instance="$1"
  fi
  __claude_sessions_fzf "$instance" --multi "--header='tab: mark · enter: erase'" \
    "--bind='enter:become(claude-sessions rm -ask {+1})'" || return 0
}

# Save the sessions open on this machine, in every profile, for
# __claude_sessions_restore to start again later: after a reboot, or once a
# claude update is in. claude-sessions finds them in Claude Code's own registry
# on macOS, and through /proc on Linux, where the registry loses every
# sandboxed session but one; it keeps its 20 newest backups in
# $XDG_STATE_HOME/claude-sessions, read-only in the sandbox.
__claude_sessions_save() {
  __claude_sessions_on_path || return 0
  claude-sessions backup
}

# Start sessions of the backups again, each in a tmux window of its own,
# picked in one fzf that selects as ga's does (__git_pick_files in git.bash):
# claude-sessions restore (github:Runeword/claude's
# packages/sessions/restore.go) lists the backups, newest first, each
# previewed as the sessions it holds, and Enter or Right lists the sessions of
# the one under the cursor that can be resumed, each previewed as its
# conversation, which Left or Esc leaves. Tab marks a row and Ctrl-A every row
# (or clears them): a marked backup stands for all its sessions, which its
# list opens with marked, and leaving that list marks the backup as its
# sessions are. Enter in the sessions list resumes what is marked, and Esc in
# the backups list cancels. A whole backup leaves out, saying why, a session
# still open and one whose conversation or directory is gone. The picker's
# state lives in the per-user runtime dir, as ga's does. A tmux session made
# again can leave a gap in the session numbers, which __tmux_renumber_sessions
# (tmux.sh) then closes, as when a session closes.
__claude_sessions_restore() {
  __claude_sessions_on_path || return 0
  if [ -z "$TMUX" ]; then
    echo "claude: restoring opens a tmux window for each session; run it in tmux" >&2
    return 0
  fi
  local sd sdq step rows id instance dir conns net plugins tsession title _
  sd=$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/claude-restore.XXXXXX") || return 0
  sdq=$(__shell_quote "$sd")
  # key's args end with {+n}, which expands to one word per marked row. The
  # ctrl-a bind keeps $FZF_SELECT_COUNT/$FZF_MATCH_COUNT single-quoted so fzf
  # (not the shell) expands them.
  step="claude-sessions restore key $sdq"
  if claude-sessions restore start "$sd"; then
    # shellcheck disable=SC2016
    fzf "${_GIT_FZF_DEFAULT[@]}" --no-keep-right \
      --bind "enter:transform($step enter {n} {+n})" \
      --bind "right:transform($step right {n} {+n})" \
      --bind "left:transform($step left {n} {+n})" \
      --bind "esc:transform($step esc {n} {+n})" \
      --bind "load:transform(claude-sessions restore load $sdq)" \
      --bind "tab:select+down" \
      --bind "btab:deselect+up" \
      --bind 'ctrl-a:transform([ "${FZF_SELECT_COUNT:-0}" -eq "${FZF_MATCH_COUNT:-0}" ] && echo deselect-all || echo select-all)' \
      --preview "claude-sessions restore show $sdq {n}" \
      --preview-window='right,60%,border-none,wrap' <"$sd/backups" >/dev/null
    rows=$(claude-sessions restore picked "$sd")
  fi
  rm -rf "$sd"
  [ -n "$rows" ] || return 0
  # A row: the session's id, profile, directory, connections, extra hosts of
  # its network filter, plugins and tmux session ("-" for none), then its
  # title.
  while IFS=$'\t' read -r id instance dir conns net plugins tsession title _; do
    __claude_sessions_reopen "$id" "$instance" "$dir" "$conns" "$net" "$plugins" "$tsession" &&
      printf 'claude: resumed %s in %s\n' "$title" "$dir"
  done <<<"$rows"
  __tmux_renumber_sessions
}

# Resume session $1 of profile $2 as __claude started it: from its directory
# $3, with the connections $4 and plugins $6 it had (comma-separated, set as
# __claude_connect sets its picks) and the extra hosts $5 of its network
# filter, in a new window of tmux session $7, which it makes again once it is
# gone, as after a reboot, rather than put every session in the current one;
# "-" stands for none, and the window goes into the current session. Sessions
# are named by number, so one of that name may be another session by then,
# which the window joins. The session is made, and when tmux refuses that
# because one of that name exists, the window goes into that one: checking
# first would go wrong when another launch makes it in between. A session made
# again takes the current window's size: tmux would make it 80x24, and -x -
# takes the size of the pane this runs in. A subshell keeps the directory and
# variables to it.
__claude_sessions_reopen() {
  (
    builtin cd -- "$3" || exit 1
    CLAUDE_SANDBOX_ALLOW_GH=0 CLAUDE_SANDBOX_ALLOW_JIRA=0 CLAUDE_SANDBOX_ALLOW_FIREBASE=0
    case ",$4," in *,gh,*) CLAUDE_SANDBOX_ALLOW_GH=1 ;; esac
    case ",$4," in *,jira,*) CLAUDE_SANDBOX_ALLOW_JIRA=1 ;; esac
    case ",$4," in *,firebase,*) CLAUDE_SANDBOX_ALLOW_FIREBASE=1 ;; esac
    CLAUDE_SANDBOX_NET_ALLOW=$5
    [ "$5" = - ] && CLAUDE_SANDBOX_NET_ALLOW=
    local __CLAUDE_PLUGINS=${6//,/ }
    [ "$6" = - ] && __CLAUDE_PLUGINS=
    __claude_init "$2" --resume "$1" || exit 1
    if [ "$7" = - ]; then
      tmux new-window -d -c "$3" "$__CLAUDE_PANE_CMD"
    else
      size=$(tmux display-message -p '#{window_width} #{window_height}')
      tmux new-session -d -s "$7" -x "${size% *}" -y "${size#* }" -c "$3" "$__CLAUDE_PANE_CMD" 2>/dev/null ||
        tmux new-window -d -t "=$7:" -c "$3" "$__CLAUDE_PANE_CMD"
    fi
  )
}
