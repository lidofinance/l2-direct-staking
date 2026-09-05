#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Fork lifecycle and logging helpers.
source "$ROOT_DIR/script/shared/fork-farm.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/acceptance.XXXXXX")"
FORK_FARM_LOG_DIR="$WORK_DIR"
ANVIL_BALANCE="0x3635C9ADC5DEA00000" # 1000 ETH
BASE_PORT="${ACCEPTANCE_BASE_PORT:-8650}"

# L1 constants (shared across all networks)
INITIAL_OWNER="0xb5c336a5c60D3482b29d83C742C65AE8351b91a8"
LIDO_DAO_AGENT="0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c"
L1_RECEIVER="0x6F357d53d6bE3238180316BA5F8f11467e164588"
L1_PROXY_ADMIN_ADDR="0x88a45d2760b63c1500E3D2E3552b28e5Cdaa37BD"
ZERO_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"

# Network count and per-network config (parallel arrays, bash 3 compatible)
NET_NAMES=(optimism arbitrum base linea)
NET_CHAIN_IDS=(10 42161 8453 59144)
NET_RPC_ENVS=(RPC_OPTIMISM RPC_ARBITRUM RPC_BASE RPC_LINEA)
# Legacy env-var names, consulted as fallbacks when the RPC_<NET> var is unset.
NET_RPC_ENVS_LEGACY=(L2_OPTIMISM_RPC_URL L2_ARBITRUM_RPC_URL L2_BASE_RPC_URL L2_LINEA_RPC_URL)
NET_GOVS=(0xEfa0dB536d2c8089685630fafe88CF7805966FC3 0x1dcA41859Cd23b526CBe74dA8F48aC96e14B1A29 0x0E37599436974a25dDeEdF795C848d30Af46eaCF 0x74Be82F00CC867614803ffd7f36A2a4aF0405670)
NET_SCRIPTS=("script/optimism/OptimismL2Upgrade.s.sol:OptimismL2UpgradeScript"
  "script/arbitrum/ArbitrumL2Upgrade.s.sol:ArbitrumL2UpgradeScript"
  "script/base/BaseL2Upgrade.s.sol:BaseL2UpgradeScript"
  "script/linea/LineaL2Upgrade.s.sol:LineaL2UpgradeScript")
NET_TESTS=("OptimismPoolUpgradeTest|OptimismCREIntegrationTest"
  "ArbitrumPoolUpgradeTest|ArbitrumCREIntegrationTest"
  "BasePoolUpgradeTest|BaseCREIntegrationTest"
  "LineaPoolUpgradeTest|LineaCREIntegrationTest")
