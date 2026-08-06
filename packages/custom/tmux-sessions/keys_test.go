package main

import "testing"

// The encodings Alt+Tab can arrive in are the whole reason this program is not
// an fzf popup, so they are pinned here explicitly.
func TestDecodeAltTab(t *testing.T) {
	tests := []struct {
		name  string
		input []byte
		want  keyKind
		n     int
	}{
		{"esc-prefixed alt+tab", []byte("\x1b\t"), keyNext, 2},
		{"csi-u alt+tab", []byte("\x1b[9;3u"), keyNext, 6},
		{"csi-u plain tab", []byte("\x1b[9;1u"), keyNext, 6},
		{"modifyOtherKeys alt+tab", []byte("\x1b[27;3;9~"), keyNext, 9},
		{"bare tab", []byte("\t"), keyNext, 1},

		{"shift+tab", []byte("\x1b[Z"), keyPrev, 3},
		{"alt+shift+tab esc-prefixed", []byte("\x1b\x1b[Z"), keyPrev, 4},
		{"csi-u alt+shift+tab", []byte("\x1b[9;4u"), keyPrev, 6},
		{"csi-u shift+tab", []byte("\x1b[9;2u"), keyPrev, 6},
		{"modifyOtherKeys alt+shift+tab", []byte("\x1b[27;4;9~"), keyPrev, 9},

		{"arrow down", []byte("\x1b[B"), keyNext, 3},
		{"arrow up", []byte("\x1b[A"), keyPrev, 3},
		{"ss3 down", []byte("\x1bOB"), keyNext, 3},
		{"modified arrow up", []byte("\x1b[1;3A"), keyPrev, 6},

		{"enter", []byte("\r"), keyAccept, 1},
		{"csi-u enter", []byte("\x1b[13;1u"), keyAccept, 7},
		{"ctrl-c", []byte("\x03"), keyCancel, 1},
		{"ctrl-n", []byte("\x0e"), keyNext, 1},
		{"ctrl-p", []byte("\x10"), keyPrev, 1},
		{"backspace", []byte("\x7f"), keyBackspace, 1},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := decode(tc.input, true)
			if got.kind != tc.want {
				t.Errorf("decode(% x) kind = %v, want %v", tc.input, got.kind, tc.want)
			}
			if got.n != tc.n {
				t.Errorf("decode(% x) consumed %d bytes, want %d", tc.input, got.n, tc.n)
			}
		})
	}
}

// A lone ESC must cancel, but only once we know nothing follows it — otherwise
// the leading byte of Alt+Tab would abort the popup instead of moving.
func TestEscapeDisambiguation(t *testing.T) {
	if got := decode([]byte("\x1b"), false); got.kind != keyIncomplete {
		t.Errorf("unsettled ESC = %v, want keyIncomplete", got.kind)
	}
	if got := decode([]byte("\x1b"), true); got.kind != keyCancel {
		t.Errorf("settled ESC = %v, want keyCancel", got.kind)
	}
}

// Sequences split across reads must not be misread as their prefixes.
func TestPartialSequences(t *testing.T) {
	for _, partial := range []string{"\x1b[", "\x1b[9", "\x1b[9;", "\x1b[9;3", "\x1b[27;3;9", "\x1bO"} {
		if got := decode([]byte(partial), false); got.kind != keyIncomplete {
			t.Errorf("decode(%q) = %v, want keyIncomplete", partial, got.kind)
		}
	}
}

// Consuming a whole sequence matters as much as classifying it: leaving stray
// bytes in the buffer would replay them as spurious keys.
func TestDecodeStream(t *testing.T) {
	stream := []byte("\x1b\t\x1b[9;3uab\x1b[Z\r")
	want := []keyKind{keyNext, keyNext, keyRune, keyRune, keyPrev, keyAccept}

	var got []keyKind
	for len(stream) > 0 {
		k := decode(stream, true)
		if k.n == 0 {
			t.Fatalf("decoder stalled on % x", stream)
		}
		got = append(got, k.kind)
		stream = stream[k.n:]
	}

	if len(got) != len(want) {
		t.Fatalf("got %d keys %v, want %d %v", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("key %d = %v, want %v", i, got[i], want[i])
		}
	}
}

func TestRuneInput(t *testing.T) {
	k := decode([]byte("x"), true)
	if k.kind != keyRune || k.r != 'x' {
		t.Errorf("decode(x) = %v/%q, want keyRune/x", k.kind, k.r)
	}
	if k := decode([]byte("é"), true); k.kind != keyRune || k.n != 2 {
		t.Errorf("multi-byte rune = %v n=%d, want keyRune n=2", k.kind, k.n)
	}
}

func TestParseParams(t *testing.T) {
	tests := []struct {
		in   string
		want []int
	}{
		{"", nil},
		{"9;3", []int{9, 3}},
		{"27;4;9", []int{27, 4, 9}},
		{"1", []int{1}},
		{"9;", []int{9, 0}},
	}
	for _, tc := range tests {
		got := parseParams([]byte(tc.in))
		if len(got) != len(tc.want) {
			t.Errorf("parseParams(%q) = %v, want %v", tc.in, got, tc.want)
			continue
		}
		for i := range tc.want {
			if got[i] != tc.want[i] {
				t.Errorf("parseParams(%q)[%d] = %d, want %d", tc.in, i, got[i], tc.want[i])
			}
		}
	}
}
