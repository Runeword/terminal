package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"unicode"
)

// maxLabel caps a label's length: the status line holds it between the session
// numbers and the window list, and a short name is quicker to read. The prompt asks for 16, and models
// sometimes overshoot by a word ("nixos-kernel-upgrade"), which this keeps.
const maxLabel = 20

// maxPromptPanes bounds the pane lines sent to the model.
const maxPromptPanes = 40

// systemPrompt is the model's system message. Its examples help Qwen3.5 2B,
// which named all 6 sample sessions well with them and 4 without; the 0.8B
// copied them instead (measured 2026-10-25).
const systemPrompt = `You label tmux sessions. Each input line is one pane: window number, program, folder, git branch ("-" for none), and the title the program set, if any.

Answer with a label for the work the session's windows share: 1 to 3 lowercase English words joined by hyphens, at most 16 characters. Name the project or the task; program names such as zsh, nvim or claude are not tasks. Answer with the label only.

Example input:
1 nvim terminal main
2 claude terminal main "Tmux session AI naming"
Example answer: tmux-ai-names

Example input:
1 zsh neovim lsp-fix
2 nvim neovim lsp-fix
Example answer: neovim-lsp-fix`

// pane is one tmux pane, reduced to what describes the work in it.
type pane struct {
	windowID string // window_id, which groups the panes of a window
	window   string // window index, shown to the model only
	program  string // pane_current_command
	folder   string // the directory's base name, "~" for $HOME
	branch   string // the directory's git branch, "" outside a repository
	title    string // the title the program set, "" when it says nothing
}

// shells are the programs a pane runs when nothing else runs in it.
var shells = []string{"zsh", "bash", "sh", "fish", "dash"}

func isShell(program string) bool {
	return slices.Contains(shells, program)
}

// parsePanes reads list-panes output in paneFormat. branchOf gives a
// directory's git branch.
func parsePanes(out, home, host string, branchOf func(dir string) string) []pane {
	var panes []pane
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		// The title comes last, so a tab in it stays in it.
		f := strings.SplitN(line, "\t", 5)
		if len(f) != 5 {
			continue
		}
		panes = append(panes, pane{
			windowID: f[0],
			window:   f[1],
			program:  f[2],
			folder:   folderName(f[3], home),
			branch:   branchOf(f[3]),
			title:    cleanTitle(f[4], f[2], host),
		})
	}
	return panes
}

func folderName(dir, home string) string {
	switch dir {
	case "":
		return "-"
	case home:
		return "~"
	}
	return filepath.Base(dir)
}

// cleanTitle keeps what a pane's title says about its work. Claude Code
// prefixes its topic with ✳, or a ◐/◑ spinner that turns every second while it
// works; a pane that never set a title keeps tmux's default, the host name; and
// a shell's title only repeats its folder or last command.
func cleanTitle(title, program, host string) string {
	if isShell(program) {
		return ""
	}
	title = strings.TrimSpace(strings.TrimLeftFunc(title, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}))
	if title == host || title == "Claude Code" {
		return ""
	}
	title = strings.Map(func(r rune) rune {
		if r == '"' {
			return '\''
		}
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, title)
	if r := []rune(title); len(r) > 60 {
		title = string(r[:60])
	}
	return title
}

// describe is a pane's line for the model, and without the window index, for
// the fingerprint.
func (p pane) describe(withWindow bool) string {
	branch := p.branch
	if branch == "" {
		branch = "-"
	}
	line := p.program + " " + p.folder + " " + branch
	if p.title != "" {
		line += ` "` + p.title + `"`
	}
	if withWindow {
		line = p.window + " " + line
	}
	return line
}

// fingerprint identifies what the panes do: their lines without the window
// index, sorted and deduplicated, so reordering windows or opening a second
// shell beside the first changes nothing.
func fingerprint(panes []pane) string {
	lines := make([]string, 0, len(panes))
	for _, p := range panes {
		lines = append(lines, p.describe(false))
	}
	slices.Sort(lines)
	sum := sha256.Sum256([]byte(strings.Join(slices.Compact(lines), "\n")))
	return hex.EncodeToString(sum[:8])
}

