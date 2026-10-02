# https://just.systems

# Load multiple dotenv files: shared `.env` (secrets/keys) PLUS the per-network
# `.env.${NETWORK}` overlay (https://github.com/casey/just/issues/1748). List values
# for dotenv settings require `set lists`, which is gated behind `set unstable`.
# Select the overlay with e.g. `NETWORK=optimism just <recipe>`; when NETWORK is
# unset the path degrades to `.env.` (a missing file just silently skips).
set unstable
set lists := true
set dotenv-load
set dotenv-filename := [".env", x'.env.${NETWORK:-}']

# Pinned Chainlink CRE CLI release (https://github.com/smartcontractkit/cre-cli/releases).
# `setup-cre-cli` installs exactly this tag into `CRE_DIR` (gitignored, inside the repo — the
# upstream installer would write to $HOME and edit your shell rc). Bump the tag here and re-run
# `just setup-cre-cli`; the recipe is a no-op when the installed binary already reports it.
CRE_CLI_VERSION := "v1.27.0"
CRE_DIR := justfile_directory() / ".cre"

# Default recipe: list all available recipes (runs on bare `just`).
default:
    @just --list

# Helper: map L2 network name → forge `<file>:<contract>` target for fee configuration checks.
[private]
_l2-config-target network:
    #!/usr/bin/env bash
    case "{{network}}" in
      optimism) echo "script/optimism/OptimismConfig.s.sol:OptimismConfigScript" ;;
      arbitrum) echo "script/arbitrum/ArbitrumConfig.s.sol:ArbitrumConfigScript" ;;
      base)     echo "script/base/BaseConfig.s.sol:BaseConfigScript" ;;
      linea)    echo "script/linea/LineaConfig.s.sol:LineaConfigScript" ;;
      *) echo "Unknown network: {{network}} (expected: optimism|arbitrum|base|linea)" >&2; exit 2 ;;
    esac

# Install chainlink-csr dependencies (run once after clone)
setup:
    cd lib/chainlink-csr && npm install --ignore-scripts && forge install

# Check live lane identity, active pool wiring/balances, recent syncs, and the CCIP gas ceiling.
# Reads config/state/; requires L2_NETWORK + L2_RPC_URL, no signing keys.
# Usage: NETWORK=<network> just preflight-check
preflight-check:
    @bash "{{justfile_directory()}}/script/commands/preflight-check.sh"

# Check live Ethereum chain identity and the configured L2 sender/adapter wiring.
# Requires L2_NETWORK and an L1 RPC resolved by script/shared/cre-env.sh.
preflight-check-l1:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    source "{{justfile_directory()}}/script/shared/cre-env.sh"
    L1_RPC_URL="$(resolve_l1_rpc)"

    case "$L2_NETWORK" in
      optimism) L2_CHAIN_SELECTOR=3734403246176062136  ; EXPECTED_SENDER=0x328de900860816d29D1367F6903a24D8ed40C997 ;;
      arbitrum) L2_CHAIN_SELECTOR=4949039107694359620  ; EXPECTED_SENDER=0x72229141D4B016682d3618ECe47c046f30Da4AD1 ;;
      base)     L2_CHAIN_SELECTOR=15971525489660198786 ; EXPECTED_SENDER=0x328de900860816d29D1367F6903a24D8ed40C997 ;;
      linea)    L2_CHAIN_SELECTOR=4627098889531055414  ; EXPECTED_SENDER=0x328de900860816d29D1367F6903a24D8ed40C997 ;;
      *) echo "Unknown L2_NETWORK: $L2_NETWORK (expected: optimism|arbitrum|base|linea)" >&2; exit 2 ;;
    esac

    L1_RECEIVER=0x6F357d53d6bE3238180316BA5F8f11467e164588
    EXPECTED_CHAIN_ID=1
    ZERO_ADDR=0x0000000000000000000000000000000000000000

    # ── Output coloring (auto-off when stdout isn't a TTY or NO_COLOR is set); same idiom as
    # preflight-check. This L1 gate has no advisory WARNs — every check either PASSes or dies.
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
      C_RST=$'\033[0m'; C_HDR=$'\033[1;36m'; C_STEP=$'\033[1m'; C_PASS=$'\033[1;32m'; C_FAIL=$'\033[1;31m'; C_DIM=$'\033[2m'
    else
      C_RST=''; C_HDR=''; C_STEP=''; C_PASS=''; C_FAIL=''; C_DIM=''
    fi
    PASS_N=0
    hdr()  { printf '%s%s%s\n' "$C_HDR"  "$*" "$C_RST"; }                                    # banner / title (bold cyan)
    step() { printf '%s%s%s\n' "$C_STEP" "$*" "$C_RST"; }                                    # "[n/4] CHECK ..." (bold)
    pass() { PASS_N=$((PASS_N+1)); printf '      %sPASS%s %s\n' "$C_PASS" "$C_RST" "$*"; }   # green keyword (tallied)
    cmd()  { printf '      %scmd:%s %s\n' "$C_DIM"  "$C_RST" "$*"; }                          # dim — example cast invocation
    die()  { printf '%sL1 PREFLIGHT FAIL:%s %s\n' "$C_FAIL" "$C_RST" "$*" >&2; exit 1; }     # red, to stderr, exit 1
    norm() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

    hdr "===================================================================="
    hdr "L1 PREFLIGHT CHECK: $L2_NETWORK"
    echo "  L1 RPC URL:            $L1_RPC_URL"
    echo "  Expected chain-id:     $EXPECTED_CHAIN_ID (Ethereum Mainnet)"
    echo "  L1 LidoCustomReceiver: $L1_RECEIVER"
    echo "  L2 CCIP selector:      $L2_CHAIN_SELECTOR"
    echo "  Expected L2 sender:    $EXPECTED_SENDER"
    hdr "===================================================================="

    step "[1/4] CHECK L1 RPC chain-id matches Ethereum Mainnet ($EXPECTED_CHAIN_ID)"
    cmd "cast chain-id --rpc-url <l1-rpc>"
    actual_chain_id=$(cast chain-id --rpc-url "$L1_RPC_URL")
    if [[ "$actual_chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
      die "L1 chain-id mismatch: got $actual_chain_id, expected $EXPECTED_CHAIN_ID"
    fi
    # RPC_ETHEREUM shares its name with the fork-test env (local anvil mainnet fork); a fork
    # preserves chain id 1, so the check above cannot tell fork from live. A stale head block
    # means a fork or badly lagging node — refuse to accept it as live state.
    head_ts=$(cast block latest --field timestamp --rpc-url "$L1_RPC_URL"); head_ts="${head_ts%%[*}"
    head_age=$(( $(date +%s) - head_ts ))
    if (( head_age > 600 )); then
      die "L1 RPC head block is ${head_age}s old — looks like a stale fork or lagging node, not live mainnet (check \$RPC_ETHEREUM)"
    fi
    pass "chain-id = $actual_chain_id (head block ${head_age}s old)"

    step "[2/4] CHECK L1 LidoCustomReceiver has bytecode at $L1_RECEIVER"
    cmd "cast code $L1_RECEIVER --rpc-url <l1-rpc>"
    code=$(cast code "$L1_RECEIVER" --rpc-url "$L1_RPC_URL")
    if [[ "$code" == "0x" || -z "$code" ]]; then
      die "L1 receiver $L1_RECEIVER has no code"
    fi
    pass "bytecode present at L1 receiver"

    step "[3/4] CHECK L1 receiver has non-zero adapter for L2 selector $L2_CHAIN_SELECTOR"
    cmd "cast call $L1_RECEIVER 'getAdapter(uint64)(address)' $L2_CHAIN_SELECTOR --rpc-url <l1-rpc>"
    adapter=$(cast call "$L1_RECEIVER" "getAdapter(uint64)(address)" "$L2_CHAIN_SELECTOR" --rpc-url "$L1_RPC_URL")
    if [[ "$(norm "$adapter")" == "$ZERO_ADDR" ]]; then
      die "no adapter set on L1 receiver for selector $L2_CHAIN_SELECTOR"
    fi
    pass "adapter = $adapter"

    step "[4/4] CHECK L1 receiver's sender for L2 selector $L2_CHAIN_SELECTOR matches $EXPECTED_SENDER"
    cmd "cast call $L1_RECEIVER 'getSender(uint64)(bytes)' $L2_CHAIN_SELECTOR --rpc-url <l1-rpc>"
    sender_bytes=$(cast call "$L1_RECEIVER" "getSender(uint64)(bytes)" "$L2_CHAIN_SELECTOR" --rpc-url "$L1_RPC_URL")
    sender_hex=${sender_bytes#0x}
    # An EVM CustomSender is stored as abi.encode(address) → 32-byte left-padded blob (64 hex chars).
    # Anything else means non-EVM encoding or unset; reject rather than silently slicing the wrong bytes.
    if [[ "${#sender_hex}" -ne 64 ]]; then
      die "unexpected sender encoding for selector $L2_CHAIN_SELECTOR: got ${#sender_hex} hex chars, expected 64 (raw: $sender_bytes)"
    fi
    decoded_sender="0x${sender_hex: -40}"
    if [[ "$(norm "$decoded_sender")" != "$(norm "$EXPECTED_SENDER")" ]]; then
      die "sender mismatch: got $decoded_sender, expected $EXPECTED_SENDER (raw bytes: $sender_bytes)"
    fi
    pass "sender = $decoded_sender (raw bytes: $sender_bytes)"

    hdr "===================================================================="
    printf '%sOK%s L1 preflight passed for %s — %s%d PASS, 0 WARN%s.\n' "$C_PASS" "$C_RST" "$L2_NETWORK" "$C_PASS" "$PASS_N" "$C_RST"
    hdr "===================================================================="

# Run the state-mate CLI over config/state against a simulated RPC, including drift and fault cases.
test-monitor-state:
    node script/commands/test-monitor-state.cjs

# Snapshot state checks from config/state: <ethereum|optimism|arbitrum|base|linea|all>. RPC precedence per
# network: L2_STATE_MATE_RPC_URL (single lane), L2_<NET>_RPC_URL, RPC_<NET>_REMOTE, public default;
# L1_RPC_URL or RPC_ETHEREUM_REMOTE for Ethereum and the shared WorkflowRegistry check.
monitor-state network:
    bash script/commands/monitor-state.sh "{{network}}"

# Check Solidity constants against state inputs, encoded fees, workflow budgets, and L1 preflight values.
# Offline; exits nonzero on drift.
verify-constants-sync:
    #!/usr/bin/env bash
    set -uo pipefail

    fail_count=0
    pass_count=0

    norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '"'; }

    expect_eq() {
      local what="$1" expected="$2" actual="$3"
      if [[ -z "$expected" ]]; then
        echo "      FAIL $what: Solidity constant not found (verifier mapping is broken)"
        fail_count=$(( fail_count + 1 ))
        return
      fi
      if [[ -z "$actual" ]]; then
        echo "      FAIL $what: missing in target (anchor/field renamed or removed)"
        fail_count=$(( fail_count + 1 ))
        return
      fi
      if [[ "$(norm "$expected")" != "$(norm "$actual")" ]]; then
        echo "      FAIL $what"
        echo "           expected (Solidity): $expected"
        echo "           actual   (target):   $actual"
        fail_count=$(( fail_count + 1 ))
      else
        echo "      PASS $what = $expected"
        pass_count=$(( pass_count + 1 ))
      fi
    }

    sol_addr() {
      grep -E "address[[:space:]]+internal[[:space:]]+constant[[:space:]]+$2[[:space:]]*=" "$1" 2>/dev/null \
        | sed -E 's/.*=[[:space:]]*(0x[a-fA-F0-9]+).*/\1/' | head -n1
    }
    sol_uint() {
      grep -E "(uint64|uint256)[[:space:]]+internal[[:space:]]+constant[[:space:]]+$2[[:space:]]*=" "$1" 2>/dev/null \
        | sed -E 's/.*=[[:space:]]*([0-9_]+).*/\1/' | tr -d '_' | head -n1
    }
    yml_anchor() {
      # Every anchor checked here is defined in the .deployed/.inputs files. The shared wiring l2.yaml only *references* them and cannot be
      # parsed standalone (dangling aliases → yq error), so scan the siblings when present; fall back
      # to the file itself only when it is self-contained (no siblings). `..` recurses every section.
      local base="${1%.yaml}" files=()
      case "$base" in
        config/state/optimism|config/state/arbitrum|config/state/base|config/state/linea)
          files+=("config/state/common.inputs.yaml")
          [[ -f "config/state/common.deployed.yaml" ]] && files+=("config/state/common.deployed.yaml")
          ;;
      esac
      [[ -f "$base.deployed.yaml" ]] && files+=("$base.deployed.yaml")
      [[ -f "$base.inputs.yaml" ]] && files+=("$base.inputs.yaml")
      [[ "${#files[@]}" -eq 0 ]] && files=("$1")
      yq ".. | select(anchor == \"$2\")" "${files[@]}" 2>/dev/null | tr -d '"' | head -n1
    }
    just_field() {
      awk -v net="$1" '
        $1 == net ")" { in_case = 1 }
        in_case { print }
        /;;/ { in_case = 0 }
      ' justfile \
        | grep -oE "[[:space:];]$2=[^[:space:];]+" | head -n1 | sed -E "s/^[[:space:];]$2=//"
    }
    just_global() {
      grep -hE "^[[:space:]]*$1=" justfile script/commands/*.sh \
        | sed -E 's/.*=[[:space:]]*"?(0x[a-fA-F0-9]+)"?.*/\1/' | sort -u
    }
    bytes32_to_addr() {
      local hex="${1#0x}"
      [[ "${#hex}" -eq 64 ]] || { printf '%s' "$1"; return; }
      printf '0x%s' "${hex: -40}"
    }

    L1_SOL=script/l1/L1Constants.sol
    L1_YAML=config/state/ethereum.yaml
    sol_l1_recv=$(sol_addr "$L1_SOL" L1_LIDO_CUSTOM_RECEIVER)
    sol_l1_recv_impl=$(sol_addr "$L1_SOL" L1_LIDO_CUSTOM_RECEIVER_IMPL)
    sol_initial_owner=$(sol_addr "$L1_SOL" INITIAL_OWNER)
    sol_dao_agent=$(sol_addr "$L1_SOL" LIDO_DAO_AGENT)
    sol_deployer=$(sol_addr "$L1_SOL" LIDO_DEPLOYER)
    sol_l1_proxy=$(sol_addr "$L1_SOL" L1_PROXY_ADMIN)
    sol_l1_weth=$(sol_addr "$L1_SOL" L1_WETH)
    sol_l1_wsteth=$(sol_addr "$L1_SOL" L1_WSTETH)
    sol_l1_router=$(sol_addr "$L1_SOL" L1_CCIP_ROUTER)
    sol_eth_selector=$(sol_uint "$L1_SOL" ETH_CCIP_CHAIN_SELECTOR)
    cre_don_family=$(sed -nE 's/.*CRE_CLI_DON_FAMILY:-([^}]*)}.*/\1/p' script/shared/cre-env.sh)

    echo "===================================================================="
    echo "VERIFY CONSTANTS SYNC"
    echo "  Source of truth: script/l1/L1Constants.sol"
    echo "                   script/{net}/{Net}Constants.sol"
    echo "  Compared targets:"
    echo "    - config/state/l2.yaml shared wiring (+ common.inputs.yaml / {net}.{inputs,deployed}.yaml)"
    echo "    - config/state/{net}.inputs.yaml fee blobs vs FeeCodec(constants)"
    echo "    - justfile preflight-check-l1 case blocks"
    echo "===================================================================="

    for net in optimism arbitrum base linea; do
      case "$net" in
        optimism) cap=Optimism ; upper=OPTIMISM ;;
        arbitrum) cap=Arbitrum ; upper=ARBITRUM ;;
        base)     cap=Base     ; upper=BASE ;;
        linea)    cap=Linea    ; upper=LINEA ;;
      esac
      sol="script/${net}/${cap}Constants.sol"
      # Resolve shared and lane-specific anchors through the input/deployed siblings.
      sm="config/state/${net}.yaml"

      sol_l2_sender=$(sol_addr   "$sol" L2_CUSTOM_SENDER)
      sol_l2_sender_impl=$(sol_addr "$sol" L2_CUSTOM_SENDER_IMPL)
      sol_l2_proxy=$(sol_addr    "$sol" L2_PROXY_ADMIN)
      sol_l2_oldsync=$(sol_addr  "$sol" L2_OLD_CHAINLINK_AUTOMATION)
      sol_l1_adapter=$(sol_addr  "$sol" "L1_${upper}_ADAPTER")
      sol_l2_weth=$(sol_addr     "$sol" L2_WETH)
      sol_l2_wsteth=$(sol_addr   "$sol" L2_WSTETH)
      sol_l2_link=$(sol_addr     "$sol" L2_LINK_TOKEN)
      sol_l2_router=$(sol_addr   "$sol" L2_CCIP_ROUTER)
      sol_l2_oracle=$(sol_addr   "$sol" L2_PRICE_ORACLE)
      sol_l2_gov=$(sol_addr      "$sol" LIDO_L2_GOVERNANCE_EXECUTOR)
      sol_l2_fwd=$(sol_addr      "$sol" CRE_FORWARDER)
      sol_l2_liq=$(sol_addr      "$sol" LIQUIDITY_OWNER)
      sol_chain_id=$(sol_uint    "$sol" "${upper}_CHAIN_ID")
      sol_l2_selector=$(sol_uint "$sol" "${upper}_CCIP_CHAIN_SELECTOR")
      cre_workflow_name=$(yq '.production.user-workflow.workflow-name' cre-workflows/sync-automation/workflow.yaml)

      echo
      echo "[$net] state-mate inputs: common.inputs.yaml + ${sm%.yaml}.inputs.yaml; deployed: common.deployed.yaml + ${sm%.yaml}.deployed.yaml"
      expect_eq "l2ChainId → ${upper}_CHAIN_ID"                                  "$sol_chain_id"      "$(yml_anchor "$sm" l2ChainId)"
      expect_eq "l2CustomSender → L2_CUSTOM_SENDER"                             "$sol_l2_sender"     "$(yml_anchor "$sm" l2CustomSender)"
      expect_eq "l2CustomSenderImpl → L2_CUSTOM_SENDER_IMPL"                    "$sol_l2_sender_impl" "$(yml_anchor "$sm" l2CustomSenderImpl)"
      expect_eq "l2ProxyAdmin → L2_PROXY_ADMIN"                                 "$sol_l2_proxy"      "$(yml_anchor "$sm" l2ProxyAdmin)"
      expect_eq "l2GovernanceExecutor → LIDO_L2_GOVERNANCE_EXECUTOR"             "$sol_l2_gov"        "$(yml_anchor "$sm" l2GovernanceExecutor)"
      expect_eq "l2CreForwarder → CRE_FORWARDER"                                 "$sol_l2_fwd"        "$(yml_anchor "$sm" l2CreForwarder)"
      expect_eq "l2LiquidityOwner → LIQUIDITY_OWNER"                             "$sol_l2_liq"        "$(yml_anchor "$sm" l2LiquidityOwner)"
      expect_eq "RETIRED_l2ChainlinkSyncAutomation → L2_OLD_CHAINLINK_AUTOMATION"              "$sol_l2_oldsync"    "$(yml_anchor "$sm" RETIRED_l2ChainlinkSyncAutomation)"
      expect_eq "l2Weth → L2_WETH"                                               "$sol_l2_weth"       "$(yml_anchor "$sm" l2Weth)"
      expect_eq "l2Wsteth → L2_WSTETH"                                           "$sol_l2_wsteth"     "$(yml_anchor "$sm" l2Wsteth)"
      expect_eq "l2LinkToken → L2_LINK_TOKEN"                                    "$sol_l2_link"       "$(yml_anchor "$sm" l2LinkToken)"
      expect_eq "l2CcipRouter → L2_CCIP_ROUTER"                                  "$sol_l2_router"     "$(yml_anchor "$sm" l2CcipRouter)"
      expect_eq "l2PriceOracle → L2_PRICE_ORACLE"                                "$sol_l2_oracle"     "$(yml_anchor "$sm" l2PriceOracle)"
      expect_eq "initialOwner → INITIAL_OWNER (L1 shared)"                       "$sol_initial_owner" "$(yml_anchor "$sm" initialOwner)"
      expect_eq "l2LidoDeployer → LIDO_DEPLOYER (L1 shared)"                     "$sol_deployer"      "$(yml_anchor "$sm" l2LidoDeployer)"
      expect_eq "ethMainnetCcipChainSelector → ETH_CCIP_CHAIN_SELECTOR (L1 shared)" "$sol_eth_selector" "$(yml_anchor "$sm" ethMainnetCcipChainSelector)"
      expect_eq "l1LidoCustomReceiverBytes32 → L1_LIDO_CUSTOM_RECEIVER (L1 shared)" "$sol_l1_recv"   "$(bytes32_to_addr "$(yml_anchor "$sm" l1LidoCustomReceiverBytes32)")"
      expect_eq "creWorkflowName → workflow.yaml production"                      "$cre_workflow_name" "$(yml_anchor "$sm" creWorkflowName)"
      expect_eq "creWorkflowTag → registered workflow tag"                        "$cre_workflow_name" "$(yml_anchor "$sm" creWorkflowTag)"
      expect_eq "workflow receiverAddress → l2CreReceiver" \
        "$(yml_anchor "$sm" l2CreReceiver)" "$(jq -r '.receiverAddress' cre-workflows/sync-automation/config.deploy.json)"
      expect_eq "workflow targetAddress → l2SyncTrigger" \
        "$(yml_anchor "$sm" l2SyncTrigger)" "$(jq -r '.targetAddress' cre-workflows/sync-automation/config.deploy.json)"
      expect_eq "creDonFamily → CRE_CLI_DON_FAMILY default"                       "$cre_don_family"    "$(yml_anchor "$sm" creDonFamily)"
      if [[ "$net" == "linea" ]]; then
        sol_gelato=$(sol_addr "$sol" L2_OLD_GELATO_AUTOMATION)
        gel="config/state/l2-linea-gelato.yaml"
        expect_eq "RETIRED_l2GelatoSyncAutomation → L2_OLD_GELATO_AUTOMATION"    "$sol_gelato" "$(yml_anchor "$gel" RETIRED_l2GelatoSyncAutomation)"
        # The standalone Gelato config mirrors a few lane anchors under misc:; each mirror must equal its source.
        for mirror in l2ChainId l2CustomSender l2Weth; do
          expect_eq "$mirror (Linea Gelato misc mirror) == linea.inputs.yaml" "$(yml_anchor "$sm" "$mirror")" "$(yml_anchor "$gel" "$mirror")"
        done
        expect_eq "ethMainnetCcipChainSelector (Linea Gelato misc mirror) == common.inputs.yaml" "$(yml_anchor config/state/common.inputs.yaml ethMainnetCcipChainSelector)" "$(yml_anchor "$gel" ethMainnetCcipChainSelector)"
      fi

      # Fee blobs + derived maxFees are NOT plain constants — they are FeeCodec-encoded from the
      # Solidity sub-params. Verify the .inputs anchors match the deploy's OWN encoding via
      # runPrintFeeParams (it reuses the exact config builder, so this is the static Solidity→.inputs guard).
      if command -v forge >/dev/null 2>&1; then
        fee_script="$(just _l2-config-target "$net")"
        fee_out="$(forge script "$fee_script" --sig 'runPrintFeeParams()' 2>/dev/null || true)"
        # Pull one KEY=value line out of the captured runPrintFeeParams output.
        fee_val() { printf '%s\n' "$fee_out" | sed -n "s/^[[:space:]]*$1=//p" | head -n1; }
        expect_eq "feeOtoD → FeeCodec.encodeCCIP(maxFee,payInLink,gasLimit)" \
          "$(fee_val FEE_OTO_D)"      "$(yml_anchor "$sm" feeOtoD)"
        expect_eq "feeDtoO → FeeCodec.encode${cap}L1toL2(...)" \
          "$(fee_val FEE_DTO_O)"      "$(yml_anchor "$sm" feeDtoO)"
        expect_eq "maxNativeFee → SyncTrigger.getMaxFees()" \
          "$(fee_val MAX_NATIVE_FEE)" "$(yml_anchor "$sm" maxNativeFee)"
        expect_eq "maxGasLimit → SyncTrigger.getMaxGasLimit() (L2_SYNC_MAX_GAS_LIMIT)" \
          "$(fee_val MAX_GAS_LIMIT)"  "$(yml_anchor "$sm" maxGasLimit)"
      else
        echo "  WARN forge not found — skipping fee-blob cross-check (feeOtoD/feeDtoO/maxFees/maxGasLimit)"
      fi

      echo "[$net] justfile preflight-check-l1 case blocks"
      expect_eq "preflight-check-l1 EXPECTED_SENDER → L2_CUSTOM_SENDER"          "$sol_l2_sender"   "$(just_field "$net" EXPECTED_SENDER)"
      expect_eq "preflight-check-l1 L2_CHAIN_SELECTOR → ${upper}_CCIP_CHAIN_SELECTOR" "$sol_l2_selector" "$(just_field "$net" L2_CHAIN_SELECTOR)"

      echo "[$net] shared L1 yaml: $L1_YAML (per-lane wiring)"
      sol_l2_sender_padded="0x000000000000000000000000${sol_l2_sender:2}"
      expect_eq "l1${cap}Adapter → L1_${upper}_ADAPTER (in $sol)"                "$sol_l1_adapter"    "$(yml_anchor "$L1_YAML" "l1${cap}Adapter")"
      expect_eq "l2${cap}SenderBytes32 → bytes32(L2_CUSTOM_SENDER)"              "$(printf '%s' "$sol_l2_sender_padded" | tr '[:upper:]' '[:lower:]')" "$(yml_anchor "$L1_YAML" "l2${cap}SenderBytes32")"
      expect_eq "${net}CcipChainSelector → ${upper}_CCIP_CHAIN_SELECTOR"          "$sol_l2_selector"   "$(yml_anchor "$L1_YAML" "${net}CcipChainSelector")"
    done

    echo
    echo "[shared L1 yaml: $L1_YAML — L1 receiver, ProxyAdmin, immutables]"
    # Check shared L1 proxy, implementation, and immutable addresses.
    expect_eq "l1LidoCustomReceiver → L1_LIDO_CUSTOM_RECEIVER"          "$sol_l1_recv"       "$(yml_anchor "$L1_YAML" l1LidoCustomReceiver)"
    expect_eq "l1LidoCustomReceiverImpl → L1_LIDO_CUSTOM_RECEIVER_IMPL" "$sol_l1_recv_impl"  "$(yml_anchor "$L1_YAML" l1LidoCustomReceiverImpl)"
    expect_eq "l1ProxyAdmin → L1_PROXY_ADMIN"                           "$sol_l1_proxy"      "$(yml_anchor "$L1_YAML" l1ProxyAdmin)"
    expect_eq "lidoDaoAgent → LIDO_DAO_AGENT"                                    "$sol_dao_agent"     "$(yml_anchor "$L1_YAML" lidoDaoAgent)"
    expect_eq "initialOwner → INITIAL_OWNER"                                     "$sol_initial_owner" "$(yml_anchor "$L1_YAML" initialOwner)"
    expect_eq "l1Weth → L1_WETH"                                                 "$sol_l1_weth"       "$(yml_anchor "$L1_YAML" l1Weth)"
    expect_eq "l1Wsteth → L1_WSTETH"                                             "$sol_l1_wsteth"     "$(yml_anchor "$L1_YAML" l1Wsteth)"
    expect_eq "l1CcipRouter → L1_CCIP_ROUTER"                                    "$sol_l1_router"     "$(yml_anchor "$L1_YAML" l1CcipRouter)"
    # ethMainnetCcipChainSelector is verified per-L2 above (line: "ethMainnetCcipChainSelector → ...").
    # It is intentionally ABSENT from ethereum.inputs.yaml: no L1 check references it, and an
    # unreferenced anchor is a fatal error under the .inputs full-delegation invariant.

    # L2 wstETH addresses surface on the L1 adapter's L2_TOKEN immutable (Optimism + Base only).
    sol_op_wsteth=$(sol_addr  "script/optimism/OptimismConstants.sol" L2_WSTETH)
    sol_base_wsteth=$(sol_addr "script/base/BaseConstants.sol"        L2_WSTETH)
    expect_eq "l2OptimismWsteth → optimism L2_WSTETH (in L1 adapter)"            "$sol_op_wsteth"     "$(yml_anchor "$L1_YAML" l2OptimismWsteth)"
    expect_eq "l2BaseWsteth → base L2_WSTETH (in L1 adapter)"                    "$sol_base_wsteth"   "$(yml_anchor "$L1_YAML" l2BaseWsteth)"

    echo
    echo "[shared L1 hardcodes outside per-network case blocks]"
    # just_global returns sorted-unique values; multiple lines means in-justfile drift.
    for line in $(just_global L1_RECEIVER);          do expect_eq "justfile L1_RECEIVER → L1_LIDO_CUSTOM_RECEIVER"    "$sol_l1_recv"      "$line"; done
    for line in $(just_global INITIAL_OWNER);        do expect_eq "justfile INITIAL_OWNER → INITIAL_OWNER"            "$sol_initial_owner" "$line"; done
    for line in $(just_global LIDO_DAO_AGENT);       do expect_eq "justfile LIDO_DAO_AGENT → LIDO_DAO_AGENT"          "$sol_dao_agent"    "$line"; done
    for line in $(just_global L1_PROXY_ADMIN_ADDR);  do expect_eq "justfile L1_PROXY_ADMIN_ADDR → L1_PROXY_ADMIN"     "$sol_l1_proxy"     "$line"; done

    echo
    echo "[CRE workflow config ↔ its measured-gas carrier]"
    # `writeGasLimit` is the gas the DON budgets for the delivered write. Its adequacy is proven by the
    # measured carrier `test_creWriteGasCarrier` (test/helpers/PoolTests.sol), which asserts against
    # the CRE_WRITE_GAS_LIMIT constant — so a JSON bump that skipped the test would silently invalidate the
    # evidence. Pin every lane's JSON to that constant (Solidity-side is canonical, as everywhere here).
    sol_write_gas="$(sol_uint "test/helpers/PoolTests.sol" CRE_WRITE_GAS_LIMIT)"
    for cfg in cre-workflows/sync-automation/config.deploy.json cre-workflows/sync-automation/config.simulate.json; do
      [[ -f "$cfg" ]] || continue
      expect_eq "$(basename "$cfg") writeGasLimit → CRE_WRITE_GAS_LIMIT" \
        "$sol_write_gas" "$(jq -r '.writeGasLimit' "$cfg")"
    done

    echo
    echo "===================================================================="
    if (( fail_count == 0 )); then
      echo "OK $pass_count duplicates in sync with Solidity."
    else
      echo "FAIL $fail_count drift(s) detected ($pass_count OK)."
      echo "     Fix the duplicate to match Solidity (canonical),"
      echo "     or update Solidity if it is the one that's wrong."
      exit 1
    fi
    echo "===================================================================="

