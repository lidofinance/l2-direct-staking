#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source script/shared/cre-env.sh
source script/shared/chain-read.sh
: "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
# L2 RPC comes from L2_RPC_URL, defined by the selected .env.<network> overlay.
: "${L2_RPC_URL:?Set L2_RPC_URL in .env.$L2_NETWORK}"

# Read the same lane identities used by state validation; do not maintain address copies here.
EXPECTED_CHAIN_ID="$(just _l2-input-anchor "$L2_NETWORK" l2ChainId)"
SENDER="$(just _l2-input-anchor "$L2_NETWORK" l2CustomSender)"
WETH="$(just _l2-input-anchor "$L2_NETWORK" l2Weth)"
WSTETH="$(just _l2-input-anchor "$L2_NETWORK" l2Wsteth)"
POOL="$(yq1 "config/state/$L2_NETWORK.deployed.yaml" l2OraclePool)"
for address in "$SENDER" "$WETH" "$WSTETH" "$POOL"; do
  if ! is_addr "$address" || [[ "$address" == 0x0000000000000000000000000000000000000000 ]]; then
    echo "Missing or invalid configured address for $L2_NETWORK: $address" >&2
    exit 1
  fi
done

# Disable colors in pipes and when NO_COLOR is set.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\033[0m'
  C_HDR=$'\033[1;36m'
  C_STEP=$'\033[1m'
  C_PASS=$'\033[1;32m'
  C_WARN=$'\033[1;33m'
  C_FAIL=$'\033[1;31m'
  C_INFO=$'\033[36m'
  C_DIM=$'\033[2m'
else
  C_RST=''
  C_HDR=''
  C_STEP=''
  C_PASS=''
  C_WARN=''
  C_FAIL=''
  C_INFO=''
  C_DIM=''
fi
# Use x=$((x+1)): ((x++)) returns failure at zero under set -e.
PASS_N=0
WARN_N=0
hdr() {
  printf '%s%s%s\n' "$C_HDR" "$*" "$C_RST"
}

step() {
  printf '%s%s%s\n' "$C_STEP" "$*" "$C_RST"
}

pass() {
  PASS_N=$((PASS_N + 1))
  printf '      %sPASS%s %s\n' "$C_PASS" "$C_RST" "$*"
} # green keyword
warn() {
  WARN_N=$((WARN_N + 1))
  printf '      %sWARN%s %s\n' "$C_WARN" "$C_RST" "$*"
} # yellow keyword
info() {
  printf '      %sINFO%s %s\n' "$C_INFO" "$C_RST" "$*"
}

cmd() {
  printf '      %scmd:%s %s\n' "$C_DIM" "$C_RST" "$*"
}

cont() {
  printf '           %s\n' "$*"
}

die() {
  printf '%sPREFLIGHT FAIL:%s %s\n' "$C_FAIL" "$C_RST" "$*" >&2
  exit 1
}

# Strip cast's "[1.234e9]" scientific-notation suffix and any whitespace.
parse_cast_num() {
  local s="$1"
  s="${s%%[*}"
  s="${s%% *}"
  printf '%s' "$s"
}

has_code() {
  local code
  code=$(cast code "$1" --rpc-url "$L2_RPC_URL" 2>/dev/null || echo "0x")
  [[ "$code" != "0x" && -n "$code" ]]
}

hdr "===================================================================="
hdr "L2 PREFLIGHT CHECK: $L2_NETWORK"
echo "  RPC URL:            $(cre_env_host "$L2_RPC_URL")"
echo "  Expected chain-id:  $EXPECTED_CHAIN_ID"
echo "  CustomSender:       $SENDER"
echo "  OraclePool:         $POOL"
echo "  Pool WETH:          $WETH"
echo "  Pool wstETH:        $WSTETH"
hdr "===================================================================="

