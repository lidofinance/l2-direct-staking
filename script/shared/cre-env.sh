#!/usr/bin/env bash
# Derive the env spellings external tools insist on from THIS repo's canonical variables.
# SOURCE this file, do not execute it.
#
#   source script/shared/cre-env.sh
#   cre_env_export                 # exports CRE_ETH_PRIVATE_KEY / CRE_WORKFLOW_OWNER / L1_RPC_URL / L2_<NET>_RPC_URL
#   L1_RPC_URL="$(resolve_l1_rpc)" # just the L1 URL, for recipes that need nothing else
#
# Derive key and RPC aliases in-process so callers share one value when credentials or endpoints change.
# Failure messages name the canonical variable to set.
#
# Canonical variables (see RUNBOOK "Environment"):
#   secrets, root .env         L2_AUTOMATION_OWNER_PRIVATE_KEY (or _PK) · L2_AUTOMATION_OWNER
#   lane facts, .env.<network> L2_NETWORK · L1_RPC_URL · L2_RPC_URL
#   machine, shell/root .env   RPC_<CHAIN>_REMOTE (upstream) · RPC_ETHEREUM (local fork proxy)

cre_env_die() {
  echo "cre-env: $*" >&2
  return 1
}

# Repo root, derived from this file's own location (script/shared/) so it holds no matter what the
# caller's cwd is.
cre_env_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$(cd "$here/../.." && pwd)"
}

# Load the secrets tier from the ROOT .env for variables that are not already in the environment.
#
# `just -E .env.<network>` replaces the configured dotenv list. Load missing root values so
# that form and `NETWORK=<network> just ...` can resolve the same credentials.
#
# Deliberately narrow: only the secrets-tier names below, only when unset (a value already in the
# environment always wins), values taken literally with no expansion — the root .env holds plain
# literals, unlike .env.<network> whose RPC bindings reference ${RPC_*} and need just's own expansion.
cre_env_load_secrets() {
  local dotenv name value
  dotenv="$(cre_env_root)/.env"
  [[ -f "$dotenv" ]] || return 0
  for name in L2_AUTOMATION_OWNER L2_AUTOMATION_OWNER_PRIVATE_KEY L2_AUTOMATION_OWNER_PK \
              ETHERSCAN_API_KEY GITHUB_API_TOKEN; do
    [[ -z "${!name:-}" ]] || continue
    value="$(grep -m1 "^[[:space:]]*${name}=" "$dotenv" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"'\r' | xargs 2>/dev/null || true)"
    [[ -n "$value" ]] && export "$name=$value"
  done
  return 0
}

# Load machine-level live RPC bindings from the ignored root .env when `just -E .env.<network>`
# replaces the normal two-file dotenv list. These canonical values are literal URLs.
cre_env_load_rpc_bindings() {
  local dotenv name value
  dotenv="$(cre_env_root)/.env"
  [[ -f "$dotenv" ]] || return 0
  for name in RPC_ETHEREUM_REMOTE RPC_OPTIMISM_REMOTE RPC_ARBITRUM_REMOTE \
              RPC_BASE_REMOTE RPC_LINEA_REMOTE; do
    [[ -z "${!name:-}" ]] || continue
    value="$(grep -m1 "^[[:space:]]*${name}=" "$dotenv" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"'\r' | xargs 2>/dev/null || true)"
    [[ -n "$value" ]] && export "$name=$value"
  done
  return 0
}

# The consolidated workflow opens clients for every lane in one process. Export the four names used by
# project.yaml from the canonical machine bindings while honoring an explicit Foundry alias.
cre_env_export_all_l2_rpcs() {
  local net upper alias remote value
  cre_env_load_rpc_bindings
  for net in optimism arbitrum base linea; do
    upper="$(printf '%s' "$net" | tr '[:lower:]' '[:upper:]')"
    alias="L2_${upper}_RPC_URL"
    remote="RPC_${upper}_REMOTE"
    value="${!alias:-${!remote:-}}"
    [[ -n "$value" ]] \
      || cre_env_die "no $net RPC. Set $remote in the root .env (or export $alias)." || return 1
    export "$alias=$value"
  done
}

# Ethereum-mainnet RPC for LIVE reads/writes. Precedence: the explicit repo binding first, then the
# upstream machine var, and the local fork proxy LAST — it is frequently down and serves a fork, so it
# must never silently win for a mainnet operation (it stays the default only in the fork/anvil recipes,
# which set it themselves).
resolve_l1_rpc() {
  cre_env_load_rpc_bindings
  local url="${L1_RPC_URL:-${RPC_ETHEREUM_REMOTE:-${RPC_ETHEREUM:-}}}"
  [[ -n "$url" ]] || cre_env_die "no Ethereum-mainnet RPC. Set L1_RPC_URL in .env.<network> (bound to \${RPC_ETHEREUM_REMOTE})." || return 1
  printf '%s\n' "$url"
}

