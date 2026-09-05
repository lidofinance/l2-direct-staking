#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
for c in yq cast jq; do
  command -v "$c" >/dev/null 2>&1 || {
    echo "$c is required" >&2
    exit 1
  }
done
WINDOW_H="${MONITOR_WINDOW_HOURS:-24}"

# ── Protocol-universal constants (same values state-mate pins inline; not lane-specific) ──
DEFAULT_ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"
SYNC_ROLE="0xbb1ef2b79fa8154a13ffa50bd30e5f91ed93ff9b924bd04be671240cbc9d4b71"
TRIGGER_SYNC_SEL="0x340b2b0b" # SyncTrigger.triggerSync()
EIP1967_ADMIN_SLOT="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
# Event topic0s — canonical signatures verified against the compiled ABIs (out/*.json).
T_SYNC="0x2826f7440c9ba1050bcd2c586a60551875ac8951ec73f01df55ef00b59ae1a9c"     # CustomSender.Sync(address,uint64,bytes32,uint256)
T_CALLEXEC="0xbe82131bb3404498c769b0511da41a4ad409fa7152562c2b6669241cbe3bb884" # CREReceiver.CallExecuted(address,bytes4,bytes)
T_MSG_OK="0xdf6958669026659bac75ba986685e11a7d271284989f565f2802522663e9a70f"   # LidoCustomReceiver.MessageSucceeded(bytes32)
T_MSG_FAIL="0xef8a84d7e9c9d42c79a42cba16e93688c646989f43846843e163672cc887e253" # LidoCustomReceiver.MessageFailed(bytes32,(bytes32,uint64,bytes,bytes,(address,uint256)[]))
# Canonical mainnet stETH; the receiver holds it transiently while staking.
L1_STETH="0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84"
TRAP_ALERT_WEI="1000000000000000000" # §2: alert if a balance > 1 ETH(-equiv)

rc=0
source script/shared/chain-read.sh
# a>=b (awk doubles — heuristic at wei scale)
ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'
}

lt() {
  awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0< b+0)}'
}

# Disable colors in pipes and when NO_COLOR is set.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RST=$'\033[0m'
  C_OK=$'\033[1;32m'
  C_INFO=$'\033[2m'
  C_WARN=$'\033[1;33m'
  C_ALERT=$'\033[1;31m'
  C_SKIP=$'\033[36m'
  C_HDR=$'\033[1;36m'
else
  C_RST=''
  C_OK=''
  C_INFO=''
  C_WARN=''
  C_ALERT=''
  C_SKIP=''
  C_HDR=''
fi
hdr() {
  printf '%s%s%s\n' "$C_HDR" "$*" "$C_RST"
}

OK() {
  printf '    %sOK%s    %s\n' "$C_OK" "$C_RST" "$1"
}

INFO() {
  printf '    %sinfo%s  %s\n' "$C_INFO" "$C_RST" "$1"
}

WARN() {
  printf '    %sWARN%s  %s\n' "$C_WARN" "$C_RST" "$1"
  rc=1
}
ALERT() {
  printf '    %sALERT%s %s\n' "$C_ALERT" "$C_RST" "$1"
  rc=1
}
SKIP() {
  printf '    %sSKIP%s  %s\n' "$C_SKIP" "$C_RST" "$1"
  rc=1
}
# ck_addr label got want friendly: warn on unreadable, alert on mismatch.
ck_addr() {
  if ! is_addr "$2"; then
    WARN "$1 unreadable"
  elif eqa "$2" "$3"; then
    OK "$1 = $4 ($3)"
  else
    ALERT "$1 = $2 (expected $4 $3)"
  fi
}

# ck_trap label wei: warn on unreadable, alert at the trapped-funds threshold.
ck_trap() {
  if ! is_uint "$2"; then
    WARN "$1 balance unreadable"
  elif ge "$2" "$TRAP_ALERT_WEI"; then
    ALERT "$1 = $(cast from-wei "$2") (>1 ETH-equiv ⇒ page)"
  else
    OK "$1 = $(cast from-wei "$2")"
  fi
}

