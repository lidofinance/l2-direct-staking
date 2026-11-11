#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source script/shared/cre-env.sh
cre_env_load_rpc_bindings
L1_RPC_URL="$(resolve_l1_rpc)"
export L1_RPC_URL

case "${1:-all}" in
  all) networks=(optimism arbitrum base linea) ;;
  optimism|arbitrum|base|linea) networks=("$1") ;;
  *) echo "Expected all, optimism, arbitrum, base, or linea" >&2; exit 2 ;;
esac

result=0
for net in "${networks[@]}"; do
  upper="$(printf '%s' "$net" | tr '[:lower:]' '[:upper:]')"
  alias="L2_${upper}_RPC_URL"
  remote="RPC_${upper}_REMOTE"
  rpc="${!alias:-${!remote:-}}"
  if [[ "${L2_NETWORK:-}" == "$net" && -n "${L2_RPC_URL:-}" ]]; then
    rpc="$L2_RPC_URL"
  fi
  if [[ -z "$rpc" ]]; then
    echo "$net: set $alias or $remote" >&2
    result=1
    continue
  fi
  export "$alias=$rpc"
  cap="$(printf '%s' "$net" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
  echo "Testing $net pool and CRE behavior on forks"
  forge test --match-contract "^${cap}(PoolTest|CREIntegrationTest)$" -vv || result=1
done
exit "$result"
