package main

import (
	"bytes"
	"encoding/json"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// now is the fixed clock the rendering tests run at.
var now = time.Unix(1_790_000_000, 0)

// resetsIn is a resets_at value d after now.
func resetsIn(d time.Duration) string {
	return strconv.FormatInt(now.Add(d).Unix(), 10)
}

// workspace is the payload member for a session whose current directory is dir.
func workspace(t *testing.T, dir string) string {
	t.Helper()
	quoted, err := json.Marshal(dir)
	if err != nil {
		t.Fatal(err)
	}
	return `,"workspace":{"current_dir":` + string(quoted) + `}`
}

// writeTree creates each file under root, with its parent directories.
func writeTree(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for name, content := range files {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestRun(t *testing.T) {
	const (
		opus55   = `"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"}`
		lastTurn = `"current_usage":{"input_tokens":2,"output_tokens":428,"cache_creation_input_tokens":2116,"cache_read_input_tokens":155115}`
		limits   = "5h ━──── 23% 2h13m  7d ━━─── 41% 5d"
		tokens   = "↓2 ↑428 W2.1k R155k =158k"
		location = "proj  main"
	)
	fiveHour := `"five_hour":{"used_percentage":23.5,"resets_at":` + resetsIn(2*time.Hour+13*time.Minute) + `}`
	sevenDay := `"seven_day":{"used_percentage":41.2,"resets_at":` + resetsIn(5*24*time.Hour) + `}`
	session := func(extra string) string {
		return `{` + opus55 + `,"context_window":{"used_percentage":16,` + lastTurn + `},"cost":{"total_cost_usd":3.21}` + extra + `}`
	}
	cacheAndLimits := `,"prompt_cache":{"ttl":"1h"},"rate_limits":{` + fiveHour + `,` + sevenDay + `}`
	midSession := session(cacheAndLimits)
	repo := filepath.Join(t.TempDir(), "proj")
	writeTree(t, repo, map[string]string{".git/HEAD": "ref: refs/heads/main\n"})
	inRepo := session(cacheAndLimits + workspace(t, repo))

	tests := []struct {
		name, payload string
		cols          int
		warn          bool
		want          string
	}{
		{
			"subscriber mid-session", midSession, 0, false,
			"ctx ───── 16%  " + limits + "  $3.21 +0.06  Opus 5.5  " + tokens,
		},
		{
			"80 columns drops the tokens", midSession, 80, false,
			"ctx ───── 16%  " + limits + "  $3.21 +0.06  Opus 5.5",
		},
		{
			"60 columns keeps context and limits", midSession, 60, false,
			"ctx ───── 16%  " + limits,
		},
		{
			"too narrow for anything keeps context", midSession, 10, false,
			"ctx ───── 16%",
		},
		{
			"directory and branch close the line", inRepo, 0, false,
			"ctx ───── 16%  " + limits + "  $3.21 +0.06  Opus 5.5  " + tokens + "  " + location,
		},
		{
			"110 columns drops only the location", inRepo, 110, false,
			"ctx ───── 16%  " + limits + "  $3.21 +0.06  Opus 5.5  " + tokens,
		},
		{
			"outside a repository names only the directory", session(`,"prompt_cache":{"ttl":"1h"}` + workspace(t, "/nonexistent/scratch")), 0, false,
			"ctx ───── 16%  $3.21 +0.06  Opus 5.5  " + tokens + "  scratch",
		},
		{
			"new session", `{` + opus55 + `,"context_window":{"used_percentage":null,"current_usage":null},"cost":{"total_cost_usd":0}}`, 0, false,
			"ctx --  $0.00  Opus 5.5",
		},
		{
			"after /compact", `{` + opus55 + `,"context_window":{"used_percentage":null,"current_usage":null},"cost":{"total_cost_usd":3.87},"rate_limits":{` + fiveHour + `,` + sevenDay + `}}`, 0, false,
			"ctx --  " + limits + "  $3.87  Opus 5.5",
		},
		{
			"api-key session has no limits", session(`,"prompt_cache":{"ttl":"1h"}`), 0, false,
			"ctx ───── 16%  $3.21 +0.06  Opus 5.5  " + tokens,
		},
		{
			"window dropped after its reset", session(`,"prompt_cache":{"ttl":"1h"},"rate_limits":{` + sevenDay + `}`), 0, false,
			"ctx ───── 16%  7d ━━─── 41% 5d  $3.21 +0.06  Opus 5.5  " + tokens,
		},
		{
			"5-minute cache writes", session(`,"prompt_cache":{"ttl":"5m"}`), 0, false,
			"ctx ───── 16%  $3.21 +0.05  Opus 5.5  " + tokens,
		},
		{
			"fast mode doubles the estimate", session(`,"prompt_cache":{"ttl":"1h"},"fast_mode":true`), 0, false,
			"ctx ───── 16%  $3.21 +0.11  Opus 5.5  " + tokens,
		},
		{
			"near the limit, seconds from its reset", `{` + opus55 + `,"context_window":{"used_percentage":16},"rate_limits":{"five_hour":{"used_percentage":99.6,"resets_at":` + resetsIn(30*time.Second) + `}}}`, 0, false,
			"ctx ───── 16%  5h ━━━━─ 99% 1m  Opus 5.5",
		},
		{
			"sub-cent haiku turn", `{"model":{"id":"claude-haiku-4-5","display_name":"Haiku 4.5"},"context_window":{"used_percentage":1,"current_usage":{"input_tokens":1500,"output_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"cost":{"total_cost_usd":0.004}}`, 0, false,
			"ctx ───── 1%  $<0.01 +<0.01  Haiku 4.5  ↓1.5k ↑500 W0 R0 =2.0k",
		},
		{
			"model id without a display name", `{"model":{"id":"claude-sonnet-5"},"context_window":{"used_percentage":16,` + lastTurn + `},"cost":{"total_cost_usd":1}}`, 0, false,
			"ctx ───── 16%  $1.00 +0.04  claude-sonnet-5  " + tokens,
		},
		{
			"empty payload", `{}`, 0, false,
			"ctx --  ?",
		},
		{
			"mistyped field keeps the rest", `{"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":"soon"},` + sevenDay + `},` + opus55 + `,"context_window":{"used_percentage":16,` + lastTurn + `},"prompt_cache":{"ttl":"1h"},"cost":{"total_cost_usd":3.21}}`, 0, true,
			"ctx ───── 16%  5h ━──── 23%  7d ━━─── 41% 5d  $3.21 +0.06  Opus 5.5  " + tokens,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var out, errw bytes.Buffer
			if err := run(strings.NewReader(tt.payload), &out, &errw, now, tt.cols); err != nil {
				t.Fatalf("run: %v", err)
			}
			if got := out.String(); got != tt.want {
				t.Errorf("line\n got %q\nwant %q", got, tt.want)
			}
			if warned := errw.Len() > 0; warned != tt.warn {
				t.Errorf("stderr %q, want a warning: %v", errw.String(), tt.warn)
			}
		})
	}
}

func TestRunRejectsMalformedJSON(t *testing.T) {
	var out bytes.Buffer
	if err := run(strings.NewReader(`{"model":`), &out, io.Discard, now, 0); err == nil {
		t.Errorf("run accepted malformed JSON and printed %q", out.String())
	}
}

func TestRequestCost(t *testing.T) {
	turn := usage{2_000, 1_500, 8_000, 120_000}
	opus55 := modelPrice{rates: opus55Rates, fast: true}
	tests := []struct {
		name string
		p    modelPrice
		ttl  string
		fast bool
		u    usage
		want float64
	}{
		{"zero", defaultPrice, "5m", false, usage{}, 0},
		{"opus 5.5 input only", opus55, "5m", false, usage{InputTokens: 1_000_000}, 4},
		{"opus 5.5 output only", opus55, "5m", false, usage{OutputTokens: 1_000_000}, 20},
		{"opus 5.5 5m cache write", opus55, "5m", false, usage{CacheCreationInputTokens: 1_000_000}, 5},
		{"opus 5.5 1h cache write", opus55, "1h", false, usage{CacheCreationInputTokens: 1_000_000}, 8},
		{"no ttl prices writes at 5m", opus55, "", false, usage{CacheCreationInputTokens: 1_000_000}, 5},
		{"opus 5.5 cache read is counted, not dropped", opus55, "1h", false, usage{CacheReadInputTokens: 1_000_000}, 0.2},
		{"opus 5.5 typical turn", opus55, "1h", false, turn, 0.126},
		{"opus typical turn", modelPrice{rates: opusRates}, "5m", false, turn, 0.1575},
		{"opus typical turn, 1h cache", modelPrice{rates: opusRates}, "1h", false, turn, 0.1875},
		{"opus 4 typical turn", modelPrice{rates: opus4Rates}, "5m", false, turn, 0.4725},
		{"sonnet 5 typical turn", modelPrice{rates: sonnet5Rates}, "5m", false, turn, 0.063},
		{"sonnet typical turn", modelPrice{rates: sonnetRates}, "5m", false, turn, 0.0945},
		{"haiku typical turn", modelPrice{rates: haikuRates}, "5m", false, turn, 0.0315},
		{"haiku 3.5 typical turn", modelPrice{rates: haiku35Rates}, "5m", false, turn, 0.0252},
		{"fable 5.1 typical turn", modelPrice{rates: fable51Rates}, "1h", false, turn, 0.285},
		{"fable typical turn", modelPrice{rates: fableRates}, "1h", false, turn, 0.375},
		{"fast mode doubles opus 5.5", opus55, "1h", true, turn, 0.252},
		{"fast mode is ignored where it doesn't run", modelPrice{rates: sonnet5Rates}, "5m", true, turn, 0.063},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := requestCost(tt.p, tt.ttl, tt.fast, tt.u)
			if math.Abs(got-tt.want) > 1e-9 {
				t.Errorf("requestCost(%+v, %q, %v, %+v) = %v, want %v", tt.p, tt.ttl, tt.fast, tt.u, got, tt.want)
			}
		})
	}
}

