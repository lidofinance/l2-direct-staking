#!/usr/bin/env bash
# Shared parsing for read-only monitoring and the stake preflight.
parse_num() {
  local s="$1"
  s="${s%%[*}"
  s="${s%% *}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"
  printf '%s' "$s"
}
yq1() {
  yq "[.. | select(anchor==\"$2\")][0]" "$1" 2>/dev/null | tr -d '"' | tr -d '\r\n'
}

is_addr() {
  [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

lc() {
  printf '%s' "${1:-}" | tr 'A-F' 'a-f'
}

eqa() {
  [[ "$(lc "$1")" == "$(lc "$2")" ]]
}
