{
  pkgs,
  files,
  permeance,
  zsh,
}:

let
  config = files.mkConfig "tmux-config" [
    ".config/tmux/tmux.conf"
    ".config/tmux/scripts/toggle-pane.sh"
    ".config/tmux/scripts/new-window-shift.sh"
    ".config/tmux/scripts/open-url.sh"
    # Bound in tmux.conf on a currently-commented M-b — bundled so the binding
    # resolves in bundled mode, not just under $PERMEANCE_ROOT.
    ".config/tmux/scripts/watch-build.sh"
    ".config/shell/functions/tmux.sh"
    # tmux-resurrect plugin tree, supplied by nixpkgs instead of vendored
    # or fetched at runtime via TPM. tmux.conf references its scripts via
    # $NIX_OUT_TMUX/.config/tmux/plugins/resurrect/...
    {
      source = "${pkgs.tmuxPlugins.resurrect}/share/tmux-plugins/resurrect";
      target = ".config/tmux/plugins/resurrect";
    }
  ];
  # For the smoke test's zsh check: reads `bindkey -M emacs` and prints each
  # key zsh's emacs keymap binds as tmux names it, with the widgets on it:
  # <key><TAB><widget>[, <widget>…]. A sequence of several keys (^X^B) counts
  # as its first key, the one a root binding would take. A key it can't name
  # fails it, so a new kind of default can't slip by.
  zshKeys = pkgs.writeText "zsh-keys.awk" ''
    function bad(s) {
      printf "zsh key %s: no tmux name for it\n", s > "/dev/stderr"
      failed = 1
      return ""
    }
    # bindkey's quoting undone: \" \$ \\ and the like stand for the character.
    function unquote(s,    out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") c = substr(s, ++i, 1)
        out = out c
      }
      return out
    }
    # ^<c>
    function ctrl(c) {
      if (c == "@") return "C-Space"
      if (c == "I") return "Tab"
      if (c == "M") return "Enter"
      if (c == "[") return "Escape"
      if (c == "?") return "BSpace"
      return "C-" tolower(c)
    }
    # A terminal key after its ^[, O<x> or [<params><x>, with xterm's
    # modifiers: [1;<m><x> and [<n>;<m>~, m - 1 summing 1 Shift, 2 Meta and
    # 4 Ctrl.
    function term(r,    p, x, n, m, name) {
      p = substr(r, 2, length(r) - 2)
      x = substr(r, length(r))
      n = p
      m = 1
      if (index(p, ";")) {
        n = substr(p, 1, index(p, ";") - 1)
        m = substr(p, index(p, ";") + 1)
      }
      if (x == "~") {
        if (n == 200) return "" # bracketed paste, not a key
        if (n == 1 || n == 7) name = "Home"
        else if (n == 2) name = "IC"
        else if (n == 3) name = "DC"
        else if (n == 4 || n == 8) name = "End"
        else if (n == 5) name = "PPage"
        else if (n == 6) name = "NPage"
      } else if (n == "" || n == 1) {
        if (x == "A") name = "Up"
        else if (x == "B") name = "Down"
        else if (x == "C") name = "Right"
        else if (x == "D") name = "Left"
        else if (x == "H") name = "Home"
        else if (x == "F") name = "End"
      }
      if (name == "" || m !~ /^[1-8]$/) return bad("^[" r)
      m--
      return (m >= 4 ? "C-" : "") (m % 4 >= 2 ? "M-" : "") (m % 2 ? "S-" : "") name
    }
    function key(s,    r) {
      if (s ~ /^\^\[./) {
        r = substr(s, 3)
        if (r ~ /^[[O]./) return term(r)
        if (r ~ /^\^.$/) {
          r = ctrl(substr(r, 2))
          return r ~ /^C-/ ? "C-M-" substr(r, 3) : "M-" r
        }
        if (r == " ") return "M-Space"
        if (length(r) == 1) return "M-" r
        return bad(s)
      }
      if (s ~ /^\^./) return ctrl(substr(s, 2, 1))
      return bad(s)
    }
    {
      if (!match($0, /^"([^"\\]|\\.)*"/)) {
        bad($0)
        next
      }
      s = substr($0, 2, RLENGTH - 2)
      rest = substr($0, RLENGTH + 1)
      # A range, "<from>"-"<to>" <widget>: the printable and 8-bit characters.
      if (rest ~ /^-"/) {
        if (rest !~ / self-insert$/) bad($0)
        next
      }
      widget = substr(rest, 2)
      if (widget == "self-insert") next
      k = key(unquote(s))
      if (k == "") next
      if (!(k in widgets)) {
        keys[++count] = k
        widgets[k] = widget
      } else if (index(", " widgets[k] ", ", ", " widget ", ") == 0) {
        widgets[k] = widgets[k] ", " widget
      }
    }
    END {
      for (j = 1; j <= count; j++) print keys[j] "\t" widgets[keys[j]]
      exit failed
    }
  '';
  self = pkgs.symlinkJoin {
    name = "tmux-with-config";
    paths = [
      pkgs.tmux
      config
    ];
    postBuild = permeance.installLauncher {
      binName = "tmux";
      compiled = true;
      staticEnv = {
        TMUX_SHELL = "${zsh}/bin/zsh";
        NIX_OUT_TMUX = permeance.out;
      };
      flags = [
        "-f"
        "${permeance.root}/.config/tmux/tmux.conf"
      ];
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "tmux";
      description = "Verify tmux config loads without errors, uses the zsh wrapper, enables resurrect pane-content capture, turns passthrough off, yanks via copy-selection, opens the link under the copy-mode cursor on Ctrl+Enter, leaves Alt+H to the shell and opens the pane below on Alt+Shift+V, takes none of zsh's default keys but those it means to, reorders windows by dragging their status-bar name, renders sessions sorted-by-number so they can be dragged to reorder too, picks the nearer name when a click on the bar falls between two, keeps M-t's window after the current one in a full session by pushing the session's last window into a new session next to it, moves a window to another session without leaving a gap in the window numbers of the one it left, closes the session numbers up to 1..N even from a session 0, goes to the next and previous session by number and lands a client whose session closes on the one before it by number, shows the current session's AI label after the session numbers and each window's one-word AI name in place of its program, both made on session and window switches, the label also set with M-N, marks the windows and sessions whose Claude waits for you, and tells tmux that Alacritty takes synchronized updates";
      script = ''
        # Each $(…) below runs its tmux server in a socket directory of its
        # own (fresh): kill-server returns before the server has exited, and a
        # server on its way out drops the clients that reach it, so a server
        # started on the same socket right after could lose its commands.
        fresh() { TMUX_TMPDIR=$(mktemp -d) && export TMUX_TMPDIR; }

        # No explicit -f — let the launcher's flags = [ "-f" "''${permeance.root}/.config/tmux/tmux.conf" ]
        # provide it, so the smoke exercises the launcher's flag routing. start-server
        # exits 0 and prints nothing even when that load fails: tmux keeps its parse
        # and command errors until the next source-file prints them, so source
        # /dev/null.
        if err=$(fresh; ${self}/bin/tmux start-server \; source-file /dev/null \; kill-server 2>&1) && [ -z "$err" ]; then
          ok "tmux.conf loads without errors (via launcher -f routing)"
        else
          fail "tmux.conf: ''${err:-tmux exited non-zero}"
        fi

        tmux_shell=$(fresh; ${self}/bin/tmux start-server \; show-option -gv default-shell \; kill-server 2>/dev/null)
        if [ "$tmux_shell" = "${zsh}/bin/zsh" ]; then
          ok "default-shell is zsh wrapper"
        else
          fail "default-shell is '$tmux_shell', expected '${zsh}/bin/zsh'"
        fi

        cap=$(fresh; ${self}/bin/tmux start-server \; show-option -gqv @resurrect-capture-pane-contents \; kill-server 2>/dev/null)
        if [ "$cap" = "on" ]; then
          ok "resurrect pane-content capture enabled"
        else
          fail "@resurrect-capture-pane-contents is '$cap', expected 'on'"
        fi

        # M-S/M-R call save.sh/restore.sh directly. resurrect.tmux only binds prefix
        # keys, unreachable with prefix None, and running it took most of every load.
        if grep -q '^[[:space:]]*run-shell.*resurrect\.tmux' ${self}/.config/tmux/tmux.conf; then
          fail "tmux.conf runs resurrect.tmux at every load"
        else
          ok "tmux.conf loads without running resurrect.tmux"
        fi

        # allow-passthrough is a pane option; its global default lives in the
        # window/pane table, so -gw (a plain -g comes back empty). Off: a pane
        # could otherwise pass an OSC 52 straight to the terminal and set the
        # clipboard, around set-clipboard external.
        passthrough=$(fresh; ${self}/bin/tmux start-server \; show-options -gwv allow-passthrough \; kill-server 2>/dev/null)
        if [ "$passthrough" = "off" ]; then
          ok "panes can't pass escape sequences through to the terminal"
        else
          fail "allow-passthrough is '$passthrough', expected 'off'"
        fi

        # The binding of one key, read from its whole table: since tmux 3.7 a
        # list-keys that matches a single key shows it as a status message
        # instead of printing it.
        binding() {
          fresh
          ${self}/bin/tmux start-server \; list-keys -T "$1" \; kill-server 2>/dev/null |
            while read -r _ _ _ key rest; do
              if [ "$key" = "$2" ]; then printf '%s\n' "$rest"; fi
            done
        }

        yank=$(binding copy-mode-vi y)
        case "$yank" in
          *copy-selection*) ok "copy-mode-vi y yanks via copy-selection" ;;
          *) fail "copy-mode-vi y is '$yank', expected copy-selection" ;;
        esac

        # A name dragged along the bar moves to where the pointer is, and on
        # by columns of travel once the pointer strays below the bar. tmux 3.8
        # reports every move of a drag that starts on the bar where it started,
        # so while it lasts the labels name themselves in their click range
        # (@wrange, @srange). The mouse bytes are typed into a client hosted in
        # a pane of a config-less tmux server.
        drags=$(
          PATH=${self}/bin:$PATH
          fresh
          tmux new-session -d -s 1 -n a sleep 60 \; set -g default-shell "$(command -v sh)" \; \
            new-window -d -t =1: -n b sleep 60 \; new-window -d -t =1: -n c sleep 60 \; \
            new-session -d -s 2 sleep 60 \; set-hook -g client-attached 'wait-for -S attached'
          ${pkgs.tmux}/bin/tmux -L outer -f /dev/null new-session -d -x 40 -y 6 'env -u TMUX tmux attach -t =1'
          timeout 10 tmux wait-for attached
          ev() { ${pkgs.tmux}/bin/tmux -L outer send-keys -H $(printf '\033[<%s;%s;%s%s' "$@" | od -An -tx1); }
          # until_ <want> <command…>: wait up to 5 s for the command to print <want>.
          until_() {
            want=$1
            shift
            for _ in $(seq 50); do
              [ "$("$@")" = "$want" ] && return
              sleep 0.1
            done
          }
          # to <col> <row> <want> <command…>: drag there until the command prints
          # <want>. A move that beats the redraw naming the labels is lost, so it
          # is sent again, a column over each time: tmux drops a move to where
          # the pointer already is.
          to() {
            col=$1 row=$2 want=$3
            shift 3
            for i in $(seq 50); do
              ev 32 $((col + i % 2)) "$row" M
              [ "$("$@")" = "$want" ] && return
              sleep 0.1
            done
          }
          bar() { ${pkgs.tmux}/bin/tmux -L outer capture-pane -p -S 0 -E 0; }
          drawn() { case "$(bar)" in *"3 c"*) echo yes ;; esac; }
          windows() { tmux list-windows -t "$1" -F '#W' | tr '\n' ' '; }
          until_ yes drawn
          b=$(bar)
          pre=''${b%%1 a*}
          a=$((''${#pre} + 3))
          pre=''${b%%3 c*}
          c=$((''${#pre} + 3))
          # Window a onto c along the bar: they swap. Then 4 columns (@wstep)
          # left below the bar: a moves one place left.
          ev 0 "$a" 1 M
          to "$c" 1 "c b a " windows =1:
          ev 32 "$c" 4 M
          to $((c - 4)) 4 "c a b " windows =1:
          ev 0 $((c - 4)) 4 m
          sleep 0.4 # a press within 0.3 s of the last is a second click
          # Session 1 onto 2 along the bar: they trade numbers.
          ev 0 1 1 M
          to 4 1 2 tmux list-clients -F '#S'
          ev 0 4 1 m
          until_ 0 tmux show -gv @sdrag
          tmux list-clients -F '#S'
          windows =2:
          # The outer server goes first, here and in the tests below: killing
          # the inner one first ends the client in the outer server's only
          # pane, and so the outer server, which a kill-server sent after that
          # may find gone ("no server running") or going ("server exited
          # unexpectedly").
          ${pkgs.tmux}/bin/tmux -L outer kill-server
          tmux kill-server
        ) || true
        drags=$(printf '%s\n' "$drags" | tr '\n' '|')
        if [ "$drags" = "2|c a b |" ]; then
          ok "a window or session name dragged along the bar, or below it, moves there"
        else
          fail "window a dragged onto c along the bar, then 4 columns left below it, and session 1 onto 2, left '$drags', expected '2|c a b |'"
        fi

        # A release over a pane that ends no status-bar drag is passed on to the
        # pane's program (nvim, fzf --mouse), as tmux does with nothing bound.
        release="$(binding root MouseUp1Pane) $(binding root MouseDragEnd1Pane)"
        case "$release" in
          *"} { send-keys -M }"*"} { send-keys -M }"*) ok "mouse releases outside a drag reach the pane" ;;
          *) fail "MouseUp1Pane / MouseDragEnd1Pane swallow the release: '$release'" ;;
        esac

        # Mouse handlers reset the drag flags only while one is set: setting any
        # option redraws every attached client in full, on every click.
        guarded='#{||:#{@wdrag},#{@sdrag}}" { set-option -g @wdrag 0'
        keys=$(fresh; ${self}/bin/tmux start-server \; list-keys -T root \; kill-server 2>/dev/null)
        case "''${keys//"$guarded"/}" in
          "$keys" | *"@wdrag 0"*) fail "a mouse handler resets the drag flags outside a drag" ;;
          *) ok "mouse handlers reset the drag flags only during a drag" ;;
        esac

        # M-w/M-W close a pane or window in tmux alone (step, then kill {last}, the
        # one just left); only a session's last window goes through the shell.
        close="$(binding root M-w) $(binding root M-W)"
        case "$close" in
          *__tmux_kill_pane*) fail "M-w/M-W still close panes and windows through the shell" ;;
          *"kill-pane -t "?"{last}"*"kill-window -t "?"{last}"*__tmux_kill_session*"kill-pane -t "?"{last}"*"kill-window -t "?"{last}"*__tmux_kill_session*) ok "M-w/M-W close panes and windows without a shell" ;;
          *) fail "M-w/M-W are '$close'" ;;
        esac

        # Alt+H reaches the shell, which has Haiku explain the typed line; the
        # pane below opens on M-V instead.
        below="$(binding root M-h)|$(binding root M-V)"
        case "$below" in
          "|split-window -v -l 8") ok "M-h is left to the shell and M-V opens the pane below" ;;
          *) fail "M-h|M-V are '$below'" ;;
        esac

        # zsh's default keys (its emacs keymap as zsh -f has it, without
        # .zshrc's own bindings) that a root binding takes: tmux gets them
        # before the shell in the pane does. zshKeys names each as tmux does,
        # and tmux, binding them in a table of their own, prints them as it
        # prints the root table's. Taken on purpose, with the widget each
        # takes from zsh:
        #   M-0…M-9  session <n>         digit-argument
        #   M-Enter  session picker      self-insert-unmeta (a newline)
        #   M-Tab    next session        self-insert-unmeta (a tab)
        #   M-n M-N  new session, label  history-search-forward
        #   M-q      detach              push-line
        #   M-S      resurrect save      spell-word (Alt+S still runs it)
        #   M-t      new window          transpose-words (Alt+Shift+T still runs it)
        #   M-w M-W  close               copy-region-as-kill
        # A key newly taken fails: move its binding, or add the key here with
        # the widget it takes. So does a key here that tmux no longer takes,
        # so that the list stays the keys zsh goes without.
        taken_on_purpose="M-0 M-1 M-2 M-3 M-4 M-5 M-6 M-7 M-8 M-9 M-Enter M-N M-S M-Tab M-W M-n M-q M-t M-w"
        if zsh_keys=$(env -i ${pkgs.zsh}/bin/zsh -f -c 'bindkey -M emacs' | awk -f ${zshKeys}) && [ -n "$zsh_keys" ]; then
          binds=()
          while IFS=$'\t' read -r key widgets; do
            binds+=(bind -T zsh "$key" display-message "$widgets" ';')
          done <<<"$zsh_keys"
          if listed=$(fresh; ${self}/bin/tmux start-server \; "''${binds[@]}" list-keys -T zsh \; list-keys -T root \; kill-server 2>&1); then
            report=$(printf '%s\n' "$listed" | awk -v expected="$taken_on_purpose" '
              function add(s) { report = report (report == "" ? "" : "; ") s }
              $1 == "bind-key" {
                i = $2 == "-r" ? 3 : 2
                if ($(i + 1) == "zsh") {
                  w = $0
                  sub(/.* display-message /, "", w)
                  gsub(/^"|"$/, "", w)
                  zsh[$(i + 2)] = w
                } else if ($(i + 1) == "root") root[$(i + 2)] = 1
              }
              END {
                n = split(expected, e, " ")
                for (j = 1; j <= n; j++) {
                  want[e[j]] = 1
                  if (!(e[j] in zsh && e[j] in root)) add(e[j] " is not taken")
                }
                for (k in zsh) if (k in root && !(k in want)) add(k " (" zsh[k] ") is taken")
                print report
              }')
            if [ -z "$report" ]; then
              ok "zsh keeps its default keys in tmux, but for $taken_on_purpose"
            else
              fail "zsh keys taken by root bindings differ from taken_on_purpose: $report"
            fi
          else
            fail "tmux can't bind zsh's keys: $listed"
          fi
        else
          fail "zsh's default keys: bindkey printed none, or one zshKeys can't name (above)"
        fi

        # C-S-<n> with no window <n> moves the current window right after the
        # last one, rather than opening a new window at <n>. The binding is
        # tmux alone, so source its commands into a server: list-keys joins
        # them with \;, and a sourced line separates commands with a plain ;.
        swap=$(binding root C-S-9)
        order=$(
          PATH=${self}/bin:$PATH
          fresh
          tmux new-session -d -s t -n a sleep 60 \; \
            new-window -d -n b sleep 60 \; new-window -d -n c sleep 60
          printf '%s\n' "$swap" | sed 's/ \\; / ; /g' | tmux source-file -
          tmux list-windows -F '#{window_index}#{window_name}#{?window_active,*,}' | tr '\n' ' '
          tmux kill-server
        ) || true
        if [ "$order" = "1b 2c 3a* " ]; then
          ok "C-S-<n> past the last window moves the current window after it"
        else
          fail "C-S-9 on window 1 of a, b, c left '$order', expected '1b 2c 3a* '"
        fi

        # M-t in a session with @wmax (4) windows still opens the window after
        # the current one, in the pressing pane's directory (# included: -c is
        # expanded as a format), and the windows after it shift one place
        # right: the session's last window moves to a new session next to it,
        # and the sessions after it move one number up. From the last window,
        # the new window moves there, and the client follows it.
        # M-t is pressed through an attached client's key table (send-keys -K,
        # which returns once the binding, run-shell included, has run), and the
        # pane of a second, config-less tmux server is the terminal that client
        # needs (a client-attached hook signals it is attached; that pane
        # inherits the fresh directory, so its attach finds the first server).
        # list-clients reads where the client is: display-message -c expands
        # its format for the newest session. New windows run sh, so that is
        # their name.
        overflow=$(
          PATH=${self}/bin:$PATH
          fresh
          mkdir "$HOME/C#S"
          tmux new-session -d -s 1 -n a -c "$HOME/C##S" sleep 60 \; \
            set -g default-shell "$(command -v sh)" \; set -g automatic-rename off \; \
            new-window -d -t =1: -n b sleep 60 \; new-window -d -t =1: -n c sleep 60 \; \
            new-window -d -t =1: -n d sleep 60 \; new-session -d -s 2 -n e sleep 60 \; \
            new-window -d -t =2: -n f sleep 60 \; new-window -d -t =2: -n g sleep 60 \; \
            new-window -d -t =2: -n h sleep 60 \; \
            set-hook -g client-attached 'wait-for -S attached'
          ${pkgs.tmux}/bin/tmux -L outer -f /dev/null new-session -d 'env -u TMUX tmux attach -t =1'
          timeout 10 tmux wait-for attached
          client=$(tmux list-clients -F '#{client_name}')
          tmux send-keys -K -c "$client" M-t # after a: d to a new 2, e..h to 3
          tmux list-clients -F '#S:#I #{b:pane_start_path}'
          tmux select-window -t =1:4
          tmux send-keys -K -c "$client" M-t # after c, the last: on to a new 2
          tmux list-clients -F '#S:#I'
          tmux list-windows -a -F '#S:#I#W'
          ${pkgs.tmux}/bin/tmux -L outer kill-server
          tmux kill-server
        ) || true
        overflow=$(printf '%s\n' "$overflow" | tr '\n' ' ')
        if [ "$overflow" = "1:2 C#S 2:1 1:1a 1:2sh 1:3b 1:4c 2:1sh 3:1d 4:1e 4:2f 4:3g 4:4h " ]; then
          ok "M-t in a full session opens the window after the current one and pushes the session's last window into a new session next to it"
        else
          fail "M-t in full sessions left '$overflow', expected '1:2 C#S 2:1 1:1a 1:2sh 1:3b 1:4c 2:1sh 3:1d 4:1e 4:2f 4:3g 4:4h '"
        fi

        # Moving a window to another session (C-M-Enter, M-S-<n>) closes up
        # the window numbers of the session it left, as closing a window does:
        # tmux skips renumber-windows for a move-window given -s. With one
        # session, C-M-Enter does nothing, and shows nothing over the pane
        # (send-keys -K prints what a binding's run-shell would show there).
        moves=$(
          PATH=${self}/bin:$PATH
          fresh
          tmux new-session -d -s 1 -n a sleep 60 \; new-window -d -t =1: -n b sleep 60 \; \
            new-window -d -t =1: -n c sleep 60 \; select-window -t =1:2 \; \
            set-hook -g client-attached 'wait-for -S attached'
          ${pkgs.tmux}/bin/tmux -L outer -f /dev/null new-session -d 'env -u TMUX tmux attach -t =1'
          timeout 10 tmux wait-for attached
          client=$(tmux list-clients -F '#{client_name}')
          tmux send-keys -K -c "$client" C-M-Enter 2>&1
          tmux new-session -d -s 2 -n d sleep 60 \; new-window -d -t =2: -n e sleep 60
          tmux send-keys -K -c "$client" C-M-Enter # b, to the end of 2
          tmux list-windows -a -F '#S:#I#W' | tr '\n' ' '
          tmux select-window -t =2:2
          tmux send-keys -K -c "$client" M-S-1 # e, to 1 as its window 2
          tmux list-windows -a -F '#S:#I#W' | tr '\n' ' '
          ${pkgs.tmux}/bin/tmux -L outer kill-server
          tmux kill-server
        ) || true
        if [ "$moves" = "1:1a 1:2c 2:1d 2:2e 2:3b 1:1a 1:2e 1:3c 2:1d 2:2b " ]; then
          ok "a window moved to another session leaves no gap in the numbers of the one it left; with one session, C-M-Enter does nothing"
        else
          fail "C-M-Enter with one session, then on b of 1 (a b c), then M-S-1 on e of 2 (d e b), left '$moves', expected '1:1a 1:2c 2:1d 2:2e 2:3b 1:1a 1:2e 1:3c 2:1d 2:2b '"
        fi

        # When a session closes, the numbered ones close up to 1..N, a session
        # 0 too (plain `tmux` names its first session 0): 0 1 3 becomes 1 2 3.
        renumber=$(
          PATH=${self}/bin:$PATH
          fresh
          tmux new-session -d sleep 60 \; new-session -d -s 1 sleep 60 \; \
            new-session -d -s 2 sleep 60 \; new-session -d -s 3 sleep 60 \; kill-session -t =2
          for _ in $(seq 50); do
            [ "$(tmux list-sessions -F '#S' | tr '\n' ' ')" = "1 2 3 " ] && break
            sleep 0.1
          done
          tmux list-sessions -F '#S' | tr '\n' ' '
          tmux kill-server
        ) || true
        if [ "$renumber" = "1 2 3 " ]; then
          ok "sessions close up to 1..N when one closes, a session 0 included"
        else
          fail "sessions 0 1 2 3, after closing 2, are '$renumber', expected '1 2 3 '"
        fi

        # Next and previous session go in the bar's order, by number, not by
        # name as text (1 10 2 …): from 9, M-Tab, C-`, C-S-Enter, M-BTab,
        # C-Enter and C-S-` (Alacritty sends Ctrl+` / Ctrl+~ as CSI-u C-` /
        # C-S-`) go to 10 1 10 9 10 9. And a client whose session closes goes
        # to the one before it by number: closing 2 lands on 1, where
        # detach-on-destroy picks 10.
        cycle=$(
          PATH=${self}/bin:$PATH
          fresh
          tmux new-session -d -s 1 sleep 60 \; set-hook -g client-attached 'wait-for -S attached'
          for n in 2 3 4 5 6 7 8 9 10; do tmux new-session -d -s "$n" sleep 60; done
          ${pkgs.tmux}/bin/tmux -L outer -f /dev/null new-session -d 'env -u TMUX tmux attach -t =9'
          timeout 10 tmux wait-for attached
          client=$(tmux list-clients -F '#{client_name}')
          for key in M-Tab 'C-`' C-S-Enter M-BTab C-Enter 'C-S-`'; do
            tmux send-keys -K -c "$client" "$key"
            tmux list-clients -F '#S'
          done
          tmux switch-client -c "$client" -t =2 \; kill-pane -t =2:
          for _ in $(seq 50); do
            [ "$(tmux list-clients -F '#S')" = 1 ] && break
            sleep 0.1
          done
          tmux list-clients -F '#S'
          ${pkgs.tmux}/bin/tmux -L outer kill-server
          tmux kill-server
        ) || true
        cycle=$(printf '%s\n' "$cycle" | tr '\n' ' ')
        if [ "$cycle" = "10 1 10 9 10 9 1 " ]; then
          ok "next and previous session go by number, from 9 to 10, and closing a session lands on the one before it by number"
        else
          fail "from 9 of 10 sessions, M-Tab C-\` C-S-Enter M-BTab C-Enter C-S-\`, then closing 2, left '$cycle', expected '10 1 10 9 10 9 1 '"
        fi

        # C-Enter in copy mode opens the link under the cursor instead, and the
        # pane stays in copy mode: a URL from any of its characters, the whole
        # of one that wrapped onto the next line (the pane is 30 columns wide,
        # the client's), without what prose puts around it, and an OSC 8 link,
        # which is how Claude marks its Markdown links, from its text. A cursor
        # on no link opens nothing, and word-separators, emptied for the read,
        # is as it was. C-Enter is pressed through an attached client, as M-t
        # is above. A stand-in xdg-open records what it is handed; it runs in
        # the background, so the records are sorted.
        links=$(
          mkdir "$HOME/bin"
          printf '%s\n' '#!${pkgs.bash}/bin/sh' 'printf "%s\n" "$1" >>"$HOME/opened"' >"$HOME/bin/xdg-open"
          chmod +x "$HOME/bin/xdg-open"
          PATH=$HOME/bin:${self}/bin:$PATH
          fresh
          tmux start-server \; set -g default-shell "$(command -v sh)" \; \
            new-session -d -s 1 -x 30 -y 9 "printf '%s\n' 'no link here' 'go to https://a.example/p.' '(see <https://b.example/q>)' 'wiki https://c.example/a_(b)).' 'https://d.example/0123456789abcdef'; printf '\033]8;;https://e.example/z\033\\\\the docs\033]8;;\033\\\\\n'; sleep 60" \; \
            set-hook -g client-attached 'wait-for -S attached'
          ${pkgs.tmux}/bin/tmux -L outer -f /dev/null new-session -d -x 30 -y 10 'env -u TMUX tmux attach -t =1'
          timeout 10 tmux wait-for attached
          client=$(tmux list-clients -F '#{client_name}')
          for _ in $(seq 50); do
            case $(tmux capture-pane -p -t =1:) in *docs*) break ;; esac
            sleep 0.1
          done
          ws=$(tmux show -gv word-separators)
          tmux copy-mode -t =1:
          for text in link example/p https://b 'a_(b' cdef docs; do
            tmux send-keys -X -t =1: history-top \; send-keys -X -t =1: search-forward-text "$text"
            tmux send-keys -K -c "$client" C-Enter
          done
          for _ in $(seq 50); do
            [ "$(wc -l <"$HOME/opened")" -ge 5 ] && break
            sleep 0.1
          done 2>/dev/null
          sort "$HOME/opened"
          [ "$(tmux show -gv word-separators)" = "$ws" ] && echo separators
          tmux display -p -t =1: '#{pane_in_mode}'
          ${pkgs.tmux}/bin/tmux -L outer kill-server
          tmux kill-server
        ) || true
        links=$(printf '%s\n' "$links" | tr '\n' ' ')
        if [ "$links" = "https://a.example/p https://b.example/q https://c.example/a_(b) https://d.example/0123456789abcdef https://e.example/z separators 1 " ]; then
          ok "C-Enter in copy mode opens the link under the cursor, a wrapped URL or an OSC 8 link's text included, and stays in copy mode"
        else
          fail "C-Enter in copy mode on no link, then on the URLs a to d and the OSC 8 link e, left '$links', expected 'https://a.example/p https://b.example/q https://c.example/a_(b) https://d.example/0123456789abcdef https://e.example/z separators 1 '"
        fi

        # Closing a session's last window moves its clients to the previous
        # session, the one left of it in the status bar, instead of detaching.
        dod=$(fresh; ${self}/bin/tmux start-server \; show -gv detach-on-destroy \; kill-server 2>/dev/null)
        if [ "$dod" = "previous" ]; then
          ok "closing a session's last window focuses the previous session"
        else
          fail "detach-on-destroy is '$dod', expected 'previous'"
        fi

        # Sessions render sorted by their number (not #{S:}'s creation order) so a
        # drag can reorder them; the sort is unrolled one filtered pass per number.
        sl=$(fresh; ${self}/bin/tmux start-server \; show -gv status-left \; kill-server 2>/dev/null)
        case "$sl" in
          *"session_name},1}"*"session_name},2}"*"session_name},3}"*) ok "status-left renders sessions sorted by number" ;;
          *) fail "status-left is not the number-sorted unroll: '$sl'" ;;
        esac

        # A click on the bar goes by the click range under the pointer, not by
        # mouse_x, which counts from a pane. Every cell between
        # two names is in the range of one of them, so a click there picks the
        # nearer: a session label's range takes the space on either side of it
        # (none before the first), and a window's range one space at each end,
        # in place of window-status-separator, which tmux draws outside the
        # ranges. In the bar as tmux expands it, ( and ) below are where a
        # range starts and ends, and ranges that touch leave no cell between.
        ranges=$(
          PATH=${self}/bin:$PATH
          fresh
          tmux new-session -d -s 1 -n a sleep 60 \; new-window -d -t =1: -n b sleep 60 \; \
            new-session -d -s 2 sleep 60 \; display -p -t =1: '#{E:status-format[0]}'
          tmux kill-server
        ) || true
        ranges=$(printf '%s\n' "$ranges" | sed -E -e 's/#\[[^]]*range=(session|window)[|][^]]*\]/(/g' -e 's/#\[norange[^]]*\]/)/g' -e 's/#\[[^]]*\]//g')
        slabel="$ranges $(binding root MouseDown1Status)"
        case "$slabel" in
          *"(1 )( 2 )"*"( 1 a )( 2 b )"*"session}\" { switch-client -t = ;"*) ok "a click on the bar, on a name or between two, picks the name under or nearest the pointer" ;;
          *) fail "bar click ranges / MouseDown1Status are '$slabel'" ;;
        esac

        # The current session's AI label (packages/tmux-session-name) shows
        # right after the session numbers, and each window's one-word AI name
        # in place of its program: switching sessions or windows runs the
        # labeller, and M-N pins a typed label or asks the model again.
        label=$(fresh; ${self}/bin/tmux start-server \; show -gv status-left \; show -gv window-status-current-format \; show -gv window-status-format \; show-hooks -g \; kill-server 2>/dev/null)$(binding root M-N)
        case "$label" in
          *"session_name},10}"*"#{@label}"*"#I #{?@wlabel,#{@wlabel},#W}"*"#I #{?@wlabel,#{@wlabel},#W}"*"client-session-changed[0] run-shell"*tmux-session-name*"session-window-changed[0] run-shell"*tmux-session-name*"@label_pin"*"tmux-session-name -force"*) ok "the bar shows the session's AI label and the windows' AI names, refreshed on switches; M-N sets the label" ;;
          *) fail "status-left label / window formats / label hooks / M-N are '$label'" ;;
        esac

        # A window whose Claude waits for you, its title "✳ <topic>" rather
        # than a ◐/◑ spinner, gets a * after its name, and its session one
        # after its number, though the window isn't the session's current
        # one; another program's ✳ title doesn't count. The stand-in claude
        # runs as the real one does on both systems: nixpkgs' claude runs the
        # file .claude-wrapped as claude, and tmux names a pane's program after
        # its argv[0] on Linux but after the file run on macOS. So it is a copy
        # of bash by that name, run as claude, which signals once it runs. -u:
        # the build has no UTF-8 locale, and tmux would print a non-ASCII mark
        # as _.
        idle=$(
          PATH=${self}/bin:$PATH
          fresh
          cp ${pkgs.bash}/bin/bash "$HOME/.claude-wrapped"
          tmux start-server \; set -g default-shell "$(command -v sh)" \; \
            new-session -d -s 1 -n a sleep 60 \; \
            new-window -d -t =1: -n b "exec -a claude $HOME/.claude-wrapped -c 'tmux wait-for -S up; sleep 60; :'" \; \
            new-session -d -s 2 sleep 60
          timeout 10 tmux wait-for up
          tmux select-pane -t =1:1 -T '✳ Docs'
          for title in '✳ Docs' '◐ Docs'; do
            tmux -u select-pane -t =1:2 -T "$title" \; \
              display -p -t =1:2 '#{E:window-status-current-format}|#{E:window-status-format}|#{E:status-left}'
          done
          tmux -u display -p -t =1:1 '#{E:window-status-format}'
          tmux kill-server
        ) || true
        idle=$(printf '%s\n' "$idle" | sed 's/#\[[^]]*\]//g' | tr '\n' ';' | tr -s ' ')
        if [ "$idle" = " 2 b* | 2 b* |1* 2 ; 2 b | 2 b |1 2 ; 1 a ;" ]; then
          ok "a window whose Claude waits for you gets a * after its name, and its session after its number"
        else
          fail "window 2 of session 1, with an idle then a busy claude, and the bar's sessions, then window 1 with a ✳ title, are '$idle', expected ' 2 b* | 2 b* |1* 2 ; 2 b | 2 b |1 2 ; 1 a ;'"
        fi

        # The stand-in titles its pane as the packaged claude does; check that
        # it still does. Its title code declares the ◐/◑ spinner and then the ✳
        # that @claude_idle matches, as \u escapes in the bundle, and the file
        # is .claude-wrapped, the name tmux sees on macOS. A failure means a
        # claude-code update changed one of them: see what claude writes now.
        if grep -aqE '\["\\u25D0","\\u25D1"],[[:alnum:]_$]+="\\u2733"' ${pkgs.claude-code}/bin/.claude-wrapped; then
          ok "the packaged claude, .claude-wrapped, still has the ◐/◑ title spinner and the ✳ the idle mark matches"
        else
          fail "${pkgs.claude-code}/bin/.claude-wrapped is missing, or no longer declares the title spinner \\u25D0/\\u25D1 followed by \\u2733: see what claude titles its pane now, and update @claude_idle"
        fi

        # Programs inside tmux can neither set nor read the clipboard through it,
        # and messages still clear the status line they are drawn over (tmux 3.7+).
        opts=$(fresh; ${self}/bin/tmux start-server \; show -sv set-clipboard \; show -sv get-clipboard \; show -gv message-style \; kill-server 2>/dev/null)
        case "$opts" in
          external*off*fill=terminal*) ok "panes can't set or read the clipboard; messages clear the status line" ;;
          *) fail "set-clipboard / get-clipboard / message-style are '$opts'" ;;
        esac

        # tmux can't detect that Alacritty takes synchronized updates; without
        # them, the cursor blinks on every move in fzf.
        features=$(fresh; ${self}/bin/tmux start-server \; show -sv terminal-features \; kill-server 2>/dev/null)
        case "$features" in
          *alacritty:sync*) ok "tmux synchronizes its redraws in Alacritty" ;;
          *) fail "terminal-features lacks alacritty:sync: '$features'" ;;
        esac
      '';
    };
  };
in
self