// TestCacheRateMultipliers checks every cache column against the pricing
// page's rules, covering the cells the typical-turn costs above don't reach.
func TestCacheRateMultipliers(t *testing.T) {
	tests := []struct {
		name      string
		r         rates
		readRatio float64
	}{
		{"opus 5.5", opus55Rates, 0.05},
		{"opus", opusRates, 0.1},
		{"opus 4", opus4Rates, 0.1},
		{"sonnet 5", sonnet5Rates, 0.1},
		{"sonnet", sonnetRates, 0.1},
		{"haiku", haikuRates, 0.1},
		{"haiku 3.5", haiku35Rates, 0.1},
		{"fable 5.1", fable51Rates, 0.025},
		{"fable", fableRates, 0.1},
	}
	near := func(a, b float64) bool { return math.Abs(a-b) < 1e-9 }
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := tt.r
			if !near(r.cacheWrite5m, 1.25*r.input) || !near(r.cacheWrite1h, 2*r.input) || !near(r.cacheRead, tt.readRatio*r.input) {
				t.Errorf("%+v, want 5m write %v, 1h write %v, read %v",
					r, 1.25*r.input, 2*r.input, tt.readRatio*r.input)
			}
		})
	}
}

func TestPriceFor(t *testing.T) {
	tests := []struct {
		name, id, displayName string
		want                  rates
		fast                  bool
	}{
		{"opus 5.5", "claude-opus-5-5", "Opus 5.5", opus55Rates, true},
		{"opus 5.5 with the 1m suffix", "claude-opus-5-5[1m]", "Opus 5.5 (1M context)", opus55Rates, true},
		{"opus 5.5 bedrock id", "us.anthropic.claude-opus-5-5", "", opus55Rates, true},
		{"id wins over a picker label", "claude-sonnet-5", "Opus-grade gateway", sonnet5Rates, false},
		{"label is the fallback for an unknown id", "gateway-model-7", "Opus 5.5", opus55Rates, true},
		{"opus 5 is not opus 5.5", "claude-opus-5", "Opus 5", opusRates, true},
		{"opus 4.8", "claude-opus-4-8", "Opus 4.8", opusRates, true},
		{"opus 4.7 has no fast mode", "claude-opus-4-7", "Opus 4.7", opusRates, false},
		{"opus 4.5 is not opus 4", "claude-opus-4-5-20251101", "Opus 4.5", opusRates, false},
		{"opus 4.1", "claude-opus-4-1-20250805", "Opus 4.1", opus4Rates, false},
		{"opus 4.1 on bedrock", "us.anthropic.claude-opus-4-1-20250805-v1:0", "", opus4Rates, false},
		{"opus 4, dated", "claude-opus-4-20250514", "", opus4Rates, false},
		{"opus 4 on vertex", "claude-opus-4@20250514", "", opus4Rates, false},
		{"sonnet 5", "claude-sonnet-5", "Sonnet 5", sonnet5Rates, false},
		{"sonnet 4.5 is not sonnet 5", "claude-sonnet-4-5", "Sonnet 4.5", sonnetRates, false},
		{"sonnet 4.6", "claude-sonnet-4-6", "Sonnet 4.6", sonnetRates, false},
		{"haiku 4.5", "claude-haiku-4-5", "Haiku 4.5", haikuRates, false},
		{"haiku 3.5", "claude-3-5-haiku-20241022", "Haiku 3.5", haiku35Rates, false},
		{"fable 5.1", "claude-fable-5-1", "Fable 5.1", fable51Rates, false},
		{"mythos 5.1", "claude-mythos-5-1", "Mythos 5.1", fable51Rates, false},
		{"fable 5", "claude-fable-5", "Fable 5", fableRates, false},
		{"mythos 5", "claude-mythos-5", "Mythos 5", fableRates, false},
		{"no model", "", "", opus55Rates, false},
		{"unknown model", "gateway-model", "Some Unknown Model", opus55Rates, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := priceFor(tt.id, tt.displayName); got.rates != tt.want || got.fast != tt.fast {
				t.Errorf("priceFor(%q, %q) = %+v, want rates %+v, fast %v", tt.id, tt.displayName, got, tt.want, tt.fast)
			}
		})
	}
}

