#!/usr/bin/env bash
# Rotate SYNC_ROLE on CustomSender: grant SyncTrigger v2, revoke v1.
# Linea also revokes the legacy Gelato bot. Plain cast only — no forge, no just.
#
#   export L2_RPC_URL=https://...
#   export INITIAL_OWNER_PRIVATE_KEY=0x...
#   ./script/shared/repoint-sync-role.sh optimism          # 2 txs
#   ./script/shared/repoint-sync-role.sh linea             # 3 txs
#   ./script/shared/repoint-sync-role.sh --calldata linea
#
# Fork dress rehearsal (anvil): omit INITIAL_OWNER_PRIVATE_KEY — the script impersonates
# INITIAL_OWNER via anvil_impersonateAccount and sends with --unlocked.

set -euo pipefail

# ── pinned addresses (2026-07-29 automation redeploy) ─────────────────
INITIAL_OWNER="0xb5c336a5c60D3482b29d83C742C65AE8351b91a8"
SYNC_TRIGGER_V1="0x1594705D5f9BbDb36453ACF15C94d041c0E02c62" # retired, all lanes
SYNC_TRIGGER_V2="0x871a5cddE9813627Ff37A2895A0c9B117A664622" # live v2, all lanes (CREATE2)

CUSTOM_SENDER_OPTIMISM="0x328de900860816d29D1367F6903a24D8ed40C997"
CUSTOM_SENDER_ARBITRUM="0x72229141D4B016682d3618ECe47c046f30Da4AD1"
CUSTOM_SENDER_BASE="0x328de900860816d29D1367F6903a24D8ed40C997"
CUSTOM_SENDER_LINEA="0x328de900860816d29D1367F6903a24D8ed40C997"

# Linea-only: legacy Gelato automation still holds SYNC_ROLE on mainnet today.
GELATO_LINEA="0xFbdDDF18Bc681Ae649991f1Aced55b2252a1acAe"

CALldata=false
NETWORK=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--calldata] <network>

  network   optimism | arbitrum | base | linea

Env:
  L2_RPC_URL                    required
  INITIAL_OWNER_PRIVATE_KEY     required for mainnet broadcast (or L2_INITIAL_OWNER_PRIVATE_KEY)
                                omit on anvil forks — impersonates INITIAL_OWNER instead

Calls CustomSender.grantRole(SYNC_ROLE, v2) then revokeRole(SYNC_ROLE, v1).
Linea adds revokeRole(SYNC_ROLE, Gelato) when Gelato still holds the role.
EOF
}

FORK_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --calldata) CALldata=true; shift ;;
    -h|--help) usage; exit 0 ;;
    optimism|arbitrum|base|linea) NETWORK="$1"; shift ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$NETWORK" ]] || { usage >&2; exit 2; }
: "${L2_RPC_URL:?L2_RPC_URL is required}"
command -v cast >/dev/null 2>&1 || { echo "Missing: cast (foundry)" >&2; exit 1; }

case "$NETWORK" in
  optimism) CUSTOM_SENDER="$CUSTOM_SENDER_OPTIMISM" ;;
  arbitrum) CUSTOM_SENDER="$CUSTOM_SENDER_ARBITRUM" ;;
  base)     CUSTOM_SENDER="$CUSTOM_SENDER_BASE" ;;
  linea)    CUSTOM_SENDER="$CUSTOM_SENDER_LINEA" ;;
esac

V2="$(cast to-check-sum-address "$SYNC_TRIGGER_V2")"
V1="$(cast to-check-sum-address "$SYNC_TRIGGER_V1")"
ADMIN="$(cast to-check-sum-address "$INITIAL_OWNER")"
SENDER="$(cast to-check-sum-address "$CUSTOM_SENDER")"
GELATO=""
[[ "$NETWORK" == "linea" ]] && GELATO="$(cast to-check-sum-address "$GELATO_LINEA")"

SYNC_ROLE="$(cast keccak 'SYNC_ROLE')"
ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"

has_role() {
  [[ "$(cast call "$SENDER" 'hasRole(bytes32,address)(bool)' "$SYNC_ROLE" "$1" --rpc-url "$L2_RPC_URL")" == "true" ]]
}

print_call() {
  local n="$1" sig="$2"; shift 2
  echo "tx $n:"
  echo "  TO=$SENDER"
  echo "  DATA=$(cast calldata "$sig" "$@")"
  echo "  VALUE=0"
}