# Check local ABI mirrors against forge inspect: SyncTrigger is exact; CREReceiver is a read-only subset.
# Compare canonical members without internalType. External dependency ABIs are outside this check.
verify-abi-sync:
    #!/usr/bin/env bash
    set -uo pipefail
    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    cd "$ROOT_DIR"
    command -v jq    >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
    command -v forge >/dev/null 2>&1 || { echo "forge is required" >&2; exit 1; }

    # "<mirror json>|<source path>:<contract>|<exact|subset>". Add a row when an in-repo contract gains a
    # mirror; pick the mode matching the file's intent (see header).
    PAIRS=(
      "config/state/abi/SyncTrigger.json|src/SyncTrigger.sol:SyncTrigger|exact"
      "config/state/abi/CREReceiver.json|src/cre/CREReceiver.sol:CREReceiver|subset"
    )

    # One canonical (key-sorted, compact) line per ABI member. `internalType` is stripped: it is cosmetic
    # (the Solidity source type name — only `type` drives the selector/decode), and the curated mirrors omit
    # it while forge emits it, so comparing it would flag a false drift.
    strip() { jq -S -c 'walk(if type == "object" then del(.internalType) else . end) | .[]'; }

    rc=0
    for pair in "${PAIRS[@]}"; do
      json="${pair%%|*}"; rest="${pair#*|}"; src="${rest%%|*}"; mode="${rest##*|}"
      if [[ ! -f "$json" ]]; then echo "✗ ${json} — mirror file missing"; rc=1; continue; fi
      live="$(forge inspect "$src" abi --json 2>/dev/null)"
      if [[ -z "$live" ]]; then echo "✗ ${src} — forge inspect produced no ABI (build error?)"; rc=1; continue; fi

      # Canonical members, sorted — declaration order is irrelevant.
      forge_members="$(echo "$live" | strip | sort)"
      json_members="$(strip < "$json" | sort)"
      count="$(echo "$json_members" | grep -c .)"

      if [[ "$mode" == exact ]]; then
        if [[ "$forge_members" == "$json_members" ]]; then
          echo "✓ ${json} (exact, ${count} members) matches ${src}"
        else
          echo "✗ ${json} (exact) DRIFTS from 'forge inspect ${src}' — regenerate it:"
          echo "      forge inspect ${src} abi --json > ${json}"
          comm -23 <(echo "$forge_members") <(echo "$json_members") | jq -r '"    + missing from mirror: \(.type) \(.name // "-")"'
          comm -13 <(echo "$forge_members") <(echo "$json_members") | jq -r '"    - stale/extra in mirror: \(.type) \(.name // "-")"'
          rc=1
        fi
      else
        # subset: every mirror member must exist verbatim in the source ABI; members absent from the
        # mirror are fine. Catches a curated getter whose signature drifted from the contract.
        stale="$(comm -13 <(echo "$forge_members") <(echo "$json_members"))"
        if [[ -z "$stale" ]]; then
          echo "✓ ${json} (subset, ${count} members) faithfully matches ${src}"
        else
          echo "✗ ${json} (subset) lists members that no longer match ${src}:"
          echo "$stale" | jq -r '"    - \(.type) \(.name // "-") (\(.inputs|length)-arg)"'
          rc=1
        fi
      fi
    done

    echo
    if (( rc == 0 )); then echo "OK — every in-repo ABI mirror is faithful to forge inspect."
    else echo "FAIL — ABI mirror drift detected (rc=${rc})."; fi
    exit $rc

