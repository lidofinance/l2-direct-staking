#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
for command in cast jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required" >&2
    exit 1
  fi
done
source script/shared/cre-artifacts.sh
cre_artifact_hashes

calldata="${CRE_CALLDATA:-}"
if [[ -z "$calldata" ]]; then
  [[ -t 0 ]] && echo "Paste the unsigned upsertWorkflow calldata, then press Return:" >&2
  IFS= read -r calldata
fi
calldata="${calldata//[[:space:]]/}"
[[ "$calldata" == 0x* ]] || calldata="0x$calldata"
if [[ ! "$calldata" =~ ^0xb377bfc5[0-9a-fA-F]+$ ]]; then
  echo "Expected raw upsertWorkflow calldata (selector 0xb377bfc5)" >&2
  exit 1
fi

sig='upsertWorkflow(string,string,bytes32,uint8,string,string,string,bytes,bool)'
decoded="$(cast decode-calldata --json "$sig" "$calldata")"
current_attrs="$(printf '%s' "$decoded" | jq -er '.[7] | select(type == "string")')"
if [[ "$current_attrs" != "0x" ]]; then
  echo "Refusing to overwrite non-empty attributes: $current_attrs" >&2
  exit 1
fi

name="$(printf '%s' "$decoded" | jq -er '.[0] | select(type == "string")')"
tag="$(printf '%s' "$decoded" | jq -er '.[1] | select(type == "string")')"
workflow_id="$(printf '%s' "$decoded" | jq -er '.[2] | select(type == "string")')"
status="$(printf '%s' "$decoded" | jq -er '.[3] | select(type == "number")')"
don="$(printf '%s' "$decoded" | jq -er '.[4] | select(type == "string")')"
binary_url="$(printf '%s' "$decoded" | jq -er '.[5] | select(type == "string")')"
config_url="$(printf '%s' "$decoded" | jq -er '.[6] | select(type == "string")')"
keep_alive="$(printf '%s' "$decoded" | jq -er '.[8] | select(type == "boolean") | tostring')"
attrs_json="$(jq -cn --arg config "$config_sha" --arg source "$source_sha" \
  '{v:"cre-attest/3",config:$config,source:$source}')"
attrs_hex="$(cast from-utf8 "$attrs_json")"

rewritten="$(cast calldata "$sig" "$name" "$tag" "$workflow_id" "$status" "$don" \
  "$binary_url" "$config_url" "$attrs_hex" "$keep_alive")"
roundtrip_attrs="$(cast decode-calldata --json "$sig" "$rewritten" | jq -er '.[7]')"
[[ "$roundtrip_attrs" == "$attrs_hex" ]] || {
  echo "Re-encoded attributes failed round-trip check" >&2
  exit 1
}
echo "Attached cre-attest/3 config/source digests; paste this calldata into the dashboard before signing." >&2
printf '%s\n' "$rewritten"