// TestPriceTableOrder catches a key that can never match: any name containing
// it also contains an earlier key, whose row claims it first.
func TestPriceTableOrder(t *testing.T) {
	for i, earlier := range modelPrices {
		for _, later := range modelPrices[i+1:] {
			if strings.Contains(later.key, earlier.key) {
				t.Errorf("%q is shadowed by the earlier %q", later.key, earlier.key)
			}
		}
	}
}

func TestHumanTokens(t *testing.T) {
	tests := []struct {
		n    int
		want string
	}{
		{0, "0"},
		{5, "5"},
		{999, "999"},
		{1000, "1.0k"},
		{2250, "2.3k"},
		{2354, "2.4k"},
		{4114, "4.1k"},
		{9949, "9.9k"},
		{9951, "10k"},
		{12345, "12k"},
		{95191, "95k"},
		{101661, "102k"},
		{999_499, "999k"},
		{999_500, "1.0M"},
		{1_000_000, "1.0M"},
		{2_500_000, "2.5M"},
		{9_951_000, "10M"},
		{15_000_000, "15M"},
	}
	for _, tt := range tests {
		t.Run(strconv.Itoa(tt.n), func(t *testing.T) {
			if got := humanTokens(tt.n); got != tt.want {
				t.Errorf("humanTokens(%d) = %q, want %q", tt.n, got, tt.want)
			}
		})
	}
}

