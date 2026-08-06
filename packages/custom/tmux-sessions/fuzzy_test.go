package main

import "testing"

func TestFuzzyMatches(t *testing.T) {
	tests := []struct {
		pattern, s string
		want       bool
	}{
		{"", "anything", true},
		{"main", "main", true},
		{"mn", "main", true},
		{"tmx", "terminal-tmux", true},
		{"xyz", "main", false},
		{"MAIN", "main", true},
		{"main", "MAIN", true},
		{"nixos", "nix", false},
	}
	for _, tc := range tests {
		if _, ok := fuzzy(tc.pattern, tc.s); ok != tc.want {
			t.Errorf("fuzzy(%q, %q) = %v, want %v", tc.pattern, tc.s, ok, tc.want)
		}
	}
}

func TestFuzzyPositions(t *testing.T) {
	m, ok := fuzzy("mn", "main")
	if !ok {
		t.Fatal("expected match")
	}
	want := []int{0, 3} // m-a-i-n: the greedy scan takes the trailing n
	if len(m.positions) != len(want) {
		t.Fatalf("positions = %v, want %v", m.positions, want)
	}
	for i := range want {
		if m.positions[i] != want[i] {
			t.Errorf("positions[%d] = %d, want %d", i, m.positions[i], want[i])
		}
	}
}

// Ranking is what makes the top row the one you meant, since the selection
// jumps there and the client follows it immediately.
func TestFuzzyRanking(t *testing.T) {
	better := func(pattern, win, lose string) {
		t.Helper()
		a, ok1 := fuzzy(pattern, win)
		b, ok2 := fuzzy(pattern, lose)
		if !ok1 || !ok2 {
			t.Fatalf("fuzzy(%q): both should match %q and %q", pattern, win, lose)
		}
		if a.score <= b.score {
			t.Errorf("fuzzy(%q): %q scored %d, want more than %q at %d",
				pattern, win, a.score, lose, b.score)
		}
	}

	better("tm", "tmux", "the-m")             // prefix beats a boundary match
	better("nix", "nixos", "naibxc")          // consecutive beats gapped
	better("cfg", "cfgtool", "app/config")    // exact prefix outranks mid-path
	better("c", "a/config", "axconfig")       // after a separator beats mid-word
	better("main", "main", "main-experiment") // shorter wins on equal structure
}
