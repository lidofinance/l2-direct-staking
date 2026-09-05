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

uint_ge() {
  local a="$1" b="$2" LC_ALL=C
  is_uint "$a" && is_uint "$b" || return 1
  a="${a#"${a%%[!0]*}"}"
  b="${b#"${b%%[!0]*}"}"
  ((${#a} > ${#b})) || { ((${#a} == ${#b})) && [[ "$a" == "$b" || "$a" > "$b" ]]; }
}

uint_double() {
  local n="$1" result="" carry=0 digit i
  is_uint "$n" || return 1
  for ((i = ${#n} - 1; i >= 0; i--)); do
    digit=$((10#${n:i:1} * 2 + carry))
    result="$((digit % 10))$result"
    carry=$((digit / 10))
  done
  result="$carry$result"
  result="${result#"${result%%[!0]*}"}"
  printf '%s' "${result:-0}"
}

lc() {
  printf '%s' "${1:-}" | tr 'A-F' 'a-f'
}

eqa() {
  [[ "$(lc "$1")" == "$(lc "$2")" ]]
}