# rd url target signature [args...]: prints the result, or empty on RPC/revert errors.
# Callers validate the result; this function runs inside command substitutions.
rd() {
  local url="$1" tgt="$2" sig="$3"
  shift 3
  local out
  out="$(cast call "$tgt" "$sig" "$@" --rpc-url "$url" 2>/dev/null)" || out=""
  parse_num "$out"
}
# from_block ~WINDOW_H hours back via a 1000-block timestamp probe (echo int, or empty on failure).
blocks_back() {
  local url="$1" lb ob nts ots span nb
  lb="$(parse_num "$(cast block-number --rpc-url "$url" 2>/dev/null)")"
  [[ "$lb" =~ ^[0-9]+$ ]] || return 1
  ob=$((lb > 1000 ? lb - 1000 : 0))
  nts="$(parse_num "$(cast block "$lb" --field timestamp --rpc-url "$url" 2>/dev/null)")"
  ots="$(parse_num "$(cast block "$ob" --field timestamp --rpc-url "$url" 2>/dev/null)")"
  [[ "$nts" =~ ^[0-9]+$ && "$ots" =~ ^[0-9]+$ && "$nts" -gt "$ots" ]] || return 1
  span=$((nts - ots))
  ((span > 0)) || span=2000
  nb=$((WINDOW_H * 3600 * 1000 / span))
  echo $((lb > nb ? lb - nb : 0))
}
# count logs of topic0 at address since from_block; echoes integer, or "?" on RPC error.
count_logs() {
  local out
  if out="$(cast logs --json --from-block "$4" --to-block latest --address "$2" "$3" --rpc-url "$1" 2>&1)"; then
    printf '%s' "$out" | jq 'length' 2>/dev/null || echo "?"
  else
    echo "?"
  fi
}

hdr "===================================================================="
hdr "POSTFLIGHT MONITOR — Lido L2 direct-staking (docs/monitoring.md subset)"
echo "  event-scan window: ${WINDOW_H}h (override: MONITOR_WINDOW_HOURS) — snapshot, not coverage"
hdr "===================================================================="

# ════════════════════════ L1 (Ethereum mainnet) ════════════════════════
echo
hdr "──────────── L1 (Ethereum mainnet) ────────────"
# Live monitor: explicit mainnet binding first, local fork proxy last (see cre-env.sh).
L1_RPC="${L1_RPC_URL:-${RPC_ETHEREUM_REMOTE:-${RPC_ETHEREUM:-}}}"
L1_IN="${ROOT_DIR}/config/state/ethereum.inputs.yaml"
if [[ -z "$L1_RPC" ]]; then
  SKIP "L1 pass — set L1_RPC_URL in .env.<network> (or RPC_ETHEREUM_REMOTE)"
elif ! chain_id=$(cast chain-id --rpc-url "$L1_RPC" 2>/dev/null); then
  SKIP "L1 pass — RPC not reachable: $L1_RPC"
elif [[ "$chain_id" != 1 ]]; then
  ALERT "L1 pass — RPC chain-id $chain_id, expected 1; skipping"