# Require each L2 external/deployed address anchor to have a constant check or a documented exemption.
verify-externals-coverage:
    #!/usr/bin/env bash
    set -uo pipefail
    fail=0; ok=0
    # Anchors that legitimately have NO Constants.sol address constant (reason each):
    #   l2OraclePool / l2SyncTrigger / l2CreReceiver — deployment addresses
    #   lidoDaoAgent    — L2 echo of the L1 DAO agent (the L1 copy IS constants-checked); pinned
    #                     on-chain via BridgeExecutor.getEthereumGovernanceExecutor
    #   ovmL2CrossDomainMessenger — OP-stack standard predeploy; pinned on-chain via BridgeExecutor
    #   lineaMessageService — Linea message-service predeploy; pinned on-chain via LineaBridgeExecutor
    #                         (Linea analogue of ovmL2CrossDomainMessenger; null on the other lanes)
    #   RETIRED_l2SyncTrigger — denied SYNC_ROLE; immutable lane identity checked by l2.yaml
    #                           (RETIRED_l2ChainlinkSyncAutomation / RETIRED_l2GelatoSyncAutomation are
    #                           pinned by yml_anchor rows above and identity-checked the same way)
    #   l2AutomationOwner — configured Automation Multisig authority;
    #                     checked against contract ownership and the registry by state-mate
    #   creWorkflowRegistry — Chainlink's shared Ethereum registry; independently checked on-chain
    #   creWorkflowId — content-derived workflow deployment output (zero is the fail-closed predeploy stub)
    allow=" l2OraclePool l2SyncTrigger l2CreReceiver RETIRED_l2SyncTrigger l2AutomationOwner creWorkflowRegistry creWorkflowId lidoDaoAgent ovmL2CrossDomainMessenger lineaMessageService "
    # Anchor names cross-checked by a `yml_anchor` row in verify-constants-sync. The justfile is
    # invariant across the loop below, so scan it ONCE here (space-padded for the `case` match)
    # rather than re-grepping it per anchor per net.
    #
    # Match on the (FILE, anchor) PAIR, not the bare name: an L1-file row (yml_anchor "$L1_YAML" …) must
    # NOT be credited as covering an identically-named L2 anchor. `lidoDaoAgent`, e.g., exists in BOTH
    # the L1 yaml (constants-checked) and each L2 lane (an on-chain echo), but only the L1 copy has a
    # verify-constants-sync row — so the L2 anchor must fall through to the allowlist below, not silently
    # pass on the unrelated L1 row (which would also make `lidoDaoAgent`'s allow entry dead code, and let
    # an L1 rename flip the L2 verdict). An L2 anchor counts as covered ONLY when a row reads it from the
    # per-lane state-mate file ("$sm", which yml_anchor expands to <net>.inputs/.deployed) or from a
    # literal config/state/*.yaml path.
    covered=" $(grep -oE 'yml_anchor "(\$sm|config/state/[^"]+)" [A-Za-z0-9_]+' justfile \
                  | awk '{print $NF}' | sort -u | tr '\n' ' ')"
    echo "===================================================================="
    echo "VERIFY EXTERNALS COVERAGE  (every L2 external/deployed anchor pinned to a source-of-truth)"
    echo "===================================================================="
    # l2-linea-gelato.yaml is standalone: its anchors live under misc: (not externals:), so they are not
    # swept here — they are pinned by the explicit yml_anchor rows above.
    for net in common optimism arbitrum base linea; do
      inputs="config/state/${net}.inputs.yaml"
      deployed="config/state/${net}.deployed.yaml"
      for file in "$inputs" "$deployed"; do
        [[ -f "$file" ]] || { echo "Missing state file: $file" >&2; exit 1; }
      done
      anchors="$( { awk '/^externals:/{f=1;next} /^[a-z]/{f=0} f&&/- &/{print}' "$inputs"; \
                    grep -hE '^[[:space:]]*- &' "$deployed" 2>/dev/null; } \
                  | grep -oE '&[A-Za-z0-9_]+' | tr -d '&' | sort -u )"
      for a in $anchors; do
        case "$covered" in *" $a "*) ok=$(( ok + 1 )); continue;; esac
        case "$allow"   in *" $a "*) ok=$(( ok + 1 )); continue;; esac
        echo "  UNCOVERED [$net] $a — add a verify-constants-sync row, or allowlist it here with a reason"
        fail=$(( fail + 1 ))
      done
    done
    echo "===================================================================="
    if [[ $fail -eq 0 ]]; then
      echo "OK every L2 external/deployed anchor is constants-checked or allowlisted ($ok checks)."
    else
      echo "FAIL $fail problem(s): an uncovered anchor (same-provenance false-pass risk) — see rows above."
      exit 1
    fi
    echo "===================================================================="

# Check the shared WorkflowRegistry record and lane contracts using the state-mate runner.
# Requires L2_NETWORK; RPC bindings follow the state commands. No signing key is needed.
verify-cre-workflow:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; load .env.<network>}"
    just _state-verify "$L2_NETWORK" "${L2_RPC_URL:-}"

# Record the shared workflow ID in common.deployed.yaml for all four lanes.
record-cre-workflow-id workflow_id:
    #!/usr/bin/env bash
    set -euo pipefail
    WORKFLOW_ID="{{workflow_id}}"
    [[ "$WORKFLOW_ID" =~ ^0x[0-9a-fA-F]{64}$ ]] || {
      echo "Bad workflow ID: $WORKFLOW_ID (expected 0x + 64 hex chars)" >&2
      exit 1
    }
    [[ "$WORKFLOW_ID" != "0x$(printf '0%.0s' {1..64})" ]] || { echo "Refusing zero workflow ID" >&2; exit 1; }
    command -v yq >/dev/null 2>&1 || { echo "Missing required command: yq" >&2; exit 1; }
    OUT="{{justfile_directory()}}/config/state/common.deployed.yaml"
    [[ -f "$OUT" ]] || { echo "Missing common deployed state: $OUT" >&2; exit 1; }
    TMP="$(mktemp "${TMPDIR:-/tmp}/common.deployed.XXXXXX.yaml")"
    trap 'rm -f "$TMP"' EXIT
    # `style="double"` is load-bearing, not cosmetic: a bare 0x… scalar is an integer to any
    # YAML 1.1 loader, which would silently turn the 64-hex-digit ID into a lossy float.
    WF="$WORKFLOW_ID" yq \
      '(.deployed.l1) = [strenv(WF)] | .deployed.l1[0] anchor = "creWorkflowId" | .deployed.l1[0] style = "double"' \
      "$OUT" > "$TMP"
    mv "$TMP" "$OUT"
    trap - EXIT
    echo "Recorded the consolidated CRE workflow ID in $OUT (shared by all four lanes)"

# What does the CRE WorkflowRegistry actually say? Keyless, read-only, no .env needed — the CLI
# mirror of the dashboard's Automation tab (docs/cre.md).
#
# It ENUMERATES `getWorkflowListByOwner` rather than reading the pinned IDs, because `workflowId` is
# content-derived: every `upsertWorkflow` mints a new one, so a pin-first read reports a stale repo
# anchor as if it were a chain fault. The pins are then diffed against the enumeration as a separate,
# clearly-labelled DRIFT row — a fact about this repository, not about the automation's health.
#
# The registry is ONE Ethereum-mainnet singleton for all four lanes; lanes are matched by workflow
# name. Query configured automation/workflow owners and each live CREReceiver author.
#
# L1 RPC: RPC_ETHEREUM_REMOTE, else RPC_ETHEREUM, else L1_RPC_URL, else a public endpoint.
# L2 RPCs (RPC_<NET>[_REMOTE]) are OPTIONAL — without them the author-gate cross-check is skipped,
# not failed. Exits nonzero on any ✕ row.
#
# Complements, does not replace: `just -E .env.<net> verify-cre-workflow` (state-mate, exhaustive,
# pin-based) and `just postflight-monitor`.
cre-registry-status:
    #!/usr/bin/env bash
    set -uo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    command -v yq >/dev/null 2>&1 || { echo "yq (mikefarah) is required" >&2; exit 1; }
    command -v cast >/dev/null 2>&1 || { echo "cast (foundry) is required" >&2; exit 1; }

    # The registry's WorkflowMetadataView, spelled out once. cast decodes the whole tuple[] for us.
    LIST_SIG='getWorkflowListByOwner(address,uint256,uint256)((bytes32,address,uint64,uint8,string,string,string,string,bytes,string)[])'
    NETS=( optimism arbitrum base linea )

    REGISTRY="$(just _l2-input-anchor optimism creWorkflowRegistry)"
    DON_FAMILY="$(just _l2-input-anchor optimism creDonFamily)"
    AUTOMATION_OWNER="$(just _l2-input-anchor optimism l2AutomationOwner)"
    WORKFLOW_OWNER="$AUTOMATION_OWNER"
    CRE_RECEIVER="$(just _l2-input-anchor optimism l2CreReceiver 2>/dev/null || true)"
    [[ -n "$CRE_RECEIVER" ]] || CRE_RECEIVER="$(yq '[.. | select(anchor == "l2CreReceiver")][0]' \
      "$ROOT_DIR/config/state/optimism.deployed.yaml" | tr -d '"')"

    L1="${RPC_ETHEREUM_REMOTE:-${RPC_ETHEREUM:-${L1_RPC_URL:-https://ethereum-rpc.publicnode.com}}}"

    echo "Resolved from config/state/*.inputs.yaml + *.deployed.yaml:"
    echo "  registry         = $REGISTRY  (Ethereum-mainnet singleton, all 4 lanes)"
    echo "  don family       = $DON_FAMILY"
    echo "  automation owner = $AUTOMATION_OWNER"
    echo "  workflow owner   = $WORKFLOW_OWNER"
    echo "  CREReceiver      = $CRE_RECEIVER  (same CREATE2 address on every lane)"
    echo "  L1 rpc           = $L1"
    echo

    cast chain-id --rpc-url "$L1" >/dev/null 2>&1 \
      || { echo "L1 RPC not reachable: $L1" >&2; exit 1; }

    rc=0
    OK()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
    BAD() { printf '  \033[31m✕\033[0m %s\n' "$1"; rc=1; }
    WARN(){ printf '  \033[33m⚠\033[0m %s\n' "$1"; }
    INFO(){ printf '    %s\n' "$1"; }

    # ── Live expectedAuthor per lane (optional; also grows the owner set) ──
    declare -a AUTHORS
    # Deduplicate shared owner addresses so a registry record is counted only once.
    OWNERS="$AUTOMATION_OWNER"
    grep -qi -- "$WORKFLOW_OWNER" <<<"$OWNERS" || OWNERS="$OWNERS $WORKFLOW_OWNER"
    echo "──── author pins (L2) ────"
    for i in "${!NETS[@]}"; do
      net="${NETS[$i]}"; u="$(echo "$net" | tr '[:lower:]' '[:upper:]')"
      rpc_var="RPC_${u}_REMOTE"; rpc="${!rpc_var:-}"
      [[ -n "$rpc" ]] || { rpc_var="RPC_${u}"; rpc="${!rpc_var:-}"; }
      AUTHORS[$i]=""
      if [[ -z "$rpc" ]] || ! cast chain-id --rpc-url "$rpc" >/dev/null 2>&1; then
        WARN "$net: expectedAuthor not read (set RPC_${u}_REMOTE) — author-gate cross-check skipped"
        continue
      fi
      a="$(cast call "$CRE_RECEIVER" 'getExpectedAuthor()(address)' --rpc-url "$rpc" 2>/dev/null | tr -d ' \r')"
      if [[ ! "$a" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        BAD "$net: getExpectedAuthor() unreadable on $CRE_RECEIVER"; continue
      fi
      AUTHORS[$i]="$a"
      INFO "$(printf '%-9s expectedAuthor = %s' "$net" "$a")"
      grep -qi -- "$a" <<<"$OWNERS" || OWNERS="$OWNERS $a"
    done
    echo

    # ── Owner-account state: the link is what the DON signs as; the quota is deploy access ──
    echo "──── owner accounts (L1 registry) ────"
    for owner in $OWNERS; do
      linked="$(cast call "$REGISTRY" 'isOwnerLinked(address)(bool)' "$owner" --rpc-url "$L1" 2>/dev/null | tr -d ' \r')"
      quota="$(cast call "$REGISTRY" 'getMaxWorkflowsPerUserDON(address,string)(uint32)' "$owner" "$DON_FAMILY" --rpc-url "$L1" 2>/dev/null | tr -d ' \r')"
      quota="${quota%% *}"
      eth="$(cast balance "$owner" --rpc-url "$L1" 2>/dev/null || echo 0)"
      if [[ "$linked" == "true" ]]; then
        OK "$owner  isOwnerLinked = true  ·  quota(${DON_FAMILY}) = ${quota:-?}  ·  $(cast from-wei "${eth%% *}") ETH"
      else
        BAD "$owner  isOwnerLinked = ${linked:-<unreadable>} — the DON will NOT sign as this address"
      fi
      # The owner account executes every registry transaction, directly or through its Safe, so DUST
      # is as disabling as zero: no `pause`, no `delete`. Keep the same 0.001 ETH floor as the dashboard.
      [[ "${eth%% *}" -lt 1000000000000000 ]] 2>/dev/null \
        && WARN "$owner has $(cast from-wei "${eth%% *}") mainnet ETH — too thin to pause/delete its own workflows"
    done
    echo

    # ── Registered workflows, enumerated ──
    # `--json` (not the human form) because the human form's `), (` tuple separator is not a reliable
    # record delimiter, and BSD vs GNU sed disagree about `\n` in a replacement.
    echo "──── registered workflows (enumerated, not pinned) ────"
    ROWS="$(mktemp "${TMPDIR:-/tmp}/cre-rows.XXXXXX")"
    trap 'rm -f "$ROWS"' EXIT
    : > "$ROWS"
    for owner in $OWNERS; do
      raw="$(cast call "$REGISTRY" "$LIST_SIG" "$owner" 0 20 --rpc-url "$L1" --json 2>&1)"
      jq -e . >/dev/null 2>&1 <<<"$raw" \
        || { BAD "getWorkflowListByOwner($owner) failed: ${raw:0:120}"; continue; }
      # id \t owner \t createdAt \t status \t name \t tag \t donFamily — tab-separated, one per line.
      jq -r '.[0][] | [.[0], .[1], .[2], .[3], .[4], .[7], .[9]] | @tsv' <<<"$raw" >> "$ROWS"
    done
    while IFS=$'\t' read -r f_id f_owner f_created f_status f_name f_tag f_don; do
      [[ -n "$f_name" ]] || continue
      printf '  %s\n' "$f_name"
      INFO "id       $f_id"
      INFO "owner    $f_owner"
      INFO "created  $(date -u -r "$f_created" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$f_created" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$f_created")"
      [[ "$f_status" == "0" ]] && OK "status   ACTIVE" || BAD "status   $f_status (1 = PAUSED) — the DON is not running this workflow"
      [[ "$f_don" == "$DON_FAMILY" ]] && OK "don      $f_don" || BAD "don      $f_don (expected $DON_FAMILY — the quota above is for a different family)"
      [[ "$f_tag" == "$f_name" ]] || WARN "tag      $f_tag (differs from name)"
    done < "$ROWS"
    echo

    # ── DRIFT: repo pins vs the enumeration. A repo fact, deliberately not a chain fault. ──
    echo "──── repo pin vs chain (config/state/common.deployed.yaml, one id for all lanes) ────"
    # Join on THIS lane's workflow and compare THAT row's id. Matching the pin against the whole id set
    # (or the name as a substring) would pass a lane whose pin actually holds a different lane's id —
    # the cross-chain blindness this repo has been bitten by before.
    for net in "${NETS[@]}"; do
      name="$(just _l2-input-anchor "$net" creWorkflowName)"
      pin="$(yq '[.. | select(anchor == "creWorkflowId")][0]' "$ROOT_DIR/config/state/common.deployed.yaml" 2>/dev/null | tr -d '"')"
      live="$(awk -F'\t' -v n="$name" '$5 == n { print $1 }' "$ROWS")"
      count="$(printf '%s' "$live" | grep -c . || true)"
      if [[ "$count" -eq 0 ]]; then
        BAD "$(printf '%-9s no workflow named %s registered under any queried owner' "$net" "$name")"
      elif [[ "$count" -gt 1 ]]; then
        BAD "$(printf '%-9s %s workflows named %s across the queried owners — ambiguous' "$net" "$count" "$name")"
      elif [[ "$live" == "$pin" ]]; then
        OK "$(printf '%-9s pin matches chain  %s' "$net" "$pin")"
      else
        WARN "$(printf '%-9s pin STALE: repo %s, chain %s — refresh with just record-cre-workflow-id %s' \
          "$net" "$pin" "$live" "$live")"
      fi
    done
    echo

    # ── The cross-plane conjunct the registry alone cannot show ──
    echo "──── author gate (registry owner ↔ L2 expectedAuthor) ────"
    for i in "${!NETS[@]}"; do
      net="${NETS[$i]}"; a="${AUTHORS[$i]}"
      [[ -n "$a" ]] || { WARN "$net: skipped (no L2 RPC)"; continue; }
      linked="$(cast call "$REGISTRY" 'isOwnerLinked(address)(bool)' "$a" --rpc-url "$L1" 2>/dev/null | tr -d ' \r')"
      if [[ "$linked" == "true" ]]; then
        OK "$(printf '%-9s expectedAuthor %s is link-registered — reports will pass the author gate' "$net" "$a")"
      else
        BAD "$(printf '%-9s expectedAuthor %s is NOT link-registered — every report reverts InvalidAuthor (silent stall)' "$net" "$a")"
      fi
    done
    echo
    echo "Not readable here (see docs/monitoring.md): DON liveness (no heartbeat;"
    echo "idle and dead are indistinguishable), registered artifact CONTENT (binaryUrl/configUrl are"
    echo "403-gated), CRE credit balance (dashboard-only), and report REJECTIONS (the forwarder"
    echo "absorbs receiver reverts, so InvalidAuthor leaves no log)."
    exit $rc

# Resolve one scalar anchor from the effective L2 inputs (common + lane delta). Exactly one definition
# is required, so operational readers enforce the same no-shadowing rule as state-mate.
[no-exit-message]
_l2-input-anchor net anchor:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{net}}" in optimism|arbitrum|base|linea) ;; *) echo "unknown L2 network: {{net}}" >&2; exit 2 ;; esac
    common="config/state/common.inputs.yaml"
    lane="config/state/{{net}}.inputs.yaml"
    [[ -f "$common" ]] || { echo "missing $common" >&2; exit 1; }
    [[ -f "$lane" ]] || { echo "missing $lane" >&2; exit 1; }
    values=()
    while IFS= read -r value; do values+=("$value"); done \
      < <(yq '.. | select(anchor == "{{anchor}}")' "$common" "$lane" 2>/dev/null | tr -d '"')
    if [[ "${#values[@]}" -ne 1 ]]; then
      echo "anchor &{{anchor}} must be defined exactly once across $common and $lane (found ${#values[@]})" >&2
      exit 1
    fi
    printf '%s\n' "${values[0]}"


# Publish source verification for the configured pool, trigger, and receiver using on-chain constructor args.
verify-sources:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${L2_ORACLE_POOL:?L2_ORACLE_POOL is required; read it from config/state/<network>.deployed.yaml}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; read it from config/state/<network>.deployed.yaml}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required; read it from config/state/<network>.deployed.yaml}"
    : "${ETHERSCAN_API_KEY:?ETHERSCAN_API_KEY is required; export an etherscan.io v2 API key before running}"
    for c in cast forge; do command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; exit 1; }; done

    chain_id=$(cast chain-id --rpc-url "$L2_RPC_URL" | tr -d '\r\n')
    echo "Publishing contract sources for $L2_NETWORK (chain $chain_id) to the Etherscan v2 explorer:"
    echo "  PausableImmutableOraclePool $L2_ORACLE_POOL"
    echo "  SyncTrigger                 $L2_SYNC_TRIGGER"
    echo "  CREReceiver                 $L2_CRE_RECEIVER"

    fail=0
    verify() { # <label> <address> <path:Name>
      echo
      echo "→ $1  $3 @ $2"
      if forge verify-contract "$2" "$3" \
           --chain "$chain_id" --rpc-url "$L2_RPC_URL" \
           --etherscan-api-key "$ETHERSCAN_API_KEY" \
           --guess-constructor-args --watch; then
        echo "   OK $1"
      else
        echo "   FAIL $1 — re-run after fixing (verification is idempotent)" >&2
        fail=1
      fi
    }
    verify pool     "$L2_ORACLE_POOL"  "lib/chainlink-csr/contracts/utils/PausableImmutableOraclePool.sol:PausableImmutableOraclePool"
    verify trigger  "$L2_SYNC_TRIGGER" "src/SyncTrigger.sol:SyncTrigger"
    verify receiver "$L2_CRE_RECEIVER" "src/cre/CREReceiver.sol:CREReceiver"
    if [[ $fail -eq 0 ]]; then
      echo
      echo "All three sources verified on the $L2_NETWORK explorer."
    fi
    exit $fail

