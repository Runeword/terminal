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
      description = "Verify tmux config loads without errors, uses the zsh wrapper, enables resurrect pane-content capture, turns passthrough off, yanks via copy-selection, reorders windows by dragging their status-bar name, renders sessions sorted-by-number so they can be dragged to reorder too, keeps M-t's window after the current one in a full session by pushing the session's last window into a new session next to it, shows the current session's AI label after the session numbers and each window's one-word AI name in place of its program, both made on session and window switches, the label also set with M-N, marks the windows whose Claude waits for you, and tells tmux that Alacritty takes synchronized updates";
      script = ''
        # No explicit -f — let the launcher's flags = [ "-f" "''${permeance.root}/.config/tmux/tmux.conf" ]
        # provide it, so the smoke exercises the launcher's flag routing. start-server
        # exits 0 and prints nothing even when that load fails: tmux keeps its parse
        # and command errors until the next source-file prints them, so source
        # /dev/null.
        if err=$(${self}/bin/tmux start-server \; source-file /dev/null \; kill-server 2>&1) && [ -z "$err" ]; then
          ok "tmux.conf loads without errors (via launcher -f routing)"
        else
          fail "tmux.conf: ''${err:-tmux exited non-zero}"
        fi

        tmux_shell=$(${self}/bin/tmux start-server \; show-option -gv default-shell \; kill-server 2>/dev/null)
        if [ "$tmux_shell" = "${zsh}/bin/zsh" ]; then
          ok "default-shell is zsh wrapper"
        else
          fail "default-shell is '$tmux_shell', expected '${zsh}/bin/zsh'"
        fi

        cap=$(${self}/bin/tmux start-server \; show-option -gqv @resurrect-capture-pane-contents \; kill-server 2>/dev/null)
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
        passthrough=$(${self}/bin/tmux start-server \; show-options -gwv allow-passthrough \; kill-server 2>/dev/null)
        if [ "$passthrough" = "off" ]; then
          ok "panes can't pass escape sequences through to the terminal"
        else
          fail "allow-passthrough is '$passthrough', expected 'off'"
        fi

        # The binding of one key, read from its whole table: since tmux 3.7 a
        # list-keys that matches a single key shows it as a status message
        # instead of printing it.
        binding() {
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

        # Dragging a window's status-bar name reorders it. swap-window's -t= can't
        # resolve the window under the pointer, so the swap is routed through the
        # marked window: MouseDown marks the grabbed window (select-pane -m) and each
        # MouseDrag swaps it toward the pointer via swap-window. Assert both halves.
        grab=$(binding root MouseDown1Status)
        case "$grab" in
          *"select-pane -m"*) ok "MouseDown1Status marks the grabbed window" ;;
          *) fail "MouseDown1Status is '$grab', expected select-pane -m" ;;
        esac

        drag=$(binding root MouseDrag1Status)
        case "$drag" in
          *swap-window*) ok "MouseDrag1Status reorders windows via swap-window" ;;
          *) fail "MouseDrag1Status is '$drag', expected swap-window" ;;
        esac

        # The grab survives the pointer straying below the titles: MouseDrag1Pane gates
        # copy-mode on the @wdrag flag so a downward stray doesn't hijack the drag.
        pdrag=$(binding root MouseDrag1Pane)
        case "$pdrag" in
          *@wdrag*copy-mode*) ok "MouseDrag1Pane gates copy-mode on the window-drag flag" ;;
          *) fail "MouseDrag1Pane is '$pdrag', expected @wdrag-gated copy-mode" ;;
        esac

        # Below the bar mouse_x counts from the pane's left edge, so the window drag
        # adds pane_left; and a pane border it crosses doesn't start a pane resize.
        below="$pdrag $(binding root MouseDrag1Border)"
        case "$below" in
          *"#{e|+:#{mouse_x},#{pane_left}}"*"if-shell -F \"#{||:#{@wdrag},#{@sdrag}}\" {  } { resize-pane -M }"*) ok "window drags below the bar count screen columns and skip border resizes" ;;
          *) fail "MouseDrag1Pane / MouseDrag1Border are '$below'" ;;
        esac

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
        keys=$(${self}/bin/tmux start-server \; list-keys -T root \; kill-server 2>/dev/null)
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
        # needs (a client-attached hook signals it is attached). list-clients
        # reads where the client is: display-message -c expands its format for
        # the newest session. New windows run sh, so that is their name.
        overflow=$(
          PATH=${self}/bin:$PATH
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

        # Ctrl+` / Ctrl+~ cycle sessions; Alacritty sends them as CSI-u C-` / C-S-`.
        # Ctrl+Space (NUL) goes to the next session too, like Ctrl+`.
        cycle="$(binding root 'C-`') / $(binding root 'C-S-`') / $(binding root C-Space)"
        if [ "$cycle" = "switch-client -n / switch-client -p / switch-client -n" ]; then
          ok 'C-` and C-Space / C-S-` switch to the next / previous session'
        else
          fail "C-\` / C-S-\` / C-Space are '$cycle'"
        fi

        # Closing a session's last window moves its clients to the previous
        # session, the one left of it in the status bar, instead of detaching.
        dod=$(${self}/bin/tmux start-server \; show -gv detach-on-destroy \; kill-server 2>/dev/null)
        if [ "$dod" = "previous" ]; then
          ok "closing a session's last window focuses the previous session"
        else
          fail "detach-on-destroy is '$dod', expected 'previous'"
        fi

        # Sessions render sorted by their number (not #{S:}'s creation order) so a
        # drag can reorder them; the sort is unrolled one filtered pass per number.
        sl=$(${self}/bin/tmux start-server \; show -gv status-left \; kill-server 2>/dev/null)
        case "$sl" in
          *"session_name},1}"*"session_name},2}"*"session_name},3}"*) ok "status-left renders sessions sorted by number" ;;
          *) fail "status-left is not the number-sorted unroll: '$sl'" ;;
        esac

        # A session label's range stops after its first space (tmux ends a range a
        # cell late, so one over both spaces took the next label's first cell), and
        # a click or a drag along the bar goes by the range under the pointer, not
        # by mouse_x, which counts from a pane.
        slabel="$sl $(binding root MouseDown1Status) $(binding root MouseDrag1Status)"
        case "$slabel" in
          *"#{session_name} #[norange] "*"session}\" { switch-client -t = ;"*"#{!=:#{session_name},#{client_session}}"*) ok "a click or drag on a session label resolves the label under the pointer" ;;
          *) fail "session label ranges / MouseDown1Status / MouseDrag1Status are '$slabel'" ;;
        esac

        # Dragging a session name reorders it by swapping numbers (tmux has no
        # swap-session): the pane handler routes a session grab through the helper.
        sdrag=$(binding root MouseDrag1Pane)
        case "$sdrag" in
          *__tmux_drag_session*) ok "session drag reorders via __tmux_drag_session" ;;
          *) fail "MouseDrag1Pane lacks __tmux_drag_session session wiring" ;;
        esac

        # The current session's AI label (packages/tmux-session-name) shows
        # right after the session numbers, and each window's one-word AI name
        # in place of its program: switching sessions or windows runs the
        # labeller, and M-N pins a typed label or asks the model again.
        label=$(${self}/bin/tmux start-server \; show -gv status-left \; show -gv window-status-current-format \; show -gv window-status-format \; show-hooks -g \; kill-server 2>/dev/null)$(binding root M-N)
        case "$label" in
          *"session_name},10}"*"#{@label}"*"#I #{?@wlabel,#{@wlabel},#W}"*"#I #{?@wlabel,#{@wlabel},#W}"*"client-session-changed[0] run-shell"*tmux-session-name*"session-window-changed[0] run-shell"*tmux-session-name*"@label_pin"*"tmux-session-name -force"*) ok "the bar shows the session's AI label and the windows' AI names, refreshed on switches; M-N sets the label" ;;
          *) fail "status-left label / window formats / label hooks / M-N are '$label'" ;;
        esac

        # A window whose Claude waits for you, its title "✳ <topic>" rather
        # than a ◐/◑ spinner, gets a ● after its name; another program's ✳
        # title doesn't count. The stand-in claude is sh run as claude
        # (pane_current_command is the argv[0] of the pane's foreground
        # process), which signals once it runs. -u: the build has no UTF-8
        # locale, and tmux would print the ● as _.
        idle=$(
          PATH=${self}/bin:$PATH
          tmux start-server \; set -g default-shell "$(command -v sh)" \; \
            new-session -d -s t -n a "exec -a claude sh -c 'tmux wait-for -S up; sleep 60; :'" \; \
            new-window -d -t =t: -n b sleep 60
          timeout 10 tmux wait-for up
          tmux select-pane -t =t:2 -T '✳ Docs'
          for title in '✳ Docs' '◐ Docs'; do
            tmux -u select-pane -t =t:1 -T "$title" \; \
              display -p -t =t:1 '#{E:window-status-current-format}|#{E:window-status-format}'
          done
          tmux -u display -p -t =t:2 '#{E:window-status-format}'
          tmux kill-server
        ) || true
        idle=$(printf '%s\n' "$idle" | sed 's/#\[[^]]*\]//g' | tr '\n' ' ')
        if [ "$idle" = "1 a ●|1 a ● 1 a|1 a 2 b " ]; then
          ok "a window whose Claude waits for you gets a ● after its name"
        else
          fail "windows with an idle, then a busy claude in 1 and a ✳ title in 2 are '$idle', expected '1 a ●|1 a ● 1 a|1 a 2 b '"
        fi

        # Programs inside tmux can neither set nor read the clipboard through it,
        # and messages still clear the status line they are drawn over (tmux 3.7+).
        opts=$(${self}/bin/tmux start-server \; show -sv set-clipboard \; show -sv get-clipboard \; show -gv message-style \; kill-server 2>/dev/null)
        case "$opts" in
          external*off*fill=terminal*) ok "panes can't set or read the clipboard; messages clear the status line" ;;
          *) fail "set-clipboard / get-clipboard / message-style are '$opts'" ;;
        esac

        # tmux can't detect that Alacritty takes synchronized updates; without
        # them, the cursor blinks on every move in fzf.
        features=$(${self}/bin/tmux start-server \; show -sv terminal-features \; kill-server 2>/dev/null)
        case "$features" in
          *alacritty:sync*) ok "tmux synchronizes its redraws in Alacritty" ;;
          *) fail "terminal-features lacks alacritty:sync: '$features'" ;;
        esac
      '';
    };
  };
in
self
