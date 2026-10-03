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
      staticEnv = {
        TMUX_SHELL = "${zsh}/bin/zsh";
        NIX_OUT_TMUX = "@OUT@";
      };
      flags = [
        "-f"
        "$PERMEANCE_ROOT/.config/tmux/tmux.conf"
      ];
    };
    passthru.tests.smoke = permeance.tests.mkSmoke {
      name = "tmux";
      description = "Verify tmux config loads without errors, uses the zsh wrapper, enables resurrect pane-content capture, limits passthrough to visible panes, yanks via copy-selection, reorders windows by dragging their status-bar name, and renders sessions sorted-by-number so they can be dragged to reorder too";
      script = ''
        # No explicit -f — let the launcher's flags = [ "-f" "$PERMEANCE_ROOT/.config/tmux/tmux.conf" ]
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
        # window/pane table, so -gw (a plain -g comes back empty).
        passthrough=$(${self}/bin/tmux start-server \; show-options -gwv allow-passthrough \; kill-server 2>/dev/null)
        if [ "$passthrough" = "on" ]; then
          ok "allow-passthrough limited to visible panes"
        else
          fail "allow-passthrough is '$passthrough', expected 'on'"
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

        # Programs inside tmux can neither set nor read the clipboard through it,
        # and messages still clear the status line they are drawn over (tmux 3.7+).
        opts=$(${self}/bin/tmux start-server \; show -sv set-clipboard \; show -sv get-clipboard \; show -gv message-style \; kill-server 2>/dev/null)
        case "$opts" in
          external*off*fill=terminal*) ok "panes can't set or read the clipboard; messages clear the status line" ;;
          *) fail "set-clipboard / get-clipboard / message-style are '$opts'" ;;
        esac
      '';
    };
  };
in
self