# Third-party check of the explorer-published contract sources: diffyscan (lidofinance/diffyscan)
# downloads each contract's verified sources from the lane explorer and diffs them file-by-file
# against the pinned deploy commit on GitHub. Complements `verify-sources` (which PUBLISHES via the
# same forge toolchain it deployed with — it cannot catch a wrong/poisoned publication; this can).
# Runs source-diff only (--skip-binary-comparison): bytecode provenance is already covered by the
# deploy broadcast + verify-test on-chain checks. Run AFTER verify-sources succeeds.
#
# Configs are committed under config/diffyscan/l2-<net>.yaml (addresses are final; explorer + chain
# id + deploy/dependency commits are pinned there — Optimism/Base use Blockscout, Arbitrum/Linea
# use Etherscan v2).
#
# Install (not vendored — a Python tool): uv tool install git+https://github.com/lidofinance/diffyscan
# Required env (.env.<network>): L2_NETWORK, ETHERSCAN_API_KEY (same v2 key as verify-sources;
#   Blockscout lanes still require the env var to be set even though the API ignores the token),
#   GITHUB_API_TOKEN (a GitHub token that can read lidofinance/l2-direct-staking; NB the org rejects
#   fine-grained PATs with lifetime > 30 days).
#
# Usage: just -E .env.<network> diffyscan
diffyscan:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network>}"
    : "${ETHERSCAN_API_KEY:?ETHERSCAN_API_KEY is required; export an etherscan.io v2 API key (same as verify-sources)}"
    : "${GITHUB_API_TOKEN:?GITHUB_API_TOKEN is required; diffyscan fetches the pinned sources via the GitHub API}"
    command -v diffyscan >/dev/null 2>&1 || { echo "Missing diffyscan — install: uv tool install git+https://github.com/lidofinance/diffyscan" >&2; exit 1; }
    cfg="config/diffyscan/l2-$L2_NETWORK.yaml"
    [[ -f "$cfg" ]] || { echo "FAIL: missing $cfg" >&2; exit 1; }
    diffyscan "$cfg" --skip-binary-comparison --yes

