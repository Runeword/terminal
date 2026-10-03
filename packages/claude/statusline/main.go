// Command claude-statusline renders Claude Code's status line: context use, the
// subscription rate limits, session and last-request cost, the model, the last
// request's tokens, and the current directory with its git branch. Claude Code
// runs it every refreshInterval with the session as JSON on stdin
// (code.claude.com/docs/en/statusline) and shows what it prints.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// statusInput is the part of Claude Code's status line payload this reads.
// Pointers mark what Claude Code omits or sends as null until it has data, so
// "unknown" renders differently from zero.
type statusInput struct {
	Model struct {
		ID          string `json:"id"`
		DisplayName string `json:"display_name"`
	} `json:"model"`
	Workspace struct {
		CurrentDir string `json:"current_dir"`
	} `json:"workspace"`
	ContextWindow struct {
		UsedPercentage *float64 `json:"used_percentage"`
		CurrentUsage   *usage   `json:"current_usage"`
	} `json:"context_window"`
	PromptCache struct {
		TTL string `json:"ttl"`
	} `json:"prompt_cache"`
	FastMode   bool `json:"fast_mode"`
	RateLimits struct {
		FiveHour *rateWindow `json:"five_hour"`
		SevenDay *rateWindow `json:"seven_day"`
	} `json:"rate_limits"`
	Cost struct {
		TotalCostUSD *float64 `json:"total_cost_usd"`
	} `json:"cost"`
}

// usage is the token breakdown of the last main-conversation API response.
type usage struct {
	InputTokens              int `json:"input_tokens"`
	OutputTokens             int `json:"output_tokens"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens"`
}

// rateWindow is one subscription rate-limit window. resets_at is epoch seconds,
// decoded as a float so a fractional value can't fail the payload.
type rateWindow struct {
	UsedPercentage float64  `json:"used_percentage"`
	ResetsAt       *float64 `json:"resets_at"`
}

// rates holds per-MTok USD list prices for a model: uncached input, output,
// cache creation at the 5-minute and 1-hour TTLs (input×1.25 and ×2), and cache
// read (input×0.1, but ×0.05 on Opus 5.5 and ×0.025 on Fable/Mythos 5.1).
type rates struct {
	input, output, cacheWrite5m, cacheWrite1h, cacheRead float64
}

// List prices from platform.claude.com/docs/en/about-claude/pricing.
var (
	opus55Rates  = rates{4, 20, 5, 8, 0.2}
	opusRates    = rates{5, 25, 6.25, 10, 0.5}
	opus4Rates   = rates{15, 75, 18.75, 30, 1.5}
	sonnet5Rates = rates{2, 10, 2.5, 4, 0.2}
	sonnetRates  = rates{3, 15, 3.75, 6, 0.3}
	haikuRates   = rates{1, 5, 1.25, 2, 0.1}
	haiku35Rates = rates{0.8, 4, 1, 1.6, 0.08}
	fable51Rates = rates{10, 50, 12.5, 20, 0.25}
	fableRates   = rates{10, 50, 12.5, 20, 1}
)

// modelPrice is one row of the price table.
type modelPrice struct {
	key   string // found as a substring of the normalised model name
	rates rates
	fast  bool // fast mode runs on this model, billed at 2× every rate
}

// modelPrices is scanned in order and the first key found wins, so a version's
// key precedes its family's ("opus-5-5" before "opus-5" before "opus").
var modelPrices = []modelPrice{
	{"opus-5-5", opus55Rates, true},
	{"opus-5", opusRates, true},
	{"opus-4-8", opusRates, true},
	// Opus 4 and 4.1 are retired first-party (Claude Code remaps them to the
	// current Opus there) but still served on Bedrock and Vertex.
	{"opus-4-1", opus4Rates, false},
	{"opus-4-0", opus4Rates, false},
	{"opus-4-2025", opus4Rates, false},
	{"opus-4@", opus4Rates, false},
	{"opus", opusRates, false},
	{"sonnet-5", sonnet5Rates, false},
	{"sonnet", sonnetRates, false},
	{"3-5-haiku", haiku35Rates, false},
	{"haiku", haikuRates, false},
	{"fable-5-1", fable51Rates, false},
	{"mythos-5-1", fable51Rates, false},
	{"fable", fableRates, false},
	{"mythos", fableRates, false},
}

// defaultPrice is used when no key matches: Claude Code prices an unknown model
// at its default model's rates, which on first party is Opus 5.5.
var defaultPrice = modelPrice{rates: opus55Rates}

// modelKeyReplacer hyphenates spaces and dots so an id and a display name spell
// a version alike: "claude-opus-5-5[1m]" and "Opus 5.5 (1M context)" both
// contain "opus-5-5".
var modelKeyReplacer = strings.NewReplacer(" ", "-", ".", "-")

// priceFor finds the price row for the session's model. The id decides: Claude
// Code always sends a resolved one ("claude-opus-5-5",
// "us.anthropic.claude-opus-4-1-20250805-v1:0"), while the display name can be
// a custom picker label, so the name is only consulted when the id matches
// nothing.
func priceFor(id, displayName string) modelPrice {
	for _, name := range [...]string{id, displayName} {
		key := modelKeyReplacer.Replace(strings.ToLower(name))
		for _, p := range modelPrices {
			if strings.Contains(key, p.key) {
				return p
			}
		}
	}
	return defaultPrice
}

