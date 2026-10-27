package main

import (
	"slices"
	"strings"
)

// maxWord caps a window's name: the window list holds one per window around
// the middle of the status line. The prompt asks for 12 characters.
const maxWord = 12

// windowSystemPrompt is the model's system message for a window's name. Its
// examples steer Qwen3.5 2B to the most specific noun of a title: without
// them it answered ai, fix or debug. With them, 19 of 20 sample windows got a
// fitting word, and the 20th got its shell's name, which saysNothing catches
// (measured 2026-10-27).
const windowSystemPrompt = `You name tmux windows. Each input line is one pane of the window: program, folder, git branch ("-" for none), and the title the program set, if any.

Answer with one lowercase English word, at most 12 characters, for what the window works on: the most specific thing the title or the branch is about, or else the project the folder names. Answer with a noun: not a verb such as fix, add or upgrade, and not a program such as zsh, nvim or claude. Answer with the word only.

Example input:
claude terminal main "Tmux session AI naming"
Example answer: naming

Example input:
nvim neovim lsp-fix
Example answer: lsp

Example input:
claude shop main "Upgrade Stripe webhook handler"
Example answer: stripe`

// wordGrammar is the GBNF grammar that holds the model's answer to one word.
const wordGrammar = `root ::= [a-z0-9]+`

// defaultBranches name no task: a window on one says no more than its folder.
var defaultBranches = []string{"main", "master"}

// words splits s into its runs of a-z and 0-9, lowercased.
func words(s string) []string {
	return strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return (r < 'a' || r > 'z') && (r < '0' || r > '9')
	})
}

// word turns the model's answer into a window's name: the first word of its
// first line, at most maxWord characters. Only [a-z0-9] is left, so no tmux
// style or format can reach the status line.
func word(s string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(s), "\n")
	w := words(line)
	if len(w) == 0 {
		return ""
	}
	return w[0][:min(len(w[0]), maxWord)]
}

// plain reports whether the panes say nothing but their programs and folders:
// none has a title or a branch other than main or master. A small model only
// guesses at such a window, often with a program's name.
func plain(panes []pane) bool {
	for _, p := range panes {
		if p.title != "" || (p.branch != "" && !slices.Contains(defaultBranches, p.branch)) {
			return false
		}
	}
	return true
}

// folderWord names the panes after the folder they share when its name is one
// word, "home" for ~, and with "" when it has none, such as /: the window list
// then shows the program. ok is false when the panes are in different folders,
// or the name has more words, for the model to pick from.
func folderWord(panes []pane) (name string, ok bool) {
	if len(panes) == 0 {
		return "", false
	}
	for _, p := range panes {
		if p.folder != panes[0].folder {
			return "", false
		}
	}
	if panes[0].folder == "~" {
		return "home", true
	}
	switch w := words(panes[0].folder); len(w) {
	case 0:
		return "", true
	case 1:
		return w[0][:min(len(w[0]), maxWord)], true
	}
	return "", false
}

// saysNothing reports whether the model's word names only a shell, a program
// running in the window or a default branch, and no title mentions it: the
// window list shows the program anyway, and a default branch names no task.
func saysNothing(w string, panes []pane) bool {
	nothing := isShell(w) || slices.Contains(defaultBranches, w)
	for _, p := range panes {
		if slices.Contains(words(p.title), w) {
			return false
		}
		nothing = nothing || w == word(p.program)
	}
	return nothing
}

// windowLines is the model's input for a window: one line per pane, without
// the window number, each line once.
func windowLines(panes []pane) string {
	var lines []string
	for _, p := range panes {
		if len(lines) == maxPromptPanes {
			break
		}
		if line := p.describe(false); !slices.Contains(lines, line) {
			lines = append(lines, line)
		}
	}
	return strings.Join(lines, "\n") + "\n"
}
