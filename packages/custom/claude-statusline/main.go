package main

import (
	"encoding/json"
	"fmt"
	"os"
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
	tokTotal := tokIn + tokOut + tokNew

	reqCost := (float64(tokIn)*15 + float64(tokOut)*75 + float64(tokNew)*18.75) / 1000000

	ctxPct := input.ContextWindow.UsedPercentage
	rate5h := input.RateLimits.FiveHour.UsedPercentage
	rate7d := input.RateLimits.SevenDay.UsedPercentage

	reset5h := formatTime(input.RateLimits.FiveHour.ResetsAt, "5h")
	reset7d := formatTime(input.RateLimits.SevenDay.ResetsAt, "7d")

	fmt.Printf("↓%d ↑%d +%d (%d) $%.4f  ctx %s %.0f%%  %s %s %.0f%%  %s %s %.0f%%  $%.2f  %s",
		tokIn, tokOut, tokNew, tokTotal, reqCost,
		bar(ctxPct), ctxPct,
		reset5h, bar(rate5h), rate5h,
		reset7d, bar(rate7d), rate7d,
		input.Cost.TotalCostUSD, model)
}