func TestGauge(t *testing.T) {
	tests := []struct {
		pct  float64
		want string
	}{
		{-3, "───── 0%"},
		{0, "───── 0%"},
		{19.9, "───── 19%"},
		{20, "━──── 20%"},
		{23.5, "━──── 23%"},
		{99.6, "━━━━─ 99%"},
		{100, "━━━━━ 100%"},
		{130, "━━━━━ 130%"},
	}
	for _, tt := range tests {
		t.Run(strconv.FormatFloat(tt.pct, 'g', -1, 64), func(t *testing.T) {
			if got := gauge(tt.pct); got != tt.want {
				t.Errorf("gauge(%v) = %q, want %q", tt.pct, got, tt.want)
			}
		})
	}
}

func TestCountdown(t *testing.T) {
	tests := []struct {
		d    time.Duration
		want string
	}{
		{-time.Second, "0m"},
		{0, "0m"},
		{time.Second, "1m"},
		{30 * time.Second, "1m"},
		{time.Minute, "1m"},
		{time.Minute + time.Second, "2m"},
		{59*time.Minute + 30*time.Second, "1h"},
		{time.Hour, "1h"},
		{2*time.Hour + 13*time.Minute, "2h13m"},
		{24 * time.Hour, "1d"},
		{5 * 24 * time.Hour, "5d"},
		{6*24*time.Hour + 23*time.Hour + 59*time.Minute, "6d23h"},
	}
	for _, tt := range tests {
		t.Run(tt.d.String(), func(t *testing.T) {
			if got := countdown(tt.d); got != tt.want {
				t.Errorf("countdown(%v) = %q, want %q", tt.d, got, tt.want)
			}
		})
	}
}

