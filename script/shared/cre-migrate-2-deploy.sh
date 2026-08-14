#!/usr/bin/env bash
# STEP 2/2 — Safe batch #2: register the sync-automation workflows under the LOL Safe. Calldata only.
# Compiles and registers the WORKING TREE of cre-workflows/, so the tree must be committed first: the
# workflow ID is derived from the binary + config, not from the owner alone. The batch title carries the
# source revision and the cron the configs actually hold, so a behaviour change cannot ride silently
# inside an owner migration. All lanes go in ONE batch, so it is all-or-nothing.
#
#   script/shared/cre-migrate-2-deploy.sh [net...]     # default: all four -> safe-txs/cre/batch.json
#   CRE_ALLOW_DIRTY=1 script/shared/cre-migrate-2-deploy.sh optimism    # draft from a dirty tree
#
# Do ONE lane first: ADR-0001 residual (a) — that the DON embeds the registry owner as
# metadata.workflowOwner — is only proven by a live CREReceiver.CallExecuted.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source script/shared/cre-env.sh

SAFE=0x23AC4BF8ca7345eE533B12705aF40F69060D9b5b
REG=0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5
NETS=("$@"); [[ $# -gt 0 ]] || NETS=(optimism arbitrum base linea)
for net in "${NETS[@]}"; do
  case "$net" in optimism|arbitrum|base|linea) ;; *) echo "Unknown network: $net" >&2; exit 2 ;; esac
  [[ -f "cre-workflows/sync-automation/config.deploy.$net.json" ]] \
    || { echo "Missing cre-workflows/sync-automation/config.deploy.$net.json — run 'just -E .env.$net update-cre-config'" >&2; exit 1; }
done
OUT=safe-txs/cre                    # NOT out/ — that is foundry's build dir; `forge clean` deletes it
mkdir -p "$OUT"

# Local gates first — cheap, deterministic, and the ones most likely to be violated.
#
# The calldata below is a function of the WORKING TREE, not of any commit: `cre workflow deploy` compiles
# what is on disk. A dirty tree therefore yields a blob that five people sign and nothing can later map
# back to a revision — and because the attestation expires, a re-run before execution can legitimately
# produce DIFFERENT calldata with nothing flagging the change. Refuse by default; CRE_ALLOW_DIRTY=1 is
# the escape hatch for iterating on a draft you are not going to sign.
if ! git diff --quiet -- cre-workflows/; then
  git status --porcelain -- cre-workflows/ >&2
  [[ "${CRE_ALLOW_DIRTY:-0}" == 1 ]] \
    || { echo "cre-workflows/ has uncommitted edits (above) — commit them, or set CRE_ALLOW_DIRTY=1 to build an unsignable draft" >&2; exit 1; }
  echo "cre-migrate: CRE_ALLOW_DIRTY=1 — building from an UNCOMMITTED tree. Do not sign this batch." >&2
fi

# Batch title: provenance plus the one behaviour knob that is NOT the owner, both READ FROM the files
# being compiled so the title cannot drift from what it names. Signers asked to approve "register under
# the LOL Safe" would otherwise have no way to see e.g. a cron change riding along in the same batch.
REV="$(git rev-parse --short HEAD)"; git diff --quiet -- cre-workflows/ || REV="$REV-dirty"
SCHEDS="$(for net in "${NETS[@]}"; do jq -r .schedule "cre-workflows/sync-automation/config.deploy.$net.json"; done \
          | sort -u | paste -sd'|' -)"
case "$SCHEDS" in
  *'|'*) NAME="CRE sync-automation — register under the LOL Safe · cron MIXED ($SCHEDS) · @ $REV" ;;
  *)     NAME="CRE sync-automation — register under the LOL Safe · cron $SCHEDS · @ $REV" ;;
esac

# See cre-migrate-1-relink.sh — resolve_l1_rpc can silently land on the local fork. Exporting the proven
# endpoint matters twice over here, because `just -E .env.<net>` REPLACES the dotenv path and drops the
# root .env: the recipe's own `cre_env_export` (the "is the Safe a contract on mainnet" check) and the
# CLI's `${L1_RPC_URL}` would otherwise resolve independently of what these gates judged.
L1="$(resolve_l1_rpc)"
cre_env_require_live_mainnet "$L1"
export L1_RPC_URL="$L1"

linked="$(cast call "$REG" 'isOwnerLinked(address)(bool)' "$SAFE" --rpc-url "$L1" | tr -d ' \r')"
case "$linked" in
  true)  ;;
  false) echo "Safe is not linked — run script/shared/cre-migrate-1-relink.sh first" >&2; exit 1 ;;
  *)     echo "cannot read isOwnerLinked($SAFE) on mainnet (got '$linked') — refusing to guess" >&2; exit 1 ;;