# CustomSender and ProxyAdmin are inherited from the fork; their addresses stay in .inputs.yaml.
NET_LOLS=(0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6 0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6 0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6 0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6)
NET_COUNT=${#NET_NAMES[@]}

for arr_name in NET_CHAIN_IDS NET_RPC_ENVS NET_RPC_ENVS_LEGACY NET_GOVS NET_SCRIPTS NET_TESTS NET_LOLS; do
  eval "arr_len=\${#${arr_name}[@]}"
  [[ "$arr_len" -eq "$NET_COUNT" ]] || die "Array $arr_name has $arr_len elements, expected $NET_COUNT"
done

cleanup() {
  fork_farm_kill_forks
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

extract_first_address() {
  local extracted
  extracted="$(printf '%s' "$1" | grep -Eo '0x[0-9a-fA-F]{40}' | head -n 1 || true)"
  [[ -n "$extracted" ]] || die "Failed to parse address from: $1"
  printf '%s\n' "$extracted"
}

compute_create_address() {
  local output
  output="$(cast compute-address "$1" --nonce "$2" | tr -d '\r\n')"
  extract_first_address "$output"
}

address_from_key() {
  cast wallet address --private-key "$1" | tr -d '\r\n'
}

# ── Step 0: Preflight ──────────────────────────────────────────
step "Step 0: Preflight checks"
for cmd in forge cast anvil node yarn jq yq; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing: $cmd"
done

L1_UPSTREAM="${RPC_ETHEREUM:-${L1_RPC_URL:-}}"
[[ -n "$L1_UPSTREAM" ]] || die "Set RPC_ETHEREUM"
chain_id=$(cast chain-id --rpc-url "$L1_UPSTREAM") || die "L1 RPC not reachable"
[[ "$chain_id" == 1 ]] || die "L1 RPC chain-id $chain_id, expected 1"
echo "L1: $L1_UPSTREAM"

# Collect and validate L2 RPCs (prefer RPC_<NET>, fall back to the legacy L2_<NET>_RPC_URL).
L2_UPSTREAMS=()
for i in $(seq 0 $((NET_COUNT - 1))); do
  rpc_env="${NET_RPC_ENVS[$i]}"
  rpc_env_legacy="${NET_RPC_ENVS_LEGACY[$i]}"
  rpc_val="${!rpc_env:-}"
  [[ -n "$rpc_val" ]] || rpc_val="${!rpc_env_legacy:-}"
  [[ -n "$rpc_val" ]] || die "Set $rpc_env"
  chain_id=$(cast chain-id --rpc-url "$rpc_val") || die "${NET_NAMES[$i]} RPC not reachable"
  [[ "$chain_id" == "${NET_CHAIN_IDS[$i]}" ]] || die "${NET_NAMES[$i]} RPC chain-id $chain_id, expected ${NET_CHAIN_IDS[$i]}"
  L2_UPSTREAMS+=("$rpc_val")
  echo "${NET_NAMES[$i]}: $rpc_val"
done
echo "All RPCs OK"

# Fund the fork deployer below; default to anvil dev key #0.
export L2_LIDO_DEPLOYER_PRIVATE_KEY="${L2_LIDO_DEPLOYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
DEPLOYER_ADDR="$(address_from_key "$L2_LIDO_DEPLOYER_PRIVATE_KEY")"
echo "Deployer: $DEPLOYER_ADDR"

# Step 1: Spawn forks. Set FORK_SPAWN_COOLDOWN_SECONDS for rate-limited remote RPCs.
FORK_SPAWN_COOLDOWN_SECONDS="${FORK_SPAWN_COOLDOWN_SECONDS:-0}"

step "Step 1: Starting Anvil forks"
L1_PORT="$BASE_PORT"
spawn_fork "L1" "$L1_UPSTREAM" "$L1_PORT"
L1_FORK_URL="$FORK_URL"

L2_FORK_URLS=()
L2_FORK_SNAPSHOTS=()
for i in $(seq 0 $((NET_COUNT - 1))); do
  # Skip cool-down after the last L2 — nothing else spawns after it.
  cooldown=$FORK_SPAWN_COOLDOWN_SECONDS
  ((i == NET_COUNT - 1)) && cooldown=0
  spawn_fork "${NET_NAMES[$i]}" "${L2_UPSTREAMS[$i]}" "$((BASE_PORT + 1 + i))" "$cooldown"
  fork_url="$FORK_URL"
  L2_FORK_URLS+=("$fork_url")
done
echo "All forks ready"

# ── Step 2: L2 migrations (per-network) ────────────────────────
DEPLOYED_POOLS=()
DEPLOYED_TRIGGERS=()
DEPLOYED_RECEIVERS=()

for i in $(seq 0 $((NET_COUNT - 1))); do
  name="${NET_NAMES[$i]}"
  fork_url="${L2_FORK_URLS[$i]}"
  gov="${NET_GOVS[$i]}"

  step "Step 2: $name L2 migration"

  cast rpc --rpc-url "$fork_url" anvil_setBalance "$DEPLOYER_ADDR" "$ANVIL_BALANCE" >/dev/null
  cast rpc --rpc-url "$fork_url" anvil_setBalance "$INITIAL_OWNER" "$ANVIL_BALANCE" >/dev/null

  # Reproduce deploy-test → activate → handoff → finalize with each step's actor.
  # handoff restores production settings; finalize seals governance.
  # Step 4 tests simulated CRE sync; real DON reports are outside this fork test.
  script_file="${NET_SCRIPTS[$i]%:*}"
  script_base="$(basename "$script_file")"
  chain_id="$(cast chain-id --rpc-url "$fork_url" | tr -d '\r\n')"
  export INITIAL_OWNER

  substep "0→1: deploy-test (deployer-owned canary)"
  (
    cd "$ROOT_DIR"
    forge script "${NET_SCRIPTS[$i]}" --sig "runDeployTest()" \
      --rpc-url "$fork_url" --broadcast --non-interactive 2>&1 | tail -5
  )

  # Read addresses from broadcast JSON so nonce changes do not break later steps.
  bcast_json="$ROOT_DIR/broadcast/${script_base}/${chain_id}/runDeployTest-latest.json"
  [[ -f "$bcast_json" ]] || die "Missing forge broadcast JSON: $bcast_json"
  pool_addr="$(jq -r '[.transactions[] | select(.contractName == "PausableImmutableOraclePool")][0].contractAddress' "$bcast_json")"
  trigger_addr="$(jq -r '[.transactions[] | select(.contractName == "SyncTrigger")][0].contractAddress' "$bcast_json")"
  recv_addr="$(jq -r '[.transactions[] | select(.contractName == "CREReceiver")][0].contractAddress' "$bcast_json")"
  pool_addr="$(cast to-check-sum-address "$pool_addr")"
  trigger_addr="$(cast to-check-sum-address "$trigger_addr")"
  recv_addr="$(cast to-check-sum-address "$recv_addr")"
  export L2_ORACLE_POOL="$pool_addr" L2_SYNC_TRIGGER="$trigger_addr" L2_CRE_RECEIVER="$recv_addr"

  # Forge suites bind to the deployed canary, before activate/handoff/finalize.
  snap="$(cast rpc --rpc-url "$fork_url" evm_snapshot | tr -d '"\r\n')"
  L2_FORK_SNAPSHOTS+=("$snap")

  substep "0→1: activate (INITIAL_OWNER repoints pool + grants SYNC_ROLE)"
  (
    cd "$ROOT_DIR"
    forge script "${NET_SCRIPTS[$i]}" --sig "runActivateUnlocked()" \
      --rpc-url "$fork_url" --broadcast --non-interactive \
      --unlocked --sender "$INITIAL_OWNER" 2>&1 | tail -5
  )

  substep "1→2: handoff (restore production config, transfer to LOL multisig)"
  (
    cd "$ROOT_DIR"
    forge script "${NET_SCRIPTS[$i]}" --sig "runHandoff()" \
      --rpc-url "$fork_url" --broadcast --non-interactive 2>&1 | tail -5
  )

  substep "2→3: finalize (irreversible governance seal)"
  (
    cd "$ROOT_DIR"
    forge script "${NET_SCRIPTS[$i]}" --sig "runFinalizeUnlocked()" \
      --rpc-url "$fork_url" --broadcast --non-interactive \
      --unlocked --sender "$INITIAL_OWNER" 2>&1 | tail -5
  )

  echo "  OraclePool: $pool_addr  SyncTrigger: $trigger_addr  CREReceiver: $recv_addr"

  DEPLOYED_POOLS+=("$pool_addr")
  DEPLOYED_TRIGGERS+=("$trigger_addr")
  DEPLOYED_RECEIVERS+=("$recv_addr")
done

# ── L1 migration (once, shared) ────────────────────────────────
step "Step 2: L1 migration (shared)"
cast rpc --rpc-url "$L1_FORK_URL" anvil_setBalance "$INITIAL_OWNER" "$ANVIL_BALANCE" >/dev/null
cast send --unlocked --from "$INITIAL_OWNER" --rpc-url "$L1_FORK_URL" \
  "$L1_RECEIVER" "grantRole(bytes32,address)" "$ZERO_ROLE" "$LIDO_DAO_AGENT" >/dev/null
cast send --unlocked --from "$INITIAL_OWNER" --rpc-url "$L1_FORK_URL" \
  "$L1_RECEIVER" "revokeRole(bytes32,address)" "$ZERO_ROLE" "$INITIAL_OWNER" >/dev/null
cast send --unlocked --from "$INITIAL_OWNER" --rpc-url "$L1_FORK_URL" \
  "$L1_PROXY_ADMIN_ADDR" "transferOwnership(address)" "$LIDO_DAO_AGENT" >/dev/null
echo "L1 admin → $LIDO_DAO_AGENT"

# ── Step 3: State-mate verification (per-network) ──────────────
step "Step 3: State-mate verification"
STATE_MATE_DIR="$ROOT_DIR/lib/state-mate"
if [[ ! -d "$STATE_MATE_DIR/node_modules" ]]; then
  echo "Installing state-mate dependencies"
  (cd "$STATE_MATE_DIR" && yarn install --immutable) || die "Failed to install state-mate dependencies"
fi

for i in $(seq 0 $((NET_COUNT - 1))); do
  name="${NET_NAMES[$i]}"
  fork_url="${L2_FORK_URLS[$i]}"
  gov="${NET_GOVS[$i]}"
  liq_owner="${NET_LOLS[$i]}"

  sm_config="$ROOT_DIR/config/state/l2.yaml"
  sm_inputs="$ROOT_DIR/config/state/$name.inputs.yaml"
  sm_common_inputs="$ROOT_DIR/config/state/l2.common.inputs.yaml"
  # Pass fork addresses through a temporary .deployed.yaml.
  # Include both common and lane inputs: l2.yaml cannot infer the lane.
  # Keep the mainnet deployer anchor: its inherited CustomSender admin role must be absent.
  fork_deployed="$WORK_DIR/$name.deployed.yaml"
  workflow_id="$(yq '.. | select(anchor == "creWorkflowId")' "$ROOT_DIR/config/state/$name.deployed.yaml" | tr -d '"' | head -n1)"
  retired_trigger="$(yq '.. | select(anchor == "RETIRED_l2SyncTrigger")' "$ROOT_DIR/config/state/$name.deployed.yaml" | tr -d '"' | head -n1)"
  retired_receiver="$(yq '.. | select(anchor == "RETIRED_l2CreReceiver")' "$ROOT_DIR/config/state/$name.deployed.yaml" | tr -d '"' | head -n1)"
  substep "$name: writing fork .deployed.yaml"
  bash "$ROOT_DIR/script/shared/write-deployed-yaml.sh" "$fork_deployed" \
    "${DEPLOYED_POOLS[$i]}" "${DEPLOYED_TRIGGERS[$i]}" "${DEPLOYED_RECEIVERS[$i]}" \
    "$workflow_id" "$retired_trigger" "$retired_receiver"

  substep "$name: running state-mate checks"
  (
    cd "$STATE_MATE_DIR"
    L1_RPC_URL="$L1_FORK_URL" L2_STATE_MATE_RPC_URL="$fork_url" \
      yarn start "$sm_config" --inputs "$sm_common_inputs" --inputs "$sm_inputs" --deployed "$fork_deployed" 2>&1 | tail -8
  ) || die "$name state-mate failed"
  # Linea-only Gelato de-role — separate config; its static inputs match the fork.
  if [[ "$name" == "linea" ]]; then
    substep "$name: running Linea Gelato de-role state-mate check"
    (
      cd "$STATE_MATE_DIR"
      L2_STATE_MATE_RPC_URL="$fork_url" yarn start "$ROOT_DIR/config/state/l2-linea-gelato.yaml" --only "l2" 2>&1 | tail -8
    ) || die "$name Gelato state-mate failed"
  fi
done
echo "All L2 state-mate checks passed"

substep "L1: running state-mate checks against fork"
(
  cd "$STATE_MATE_DIR"
  L1_RPC_URL="$L1_FORK_URL" yarn start "$ROOT_DIR/config/state/ethereum.yaml" --only "l1" 2>&1 | tail -12
) || die "L1 state-mate failed"
echo "L1 state-mate checks passed"

# Step 4: Forge tests bind to Stage-1 canaries and rerun the remaining migration.
# Revert L2 snapshots while retaining the warmed cache; use the untouched L1 upstream.
# vm.createFork keeps each suite's changes in memory.
substep "Restoring L2 Stage-1 canary snapshots for forge tests"
for i in $(seq 0 $((NET_COUNT - 1))); do
  cast rpc --rpc-url "${L2_FORK_URLS[$i]}" evm_revert "${L2_FORK_SNAPSHOTS[$i]}" >/dev/null ||
    die "${NET_NAMES[$i]} evm_revert to snapshot ${L2_FORK_SNAPSHOTS[$i]} failed"
done

# Run suites sequentially to limit upstream RPC load. Export both RPC aliases used by the tests.
step "Step 4: Forge integration tests (per network)"
for i in $(seq 0 $((NET_COUNT - 1))); do
  name="${NET_NAMES[$i]}"
  l2_env="${NET_RPC_ENVS_LEGACY[$i]}"
  substep "$name: forge tests (${NET_TESTS[$i]})"
  (
    cd "$ROOT_DIR"
    export L1_RPC_URL="$L1_UPSTREAM"
    export "$l2_env=${L2_FORK_URLS[$i]}"
    export "LOCAL_$l2_env=${L2_FORK_URLS[$i]}"
    export L2_ORACLE_POOL="${DEPLOYED_POOLS[$i]}"
    export L2_SYNC_TRIGGER="${DEPLOYED_TRIGGERS[$i]}"
    export L2_CRE_RECEIVER="${DEPLOYED_RECEIVERS[$i]}"
    export ETH_RPC_TIMEOUT="${ETH_RPC_TIMEOUT:-120}"
    forge test --match-contract "${NET_TESTS[$i]}" -vv
  ) || die "$name forge tests failed"
done

# ── Step 5: Report ─────────────────────────────────────────────
step "PASS: Full acceptance test complete"
echo "  L1 fork: $L1_FORK_URL"
for i in $(seq 0 $((NET_COUNT - 1))); do
  echo "  ${NET_NAMES[$i]}: pool=${DEPLOYED_POOLS[$i]} trigger=${DEPLOYED_TRIGGERS[$i]} receiver=${DEPLOYED_RECEIVERS[$i]}"
done
