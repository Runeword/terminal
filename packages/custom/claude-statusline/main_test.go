package main

import (
	"encoding/json"
	"math"
	"reflect"
	"testing"
)

func TestRequestCost(t *testing.T) {
	tests := []struct {
		name                                 string
		r                                    rates
		ttl                                  string
		input, output, cacheWrite, cacheRead int
		want                                 float64
	}{
		{"zero", opusRates, "5m", 0, 0, 0, 0, 0},
		{"opus 5.5 input only", opus55Rates, "5m", 1_000_000, 0, 0, 0, 4.0},
		{"opus 5.5 output only", opus55Rates, "5m", 0, 1_000_000, 0, 0, 20.0},
		{"opus 5.5 5m cache write", opus55Rates, "5m", 0, 0, 1_000_000, 0, 5.0},
		{"opus 5.5 1h cache write", opus55Rates, "1h", 0, 0, 1_000_000, 0, 8.0},
		{"no ttl prices writes at 5m", opus55Rates, "", 0, 0, 1_000_000, 0, 5.0},
		{"opus 5.5 cache read is counted, not dropped", opus55Rates, "1h", 0, 0, 0, 1_000_000, 0.2},
		{"opus 5.5 typical turn", opus55Rates, "1h", 2_000, 1_500, 8_000, 120_000, 0.126},
		{"opus typical turn", opusRates, "5m", 2_000, 1_500, 8_000, 120_000, 0.1575},
		{"opus typical turn, 1h cache", opusRates, "1h", 2_000, 1_500, 8_000, 120_000, 0.1875},
		{"sonnet 5 typical turn", sonnet5Rates, "5m", 2_000, 1_500, 8_000, 120_000, 0.063},
		{"sonnet typical turn", sonnetRates, "5m", 2_000, 1_500, 8_000, 120_000, 0.0945},
		{"haiku typical turn", haikuRates, "5m", 2_000, 1_500, 8_000, 120_000, 0.0315},
		{"fable 5.1 typical turn", fable51Rates, "1h", 2_000, 1_500, 8_000, 120_000, 0.285},
		{"fable typical turn", fableRates, "1h", 2_000, 1_500, 8_000, 120_000, 0.375},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := requestCost(tt.r, tt.ttl, tt.input, tt.output, tt.cacheWrite, tt.cacheRead)
			if math.Abs(got-tt.want) > 1e-9 {
				t.Errorf("requestCost(%+v, %q, %d, %d, %d, %d) = %v, want %v",
					tt.r, tt.ttl, tt.input, tt.output, tt.cacheWrite, tt.cacheRead, got, tt.want)
			}
		})
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
		{2354, "2.4k"},
		{4114, "4.1k"},
		{12345, "12k"},
		{95191, "95k"},
		{101661, "102k"},
		{999_499, "999k"},
		{999_500, "1.0M"},
		{1_000_000, "1.0M"},
		{2_500_000, "2.5M"},
		{15_000_000, "15M"},
	}
	for _, tt := range tests {
		t.Run(tt.want, func(t *testing.T) {
			if got := humanTokens(tt.n); got != tt.want {
				t.Errorf("humanTokens(%d) = %q, want %q", tt.n, got, tt.want)
			}
		})
	}
}

func TestRatesFor(t *testing.T) {
	tests := []struct {
		name, id, displayName string
		want                  rates
	}{
		{"opus 5.5", "claude-opus-5-5", "Opus 5.5", opus55Rates},
		{"opus 5.5 with 1m suffix", "claude-opus-5-5[1m]", "Opus 5.5 (1M context)", opus55Rates},
		{"opus 5.5 behind an alias id", "opus", "Opus 5.5", opus55Rates},
		{"opus 5.5 behind a picker label", "claude-opus-5-5", "Team model", opus55Rates},
		{"opus 5.5 bedrock id", "us.anthropic.claude-opus-5-5", "", opus55Rates},
		{"opus 5 is not opus 5.5", "claude-opus-5", "Opus 5", opusRates},
		{"opus 4.8", "claude-opus-4-8", "Opus 4.8", opusRates},
		{"sonnet 5", "claude-sonnet-5", "Sonnet 5", sonnet5Rates},
		{"sonnet 4.5 is not sonnet 5", "claude-sonnet-4-5", "Sonnet 4.5", sonnetRates},
		{"sonnet 4.6", "claude-sonnet-4-6", "Sonnet 4.6", sonnetRates},
		{"haiku 4.5", "claude-haiku-4-5", "Haiku 4.5", haikuRates},
		{"fable 5.1", "claude-fable-5-1", "Fable 5.1", fable51Rates},
		{"mythos 5.1", "claude-mythos-5-1", "Mythos 5.1", fable51Rates},
		{"fable 5", "claude-fable-5", "Fable 5", fableRates},
		{"mythos 5", "claude-mythos-5", "Mythos 5", fableRates},
		{"empty", "", "", opusRates},
		{"unknown", "gateway-model", "Some Unknown Model", opusRates},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ratesFor(tt.id, tt.displayName); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("ratesFor(%q, %q) = %+v, want %+v", tt.id, tt.displayName, got, tt.want)
			}
		})
	}
}

// TestStatusInputDecodes guards the JSON tags of the fields pricing depends on,
// using the field names from Claude Code's statusline schema.
func TestStatusInputDecodes(t *testing.T) {
	payload := `{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"prompt_cache":{"ttl":"1h"}}`
	var in StatusInput
	if err := json.Unmarshal([]byte(payload), &in); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if in.Model.ID != "claude-opus-5-5" || in.Model.DisplayName != "Opus 5.5" || in.PromptCache.TTL != "1h" {
		t.Errorf("decoded model %+v, prompt_cache %+v", in.Model, in.PromptCache)
	}
}