func TestGitBranch(t *testing.T) {
	const (
		onMain = "ref: refs/heads/main\n"
		sha1   = "0123456789abcdef0123456789abcdef01234567"
	)
	sha256 := strings.Repeat("89abcdef", 8)
	tests := []struct {
		name  string
		files map[string]string // written under a fresh root; ROOT in a file is that root
		dir   string            // relative to the root unless absolute
		want  string
	}{
		{"branch", map[string]string{"repo/.git/HEAD": onMain}, "repo", "main"},
		{"branch with a slash", map[string]string{"repo/.git/HEAD": "ref: refs/heads/feature/statusline\n"}, "repo", "feature/statusline"},
		{"from a subdirectory", map[string]string{"repo/.git/HEAD": onMain, "repo/cmd/app/main.go": ""}, "repo/cmd/app", "main"},
		{"nearest repository wins", map[string]string{"repo/.git/HEAD": onMain, "repo/vendor/lib/.git/HEAD": "ref: refs/heads/dev\n"}, "repo/vendor/lib", "dev"},
		{"detached", map[string]string{"repo/.git/HEAD": sha1 + "\n"}, "repo", "0123456"},
		{"detached, sha-256", map[string]string{"repo/.git/HEAD": sha256 + "\n"}, "repo", "89abcde"},
		{"linked worktree", map[string]string{"repo/.git/HEAD": onMain, "repo/.git/worktrees/wt/HEAD": "ref: refs/heads/topic\n", "wt/.git": "gitdir: ROOT/repo/.git/worktrees/wt\n"}, "wt", "topic"},
		{"submodule, relative gitdir", map[string]string{"repo/.git/HEAD": onMain, "repo/.git/modules/sub/HEAD": sha1 + "\n", "repo/sub/.git": "gitdir: ../.git/modules/sub\n"}, "repo/sub", "0123456"},
		{"reftable placeholder", map[string]string{"repo/.git/HEAD": "ref: refs/heads/.invalid\n"}, "repo", ""},
		{"malformed .git file", map[string]string{"repo/.git": "not a gitfile\n"}, "repo", ""},
		{"malformed HEAD", map[string]string{"repo/.git/HEAD": "garbage\n"}, "repo", ""},
		{"not a repository", nil, "/nonexistent/scratch", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root := t.TempDir()
			files := make(map[string]string, len(tt.files))
			for name, content := range tt.files {
				files[name] = strings.ReplaceAll(content, "ROOT", root)
			}
			writeTree(t, root, files)
			dir := tt.dir
			if !filepath.IsAbs(dir) {
				dir = filepath.Join(root, dir)
			}
			if got := gitBranch(dir); got != tt.want {
				t.Errorf("gitBranch(%q) = %q, want %q", tt.dir, got, tt.want)
			}
		})
	}
}
