#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
: "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
for c in yq cast jq bc; do
  command -v "$c" >/dev/null 2>&1 || {
    echo "$c is required" >&2
    exit 1
  }
done

# Resolve L2 RPC: prefer RPC_<NET> (shell env), fall back to L2_RPC_URL (legacy .env file).
_net_upper=$(echo "$L2_NETWORK" | tr '[:lower:]' '[:upper:]')
_rpc_var="RPC_${_net_upper}"
L2_RPC_URL="${!_rpc_var:-${L2_RPC_URL:-}}"
: "${L2_RPC_URL:?Set ${_rpc_var} (or legacy L2_RPC_URL) for $L2_NETWORK}"

sm_inputs="${ROOT_DIR}/config/state/${L2_NETWORK}.inputs.yaml"
sm_deployed="${ROOT_DIR}/config/state/${L2_NETWORK}.deployed.yaml"
[[ -f "$sm_inputs" ]] || {
  echo "inputs file not found: $sm_inputs" >&2
  exit 1
}

die() {
  echo "SMOKE FAIL: $*" >&2
  exit 1
}
source script/shared/chain-read.sh
nonzero_addr() {
  is_addr "$1" && [[ "$(lc "$1")" != "0x0000000000000000000000000000000000000000" ]]
}

# exact big-int (wei exceeds bash 64-bit)
ge() {
  [[ "$(echo "$1 >= $2" | bc)" == "1" ]]
}

# Must-succeed read: dies with context (the tolerant reads below use inline `|| true`).
rdcall() {
  local out
  out="$(cast call "$@" --rpc-url "$L2_RPC_URL" 2>/dev/null)" || die "cast call failed: $*"
  parse_num "$out"
}

# ── Resolve constants (no new hardcodes — single source verify-constants-sync/state-mate guard) ──
EXPECTED_CHAIN_ID="$(yq1 "$sm_inputs" l2ChainId)"
WETH="$(yq1 "$sm_inputs" l2Weth)"
WSTETH="$(yq1 "$sm_inputs" l2Wsteth)"
OLD_POOL="$(yq1 "$sm_inputs" RETIRED_l2OraclePool)"
# CustomSender is a pre-existing external in .inputs; env (printed by deploy-test) wins.
SENDER="${L2_CUSTOM_SENDER:-$(yq1 "$sm_inputs" l2CustomSender)}"
# New pool: env (printed by deploy-test) wins; else the freshly-generated .deployed.yaml anchor.
POOL="${L2_ORACLE_POOL:-$([[ -f "$sm_deployed" ]] && yq1 "$sm_deployed" l2OraclePool || true)}"

: "${L2_SMOKE_PRIVATE_KEY:?required — the canary signer key (needs native ETH for the dust stake + gas; wstETH only if SMOKE_SEED_WSTETH>0)}"
SIGNER="$(cast wallet address --private-key "$L2_SMOKE_PRIVATE_KEY" 2>/dev/null | tr -d '\r\n')" || die "invalid L2_SMOKE_PRIVATE_KEY"

STAKE_TOKEN="${SMOKE_STAKE_TOKEN:-native}"
DUST="${SMOKE_STAKE_AMOUNT:-1000000000000000}" # 1e15 = 0.001
SEED="${SMOKE_SEED_WSTETH:-0}"                 # 0 = stake-only (pool already funded); set >0 to seed first
MIN_OUT="${SMOKE_MIN_OUT:-0}"
GAS_BUFFER="${SMOKE_GAS_BUFFER:-1000000000000000}" # 1e15 = 0.001, native ETH gas headroom
for v in DUST SEED MIN_OUT GAS_BUFFER; do
  is_uint "${!v}" || die "$v must be a wei integer, got '${!v}'"
done
[[ "$DUST" != "0" ]] || die "SMOKE_STAKE_AMOUNT must be > 0 (fastStake reverts on zero)"
[[ "$STAKE_TOKEN" == native || "$STAKE_TOKEN" == weth ]] || die "SMOKE_STAKE_TOKEN must be native|weth, got '$STAKE_TOKEN'"

