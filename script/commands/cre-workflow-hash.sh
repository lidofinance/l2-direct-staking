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
pinned_config="$(sed -n "s/^const CRE_CONFIG_SHA256 = '\([0-9a-f]*\)';$/\1/p" site/static/app.js)"
pinned_source="$(sed -n "s/^const CRE_SOURCE_SHA256 = '\([0-9a-f]*\)';$/\1/p" site/static/app.js)"
embedded_config="$(sed -n 's/^const CRE_CONFIG_JSON = \(.*\);$/\1/p' site/static/app.js)"
actual_config="$(jq -Rs . "$CONFIG")"

printf "const CRE_CONFIG_SHA256 = '%s';\n" "$config_sha"
printf "const CRE_SOURCE_SHA256 = '%s';\n" "$source_sha"

rc=0
[[ "$pinned_config" == "$config_sha" ]] || {
  echo "site/static/app.js CRE_CONFIG_SHA256 is stale" >&2
  rc=1
}
[[ "$pinned_source" == "$source_sha" ]] || {
  echo "site/static/app.js CRE_SOURCE_SHA256 is stale" >&2
  rc=1
}
[[ "$embedded_config" == "$actual_config" ]] || {
  echo "site/static/app.js CRE_CONFIG_JSON is not config.deploy.json byte-for-byte" >&2
  rc=1
}
exit "$rc"
