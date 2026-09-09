#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ROOT_DIR="$(pwd)"
source "$ROOT_DIR/script/shared/cre-env.sh"
# just -E replaces the dotenv path; load missing root secrets as the CRE commands do.
cre_env_load_secrets
command -v cast >/dev/null 2>&1 || {
  echo "Missing 'cast' (foundry)" >&2
  exit 1
}
rc=0
OK() {
  echo "  ✓ $*"
}

BAD() {
  echo "  ✗ $*"
  rc=1
}
INFO() {
  echo "  · $*"
}

lc() {
  printf '%s' "${1:-}" | tr 'A-Z' 'a-z'
}

anchor() {
  local net
  net="$(basename "$1" .inputs.yaml)"
  just _l2-input-anchor "$net" "$2" 2>/dev/null
}

echo "===================================================================="
echo "ENV DOCTOR — canonical variables and what they resolve to"
echo "===================================================================="
echo
echo "Secrets tier (root .env — keys/tokens only):"
for v in L2_LIDO_DEPLOYER_PRIVATE_KEY INITIAL_OWNER_PRIVATE_KEY ETHERSCAN_API_KEY GITHUB_API_TOKEN; do
  [[ -n "${!v:-}" ]] && INFO "$v = set" || INFO "$v = unset"
done
AO_KEY="${L2_AUTOMATION_OWNER_PRIVATE_KEY:-${L2_AUTOMATION_OWNER_PK:-}}"
if [[ -n "$AO_KEY" ]]; then
  if [[ -n "${L2_AUTOMATION_OWNER_PRIVATE_KEY:-}" ]]; then
    INFO "Automation Owner key = set (via L2_AUTOMATION_OWNER_PRIVATE_KEY)"
  else
    INFO "Automation Owner key = set (via L2_AUTOMATION_OWNER_PK)"
  fi
else
  BAD "Automation Owner key unset — set L2_AUTOMATION_OWNER_PRIVATE_KEY (or L2_AUTOMATION_OWNER_PK) in the root .env"
fi
if [[ -n "${CRE_ETH_PRIVATE_KEY:-}" ]]; then
  BAD "CRE_ETH_PRIVATE_KEY is set in the environment — it is DERIVED from the Automation Owner key; a hand-written copy will rot on rotation. Remove it from .env."
else
  OK "no hand-written CRE_ETH_PRIVATE_KEY (derived at call time)"
fi
echo
echo "Actor addresses:"
INFO "DEPLOYER              = ${DEPLOYER:-<unset>}"
INFO "L2_AUTOMATION_OWNER   = ${L2_AUTOMATION_OWNER:-<unset>}"
WORKFLOW_OWNER="$(just _l2-input-anchor optimism creWorkflowOwner 2>/dev/null || true)"
INFO "CRE_WORKFLOW_OWNER    = ${WORKFLOW_OWNER:-<unset>}"
if [[ -n "$AO_KEY" && -n "${L2_AUTOMATION_OWNER:-}" ]]; then
  DERIVED="$(cast wallet address --private-key "$AO_KEY" 2>/dev/null || true)"
  if [[ -z "$DERIVED" ]]; then
    BAD "Automation Owner key is not a valid private key"
  elif [[ "$(lc "$DERIVED")" == "$(lc "$L2_AUTOMATION_OWNER")" ]]; then
    OK "AO key signs as $DERIVED == L2_AUTOMATION_OWNER"
  else
    BAD "AO key signs as $DERIVED but L2_AUTOMATION_OWNER = $L2_AUTOMATION_OWNER"
  fi
fi
if [[ -n "${L2_LIDO_DEPLOYER_PRIVATE_KEY:-}" && -n "${DEPLOYER:-}" ]]; then
  DEP_DERIVED="$(cast wallet address --private-key "$L2_LIDO_DEPLOYER_PRIVATE_KEY" 2>/dev/null || true)"
  [[ "$(lc "$DEP_DERIVED")" == "$(lc "$DEPLOYER")" ]] &&
    OK "deployer key signs as $DEP_DERIVED == DEPLOYER" ||
    BAD "deployer key signs as ${DEP_DERIVED:-<invalid>} but DEPLOYER = $DEPLOYER"