step "[1/5] CHECK chain-id of RPC matches expected ($EXPECTED_CHAIN_ID)"
cmd "cast chain-id --rpc-url <rpc>"
actual_chain_id=$(cast chain-id --rpc-url "$L2_RPC_URL")
if [[ "$actual_chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
  die "chain-id mismatch: got $actual_chain_id, expected $EXPECTED_CHAIN_ID for $L2_NETWORK"
fi
# Forks retain the chain ID. Reject stale heads to catch old forks or lagging RPCs.
head_ts=$(parse_cast_num "$(cast block latest --field timestamp --rpc-url "$L2_RPC_URL")")
head_age=$(($(date +%s) - head_ts))
if ((head_age > 600)); then
  die "RPC head block is ${head_age}s old — looks like a stale fork or lagging node, not live $L2_NETWORK (check \$L2_RPC_URL)"
fi
pass "chain-id = $actual_chain_id (head block ${head_age}s old)"

step "[2/5] CHECK CustomSender contract has bytecode at $SENDER"
cmd "cast code $SENDER --rpc-url <rpc>"
if ! has_code "$SENDER"; then
  die "CustomSender $SENDER has no code on this RPC"
fi
pass "bytecode present at CustomSender"

step "[3/5] CHECK active oracle pool wiring and token balances (WETH + wstETH)"
active_pool="$(cast call "$SENDER" 'getOraclePool()(address)' --rpc-url "$L2_RPC_URL")"
if ! eqa "$active_pool" "$POOL"; then
  die "CustomSender pool $active_pool does not match configured pool $POOL"
fi
if ! has_code "$POOL"; then
  die "no contract bytecode at configured pool $POOL"
else
  report_balance() {
    local label="$1" token="$2"
    cmd "cast call $token 'balanceOf(address)(uint256)' $POOL --rpc-url <rpc>  # $label"
    if raw=$(cast call "$token" "balanceOf(address)(uint256)" "$POOL" --rpc-url "$L2_RPC_URL" 2>/dev/null); then
      local wei ether
      wei=$(parse_cast_num "$raw")
      ether=$(cast from-wei "$wei" 2>/dev/null || echo "?")
      info "pool $label balance = $wei wei (~ $ether $label)"
    else
      warn "could not read $label balance for $POOL (token=$token may be wrong on this RPC)"
    fi
  }
  report_balance WETH "$WETH"
  report_balance wstETH "$WSTETH"
fi

step "[4/5] CHECK CustomSender 'Sync' events in last ~12h (catches every sync path)"
# topic0 of ICustomSender.Sync(address,uint64,bytes32,uint256); see lib/chainlink-csr/selectors.txt
SYNC_TOPIC=0x2826f7440c9ba1050bcd2c586a60551875ac8951ec73f01df55ef00b59ae1a9c
latest_block=$(cast block-number --rpc-url "$L2_RPC_URL" | tr -d '\r\n')
older_block=$((latest_block - 1000))
latest_ts=$(parse_cast_num "$(cast block "$latest_block" --rpc-url "$L2_RPC_URL" --field timestamp 2>/dev/null || true)")
older_ts=$(parse_cast_num "$(cast block "$older_block" --rpc-url "$L2_RPC_URL" --field timestamp 2>/dev/null || true)")
if [[ -n "$latest_ts" && -n "$older_ts" && "$latest_ts" -gt "$older_ts" ]]; then
  # Compute 12h-window blocks directly to avoid integer division zeroing out
  # for sub-second block times (Arbitrum: ~0.25s, Optimism: 2s, Linea: variable).
  ts_per_1000=$((latest_ts - older_ts))
  ((ts_per_1000 > 0)) || ts_per_1000=2000
  twelve_h_blocks=$((12 * 3600 * 1000 / ts_per_1000))
  from_block=$((latest_block - twelve_h_blocks))
  cmd "cast logs --json --from-block $from_block --to-block latest --address $SENDER '$SYNC_TOPIC' --rpc-url <rpc>"
  if logs_json=$(cast logs --json --from-block "$from_block" --to-block latest \
    --address "$SENDER" "$SYNC_TOPIC" \
    --rpc-url "$L2_RPC_URL" 2>&1); then
    count=$(printf '%s' "$logs_json" | jq 'length' 2>/dev/null || echo 0)
    if [[ "${count:-0}" -eq 0 ]]; then
      pass "0 Sync events on $SENDER in last ~12h ($twelve_h_blocks blocks scanned; 1000-block probe spanned ${ts_per_1000}s)"
    else
      warn "$count Sync event(s) on $SENDER in last ~12h — a CCIP message may still be in flight."
      last_block_hex=$(printf '%s' "$logs_json" | jq -r '.[-1].blockNumber' 2>/dev/null)
      if [[ -n "$last_block_hex" && "$last_block_hex" != "null" ]]; then
        last_block_dec=$(cast --to-dec "$last_block_hex" 2>/dev/null || echo "$last_block_hex")
        cont "most recent at block $last_block_dec; check https://ccip.chain.link/ for pending."
      fi
      cont "Track each message to its recorded return recipient; a recent Sync alone does not establish pending funds."
    fi
  else
    warn "could not scan Sync events (RPC error or range too wide):"
    cont "$(printf '%s\n' "$logs_json" | head -n1)"
    cont "Inspect manually on the L2 block explorer:"
    cont "filter address=$SENDER topic0=$SYNC_TOPIC over the last ~$twelve_h_blocks blocks."
  fi
else
  warn "could not derive 12h-ago block estimate (timestamp probe failed); skipping Sync event scan."
fi

step "[5/5] CHECK configured maxGasLimit ceiling vs live CCIP maxPerMsgGasLimit"
# Read the 1-based ABI word at the offset verified for this CCIP version.
# These config structs are static: each field occupies one 32-byte word.
abi_word_dec() {
  local raw="${1#0x}" n="$2" w
  w="${raw:$(((n - 1) * 64)):64}"
  if [[ "$w" =~ ^[0-9a-fA-F]{64}$ ]]; then
    cast --to-dec "0x$w" 2>/dev/null || true
  fi
}
# Source the lane-specific cap and shared destination selector from their state-mate inputs.
sm_inputs="config/state/${L2_NETWORK}.inputs.yaml"
EXPECTED=$(awk '$2=="&maxGasLimit"{print $3; exit}' "$sm_inputs" 2>/dev/null)
# getOnRamp targets Ethereum; use its shared selector if the anchor read fails.
DEST_SEL=$(just _l2-input-anchor "$L2_NETWORK" ethMainnetCcipChainSelector 2>/dev/null || true)
: "${DEST_SEL:=5009297550715157269}"
if [[ -z "${EXPECTED:-}" || ! "$EXPECTED" =~ ^[0-9]+$ ]]; then
  warn "could not read &maxGasLimit from $sm_inputs; skipping live-cap check"
else
  ROUTER=$(cast call "$SENDER" 'CCIP_ROUTER()(address)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
  ONRAMP=$(cast call "$ROUTER" 'getOnRamp(uint64)(address)' "$DEST_SEL" --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
  if [[ -z "$ROUTER" ]]; then
    warn "CustomSender.CCIP_ROUTER() did not respond; skipping live-cap check"
  elif [[ -z "$ONRAMP" || "$ONRAMP" == "0x0000000000000000000000000000000000000000" ]]; then
    warn "Router.getOnRamp($DEST_SEL) = ${ONRAMP:-<none>} — lane not provisioned on this RPC; skipping cap check"
  else
    # Select the cap contract and word offset by typeAndVersion.
    # Track known versions to distinguish decode failures from unsupported layouts.
    TV=$(cast call "$ONRAMP" 'typeAndVersion()(string)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
    TV="${TV%\"}"
    TV="${TV#\"}" # strip cast's surrounding quotes, if any
    LIVE_CAP=""
    version_known=
    case "$TV" in
      "EVM2EVMOnRamp 1.5.0")
        # v1.5 (Optimism, Linea): maxPerMsgGasLimit is word 10 of the OnRamp DynamicConfig.
        version_known=1
        raw=$(cast call "$ONRAMP" 'getDynamicConfig()' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
        LIVE_CAP=$(abi_word_dec "$raw" 10)
        ;;
      OnRamp*)
        # OnRamp word 1 holds FeeQuoter; its cap offset depends on the FeeQuoter version.
        dyn=$(cast call "$ONRAMP" 'getDynamicConfig()' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
        dyn=${dyn#0x}
        FQ="0x${dyn:24:40}"
        FQV=$(cast call "$FQ" 'typeAndVersion()(string)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
        FQV="${FQV%\"}"
        FQV="${FQV#\"}"
        raw=$(cast call "$FQ" 'getDestChainConfig(uint64)' "$DEST_SEL" --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
        case "$FQV" in
          "FeeQuoter 2.0.0")
            version_known=1
            LIVE_CAP=$(abi_word_dec "$raw" 3)
            ;; # isEnabled, maxDataBytes, maxPerMsgGasLimit, ...
          "FeeQuoter 1.6.0"*)
            version_known=1
            LIVE_CAP=$(abi_word_dec "$raw" 4)
            ;; # isEnabled, maxNumTokens, maxDataBytes, maxPerMsgGasLimit
          *) warn "unrecognized FeeQuoter version '$FQV' at $FQ; cap field offset unknown — skipping (CCIP layout may have changed)" ;;
        esac
        ;;
      *)
        warn "unrecognized onRamp typeAndVersion '$TV' at $ONRAMP; cap check skipped (CCIP layout may have changed — re-verify the read path)"
        ;;
    esac
    if [[ -n "$LIVE_CAP" && "$LIVE_CAP" =~ ^[0-9]+$ ]]; then
      info "onRamp $ONRAMP ($TV); live maxPerMsgGasLimit = $LIVE_CAP, configured ceiling = $EXPECTED"
      if ((EXPECTED > LIVE_CAP)); then
        die "configured maxGasLimit ceiling $EXPECTED exceeds live CCIP cap $LIVE_CAP on $L2_NETWORK ($TV) — an over-cap feeOtoD would pass setFeeOtoD then revert MessageGasLimitTooHigh inside every sync"
      elif ((EXPECTED == LIVE_CAP)); then
        pass "ceiling == live CCIP cap = $LIVE_CAP"
      else
        warn "ceiling $EXPECTED is below live CCIP cap $LIVE_CAP (tighter than CCIP; OK, but widen if the headroom isn't intentional)"
      fi
    elif [[ -n "$version_known" ]]; then
      warn "could not decode live maxPerMsgGasLimit from $ONRAMP ($TV); skipping cap comparison"
    fi
  fi
fi

hdr "===================================================================="
# Fatal checks exit through die. Advisory warnings leave the gate successful.
if ((WARN_N > 0)); then
  printf '%sOK%s L2 preflight passed for %s — %s%d PASS%s, %s%d WARN%s (review the warnings above before proceeding).\n' \
    "$C_PASS" "$C_RST" "$L2_NETWORK" "$C_PASS" "$PASS_N" "$C_RST" "$C_WARN" "$WARN_N" "$C_RST"
else
  printf '%sOK%s L2 preflight passed for %s — %s%d PASS, 0 WARN%s. Review live state before changing configuration.\n' \
    "$C_PASS" "$C_RST" "$L2_NETWORK" "$C_PASS" "$PASS_N" "$C_RST"
fi
hdr "===================================================================="
