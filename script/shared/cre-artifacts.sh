#!/usr/bin/env bash
# Source from the repository root to hash the files used for deployment.
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "shasum or sha256sum is required" >&2
    return 1
  fi
}

cre_artifact_hashes() {
  config_sha="$(sha256_file cre-workflows/sync-automation/config.deploy.json)" || return 1
  source_sha="$(sha256_file cre-workflows/sync-automation/main.ts)" || return 1
}