echo "════ $NETWORK ════ CustomSender $SENDER"
echo "  SYNC_ROLE: $V1 (v1)  →  $V2 (v2)"
[[ -n "$GELATO" ]] && echo "  also revoke: $GELATO (Gelato)"
echo "  signed by: $ADMIN"

[[ "$(cast call "$SENDER" 'hasRole(bytes32,address)(bool)' "$ADMIN_ROLE" "$ADMIN" --rpc-url "$L2_RPC_URL")" == "true" ]] \
  || { echo "Initial Owner lacks DEFAULT_ADMIN_ROLE (finalize already ran?)" >&2; exit 1; }
has_role "$V1" || { echo "v1 ($V1) does not hold SYNC_ROLE" >&2; exit 1; }
[[ "$(cast to-check-sum-address "$(cast call "$V2" 'SENDER()(address)' --rpc-url "$L2_RPC_URL")")" == "$SENDER" ]] \
  || { echo "v2 SENDER() does not match this lane's CustomSender" >&2; exit 1; }
REVOKE_GELATO=false
if [[ -n "$GELATO" ]] && has_role "$GELATO"; then
  REVOKE_GELATO=true
  echo "  Gelato holds SYNC_ROLE — will revoke after v1"
elif [[ -n "$GELATO" ]]; then
  echo "  Gelato already de-roled — skip"
fi
echo "  preflight OK"

if [[ "$CALldata" == true ]]; then
  echo; echo "Calldata only — no broadcast."
  print_call 1 'grantRole(bytes32,address)' "$SYNC_ROLE" "$V2"
  echo
  print_call 2 'revokeRole(bytes32,address)' "$SYNC_ROLE" "$V1"
  if [[ "$REVOKE_GELATO" == true ]]; then
    echo
    print_call 3 'revokeRole(bytes32,address)' "$SYNC_ROLE" "$GELATO"
  fi
  exit 0
fi

owner_key="${INITIAL_OWNER_PRIVATE_KEY:-${L2_INITIAL_OWNER_PRIVATE_KEY:-}}"
if [[ -z "$owner_key" ]]; then
  FORK_MODE=true
  echo "No INITIAL_OWNER_PRIVATE_KEY — fork mode: impersonating $ADMIN"
  cast rpc --rpc-url "$L2_RPC_URL" anvil_impersonateAccount "$ADMIN" >/dev/null 2>&1 \
    || { echo "Impersonation refused — not an anvil fork? Set INITIAL_OWNER_PRIVATE_KEY for mainnet." >&2; exit 1; }
  cast rpc --rpc-url "$L2_RPC_URL" anvil_setBalance "$ADMIN" 0xde0b6b3a7640000 >/dev/null 2>&1 || true
else
  [[ "$(cast wallet address --private-key "$owner_key")" == "$ADMIN" ]] \
    || { echo "Key does not match Initial Owner $ADMIN" >&2; exit 1; }
fi

cast_send() {
  local n="$1" sig="$2"; shift 2
  echo; echo "tx $n: $sig"
  if [[ "$FORK_MODE" == true ]]; then
    cast send "$SENDER" "$sig" "$@" --rpc-url "$L2_RPC_URL" --unlocked --from "$ADMIN"
  else
    cast send "$SENDER" "$sig" "$@" --rpc-url "$L2_RPC_URL" --private-key "$owner_key"
  fi
}

cast_send 1 'grantRole(bytes32,address)' "$SYNC_ROLE" "$V2"
cast_send 2 'revokeRole(bytes32,address)' "$SYNC_ROLE" "$V1"
[[ "$REVOKE_GELATO" == true ]] && cast_send 3 'revokeRole(bytes32,address)' "$SYNC_ROLE" "$GELATO"

has_role "$V2" || { echo "FAIL: v2 lacks SYNC_ROLE after run" >&2; exit 1; }
has_role "$V1" && { echo "FAIL: v1 still holds SYNC_ROLE" >&2; exit 1; }
[[ "$REVOKE_GELATO" == true ]] && has_role "$GELATO" && { echo "FAIL: Gelato still holds SYNC_ROLE" >&2; exit 1; }

msg="Done. Verified: hasRole(SYNC_ROLE, v2)=true; v1=false"
[[ "$REVOKE_GELATO" == true ]] && msg+="; Gelato=false"
echo
echo "$msg."
