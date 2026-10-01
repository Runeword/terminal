// Command claude-sessions lists, previews and erases Claude Code sessions for
// the fzf picker behind __claude_sessions (sources/.config/shell/functions/
// claude.bash). Claude Code's own /resume picker can't be scripted and can't
// delete a session, and `claude project purge` wipes a whole project, its
// auto-memory included.
//
//	claude-sessions list            one row per session of the current
//	                                directory, newest first: the id, a tab,
//	                                then age, git branch and title
//	claude-sessions preview <id>    the session's conversation, for fzf
//	claude-sessions rm [-ask] <id>  erase the session and what only it uses
//
// Transcripts live in $CLAUDE_CONFIG_DIR (else ~/.claude) at
// projects/<project>/<id>.jsonl, <project> being the working directory with
// every character other than an ASCII letter or digit turned into '-'. Their
// record format is internal to Claude Code and changes between releases, so
// list does what the Agent SDK's own list_sessions does (claude-agent-sdk
// 0.2.163, _internal/sessions.py): it reads only the first and last 64 KiB of
// each file and picks a few "key":"value" fields out of them, which keeps
// working when new record types appear. Like the /resume picker, it leaves
// out `claude -p` and Agent SDK runs.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	// liteBuf is how much of each end of a transcript list reads.
	liteBuf = 64 << 10
	// maxDirName is the longest <project> name Claude Code writes as is; a
	// longer one is cut there and gets a hash of the full path appended.
	maxDirName = 200
	// maxPrompt and maxBranch cap a prompt used as a title and the branch
	// column, in runes.
	maxPrompt = 200
	maxBranch = 24

	bold  = "\x1b[1m"
	dim   = "\x1b[2m"
	reset = "\x1b[0m"
)

var (
	uuidRE = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	// Plan slugs and paste hashes become file names, so only these get there.
	slugRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)
	hashRE = regexp.MustCompile(`^[0-9a-f]+$`)
	// Prompts Claude Code writes itself, skipped when looking for the first
	// one the user typed (the SDK's _SKIP_FIRST_PROMPT_PATTERN).
	skipPromptRE = regexp.MustCompile(`^(?:<local-command-stdout>|<session-start-hook>|<tick>|<goal>|\[Request interrupted by user[^\]]*\]|\s*<ide_opened_file>[\s\S]*</ide_opened_file>\s*$|\s*<ide_selection>[\s\S]*</ide_selection>\s*$)`)
	commandRE    = regexp.MustCompile(`<command-name>(.*?)</command-name>`)
	commandArgRE = regexp.MustCompile(`(?s)<command-args>(.*?)</command-args>`)
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	cfg, err := configDir()
	if err == nil {
		err = run(os.Args[1], os.Args[2:], cfg, time.Now())
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "claude-sessions:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: claude-sessions list | preview <id> | rm [-ask] <id>")
	os.Exit(2)
}

func run(cmd string, args []string, cfg string, now time.Time) error {
	var out bytes.Buffer
	switch cmd {
	case "list":
		if len(args) != 0 {
			usage()
		}
		cwd, err := os.Getwd()
		if err != nil {
			return err
		}
		if err = list(&out, cfg, cwd, now); err != nil {
			return err
		}
	case "preview":
		if len(args) != 1 {
			usage()
		}
		if err := preview(&out, cfg, args[0], now); err != nil {
			return err
		}
	case "rm":
		flags := flag.NewFlagSet("rm", flag.ExitOnError)
		ask := flags.Bool("ask", false, "show the session and erase it only on a yes from stdin")
		_ = flags.Parse(args) // ExitOnError: exits itself
		if flags.NArg() != 1 {
			usage()
		}
		return rm(os.Stdout, os.Stdin, cfg, flags.Arg(0), *ask, now)
	default:
		usage()
	}
	_, err := out.WriteTo(os.Stdout)
	return err
}

