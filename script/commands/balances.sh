#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
export LC_ALL=C # numeric report: never let a locale render decimal commas

MIN_WEI="${BALANCES_MIN_WEI:-10000000000000}"
# Derive labels and RPC variable names from NETS. Only L1 accounts appear in the Ethereum column.
NETS=(ethereum optimism arbitrum base linea)
ENTITIES=(LidoDeployer LidoCustomReceiver "Automation Owner" SyncTrigger CustomSender OraclePool)
ASSETS=(ETH WETH wstETH)
declare -a NAMES
for net in "${NETS[@]}"; do
  u="$(echo "$net" | tr '[:lower:]' '[:upper:]')"
  NAMES+=("${u:0:1}${net:1}")
done

# Display precision follows the threshold (1e13 wei -> 5 places), derived once for the whole run.
PLACES=18
t="$MIN_WEI"
while ((t > 0 && t % 10 == 0 && PLACES > 0)); do
  t=$((t / 10))
  PLACES=$((PLACES - 1))
done

# RPC order: L2_<NET>_RPC_URL → RPC_<NET>_REMOTE → RPC_<NET>.
# Ethereum uses L1_RPC_URL as its override.
rpc_for() {
  local net="$1" u override v
  u="$(echo "$net" | tr '[:lower:]' '[:upper:]')"
  if [[ "$net" == ethereum ]]; then
    override="L1_RPC_URL"
  else
    override="L2_${u}_RPC_URL"
  fi
  for v in "$override" "RPC_${u}_REMOTE" "RPC_${u}"; do
    if [[ -n "${!v:-}" ]]; then
      printf '%s' "${!v}"
      return
    fi
  done
}

# Return wei, or empty on a failed read. Strip cast's scientific-notation suffix.
read_wei() {
  local addr="$1" rpc="$2" asset="$3" token="$4" out=""
  if [[ -n "$rpc" ]]; then
    if [[ "$asset" == ETH ]]; then
      out="$(cast balance "$addr" --rpc-url "$rpc" 2>/dev/null || true)"
    elif [[ -n "$token" ]]; then
      out="$(cast call "$token" 'balanceOf(address)(uint256)' "$addr" --rpc-url "$rpc" 2>/dev/null || true)"
    fi
  fi
  printf '%s' "${out%% *}"
}