// requestCost estimates what the last request cost from its tokens. Cache
// writes use the 1-hour rate when the prompt cache's TTL is "1h" and the
// 5-minute rate otherwise; fast mode doubles every rate on the models it runs
// on.
//
// It prices at the session's model: the payload has no per-response model, so
// after a refusal fallback or a /model switch the figure is off until the next
// request. fast_mode is the session toggle too, so the estimate is doubled even
// for requests that ran at standard speed during a fast-mode cooldown.
func requestCost(p modelPrice, ttl string, fast bool, u usage) float64 {
	r := p.rates
	writeRate := r.cacheWrite5m
	if ttl == "1h" {
		writeRate = r.cacheWrite1h
	}
	cost := (float64(u.InputTokens)*r.input +
		float64(u.OutputTokens)*r.output +
		float64(u.CacheCreationInputTokens)*writeRate +
		float64(u.CacheReadInputTokens)*r.cacheRead) / 1_000_000
	if fast && p.fast {
		cost *= 2
	}
	return cost
}

// humanTokens renders a token count compactly so the line stays legible: bare
// below 1000, then "k" (thousands) or "M" (millions), rounded half up, with one
// decimal while the rounded value is under 10 and none above. So 2354→"2.4k",
// 9951→"10k", 95191→"95k", 101661→"102k". The k/M cutover sits just under 1e6
// so a count that would round to "1000k" shows as "1.0M" instead.
func humanTokens(n int) string {
	switch {
	case n < 1000:
		return strconv.Itoa(n)
	case n < 999_500:
		return scaled(n, 1000, "k")
	default:
		return scaled(n, 1_000_000, "M")
	}
}

// scaled renders n in units of unit, choosing the decimals after rounding so
// 9_951 gives "10k" rather than "10.0k".
func scaled(n, unit int, suffix string) string {
	if tenths := (n*10 + unit/2) / unit; tenths < 100 {
		return strconv.Itoa(tenths/10) + "." + strconv.Itoa(tenths%10) + suffix
	}
	return strconv.Itoa((n+unit/2)/unit) + suffix
}

// gaugeCells is the width of a gauge's bar.
const gaugeCells = 5

// gauge renders a percentage as a bar and a number taken from the same floored
// value, so the two agree: each cell is a full 20%, and a full bar or "100%"
// means the limit is reached, not 99.6% of it.
func gauge(pct float64) string {
	p := max(int(math.Floor(pct)), 0)
	filled := min(p*gaugeCells/100, gaugeCells)
	return strings.Repeat("━", filled) + strings.Repeat("─", gaugeCells-filled) + " " + strconv.Itoa(p) + "%"
}

// countdown renders the time left until a reset, rounded up to the minute so
// the last seconds before it don't read as an already-reset "0m", and without
// zero parts: "2h13m", "6d23h", "5d", "1h", "1m".
func countdown(d time.Duration) string {
	if d <= 0 {
		return "0m"
	}
	m := int((d + time.Minute - 1) / time.Minute)
	days, hours, mins := m/(24*60), m/60%24, m%60
	switch {
	case days > 0:
		return withPart(days, "d", hours, "h")
	case hours > 0:
		return withPart(hours, "h", mins, "m")
	default:
		return strconv.Itoa(mins) + "m"
	}
}

// withPart renders a+unitA, followed by b+unitB when b is non-zero.
func withPart(a int, unitA string, b int, unitB string) string {
	s := strconv.Itoa(a) + unitA
	if b > 0 {
		s += strconv.Itoa(b) + unitB
	}
	return s
}

// locationSection renders the name of the session's current directory and the
// git branch checked out there, "terminal main", or nothing when Claude Code
// sent no directory.
func locationSection(dir string) string {
	if dir == "" {
		return ""
	}
	s := filepath.Base(dir)
	if branch := gitBranch(dir); branch != "" {
		s += " " + branch
	}
	return s
}

// gitBranch returns the branch checked out in the git repository holding dir,
// the short commit id when HEAD is detached, or "" outside a repository. It
// reads HEAD instead of running git: the line is redrawn every
// refreshInterval, and inside claude `git` is the allowlisting git-shim.
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
		// placeholder in the file, a name no branch can have (a ref component
		// can't start with a dot).
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