// idleLabel names a session whose panes are all shells in one folder after
// that folder, with no need to ask the model.
func idleLabel(panes []pane) (string, bool) {
	if len(panes) == 0 {
		return "", false
	}
	for _, p := range panes {
		if !isShell(p.program) || p.folder != panes[0].folder {
			return "", false
		}
	}
	if panes[0].folder == "~" {
		return "home", true
	}
	label := sanitize(panes[0].folder)
	return label, label != ""
}

// labelGrammar is the GBNF grammar llama.cpp holds the answer to: 1 to 3 words
// of [a-z0-9] joined by hyphens, so a small model can't wander off the format.
const labelGrammar = `root ::= [a-z0-9]+ ("-" [a-z0-9]+)? ("-" [a-z0-9]+)?`

// prompt is the model's input: one line per pane.
func prompt(panes []pane) string {
	var b strings.Builder
	for i, p := range panes {
		if i == maxPromptPanes {
			break
		}
		b.WriteString(p.describe(true))
		b.WriteByte('\n')
	}
	return b.String()
}

// chatPrompt wraps the system message and the pane lines in Qwen's ChatML
// turns, ending on the empty think block its chat template writes when
// thinking is off. Any program can set a pane title, so "<|" is broken up in
// the lines: no title can close the user turn and open one of its own.
func chatPrompt(system, lines string) string {
	lines = strings.ReplaceAll(strings.TrimSpace(lines), "<|", "< |")
	return "<|im_start|>system\n" + system + "<|im_end|>\n" +
		"<|im_start|>user\n" + lines + "<|im_end|>\n" +
		"<|im_start|>assistant\n<think>\n\n</think>\n\n"
}

// answer is the label part of llama-completion's output, which ends with
// "[end of text]" when the model stops by itself.
func answer(out string) string {
	return strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(out), "[end of text]"))
}

// sanitize turns text into a label: the first line, lowercased, its runs of
// anything but a-z and 0-9 turned into one hyphen, at most 3 words and
// maxLabel characters, cut at a hyphen. Only [a-z0-9-] is left, so no tmux
// style (#[...]) or format (#{...}) can reach the status line.
func sanitize(s string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(s), "\n")
	label := ""
	for i, w := range words(line) {
		if i == 3 {
			break
		}
		next := w
		if label != "" {
			next = label + "-" + w
		}
		if len(next) > maxLabel {
			if label == "" {
				label = w[:maxLabel]
			}
			break
		}
		label = next
	}
	return label
}

// gitBranch returns dir's branch the way claude-statusline does: by reading
// HEAD rather than running git. It is the short commit id when HEAD is
// detached, or "" outside a repository.
func gitBranch(dir string) string {
	gitDir := findGitDir(dir)
	if gitDir == "" {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(gitDir, "HEAD"))
	if err != nil {
		return ""
	}
	head := strings.TrimSpace(string(b))
	if ref, ok := strings.CutPrefix(head, "ref: "); ok {
		branch := strings.TrimPrefix(ref, "refs/heads/")
		// A reftable repository keeps HEAD in its tables and leaves this
		// placeholder in the file.
		if branch == ".invalid" {
			return ""
		}
		return branch
	}
	// Detached: HEAD holds the commit's object id, 40 hex digits (64 in a
	// SHA-256 repository).
	if (len(head) == 40 || len(head) == 64) && strings.Trim(head, "0123456789abcdef") == "" {
		return head[:7]
	}
	return ""
}

// findGitDir walks up from dir to the nearest .git and returns the git
// directory it stands for: .git itself, or in a linked worktree or a
// submodule, the directory the .git file names. "" outside a repository.
func findGitDir(dir string) string {
	if dir == "" {
		return ""
	}
	for {
		dotGit := filepath.Join(dir, ".git")
		if fi, err := os.Stat(dotGit); err == nil {
			if fi.IsDir() {
				return dotGit
			}
			return readGitFile(dotGit)
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// readGitFile returns the directory a .git file names on its "gitdir: <path>"
// line, a relative path being relative to the file's directory, or "" when the
// file isn't one.
func readGitFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	target, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir: ")
	if !ok {
		return ""
	}
	if !filepath.IsAbs(target) {
		target = filepath.Join(filepath.Dir(path), target)
	}
	return target
}
