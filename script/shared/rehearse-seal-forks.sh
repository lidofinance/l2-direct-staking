#!/usr/bin/env bash
# Rehearse the irreversible governance seal on forks of live mainnet state:
#   Initial Owner impersonated → runFinalizeUnlocked ×4 → runUnlocked migrate-l1 → state-mate.
#
# Unlike `just test-acceptance` (fresh canary deploy on forks), this starts from the *current*
# live wiring already present on upstream (activate / handoff / AO automation already done) and
# only exercises the seal steps the Initial Owner will broadcast for real.
#
# Required env: live mainnet RPCs. Resolution order per chain (first non-empty wins):
#   L1: RPC_ETHEREUM_REMOTE → RPC_ETHEREUM → L1_RPC_URL
#   L2: RPC_<NET>_REMOTE → RPC_<NET> → L2_<NET>_RPC_URL
# Prefer *_REMOTE so a stale local anvil proxy in RPC_<NET> cannot be forked by mistake.
# No Initial Owner private key — anvil impersonation only.
#
# Optional: SEAL_REHEARSAL_BASE_PORT (default 8750), FORK_SPAWN_COOLDOWN_SECONDS (default 5;
# bump e.g. to 10 when forking four L2s off one shared Infura key).
#
# Usage: just rehearse-seal
#    or: bash script/shared/rehearse-seal-forks.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/script/shared/fork-farm.sh"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rehearse-seal.XXXXXX")"
FORK_FARM_LOG_DIR="$WORK_DIR"
ANVIL_BALANCE="0x3635C9ADC5DEA00000" # 1000 ETH
BASE_PORT="${SEAL_REHEARSAL_BASE_PORT:-8750}"
# The *_REMOTE upstreams are one shared remote key, which rate-limits under parallel genesis bursts.
FORK_SPAWN_COOLDOWN_SECONDS="${FORK_SPAWN_COOLDOWN_SECONDS:-5}"

