package main

import "strings"

// Fuzzy subsequence matching over session names and their working directories.
//
// The weights mirror fzf's scoring model, which is well tuned for exactly this
// shape of input — short, path-like strings — and gives the ranking the same
// feel as the fzf pickers used elsewhere in this config.
const (
	scoreMatch        = 16
	bonusBoundary     = scoreMatch / 2    // match starting a new word
	bonusCamel        = bonusBoundary - 1 // lower→upper transition
	bonusConsecutive  = 4                 // adjacent to the previous match
	scoreGapStart     = -3
	scoreGapExtension = -1

	// The first matched character carries double bonus, which is what makes a
	// prefix match ("tm" → "tmux") beat a mid-string one ("tm" → "the-m").
	firstCharMultiplier = 2
)

type match struct {
	score     int
	positions []int
}

// fuzzy matches pattern against s as a case-insensitive subsequence.
//
// The scan is greedy left-to-right rather than exhaustive: for strings this
// short an optimal alignment rarely changes the order, and greedy keeps the
// highlight positions naturally sorted.
func fuzzy(pattern, s string) (match, bool) {
	if pattern == "" {
		return match{}, true
	}

	pat := []rune(strings.ToLower(pattern))
	src := []rune(s)
	low := []rune(strings.ToLower(s))

	m := match{positions: make([]int, 0, len(pat))}
	pi, last := 0, -1

	for i := 0; i < len(low) && pi < len(pat); i++ {
		if low[i] != pat[pi] {
			continue
		}

		m.score += scoreMatch

		bonus := bonusAt(src, i)
		if last < 0 {
			bonus *= firstCharMultiplier
		}
		m.score += bonus

		switch {
		case last < 0: // no gap before the first match
		case i == last+1:
			m.score += bonusConsecutive
		default:
			gap := i - last - 1
			m.score += scoreGapStart + scoreGapExtension*(gap-1)
		}

		m.positions = append(m.positions, i)
		last = i
		pi++
	}

	if pi < len(pat) {
		return match{}, false
	}

	// Mild preference for shorter haystacks, so a short exact name outranks a
	// long path that merely contains the same letters.
	m.score -= len(src) / 8
	return m, true
}

func bonusAt(s []rune, i int) int {
	if i == 0 {
		return bonusBoundary
	}
	prev, cur := s[i-1], s[i]
	if strings.ContainsRune("-_/. :@", prev) {
		return bonusBoundary
	}
	if prev >= 'a' && prev <= 'z' && cur >= 'A' && cur <= 'Z' {
		return bonusCamel
	}
	return 0
}