esac
# That number is the DON default unless a grant was issued, so 3 does not mean "three were allocated".
Q="$(cast call "$REG" 'getMaxWorkflowsPerUserDON(address,string)(uint32)' "$SAFE" "${CRE_CLI_DON_FAMILY:-zone-a}" --rpc-url "$L1")"
[[ "${Q%% *}" -ge "${#NETS[@]}" ]] \
  || { echo "deploy quota ${Q%% *} < ${#NETS[@]} lanes — request a grant with 'just cre account access'" >&2; exit 1; }

BAK="$(mktemp "${TMPDIR:-/tmp}/project.yaml.XXXXXX")"; cp cre-workflows/project.yaml "$BAK"
# Two traps, not one handler on three signals — see cre-migrate-1-relink.sh.
trap 'mv "$BAK" cre-workflows/project.yaml' EXIT
trap 'exit 130' INT TERM

# `set -e` + `pipefail` would kill the assignment on a no-match (and on SIGPIPE for a large log) BEFORE
# the shape guard could explain it.
extract() { # selector logfile -> 0x<calldata>, empty when absent
  printf '0x%s\n' "$(grep -oE "(0x)?$1[0-9a-fA-F]+" "$2" | sed 's/^0x//' | head -1 || true)"
}

UPSERT='upsertWorkflow(string,string,bytes32,uint8,string,string,string,bytes,bool)'

TXS=()
: > "$OUT/workflow-ids.txt"   # truncate: this file must describe THIS batch, not accumulate across runs
for net in "${NETS[@]}"; do
  set -a; . "./.env.$net"; set +a
  # deploy-cre-workflow requires L2_CRE_RECEIVER and .env.<net> does not carry it.
  L2_CRE_RECEIVER="$(yq ".deployed.l2[] | select(anchor == \"l2CreReceiver\")" "config/state/$net.deployed.yaml" | tr -d '"')"
  export L2_CRE_RECEIVER
  yq -i ".\"production-$net\".account.\"workflow-owner-address\" = \"$SAFE\"" cre-workflows/project.yaml
  # The recipe re-reads getExpectedAuthor() and aborts on mismatch. All four lanes were pinned to the
  # Safe on 2026-08-13, so it passes — and still catches a lane that was missed or re-pinned back.
  CRE_DEPLOY_UNSIGNED=true CRE_WORKFLOW_OWNER=$SAFE just -E ".env.$net" deploy-cre-workflow 2>&1 \
    | tee "$OUT/$net.deploy.log"
  data="$(extract b377bfc5 "$OUT/$net.deploy.log")"
  [[ "$data" =~ ^0xb377bfc5([0-9a-fA-F]{2})+$ ]] \
    || { echo "no upsertWorkflow calldata in $OUT/$net.deploy.log" >&2; exit 1; }

  # A regex proves only that the blob is shaped like an upsert. Decode it so the batch is reviewable
  # against something before five people sign it — name, tag, DON family and the URLs are all in here.
  echo "── $net · decoded upsertWorkflow ─────────────────────────────────────"
  cast calldata-decode "$UPSERT" "$data"
  # Field 3 is the bytes32 workflow ID (positional — confirmed by finding the same value in the CLI's own
  # output). This is the value `record-cre-workflow-id` wants, taken from the signed bytes rather than
  # from a log line, so what gets recorded is what gets executed.
  wf="$(cast calldata-decode "$UPSERT" "$data" | sed -n 3p | tr -d ' \r')"
  if grep -qi -- "${wf#0x}" "$OUT/$net.deploy.log"; then
    echo "workflow ID $wf (matches the ID printed by the CLI)"
  else
    echo "workflow ID $wf — NOT found in the CLI output; confirm by hand before recording it" >&2
  fi
  echo "$net $wf" >> "$OUT/workflow-ids.txt"

  TXS+=("$(jq -n --arg to "$REG" --arg data "$data" '{to:$to, value:"0", data:$data}')")
done

printf '%s\n' "${TXS[@]}" | jq -s --arg s "$SAFE" --arg n "$NAME" --argjson now "$(date +%s)000" \
  '{version:"1.0", chainId:"1", createdAt:$now,
    meta:{name:$n, txBuilderVersion:"1.16.5", createdFromSafeAddress:$s},
    transactions:.}' > "$OUT/batch.json"

echo
echo "Wrote $OUT/batch.json — ${#TXS[@]} tx to $REG. Import from $SAFE (3-of-5)."
echo "Batch title: $NAME"
echo "Workflow IDs (from the signed calldata, not the log): $OUT/workflow-ids.txt"
echo "After execution, per lane: just record-cre-workflow-id <net> <workflow-id>"
echo "                     then: just -E .env.<net> verify-cre-workflow"