# Build and upload the consolidated four-lane CRE workflow, then emit unsigned WorkflowRegistry
# calldata for the Automation Multisig pinned in project.yaml. One registration drives all four L2s.
#
# Required env (root .env): all four RPC_<NET>_REMOTE URLs, an Ethereum RPC, and the Automation Owner
# key the CRE CLI uses to authenticate the artifact upload. Before emitting calldata, the recipe reads
# CREReceiver.getExpectedAuthor() on every lane and aborts unless all four equal the Safe owner.
#
# Usage: just deploy-cre-workflow
deploy-cre-workflow:
    #!/usr/bin/env bash
    set -euo pipefail
    CRE="$(just _cre-bin)"
    command -v cast >/dev/null 2>&1 || { echo "Missing 'cast' (foundry)" >&2; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "Missing required command: jq" >&2; exit 1; }
    command -v yq >/dev/null 2>&1 || { echo "Missing required command: yq" >&2; exit 1; }

    # The key authenticates the CLI upload. The on-chain owner comes from production.account in
    # project.yaml because --unsigned puts the Safe, not this EOA, into the workflow ID and registry row.
    source "{{justfile_directory()}}/script/shared/cre-env.sh"
    cre_env_export
    cre_env_export_all_l2_rpcs

    TARGET="production"
    CONFIG="config.deploy.json"
    [[ -f "cre-workflows/sync-automation/$CONFIG" ]] \
      || { echo "Missing cre-workflows/sync-automation/$CONFIG." >&2; exit 1; }
    grep -q '0xYOUR_' "cre-workflows/sync-automation/$CONFIG" \
      && { echo "Placeholder addresses still in $CONFIG." >&2; exit 1; } || true

    WORKFLOW_OWNER="$(yq -r '.production.account.workflow-owner-address' cre-workflows/project.yaml)"
    RECEIVER="$(jq -er '.receiverAddress' "cre-workflows/sync-automation/$CONFIG")"
    [[ "$WORKFLOW_OWNER" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "Bad production workflow owner: $WORKFLOW_OWNER" >&2; exit 1; }
    [[ "$RECEIVER" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "Bad receiverAddress in $CONFIG: $RECEIVER" >&2; exit 1; }
    OWNER_CS="$(cast to-check-sum-address "$WORKFLOW_OWNER")"

    for net in optimism arbitrum base linea; do
      upper="$(printf '%s' "$net" | tr '[:lower:]' '[:upper:]')"
      rpc_var="L2_${upper}_RPC_URL"
      rpc="${!rpc_var}"
      pinned="$(cast call "$RECEIVER" 'getExpectedAuthor()(address)' --rpc-url "$rpc" | tr -d '\r\n')"
      pinned_cs="$(cast to-check-sum-address "$pinned")"
      if [[ "$OWNER_CS" != "$pinned_cs" ]]; then
        echo "ABORT: $net CREReceiver.getExpectedAuthor() is $pinned_cs, production owner is $OWNER_CS." >&2
        echo "Every report on this lane would fail the author gate." >&2
        exit 1
      fi
      echo "Cross-check OK: $net expectedAuthor == $OWNER_CS."
    done

    # Run from the PROJECT root (cre-workflows/, holding project.yaml) and pass the workflow folder by
    # NAME: the CLI resolves <workflow-folder-path> against the project root it discovers, so `.` from
    # inside sync-automation/ resolves back to cre-workflows/ and it looks for workflow.yaml there.
    echo "Emitting UNSIGNED WorkflowRegistry calldata for $OWNER_CS (target $TARGET)."
    (cd cre-workflows && "$CRE" workflow deploy sync-automation --target="$TARGET" --unsigned)
    echo
    echo "===================================================================="
    echo "The pinned CRE CLI emits empty attributes. Run 'just cre-attach-params', paste the calldata,"
    echo "and execute the rewritten calldata from $OWNER_CS."
    echo "Record the returned workflow ID once (shared by all four lanes) with 'just record-cre-workflow-id <workflow-id>',"
    echo "then run 'NETWORK=<network> just verify-cre-workflow' for each lane."
    echo "===================================================================="

# Measure L1 receiver/adapter gas on mainnet forks. See docs/fees.md for measurement limits.
# Requires RPC_ETHEREUM and RPC_<NET>, or Foundry L1_RPC_URL / L2_<NET>_RPC_URL aliases.
measure-fee-gas:
    #!/usr/bin/env bash
    set -uo pipefail

    # Prefer RPC_<NET>, then the Foundry aliases consumed by the Solidity tests.
    L1_RPC_URL="${RPC_ETHEREUM:-${L1_RPC_URL:-}}"
    [[ -n "$L1_RPC_URL" ]] || { echo "Set RPC_ETHEREUM (or L1_RPC_URL)" >&2; exit 1; }
    cast chain-id --rpc-url "$L1_RPC_URL" >/dev/null 2>&1 \
      || { echo "L1 RPC not reachable: $L1_RPC_URL (RPC_ETHEREUM)" >&2; exit 1; }
    export L1_RPC_URL

    SPECS=(    OptimismPool ArbitrumPool BasePool LineaPool)
    RPC_ENVS=( RPC_OPTIMISM        RPC_ARBITRUM        RPC_BASE        RPC_LINEA)
    # Foundry aliases read by vm.envString.
    L2_ENVS=(  L2_OPTIMISM_RPC_URL L2_ARBITRUM_RPC_URL L2_BASE_RPC_URL L2_LINEA_RPC_URL)

    rc=0
    for i in $(seq 0 $(( ${#SPECS[@]} - 1 ))); do
      spec="${SPECS[$i]}"; rpc_env="${RPC_ENVS[$i]}"; l2_env="${L2_ENVS[$i]}"
      echo "──── ${spec} ────"
      rpc_val="${!rpc_env:-}"
      [[ -n "$rpc_val" ]] || rpc_val="${!l2_env:-}"
      if [[ -z "$rpc_val" ]]; then
        echo "  (skipped — set ${rpc_env} or ${l2_env})"; rc=1
        continue
      fi
      if ! cast chain-id --rpc-url "$rpc_val" >/dev/null 2>&1; then
        echo "  (skipped — ${rpc_env} not reachable: ${rpc_val})"; rc=1
        continue
      fi
      env "${l2_env}=${rpc_val}" \
        forge test --match-path "test/${spec}.t.sol" --match-test test_ccipReceiveGasRealAdapter -vv 2>&1 \
        | grep -E "FeeOtoD.gasLimit carrier|measured ccipReceive|configured FeeOtoD|utilization|planning-proj|\[(PASS|FAIL)\]" \
        || { echo "  (no carrier output — forge test produced none; rerun without the grep filter)"; rc=1; }
    done
    exit $rc

# Quote live L2→L1 Router.getFee for the configured maximum sync amount and compare with maxFee.
# The return leg uses the native bridge. Requires RPC_<NET> or L2_<NET>_RPC_URL; see docs/fees.md.
quote-ccip-fees:
    #!/usr/bin/env bash
    set -uo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    command -v yq >/dev/null 2>&1 || { echo "yq (mikefarah) is required" >&2; exit 1; }
    SIG="getFee(uint64,(bytes,bytes,(address,uint256)[],address,bytes))(uint256)"
    # Four lane anchors are pulled in one yq pass; the two shared anchors use the effective-input
    # resolver, which also rejects accidental common/lane duplicates. The
    # .inputs.yaml entries are anchored list items addressed by recursive descent (`.[]` misses
    # them); the `[..][0]` form pins output order to query order so the positional read is safe.
    ANCHORS='[.. | select(anchor=="l2CcipRouter")][0],
      [.. | select(anchor=="l2Weth")][0],
      [.. | select(anchor=="feeOtoD")][0],
      [.. | select(anchor=="feeDtoO")][0]'

    # One source-of-truth lane list; display names and RPC env-var names are derived (no parallel
    # arrays to keep in lockstep), matching preflight-check's RPC_<NET-upper> convention.
    NETS=( optimism arbitrum base linea )
    declare -a NAMES RPC_ENVS L2_ENVS
    for net in "${NETS[@]}"; do
      u="$(echo "$net" | tr '[:lower:]' '[:upper:]')"
      NAMES+=("${u:0:1}${net:1}"); RPC_ENVS+=("RPC_$u"); L2_ENVS+=("L2_${u}_RPC_URL")
    done

    # ── Resolve lane constants in one yq pass, then shared constants through the effective-input helper ──
    declare -a ROUTER SELECTOR RECEIVER WETH GASLIM MAXFEE DATALEN
    echo "Resolved from config/state/<net>.inputs.yaml:"
    for i in "${!NETS[@]}"; do
      f="${ROOT_DIR}/config/state/${NETS[$i]}.inputs.yaml"
      [[ -f "$f" ]] || { echo "  ${NAMES[$i]}: inputs file not found: $f" >&2; exit 1; }
      { IFS= read -r ROUTER[$i]; IFS= read -r WETH[$i]
        IFS= read -r otod;        IFS= read -r dtoo
      } < <(yq "$ANCHORS" "$f")
      SELECTOR[$i]="$(just _l2-input-anchor "${NETS[$i]}" ethMainnetCcipChainSelector)"
      RECEIVER[$i]="$(just _l2-input-anchor "${NETS[$i]}" l1LidoCustomReceiverBytes32)"
      otod="${otod#0x}"; dtoo="${dtoo#0x}"
      [[ ${#otod} -eq 42 ]] || { echo "  ${NAMES[$i]}: malformed feeOtoD (got ${#otod} hex chars, want 42): 0x$otod" >&2; exit 1; }
      # maxFee is a uint128 (32 hex chars). Parse with `cast to-dec`, NOT bash `$(( 16#… ))`, which is
      # signed 64-bit and silently wraps a maxFee >= 2^63 wei (~9.22 ETH) to a garbage/negative value.
      MAXFEE[$i]="$(cast to-dec "0x${otod:0:32}")"   # encodeCCIP bytes 0..15  = maxFee (uint128)
      GASLIM[$i]=$(( 16#${otod:34:8} ))              # encodeCCIP bytes 17..20 = gasLimit (uint32, 64-bit-safe)
      DATALEN[$i]=$(( 52 + ${#dtoo} / 2 ))           # recipient[20] + amount[32] + feeDtoO
      printf '  %-8s router=%s weth=%s selector=%s gasLimit=%s maxFee=%s ETH data=%sB\n' \
        "${NAMES[$i]}" "${ROUTER[$i]}" "${WETH[$i]}" "${SELECTOR[$i]}" "${GASLIM[$i]}" \
        "$(cast from-wei "${MAXFEE[$i]}")" "${DATALEN[$i]}"
    done
    echo "  receiver (shared) = ${RECEIVER[0]}"
    echo

    rc=0
    for i in "${!NAMES[@]}"; do
      name="${NAMES[$i]}"; rpc_env="${RPC_ENVS[$i]}"; l2_env="${L2_ENVS[$i]}"
      echo "──── ${name} ────"
      rpc_val="${!rpc_env:-}"
      [[ -n "$rpc_val" ]] || rpc_val="${!l2_env:-}"
      if [[ -z "$rpc_val" ]]; then
        echo "  (skipped — set ${rpc_env} or ${l2_env})"; rc=1
        continue
      fi
      if ! cast chain-id --rpc-url "$rpc_val" >/dev/null 2>&1; then
        echo "  (skipped — ${rpc_env} not reachable: ${rpc_val})"; rc=1
        continue
      fi
      extra="0x97a657c9$(printf '%064x' "${GASLIM[$i]}")"  # EVMExtraArgsV1 tag ++ abi.encode(gasLimit)
      data="0x$(printf '%0*d' $(( DATALEN[$i] * 2 )) 0)"   # zero bytes of the real payload length
      msg="(${RECEIVER[$i]},${data},[(${WETH[$i]},1000000000000000000)],0x0000000000000000000000000000000000000000,${extra})"
      raw="$(cast call "${ROUTER[$i]}" "$SIG" "${SELECTOR[$i]}" "$msg" --rpc-url "$rpc_val" 2>&1)" \
        || { echo "  getFee reverted: ${raw}"; rc=1; continue; }
      fee_wei="${raw%% *}"                                 # strip any "[1.23e16]" annotation
      # Compute the ratio in awk to avoid signed 64-bit overflow and integer truncation.
      # Preserve the original decimal strings for exact cast displays; reject zero maxFee.
      if [[ "${MAXFEE[$i]}" == "0" ]]; then
        bps=0; flag="  ⚠ maxFee is 0 (malformed feeOtoD)"
      else
        bps=$(awk -v f="$fee_wei" -v m="${MAXFEE[$i]}" 'BEGIN { printf "%d", f * 10000 / m }')
        flag=""; (( bps >= 8000 )) && flag="  ⚠ >=80% of maxFee"
      fi
      printf '  fee: %s ETH  (gasLimit %s, %d.%02d%% of %s ETH maxFee)%s\n' \
        "$(cast from-wei "$fee_wei")" "${GASLIM[$i]}" "$(( bps / 100 ))" "$(( bps % 100 ))" \
        "$(cast from-wei "${MAXFEE[$i]}")" "$flag"
    done
    exit $rc

# Sweep live Router.getFee over sync amounts and report the marginal premium.
# Decode transfer policy only for supported v1.5 OnRamps; see docs/fees.md.
quote-ccip-fee-by-amount:
    #!/usr/bin/env bash
    set -uo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    command -v yq >/dev/null 2>&1 || { echo "yq (mikefarah) is required" >&2; exit 1; }
    SIG="getFee(uint64,(bytes,bytes,(address,uint256)[],address,bytes))(uint256)"
    AMTS_WETH=( 0.001 0.01 0.1 1 10 100 1000 10000 100000 )   # geometric sweep of the bridged amount
    # Same lane anchors / effective shared lookups as quote-ccip-fees.
    ANCHORS='[.. | select(anchor=="l2CcipRouter")][0],
      [.. | select(anchor=="l2Weth")][0],
      [.. | select(anchor=="feeOtoD")][0],
      [.. | select(anchor=="feeDtoO")][0]'

    NETS=( optimism arbitrum base linea )
    declare -a NAMES RPC_ENVS L2_ENVS
    for net in "${NETS[@]}"; do
      u="$(echo "$net" | tr '[:lower:]' '[:upper:]')"
      NAMES+=("${u:0:1}${net:1}"); RPC_ENVS+=("RPC_$u"); L2_ENVS+=("L2_${u}_RPC_URL")
    done

    # ── Resolve lane constants in one yq pass, then shared constants through the effective-input helper ──
    declare -a ROUTER SELECTOR RECEIVER WETH GASLIM MAXFEE DATALEN
    echo "Resolved from config/state/<net>.inputs.yaml:"
    for i in "${!NETS[@]}"; do
      f="${ROOT_DIR}/config/state/${NETS[$i]}.inputs.yaml"
      [[ -f "$f" ]] || { echo "  ${NAMES[$i]}: inputs file not found: $f" >&2; exit 1; }
      { IFS= read -r ROUTER[$i]; IFS= read -r WETH[$i]
        IFS= read -r otod;        IFS= read -r dtoo
      } < <(yq "$ANCHORS" "$f")
      SELECTOR[$i]="$(just _l2-input-anchor "${NETS[$i]}" ethMainnetCcipChainSelector)"
      RECEIVER[$i]="$(just _l2-input-anchor "${NETS[$i]}" l1LidoCustomReceiverBytes32)"
      otod="${otod#0x}"; dtoo="${dtoo#0x}"
      [[ ${#otod} -eq 42 ]] || { echo "  ${NAMES[$i]}: malformed feeOtoD (got ${#otod} hex chars, want 42): 0x$otod" >&2; exit 1; }
      MAXFEE[$i]="$(cast to-dec "0x${otod:0:32}")"   # encodeCCIP bytes 0..15  = maxFee (uint128)
      GASLIM[$i]=$(( 16#${otod:34:8} ))              # encodeCCIP bytes 17..20 = gasLimit (uint32)
      DATALEN[$i]=$(( 52 + ${#dtoo} / 2 ))           # recipient[20] + amount[32] + feeDtoO
      printf '  %-8s router=%s weth=%s selector=%s gasLimit=%s maxFee=%s ETH\n' \
        "${NAMES[$i]}" "${ROUTER[$i]}" "${WETH[$i]}" "${SELECTOR[$i]}" "${GASLIM[$i]}" \
        "$(cast from-wei "${MAXFEE[$i]}")"
    done
    echo "  receiver (shared) = ${RECEIVER[0]}"
    echo

    rc=0
    for i in "${!NAMES[@]}"; do
      name="${NAMES[$i]}"; rpc_env="${RPC_ENVS[$i]}"; l2_env="${L2_ENVS[$i]}"
      echo "──── ${name} ────"
      rpc_val="${!rpc_env:-}"
      [[ -n "$rpc_val" ]] || rpc_val="${!l2_env:-}"
      if [[ -z "$rpc_val" ]]; then
        echo "  (skipped — set ${rpc_env} or ${l2_env})"; rc=1
        continue
      fi
      if ! cast chain-id --rpc-url "$rpc_val" >/dev/null 2>&1; then
        echo "  (skipped — ${rpc_env} not reachable: ${rpc_val})"; rc=1
        continue
      fi

      # ── Part A: configured token-transfer fee policy. The struct layout is FeeQuoter-version-specific,
      # so we ONLY decode the stable v1.5 EVM2EVMOnRamp layout (OP/Linea: 7 words, last = isEnabled).
      # Arb/Base run a newer FeeQuoter (2.0.0) whose TokenTransferFeeConfig differs — blind-decoding it
      # yields garbage, so we print its version and defer to the sweep (Part B = version-agnostic truth). ──
      cfg_decibps=""   # set only when reliably decoded (v1.5); cross-checked against the sweep below
      onramp="$(cast call "${ROUTER[$i]}" "getOnRamp(uint64)(address)" "${SELECTOR[$i]}" --rpc-url "$rpc_val" 2>&1)"
      if [[ ! "$onramp" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        echo "  config: (getOnRamp failed — $onramp)"; rc=1
      else
        ver="$(cast call "$onramp" "typeAndVersion()(string)" --rpc-url "$rpc_val" 2>&1)"
        if [[ "$ver" == *EVM2EVMOnRamp* ]]; then
          cfgraw="$(cast call "$onramp" "getTokenTransferFeeConfig(address)" "${WETH[$i]}" --rpc-url "$rpc_val" 2>&1)"
          if [[ "$cfgraw" =~ ^0x[0-9a-fA-F]+$ && ${#cfgraw} -ge 450 ]]; then
            h="${cfgraw#0x}"
            minc="$(cast to-dec "0x${h:0:64}")"; maxc="$(cast to-dec "0x${h:64:64}")"; dbps="$(cast to-dec "0x${h:128:64}")"
            isen="$(cast to-dec "0x${h:$(( (${#h}/64 - 1) * 64 )):64}")"; cfg_decibps="$dbps"
            printf '  config (EVM2EVMOnRamp v1.5): deciBps=%s (%s.%s bps) min=$%s.%02d max=$%s.%02d enabled=%s\n' \
              "$dbps" "$(( dbps / 10 ))" "$(( dbps % 10 ))" "$(( minc / 100 ))" "$(( minc % 100 ))" "$(( maxc / 100 ))" "$(( maxc % 100 ))" "$isen"
            [[ "$maxc" == "4294967295" ]] && echo "          (max = uint32 sentinel \$42,949,672.95 → effectively UNCAPPED: premium grows ~linearly with amount)"
          else
            echo "  config: (v1.5 transfer-fee read failed — $cfgraw)"; rc=1
          fi
        else
          dynraw="$(cast call "$onramp" "getDynamicConfig()" --rpc-url "$rpc_val" 2>&1)"
          if [[ "$dynraw" =~ ^0x[0-9a-fA-F]{128,}$ ]]; then
            feequoter="0x${dynraw:26:40}"   # DynamicConfig field 0 = feeQuoter (OnRamp.sol:71), left-padded word 0
            fqver="$(cast call "$feequoter" "typeAndVersion()(string)" --rpc-url "$rpc_val" 2>&1 | tr -d '"')"
            printf '  config: %s at %s — transfer-fee struct is version-specific, not decoded (sweep is authoritative)\n' "$fqver" "$feequoter"
          else
            echo "  config: (getDynamicConfig failed — $dynraw)"; rc=1
          fi
        fi
      fi

      # ── Part B: sweep the bridged amount through getFee (ground truth; data + gasLimit fixed, so only
      # the token-transfer premium can move). All fee math in awk — fees reach tens of ETH (>2^63 wei). ──
      extra="0x97a657c9$(printf '%064x' "${GASLIM[$i]}")"   # EVMExtraArgsV1 tag ++ abi.encode(gasLimit)
      data="0x$(printf '%0*d' $(( DATALEN[$i] * 2 )) 0)"     # zero bytes of the real payload length
      m="${MAXFEE[$i]}"; first=""; prev=""; prev_amt=""; maxseen=0; maxmd=0; breach_amt=""; breach_prev=""
      for amt in "${AMTS_WETH[@]}"; do
        amt_wei="$(cast to-wei "$amt" 2>/dev/null)" || { printf '    %-9s WETH  (bad amount)\n' "$amt"; continue; }
        msg="(${RECEIVER[$i]},${data},[(${WETH[$i]},${amt_wei})],0x0000000000000000000000000000000000000000,${extra})"
        raw="$(cast call "${ROUTER[$i]}" "$SIG" "${SELECTOR[$i]}" "$msg" --rpc-url "$rpc_val" 2>&1)" \
          || { printf '    %-9s WETH  getFee reverted: %s\n' "$amt" "$raw"; rc=1; continue; }
        fee_wei="${raw%% *}"                                 # strip any "[1.23e16]" annotation
        if [[ -z "$first" ]]; then d="—"; first="$fee_wei"; else
          d="$(awk -v a="$fee_wei" -v b="$prev" 'BEGIN{ printf "%.18f", (a-b)/1e18 }')"
          # marginal deci-bps vs previous point: WETH is the value token, so premiumETH ≈ amountWETH × bpsFrac.
          md="$(awk -v a="$fee_wei" -v b="$prev" -v x="$amt" -v y="$prev_amt" 'BEGIN{ dd=x-y; if(dd>0)printf "%.4f",(a-b)/1e18/dd*1e5; else print 0 }')"
          maxmd="$(awk -v a="$md" -v b="$maxmd" 'BEGIN{ print (a>b)?a:b }')"
        fi
        pct="$(awk -v f="$fee_wei" -v mm="$m" 'BEGIN{ if(mm==0)print"0.00"; else printf "%.2f", f*100/mm }')"
        flag="$(awk -v f="$fee_wei" -v mm="$m" 'BEGIN{ print (mm>0 && f>=mm)?"  ✗ exceeds maxFee":((mm>0 && f>=0.8*mm)?"  ⚠ >=80% maxFee":"") }')"
        printf '    %-9s WETH  fee=%s ETH  Δ=%s ETH  (%s%% maxFee)%s\n' "$amt" "$(cast from-wei "$fee_wei")" "$d" "$pct" "$flag"
        if [[ -z "$breach_amt" ]] && awk -v f="$fee_wei" -v mm="$m" 'BEGIN{ exit !(mm>0 && f>=mm) }'; then breach_amt="$amt"; breach_prev="$prev_amt"; fi
        maxseen="$(awk -v a="$fee_wei" -v b="$maxseen" 'BEGIN{ print (a>b)?a:b }')"
        prev="$fee_wei"; prev_amt="$amt"
      done

      if [[ -n "$first" ]]; then
        if awk -v x="$maxmd" 'BEGIN{ exit !(x>=1) }'; then   # >=0.1 bps slope ⇒ amount-sensitive
          verdict="$(awk -v x="$maxmd" 'BEGIN{ printf "VARIES — fee scales with the amount at ~%.2f bps in the linear band", x/10 }')"
        else
          verdict="FLAT — fee does NOT depend on the amount across the swept range"
        fi
        printf '  verdict: %s; max swept fee = %s ETH\n' "$verdict" "$(cast from-wei "$maxseen")"
        if [[ -n "$cfg_decibps" && "$cfg_decibps" != "0" ]] && awk -v c="$cfg_decibps" -v s="$maxmd" 'BEGIN{ exit !(s<0.8*c || s>1.25*c) }'; then
          printf '           ⚠ v1.5 config deciBps=%s disagrees with sweep-implied ~%.0f deci-bps — investigate\n' "$cfg_decibps" "$maxmd"
        fi
        if [[ -n "$breach_amt" ]]; then
          be="$(awk -v mm="$m" -v md="$maxmd" 'BEGIN{ if(md>0) printf "%.0f", (mm/1e18)/(md/1e5); else print "?" }')"
          printf '           ✗ fee reaches the %s ETH maxFee at ~%s WETH (observed between %s and %s WETH) → a sync at/above that size reverts (CCIPSenderExceedsMaxFee)\n' \
            "$(cast from-wei "$m")" "$be" "${breach_prev:-0}" "$breach_amt"
        else
          printf '           ✓ no swept amount (≤ %s WETH) reaches the %s ETH maxFee\n' "${AMTS_WETH[${#AMTS_WETH[@]}-1]}" "$(cast from-wei "$m")"
        fi
      fi
    done
    exit $rc

# Read-only health snapshot across L1 and all four lanes; see docs/monitoring.md.
# Checks wiring, owners, sync liveness, trapped funds, fee float, and recent delivery events.
# MONITOR_WINDOW_HOURS sets the event window (default 24). WARN/ALERT/SKIP exits nonzero.
postflight-monitor:
    @bash "{{justfile_directory()}}/script/commands/postflight-monitor.sh"


# Verify a small fastStake against the configured pool. Dry-run by default; SMOKE_CONFIRM=yes sends.
smoke-stake:
    @bash "{{justfile_directory()}}/script/commands/smoke-stake.sh"

# Verify pinned CRE forwarder bytecode, Router ABI, and receiver ERC-165 support across all lanes.
# A typeAndVersion label alone does not establish the supported onReport interface. Read-only.
verify-cre-forwarder:
    #!/usr/bin/env bash
    set -uo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    command -v yq >/dev/null 2>&1 || { echo "yq (mikefarah) is required" >&2; exit 1; }

    # Known-good forwarder bytecode (EXTCODEHASH) — identical across all four production lanes.
    EXPECT_CODEHASH="0x2b21870eb5ea9013a781ed3db7d5fab742b612b2ac8de0990ac9d95b22f795fc"
    # Dummy args for the view-function ABI probes (values irrelevant — we test selector existence).
    A="0x0000000000000000000000000000000000000001"
    B32="0x0000000000000000000000000000000000000000000000000000000000000000"
    B2="0x0000"
    IRECEIVER_ID="0x805f2132"   # type(IReceiver).interfaceId (onReport-only)
    ERC165_ID="0x01ffc9a7"      # ERC-165 base

    # Retry transport errors; only an EVM revert establishes an absent/reverting selector.
    # Return REPLY_STATUS in {ok,revert,rpcerr} and REPLY_OUT.
    probe () {
      local url="$1"; shift
      local attempt out
      for attempt in 1 2 3 4; do
        if out="$(cast call "$@" --rpc-url "$url" 2>&1)"; then REPLY_STATUS=ok; REPLY_OUT="$out"; return; fi
        # Classify transport errors first: a server response may also contain "revert".
        if grep -qiE 'error sending request|tcp connect|connection (refused|reset|closed|error)|timed out|dns error|deserializ|bad gateway|gateway time|service unavailable|temporarily unavailable|too many requests|server error|status code' <<<"$out"; then
          REPLY_STATUS=rpcerr; REPLY_OUT="$out"   # transport/server error → loop and retry
        elif grep -qiE 'execution reverted|revert' <<<"$out"; then
          REPLY_STATUS=revert; REPLY_OUT="$out"; return
        else
          REPLY_STATUS=rpcerr; REPLY_OUT="$out"   # unrecognized failure → treat as transport, retry
        fi
      done
    }
    # Fetch EXTCODEHASH with retries; echoes a 0x+64hex hash on success, empty on persistent RPC error.
    fetch_codehash () {
      local addr="$1" url="$2" attempt out
      for attempt in 1 2 3 4; do
        out="$(cast codehash "$addr" --rpc-url "$url" 2>/dev/null | tr -d '\r')"
        [[ "$out" =~ ^0x[0-9a-fA-F]{64}$ ]] && { echo "$out"; return; }
      done
      echo ""
    }

    # One source-of-truth lane list; display names + RPC env-var names derived (matches quote-ccip-fees).
    NETS=( optimism arbitrum base linea )
    declare -a NAMES RPC_ENVS L2_ENVS FWD RECV
    for net in "${NETS[@]}"; do
      u="$(echo "$net" | tr '[:lower:]' '[:upper:]')"
      NAMES+=("${u:0:1}${net:1}"); RPC_ENVS+=("RPC_$u"); L2_ENVS+=("L2_${u}_RPC_URL")
    done

    # ── Resolve each lane's pinned forwarder (.inputs.yaml) and deployed receiver (.deployed.yaml, if
    #    present) — addressed by anchor via recursive descent, never hardcoded. ──
    echo "Resolved from config/state/<net>.{inputs,deployed}.yaml:"
    for i in "${!NETS[@]}"; do
      inf="${ROOT_DIR}/config/state/${NETS[$i]}.inputs.yaml"
      dep="${ROOT_DIR}/config/state/${NETS[$i]}.deployed.yaml"
      [[ -f "$inf" ]] || { echo "  ${NAMES[$i]}: inputs file not found: $inf" >&2; exit 1; }
      FWD[$i]="$(yq '[.. | select(anchor=="l2CreForwarder")][0]' "$inf" | tr -d '"')"
      RECV[$i]=""
      if [[ -f "$dep" ]]; then
        r="$(yq '[.. | select(anchor=="l2CreReceiver")][0]' "$dep" 2>/dev/null | tr -d '"')"
        [[ "$r" =~ ^0x[0-9a-fA-F]{40}$ ]] && RECV[$i]="$r"
      fi
      printf '  %-9s forwarder=%s%s\n' "${NAMES[$i]}" "${FWD[$i]}" \
        "$( [[ -n "${RECV[$i]}" ]] && echo "  receiver=${RECV[$i]}" )"
    done
    echo "  expected EXTCODEHASH (all lanes) = ${EXPECT_CODEHASH}"
    echo

    rc=0; recv_skipped=0   # recv_skipped: PASSing lanes whose receiver-side ERC-165 cross-check did not run
    for i in "${!NAMES[@]}"; do
      name="${NAMES[$i]}"; rpc_env="${RPC_ENVS[$i]}"; l2_env="${L2_ENVS[$i]}"; fwd="${FWD[$i]}"
      echo "──── ${name}  ${fwd} ────"
      if [[ ! "$fwd" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        echo "  ✗ FAIL — l2CreForwarder anchor missing/malformed in inputs file"; rc=1; continue
      fi
      rpc_val="${!rpc_env:-}"
      [[ -n "$rpc_val" ]] || rpc_val="${!l2_env:-}"
      if [[ -z "$rpc_val" ]]; then echo "  (skipped — set ${rpc_env} or ${l2_env})"; rc=1; continue; fi
      if ! cast chain-id --rpc-url "$rpc_val" >/dev/null 2>&1; then
        echo "  (skipped — ${rpc_env} not reachable: ${rpc_val})"; rc=1; continue
      fi

      pass=1; unver=0

      # informational only — NOT a gate (see header: the live label is the stale "KeystoneForwarder 1.0.0")
      tv="$(cast call "$fwd" 'typeAndVersion()(string)' --rpc-url "$rpc_val" 2>&1 | tr -d '\r')"
      echo "  typeAndVersion = ${tv}   (informational; not a discriminator)"

      # 1) bytecode identity — the strongest pin
      ch="$(fetch_codehash "$fwd" "$rpc_val")"
      if [[ -z "$ch" ]]; then
        echo "  ⚠ EXTCODEHASH unverified (RPC error after retries)"; unver=1
      elif [[ "$ch" == "$EXPECT_CODEHASH" ]]; then
        echo "  ✓ EXTCODEHASH matches known-good Router build"
      else
        echo "  ✗ EXTCODEHASH MISMATCH: ${ch} — bytecode changed, re-verify ABI before trusting"; pass=0
      fi

      # 2) Router ABI present: isForwarder(address)
      probe "$rpc_val" "$fwd" 'isForwarder(address)(bool)' "$A"
      case "$REPLY_STATUS" in
        ok)     echo "  ✓ isForwarder(address) present (Router build)";;
        revert) echo "  ✗ isForwarder(address) absent — NOT the Router build"; pass=0;;
        *)      echo "  ⚠ isForwarder(address) unverified (RPC error)"; unver=1;;
      esac

      # 3) Router ABI present: 3-arg getTransmitter
      probe "$rpc_val" "$fwd" 'getTransmitter(address,bytes32,bytes2)(address)' "$A" "$B32" "$B2"
      case "$REPLY_STATUS" in
        ok)     echo "  ✓ getTransmitter(address,bytes32,bytes2) present (Router 3-arg form)";;
        revert) echo "  ✗ getTransmitter(address,bytes32,bytes2) absent — NOT the Router build"; pass=0;;
        *)      echo "  ⚠ getTransmitter(address,bytes32,bytes2) unverified (RPC error)"; unver=1;;
      esac

      # 4) legacy ABI ABSENT: 2-arg getTransmitter MUST revert (it is the legacy variant's signature)
      probe "$rpc_val" "$fwd" 'getTransmitter(address,bytes32)(address)' "$A" "$B32"
      case "$REPLY_STATUS" in
        revert) echo "  ✓ legacy getTransmitter(address,bytes32) absent (not the legacy variant)";;
        ok)     echo "  ✗ legacy getTransmitter(address,bytes32) RESPONDS — legacy onReport(bytes32,address,bytes) forwarder detected!"; pass=0;;
        *)      echo "  ⚠ legacy getTransmitter(address,bytes32) unverified (RPC error)"; unver=1;;
      esac

      # 5) optional receiver-side cross-check — does OUR receiver pass the ERC-165 gate this forwarder
      #    enforces? Skips cleanly (does not fail) when the address has no code on this RPC, e.g. a
      #    fork/rehearsal .deployed.yaml or a pre-deploy state.
      if [[ -n "${RECV[$i]}" ]]; then
        code="$(cast code "${RECV[$i]}" --rpc-url "$rpc_val" 2>/dev/null | tr -d '\r')"
        if [[ -z "$code" || "$code" == "0x" ]]; then
          echo "  · receiver cross-check skipped (l2CreReceiver ${RECV[$i]} has no code on this RPC — fork artifact or pre-deploy)"
          recv_skipped=$((recv_skipped + 1))
        else
          probe "$rpc_val" "${RECV[$i]}" 'supportsInterface(bytes4)(bool)' "$IRECEIVER_ID"; s1="$REPLY_OUT"; st1="$REPLY_STATUS"
          probe "$rpc_val" "${RECV[$i]}" 'supportsInterface(bytes4)(bool)' "$ERC165_ID";   s2="$REPLY_OUT"; st2="$REPLY_STATUS"
          if [[ "$st1" == ok && "$st2" == ok && "$s1" == "true" && "$s2" == "true" ]]; then
            echo "  ✓ CREReceiver ${RECV[$i]} passes the gate (supportsInterface ${IRECEIVER_ID} && ${ERC165_ID})"
          elif [[ "$st1" == rpcerr || "$st2" == rpcerr ]]; then
            echo "  ⚠ CREReceiver gate unverified (RPC error)"; unver=1
          else
            echo "  ✗ CREReceiver ${RECV[$i]} FAILS the ERC-165 gate (${IRECEIVER_ID}=${s1} ${ERC165_ID}=${s2}) — reports would not be delivered"; pass=0
          fi
        fi
      else
        echo "  · receiver cross-check skipped (no l2CreReceiver anchor in .deployed.yaml)"
        recv_skipped=$((recv_skipped + 1))
      fi

      if (( ! pass )); then echo "  ➜ FAIL"; rc=1
      elif (( unver )); then echo "  ➜ INCOMPLETE — some checks unverified (RPC errors); re-run"; rc=1
      else echo "  ➜ PASS"; fi
    done

    echo
    if (( rc == 0 )); then
      if (( recv_skipped > 0 )); then
        echo "OK (forwarder side) — every checked lane is the ERC-165-gating, 2-arg-onReport Router build."
        echo "   NOTE: the CREReceiver-side ERC-165 cross-check was SKIPPED on ${recv_skipped} lane(s) (no l2CreReceiver in .deployed.yaml, or no code on-chain) — receiver↔forwarder gate compatibility is NOT confirmed there; re-run post-deploy against a populated .deployed.yaml."
      else
        echo "OK — every checked lane is the ERC-165-gating, 2-arg-onReport Router build, and CREReceiver passes the gate on every lane."
      fi
    else
      echo "FAILures or skips above (rc=${rc})"
    fi
    exit $rc


# Verify the LOL Safe has code and the same signer set and threshold on every lane (read-only).
verify-lol-safe:
    #!/usr/bin/env bash
    set -uo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    command -v yq >/dev/null 2>&1 || { echo "yq (mikefarah) is required" >&2; exit 1; }

    # `cast call` probe with transport-error retries (same discipline as verify-cre-forwarder: a flaky
    # RPC surfaces as "unverified", never as a false "not a Safe"). REPLY_STATUS ∈ {ok,revert,rpcerr}.
    probe () {
      local url="$1"; shift
      local attempt out
      for attempt in 1 2 3 4; do
        if out="$(cast call "$@" --rpc-url "$url" 2>&1)"; then REPLY_STATUS=ok; REPLY_OUT="$out"; return; fi
        if grep -qiE 'error sending request|tcp connect|connection (refused|reset|closed|error)|timed out|dns error|deserializ|bad gateway|gateway time|service unavailable|temporarily unavailable|too many requests|server error|status code' <<<"$out"; then
          REPLY_STATUS=rpcerr; REPLY_OUT="$out"   # transport/server error → loop and retry
        elif grep -qiE 'execution reverted|revert' <<<"$out"; then
          REPLY_STATUS=revert; REPLY_OUT="$out"; return
        else
          REPLY_STATUS=rpcerr; REPLY_OUT="$out"   # unrecognized failure → treat as transport, retry
        fi
      done
    }

    NETS=( optimism arbitrum base linea )
    declare -a NAMES LOLS
    for net in "${NETS[@]}"; do
      u="$(echo "$net" | tr '[:lower:]' '[:upper:]')"
      NAMES+=("${u:0:1}${net:1}")
    done

    # ── Resolve each lane's effective l2LiquidityOwner anchor. The helper reads common + lane inputs
    #    and rejects shadowing, so the unified-address claim is structural as well as value-checked. ──
    echo "Resolved from common.inputs.yaml + config/state/<net>.inputs.yaml (l2LiquidityOwner):"
    for i in "${!NETS[@]}"; do
      inf="${ROOT_DIR}/config/state/${NETS[$i]}.inputs.yaml"
      [[ -f "$inf" ]] || { echo "  ${NAMES[$i]}: inputs file not found: $inf" >&2; exit 1; }
      LOLS[$i]="$(just _l2-input-anchor "${NETS[$i]}" l2LiquidityOwner)"
      [[ "${LOLS[$i]}" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "  ${NAMES[$i]}: effective l2LiquidityOwner anchor missing/malformed" >&2; exit 1; }
      printf '  %-9s %s\n' "${NAMES[$i]}" "${LOLS[$i]}"
    done
    LOL="${LOLS[0]}"
    for i in "${!NETS[@]}"; do
      [[ "${LOLS[$i]}" == "$LOL" ]] || { echo "✗ FAIL — lanes disagree on the LOL address (see the list above): the unified-Safe design holds ONE address on all four lanes" >&2; exit 1; }
    done
    echo

    rc=0
    declare -a THRS OSETS   # per-lane threshold + normalized owner set (lowercased, sorted, comma-joined)
    for i in "${!NAMES[@]}"; do
      name="${NAMES[$i]}"
      u="$(echo "${NETS[$i]}" | tr '[:lower:]' '[:upper:]')"
      echo "──── ${name}  ${LOL} ────"
      THRS[$i]=""; OSETS[$i]=""

      # RPC: local proxy → remote override → legacy var; each candidate is probed before use.
      rpc_val=""; rpc_env=""
      for cand_env in "RPC_$u" "RPC_${u}_REMOTE" "L2_${u}_RPC_URL"; do
        cand="${!cand_env:-}"
        [[ -n "$cand" ]] || continue
        if cast chain-id --rpc-url "$cand" >/dev/null 2>&1; then rpc_val="$cand"; rpc_env="$cand_env"; break; fi
      done
      if [[ -z "$rpc_val" ]]; then echo "  ✗ no reachable RPC (tried RPC_$u, RPC_${u}_REMOTE, L2_${u}_RPC_URL)"; rc=1; continue; fi
      echo "  rpc = \$${rpc_env}"

      pass=1; unver=0

      # 1) The configured Safe must be deployed.
      code="$(cast code "$LOL" --rpc-url "$rpc_val" 2>/dev/null | tr -d '\r')"
      if [[ -z "$code" ]]; then
        echo "  ⚠ code unverified (RPC error)"; unver=1
      elif [[ "$code" == "0x" ]]; then
        echo "  ✗ NO CODE at ${LOL} on this lane — the configured liquidity owner cannot operate this pool"; pass=0
      else
        echo "  ✓ contract deployed (code present)"
      fi

      if (( pass && ! unver )); then
        # informational only — the Safe version label (not a discriminator)
        probe "$rpc_val" "$LOL" 'VERSION()(string)'
        [[ "$REPLY_STATUS" == ok ]] && echo "  VERSION = ${REPLY_OUT}   (informational)"

        # 2) answers as a Safe: threshold + owners
        probe "$rpc_val" "$LOL" 'getThreshold()(uint256)'
        case "$REPLY_STATUS" in
          ok)     THRS[$i]="$REPLY_OUT"; echo "  ✓ getThreshold() = ${REPLY_OUT}";;
          revert) echo "  ✗ getThreshold() reverts — not a Safe at this address"; pass=0;;
          *)      echo "  ⚠ getThreshold() unverified (RPC error)"; unver=1;;
        esac
        probe "$rpc_val" "$LOL" 'getOwners()(address[])'
        case "$REPLY_STATUS" in
          ok)
            # Normalize to a SET (strip brackets, lowercase, sort): Safe stores owners as a linked
            # list whose ORDER legitimately differs between chains; only the set is load-bearing.
            OSETS[$i]="$(tr -d '[]' <<<"$REPLY_OUT" | tr ',' '\n' | tr -d ' ' | tr '[:upper:]' '[:lower:]' | sed '/^$/d' | sort | paste -s -d, -)"
            n_owners="$(awk -F, '{print NF}' <<<"${OSETS[$i]}")"
            echo "  ✓ getOwners() → ${n_owners} owners:"
            tr ',' '\n' <<<"${OSETS[$i]}" | sed 's/^/      /'
            ;;
          revert) echo "  ✗ getOwners() reverts — not a Safe at this address"; pass=0;;
          *)      echo "  ⚠ getOwners() unverified (RPC error)"; unver=1;;
        esac
      fi

      if (( ! pass )); then echo "  ➜ FAIL"; rc=1
      elif (( unver )); then echo "  ➜ INCOMPLETE — some checks unverified (RPC errors); re-run"; rc=1
      else echo "  ➜ PASS"; fi
    done

    # ── Cross-lane identity: same threshold + same owner SET everywhere — the substance of "ONE Safe". ──
    echo
    if (( rc == 0 )); then
      for i in "${!NAMES[@]}"; do
        if [[ "${THRS[$i]}" != "${THRS[0]}" || "${OSETS[$i]}" != "${OSETS[0]}" ]]; then
          echo "✗ FAIL — ${NAMES[$i]} differs from ${NAMES[0]} (threshold ${THRS[$i]:-?} vs ${THRS[0]:-?}, or the owner sets above diverge). Same address ≠ same Safe — align the signer sets before treating the four instances as one actor."
          rc=1
        fi
      done
    fi

    if (( rc == 0 )); then
      n_owners="$(awk -F, '{print NF}' <<<"${OSETS[0]}")"
      echo "OK — LOL Safe ${LOL} deployed on all 4 lanes; one signer set (${THRS[0]}-of-${n_owners}) everywhere."
    else
      echo "FAILures or skips above (rc=${rc})"
    fi
    exit $rc

[private]
_state-verify network rpc_url='':
    #!/usr/bin/env bash
    set -euo pipefail

    NETWORK="{{network}}"
    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    source "$ROOT_DIR/script/shared/cre-env.sh"
    cre_env_load_rpc_bindings
    L1_STATE_MATE_RPC_URL="$(resolve_l1_rpc)"
    RPC_URL="{{rpc_url}}"
    # Map network name to default RPC env var.
    # Priority: explicit argument > lane overlay > machine upstream > Foundry alias.
    case "$NETWORK" in
      optimism) DEFAULT_RPC_URL="${L2_RPC_URL:-${RPC_OPTIMISM_REMOTE:-${L2_OPTIMISM_RPC_URL:-}}}" ;;
      arbitrum) DEFAULT_RPC_URL="${L2_RPC_URL:-${RPC_ARBITRUM_REMOTE:-${L2_ARBITRUM_RPC_URL:-}}}" ;;
      base)     DEFAULT_RPC_URL="${L2_RPC_URL:-${RPC_BASE_REMOTE:-${L2_BASE_RPC_URL:-}}}" ;;
      linea)    DEFAULT_RPC_URL="${L2_RPC_URL:-${RPC_LINEA_REMOTE:-${L2_LINEA_RPC_URL:-}}}" ;;
      *)        echo "Unknown network: $NETWORK" >&2; exit 1 ;;
    esac

    STATE_MATE_DIR="$ROOT_DIR/lib/state-mate"
    # All four mainnet L2 lanes share one wiring file plus one common input file; each run adds its
    # lane input delta and deployed sibling explicitly. Absolute paths, since the runner cd's into
    # lib/state-mate.
    STATE_MATE_CONFIG="$ROOT_DIR/config/state/l2.yaml"
    # Deployed state is split the same way: common.deployed.yaml carries the outputs shared by all
    # four lanes (the ONE consolidated CRE workflow id, deployed.l1) and <net>.deployed.yaml the
    # lane's own three contracts + revoked trigger (deployed.l2). state-mate merges the two maps.
    STATE_MATE_SIBLING_ARGS=(
      --inputs   "$ROOT_DIR/config/state/common.inputs.yaml"
      --inputs   "$ROOT_DIR/config/state/$NETWORK.inputs.yaml"
      --deployed "$ROOT_DIR/config/state/common.deployed.yaml"
      --deployed "$ROOT_DIR/config/state/$NETWORK.deployed.yaml"
    )
    die() { echo "$*" >&2; exit 1; }

    command -v node >/dev/null 2>&1 || die "Missing required command: node"
    if command -v corepack >/dev/null 2>&1; then
      YARN_CMD=(corepack yarn)
    elif command -v yarn >/dev/null 2>&1; then
      YARN_CMD=(yarn)
    else
      die "Missing required command: yarn (or corepack)"
    fi

    if [[ ! -d "$STATE_MATE_DIR/node_modules" ]]; then
      echo "Installing state-mate dependencies"
      (cd "$STATE_MATE_DIR" && "${YARN_CMD[@]}" install --immutable)
    fi

    RPC_URL="${RPC_URL:-$DEFAULT_RPC_URL}"
    [[ -n "$RPC_URL" ]] || die "Missing RPC URL: pass [rpc_url] or set L2_RPC_URL."
    echo "Running combined L1 + L2 state-mate checks for $NETWORK"
    # Show the invocation with credential-bearing RPC URLs redacted.
    echo "+ cd $STATE_MATE_DIR"
    echo "+ L1_RPC_URL=<ethereum-rpc> L2_STATE_MATE_RPC_URL=<lane-rpc> ${YARN_CMD[*]} start $STATE_MATE_CONFIG ${STATE_MATE_SIBLING_ARGS[*]+${STATE_MATE_SIBLING_ARGS[*]}}"

    set +e
    (
      cd "$STATE_MATE_DIR"
      env -u NO_COLOR L1_RPC_URL="$L1_STATE_MATE_RPC_URL" L2_STATE_MATE_RPC_URL="$RPC_URL" \
        FORCE_COLOR=3 CLICOLOR_FORCE=1 "${YARN_CMD[@]}" start "$STATE_MATE_CONFIG" \
        "${STATE_MATE_SIBLING_ARGS[@]}"
    )
    STATE_MATE_EXIT="$?"
    set -e

    echo ""
    # NB: a failing wiring run does NOT abort here — every remaining config run still executes, so one
    # invocation reports the COMPLETE picture (a partial pass is the false-pass hazard). Exits are
    # accumulated and re-raised at the very end.
    if [[ "$STATE_MATE_EXIT" -eq 0 ]]; then
      echo "$NETWORK state verification passed"
    else
      echo "state-mate checks FAILED for $NETWORK (continuing with the remaining runs)" >&2
    fi

    # Linea also checks the revoked Gelato role. The revoked trigger is checked by the shared
    # l2.yaml run for every lane; only this genuinely Linea-specific assertion remains separate.
    GELATO_EXIT=0
    GELATO_CONFIG=""
    [[ "$NETWORK" == "linea" ]] && GELATO_CONFIG="config/state/l2-linea-gelato.yaml"
    if [[ -n "$GELATO_CONFIG" ]]; then
      echo "Running Linea revoked Gelato role check"
      echo "+ cd $STATE_MATE_DIR"
      echo "+ L2_STATE_MATE_RPC_URL=<lane-rpc> ${YARN_CMD[*]} start $ROOT_DIR/$GELATO_CONFIG --only l2"
      set +e
      (
        cd "$STATE_MATE_DIR"
        env -u NO_COLOR L2_STATE_MATE_RPC_URL="$RPC_URL" FORCE_COLOR=3 CLICOLOR_FORCE=1 \
          "${YARN_CMD[@]}" start "$ROOT_DIR/$GELATO_CONFIG" --only "l2"
      )
      GELATO_EXIT="$?"
      set -e
      if [[ "$GELATO_EXIT" -eq 0 ]]; then
        echo "Linea Gelato state verification passed"
      else
        echo "Linea Gelato state-mate check FAILED" >&2
      fi
    fi

    # Single non-zero exit for the whole recipe, naming every run that failed.
    FAILED_RUNS=()
    [[ "$STATE_MATE_EXIT" -eq 0 ]] || FAILED_RUNS+=("combined L1+L2 wiring (config/state/l2.yaml)")
    [[ "$GELATO_EXIT" -eq 0 ]] || FAILED_RUNS+=("Linea Gelato ($GELATO_CONFIG)")
    if (( ${#FAILED_RUNS[@]} > 0 )); then
      die "state-mate checks failed for $NETWORK: ${FAILED_RUNS[*]}"
    fi


# Verify shared L1 ownership, permissions, and per-lane wiring with state-mate.
verify-l1-state-mate l1_rpc_url='':
    #!/usr/bin/env bash
    set -euo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    RPC_URL="{{l1_rpc_url}}"
    [[ -n "$RPC_URL" ]] || RPC_URL="${L1_RPC_URL:-}"
    [[ -n "$RPC_URL" ]] || { echo "Missing RPC URL: pass [l1_rpc_url] or set L1_RPC_URL" >&2; exit 1; }

    STATE_MATE_DIR="$ROOT_DIR/lib/state-mate"
    STATE_MATE_CONFIG="$ROOT_DIR/config/state/ethereum.yaml"

    command -v node >/dev/null 2>&1 || { echo "Missing required command: node" >&2; exit 1; }
    if command -v corepack >/dev/null 2>&1; then
      YARN_CMD=(corepack yarn)
    elif command -v yarn >/dev/null 2>&1; then
      YARN_CMD=(yarn)
    else
      echo "Missing required command: yarn (or corepack)" >&2; exit 1
    fi

    if [[ ! -d "$STATE_MATE_DIR/node_modules" ]]; then
      echo "Installing state-mate dependencies"
      (cd "$STATE_MATE_DIR" && "${YARN_CMD[@]}" install --immutable)
    fi

    echo "Running L1 state-mate checks against ${RPC_URL}"
    (
      cd "$STATE_MATE_DIR"
      env -u NO_COLOR L1_RPC_URL="$RPC_URL" FORCE_COLOR=3 CLICOLOR_FORCE=1 \
        "${YARN_CMD[@]}" start "$STATE_MATE_CONFIG" --only "l1"
    )
    echo "L1 state verification passed"


# Verify configured Optimism ownership, wiring, and CRE registration (read-only).
verify-optimism-state rpc_url='':
    @just _state-verify optimism "{{rpc_url}}"

verify-arbitrum-state rpc_url='':
    @just _state-verify arbitrum "{{rpc_url}}"

verify-base-state rpc_url='':
    @just _state-verify base "{{rpc_url}}"

verify-linea-state rpc_url='':
    @just _state-verify linea "{{rpc_url}}"

# Report ETH, WETH, and wstETH balances across system accounts; minimum display amount is 0.00001.
# A failed balance read is shown as TOKEN ?, never zero. Read-only; no signing keys.
balances:
    @bash "{{justfile_directory()}}/script/commands/balances.sh"


# Read current owners and known role holders across all lanes; report every mismatch.
audit-ownership:
    @just _audit-ownership-net optimism Optimism "${L2_OPTIMISM_RPC_URL:-${RPC_OPTIMISM_REMOTE:-$RPC_OPTIMISM}}"
    @echo ""
    @just _audit-ownership-net arbitrum Arbitrum "${L2_ARBITRUM_RPC_URL:-${RPC_ARBITRUM_REMOTE:-$RPC_ARBITRUM}}"
    @echo ""
    @just _audit-ownership-net base Base "${L2_BASE_RPC_URL:-${RPC_BASE_REMOTE:-$RPC_BASE}}"
    @echo ""
    @just _audit-ownership-net linea Linea "${L2_LINEA_RPC_URL:-${RPC_LINEA_REMOTE:-$RPC_LINEA}}"

[no-exit-message]
_audit-ownership-net net label rpc_url:
    #!/usr/bin/env bash
    set -uo pipefail
    inp="config/state/{{net}}.inputs.yaml"
    dep="config/state/{{net}}.deployed.yaml"
    rpc="{{rpc_url}}"
    ext () { just _l2-input-anchor "{{net}}" "$1"; }
    dpl () { yq ".deployed.l2[] | select(anchor == \"$1\")" "$dep" | tr -d '"'; }

    # NB: no shell variable here may be named INITIAL_OWNER / L1_RECEIVER / LIDO_DAO_AGENT /
    # L1_PROXY_ADMIN_ADDR — `verify-constants-sync`'s `just_global` greps the justfile for exactly those
    # assignment names and would read this line as a drifted address literal. Hence INIT_OWNER.
    SENDER="$(ext l2CustomSender)";      PROXY_ADMIN="$(ext l2ProxyAdmin)"
    INIT_OWNER="$(ext initialOwner)";    GOV_EXEC="$(ext l2GovernanceExecutor)"
    LOL="$(ext l2LiquidityOwner)";         DEPLOYER="$(ext l2LidoDeployer)"
    AUTOMATION_OWNER="$(ext l2AutomationOwner)"; WORKFLOW_OWNER="$AUTOMATION_OWNER"
    FORWARDER="$(ext l2CreForwarder)";     OLD_AUTOMATION="$(ext RETIRED_l2ChainlinkSyncAutomation)"
    POOL="$(dpl l2OraclePool)"; TRIGGER="$(dpl l2SyncTrigger)"; RECEIVER="$(dpl l2CreReceiver)"
    RETIRED_TRIGGER="$(dpl RETIRED_l2SyncTrigger)"
    # Linea also checks a revoked Gelato automation; its anchor lives under misc: in the standalone
    # gelato wiring file (see l2-linea-gelato.yaml).
    OLD_GELATO=""
    if [[ "{{net}}" == "linea" ]]; then
      OLD_GELATO="$(yq '.misc[] | select(anchor == "RETIRED_l2GelatoSyncAutomation")' config/state/l2-linea-gelato.yaml | tr -d '"')"
    fi

    SYNC_ROLE="$(cast keccak 'SYNC_ROLE')"
    ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"
    TRIGGER_SYNC_SEL="$(cast sig 'triggerSync()')"

    # `cast call` with transport retries: an RPC hiccup must read as `?`, never as a false 0x0/false.
    rd () { local out; for _ in 1 2 3; do if out="$(cast call "$@" --rpc-url "$rpc" 2>/dev/null)"; then echo "$out"; return; fi; done; echo "?"; }
    # Label a resolved address with the anchor it matches — the whole point of the report.
    # `tr`, not ${v,,}: macOS ships bash 3.2, where the lowercase expansion is a syntax error.
    lc () { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
    who () {
      local a; a="$(lc "$1")"
      case "$a" in
        "$(lc "$LOL")")            echo "LOL multisig" ;;
        "$(lc "$AUTOMATION_OWNER")") echo "Automation Multisig" ;;
        "$(lc "$WORKFLOW_OWNER")")   echo "Workflow owner" ;;
        "$(lc "$DEPLOYER")")       echo "Lido Deployer" ;;
        "$(lc "$INIT_OWNER")")  echo "Initial Owner" ;;
        "$(lc "$GOV_EXEC")")       echo "L2 gov executor" ;;
        "$(lc "$FORWARDER")")      echo "CRE forwarder" ;;
        "$(lc "$TRIGGER")")        echo "SyncTrigger" ;;
        "$(lc "$RECEIVER")")       echo "CREReceiver" ;;
        "$(lc "$RETIRED_TRIGGER")") echo "RETIRED SyncTrigger" ;;
        "$(lc "$POOL")")           echo "OraclePool" ;;
        "?"|"")                    echo "read failed" ;;
        *)                         echo "UNKNOWN — investigate" ;;
      esac
    }
    row () { printf '  %-46s %-42s %s\n' "$1" "$2" "$3"; }

    echo "════ {{label}} ════ block $(cast block-number --rpc-url "$rpc" 2>/dev/null || echo '?')"
    echo "  anchors (config/state/{{net}}.{inputs,deployed}.yaml):"
    printf '    %-22s %s\n' \
      CustomSender "$SENDER" ProxyAdmin "$PROXY_ADMIN" InitialOwner "$INIT_OWNER" \
      GovExecutor "$GOV_EXEC" LOL "$LOL" AutomationOwner "$AUTOMATION_OWNER" WorkflowOwner "$WORKFLOW_OWNER" \
      Deployer "$DEPLOYER" CreForwarder "$FORWARDER" \
      OraclePool "$POOL" SyncTrigger "$TRIGGER" CREReceiver "$RECEIVER" \
      RetiredSyncTrigger "$RETIRED_TRIGGER" OldAutomation "$OLD_AUTOMATION"
    [[ -n "$OLD_GELATO" ]] && printf '    %-22s %s\n' OldGelatoAutomation "$OLD_GELATO"
    echo
    echo "  ── owner() ──"
    for pair in "OraclePool:$POOL" "SyncTrigger:$TRIGGER" "CREReceiver:$RECEIVER" \
      "L2ProxyAdmin:$PROXY_ADMIN"; do
      v="$(rd "${pair#*:}" 'owner()(address)')"; row "${pair%%:*}.owner()" "$v" "= $(who "$v")"
    done
    echo "  ── automation wiring ──"
    v="$(rd "$RECEIVER" 'getForwarder()(address)')";      row "CREReceiver.getForwarder()" "$v" "= $(who "$v")"
    v="$(rd "$RECEIVER" 'getExpectedAuthor()(address)')"; row "CREReceiver.getExpectedAuthor()" "$v" "= $(who "$v")"
    v="$(rd "$RECEIVER" 'isCallAllowed(address,bytes4)(bool)' "$TRIGGER" "$TRIGGER_SYNC_SEL")"
    row "CREReceiver.isCallAllowed(trigger,triggerSync)" "$v" ""
    v="$(rd "$TRIGGER" 'getForwarder()(address)')";       row "SyncTrigger.getForwarder()" "$v" "= $(who "$v")"
    v="$(rd "$TRIGGER" 'SENDER()(address)')";             row "SyncTrigger.SENDER()" "$v" "$([[ "$(lc "$v")" == "$(lc "$SENDER")" ]] && echo '= CustomSender' || echo 'MISMATCH — investigate')"
    row "SyncTrigger ETH float" "$(cast balance "$TRIGGER" --rpc-url "$rpc" 2>/dev/null || echo '?') wei" "getMaxFees() = $(rd "$TRIGGER" 'getMaxFees()(uint256)')"
    echo "  ── CustomSender pointer + roles ──"
    v="$(rd "$SENDER" 'getOraclePool()(address)')";       row "CustomSender.getOraclePool()" "$v" "= $(who "$v")"
    # Who may grant/revoke SYNC_ROLE. Upstream never calls `_setRoleAdmin`, so this is expected to be
    # DEFAULT_ADMIN_ROLE (0x00) — i.e. there is NO separate SYNC_ROLE manager, the sender's admin is it.
    # A non-zero value means someone upgraded the implementation to introduce a dedicated admin role.
    v="$(rd "$SENDER" 'getRoleAdmin(bytes32)(bytes32)' "$SYNC_ROLE")"
    case "$v" in
      "$ADMIN_ROLE") note="= DEFAULT_ADMIN_ROLE — no dedicated SYNC_ROLE manager" ;;
      "?"|"")        note="read failed" ;;
      *)             note="DEDICATED SYNC_ROLE ADMIN — investigate" ;;
    esac
    row "getRoleAdmin(SYNC_ROLE)" "$v" "$note"
    for pair in "SyncTrigger:$TRIGGER" "RETIRED SyncTrigger:$RETIRED_TRIGGER" \
      "old automation:$OLD_AUTOMATION" ${OLD_GELATO:+"old gelato:$OLD_GELATO"}; do
      row "hasRole(SYNC_ROLE, ${pair%%:*})" "$(rd "$SENDER" 'hasRole(bytes32,address)(bool)' "$SYNC_ROLE" "${pair#*:}")" "${pair#*:}"
    done
    for pair in "Initial Owner:$INIT_OWNER" "gov executor:$GOV_EXEC" "Lido Deployer:$DEPLOYER" "LOL:$LOL"; do
      row "hasRole(DEFAULT_ADMIN_ROLE, ${pair%%:*})" "$(rd "$SENDER" 'hasRole(bytes32,address)(bool)' "$ADMIN_ROLE" "${pair#*:}")" "${pair#*:}"
    done


# Check resolved IR settings, custom storage-layout usage, compiler warnings, and deployed metadata.
# See docs/compiler-bug-exposure.md for the exact scope and limits. Read-only; RPC checks may be skipped.
verify-compiler-provenance:
    #!/usr/bin/env bash
    set -uo pipefail
    fail=0
    solc_pin="$(yq -p toml -oy '.profile.default.solc' foundry.toml)"
    echo "── local build settings (foundry.toml + artifact metadata) ──"
    printf '  %-34s %s\n' "foundry.toml solc" "$solc_pin"
    for k in via_ir optimizer optimizer_runs evm_version; do
      printf '  %-34s %s\n' "$k" "$(forge config | sed -n "s/^$k = //p")"
    done

    echo
    echo "── G1  via_ir must be false ──"
    via="$(forge config | sed -n 's/^via_ir = //p')"
    if [[ "$via" == "false" ]]; then echo "  OK   via_ir = false"; else
      echo "  FAIL via_ir = $via — the IR pipeline is on; re-run the UnsoundSpillInMutualRecursion analysis"; fail=1; fi

    echo
    echo "── G2  no custom storage-layout specifier in the compilation closure ──"
    for pair in "src/SyncTrigger.sol:SyncTrigger" "src/cre/CREReceiver.sol:CREReceiver"; do
      art="out/$(basename "${pair%%:*}")/${pair##*:}.json"
      [[ -f "$art" ]] || { echo "  FAIL missing artifact $art — run 'forge build' first"; fail=1; continue; }
      hits=0
      while read -r f; do
        [[ -f "$f" ]] || continue
        if grep -qE '(^|[^[:alnum:]_])layout[[:space:]]+at[[:space:]]' "$f"; then
          echo "  FAIL 'layout at' in $f"; hits=$((hits + 1)); fi
      done < <(jq -r '(.metadata | if type == "string" then fromjson else . end).sources | keys[]' "$art")
      n="$(jq -r '(.metadata | if type == "string" then fromjson else . end).sources | length' "$art")"
      [[ "$hits" == 0 ]] && printf '  OK   %-12s clean across %s closure source(s)\n' "${pair##*:}" "$n" || fail=1
    done

    echo
    echo "── G3  solc emits no storage-end warning for either contract ──"
    warn="$(forge build --force 2>&1 | grep -i 'close to the end of storage' || true)"
    if [[ -z "$warn" ]]; then echo "  OK   warning absent from a clean build"; else
      echo "  FAIL $warn"; fail=1; fi

    echo
    echo "── G4  deployed CBOR metadata trailer == local artifact trailer ──"
    trailer () { # strip 0x, read the 2-byte CBOR length suffix, echo the whole trailer lowercased
      local c="${1#0x}"; [[ ${#c} -gt 8 ]] || { echo ""; return; }
      local n=$(( 0x${c: -4} )); echo "${c: -$(( (n + 2) * 2 ))}" | tr 'A-F' 'a-f'; }
    for pair in "SyncTrigger:src/SyncTrigger.sol:l2SyncTrigger" "CREReceiver:src/cre/CREReceiver.sol:l2CreReceiver"; do
      name="${pair%%:*}"; rest="${pair#*:}"; src="${rest%%:*}"; anchor="${rest##*:}"
      want="$(trailer "$(jq -r '.deployedBytecode.object' "out/$(basename "$src")/$name.json")")"
      printf '  %s local trailer %s\n' "$name" "$want"
      for net in optimism arbitrum base linea; do
        case "$net" in
          optimism) rpc="${L2_OPTIMISM_RPC_URL:-${RPC_OPTIMISM_REMOTE:-${RPC_OPTIMISM:-}}}" ;;
          arbitrum) rpc="${L2_ARBITRUM_RPC_URL:-${RPC_ARBITRUM_REMOTE:-${RPC_ARBITRUM:-}}}" ;;
          base)     rpc="${L2_BASE_RPC_URL:-${RPC_BASE_REMOTE:-${RPC_BASE:-}}}" ;;
          linea)    rpc="${L2_LINEA_RPC_URL:-${RPC_LINEA_REMOTE:-${RPC_LINEA:-}}}" ;;
        esac
        addr="$(yq ".deployed.l2[] | select(anchor == \"$anchor\")" "config/state/$net.deployed.yaml" | tr -d '"')"
        if [[ -z "$rpc" ]]; then printf '    %-9s %s  SKIP (no RPC)\n' "$net" "$addr"; continue; fi
        got="$(trailer "$(cast code "$addr" --rpc-url "$rpc" 2>/dev/null || echo)")"
        if [[ -z "$got" ]]; then printf '    %-9s %s  FAIL (no code / RPC error)\n' "$net" "$addr"; fail=1
        elif [[ "$got" == "$want" ]]; then printf '    %-9s %s  OK\n' "$net" "$addr"
        else printf '    %-9s %s  FAIL trailer %s\n' "$net" "$addr" "$got"; fail=1; fi
      done
    done

    echo
    if [[ "$fail" == 0 ]]; then echo "verify-compiler-provenance: ALL CHECKS PASSED (solc $solc_pin)"; else
      echo "verify-compiler-provenance: FAILURES ABOVE — re-run docs/compiler-bug-exposure.md" >&2; fi
    exit "$fail"


# ──────────────────────────────────────────────────────────────────
# CRE (Chainlink Runtime Environment) workflow commands
# ──────────────────────────────────────────────────────────────────

# Run CREReceiver unit tests (no fork required)
test-cre-receiver:
    forge test --match-contract CREReceiverTest -vvv

# Run CRE integration tests (fork-based, requires L1_RPC_URL + all four L2_<NET>_RPC_URL bindings)
test-cre-integration:
    forge test --match-contract CREIntegrationTest -vvv

# Run all CRE Solidity tests (unit + integration)
test-cre:
    forge test --match-contract 'CRE' -vvv

# Run CRE TypeScript workflow encoding tests
test-cre-workflow:
    cd cre-workflows/sync-automation && bun test

# Verify the dashboard's source/config pins and its byte-exact embedded config copy. On drift, print
# the replacement constants and exit non-zero so a caller cannot mistake stale pins for regenerated ones.
cre-workflow-hash:
    @bash "{{justfile_directory()}}/script/commands/cre-workflow-hash.sh"

# CRE CLI v1.27.0 hardcodes empty WorkflowRegistry attributes. Read its unsigned upsert calldata from
# stdin (or CRE_CALLDATA), replace only attributes with the two repository digests, and print calldata
# for the Safe. The workflow ID stays unchanged because attributes are not an ID input.
cre-attach-params:
    @bash "{{justfile_directory()}}/script/commands/cre-attach-params.sh"

# Retry an L1 MessageFailed event: dry-run (default) or send.
retry-failed-message tx mode='dry-run' message_id='':
    @bash "{{justfile_directory()}}/script/commands/retry-failed-message.sh" "{{tx}}" "{{mode}}" "{{message_id}}"

# Run all CRE tests (Solidity + TypeScript)
test-cre-all: test-cre test-cre-workflow

# Install CRE workflow SDK dependencies; the separate CLI is installed by setup-cre-cli.
setup-cre:
    cd cre-workflows/sync-automation && bun install

# Install the pinned CRE CLI into the ignored repo-local .cre directory and verify its checksum.
setup-cre-cli:
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION="{{CRE_CLI_VERSION}}"
    BIN_DIR="{{CRE_DIR}}/bin"
    CRE_BIN="$BIN_DIR/cre"

    if [[ -x "$CRE_BIN" ]] && "$CRE_BIN" version 2>/dev/null | grep -qF "$VERSION"; then
      echo "cre CLI already at $VERSION: $CRE_BIN"
      exit 0
    fi

    for cmd in curl unzip; do
      command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
    done

    # Asset naming per the upstream installer: darwin ships .zip, linux .tar.gz. The generic
    # (non-ldd2-35) linux build is the default there too.
    case "$(uname -s)" in
      Darwin) PLATFORM=darwin; EXT=zip ;;
      Linux)  PLATFORM=linux;  EXT=tar.gz ;;
      *) echo "Unsupported OS: $(uname -s) (cre ships darwin/linux; Windows needs the PowerShell installer)" >&2; exit 1 ;;
    esac
    case "$(uname -m)" in
      x86_64|amd64)  ARCH=amd64 ;;
      arm64|aarch64) ARCH=arm64 ;;
      *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
    esac

    ASSET="cre_${PLATFORM}_${ARCH}.${EXT}"
    BASE_URL="https://github.com/smartcontractkit/cre-cli/releases/download/$VERSION"
    # The archive is named without the version; the binary INSIDE it (and the checksums.txt entry)
    # carry the tag.
    MEMBER="cre_${VERSION}_${PLATFORM}_${ARCH}"
    CHECKSUM_KEY="cre_${VERSION}_${PLATFORM}_${ARCH}.${EXT}"

    echo "Installing cre $VERSION ($PLATFORM/$ARCH) into $BIN_DIR"

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT

    curl --fail --location --silent --show-error "$BASE_URL/$ASSET" --output "$TMP_DIR/$ASSET" \
      || { echo "Failed to download $BASE_URL/$ASSET — is $VERSION a real release tag?" >&2; exit 1; }
    curl --fail --location --silent --show-error "$BASE_URL/checksums.txt" --output "$TMP_DIR/checksums.txt" \
      || { echo "Failed to download $BASE_URL/checksums.txt" >&2; exit 1; }

    # checksums.txt lines look like `cre_v1.27.0_darwin_arm64.zip: <sha256>`; the ldd-2.35 linux
    # variants reuse the same filename with a ` (ldd-2.35)` suffix, so match the key EXACTLY up to
    # the colon rather than substring-matching the filename.
    EXPECTED="$(awk -F': ' -v k="$CHECKSUM_KEY" '$1 == k { print $2; exit }' "$TMP_DIR/checksums.txt")"
    [[ -n "$EXPECTED" ]] || { echo "No checksum entry for $CHECKSUM_KEY in checksums.txt" >&2; exit 1; }

    if command -v sha256sum >/dev/null 2>&1; then
      ACTUAL="$(sha256sum "$TMP_DIR/$ASSET" | awk '{print $1}')"
    else
      ACTUAL="$(shasum -a 256 "$TMP_DIR/$ASSET" | awk '{print $1}')"
    fi
    if [[ "$ACTUAL" != "$EXPECTED" ]]; then
      echo "CHECKSUM MISMATCH for $ASSET — refusing to install." >&2
      echo "  expected: $EXPECTED" >&2
      echo "  actual:   $ACTUAL" >&2
      exit 1
    fi
    echo "Checksum OK: $ACTUAL"

    if [[ "$EXT" == "zip" ]]; then
      unzip -q -o "$TMP_DIR/$ASSET" "$MEMBER" -d "$TMP_DIR"
    else
      tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR" "$MEMBER"
    fi
    [[ -f "$TMP_DIR/$MEMBER" ]] || { echo "Expected $MEMBER inside $ASSET, not found" >&2; exit 1; }

    mkdir -p "$BIN_DIR"
    chmod +x "$TMP_DIR/$MEMBER"
    # Strip the macOS quarantine xattr, else Gatekeeper blocks the unsigned binary.
    if [[ "$PLATFORM" == "darwin" ]] && command -v xattr >/dev/null 2>&1; then
      xattr -c "$TMP_DIR/$MEMBER" 2>/dev/null || true
    fi
    mv "$TMP_DIR/$MEMBER" "$CRE_BIN"

    echo "===================================================================="
    "$CRE_BIN" version
    echo "Installed: $CRE_BIN  (gitignored; nothing written outside the repo)"
    echo "Run CRE commands through 'just cre …' so they execute from cre-workflows/ (project.yaml)."
    echo "===================================================================="

