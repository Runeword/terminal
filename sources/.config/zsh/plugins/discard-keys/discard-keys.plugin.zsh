# discard-keys - Prevent unhandled escape sequences from printing garbage in the prompt.
#
# Terminal emulators and multiplexers encode modified key combos as CSI sequences.
# When zsh has no binding for one, the raw bytes leak into the command line.
#
# These sequences cannot be enumerated with bindkey: the CSI u form carries an
# arbitrary Unicode codepoint, a 1-256 modifier, an event type, and a
# variable-length text field, so the set is unbounded. Bind the CSI prefix
# instead and consume the sequence up to its final byte (ECMA-48: 0x40-0x7E).
#
# zle prefers the longest match, so specific bindings still win over this
# catch-all - \e[A, \e[1;5D, and bracketed paste (\e[200~) are unaffected.
#
# Source this BEFORE your real keybindings.

__discard-csi() {
  local c
  # Parameter and intermediate bytes are 0x20-0x3F; the first byte in 0x40-0x7E
  # ends the sequence. The timeout bounds a lone, hand-typed \e[.
  while read -k 1 -t 0.1 c; do
    case $c in ([@-~]) break ;; esac
  done
}
zle -N __discard-csi
bindkey $'\e[' __discard-csi
