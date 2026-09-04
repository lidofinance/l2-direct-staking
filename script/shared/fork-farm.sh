#!/usr/bin/env bash
# Anvil fork farm: spawn mainnet forks one at a time, track their PIDs, reap them on exit.
# SOURCE this file, do not execute it.
#
#   FORK_FARM_LOG_DIR="$WORK_DIR"                    # where each anvil's output is written
#   source script/shared/fork-farm.sh
#   trap 'fork_farm_kill_forks; rm -rf "$WORK_DIR"' EXIT
#   spawn_fork ethereum "$RPC_ETHEREUM_REMOTE" 8650  # blocks until ready; sets FORK_URL
#
# Why shared: two multi-chain fork harnesses need the identical 1×L1 + 4×L2 farm — `_acceptance-test`
# (fresh canary deploy on forks) and `rehearse-seal` (seal-only rehearsal on live wiring). The serial
# spawn with a cool-down is a hard-won rate-limit workaround; keeping one copy means a fix to it
# cannot land in only half the callers.
#
# Also holds the progress/abort helpers both callers print with, so their output reads the same.

die() { echo "FAIL: $*" >&2; exit 1; }
step() { echo ""; echo "═══ $1 ═══"; }
substep() { echo "  ── $1"; }

# PIDs of every anvil this farm started.
ANVIL_PIDS=""

fork_farm_kill_forks() {
  local pid
  for pid in $ANVIL_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  ANVIL_PIDS=""
}

wait_for_rpc() {
  local url="$1" name="$2" timeout="${3:-180}"
  for _ in $(seq 1 "$timeout"); do
    cast chain-id --rpc-url "$url" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "$name fork failed to start within ${timeout}s"
}

# spawn_fork <name> <upstream> <port> [cooldown_seconds]
# Starts one anvil fork of <upstream>, blocks until it answers eth_chainId, and sets FORK_URL to its
# endpoint. Output goes to $FORK_FARM_LOG_DIR/<name>.log.
#
# Forks are spawned SERIALLY (each waits for the previous one to answer, plus a short cool-down)
# because anvil bursts eth_get* calls while building genesis: four parallel L2 forks against one
# shared API key hit HTTP 429 and the losing anvils exit with "failed to create genesis".
# `wait_for_rpc` returns as soon as chain-id answers, but the genesis burst is still draining for a
# few seconds after that — the cool-down lets it finish before the next fork starts hammering the
# same key. It is a wall-clock BUDGET measured from spawn, not an additive sleep: if waiting for the
# RPC already burned it on a slow day, nothing sleeps. Callers set the default via
# FORK_SPAWN_COOLDOWN_SECONDS — 0 when the upstreams are local proxies that cannot rate-limit.
spawn_fork() {
  local name="$1" upstream="$2" port="$3" cooldown="${4:-${FORK_SPAWN_COOLDOWN_SECONDS:-0}}"
  local spawn_t=$SECONDS
  : "${FORK_FARM_LOG_DIR:?set FORK_FARM_LOG_DIR before spawn_fork}"
  FORK_URL="http://127.0.0.1:$port"
  anvil --hardfork amsterdam --silent --auto-impersonate -p "$port" -f "$upstream" >"$FORK_FARM_LOG_DIR/$name.log" 2>&1 &
  ANVIL_PIDS="$ANVIL_PIDS $!"
  echo "$name fork: $FORK_URL (upstream $upstream)"
  wait_for_rpc "$FORK_URL" "$name"
  if (( cooldown > 0 )); then
    local remaining=$(( cooldown - (SECONDS - spawn_t) ))
    (( remaining > 0 )) && sleep "$remaining"
  fi
  # Explicit: an already-spent budget leaves the `if` returning 1, which under `set -e` would abort
  # the caller at the spawn call site.
  return 0
}