# Show what the env model actually resolves to — read-only, no writes, no broadcasts.
#
# The repo keeps ONE canonical name per fact and derives every tool-specific spelling at call time
# (script/shared/cre-env.sh), so the thing worth checking is not "which file has the value" but "what
# resolves, and do the copies agree". This prints that, and cross-checks the pairs that can silently
# diverge: signing key → address vs the declared actor address vs the committed `.inputs.yaml` anchor
# vs the live on-chain pin.
#
# Secrets are never printed — only "set/unset" and the address the key derives to. RPC URLs carry API
# keys in the path, so only their host is shown.
#
# Usage: just env-doctor                      (all four lanes)
#        NETWORK=optimism just env-doctor     (one lane, with live chain-id + on-chain reads)
env-doctor:
    @bash "{{justfile_directory()}}/script/commands/env-doctor.sh"

# Resolve the `cre` CLI: the repo-local pinned binary first, then anything on PATH.
[private]
_cre-bin:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -x "{{CRE_DIR}}/bin/cre" ]]; then
      echo "{{CRE_DIR}}/bin/cre"
    elif command -v cre >/dev/null 2>&1; then
      command -v cre
    else
      echo "Missing 'cre' CLI. Install the pinned, repo-local copy with: just setup-cre-cli" >&2
      exit 1
    fi