// configDir is Claude Code's config directory: $CLAUDE_CONFIG_DIR, else ~/.claude.
func configDir() (string, error) {
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return d, nil
	}
	home, err := os.UserHomeDir()
	return filepath.Join(home, ".claude"), err
}

// dirName is the <project> name Claude Code derives from a working directory.
func dirName(cwd string) string {
	var b strings.Builder
	for _, r := range cwd {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' {
			b.WriteRune(r)
		} else {
			b.WriteByte('-')
		}
	}
	return b.String()
}

// projectDir is the directory holding cwd's transcripts, "" when there is
// none. A name past maxDirName ends in a hash that differs between Claude Code
// builds, so it is matched on its cut prefix, as the SDK's _find_project_dir
// does.
func projectDir(cfg, cwd string) string {
	if real, err := filepath.EvalSymlinks(cwd); err == nil {
		cwd = real
	}
	projects := filepath.Join(cfg, "projects")
	name := dirName(cwd)
	if len(name) <= maxDirName {
		if isDir(filepath.Join(projects, name)) {
			return filepath.Join(projects, name)
		}
		return ""
	}
	entries, _ := os.ReadDir(projects)
	for _, e := range entries {
		if e.IsDir() && strings.HasPrefix(e.Name(), name[:maxDirName]+"-") {
			return filepath.Join(projects, e.Name())
		}
	}
	return ""
}

func isDir(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}

// transcripts are session id's transcript files: one, unless the session was
// copied by hand into another project.
func transcripts(cfg, id string) ([]string, error) {
	if !uuidRE.MatchString(id) {
		return nil, fmt.Errorf("not a session id: %q", id)
	}
	paths := inProjects(cfg, "*/"+id+".jsonl")
	if len(paths) == 0 {
		return nil, fmt.Errorf("no session %s in %s", id, filepath.Join(cfg, "projects"))
	}
	return paths, nil
}

// inProjects is the paths under cfg's projects directory that match pattern.
// The pattern is matched inside that directory, so the metacharacters a
// config path may hold (a '[' in it, say) don't count.
func inProjects(cfg, pattern string) []string {
	projects := filepath.Join(cfg, "projects")
	names, _ := fs.Glob(os.DirFS(projects), pattern) // the callers' patterns are valid
	paths := make([]string, len(names))
	for i, name := range names {
		paths[i] = filepath.Join(projects, name)
	}
	return paths
}

// lite is what list reads of a transcript: its stat and both of its ends.
type lite struct {
	mod        time.Time
	size       int64
	head, tail []byte
}

func readLite(path string) (l lite, err error) {
	f, err := os.Open(path)
	if err != nil {
		return lite{}, err
	}
	defer func() { err = errors.Join(err, f.Close()) }()
	st, err := f.Stat()
	if err != nil {
		return lite{}, err
	}
	l = lite{mod: st.ModTime(), size: st.Size()}
	l.head = make([]byte, min(l.size, liteBuf))
	if _, err = f.ReadAt(l.head, 0); err != nil && !errors.Is(err, io.EOF) {
		return lite{}, err
	}
	l.tail = l.head
	if off := l.size - liteBuf; off > 0 {
		l.tail = make([]byte, liteBuf)
		if _, err = f.ReadAt(l.tail, off); err != nil && !errors.Is(err, io.EOF) {
			return lite{}, err
		}
	}
	return l, nil
}

// load is the row of the transcript at path, or false for a file gone since
// it was listed, an empty one, or a session the list leaves out.
func load(path, id string) (session, bool) {
	l, err := readLite(path)
	if err != nil || len(l.head) == 0 {
		return session{}, false
	}
	return parse(id, l)
}

// session is one row of the list.
type session struct {
	id     string
	mod    time.Time
	size   int64
	title  string
	branch string
}

