package main

import (
	"math"
	"reflect"
	"testing"
)

func TestRequestCost(t *testing.T) {
	tests := []struct {
		name                                 string
		r                                    rates
		input, output, cacheWrite, cacheRead int
		want                                 float64
	}{
		{"zero", opusRates, 0, 0, 0, 0, 0},
		{"opus input only", opusRates, 1_000_000, 0, 0, 0, 5.0},
		{"opus output only", opusRates, 0, 1_000_000, 0, 0, 25.0},
		{"opus cache write only", opusRates, 0, 0, 1_000_000, 0, 6.25},
		{"opus cache read is counted, not dropped", opusRates, 0, 0, 0, 1_000_000, 0.5},
		{"opus typical turn", opusRates, 2_000, 1_500, 8_000, 120_000, 0.1575},
		{"sonnet typical turn", sonnetRates, 2_000, 1_500, 8_000, 120_000, 0.0945},
		{"haiku typical turn", haikuRates, 2_000, 1_500, 8_000, 120_000, 0.0315},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := requestCost(tt.r, tt.input, tt.output, tt.cacheWrite, tt.cacheRead)
			if math.Abs(got-tt.want) > 1e-9 {
				t.Errorf("requestCost(%+v, %d, %d, %d, %d) = %v, want %v",
					tt.r, tt.input, tt.output, tt.cacheWrite, tt.cacheRead, got, tt.want)
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
		displayName string
		want        rates
	}{
		{"Opus 4.8", opusRates},
		{"Claude Opus 4.8", opusRates},
		{"Sonnet 4.5", sonnetRates},
		{"claude sonnet 5", sonnetRates},
		{"Haiku 4.5", haikuRates},
		{"Fable 5", fableRates},
		{"Mythos 5", fableRates},
		{"", opusRates},
		{"?", opusRates},
		{"Some Unknown Model", opusRates},
	}
	for _, tt := range tests {
		t.Run(tt.displayName, func(t *testing.T) {
			if got := ratesFor(tt.displayName); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("ratesFor(%q) = %+v, want %+v", tt.displayName, got, tt.want)
			}
		})
	}
}