if [[ "${SMOKE_CONFIRM:-}" == "yes" ]]; then
  MODE="EXECUTE (moves real funds)"
else
  MODE="DRY RUN (set SMOKE_CONFIRM=yes to execute)"
fi
echo "===================================================================="
echo "SMOKE-STAKE (live canary): $L2_NETWORK    [$MODE]"
echo "  RPC URL:        $L2_RPC_URL"
echo "  Signer:         $SIGNER"
echo "  New OraclePool: $POOL"
echo "  CustomSender:   $SENDER"
echo "  WETH:           $WETH"
echo "  wstETH:         $WSTETH"
if [[ "$SEED" == "0" ]]; then
  echo "  Seed wstETH:    0 (STAKE-ONLY — pool must already hold liquidity)"
else
  echo "  Seed wstETH:    $SEED wei (~ $(cast from-wei "$SEED") wstETH)"
fi
echo "  Dust stake:     $DUST wei (~ $(cast from-wei "$DUST") ETH) via $STAKE_TOKEN"
echo "  Min amount out: $MIN_OUT wei"
echo "===================================================================="

nonzero_addr "$POOL" || die "new OraclePool unresolved — set L2_ORACLE_POOL or populate l2OraclePool in $sm_deployed (got '$POOL')"
nonzero_addr "$SENDER" || die "CustomSender unresolved — set L2_CUSTOM_SENDER or populate l2CustomSender in $sm_inputs (got '$SENDER')"
is_addr "$WETH" || die "l2Weth unresolved from $sm_inputs"
is_addr "$WSTETH" || die "l2Wsteth unresolved from $sm_inputs"
is_uint "$EXPECTED_CHAIN_ID" || die "l2ChainId unresolved from $sm_inputs"

# ── [1/4] Live, not a stale fork ──
echo "[1/4] CHECK chain-id + head freshness (live, not a stale fork)"
actual_chain_id="$(parse_num "$(cast chain-id --rpc-url "$L2_RPC_URL")")"
[[ "$actual_chain_id" == "$EXPECTED_CHAIN_ID" ]] || die "chain-id mismatch: got $actual_chain_id, expected $EXPECTED_CHAIN_ID for $L2_NETWORK"
head_ts="$(parse_num "$(cast block latest --field timestamp --rpc-url "$L2_RPC_URL")")"
head_age=$(($(date +%s) - head_ts))
((head_age <= 600)) || die "RPC head block is ${head_age}s old — looks like a stale fork or lagging node, not live $L2_NETWORK (check \$${_rpc_var})"
echo "      PASS chain-id=$actual_chain_id (head ${head_age}s old)"