// parse reads a session's row out of its lite read. It reports false for what
// the /resume picker leaves out too: subagent sidechains, `claude -p` and Agent
// SDK runs (entrypoint sdk-*), and metadata-only files with nothing to title
// them by.
func parse(id string, l lite) (session, bool) {
	first, _, _ := bytes.Cut(l.head, []byte("\n"))
	if bytes.Contains(first, []byte(`"isSidechain":true`)) || bytes.Contains(first, []byte(`"isSidechain": true`)) {
		return session{}, false
	}
	if strings.HasPrefix(firstField(l.head, "entrypoint"), "sdk") {
		return session{}, false
	}
	s := session{id: id, mod: l.mod, size: l.size}
	// A name set with /rename wins over the generated title, then comes what
	// the user last typed, then the first prompt: the SDK's summary.
	for _, f := range []struct {
		b   []byte
		key string
	}{
		{l.tail, "customTitle"},
		{l.head, "customTitle"},
		{l.tail, "aiTitle"},
		{l.head, "aiTitle"},
		{l.tail, "lastPrompt"},
		{l.tail, "summary"},
	} {
		if s.title = clean(lastField(f.b, f.key)); s.title != "" {
			break
		}
	}
	if s.title == "" {
		s.title = clean(firstPrompt(l.head))
	}
	if s.title == "" {
		return session{}, false
	}
	if s.branch = clean(lastField(l.tail, "gitBranch")); s.branch == "" {
		s.branch = clean(firstField(l.head, "gitBranch"))
	}
	if s.branch == "" {
		s.branch = "-"
	}
	return s, true
}

// fields calls fn with each "key":"value" string value in b, in order, until
// fn returns false. It scans bytes rather than parsing JSON, as the SDK does,
// so it also works on the lines cut at either end of a lite read. The same key
// quoted inside another string (\"key\":\"…) never matches: its quotes are
// escaped.
func fields(b []byte, key string, fn func(string) bool) {
	pats := [2][]byte{[]byte(`"` + key + `":"`), []byte(`"` + key + `": "`)}
	var at [2]int // next match of each pattern, -1 once there is none left
	for p := range pats {
		at[p] = index(b, 0, pats[p])
	}
	for {
		p := 0
		if at[0] < 0 || at[1] >= 0 && at[1] < at[0] {
			p = 1
		}
		if at[p] < 0 {
			return
		}
		v, end, ok := valueAt(b, at[p]+len(pats[p]))
		if !ok || !fn(v) {
			return
		}
		for q := range pats {
			if at[q] >= 0 && at[q] < end {
				at[q] = index(b, end, pats[q])
			}
		}
	}
}

// index is bytes.Index from offset i, as an index into b (-1 when absent).
func index(b []byte, i int, pat []byte) int {
	if k := bytes.Index(b[i:], pat); k >= 0 {
		return i + k
	}
	return -1
}

// valueAt reads the string value that starts at b[i], just past its opening
// quote, and returns it unescaped with the index past its closing quote.
func valueAt(b []byte, i int) (string, int, bool) {
	for j := i; j < len(b); j++ {
		switch b[j] {
		case '\\':
			j++
		case '"':
			raw := b[i:j]
			if bytes.IndexByte(raw, '\\') < 0 {
				return string(raw), j + 1, true
			}
			var s string
			if json.Unmarshal(b[i-1:j+1], &s) != nil {
				return string(raw), j + 1, true
			}
			return s, j + 1, true
		}
	}
	return "", len(b), false
}

func firstField(b []byte, key string) string {
	var v string
	fields(b, key, func(s string) bool { v = s; return false })
	return v
}

func lastField(b []byte, key string) string {
	var v string
	fields(b, key, func(s string) bool { v = s; return true })
	return v
}

