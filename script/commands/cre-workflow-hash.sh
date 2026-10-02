#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
command -v jq >/dev/null 2>&1 || {
  echo "jq is required" >&2
  exit 1
}
source script/shared/cre-artifacts.sh
cre_artifact_hashes

CONFIG="cre-workflows/sync-automation/config.deploy.json"
SITE_CONFIG="site/static/config.js"
pinned_config="$(sed -n "s/^export const CRE_CONFIG_SHA256 = '\([0-9a-f]*\)';$/\1/p" "$SITE_CONFIG")"
pinned_source="$(sed -n "s/^export const CRE_SOURCE_SHA256 = '\([0-9a-f]*\)';$/\1/p" "$SITE_CONFIG")"
embedded_config="$(sed -n 's/^export const CRE_CONFIG_JSON = \(.*\);$/\1/p' "$SITE_CONFIG")"
actual_config="$(jq -Rs . "$CONFIG")"

printf "export const CRE_CONFIG_SHA256 = '%s';\n" "$config_sha"
printf "export const CRE_SOURCE_SHA256 = '%s';\n" "$source_sha"

rc=0
[[ "$pinned_config" == "$config_sha" ]] || {
  echo "$SITE_CONFIG CRE_CONFIG_SHA256 is stale" >&2
  rc=1
}
[[ "$pinned_source" == "$source_sha" ]] || {
  echo "$SITE_CONFIG CRE_SOURCE_SHA256 is stale" >&2
  rc=1
}
[[ "$embedded_config" == "$actual_config" ]] || {
  echo "$SITE_CONFIG CRE_CONFIG_JSON is not config.deploy.json byte-for-byte" >&2
  rc=1
}
exit "$rc"