# ── [2/4] Migration done: sender points at the NEW pool ──
echo "[2/4] CHECK CustomSender.getOraclePool() == new pool (activate done)"
live_pool="$(parse_num "$(cast call "$SENDER" 'getOraclePool()(address)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
is_addr "$live_pool" || die "CustomSender.getOraclePool() unreadable at $SENDER (wrong sender address / RPC?)"
if ! eqa "$live_pool" "$POOL"; then
  if is_addr "$OLD_POOL" && eqa "$live_pool" "$OLD_POOL"; then
    die "CustomSender still points at the OLD pool ($live_pool) — run activate first (fastStake would hit the old pool)"
  fi
  die "CustomSender.getOraclePool()=$live_pool != target new pool $POOL — refusing (would seed one pool, stake into another)"
fi
echo "      PASS sender -> new pool $POOL"

# ── [3/4] Pool sanity ──
echo "[3/4] CHECK new pool immutables + not paused"
p_in="$(parse_num "$(cast call "$POOL" 'TOKEN_IN()(address)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
p_out="$(parse_num "$(cast call "$POOL" 'TOKEN_OUT()(address)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
p_sender="$(parse_num "$(cast call "$POOL" 'SENDER()(address)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
p_paused="$(parse_num "$(cast call "$POOL" 'paused()(bool)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
p_fee="$(parse_num "$(cast call "$POOL" 'getFee()(uint96)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
is_uint "$p_fee" || p_fee=0
eqa "$p_in" "$WETH" || die "pool.TOKEN_IN()=$p_in != l2Weth $WETH"
eqa "$p_out" "$WSTETH" || die "pool.TOKEN_OUT()=$p_out != l2Wsteth $WSTETH"
eqa "$p_sender" "$SENDER" || die "pool.SENDER()=$p_sender != $SENDER"
[[ "$p_paused" == "false" ]] || die "pool is paused (paused()=$p_paused) — swap is whenNotPaused; unpause before the canary"
echo "      PASS TOKEN_IN=WETH, TOKEN_OUT=wstETH, SENDER ok, paused=false, fee=$p_fee (PRECISION 1e18)"

# Snapshot pool balances; stake-only mode needs the existing wstETH reserve.
pool_wst0="$(rdcall "$WSTETH" 'balanceOf(address)(uint256)' "$POOL")"
pool_weth0="$(rdcall "$WETH" 'balanceOf(address)(uint256)' "$POOL")"

# ── [4/4] Signer funded + seed (or existing pool reserve) covers the expected output ──
echo "[4/4] CHECK signer balances + expected output"
sig_wst="$(rdcall "$WSTETH" 'balanceOf(address)(uint256)' "$SIGNER")"
sig_eth="$(parse_num "$(cast balance "$SIGNER" --rpc-url "$L2_RPC_URL" 2>/dev/null || echo 0)")"
is_uint "$sig_eth" || sig_eth=0
# expected fastStake output (matches OraclePool.swap, integer math): (dust - dust*fee/1e18) * 1e18 / price
oracle="$(parse_num "$(cast call "$POOL" 'getOracle()(address)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
price=""
expected_out=""
if is_addr "$oracle"; then
  price="$(parse_num "$(cast call "$oracle" 'getLatestAnswer()(uint256)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
  if is_uint "$price" && [[ "$price" != "0" ]]; then
    expected_out="$(echo "( $DUST - $DUST * $p_fee / 1000000000000000000 ) * 1000000000000000000 / $price" | bc)"
  fi
fi
echo "      INFO signer wstETH=$sig_wst wei (~ $(cast from-wei "$sig_wst")); native ETH=$sig_eth wei (~ $(cast from-wei "$sig_eth"))"
if [[ -n "$expected_out" ]]; then
  echo "      INFO oracle=$oracle price=$price -> expected out ~ $expected_out wei (~ $(cast from-wei "$expected_out") wstETH)"
else
  echo "      WARN oracle price unreadable; expected-output check skipped (verification still uses the measured delta)"
fi
if [[ "$SEED" == "0" ]]; then
  # Without a seed, require a readable price and enough existing pool liquidity.
  [[ -n "$expected_out" ]] || die "stake-only mode (SMOKE_SEED_WSTETH=0) needs a readable oracle price to size the expected output — aborting"
  echo "      INFO pool wstETH reserve=$pool_wst0 wei (~ $(cast from-wei "$pool_wst0")) [stake-only: no seed]"
  ge "$pool_wst0" "$expected_out" || die "pool wstETH reserve $pool_wst0 < expected output $expected_out — swap would revert OraclePoolInsufficientTokenOut; seed the pool (SMOKE_SEED_WSTETH>0) or lower SMOKE_STAKE_AMOUNT"
else
  ge "$sig_wst" "$SEED" || die "signer wstETH $sig_wst < seed $SEED — acquire a little wstETH on $L2_NETWORK first (or SMOKE_SEED_WSTETH=0 to stake against existing pool liquidity)"
  if [[ -n "$expected_out" ]]; then
    ge "$SEED" "$expected_out" || die "seed $SEED < expected output $expected_out — raise SMOKE_SEED_WSTETH (swap would revert OraclePoolInsufficientTokenOut)"
  fi
fi
if [[ "$STAKE_TOKEN" == native ]]; then
  ge "$sig_eth" "$(echo "$DUST + $GAS_BUFFER" | bc)" || die "signer native ETH $sig_eth < dust $DUST + gas buffer $GAS_BUFFER — top up (or lower SMOKE_GAS_BUFFER)"
else
  ge "$sig_eth" "$GAS_BUFFER" || die "signer native ETH $sig_eth < gas buffer $GAS_BUFFER — top up for gas"
  sig_weth="$(rdcall "$WETH" 'balanceOf(address)(uint256)' "$SIGNER")"
  ge "$sig_weth" "$DUST" || die "SMOKE_STAKE_TOKEN=weth but signer WETH $sig_weth < dust $DUST — wrap some ETH->WETH or use native"
  echo "      INFO signer WETH=$sig_weth wei (~ $(cast from-wei "$sig_weth"))"
fi
if [[ "$SEED" == "0" ]]; then
  echo "      PASS signer funded (dust + gas) + pool reserve covers the output"
else
  echo "      PASS signer funded (seed + dust + gas covered)"
fi

if [[ "${SMOKE_CONFIRM:-}" != "yes" ]]; then
  echo "===================================================================="
  echo "DRY RUN OK — all preconditions passed; no funds moved."
  echo "  Re-run to EXECUTE:  SMOKE_CONFIRM=yes just -E .env.$L2_NETWORK smoke-stake"
  if [[ "$SEED" == "0" ]]; then
    echo "  Would (1) skip the seed (stake-only — pool reserve $pool_wst0 wei wstETH covers the output)"
  else
    echo "  Would (1) transfer $SEED wei wstETH -> pool $POOL"
  fi
  echo "        (2) fastStake $DUST wei via $STAKE_TOKEN, expecting ~ ${expected_out:-?} wei wstETH to $SIGNER"
  echo "===================================================================="
  exit 0
fi

# ── EXECUTE (SMOKE_CONFIRM=yes) ──
echo "EXECUTE — moving funds"
SEND=(cast send --rpc-url "$L2_RPC_URL" --private-key "$L2_SMOKE_PRIVATE_KEY" --json)

if [[ "$SEED" == "0" ]]; then
  seed_tx="(skipped)"
  pool_wst1="$pool_wst0"
  echo "  -> seed: skipped (SMOKE_SEED_WSTETH=0 — staking against existing pool reserve $pool_wst0 wei)"
else
  echo "  -> seed: wstETH.transfer($POOL, $SEED)"
  seed_rcpt="$("${SEND[@]}" "$WSTETH" 'transfer(address,uint256)' "$POOL" "$SEED")" || die "seed transfer failed"
  seed_tx="$(printf '%s' "$seed_rcpt" | jq -r '.transactionHash')"
  [[ "$(printf '%s' "$seed_rcpt" | jq -r '.status')" == "0x1" ]] || die "seed tx reverted ($seed_tx)"
  pool_wst1="$(rdcall "$WSTETH" 'balanceOf(address)(uint256)' "$POOL")"
  [[ "$pool_wst1" == "$(echo "$pool_wst0 + $SEED" | bc)" ]] || die "pool wstETH after seed = $pool_wst1, expected $(echo "$pool_wst0 + $SEED" | bc) (tx $seed_tx)"
  echo "     seeded: tx=$seed_tx ; pool wstETH $pool_wst0 -> $pool_wst1"
fi

# Window start: staker wstETH immediately before the stake tx (= after seed).
staker_before="$(rdcall "$WSTETH" 'balanceOf(address)(uint256)' "$SIGNER")"

echo "  -> stake: CustomSender.fastStake($STAKE_TOKEN, $DUST, $MIN_OUT)"
if [[ "$STAKE_TOKEN" == native ]]; then
  stake_rcpt="$("${SEND[@]}" --value "$DUST" "$SENDER" 'fastStake(address,uint256,uint256)' '0x0000000000000000000000000000000000000000' "$DUST" "$MIN_OUT")" || die "fastStake (native) failed"
else
  echo "     approve: WETH.approve($SENDER, $DUST)"
  ap_rcpt="$("${SEND[@]}" "$WETH" 'approve(address,uint256)' "$SENDER" "$DUST")" || die "WETH approve failed"
  [[ "$(printf '%s' "$ap_rcpt" | jq -r '.status')" == "0x1" ]] || die "approve reverted"
  stake_rcpt="$("${SEND[@]}" "$SENDER" 'fastStake(address,uint256,uint256)' "$WETH" "$DUST" "$MIN_OUT")" || die "fastStake (weth) failed"
fi
stake_tx="$(printf '%s' "$stake_rcpt" | jq -r '.transactionHash')"
[[ "$(printf '%s' "$stake_rcpt" | jq -r '.status')" == "0x1" ]] || die "fastStake tx reverted ($stake_tx)"

# ── Verify by observation ──
staker_after="$(rdcall "$WSTETH" 'balanceOf(address)(uint256)' "$SIGNER")"
pool_wst2="$(rdcall "$WSTETH" 'balanceOf(address)(uint256)' "$POOL")"
pool_weth2="$(rdcall "$WETH" 'balanceOf(address)(uint256)' "$POOL")"
delta="$(echo "$staker_after - $staker_before" | bc)"

# Corroborate against the FastStake event amountOut (2nd data word); not load-bearing.
ft_topic="$(cast keccak 'FastStake(address,address,uint256,uint256)')"
ev_data="$(printf '%s' "$stake_rcpt" | jq -r --arg t "$(lc "$ft_topic")" --arg a "$(lc "$SENDER")" 'first(.logs[] | select((.address|ascii_downcase)==$a and (.topics[0]|ascii_downcase)==$t) | .data) // empty' 2>/dev/null || true)"
ev_out=""
if [[ "$ev_data" =~ ^0x[0-9a-fA-F]+$ ]]; then
  d="${ev_data#0x}"
  [[ ${#d} -ge 128 ]] && ev_out="$(cast to-dec "0x${d:64:64}")"
fi

echo "     delta(staker wstETH) = $delta wei (~ $(cast from-wei "$delta"))   [tx $stake_tx]"
[[ "$(echo "$delta > 0" | bc)" == "1" ]] || die "staker wstETH delta = $delta (expected > 0) — fastStake delivered nothing"
if [[ -n "$ev_out" ]]; then
  [[ "$ev_out" == "$delta" ]] || die "FastStake.amountOut=$ev_out != measured staker delta=$delta"
  echo "     OK FastStake.amountOut == measured delta = $delta"
else
  echo "     WARN could not decode FastStake event amountOut; relying on the measured balance delta"
fi
want_wst="$(echo "$pool_wst1 - $delta" | bc)"
want_weth="$(echo "$pool_weth0 + $DUST" | bc)"
[[ "$pool_wst2" == "$want_wst" ]] || die "pool wstETH after = $pool_wst2, expected $want_wst (before+seed-out)"
[[ "$pool_weth2" == "$want_weth" ]] || die "pool WETH after = $pool_weth2, expected $want_weth (before+dust)"

echo "===================================================================="
echo "OK SMOKE-STAKE PASSED — $L2_NETWORK"
echo "  staker $SIGNER received $delta wei wstETH (~ $(cast from-wei "$delta"))"
if [[ "$SEED" == "0" ]]; then
  echo "  seed tx:     (skipped — stake-only against existing pool reserve)"
else
  echo "  seed tx:     $seed_tx   (+$SEED wei wstETH -> pool)"
fi
echo "  stake tx:    $stake_tx   ($DUST wei $STAKE_TOKEN -> fastStake)"
if [[ "$SEED" == "0" ]]; then
  echo "  pool wstETH: $pool_wst0 -> $pool_wst2 (after stake)"
else
  echo "  pool wstETH: $pool_wst0 -> $pool_wst1 (seed) -> $pool_wst2 (after stake)"
fi
echo "  pool WETH:   $pool_weth0 -> $pool_weth2 (+$DUST)"
[[ -n "$price" ]] && echo "  oracle price: $price (expected out ~ ${expected_out:-?} wei)"
echo "===================================================================="