# Authentication key for the CRE CLI; both supported variable spellings resolve here.
resolve_automation_owner_key() {
  cre_env_load_secrets
  local key="${L2_AUTOMATION_OWNER_PRIVATE_KEY:-${L2_AUTOMATION_OWNER_PK:-}}"
  [[ -n "$key" ]] \
    || cre_env_die "Automation Owner key missing. Set L2_AUTOMATION_OWNER_PRIVATE_KEY (or L2_AUTOMATION_OWNER_PK) in the root .env — NOT CRE_ETH_PRIVATE_KEY, which is derived from it." || return 1
  printf '%s\n' "$key"
}

# Export everything the `cre` CLI and cre-workflows/project.yaml interpolate:
#   CRE_ETH_PRIVATE_KEY   ← L2_AUTOMATION_OWNER_PRIVATE_KEY / _PK
#   CRE_WORKFLOW_OWNER    ← an explicit value if set, else L2_AUTOMATION_OWNER
#   L1_RPC_URL            ← resolve_l1_rpc
#   L2_<NET>_RPC_URL      ← L2_RPC_URL (Foundry alias read by fork-test helpers)
#
# Aborts when the declared owner address and the signing key are different accounts: registering a
# workflow under an address the DON will not sign as bricks every report at the CREReceiver author gate.
cre_env_export() {
  local key owner derived net upper alias
  cre_env_load_secrets
  key="$(resolve_automation_owner_key)" || return 1
  owner="${CRE_WORKFLOW_OWNER:-${L2_AUTOMATION_OWNER:-}}"
  [[ "$owner" =~ ^0x[0-9a-fA-F]{40}$ ]] \
    || cre_env_die "workflow owner must be a 0x+40-hex address; got '${owner}'. Set L2_AUTOMATION_OWNER in the root .env (or CRE_WORKFLOW_OWNER to override)." || return 1
  [[ "$owner" != "0x0000000000000000000000000000000000000000" ]] \
    || cre_env_die "refusing the zero address as workflow owner" || return 1

  command -v cast >/dev/null 2>&1 || cre_env_die "missing 'cast' (foundry) — needed to cross-check the key against the address" || return 1
  derived="$(cast wallet address --private-key "$key" 2>/dev/null || true)"
  [[ -n "$derived" ]] || cre_env_die "could not derive an address from the Automation Owner key — is it a valid 0x-prefixed private key?" || return 1
  if [[ "$(cast to-check-sum-address "$derived")" != "$(cast to-check-sum-address "$owner")" ]]; then
    cre_env_die "key/address mismatch — the Automation Owner key signs as $derived but the declared owner is $owner. Fix L2_AUTOMATION_OWNER or the key in the root .env; do not proceed." || return 1
  fi

  export CRE_ETH_PRIVATE_KEY="$key"
  export CRE_WORKFLOW_OWNER="$owner"
  # Deploy quota is scoped by DON family; use the same family as the registry checks.
  export CRE_CLI_DON_FAMILY="${CRE_CLI_DON_FAMILY:-zone-a}"
  # Assign first, THEN export: `export V="$(cmd)"` reports export's own status, so a failing
  # resolve_l1_rpc would be swallowed and an empty URL exported.
  local l1
  l1="$(resolve_l1_rpc)" || return 1
  export L1_RPC_URL="$l1"

  # Feed the per-lane alias consumed by Foundry and project.yaml from the lane overlay.
  net="${L2_NETWORK:-}"
  if [[ -n "$net" && -n "${L2_RPC_URL:-}" ]]; then
    upper="$(printf '%s' "$net" | tr '[:lower:]' '[:upper:]')"
    alias="L2_${upper}_RPC_URL"
    [[ -n "${!alias:-}" ]] || export "$alias=$L2_RPC_URL"
  fi

  echo "cre-env: workflow owner $CRE_WORKFLOW_OWNER (key verified) · L1 $(cre_env_host "$L1_RPC_URL")${net:+ · lane $net $(cre_env_host "${L2_RPC_URL:-}")}"
}

# Host-only rendering of an RPC URL — these carry API keys in the path, so never echo them whole.
cre_env_host() {
  local url="${1:-}"
  [[ -n "$url" ]] || { printf '%s' "(unset)"; return; }
  if [[ "$url" =~ ^(https?|wss?)://([^/?#]+) ]]; then
    printf '%s://%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]##*@}"
  else
    printf '%s' '(invalid URL)'
  fi
}
