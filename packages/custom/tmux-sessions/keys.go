package main

import "unicode/utf8"

// Key decoding.
//
// The whole reason this program exists instead of an fzf popup: fzf rejects
// `alt-tab` outright ("unsupported key"), so Alt+Tab can never drive its
// selection. Reading the byte stream ourselves is the only way to bind it.
//
// Alt+Tab reaches us in one of three encodings depending on how the terminal
// and tmux negotiate modifiers:
//
//	ESC TAB          "8-bit meta" — Alacritty's default for Alt+<key>
//	CSI 9 ; 3 u      kitty-style extended keys — what tmux emits under
//	                 `set -s extended-keys always` (set in our tmux.conf)
//	CSI 27 ; 3 ; 9 ~ xterm modifyOtherKeys, the older form of the same idea
//
// All three are decoded, so the binding survives a change to `extended-keys`
// or a different terminal, rather than silently degrading to a bare Escape.

type keyKind int

const (
	keyNone       keyKind = iota // recognised, but nothing is bound to it
	keyIncomplete                // a prefix — decide once more bytes arrive
	keyRune                      // printable input, appended to the filter
	keyNext
	keyPrev
	keyAccept
	keyCancel
	keyBackspace
	keyClearLine
	keyClearWord
)

type key struct {
	kind keyKind
	r    rune
	n    int // bytes consumed
}

// Modifier bitmask as encoded by CSI-u and modifyOtherKeys: the parameter is
// 1 + the mask, where 1=shift, 2=alt, 4=ctrl. So 3=alt, 4=alt+shift.
const (
	modShift = 1 << 0
	modAlt   = 1 << 1
)

// decode reads one key from the front of b.
//
// settled reports that no further bytes are expected imminently — the caller
// sets it after the escape-timeout expires. It is what separates a bare Escape
// (cancel) from the ESC that merely prefixes Alt+<key>; without it a lone ESC
// and the start of Alt+Tab are indistinguishable.
func decode(b []byte, settled bool) key {
	if len(b) == 0 {
		return key{kind: keyIncomplete}
	}

	switch b[0] {
	case 0x1b:
		return decodeEsc(b, settled)
	case '\r', '\n': // Enter, and C-j which shares 0x0a
		return key{kind: keyAccept, n: 1}
	case '\t':
		return key{kind: keyNext, n: 1}
	case 0x7f, 0x08:
		return key{kind: keyBackspace, n: 1}
	case 0x03, 0x07: // C-c, C-g
		return key{kind: keyCancel, n: 1}
	case 0x15: // C-u
		return key{kind: keyClearLine, n: 1}
	case 0x17: // C-w
		return key{kind: keyClearWord, n: 1}
	case 0x0e: // C-n
		return key{kind: keyNext, n: 1}
	case 0x10: // C-p
		return key{kind: keyPrev, n: 1}
	}

	if b[0] < 0x20 {
		return key{kind: keyNone, n: 1}
	}

	r, size := utf8.DecodeRune(b)
	if r == utf8.RuneError && size <= 1 {
		// Possibly a multi-byte rune split across reads.
		if !settled && len(b) < utf8.UTFMax {
			return key{kind: keyIncomplete}
		}
		return key{kind: keyNone, n: 1}
	}
	return key{kind: keyRune, r: r, n: size}
}

func decodeEsc(b []byte, settled bool) key {
	if len(b) == 1 {
		if settled {
			return key{kind: keyCancel, n: 1} // a genuine, lone Escape
		}
		return key{kind: keyIncomplete}
	}

	switch b[1] {
	case '\t': // ESC TAB — Alt+Tab
		return key{kind: keyNext, n: 2}

	case 0x1b:
		// ESC ESC ... — Alt held over a sequence that is itself escape-prefixed,
		// which is how Alt+Shift+Tab arrives as ESC ESC [ Z.
		inner := decodeEsc(b[1:], settled)
		if inner.kind == keyIncomplete {
			return key{kind: keyIncomplete}
		}
		switch inner.kind {
		case keyNext, keyPrev:
			return key{kind: inner.kind, n: inner.n + 1}
		}
		return key{kind: keyNone, n: inner.n + 1}

	case '[':
		return decodeCSI(b, settled)

	case 'O': // SS3 — arrows in application cursor mode
		if len(b) < 3 {
			if settled {
				return key{kind: keyNone, n: 2}
			}
			return key{kind: keyIncomplete}
		}
		switch b[2] {
		case 'A':
			return key{kind: keyPrev, n: 3}
		case 'B':
			return key{kind: keyNext, n: 3}
		}
		return key{kind: keyNone, n: 3}
	}

	// ESC <char> — some other Alt+<key>; consume both so the ESC is not
	// re-read as a cancel on the next pass.
	return key{kind: keyNone, n: 2}
}

func decodeCSI(b []byte, settled bool) key {
	// CSI parameter and intermediate bytes span 0x20..0x3f; the first byte
	// outside that range terminates the sequence.
	i := 2
	for i < len(b) && b[i] >= 0x20 && b[i] <= 0x3f {
		i++
	}
	if i >= len(b) {
		if settled {
			return key{kind: keyNone, n: len(b)}
		}
		return key{kind: keyIncomplete}
	}

	params := parseParams(b[2:i])
	n := i + 1

	switch b[i] {
	case 'Z': // CSI Z — Shift+Tab
		return key{kind: keyPrev, n: n}
	case 'A':
		return key{kind: keyPrev, n: n}
	case 'B':
		return key{kind: keyNext, n: n}

	case 'u': // CSI <code> ; <mods> u
		code, mods := at(params, 0), at(params, 1)
		return tabAware(code, mods, n)

	case '~':
		// CSI 27 ; <mods> ; <code> ~ — modifyOtherKeys. Anything else with a
		// '~' final (Home, PgUp, …) is not bound.
		if len(params) == 3 && params[0] == 27 {
			return tabAware(params[2], params[1], n)
		}
		return key{kind: keyNone, n: n}
	}

	return key{kind: keyNone, n: n}
}

// tabAware maps an extended-key (code, mods) pair onto a binding. Shift
// reverses direction, which is what makes Alt+Shift+Tab walk the list
// backwards exactly as Alt+Tab walks it forwards.
func tabAware(code, mods, n int) key {
	mask := 0
	if mods > 0 {
		mask = mods - 1
	}
	switch code {
	case 9: // Tab
		if mask&modShift != 0 {
			return key{kind: keyPrev, n: n}
		}
		return key{kind: keyNext, n: n}
	case 13: // Enter
		return key{kind: keyAccept, n: n}
	case 27: // Escape
		return key{kind: keyCancel, n: n}
	}
	return key{kind: keyNone, n: n}
}

func parseParams(b []byte) []int {
	if len(b) == 0 {
		return nil
	}
	out := []int{}
	cur, seen := 0, false
	for _, c := range b {
		switch {
		case c >= '0' && c <= '9':
			cur, seen = cur*10+int(c-'0'), true
		case c == ';':
			out, cur, seen = append(out, cur), 0, false
		default:
			// Private-parameter markers such as '?' or '<'; ignore.
		}
	}
	if seen || len(out) > 0 {
		out = append(out, cur)
	}
	return out
}

func at(p []int, i int) int {
	if i < len(p) {
		return p[i]
	}
	return 0
}
