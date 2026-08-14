#!/usr/bin/env bash
# Derive the env spellings external tools insist on from THIS repo's canonical variables.
# SOURCE this file, do not execute it.
#
#   source script/shared/cre-env.sh
#   cre_env_export                 # exports CRE_ETH_PRIVATE_KEY / CRE_WORKFLOW_OWNER / L1_RPC_URL / L2_<NET>_RPC_URL
#   L1_RPC_URL="$(resolve_l1_rpc)" # just the L1 URL, for recipes that need nothing else
#
# Why: the same fact used to be stored twice under two names — the Automation Owner key as both
# `L2_AUTOMATION_OWNER_PK` (forge scripts) and `CRE_ETH_PRIVATE_KEY` (cre CLI), and RPC URLs under four
# spellings. Hand-copied duplicates rot: rotate one, the other keeps signing with the old key. Here the
# aliases are DERIVED in-process, never written to a file, and every failure message names the canonical
# variable to fix rather than the alias that happened to be empty.
#
# Canonical variables (see RUNBOOK "Env model"):
#   secrets, root .env         L2_AUTOMATION_OWNER_PRIVATE_KEY (or _PK) · L2_AUTOMATION_OWNER
#   lane facts, .env.<network> L2_NETWORK · L2_RPC_URL
#   machine, shell profile     RPC_ETHEREUM_REMOTE (upstream) · RPC_ETHEREUM (local fork proxy)
#
# L1_RPC_URL is NOT a fourth store: root .env declares it as `${RPC_ETHEREUM_REMOTE}`, an indirection
# that only `just`'s dotenv expands. So it cannot join the cre_env_load_secrets list below (which takes
# values literally, and would hand out the string `${RPC_ETHEREUM_REMOTE}` verbatim), and a plain script
# that sources this file resolves mainnet from RPC_ETHEREUM_REMOTE in the shell profile. When that is
# unset, resolve_l1_rpc falls through to the local FORK proxy — which is why anything that writes to
# mainnet must call cre_env_require_live_mainnet rather than trusting the resolution.

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
# Necessary because `just -E .env.<network>` REPLACES the dotenv path rather than adding to it: the
# justfile's `set dotenv-filename := [".env", x'.env.${NETWORK:-}']` loads both files, but the `-E` form
# — which every runbook and recipe comment uses — loads only the named one, so the root .env's keys are
# absent. Rather than retire that convention (or, worse, put a second copy of the key in each
# .env.<network>), fill the gap here: `just -E .env.<net> …` and `NETWORK=<net> just …` then behave
# identically.
#
# Deliberately narrow: only the secrets-tier names below, only when unset (a value already in the
# environment always wins), values taken literally with no expansion — the root .env holds plain
# literals, unlike .env.<network> whose RPC bindings reference ${RPC_*} and need just's own expansion.
cre_env_load_secrets() {
  local dotenv name value
  dotenv="$(cre_env_root)/.env"
  [[ -f "$dotenv" ]] || return 0
  for name in L2_AUTOMATION_OWNER L2_AUTOMATION_OWNER_PRIVATE_KEY L2_AUTOMATION_OWNER_PK \
              DEPLOYER L2_LIDO_DEPLOYER_PRIVATE_KEY INITIAL_OWNER_PRIVATE_KEY \
              ETHERSCAN_API_KEY GITHUB_API_TOKEN; do
    [[ -z "${!name:-}" ]] || continue
    value="$(grep -m1 "^[[:space:]]*${name}=" "$dotenv" 2>/dev/null | cut -d= -f2- | tr -d '"'"'"'\r' | xargs 2>/dev/null || true)"
    [[ -n "$value" ]] && export "$name=$value"
  done
  return 0
}

# Ethereum-mainnet RPC for LIVE reads/writes. Precedence: the explicit repo binding first, then the
# upstream machine var, and the local fork proxy LAST — it is frequently down and serves a fork, so it
# must never silently win for a mainnet operation (it stays the default only in the fork/anvil recipes,
# which set it themselves).
resolve_l1_rpc() {
  local url="${L1_RPC_URL:-${RPC_ETHEREUM_REMOTE:-${RPC_ETHEREUM:-}}}"
  [[ -n "$url" ]] || cre_env_die "no Ethereum-mainnet RPC. Export RPC_ETHEREUM_REMOTE in your shell profile (root .env binds L1_RPC_URL to it, but only under \`just\`)." || return 1
  printf '%s\n' "$url"
}

# Prove the resolved endpoint is LIVE Ethereum mainnet before a ceremony writes to it.
#
# resolve_l1_rpc's precedence is a preference, not a proof: when RPC_ETHEREUM_REMOTE is unset the local
# fork proxy wins silently, and a fork cannot be told from mainnet by chain-id — `anvil -f` reports 1.
# The discriminator is head freshness: a fork is pinned at its fork block and advances only when
# something mines on it. Anything mainnet-writing calls this instead of trusting the resolution; reads
# and fork-scoped recipes deliberately do not.
cre_env_require_live_mainnet() {
  local url="${1:-}" id ts age
  [[ -n "$url" ]] || cre_env_die "cre_env_require_live_mainnet: no URL given" || return 1
  id="$(cast chain-id --rpc-url "$url" 2>/dev/null | tr -d ' \r' || true)"
  [[ "$id" == 1 ]] \
    || cre_env_die "L1 endpoint $(cre_env_host "$url") reports chain-id '${id:-<unreachable>}', not 1" || return 1
  ts="$(cast block latest --field timestamp --rpc-url "$url" 2>/dev/null | tr -d ' \r' || true)"
  [[ "$ts" =~ ^[0-9]+$ ]] \
    || cre_env_die "could not read the head block timestamp from $(cre_env_host "$url")" || return 1
  age=$(( $(date +%s) - ts ))
  (( age >= 0 && age < ${CRE_L1_MAX_HEAD_AGE:-900} )) \
    || cre_env_die "L1 head at $(cre_env_host "$url") is ${age}s old — a pinned fork or a stalled node, not live mainnet. This step writes to mainnet; refusing." || return 1
  echo "cre-env: L1 $(cre_env_host "$url") is live mainnet (head ${age}s old)." >&2
}