# Run the pinned CRE CLI from cre-workflows/ with derived key, owner, and RPC aliases.
# The key must match the configured workflow owner. cre account link-key sends an Ethereum transaction;
# cre login stores its session under $HOME. See docs/cre.md.
cre *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    CRE="$(just _cre-bin)"
    source "{{justfile_directory()}}/script/shared/cre-env.sh"
    cre_env_export
    cre_env_export_all_l2_rpcs   # the consolidated production target interpolates all four L2 RPC aliases
    echo "cre binary: $CRE"
    echo "cwd:        $(pwd)/cre-workflows"
    cd cre-workflows
    exec "$CRE" {{ARGS}}

# ──────────────────────────────────────────────────────────────────
# Anvil fork helpers
# ──────────────────────────────────────────────────────────────────

rpc-start-l1:
    anvil --hardfork amsterdam -p 8545 -f "$L1_RPC_URL"

rpc-start-optimism:
    anvil --hardfork amsterdam -p 8551 -f "$L2_OPTIMISM_RPC_URL"

rpc-start-arbitrum:
    anvil --hardfork amsterdam -p 8552 -f "$L2_ARBITRUM_RPC_URL"

rpc-start-base:
    anvil --hardfork amsterdam -p 8553 -f "$L2_BASE_RPC_URL"

rpc-start-linea:
    anvil --hardfork amsterdam -p 8554 -f "$L2_LINEA_RPC_URL"

# Run pool and CRE behavior suites against mainnet forks with current ownership fixtures.
test-forks network='all':
    @bash "{{justfile_directory()}}/script/commands/test-forks.sh" "{{network}}"