fi
echo
echo "L1 (Ethereum mainnet):"
if L1="$(resolve_l1_rpc 2>/dev/null)"; then
  SRC="L1_RPC_URL"
  [[ -n "${L1_RPC_URL:-}" ]] || SRC="RPC_ETHEREUM_REMOTE/RPC_ETHEREUM (fallback)"
  INFO "resolved $(cre_env_host "$L1")  ← $SRC"
  CID="$(cast chain-id --rpc-url "$L1" 2>/dev/null || echo '?')"
  [[ "$CID" == "1" ]] && OK "chain-id 1" || BAD "chain-id $CID (expected 1) — is this the local fork proxy or a wrong endpoint?"

  # Check registry linkage, DON quota, and mainnet gas for the workflow-owner Safe.
  # CRE organization access and credits require the CRE dashboard (docs/cre.md).
  if [[ "$CID" == "1" && -n "$WORKFLOW_OWNER" ]]; then
    WF_REGISTRY=0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5
    DON_FAMILY="${CRE_DON_FAMILY:-zone-a}"
    LINKED="$(cast call "$WF_REGISTRY" 'isOwnerLinked(address)(bool)' "$WORKFLOW_OWNER" --rpc-url "$L1" 2>/dev/null || echo '?')"
    [[ "$LINKED" == "true" ]] &&
      OK "WorkflowRegistry: owner linked (isOwnerLinked = true)" ||
      BAD "WorkflowRegistry: Safe owner NOT linked (isOwnerLinked = $LINKED)"
    QUOTA="$(cast call "$WF_REGISTRY" 'getMaxWorkflowsPerUserDON(address,string)(uint32)' "$WORKFLOW_OWNER" "$DON_FAMILY" --rpc-url "$L1" 2>/dev/null || echo '0')"
    [[ "${QUOTA%% *}" =~ ^[0-9]+$ && "${QUOTA%% *}" -gt 0 ]] &&
      OK "WorkflowRegistry: deploy quota on DON '$DON_FAMILY' = ${QUOTA%% *} workflow(s)" ||
      BAD "WorkflowRegistry: zero deploy quota on DON '$DON_FAMILY' — request access with 'just cre account access'"
    OWNER_WEI="$(cast balance "$WORKFLOW_OWNER" --rpc-url "$L1" 2>/dev/null || echo 0)"
    OWNER_WEI="${OWNER_WEI%%[*}"
    OWNER_WEI="${OWNER_WEI%% *}"
    [[ "$OWNER_WEI" =~ ^[0-9]+$ && "$OWNER_WEI" =~ [1-9] ]] &&
      OK "Workflow-owner Safe mainnet gas: $(cast from-wei "$OWNER_WEI") ETH" ||
      BAD "Workflow-owner Safe has 0 mainnet ETH — fund it before executing registry calldata"
    REGISTERED="$(cast call "$WF_REGISTRY" 'getWorkflowListByOwner(address,uint256,uint256)' "$WORKFLOW_OWNER" 0 20 --rpc-url "$L1" 2>/dev/null || true)"
    if [[ ! "$REGISTERED" =~ ^0x[0-9a-fA-F]+$ || ${#REGISTERED} -lt 130 ]]; then
      BAD "WorkflowRegistry: could not read workflow list"
    elif [[ "$REGISTERED" == 0x*0000000000000000000000000000000000000000000000000000000000000000 && ${#REGISTERED} -le 130 ]]; then
      INFO "WorkflowRegistry: no workflows registered under this owner yet"
    else
      INFO "WorkflowRegistry: workflow(s) already registered under this owner (getWorkflowListByOwner non-empty)"
    fi
  fi
else
  BAD "no Ethereum-mainnet RPC — bind L1_RPC_URL in .env.<network> to \${RPC_ETHEREUM_REMOTE}"
fi
echo
# Use the loaded lane environment when selected; otherwise read each lane's dotenv bindings.
LANES=(optimism arbitrum base linea)
[[ -z "${L2_NETWORK:-}" ]] || LANES=("$L2_NETWORK")
for net in "${LANES[@]}"; do
  echo "──────── lane: $net ────────"
  IN="$ROOT_DIR/config/state/$net.inputs.yaml"
  CRE_DEP="$ROOT_DIR/config/state/$net.deployed.yaml"
  if [[ "${L2_NETWORK:-}" == "$net" ]]; then
    L2="${L2_RPC_URL:-}"
    RECV="${L2_CRE_RECEIVER:-}"
    TRIG="${L2_SYNC_TRIGGER:-}"
  else
    # Expand only a complete ${RPC_*} binding; never evaluate dotenv values as shell code.
    L2="$(grep -m1 '^L2_RPC_URL=' "$ROOT_DIR/.env.$net" 2>/dev/null | cut -d= -f2- || true)"
    L2="${L2%\"}"
    L2="${L2#\"}"
    L2="${L2%\'}"
    L2="${L2#\'}"
    rpc_binding='^\$\{(RPC_[A-Za-z0-9_]+)\}$'
    if [[ "$L2" =~ $rpc_binding ]]; then
      rpc_var="${BASH_REMATCH[1]}"
      L2="${!rpc_var:-}"
    fi
    RECV="$(grep -m1 '^L2_CRE_RECEIVER=' "$ROOT_DIR/.env.$net" 2>/dev/null | cut -d= -f2- || true)"
    TRIG="$(grep -m1 '^L2_SYNC_TRIGGER=' "$ROOT_DIR/.env.$net" 2>/dev/null | cut -d= -f2- || true)"
    INFO "(read from .env.$net — run with NETWORK=$net for the fully loaded overlay)"
  fi
  WFID=""
  if [[ -f "$CRE_DEP" ]]; then
    WFID="$(yq '.. | select(anchor == "creWorkflowId")' "$CRE_DEP" 2>/dev/null | tr -d '"' | head -n1)"
  fi
  INFO "L2 RPC   $(cre_env_host "$L2")"
  case "$net" in
    optimism) expected_chain_id=10 ;;
    arbitrum) expected_chain_id=42161 ;;
    base) expected_chain_id=8453 ;;
    linea) expected_chain_id=59144 ;;
    *) BAD "Unknown lane: $net"; continue ;;
  esac
  CID="$(cast chain-id --rpc-url "$L2" 2>/dev/null || true)"
  if [[ "$CID" != "$expected_chain_id" ]]; then
    BAD "$net RPC chain-id ${CID:-unreadable}, expected $expected_chain_id"
    continue
  fi
  INFO "trigger  ${TRIG:-<unset>}"
  INFO "receiver ${RECV:-<unset>}"
  # Ownership migration is per-lane. Recognize the Safe, retired EOA, and LOL owner
  # and report the phase (docs/automation-owner-redeploy.md S3).
  ANCHOR_AO="$(anchor "$IN" l2AutomationOwner)"
  ANCHOR_WF="$(anchor "$IN" creWorkflowOwner)"
  ANCHOR_LOL="$(anchor "$IN" l2LiquidityOwner)"
  if [[ -n "$ANCHOR_AO" && "$ANCHOR_AO" != "null" ]]; then
    if [[ -z "${L2_AUTOMATION_OWNER:-}" || "$(lc "$ANCHOR_AO")" == "$(lc "$L2_AUTOMATION_OWNER")" ]]; then
      OK "l2AutomationOwner anchor == L2_AUTOMATION_OWNER ($ANCHOR_AO)"
    else
      BAD "l2AutomationOwner anchor $ANCHOR_AO != L2_AUTOMATION_OWNER $L2_AUTOMATION_OWNER"
    fi
  else
    INFO "no l2AutomationOwner anchor yet (lane still on the LOL-owned automation pair)"
  fi
  if [[ -n "$L2" && -n "$RECV" ]]; then
    PINNED="$(cast call "$RECV" 'getExpectedAuthor()(address)' --rpc-url "$L2" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -z "$PINNED" ]]; then
      INFO "on-chain getExpectedAuthor(): unreachable (RPC down or wrong address)"
    elif [[ -n "$ANCHOR_WF" && "$(lc "$PINNED")" == "$(lc "$ANCHOR_WF")" ]]; then
      OK "on-chain CREReceiver.getExpectedAuthor() == creWorkflowOwner ($PINNED)"
    elif [[ -n "${L2_AUTOMATION_OWNER:-}" && "$(lc "$PINNED")" == "$(lc "$L2_AUTOMATION_OWNER")" ]]; then
      INFO "on-chain getExpectedAuthor() = $PINNED (retired per-lane workflow owner)"
    elif [[ -n "$ANCHOR_LOL" && "$(lc "$PINNED")" == "$(lc "$ANCHOR_LOL")" ]]; then
      INFO "on-chain getExpectedAuthor() = $PINNED (LOL multisig) — lane not yet moved to the consolidated workflow owner; deploy-cre-workflow would abort here by design"
    else
      BAD "on-chain CREReceiver.getExpectedAuthor() = $PINNED — not creWorkflowOwner (${ANCHOR_WF:-<absent>}), retired owner (${L2_AUTOMATION_OWNER:-<unset>}), or l2LiquidityOwner (${ANCHOR_LOL:-<absent>})"
    fi
  fi
  if [[ -n "$WFID" ]]; then
    [[ "$WFID" =~ ^0x[0-9a-fA-F]{64}$ ]] &&
      OK "creWorkflowId deployed-state anchor well-formed ($WFID)" ||
      BAD "creWorkflowId malformed in $CRE_DEP: $WFID"
  else
    INFO "creWorkflowId: <unrecorded> (missing anchor in $CRE_DEP; record after workflow deploy/upsert)"
  fi
  echo
done
echo "===================================================================="
[[ $rc -eq 0 ]] && echo "env-doctor: OK" || echo "env-doctor: problems above (rc=$rc)"
echo "===================================================================="
exit $rc
