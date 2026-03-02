# discard-keys - Prevent unhandled escape sequences from printing garbage in the prompt.
#
# Terminal emulators and multiplexers encode modified key combos as escape sequences.
# When zsh doesn't have a binding for a sequence, the raw bytes leak into the prompt.
# This plugin binds all common formats to a no-op widget, silently discarding them.
#
# Formats covered:
#   CSI u (Kitty/Alacritty)      \e[<keycode>;<modifier>u
#   Modified function keys        \e[<keycode>;<modifier>~
#   Modified cursor/F1-F4 keys   \e[1;<modifier><A-S>
#   xterm modifyOtherKeys (tmux)  \e[27;<modifier>;<keycode>~
#
# Modifiers: 2=Shift 3=Alt 4=Alt+Shift 5=Ctrl 6=Ctrl+Shift 7=Ctrl+Alt 8=Ctrl+Alt+Shift
#
# Source this BEFORE your real keybindings so they can override specific sequences.

__discard-key() { }
zle -N __discard-key

() {
  local key mod

  # CSI u format: \e[<keycode>;<modifier>u
  # Covers all ASCII keycodes (1-127)
  for key in {1..127}; do
    for mod in 2 3 4 5 6 7 8; do
      bindkey $'\e'"[${key};${mod}u" __discard-key
    done
  done

  # Modified function key format: \e[<keycode>;<modifier>~
  # Covers: Home, Insert, Delete, End, PageUp, PageDown (1-6), F1-F12 (11-24)
  for key in {1..6} {11..24}; do
    for mod in 2 3 4 5 6 7 8; do
      bindkey $'\e'"[${key};${mod}~" __discard-key
    done
  done

  # Modified cursor keys: \e[1;<modifier><letter>
  # Covers: arrows (A-D), Begin (E), End (F), Home (H), F1-F4 (P-S)
  for key in A B C D E F H P Q R S; do
    for mod in 2 3 4 5 6 7 8; do
      bindkey $'\e'"[1;${mod}${key}" __discard-key
    done
  done

  # xterm modifyOtherKeys format: \e[27;<modifier>;<keycode>~
  # Covers all ASCII keycodes (1-127)
  for key in {1..127}; do
    for mod in 2 3 4 5 6 7 8; do
      bindkey $'\e'"[27;${mod};${key}~" __discard-key
    done
  done
}
