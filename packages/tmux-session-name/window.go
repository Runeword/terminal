package main

import (
	"slices"
	"strings"
)

// windowSystemPrompt is the model's system message for a window's name. Its
// examples steer Qwen3.5 2B to the most specific nouns of a title or a branch.
// The program to leave out is the one each line starts with: told "not
// programs such as zsh, nvim or claude", it left zsh out of a branch about it
// (feat/zsh-prompt gave dotfiles-git). It still puts the program in some
// answers (login-node), which meaningful takes out. All 29 sample windows it
// was tuned on got a fitting name; of 20 others, 18 did, and 2 got their
// folder's (measured 2026-11-18).
const windowSystemPrompt = `You name tmux windows. Each input line is one pane of the window: program, folder, git branch ("-" for none), and the title the program set, if any.

Answer with a name for what the window works on: 1 to 3 lowercase English words joined by hyphens, at most 16 characters. Name the most specific thing the title or the branch is about, or else the project the folder names. Use nouns, not verbs such as fix, add or upgrade. Leave out the program each line starts with: it names no work. Answer with the name only.

Example input:
claude terminal main "Tmux session AI naming"
Example answer: ai-naming

Example input:
nvim neovim lsp-fix
Example answer: neovim-lsp

Example input:
zsh shop feat/checkout-form
Example answer: checkout-form

Example input:
claude shop main "Upgrade Stripe webhook handler"
Example answer: stripe-webhook`

// defaultBranches name no task: a window on one says no more than its folder.
var defaultBranches = []string{"main", "master"}

// words splits s into its runs of a-z and 0-9, lowercased.
func words(s string) []string {
	return strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return (r < 'a' || r > 'z') && (r < '0' || r > '9')
	})
}

// meaningful turns the model's answer into a window's name, as sanitize does,
// without the words that say nothing.
func meaningful(answer string, panes []pane) string {
	line, _, _ := strings.Cut(strings.TrimSpace(answer), "\n")
	kept := slices.DeleteFunc(words(line), func(w string) bool { return saysNothing(w, panes) })
	return sanitize(strings.Join(kept, "-"))
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

// folderLabel names the panes after the folder they share when the whole of
// its name makes a window's name (one word cut to maxLabel, or up to 3 that
// fit), "home" for ~, and with "" when it has none, such as /: the window list
// then shows the program. ok is false when the panes are in different
// folders, or the name has more words, for the model to pick from.
func folderLabel(panes []pane) (name string, ok bool) {
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
	w := words(panes[0].folder)
	name = sanitize(panes[0].folder)
	if len(w) > 1 && name != strings.Join(w, "-") {
		return "", false
	}
	return name, true
}

// saysNothing reports whether a word of the model's answer names only a
// shell, a program running in the window or a default branch, and no title or
// other branch mentions it: the window list shows the program anyway, and a
// default branch names no task.
func saysNothing(w string, panes []pane) bool {
	nothing := isShell(w) || slices.Contains(defaultBranches, w)
	for _, p := range panes {
		if slices.Contains(words(p.title), w) {
			return false
		}
		if !slices.Contains(defaultBranches, p.branch) && slices.Contains(words(p.branch), w) {
			return false
		}
		// All its words: claude runs as .claude-wrapped on macOS.
		nothing = nothing || slices.Contains(words(p.program), w)
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