# Return a formatted amount, empty below threshold, or "?" on read failure.
# Compare decimal strings: wei balances can overflow Bash's signed 64-bit arithmetic.
format_balance() {
  local wei="$1"
  [[ "$wei" =~ ^[0-9]+$ ]] || {
    printf '?'
    return
  }
  if ((${#wei} < ${#MIN_WEI})) || { ((${#wei} == ${#MIN_WEI})) && [[ "$wei" < "$MIN_WEI" ]]; }; then
    return 0
  fi
  printf '%.*f' "$PLACES" "$(cast from-wei "$wei")"
}

# Emit net/entity/asset/value rows. Unresolved addresses render as "-" without an RPC read.
record_address() {
  local net="$1" entity="$2" addr="$3" rpc="$4" weth="$5" wsteth="$6"
  local asset token value
  [[ "$addr" != null ]] || addr=""
  for asset in "${ASSETS[@]}"; do
    [[ "$asset" == wstETH ]] && token="$wsteth" || token="$weth"
    value=""
    [[ -z "$addr" ]] || value="$(format_balance "$(read_wei "$addr" "$rpc" "$asset" "$token")")"
    printf '%s\t%s\t%s\t%s\n' "$net" "$entity" "$asset" "$value"
  done
}

# Read deployed addresses from .deployed.yaml and tokens/actors from inputs.
# Recursive yq finds anchored list items; [..][0] preserves query order and yields null if missing.
collect_ethereum() {
  local rpc="$1" weth wsteth receiver deployer
  {
    IFS= read -r weth
    IFS= read -r wsteth
    IFS= read -r receiver
  } < <(yq '
    [.. | select(anchor=="l1Weth")][0],
    [.. | select(anchor=="l1Wsteth")][0],
    [.. | select(anchor=="l1LidoCustomReceiver")][0]' config/state/ethereum.inputs.yaml)
  # The deployer is shared across chains; read its common L2 anchor for the L1 row too.
  deployer="$(just _l2-input-anchor optimism l2LidoDeployer)"
  record_address ethereum LidoDeployer "$deployer" "$rpc" "$weth" "$wsteth"
  record_address ethereum LidoCustomReceiver "$receiver" "$rpc" "$weth" "$wsteth"
}

collect_lane() {
  local net="$1" rpc="$2" weth wsteth deployer sender owner trigger pool
  {
    IFS= read -r weth
    IFS= read -r wsteth
    IFS= read -r sender
  } < <(yq '
    [.. | select(anchor=="l2Weth")][0],
    [.. | select(anchor=="l2Wsteth")][0],
    [.. | select(anchor=="l2CustomSender")][0]' "config/state/${net}.inputs.yaml")
  deployer="$(just _l2-input-anchor "$net" l2LidoDeployer)"
  owner="$(just _l2-input-anchor "$net" l2AutomationOwner)"
  {
    IFS= read -r trigger
    IFS= read -r pool
  } < <(yq '
    [.. | select(anchor=="l2SyncTrigger")][0],
    [.. | select(anchor=="l2OraclePool")][0]' "config/state/${net}.deployed.yaml")
  [[ -n "$owner" && "$owner" != null ]] || owner="${L2_AUTOMATION_OWNER:-}"
  record_address "$net" LidoDeployer "$deployer" "$rpc" "$weth" "$wsteth"
  record_address "$net" "Automation Owner" "$owner" "$rpc" "$weth" "$wsteth"
  record_address "$net" SyncTrigger "$trigger" "$rpc" "$weth" "$wsteth"
  record_address "$net" CustomSender "$sender" "$rpc" "$weth" "$wsteth"
  record_address "$net" OraclePool "$pool" "$rpc" "$weth" "$wsteth"
}

# Collect each network in parallel.
outdir="$(mktemp -d)"
trap 'rm -rf "$outdir"' EXIT
for net in "${NETS[@]}"; do
  rpc="$(rpc_for "$net")"
  {
    case "$net" in
      ethereum) expected_chain_id=1 ;;
      optimism) expected_chain_id=10 ;;
      arbitrum) expected_chain_id=42161 ;;
      base) expected_chain_id=8453 ;;
      linea) expected_chain_id=59144 ;;
    esac
    chain_id=$(cast chain-id --rpc-url "$rpc" 2>/dev/null) || exit 1
    if [[ "$chain_id" != "$expected_chain_id" ]]; then
      echo "balances: $net RPC chain-id $chain_id, expected $expected_chain_id" >&2
      exit 1
    fi
    cast block-number --rpc-url "$rpc" >"$outdir/$net.block" 2>/dev/null || true
    if [[ "$net" == ethereum ]]; then
      collect_ethereum "$rpc"
    else
      collect_lane "$net" "$rpc"
    fi
  } >"$outdir/$net.rows" &
done
wait
for net in "${NETS[@]}"; do
  [[ -s "$outdir/$net.rows" ]] || {
    echo "balances: could not collect $net (see errors above)" >&2
    exit 1
  }
done

# Group by network/account/asset and size the table columns to fit.
cat "$outdir"/*.rows | awk -F '\t' \
  -v netlist="$(
    IFS=$'\t'
    printf '%s' "${NETS[*]}"
  )" \
  -v namelist="$(
    IFS=$'\t'
    printf '%s' "${NAMES[*]}"
  )" \
  -v entlist="$(
    IFS=$'\t'
    printf '%s' "${ENTITIES[*]}"
  )" \
  -v astlist="$(
    IFS=$'\t'
    printf '%s' "${ASSETS[*]}"
  )" '
  function put(r, c, k, s) {          # k-th physical line of cell (r, c)
    cell[r, c, k] = s
    if (k > lines[r]) lines[r] = k
    if (length(s) > width[c]) width[c] = length(s)
  }
  function emit(r,   k, c) {
    for (k = 1; k <= lines[r]; k++) {
      printf "|"
      for (c = 1; c <= ncol; c++) printf " %-*s |", width[c], cell[r, c, k]
      printf "\n"
    }
  }
  BEGIN {
    nnet = split(netlist, net, FS); split(namelist, name, FS)
    nent = split(entlist, ent, FS); nast = split(astlist, ast, FS)
    ncol = nnet + 1
  }
  { value[$1 FS $2 FS $3] = $4 }
  END {
    put(1, 1, 1, "Account")
    for (c = 1; c <= nnet; c++) put(1, c + 1, 1, name[c])
    for (r = 1; r <= nent; r++) {
      put(r + 1, 1, 1, ent[r])
      for (c = 1; c <= nnet; c++) {
        k = 0
        for (a = 1; a <= nast; a++) {
          v = value[net[c] FS ent[r] FS ast[a]]
          if (v != "") put(r + 1, c + 1, ++k, ast[a] " " v)
        }
        if (k == 0) put(r + 1, c + 1, 1, "-")
      }
    }
    rule = "+"
    for (c = 1; c <= ncol; c++) rule = rule sprintf("%*s+", width[c] + 2, "")
    gsub(/ /, "-", rule)
    print rule
    for (r = 1; r <= nent + 1; r++) { emit(r); print rule }
  }
'
echo
blocks=""
for i in "${!NETS[@]}"; do
  block="$(cat "$outdir/${NETS[$i]}.block" 2>/dev/null || true)"
  blocks="${blocks}${blocks:+, }${NAMES[$i]} ${block:-?}"
done
echo "Blocks: $blocks"
echo "Threshold: all balances >= $(format_balance "$MIN_WEI")."
echo 'Legend: - = no balance at/above threshold or not applicable; TOKEN ? = balance read failed.'
