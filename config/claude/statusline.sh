#!/bin/sh
# Claude Code status line - receives JSON on stdin

eval "$(jq -r '
  @sh "model=\(.model.display_name // "?")",
  @sh "ctx_pct=\(.context_window.used_percentage // 0)",
  @sh "tok_in=\(.context_window.current_usage.input_tokens // 0)",
  @sh "tok_out=\(.context_window.current_usage.output_tokens // 0)",
  @sh "tok_new=\(.context_window.current_usage.cache_creation_input_tokens // 0)",
  @sh "rate_5h=\(.rate_limits.five_hour.used_percentage // 0)",
  @sh "rate_7d=\(.rate_limits.seven_day.used_percentage // 0)",
  @sh "epoch_5h=\(.rate_limits.five_hour.resets_at // empty)",
  @sh "epoch_7d=\(.rate_limits.seven_day.resets_at // empty)",
  @sh "cost=\(.cost.total_cost_usd // 0)"
')"

tok_total=$((tok_in + tok_out + tok_new))
req_cost=$(awk "BEGIN {printf \"%.4f\", ($tok_in * 15 + $tok_out * 75 + $tok_new * 18.75) / 1000000}")

fmt_time() {
  epoch=$1
  fallback=$2
  [ "$epoch" = "" ] && printf '%s' "$fallback" && return
  now=$(date +%s)
  diff=$((epoch - now))
  [ "$diff" -le 0 ] && printf '0m' && return
  if [ "$diff" -ge 86400 ]; then
    d=$((diff / 86400))
    h=$(((diff % 86400) / 3600))
    printf '%dd%dh' "$d" "$h"
  elif [ "$diff" -ge 3600 ]; then
    h=$((diff / 3600))
    m=$(((diff % 3600) / 60))
    printf '%dh%dm' "$h" "$m"
  else
    m=$((diff / 60))
    printf '%dm' "$m"
  fi
}

reset_5h=$(fmt_time "$epoch_5h" "5h")
reset_7d=$(fmt_time "$epoch_7d" "7d")

bar() {
  pct=$1
  width=5
  filled=$((pct * width / 100))
  i=0
  while [ "$i" -lt "$width" ]; do
    if [ "$i" -lt "$filled" ]; then
      printf '━'
    else
      printf '─'
    fi
    i=$((i + 1))
  done
}

LC_NUMERIC=C printf '↓%d ↑%d +%d (%d) $%s  ctx %s %d%%  %s %s %d%%  %s %s %d%%  $%.2f  %s' \
  "$tok_in" "$tok_out" "$tok_new" "$tok_total" "$req_cost" \
  "$(bar "$ctx_pct")" "$ctx_pct" \
  "$reset_5h" "$(bar "$rate_5h")" "$rate_5h" \
  "$reset_7d" "$(bar "$rate_7d")" "$rate_7d" \
  "$cost" "$model"