else
  # L1 receiver decoded from the bytes32 anchor in the common L2 inputs; DAO agent + wstETH
  # come from the independently verified L1 inputs (one yq pass).
  L1_RECV="$(cast parse-bytes32-address "$(just _l2-input-anchor optimism l1LidoCustomReceiverBytes32)" 2>/dev/null || true)"
  {
    IFS= read -r DAO
    IFS= read -r INIT_OWNER
    IFS= read -r L1_WSTETH
  } < <(yq \
    '[.. | select(anchor=="lidoDaoAgent")][0], [.. | select(anchor=="initialOwner")][0], [.. | select(anchor=="l1Wsteth")][0]' \
    "$L1_IN" 2>/dev/null)
  if ! is_addr "$L1_RECV"; then
    SKIP "L1 receiver address unresolved (l1LidoCustomReceiverBytes32)"
  else
    echo "  receiver = $L1_RECV"
    # §2 trapped funds — alert if any balance > 1 ETH(-equiv); the ">1h" duration is the indexer's job.
    ck_trap "§2 L1 receiver ETH" "$(parse_num "$(cast balance "$L1_RECV" --rpc-url "$L1_RPC" 2>/dev/null)")"
    for pair in "wstETH:$L1_WSTETH" "stETH:$L1_STETH"; do
      lbl="${pair%%:*}"
      tok="${pair#*:}"
      is_addr "$tok" || {
        WARN "§2 L1 receiver $lbl token address unresolved"
        continue
      }
      ck_trap "§2 L1 receiver $lbl" "$(rd "$L1_RPC" "$tok" 'balanceOf(address)(uint256)' "$L1_RECV")"
    done
    # §2 MessageFailed — best-effort scan
    fb="$(blocks_back "$L1_RPC" || true)"
    if [[ -n "$fb" ]]; then
      n="$(count_logs "$L1_RPC" "$L1_RECV" "$T_MSG_FAIL" "$fb")"
      if [[ "$n" == "?" ]]; then
        WARN "§2 MessageFailed scan failed (RPC range limit?) — check an indexer"
      elif [[ "$n" -gt 0 ]]; then
        ALERT "§2 $n MessageFailed in last ${WINDOW_H}h — PAGE (retryFailedMessage / recoverTokens)"
      else
        OK "§2 0 MessageFailed in last ${WINDOW_H}h (best-effort window)"
      fi
      ok="$(count_logs "$L1_RPC" "$L1_RECV" "$T_MSG_OK" "$fb")"
      INFO "§3 ${ok} MessageSucceeded in last ${WINDOW_H}h (pair vs L2 Sync below; 1:1 needs an indexer)"
    else
      WARN "§2/§3 L1 event scan skipped (block-window probe failed)"
    fi
    # §1 L1 access-control (ACL is non-enumerable → assert hasRole pair, not getRoleMemberCount)
    r1="$(rd "$L1_RPC" "$L1_RECV" 'hasRole(bytes32,address)(bool)' "$DEFAULT_ADMIN_ROLE" "$DAO")"
    if [[ "$r1" == "true" ]]; then
      OK "§1 L1 receiver admin = Lido DAO Agent ($DAO)"
    elif [[ "$r1" == "false" ]]; then
      ALERT "§1 L1 receiver hasRole(admin, DAO) = false (expected true)"
    else
      WARN "§1 L1 receiver hasRole unreadable"
    fi
    r2="$(rd "$L1_RPC" "$L1_RECV" 'hasRole(bytes32,address)(bool)' "$DEFAULT_ADMIN_ROLE" "$INIT_OWNER")"
    if [[ "$r2" == "false" ]]; then
      OK "§1 L1 receiver admin NOT Initial Owner (rotated)"
    elif [[ "$r2" == "true" ]]; then
      ALERT "§1 L1 receiver hasRole(admin, InitialOwner) = true (expected false)"
    else
      WARN "§1 L1 receiver init-owner hasRole unreadable"
    fi
    INFO "§1 sole-admin count (==1) needs an enumerable ACL or RoleGranted/Revoked history — indexer"
    # §1 L1 ProxyAdmin — derived from the receiver's EIP-1967 admin slot (no hardcoded address)
    pa="$(cast parse-bytes32-address "$(cast storage "$L1_RECV" "$EIP1967_ADMIN_SLOT" --rpc-url "$L1_RPC" 2>/dev/null)" 2>/dev/null || true)"
    if is_addr "$pa"; then
      ck_addr "§1 L1 ProxyAdmin ($pa) owner" "$(rd "$L1_RPC" "$pa" 'owner()(address)')" "$DAO" "Lido DAO Agent"
    else
      WARN "§1 L1 ProxyAdmin not derivable from admin slot"
    fi
  fi
  INFO "§4 CRE registry owner/status: run \`just -E .env.<net> verify-cre-workflow\` (registry owner == LOL Safe, status ACTIVE)"