// findGitDir walks up from dir to the nearest .git, as git's own discovery
// does, and returns the git directory it stands for: .git itself, or in a
// linked worktree or a submodule, the directory the .git file names. "" outside
// a repository.
func findGitDir(dir string) string {
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

// contextSection renders context-window use, or "ctx --" while Claude Code has
// no figure (before the first response and right after /compact).
func contextSection(pct *float64) string {
	if pct == nil {
		return "ctx --"
	}
	return "ctx " + gauge(*pct)
}

// limitSection renders one rate-limit window as "5h ━──── 23% 2h13m", or
// nothing when Claude Code didn't send it: API-key sessions never get one, and
// subscription windows arrive with the first response and are dropped once
// they reset.
func limitSection(name string, w *rateWindow, now time.Time) string {
	if w == nil {
		return ""
	}
	s := name + " " + gauge(w.UsedPercentage)
	// A resets_at of the wrong type decodes as a non-nil zero: no countdown.
	if w.ResetsAt != nil && *w.ResetsAt > 0 {
		s += " " + countdown(time.Unix(int64(*w.ResetsAt), 0).Sub(now))
	}
	return s
}

// costSection renders the session total Claude Code reports, then the
// estimated cost of the last request: "$3.21 +0.06".
func costSection(in statusInput) string {
	var parts []string
	if total := in.Cost.TotalCostUSD; total != nil {
		parts = append(parts, "$"+dollars(*total))
	}
	if u := in.ContextWindow.CurrentUsage; u != nil {
		p := priceFor(in.Model.ID, in.Model.DisplayName)
		parts = append(parts, "+"+dollars(requestCost(p, in.PromptCache.TTL, in.FastMode, *u)))
	}
	return strings.Join(parts, " ")
}

// dollars renders an amount to the cent, or "<0.01" for a non-zero amount that
// would otherwise print as 0.00.
func dollars(v float64) string {
	if v > 0 && v < 0.01 {
		return "<0.01"
	}
	return strconv.FormatFloat(v, 'f', 2, 64)
}

// modelName is the display name, falling back to the id, then "?".
func modelName(in statusInput) string {
	switch {
	case in.Model.DisplayName != "":
		return in.Model.DisplayName
	case in.Model.ID != "":
		return in.Model.ID
	default:
		return "?"
	}
}

// tokenSection renders the last request's tokens: ↓uncached input, ↑output,
// W cache writes, R cache reads, = their total. Empty before the first
// response and right after /compact.
func tokenSection(u *usage) string {
	if u == nil {
		return ""
	}
	total := u.InputTokens + u.OutputTokens + u.CacheCreationInputTokens + u.CacheReadInputTokens
	return fmt.Sprintf("↓%s ↑%s W%s R%s =%s",
		humanTokens(u.InputTokens), humanTokens(u.OutputTokens),
		humanTokens(u.CacheCreationInputTokens), humanTokens(u.CacheReadInputTokens),
		humanTokens(total))
}

const (
	// sectionGap separates the sections of the line.
	sectionGap = "  "
	// footerPadding is what Claude Code's footer takes from $COLUMNS (the full
	// terminal width) around the status line: two columns on each side.
	footerPadding = 4
)

// render builds the status line. Sections run in priority order (context, the
// 5-hour and 7-day limits, cost, model, the last request's tokens, then
// directory and branch), and whole sections are dropped from the end to fit
// cols, the terminal width Claude Code passes in $COLUMNS; 0 means unknown, so
// nothing is dropped.
func render(in statusInput, now time.Time, cols int) string {
	sections := []string{contextSection(in.ContextWindow.UsedPercentage)}
	for _, s := range []string{
		limitSection("5h", in.RateLimits.FiveHour, now),
		limitSection("7d", in.RateLimits.SevenDay, now),
		costSection(in),
		modelName(in),
		tokenSection(in.ContextWindow.CurrentUsage),
		locationSection(in.Workspace.CurrentDir),
	} {
		if s != "" {
			sections = append(sections, s)
		}
	}
	width := 0
	if cols > 0 {
		width = max(cols-footerPadding, 1)
	}
	return fit(sections, width)
}

// fit joins the longest prefix of sections that fits in width columns, always
// keeping the first; width 0 means no limit. It counts runes, which is the
// width of everything this prints except a display name, directory or branch
// with wide characters.
func fit(sections []string, width int) string {
	var b strings.Builder
	used := 0
	for i, s := range sections {
		n := utf8.RuneCountInString(s)
		if i > 0 {
			n += len(sectionGap)
			if width > 0 && used+n > width {
				break
			}
			b.WriteString(sectionGap)
		}
		b.WriteString(s)
		used += n
	}
	return b.String()
}

// run decodes one payload from r and writes its status line to w. A field of
// the wrong type is reported on errw and left zero rather than failing the
// payload: encoding/json keeps filling the other fields, and a partial line
// beats the blank one Claude Code shows when the command exits non-zero.
func run(r io.Reader, w, errw io.Writer, now time.Time, cols int) error {
	var in statusInput
	if err := json.NewDecoder(r).Decode(&in); err != nil {
		var typeErr *json.UnmarshalTypeError
		if !errors.As(err, &typeErr) {
			return err
		}
		_, _ = fmt.Fprintln(errw, "claude-statusline: ignoring", err)
	}
	_, err := io.WriteString(w, render(in, now, cols))
	return err
}

func main() {
	// An unset or malformed COLUMNS reads as 0: no width limit.
	cols, _ := strconv.Atoi(os.Getenv("COLUMNS"))
	if err := run(os.Stdin, os.Stdout, os.Stderr, time.Now(), cols); err != nil {
		fmt.Fprintln(os.Stderr, "claude-statusline:", err)
		os.Exit(1)
	}
}
