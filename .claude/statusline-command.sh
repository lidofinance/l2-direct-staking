#!/usr/bin/env bash
input=$(cat)

# Total session tokens (input + output)
in_tok=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
out_tok=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
total=$((in_tok + out_tok))
if [ "$total" -ge 1000000 ] 2>/dev/null; then
  tok="$(echo "$total" | awk '{printf "%.1fM", $1/1000000}')"
elif [ "$total" -ge 1000 ] 2>/dev/null; then
  tok="$(echo "$total" | awk '{printf "%.1fK", $1/1000}')"
else
  tok="$total"
fi

# Context window usage
ctx=$(echo "$input" | jq -r '.context_window.used_percentage // 0')

# Session cost
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0' | awk '{printf "$%.2f", $1}')

printf "tokens: %s | ctx: %s%% | %s" "$tok" "$ctx" "$cost"
