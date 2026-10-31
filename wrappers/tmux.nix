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
      description = "Verify tmux config loads without errors, uses the zsh wrapper, enables resurrect pane-content capture, turns passthrough off, yanks via copy-selection, reorders windows by dragging their status-bar name, renders sessions sorted-by-number so they can be dragged to reorder too, picks the nearer name when a click on the bar falls between two, keeps M-t's window after the current one in a full session by pushing the session's last window into a new session next to it, moves a window to another session without leaving a gap in the window numbers of the one it left, closes the session numbers up to 1..N even from a session 0, goes to the next and previous session by number and lands a client whose session closes on the one before it by number, shows the current session's AI label after the session numbers and each window's one-word AI name in place of its program, both made on session and window switches, the label also set with M-N, marks the windows and sessions whose Claude waits for you, and tells tmux that Alacritty takes synchronized updates";
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
          tmux kill-server
          ${pkgs.tmux}/bin/tmux -L outer kill-server
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
          tmux kill-server
          ${pkgs.tmux}/bin/tmux -L outer kill-server
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
          tmux kill-server
          ${pkgs.tmux}/bin/tmux -L outer kill-server
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
        # C-Space, C-Enter and C-S-` (Alacritty sends Ctrl+` / Ctrl+~ as CSI-u
        # C-` / C-S-`) go to 10 1 10 9 10 1 10. And a client whose session
        # closes goes to the one before it by number: closing 2 lands on 1,
        # where detach-on-destroy picks 10.
        cycle=$(
          PATH=${self}/bin:$PATH
          fresh
          tmux new-session -d -s 1 sleep 60 \; set-hook -g client-attached 'wait-for -S attached'
          for n in 2 3 4 5 6 7 8 9 10; do tmux new-session -d -s "$n" sleep 60; done
          ${pkgs.tmux}/bin/tmux -L outer -f /dev/null new-session -d 'env -u TMUX tmux attach -t =9'
          timeout 10 tmux wait-for attached
          client=$(tmux list-clients -F '#{client_name}')
          for key in M-Tab 'C-`' C-S-Enter M-BTab C-Space C-Enter 'C-S-`'; do
            tmux send-keys -K -c "$client" "$key"
            tmux list-clients -F '#S'
          done
          tmux switch-client -c "$client" -t =2 \; kill-pane -t =2:
          for _ in $(seq 50); do
            [ "$(tmux list-clients -F '#S')" = 1 ] && break
            sleep 0.1
          done
          tmux list-clients -F '#S'
          tmux kill-server
          ${pkgs.tmux}/bin/tmux -L outer kill-server
        ) || true
        cycle=$(printf '%s\n' "$cycle" | tr '\n' ' ')
        if [ "$cycle" = "10 1 10 9 10 1 10 1 " ]; then
          ok "next and previous session go by number, from 9 to 10, and closing a session lands on the one before it by number"
        else
          fail "from 9 of 10 sessions, M-Tab C-\` C-S-Enter M-BTab C-Space C-Enter C-S-\`, then closing 2, left '$cycle', expected '10 1 10 9 10 1 10 1 '"
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
