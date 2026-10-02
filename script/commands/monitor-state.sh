#!/usr/bin/env bash
# Run the checked-in expected state (config/state) against live RPCs with state-mate.
#
#   script/commands/monitor-state.sh <ethereum|optimism|arbitrum|base|linea|all>
#
# Environment:
#   STATE_MATE_DIR         state-mate checkout with dependencies installed (default: lib/state-mate)
#   L1_RPC_URL             Ethereum RPC; falls back to RPC_ETHEREUM_REMOTE. Required for `ethereum`.
#                          For an L2 lane it enables the shared WorkflowRegistry check (l2.yaml `l1:`);
#                          without it the lane run is restricted to `--only l2` and says so.
#   L2_STATE_MATE_RPC_URL  highest-priority RPC override for ONE lane run (ignored by `all`)
#   L2_<NET>_RPC_URL       lane RPC; then RPC_<NET>_REMOTE; then the network's public RPC
#
# Every configured run executes even after a failure; the exit code is nonzero if any run failed.
# The scripts do not load a repository .env file; export overrides in the invoking shell.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config/state"
STATE_MATE_DIR="${STATE_MATE_DIR:-$ROOT_DIR/lib/state-mate}"

usage() {
  echo 'Usage: script/commands/monitor-state.sh <ethereum|optimism|arbitrum|base|linea|all>' >&2
  exit 2
}
[[ $# -eq 1 ]] || usage
case "$1" in
  --help|-h) usage ;;
  ethereum|optimism|arbitrum|base|linea|all) TARGET="$1" ;;
  *) echo "Unknown network: $1" >&2; usage ;;
esac

[[ -d "$STATE_MATE_DIR" ]] || { echo "STATE_MATE_DIR does not exist: $STATE_MATE_DIR" >&2; exit 2; }
STATE_MATE_DIR="$(cd "$STATE_MATE_DIR" && pwd)"
command -v node >/dev/null 2>&1 || { echo "Missing required command: node" >&2; exit 2; }
if [[ ! -d "$STATE_MATE_DIR/node_modules" ]]; then
  if command -v corepack >/dev/null 2>&1; then
    echo "Installing state-mate dependencies in $STATE_MATE_DIR"
    (cd "$STATE_MATE_DIR" && corepack yarn install --immutable) || exit 2
  else
    echo "state-mate dependencies are missing in $STATE_MATE_DIR (run yarn install there)" >&2
    exit 2
  fi
fi

L1_RPC="${L1_RPC_URL:-${RPC_ETHEREUM_REMOTE:-}}"

public_rpc() {
  case "$1" in
    optimism) echo 'https://mainnet.optimism.io' ;;
    arbitrum) echo 'https://arb1.arbitrum.io/rpc' ;;
    base)     echo 'https://mainnet.base.org' ;;
    linea)    echo 'https://rpc.linea.build' ;;
  esac
}

# Resolve the lane RPC: single-lane override (when allowed), lane variable, machine upstream, public.
lane_rpc() {
  local net="$1" allow_override="$2" upper rpc_var remote_var
  upper="$(printf '%s' "$net" | tr '[:lower:]' '[:upper:]')"
  rpc_var="L2_${upper}_RPC_URL"; remote_var="RPC_${upper}_REMOTE"
  if [[ "$allow_override" == 1 && -n "${L2_STATE_MATE_RPC_URL:-}" ]]; then
    echo "$L2_STATE_MATE_RPC_URL"
  else
    echo "${!rpc_var:-${!remote_var:-$(public_rpc "$net")}}"
  fi
}

# state_mate <config> <args...>; RPC URLs come from the environment (L1_RPC_URL / L2_STATE_MATE_RPC_URL).
state_mate() {
  local config="$1"; shift
  echo "+ state-mate ${config#"$ROOT_DIR"/} $*"
  (
    cd "$STATE_MATE_DIR"
    # Explicit project root supports the TypeScript 6 / ts-node combination.
    env -u NO_COLOR FORCE_COLOR=3 CLICOLOR_FORCE=1 node -e '
      require("ts-node").register({ compilerOptions: { rootDir: "." } });
      require("tsconfig-paths/register");
      process.argv = [process.argv[0], "state-mate", ...process.argv.slice(1)];
      require("./src/state-mate");' "$config" "$@"
  )
}

FAILED=()
record() { # record <label> <exit>
  if [[ "$2" -eq 0 ]]; then echo "$1: PASS"; else echo "$1: FAIL (exit $2)" >&2; FAILED+=("$1"); fi
}

run_ethereum() {
  printf '\n== ethereum (config/state/ethereum.yaml) ==\n'
  if [[ -z "$L1_RPC" ]]; then
    echo "ethereum: FAIL (set L1_RPC_URL or RPC_ETHEREUM_REMOTE)" >&2; FAILED+=("ethereum"); return
  fi
  L1_RPC_URL="$L1_RPC" state_mate "$CONFIG_DIR/ethereum.yaml" \
    --inputs "$CONFIG_DIR/ethereum.inputs.yaml" --only l1
  record "ethereum" "$?"
}

run_lane() { # run_lane <net> <allow_single_lane_override>
  local net="$1" rpc only=()
  rpc="$(lane_rpc "$net" "$2")"
  printf '\n== %s (config/state/l2.yaml) ==\n' "$net"
  if [[ -z "$L1_RPC" ]]; then
    echo "WARN: no L1 RPC (L1_RPC_URL / RPC_ETHEREUM_REMOTE); skipping the shared WorkflowRegistry check (--only l2)"
    only=(--only l2)
  fi
  L1_RPC_URL="${L1_RPC:-unused}" L2_STATE_MATE_RPC_URL="$rpc" state_mate "$CONFIG_DIR/l2.yaml" \
    --inputs "$CONFIG_DIR/common.inputs.yaml" --inputs "$CONFIG_DIR/$net.inputs.yaml" \
    --deployed "$CONFIG_DIR/common.deployed.yaml" --deployed "$CONFIG_DIR/$net.deployed.yaml" \
    ${only[@]+"${only[@]}"}
  record "$net" "$?"
  if [[ "$net" == linea ]]; then
    printf '\n== linea (config/state/l2-linea-gelato.yaml) ==\n'
    L2_STATE_MATE_RPC_URL="$rpc" state_mate "$CONFIG_DIR/l2-linea-gelato.yaml" --only l2
    record "linea (gelato)" "$?"
  fi
}

case "$TARGET" in
  ethereum) run_ethereum ;;
  all)
    if [[ -n "$L1_RPC" ]]; then run_ethereum; else echo "WARN: no L1 RPC; skipping the ethereum run"; fi
    for net in optimism arbitrum base linea; do run_lane "$net" 0; done
    ;;
  *) run_lane "$TARGET" 1 ;;
esac

echo
if (( ${#FAILED[@]} > 0 )); then
  echo "monitor-state failed for: ${FAILED[*]}" >&2
  exit 1
fi
echo "monitor-state passed for $TARGET"
