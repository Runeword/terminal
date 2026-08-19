package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type StatusInput struct {
	Model struct {
		DisplayName string `json:"display_name"`
	} `json:"model"`
	ContextWindow struct {
		UsedPercentage float64 `json:"used_percentage"`
		CurrentUsage   struct {
			InputTokens              int `json:"input_tokens"`
			OutputTokens             int `json:"output_tokens"`
			CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
			CacheReadInputTokens     int `json:"cache_read_input_tokens"`
		} `json:"current_usage"`
	} `json:"context_window"`
	RateLimits struct {
		FiveHour struct {
			UsedPercentage float64 `json:"used_percentage"`
			ResetsAt       *int64  `json:"resets_at"`
		} `json:"five_hour"`
		SevenDay struct {
			UsedPercentage float64 `json:"used_percentage"`
			ResetsAt       *int64  `json:"resets_at"`
		} `json:"seven_day"`
	} `json:"rate_limits"`
	Cost struct {
		TotalCostUSD float64 `json:"total_cost_usd"`
	} `json:"cost"`
}

// rates holds per-MTok USD prices for a model family: uncached input, output,
// 5-minute-TTL cache creation (input×1.25), and cache read (input×0.1).
type rates struct {
	input, output, cacheWrite, cacheRead float64
}

var (
	opusRates   = rates{5, 25, 6.25, 0.5}
	sonnetRates = rates{3, 15, 3.75, 0.3}
	haikuRates  = rates{1, 5, 1.25, 0.1}
	fableRates  = rates{10, 50, 12.5, 1}
)

// ratesFor selects pricing from the model's display name, defaulting to Opus
// when the family is unrecognised (or the name is empty).
func ratesFor(displayName string) rates {
	name := strings.ToLower(displayName)
	switch {
	case strings.Contains(name, "haiku"):
		return haikuRates
	case strings.Contains(name, "sonnet"):
		return sonnetRates
	case strings.Contains(name, "fable"), strings.Contains(name, "mythos"):
		return fableRates
	default:
		return opusRates
	}
}

// requestCost estimates the USD cost of a single request from its token counts.
func requestCost(r rates, input, output, cacheWrite, cacheRead int) float64 {
	return (float64(input)*r.input +
		float64(output)*r.output +
		float64(cacheWrite)*r.cacheWrite +
		float64(cacheRead)*r.cacheRead) / 1_000_000
}

// humanTokens renders a token count compactly so the bar stays legible: bare
// below 1000, then "k" (thousands) or "M" (millions) with one decimal while the
// scaled value is under 10 and none above. So 2354→"2.4k", 95191→"95k",
// 101661→"102k". The k/M cutover sits just under 1e6 so a count that would round
// to "1000k" shows as "1.0M" instead.
func humanTokens(n int) string {
	switch {
	case n < 1000:
		return strconv.Itoa(n)
	case n < 999_500:
		return scaled(float64(n)/1000, "k")
	default:
		return scaled(float64(n)/1_000_000, "M")
	}
}

func scaled(v float64, unit string) string {
	prec := 0
	if v < 10 {
		prec = 1
	}
	return strconv.FormatFloat(v, 'f', prec, 64) + unit
}

func bar(pct float64) string {
	width := 5
	filled := int(pct * float64(width) / 100)
	result := ""
	for i := 0; i < width; i++ {
		if i < filled {
			result += "━"
		} else {
			result += "─"
		}
	}
	return result
}

func formatTime(epoch *int64, fallback string) string {
	if epoch == nil {
		return fallback
	}
	now := time.Now().Unix()
	diff := *epoch - now
	if diff <= 0 {
		return "0m"
	}
	if diff >= 86400 {
		d := diff / 86400
		h := (diff % 86400) / 3600
		return fmt.Sprintf("%dd%dh", d, h)
	}
	if diff >= 3600 {
		h := diff / 3600
		m := (diff % 3600) / 60
		return fmt.Sprintf("%dh%dm", h, m)
	}
	m := diff / 60
	return fmt.Sprintf("%dm", m)
}

func main() {
	var input StatusInput
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		fmt.Fprintf(os.Stderr, "error parsing JSON: %v\n", err)
		os.Exit(1)
	}

	model := input.Model.DisplayName
	if model == "" {
		model = "?"
	}

	tokIn := input.ContextWindow.CurrentUsage.InputTokens
	tokOut := input.ContextWindow.CurrentUsage.OutputTokens
	tokNew := input.ContextWindow.CurrentUsage.CacheCreationInputTokens
	tokRead := input.ContextWindow.CurrentUsage.CacheReadInputTokens
	tokTotal := tokIn + tokOut + tokNew + tokRead

	reqCost := requestCost(ratesFor(model), tokIn, tokOut, tokNew, tokRead)

	ctxPct := input.ContextWindow.UsedPercentage
	rate5h := input.RateLimits.FiveHour.UsedPercentage
	rate7d := input.RateLimits.SevenDay.UsedPercentage

	reset5h := formatTime(input.RateLimits.FiveHour.ResetsAt, "5h")
	reset7d := formatTime(input.RateLimits.SevenDay.ResetsAt, "7d")

	fmt.Printf("↓%s ↑%s W%s R%s =%s $%.4f  ctx %s %.0f%%  %s %s %.0f%%  %s %s %.0f%%  $%.2f  %s",
		humanTokens(tokIn), humanTokens(tokOut), humanTokens(tokNew), humanTokens(tokRead), humanTokens(tokTotal), reqCost,
		bar(ctxPct), ctxPct,
		reset5h, bar(rate5h), rate5h,
		reset7d, bar(rate7d), rate7d,
		input.Cost.TotalCostUSD, model)
}