NET_NAMES=(optimism arbitrum base linea)
LAST_NET=$(( ${#NET_NAMES[@]} - 1 ))

cleanup() {
  fork_farm_kill_forks
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Uppercase a lane name for its RPC_<NET>[_REMOTE] / L2_<NET>_RPC_URL env spellings.
# (bash 3 has no ${x^^}.)
net_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

require_address() {
  local value="$1" what="$2"
  [[ "$value" =~ ^0x[0-9a-fA-F]{40}$ && "$value" != 0x0000000000000000000000000000000000000000 ]] \
    || die "$what is not a non-zero address (got '$value')"
}

# Print the address carried by YAML anchor $2 in file $1.
yml_addr() {
  local file="$1" anchor="$2" value
  [[ -f "$file" ]] || die "missing $file"
  value="$(yq ".. | select(anchor == \"$anchor\") | ." "$file" 2>/dev/null | head -n1 | tr -d '"')"
  require_address "$value" "anchor &$anchor in $file"
  printf '%s\n' "$value"
}

require_code() {
  local rpc_url="$1" address="$2" context="$3" size
  size="$(cast codesize "$address" --rpc-url "$rpc_url" 2>/dev/null | tr -d '\r\n' || true)"
  [[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] || die "$context: no code at $address via $rpc_url"
}

for cmd in forge cast anvil yq just; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
done

# ── Preflight ─────────────────────────────────────────────────────────────
step "Preflight"
L1_UPSTREAM="${RPC_ETHEREUM_REMOTE:-${RPC_ETHEREUM:-${L1_RPC_URL:-}}}"
[[ -n "$L1_UPSTREAM" ]] || die "Set RPC_ETHEREUM_REMOTE (or RPC_ETHEREUM / L1_RPC_URL)"
cast chain-id --rpc-url "$L1_UPSTREAM" >/dev/null 2>&1 || die "L1 RPC not reachable: $L1_UPSTREAM"
echo "L1: $L1_UPSTREAM"

# Resolve the live wiring once per lane: upstream RPC plus every address the seal acts on.
L2_UPSTREAMS=()
L2_POOLS=()
L2_TRIGGERS=()
L2_RECEIVERS=()
L2_RETIRED=()
for i in "${!NET_NAMES[@]}"; do
  name="${NET_NAMES[$i]}"
  upper="$(net_upper "$name")"
  remote_env="RPC_${upper}_REMOTE"
  plain_env="RPC_${upper}"
  legacy_env="L2_${upper}_RPC_URL"
  rpc_val="${!remote_env:-}"
  [[ -n "$rpc_val" ]] || rpc_val="${!plain_env:-}"
  [[ -n "$rpc_val" ]] || rpc_val="${!legacy_env:-}"
  [[ -n "$rpc_val" ]] || die "Set $remote_env (or $plain_env / $legacy_env)"

  deployed="config/state/$name.deployed.yaml"
  L2_POOLS+=("$(yml_addr "$deployed" l2OraclePool)")
  L2_TRIGGERS+=("$(yml_addr "$deployed" l2SyncTrigger)")
  L2_RECEIVERS+=("$(yml_addr "$deployed" l2CreReceiver)")
  L2_RETIRED+=("$(yml_addr "$deployed" RETIRED_l2SyncTrigger)")

  # Fail closed unless the live SyncTrigger has code on this upstream: no code means either an
  # unreachable RPC or a stale local anvil proxy standing in for mainnet. Doubles as the
  # reachability probe, so no separate chain-id round trip.
  require_code "$rpc_val" "${L2_TRIGGERS[$i]}" \
    "$name upstream (unreachable, or not live mainnet — prefer $remote_env)"
  L2_UPSTREAMS+=("$rpc_val")
  echo "$name: $rpc_val"
done

INITIAL_OWNER="$(yml_addr config/state/ethereum.inputs.yaml initialOwner)"
export INITIAL_OWNER
echo "Initial Owner: $INITIAL_OWNER"

# ── Spawn forks ───────────────────────────────────────────────────────────
step "Starting Anvil forks (live-state base)"
spawn_fork ethereum "$L1_UPSTREAM" "$BASE_PORT"
L1_FORK_URL="$FORK_URL"

L2_FORK_URLS=()
for i in "${!NET_NAMES[@]}"; do
  # Nothing spawns after the last lane, so it needs no cool-down.
  cooldown="$FORK_SPAWN_COOLDOWN_SECONDS"
  (( i == LAST_NET )) && cooldown=0
  spawn_fork "${NET_NAMES[$i]}" "${L2_UPSTREAMS[$i]}" "$(( BASE_PORT + 1 + i ))" "$cooldown"
  L2_FORK_URLS+=("$FORK_URL")
  # Anvil answers chain-id before it has necessarily served any state; confirm this fork really
  # inherited the live SyncTrigger bytecode before a seal is broadcast against it.
  require_code "$FORK_URL" "${L2_TRIGGERS[$i]}" "${NET_NAMES[$i]} fork (upstream fork incomplete)"
done

# ── L2 finalize ×4 (impersonated Initial Owner) ───────────────────────────
step "L2 finalize ×4 (runFinalizeUnlocked, impersonated IO)"
for i in "${!NET_NAMES[@]}"; do
  name="${NET_NAMES[$i]}"
  fork_url="${L2_FORK_URLS[$i]}"

  script_target="$(just _l2-script-target "$name")" || die "$name: no upgrade script target"
  # Resolved with the same reader the production `finalize` recipe uses (common + lane delta), so the
  # rehearsal cannot disagree with the real run about who the Automation Owner is.
  automation_owner="$(just _l2-input-anchor "$name" l2AutomationOwner)" \
    || die "$name: cannot resolve l2AutomationOwner"
  require_address "$automation_owner" "$name l2AutomationOwner"

  export L2_AUTOMATION_OWNER="$automation_owner"
  export L2_ORACLE_POOL="${L2_POOLS[$i]}"
  export L2_SYNC_TRIGGER="${L2_TRIGGERS[$i]}"
  export L2_CRE_RECEIVER="${L2_RECEIVERS[$i]}"
  export L2_RETIRED_SYNC_TRIGGER="${L2_RETIRED[$i]}"

  cast rpc --rpc-url "$fork_url" anvil_setBalance "$INITIAL_OWNER" "$ANVIL_BALANCE" >/dev/null

  substep "$name: runFinalizeUnlocked (pool=$L2_ORACLE_POOL trigger=$L2_SYNC_TRIGGER)"
  forge script "$script_target" --sig 'runFinalizeUnlocked()' \
    --rpc-url "$fork_url" --broadcast --non-interactive \
    --unlocked --sender "$INITIAL_OWNER" \
    || die "$name finalize failed"
done

# ── L1 migrate (impersonated Initial Owner) ───────────────────────────────
step "L1 migrate-l1 (runUnlocked, impersonated IO)"
cast rpc --rpc-url "$L1_FORK_URL" anvil_setBalance "$INITIAL_OWNER" "$ANVIL_BALANCE" >/dev/null
forge script script/l1/L1UpgradeScript.s.sol:L1UpgradeScript --sig 'runUnlocked()' \
  --rpc-url "$L1_FORK_URL" --broadcast --non-interactive \
  --unlocked --sender "$INITIAL_OWNER" \
  || die "L1 migrate-l1 failed"

# ── state-mate post-seal ──────────────────────────────────────────────────
# Delegated to the production verification recipes, so the rehearsal asserts the end state through
# the exact configs and arguments the operator will use post-seal. The per-lane runs are narrowed to
# `--only l2`: the seal does not touch the CRE WorkflowRegistry, and an unrelated registry
# ACTIVE/owner mismatch must not mask the seal verdict.
#
# A failing run is recorded, not fatal — one broken lane must not hide the state of the other three
# (the partial-pass hazard `_state-verify` is itself built around).
step "state-mate post-seal verification"
FAILED_RUNS=()
for i in "${!NET_NAMES[@]}"; do
  name="${NET_NAMES[$i]}"
  substep "$name: _state-verify --only l2 (plus the Linea Gelato de-role run on that lane)"
  L1_RPC_URL="$L1_FORK_URL" just _state-verify "$name" "${L2_FORK_URLS[$i]}" l2 \
    || FAILED_RUNS+=("$name")
done

substep "L1: ethereum.yaml"
just verify-l1-state-mate "$L1_FORK_URL" || FAILED_RUNS+=("ethereum")

(( ${#FAILED_RUNS[@]} == 0 )) || die "post-seal state-mate failed for: ${FAILED_RUNS[*]}"

step "PASS: seal rehearsal complete (4× finalize + migrate-l1 + state-mate)"