fi

# ════════════════════════ L2 lanes (×4) ════════════════════════
NETS=(optimism arbitrum base linea)
for net in "${NETS[@]}"; do
  case "$net" in
    optimism) expected_chain_id=10 ;;
    arbitrum) expected_chain_id=42161 ;;
    base) expected_chain_id=8453 ;;
    linea) expected_chain_id=59144 ;;
  esac
  u="$(echo "$net" | tr '[:lower:]' '[:upper:]')"
  name="${u:0:1}${net:1}"
  rpc_env="RPC_$u"
  l2_env="L2_${u}_RPC_URL"
  echo
  hdr "──────────── ${name} ────────────"
  INF="${ROOT_DIR}/config/state/${net}.inputs.yaml"
  DEP="${ROOT_DIR}/config/state/${net}.deployed.yaml"
  [[ -f "$INF" ]] || {
    SKIP "${name} — inputs file not found: $INF"
    continue
  }
  url="${!rpc_env:-}"
  [[ -n "$url" ]] || url="${!l2_env:-}"
  if [[ -z "$url" ]]; then
    SKIP "${name} — set ${rpc_env} (or legacy ${l2_env})"
    continue
  fi
  if ! chain_id=$(cast chain-id --rpc-url "$url" 2>/dev/null); then
    SKIP "${name} — ${rpc_env} not reachable: ${url}"
    continue
  fi
  if [[ "$chain_id" != "$expected_chain_id" ]]; then
    ALERT "${name} — RPC chain-id $chain_id, expected $expected_chain_id; skipping"
    continue
  fi
  FB="$(blocks_back "$url" || true)" # one block-window probe per lane, reused by the §4 + §3 event scans

  # Read lane anchors, then shared anchors through the duplicate-checking input resolver.
  {
    IFS= read -r ROUTER
    IFS= read -r WETH
    IFS= read -r OLDPOOL
    IFS= read -r CREFWD
    IFS= read -r INP_SENDER
  } < <(yq '[.. | select(anchor=="l2CcipRouter")][0], [.. | select(anchor=="l2Weth")][0],
    [.. | select(anchor=="RETIRED_l2OraclePool")][0], [.. | select(anchor=="l2CreForwarder")][0],
    [.. | select(anchor=="l2CustomSender")][0]' "$INF" 2>/dev/null)
  LOL="$(just _l2-input-anchor "$net" l2LiquidityOwner)"
  SEL="$(just _l2-input-anchor "$net" ethMainnetCcipChainSelector)"
  SYNCMIN="$(just _l2-input-anchor "$net" syncMinAmount)"
  # Deployed addresses (only SyncTrigger is not on-chain-discoverable). Absent file ⇒ SKIP those rows.
  DEP_TRIG=""
  DEP_RECV=""
  DEP_POOL=""
  if [[ -f "$DEP" ]]; then
    {
      IFS= read -r DEP_TRIG
      IFS= read -r DEP_RECV
      IFS= read -r DEP_POOL
    } < <(yq '[.. | select(anchor=="l2SyncTrigger")][0],
      [.. | select(anchor=="l2CreReceiver")][0], [.. | select(anchor=="l2OraclePool")][0]' "$DEP" 2>/dev/null)
  fi

  # Bootstrap CustomSender LIVE from the known old pool, cross-check vs the .inputs externals anchor.
  SENDER="$(rd "$url" "$OLDPOOL" 'SENDER()(address)')"
  if ! is_addr "$SENDER"; then
    SENDER="$INP_SENDER"
  fi
  if is_addr "$SENDER"; then
    echo "  CustomSender = $SENDER"
    if is_addr "$DEP_TRIG"; then
      echo "  SyncTrigger  = $DEP_TRIG (.deployed)"
    fi
    is_addr "$INP_SENDER" && { eqa "$SENDER" "$INP_SENDER" || ALERT "§1 CustomSender live=$SENDER ≠ .inputs=$INP_SENDER (stale/contaminated file)"; }
  else
    WARN "${name} — CustomSender unresolved (oldPool.SENDER() failed, no l2CustomSender in .inputs); §1/§3/§5 limited"
  fi

  # ── §1 wiring + new pool (derived live; cross-checked vs file) ──
  POOL=""
  if is_addr "$SENDER"; then
    POOL="$(rd "$url" "$SENDER" 'getOraclePool()(address)')"
    if is_addr "$POOL"; then
      if is_addr "$DEP_POOL"; then
        eqa "$POOL" "$DEP_POOL" && OK "§1 getOraclePool live == .deployed ($POOL)" || ALERT "§1 getOraclePool live=$POOL ≠ .deployed=$DEP_POOL (contamination)"
      else
        INFO "§1 new OraclePool (live) = $POOL"
      fi
    else
      WARN "§1 CustomSender.getOraclePool() unreadable"
      POOL="$DEP_POOL"
    fi
  fi
  if is_addr "$POOL"; then
    ck_addr "§1 OraclePool owner" "$(rd "$url" "$POOL" 'owner()(address)')" "$LOL" "LOL"
    p="$(rd "$url" "$POOL" 'paused()(bool)')"
    if [[ "$p" == "false" ]]; then
      OK "§3 OraclePool not paused"
    elif [[ "$p" == "true" ]]; then
      ALERT "§3 OraclePool paused (blocks fastStake)"
    else
      WARN "§3 OraclePool paused() unreadable"
    fi
  fi

  # ── SyncTrigger-centric rows (need the deployed trigger address) ──
  if ! is_addr "$DEP_TRIG"; then
    SKIP "§1/§3/§5 SyncTrigger+CREReceiver rows — config/state/${net}.deployed.yaml absent (run after deploy-test)"
  else
    TRIG="$DEP_TRIG"
    if is_addr "$SENDER"; then
      hr="$(rd "$url" "$SENDER" 'hasRole(bytes32,address)(bool)' "$SYNC_ROLE" "$TRIG")"
      if [[ "$hr" == "true" ]]; then
        OK "§1 CustomSender SYNC_ROLE → SyncTrigger"
      elif [[ "$hr" == "false" ]]; then
        ALERT "§1 CustomSender hasRole(SYNC_ROLE, trigger) = false (expected true)"
      else
        WARN "§1 CustomSender SYNC_ROLE check unreadable"
      fi
    fi
    ck_addr "§1 SyncTrigger owner" "$(rd "$url" "$TRIG" 'owner()(address)')" "$LOL" "LOL"
    # CREReceiver derived from the trigger's forwarder (live), cross-checked vs file
    RECV="$(rd "$url" "$TRIG" 'getForwarder()(address)')"
    if is_addr "$RECV"; then
      is_addr "$DEP_RECV" && { eqa "$RECV" "$DEP_RECV" || ALERT "§1 SyncTrigger.getForwarder live=$RECV ≠ .deployed CREReceiver=$DEP_RECV"; }
    else
      RECV="$DEP_RECV"
    fi
    if is_addr "$RECV"; then
      ck_addr "§1 CREReceiver owner" "$(rd "$url" "$RECV" 'owner()(address)')" "$LOL" "LOL"
      ck_addr "§1 CREReceiver expectedAuthor" "$(rd "$url" "$RECV" 'getExpectedAuthor()(address)')" "$LOL" "LOL"
      ck_addr "§1 CREReceiver forwarder" "$(rd "$url" "$RECV" 'getForwarder()(address)')" "$CREFWD" "pinned CRE forwarder"
      ca="$(rd "$url" "$RECV" 'isCallAllowed(address,bytes4)(bool)' "$TRIG" "$TRIGGER_SYNC_SEL")"
      if [[ "$ca" == "true" ]]; then
        OK "§1 CREReceiver allows triggerSync from SyncTrigger"
      elif [[ "$ca" == "false" ]]; then
        ALERT "§1 CREReceiver isCallAllowed(trigger, triggerSync) = false (expected true)"
      else
        WARN "§1 CREReceiver isCallAllowed unreadable"
      fi
    fi

    # ── §3 liveness ──
    le="$(rd "$url" "$TRIG" 'getLastExecution()(uint48)')"
    nowts="$(parse_num "$(cast block latest --field timestamp --rpc-url "$url" 2>/dev/null)")"
    poolweth=""
    is_addr "$POOL" && poolweth="$(rd "$url" "$WETH" 'balanceOf(address)(uint256)' "$POOL")"
    if [[ "$le" =~ ^[0-9]+$ && "$nowts" =~ ^[0-9]+$ ]]; then
      age=$((nowts - le))
      ah=$((age / 3600))
      due_by_pool=0
      [[ "$poolweth" =~ ^[0-9]+$ && "$SYNCMIN" =~ ^[0-9]+$ ]] && ge "$poolweth" "$SYNCMIN" && due_by_pool=1
      if ((ah > 24)) && ((due_by_pool == 1)); then
        WARN "§3 last sync ${ah}h ago while pool WETH ≥ min — investigate stall"
      else
        OK "§3 last sync ${ah}h ago$( ((due_by_pool == 1)) && echo " (pool WETH ≥ min)" || echo " (pool below min — idle is expected)")"
      fi
    else
      WARN "§3 getLastExecution unreadable"
    fi
    [[ "$poolweth" =~ ^[0-9]+$ ]] && INFO "§3 OraclePool WETH = $(cast from-wei "$poolweth") (drains each sync)"

    should="$(rd "$url" "$TRIG" 'shouldSyncAmount()(uint256)')"
    can="$(rd "$url" "$TRIG" 'canSync()(bool)')"
    if [[ "$should" =~ ^[0-9]+$ && ("$can" == "true" || "$can" == "false") ]]; then
      if [[ "$should" != "0" && "$can" == "false" ]]; then
        ALERT "§3 due-but-blocked: shouldSyncAmount=$(cast from-wei "$should") WETH yet canSync=false — silent stall (float<getMaxFees / SYNC_ROLE revoked / pool paused)"
      elif [[ "$should" != "0" && "$can" == "true" ]]; then
        INFO "§3 due & executable (shouldSyncAmount=$(cast from-wei "$should") WETH, canSync=true) — workflow should fire"
      else
        OK "§3 idle (shouldSyncAmount=0, canSync=$can)"
      fi
    else
      WARN "§3 shouldSyncAmount/canSync unreadable"
    fi

    # ── §5 float headroom (≥2× recommended; <1× ⇒ next sync reverts) ──
    flo="$(parse_num "$(cast balance "$TRIG" --rpc-url "$url" 2>/dev/null)")"
    mf="$(rd "$url" "$TRIG" 'getMaxFees()(uint256)')"
    if [[ "$flo" =~ ^[0-9]+$ && "$mf" =~ ^[0-9]+$ && "$mf" != "0" ]]; then
      ratio="$(awk -v f="$flo" -v m="$mf" 'BEGIN{printf "%.2f", f/m}')"
      if lt "$flo" "$mf"; then
        ALERT "§5 float ${ratio}× getMaxFees (< 1× = next sync reverts, lane stalls): $(cast from-wei "$flo") / $(cast from-wei "$mf") ETH"
      elif lt "$flo" "$(awk -v m="$mf" 'BEGIN{printf "%.0f", 2*m}')"; then
        WARN "§5 float ${ratio}× getMaxFees (< 2× — top up): $(cast from-wei "$flo") / $(cast from-wei "$mf") ETH"
      else
        OK "§5 float ${ratio}× getMaxFees ($(cast from-wei "$flo") ETH)"
      fi
    else
      WARN "§5 float / getMaxFees unreadable"
    fi

    # ── §4 CallExecuted best-effort scan (the only on-chain proof the DON author-gate passes) ──
    if is_addr "$RECV"; then
      if [[ -n "$FB" ]]; then
        n="$(count_logs "$url" "$RECV" "$T_CALLEXEC" "$FB")"
        if [[ "$n" == "?" ]]; then
          WARN "§4 CallExecuted scan failed (RPC range limit?) — check an indexer"
        elif [[ "$n" -gt 0 ]]; then
          OK "§4 author gate proven ($n CallExecuted in last ${WINDOW_H}h)"
        else
          WARN "§4 0 CallExecuted in last ${WINDOW_H}h — idle OR author-gate failure (InvalidAuthor); confirm via longer history/indexer"
        fi
      else
        WARN "§4 CallExecuted scan skipped (block-window probe failed)"
      fi
    fi
  fi

  # ── §3 CCIP allow-list (router known; no trigger needed) + §3 Sync scan ──
  if is_addr "$ROUTER" && [[ "$SEL" =~ ^[0-9]+$ ]]; then
    sup="$(rd "$url" "$ROUTER" 'isChainSupported(uint64)(bool)' "$SEL")"
    if [[ "$sup" == "true" ]]; then
      OK "§3 CCIP dest-chain (Ethereum) allow-listed"
    elif [[ "$sup" == "false" ]]; then
      ALERT "§3 CCIP dest-chain de-allow-listed — every triggerSync reverts inside the router (revert-spam, not a clean stall)"
    else
      WARN "§3 Router.isChainSupported unreadable"
    fi
  fi
  if is_addr "$SENDER"; then
    if [[ -n "$FB" ]]; then
      s="$(count_logs "$url" "$SENDER" "$T_SYNC" "$FB")"
      [[ "$s" == "?" ]] && WARN "§3 Sync scan failed (RPC range limit?)" || INFO "§3 ${s} Sync events (L2) in last ${WINDOW_H}h (pair vs L1 MessageSucceeded; 1:1 needs an indexer)"
    fi
  fi
done

# ════════════════════════ NOT covered here (wire into indexer / dashboard) ════════════════════════
echo
hdr "──────────── NOT covered here — needs an indexer / dashboard ────────────"
echo "  • §1 events: RoleGranted/Revoked, OwnershipTransferred, Forwarder/ExpectedAuthor/AllowedCallUpdated, OraclePool Paused → Tenderly/Dune"
echo "  • §4 CRE credit balance (LOL Safe's CRE account) — dashboard-only, no on-chain signal → https://cre.chain.link/workflows"
echo "        on-chain proxy = the §3 liveness rows above (stale sync + healthy fees/float ⇒ suspect credit starvation)"
echo "  • §2 CCIP manual-exec queue → https://ccip.chain.link/   • §5 Arbitrum retryable redeems → https://retryable-dashboard.arbitrum.io/"
echo "  • RMN curse (no single stable view) + continuous 1:1 Sync↔MessageSucceeded pairing → indexer"
echo "  • exhaustive §1 wiring → state-mate (\`just -E .env.<net> test-<net>-upgrade-state-verify\`); fee/gas headroom (§5) → \`just quote-ccip-fees\` + \`just -E .env.<net> preflight-check\`"
echo
hdr "===================================================================="
if ((rc == 0)); then
  printf '%sOK%s postflight-monitor: all on-chain-readable checks green (still wire the dashboard/indexer rows above).\n' "$C_OK" "$C_RST"
else
  printf '%spostflight-monitor finished with WARN/ALERT/SKIP rows%s — review above (exit %s).\n' "$C_WARN" "$C_RST" "$rc"
fi
hdr "===================================================================="
exit $rc
