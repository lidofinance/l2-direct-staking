#!/usr/bin/env bash
# STEP 1/2 — Safe batch #1: link the LOL Safe as the org's workflow owner on the L1 WorkflowRegistry.
# Emits calldata only; the Safe must be msg.sender (linkOwner has no owner parameter).
#
#   script/shared/cre-migrate-1-relink.sh              # -> safe-txs/cre/link.json
#
# The org caps linked owners at 1, currently held by the AO, and while it is full the backend REFUSES to
# issue the Safe's attestation: `cre account link-key` returns "Limit of linked owners reached for this
# org" and there is no calldata to sign.
#
# DECIDED 2026-08-14 — get the cap raised to >=2 through Chainlink support, then re-run this script. The
# rejected alternative was unlinking the AO first (`cre account unlink-key`): it costs its own 3-of-5
# ceremony, performs unverified "pre-unlink cleanup" on the AO's running workflows, leaves a window in
# which the org can register nothing, and it was never established that the Safe is an admissible caller
# for someone else's unlink. That branch is deliberately absent rather than shipped unvalidated.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source script/shared/cre-env.sh

[[ $# -eq 0 ]] || { echo "usage: $0   (no arguments)" >&2; exit 2; }

SAFE=0x23AC4BF8ca7345eE533B12705aF40F69060D9b5b
AO=0xBdF111fec2e818Ad9c76fbBaE46144746AD55773
REG=0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5
LANE="${CRE_LINK_LANE:-optimism}"   # any target: the CLI needs one, linking is not lane-scoped
OUT=safe-txs/cre                    # NOT out/ — that is foundry's build dir; `forge clean` deletes it
mkdir -p "$OUT"
set -a; . "./.env.$LANE"; set +a

# resolve_l1_rpc only PREFERS mainnet: with RPC_ETHEREUM_REMOTE unset it falls through to
# RPC_ETHEREUM — the local fork — and root .env's L1_RPC_URL is a `${RPC_ETHEREUM_REMOTE}` indirection
# that only `just` expands, so a plain script cannot recover it. Prove the endpoint rather than prefer
# it, then export it so the `just cre` child and the CLI's own ${L1_RPC_URL} interpolation use the SAME
# endpoint the gates below judged.
L1="$(resolve_l1_rpc)"
cre_env_require_live_mainnet "$L1"
export L1_RPC_URL="$L1"

# The unsigned path has no key to derive the owner from, so project.yaml needs a literal address.
git diff --quiet -- cre-workflows/project.yaml || { echo "project.yaml has uncommitted edits" >&2; exit 1; }
BAK="$(mktemp "${TMPDIR:-/tmp}/project.yaml.XXXXXX")"; cp cre-workflows/project.yaml "$BAK"
# Two traps, not one handler on three signals: the INT/TERM handler exits, which fires EXIT exactly once.
# A bare `trap … EXIT INT TERM` would run the restore twice and the second `mv` would fail.
trap 'mv "$BAK" cre-workflows/project.yaml' EXIT
trap 'exit 130' INT TERM

safe_json() { # name data -> Safe Transaction Builder file
  jq -n --arg n "$1" --arg to "$REG" --arg data "$2" --arg s "$SAFE" --argjson now "$(date +%s)000" \
    '{version:"1.0", chainId:"1", createdAt:$now,
      meta:{name:$n, txBuilderVersion:"1.16.5", createdFromSafeAddress:$s},
      transactions:[{to:$to, value:"0", data:$data}]}'
}

# `set -e` + `pipefail` would kill `data=$(grep … | head -1)` on a no-match — and on SIGPIPE once a log
# outgrows the pipe buffer — BEFORE the shape guard below could explain what went wrong. Absorbing the
# status here is what makes those messages reachable at all.
extract() { # selector logfile -> 0x<calldata>, empty when absent
  printf '0x%s\n' "$(grep -oE "(0x)?$1[0-9a-fA-F]+" "$2" | sed 's/^0x//' | head -1 || true)"
}

# An RPC failure used to read as "already linked" and exit 0, sending the operator straight to step 2
# with an unlinked Safe. Only the two admissible answers may pass.
linked="$(cast call "$REG" 'isOwnerLinked(address)(bool)' "$SAFE" --rpc-url "$L1" | tr -d ' \r')"
case "$linked" in
  false) ;;
  true)  echo "$SAFE is already linked — skip to script/shared/cre-migrate-2-deploy.sh."; exit 0 ;;
  *)     echo "cannot read isOwnerLinked($SAFE) on mainnet (got '$linked') — refusing to guess" >&2; exit 1 ;;
esac

yq -i ".\"production-$LANE\".account.\"workflow-owner-address\" = \"$SAFE\"" cre-workflows/project.yaml
CRE_DEPLOY_UNSIGNED=true CRE_WORKFLOW_OWNER=$SAFE \
  just cre account link-key --unsigned -l "${CRE_OWNER_LABEL:-lido-lol-safe}" \
  --target="production-$LANE" --non-interactive --yes 2>&1 | tee "$OUT/link.log"

data="$(extract dc101969 "$OUT/link.log")"
[[ "$data" =~ ^0xdc101969([0-9a-fA-F]{2})+$ ]] \
  || { echo "no linkOwner calldata in $OUT/link.log — if it says \"Limit of linked owners reached\", the" >&2
       echo "cap is still 1 and still held by $AO; Chainlink support must raise it to >=2 (see header)." >&2
       exit 1; }
cast calldata-decode 'linkOwner(uint256,bytes32,bytes)' "$data"

# Replay the EXACT (sender, calldata) pair the Safe will execute. `cast call` runs the real function body
# without broadcasting, so it reverts with the same errors the live call would — and unlike
# `canLinkOwner(…)` it also covers msg.sender, which that view's arguments cannot express. (Under
# MultiSend the Safe delegatecalls, so the inner msg.sender really is the Safe.) The proof is single-use
# and expiring, so re-run this immediately before execution, not only before signing.
echo "Dry run from $SAFE — no revert means it will succeed:"
cast call "$REG" --data "$data" --from "$SAFE" --rpc-url "$L1" \
  || { echo "REVERTED — do not sign. The attestation may have expired, or the cap is still full." >&2; exit 1; }

safe_json "CRE — link the LOL Safe as workflow owner" "$data" > "$OUT/link.json"
echo "Wrote $OUT/link.json — import from $SAFE (3-of-5)."
echo "Next: script/shared/cre-migrate-2-deploy.sh"