# The Automation Owner signing key, read with the SAME name-and-fallback order as
# `_envAutomationOwnerPrivateKey()` in script/shared/L2UpgradeScriptBase.s.sol, so forge and the CLI
# cannot disagree about which key belongs to the Automation Owner.
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
#   L2_<NET>_RPC_URL      ← L2_RPC_URL (legacy per-lane spelling the forge fork-test helpers read)
#
# Aborts when the declared owner address and the signing key are different accounts: registering a
# workflow under an address the DON will not sign as bricks every report at the CREReceiver author gate.
#
# One predicate, two shapes of owner — "the declared owner is controllable from here":
#   owner == the key's address  → an EOA the key signs for.
#   owner != the key's address  → it must be a CONTRACT on mainnet (a Safe) AND the run must be
#                                 unsigned, because the `cre` CLI can then only PRINT the
#                                 WorkflowRegistry calldata for the Safe to execute (ADR-0001).
# CRE_ETH_PRIVATE_KEY stays required and exported on both: the CLI needs a wallet to initialise its RPC
# client. On the Safe shape it never signs the owner transaction.
cre_env_export() {
  local key owner derived net upper alias mode code l1
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

  l1="$(resolve_l1_rpc)" || return 1
  mode="key verified"
  if [[ "$(cast to-check-sum-address "$derived")" != "$(cast to-check-sum-address "$owner")" ]]; then
    [[ "${CRE_DEPLOY_UNSIGNED:-false}" == "true" ]] \
      || cre_env_die "key/address mismatch — the Automation Owner key signs as $derived but the declared owner is $owner. Fix L2_AUTOMATION_OWNER or the key in the root .env; do not proceed. (Registering under a Safe? That is the CRE_DEPLOY_UNSIGNED=true path.)" || return 1
    # Code check on the SAME chain the WorkflowRegistry lives on (Ethereum mainnet): an address with code
    # on an L2 and none on L1 is exactly the cross-chain mix-up this catches. Unreadable ≠ disproved, so
    # an RPC that cannot answer warns rather than stranding the operator on a read they cannot fix.
    code="$(cast code "$owner" --rpc-url "$l1" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ "$code" == "0x" ]]; then
      cre_env_die "$owner has NO code on Ethereum mainnet — it is an EOA or a typo, not a Safe. The workflow owner is fixed at registration and cannot be transferred; do not proceed." || return 1
    elif [[ -z "$code" ]]; then
      echo "cre-env: WARNING — could not read code at $owner on Ethereum mainnet (RPC unreachable?). Unable to confirm it is a multisig; verify by hand before executing the calldata." >&2
    fi
    mode="multisig, unsigned"
    echo "cre-env: CRE_ETH_PRIVATE_KEY ($derived) is used for RPC init only and will NOT sign the owner tx." >&2
  fi

  export CRE_ETH_PRIVATE_KEY="$key"
  export CRE_WORKFLOW_OWNER="$owner"
  # DON family. Previously expressed as `cre-cli: don-family: "zone-a"` in project.yaml, which the pinned
  # CLI does not read (no such settings key — it was silently ignored); the CLI takes it from this
  # environment variable. Kept explicit rather than left to a CLI default because the Automation Owner's
  # deploy quota is granted PER DON FAMILY — `just env-doctor` reads
  # `getMaxWorkflowsPerUserDON(owner, zone-a)`, and a workflow registered on a different family than the
  # one that check reports would make that evidence meaningless.
  export CRE_CLI_DON_FAMILY="${CRE_CLI_DON_FAMILY:-zone-a}"
  # Assigned above (not `export V="$(cmd)"`, which reports export's own status and would swallow a
  # failing resolve_l1_rpc, exporting an empty URL).
  export L1_RPC_URL="$l1"

  # Legacy per-lane spelling: project.yaml no longer needs it (it reads ${L2_RPC_URL}), but the forge
  # fork-test helpers still do, so keep them fed from the same canonical value when they are unset.
  net="${L2_NETWORK:-}"
  if [[ -n "$net" && -n "${L2_RPC_URL:-}" ]]; then
    upper="$(printf '%s' "$net" | tr '[:lower:]' '[:upper:]')"
    alias="L2_${upper}_RPC_URL"
    [[ -n "${!alias:-}" ]] || export "$alias=$L2_RPC_URL"
  fi

  echo "cre-env: workflow owner $CRE_WORKFLOW_OWNER ($mode) · L1 $(cre_env_host "$L1_RPC_URL")${net:+ · lane $net $(cre_env_host "${L2_RPC_URL:-}")}"
}

# Host-only rendering of an RPC URL — these carry API keys in the path, so never echo them whole.
cre_env_host() {
  local url="${1:-}"
  [[ -n "$url" ]] || { printf '%s' "(unset)"; return; }
  printf '%s' "$(printf '%s' "$url" | sed -E 's#^([a-z]+://[^/]+).*#\1#')"
}