// entry is the part of a transcript record that preview and firstPrompt read.
type entry struct {
	Type             string `json:"type"`
	IsMeta           bool   `json:"isMeta"`
	IsSidechain      bool   `json:"isSidechain"`
	IsCompactSummary bool   `json:"isCompactSummary"`
	Message          struct {
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

// block is one element of a message's content array.
type block struct {
	Type string `json:"type"`
	Text string `json:"text"`
	Name string `json:"name"`
}

// blocks is the message's content; a plain string is one text block.
func (e entry) blocks() []block {
	var s string
	if json.Unmarshal(e.Message.Content, &s) == nil {
		return []block{{Type: "text", Text: s}}
	}
	var bs []block
	_ = json.Unmarshal(e.Message.Content, &bs)
	return bs
}

// firstPrompt is the first prompt the user typed, the SDK's
// _extract_first_prompt_from_head: tool results, records Claude Code writes
// itself and slash commands are passed over, the first command standing in
// when nothing else was typed.
func firstPrompt(head []byte) string {
	command := ""
	for _, line := range bytes.Split(head, []byte("\n")) {
		if !userLine(line) {
			continue
		}
		var e entry
		if json.Unmarshal(line, &e) != nil || e.Type != "user" {
			continue
		}
		for _, b := range e.blocks() {
			if b.Type != "text" {
				continue
			}
			text := strings.TrimSpace(strings.ReplaceAll(b.Text, "\n", " "))
			if m := commandRE.FindStringSubmatch(text); m != nil {
				if command == "" {
					command = m[1]
				}
				continue
			}
			if text != "" && !skipPromptRE.MatchString(text) {
				return cut(text, maxPrompt)
			}
		}
	}
	return command
}

// userLine is the SDK's filter before parsing a line: a user record that is
// neither a tool result nor one Claude Code wrote itself.
func userLine(line []byte) bool {
	has := func(subs ...string) bool {
		for _, s := range subs {
			if bytes.Contains(line, []byte(s)) {
				return true
			}
		}
		return false
	}
	return has(`"type":"user"`, `"type": "user"`) &&
		!has(`"tool_result"`, `"isMeta":true`, `"isMeta": true`, `"isCompactSummary":true`, `"isCompactSummary": true`)
}

// list writes one row per session of cwd's project, newest first.
func list(w *bytes.Buffer, cfg, cwd string, now time.Time) error {
	dir := projectDir(cfg, cwd)
	if dir == "" {
		return nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	var all []session
	for _, e := range entries {
		id, isTranscript := strings.CutSuffix(e.Name(), ".jsonl")
		if !isTranscript || !e.Type().IsRegular() || !uuidRE.MatchString(id) {
			continue
		}
		if s, ok := load(filepath.Join(dir, e.Name()), id); ok {
			all = append(all, s)
		}
	}
	slices.SortFunc(all, func(a, b session) int { return b.mod.Compare(a.mod) })
	width := 0
	for i := range all {
		all[i].branch = cut(all[i].branch, maxBranch)
		width = max(width, utf8.RuneCountInString(all[i].branch))
	}
	for _, s := range all {
		fmt.Fprintf(w, "%s\t%-4s  %s  %s\n", s.id, age(now.Sub(s.mod)), pad(s.branch, width), s.title)
	}
	return nil
}

// preview writes a session's title and conversation for fzf's preview: the
// prompts typed, the replies, and one line per tool call.
func preview(w *bytes.Buffer, cfg, id string, now time.Time) error {
	paths, err := transcripts(cfg, id)
	if err != nil {
		return err
	}
	l, err := readLite(paths[0])
	if err != nil {
		return err
	}
	data, err := os.ReadFile(paths[0])
	if err != nil {
		return err
	}
	title, branch := "(untitled)", "-"
	if s, ok := parse(id, l); ok {
		title, branch = s.title, s.branch
	}
	fmt.Fprintf(w, "%s%s%s\n%s%s · %s · %s · %s%s\n", bold, title, reset,
		dim, id, branch, ago(now.Sub(l.mod)), human(l.size), reset)
	// A run of calls to the same tool is one line: "· Bash ×6".
	tool, calls := "", 0
	flush := func() {
		switch {
		case calls == 1:
			fmt.Fprintf(w, "%s· %s%s\n", dim, tool, reset)
		case calls > 1:
			fmt.Fprintf(w, "%s· %s ×%d%s\n", dim, tool, calls, reset)
		}
		tool, calls = "", 0
	}
	for _, line := range bytes.Split(data, []byte("\n")) {
		var e entry
		if len(line) == 0 || json.Unmarshal(line, &e) != nil || e.IsMeta || e.IsSidechain {
			continue
		}
		switch {
		case e.Type == "user" && e.IsCompactSummary:
			flush()
			fmt.Fprintf(w, "\n%s── compacted ──%s\n", dim, reset)
		case e.Type == "user":
			for _, b := range e.blocks() {
				if text := prompt(b); text != "" {
					flush()
					fmt.Fprintf(w, "\n%s\n", styled(bold, "❯ "+text))
				}
			}
		case e.Type == "assistant":
			for _, b := range e.blocks() {
				switch b.Type {
				case "text":
					if text := strings.TrimSpace(cleanText(b.Text)); text != "" {
						flush()
						fmt.Fprintf(w, "\n%s\n", text)
					}
				case "tool_use":
					if name := clean(b.Name); name != tool {
						flush()
						tool = name
					}
					calls++
				}
			}
		}
	}
	flush()
	return nil
}

// prompt is what the user typed in block b, "" for a tool result or text that
// Claude Code wrote itself; a slash command shows as itself and its arguments.
func prompt(b block) string {
	if b.Type != "text" {
		return ""
	}
	text := strings.TrimSpace(cleanText(b.Text))
	if m := commandRE.FindStringSubmatch(text); m != nil {
		cmd := m[1]
		if a := commandArgRE.FindStringSubmatch(text); a != nil && strings.TrimSpace(a[1]) != "" {
			cmd += " " + strings.TrimSpace(a[1])
		}
		return cmd
	}
	if skipPromptRE.MatchString(text) || strings.HasPrefix(text, "<system-reminder>") {
		return ""
	}
	return text
}

// rm erases session id: its transcript and the directory beside it (subagent
// transcripts, large tool results), its /rewind snapshots, hook environment
// and debug log, its prompts in history.jsonl, and the plans and pastes no
// other session refers to. With ask it first shows the session on out and
// erases it only on a yes from in. A session still open writes its
// transcript back, so it has to be closed first.
func rm(out io.Writer, in io.Reader, cfg, id string, ask bool, now time.Time) error {
	id = strings.ToLower(id)
	paths, err := transcripts(cfg, id)
	if err != nil {
		return err
	}
	if ask && !confirm(out, in, paths[0], id, now) {
		_, _ = fmt.Fprintln(out, "kept")
		return nil
	}
	slugs, err := slugsOf(paths)
	if err != nil {
		return err
	}

	var e eraser
	for _, path := range paths {
		e.remove("transcript", path)
		e.remove("subagents and tool results", strings.TrimSuffix(path, ".jsonl"))
	}
	e.remove("file history", filepath.Join(cfg, "file-history", id))
	e.remove("hook env", filepath.Join(cfg, "session-env", id))
	e.remove("debug log", filepath.Join(cfg, "debug", id+".txt"))
	prompts, pastes, err := dropHistory(filepath.Join(cfg, "history.jsonl"), id)
	if err != nil {
		e.errs = append(e.errs, err)
	}
	if prompts > 0 {
		e.done = append(e.done, count(prompts, "prompt"))
	}
	var files []string
	for _, h := range pastes {
		if hashRE.MatchString(h) {
			files = append(files, filepath.Join(cfg, "paste-cache", h+".txt"))
		}
	}
	e.remove(count(len(files), "paste"), files...)
	files = nil
	for _, slug := range slugs {
		if slugRE.MatchString(slug) && !slugUsed(cfg, slug) {
			files = append(files, filepath.Join(cfg, "plans", slug+".md"))
		}
	}
	e.remove(count(len(files), "plan"), files...)

	if len(e.done) == 0 {
		e.done = []string{"nothing left"}
	}
	_, _ = fmt.Fprintf(out, "erased %s: %s\n", id, strings.Join(e.done, ", "))
	return errors.Join(e.errs...)
}

// eraser deletes what rm erases and keeps the tally it reports.
type eraser struct {
	done []string
	errs []error
}

// remove deletes paths, noting what in the tally when any of them was there.
func (e *eraser) remove(what string, paths ...string) {
	n := 0
	for _, path := range paths {
		if _, err := os.Lstat(path); err != nil {
			continue
		}
		if err := os.RemoveAll(path); err != nil {
			e.errs = append(e.errs, err)
			continue
		}
		n++
	}
	if n > 0 {
		e.done = append(e.done, what)
	}
}

// confirm shows the session on out and reports whether the answer on in is yes.
func confirm(out io.Writer, in io.Reader, path, id string, now time.Time) bool {
	title, when := id, "?"
	if l, err := readLite(path); err == nil {
		if s, ok := parse(id, l); ok {
			title = s.title
		}
		when = ago(now.Sub(l.mod))
	}
	_, _ = fmt.Fprintf(out, "Erase %q (active %s)?\nClose it first if it is still open. [y/N] ", title, when)
	answer, _ := bufio.NewReader(in).ReadString('\n') // no answer is a no
	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "y", "yes":
		return true
	}
	return false
}

// slugsOf is the plan slugs the transcripts at paths name, sorted.
func slugsOf(paths []string) ([]string, error) {
	seen := map[string]bool{}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		fields(data, "slug", func(s string) bool { seen[s] = true; return true })
	}
	slugs := make([]string, 0, len(seen))
	for s := range seen {
		slugs = append(slugs, s)
	}
	slices.Sort(slugs)
	return slugs, nil
}

// slugUsed reports whether a transcript still in place names plan slug, as
// one branched or forked from the erased session does. A transcript that
// can't be read counts as naming it, so the plan stays.
func slugUsed(cfg, slug string) bool {
	needle := []byte(`"slug":"` + slug + `"`)
	for _, path := range inProjects(cfg, "*/*.jsonl") {
		if data, err := os.ReadFile(path); err != nil || bytes.Contains(data, needle) {
			return true
		}
	}
	return false
}

// historyLine is the part of a history.jsonl line rm reads.
type historyLine struct {
	SessionID      string `json:"sessionId"`
	PastedContents map[string]struct {
		ContentHash string `json:"contentHash"`
	} `json:"pastedContents"`
}

// historyFilter sorts history.jsonl lines into the session's own, which it
// counts, and the others, which it keeps byte for byte, noting the pastes
// either side refers to.
type historyFilter struct {
	id           string
	kept         bytes.Buffer
	dropped      int
	mine, others map[string]bool
}

// read filters r to its end.
func (h *historyFilter) read(r *bufio.Reader) error {
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 {
			h.add(line)
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

func (h *historyFilter) add(line []byte) {
	var l historyLine
	pastes := h.others
	if json.Unmarshal(line, &l) == nil && l.SessionID == h.id {
		pastes = h.mine
		h.dropped++
	} else {
		h.kept.Write(line)
	}
	for _, p := range l.PastedContents {
		if p.ContentHash != "" {
			pastes[p.ContentHash] = true
		}
	}
}

// dropHistory removes session id's prompts from the up-arrow history at path,
// keeping every other line byte for byte and the file's mode. Open sessions
// append to it meanwhile, so it reads the old file to its end again after the
// rename and carries over what landed there. It returns how many prompts it
// dropped and the pastes they used that no other prompt does.
func dropHistory(path, id string) (dropped int, pastes []string, err error) {
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, nil, nil
	}
	if err != nil {
		return 0, nil, err
	}
	defer func() { err = errors.Join(err, f.Close()) }()
	st, err := f.Stat()
	if err != nil {
		return 0, nil, err
	}
	h := historyFilter{id: id, mine: map[string]bool{}, others: map[string]bool{}}
	r := bufio.NewReader(f)
	if err = h.read(r); err != nil || h.dropped == 0 {
		return 0, nil, err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".history.jsonl.*")
	if err != nil {
		return 0, nil, err
	}
	defer func() { _ = os.Remove(tmp.Name()) }() // fails once renamed: nothing left
	if err = writeFile(tmp, st.Mode().Perm(), h.kept.Bytes()); err != nil {
		return 0, nil, err
	}
	if err = os.Rename(tmp.Name(), path); err != nil {
		return 0, nil, err
	}
	h.kept.Reset()
	if err = h.read(r); err != nil {
		return 0, nil, err
	}
	if h.kept.Len() > 0 {
		var late *os.File
		if late, err = os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0); err != nil {
			return 0, nil, err
		}
		if err = writeFile(late, st.Mode().Perm(), h.kept.Bytes()); err != nil {
			return 0, nil, err
		}
	}
	for p := range h.mine {
		if !h.others[p] {
			pastes = append(pastes, p)
		}
	}
	slices.Sort(pastes)
	return h.dropped, pastes, nil
}

// writeFile gives f mode perm, writes data and closes it.
func writeFile(f *os.File, perm fs.FileMode, data []byte) error {
	err := f.Chmod(perm)
	if err == nil {
		_, err = f.Write(data)
	}
	return errors.Join(err, f.Close())
}

// age is how long ago a session was last active, in at most four characters.
func age(d time.Duration) string {
	day := 24 * time.Hour
	switch {
	case d < time.Minute:
		return "now"
	case d < time.Hour:
		return fmt.Sprintf("%dm", d/time.Minute)
	case d < day:
		return fmt.Sprintf("%dh", d/time.Hour)
	case d < 100*day:
		return fmt.Sprintf("%dd", d/day)
	}
	return fmt.Sprintf("%dw", d/(7*day))
}

func ago(d time.Duration) string {
	if a := age(d); a != "now" {
		return a + " ago"
	}
	return "just now"
}

func human(n int64) string {
	switch {
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%d KB", n>>10)
	}
	return fmt.Sprintf("%d B", n)
}

func count(n int, what string) string {
	if n == 1 {
		return "1 " + what
	}
	return fmt.Sprintf("%d %ss", n, what)
}

// cut shortens s to n runes, the last one an ellipsis.
func cut(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return strings.TrimRight(string(r[:n-1]), " ") + "…"
}

func pad(s string, width int) string {
	return s + strings.Repeat(" ", max(0, width-utf8.RuneCountInString(s)))
}

// clean makes transcript text safe for one fzf row: every control character
// (newlines, tabs, which separate the row's fields, and the ESC that starts a
// terminal escape sequence) becomes a space, and each run of spaces one.
func clean(s string) string {
	return strings.Join(strings.Fields(strings.Map(func(r rune) rune {
		if control(r) {
			return ' '
		}
		return r
	}, s)), " ")
}

// cleanText is clean for the preview: newlines and tabs stay, the other
// control characters go.
func cleanText(s string) string {
	return strings.Map(func(r rune) rune {
		if r != '\n' && r != '\t' && control(r) {
			return -1
		}
		return r
	}, s)
}

func control(r rune) bool {
	return r < 0x20 || r == 0x7f || r >= 0x80 && r <= 0x9f
}

// styled wraps each line of text in style, which fzf would otherwise drop at
// the first line break.
func styled(style, text string) string {
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		lines[i] = style + l + reset
	}
	return strings.Join(lines, "\n")
}
