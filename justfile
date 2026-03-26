# https://just.systems

set dotenv-load

# Helper: extract an address from a YAML anchor
_ya file anchor:
    @yq '.[] | select(anchor == "{{anchor}}")' {{file}}

# Install chainlink-csr dependencies (run once after clone)
setup:
    cd chainlink-csr && npm install --ignore-scripts && forge install

# Run the Optimism pool upgrade fork test
test-optimism-upgrade:
    forge test --match-contract OptimismPoolUpgradeTest --rpc-url "$LOCAL_L2_OPTIMISM_RPC_URL" -vvv

[private]
_optimism-state-migrate rpc_url='':
    #!/usr/bin/env bash
    set -euo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    RPC_URL="{{rpc_url}}"
    DEFAULT_RPC_URL="${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_OPTIMISM_RPC_URL:-${L2_OPTIMISM_RPC_URL:-}}}"
    STATE_MATE_OUTPUT_FILE="${L2_STATE_MATE_OUTPUT_FILE:-${TMPDIR:-/tmp}/optimism-l2-state-mate.env}"
    INITIAL_OWNER_DEFAULT="${L2_STATE_MATE_INITIAL_OWNER:-0xb5c336a5c60D3482b29d83C742C65AE8351b91a8}"
    ANVIL_SIGNER_BALANCE_HEX="0x3635C9ADC5DEA00000"

    die() { echo "$*" >&2; exit 1; }
    require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
    require_env() { [[ -n "${!1:-}" ]] || die "Missing required env var: $1"; }

    resolve_rpc_url() {
      if [[ -n "$RPC_URL" ]]; then
        printf '%s\n' "$RPC_URL"
        return
      fi
      if [[ -n "$DEFAULT_RPC_URL" ]]; then
        printf '%s\n' "$DEFAULT_RPC_URL"
        return
      fi
      die "Missing RPC URL: pass [rpc_url], or set L2_STATE_MATE_RPC_URL (or LOCAL_L2_OPTIMISM_RPC_URL / L2_OPTIMISM_RPC_URL)."
    }

    extract_first_address() {
      local input="$1"
      local extracted
      extracted="$(printf '%s' "$input" | grep -Eo '0x[0-9a-fA-F]{40}' | head -n 1 || true)"
      [[ -n "$extracted" ]] || die "Failed to parse address from output: $input"
      printf '%s\n' "$extracted"
    }

    address_from_private_key() {
      cast wallet address --private-key "$1" | tr -d '\r\n'
    }

    compute_create_address() {
      local output
      output="$(cast compute-address "$1" --nonce "$2" | tr -d '\r\n')"
      extract_first_address "$output"
    }

    require_cmd cast
    require_cmd forge
    require_env L2_LIDO_DEPLOYER_PRIVATE_KEY
    require_env L2_GOVERNANCE_EXECUTOR

    RPC_URL="$(resolve_rpc_url)"
    L2_LIQUIDITY_OWNER_RESOLVED="${L2_LIQUIDITY_OWNER:-$L2_GOVERNANCE_EXECUTOR}"

    if [[ -n "${INITIAL_OWNER_PRIVATE_KEY:-}" ]]; then
      INITIAL_OWNER_ADDRESS="$(address_from_private_key "$INITIAL_OWNER_PRIVATE_KEY")"
      UPGRADE_SCRIPT_SIG="run()"
      FORGE_UNLOCKED_ARGS=()
    elif [[ -n "${L2_INITIAL_OWNER_PRIVATE_KEY:-}" ]]; then
      INITIAL_OWNER_ADDRESS="$(address_from_private_key "$L2_INITIAL_OWNER_PRIVATE_KEY")"
      UPGRADE_SCRIPT_SIG="run()"
      FORGE_UNLOCKED_ARGS=()
    else
      INITIAL_OWNER_ADDRESS="${INITIAL_OWNER:-${L2_INITIAL_OWNER:-$INITIAL_OWNER_DEFAULT}}"
      export INITIAL_OWNER="$INITIAL_OWNER_ADDRESS"
      UPGRADE_SCRIPT_SIG="runWithUnlockedInitialOwner()"
      FORGE_UNLOCKED_ARGS=(--unlocked --sender "$INITIAL_OWNER_ADDRESS")
    fi

    L2_LIDO_DEPLOYER_ADDRESS="$(address_from_private_key "$L2_LIDO_DEPLOYER_PRIVATE_KEY")"
    cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$INITIAL_OWNER_ADDRESS" "$ANVIL_SIGNER_BALANCE_HEX" >/dev/null 2>&1 || true
    cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$L2_LIDO_DEPLOYER_ADDRESS" "$ANVIL_SIGNER_BALANCE_HEX" >/dev/null 2>&1 || true

    if [[ "$UPGRADE_SCRIPT_SIG" == "runWithUnlockedInitialOwner()" ]]; then
      if ! cast rpc --rpc-url "$RPC_URL" anvil_impersonateAccount "$INITIAL_OWNER_ADDRESS" >/dev/null 2>&1; then
        die "runWithUnlockedInitialOwner() requires an anvil-compatible RPC. Set INITIAL_OWNER_PRIVATE_KEY for arbitrary RPC endpoints."
      fi
    fi

    DEPLOYER_NONCE_BEFORE="$(cast nonce "$L2_LIDO_DEPLOYER_ADDRESS" --rpc-url "$RPC_URL" | tr -d '\r\n')"

    echo "Running OptimismL2UpgradeScript on ${RPC_URL}"
    (
      cd "$ROOT_DIR"
      forge script script/optimism/OptimismL2Upgrade.s.sol:OptimismL2UpgradeScript \
        --sig "$UPGRADE_SCRIPT_SIG" \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --non-interactive \
        "${FORGE_UNLOCKED_ARGS[@]}"
    )

    ORACLE_POOL_ADDRESS="$(compute_create_address "$L2_LIDO_DEPLOYER_ADDRESS" "$DEPLOYER_NONCE_BEFORE")"
    SYNC_TRIGGER_NONCE="$((DEPLOYER_NONCE_BEFORE + 1))"
    SYNC_TRIGGER_ADDRESS="$(compute_create_address "$L2_LIDO_DEPLOYER_ADDRESS" "$SYNC_TRIGGER_NONCE")"

    printf '%s\n' \
      "L2_STATE_MATE_RPC_URL=${RPC_URL}" \
      "L2_STATE_MATE_ORACLE_POOL=${ORACLE_POOL_ADDRESS}" \
      "L2_STATE_MATE_SYNC_TRIGGER=${SYNC_TRIGGER_ADDRESS}" \
      "L2_STATE_MATE_INITIAL_OWNER=${INITIAL_OWNER_ADDRESS}" \
      "L2_STATE_MATE_LIDO_DEPLOYER=${L2_LIDO_DEPLOYER_ADDRESS}" \
      "L2_STATE_MATE_LIQUIDITY_OWNER=${L2_LIQUIDITY_OWNER_RESOLVED}" \
      >"$STATE_MATE_OUTPUT_FILE"

    echo "Migration completed on ${RPC_URL}"
    echo "New oracle pool: ${ORACLE_POOL_ADDRESS}"
    echo "New sync trigger: ${SYNC_TRIGGER_ADDRESS}"
    echo "Saved migration outputs: ${STATE_MATE_OUTPUT_FILE}"

[private]
_optimism-state-update-config rpc_url='':
    #!/usr/bin/env bash
    set -euo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    RPC_URL="{{rpc_url}}"
    DEFAULT_RPC_URL="${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_OPTIMISM_RPC_URL:-${L2_OPTIMISM_RPC_URL:-}}}"
    STATE_MATE_OUTPUT_FILE="${L2_STATE_MATE_OUTPUT_FILE:-${TMPDIR:-/tmp}/optimism-l2-state-mate.env}"
    STATE_MATE_TEMPLATE="$ROOT_DIR/script/optimism/state-mate/optimism-l2-upgrade.template.yaml"
    STATE_MATE_CONFIG="$ROOT_DIR/script/optimism/state-mate/optimism.yaml"
    STATE_MATE_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/optimism-l2-state-config.XXXXXX")"
    L2_CUSTOM_SENDER="${L2_STATE_MATE_CUSTOM_SENDER:-0x328de900860816d29D1367F6903a24D8ed40C997}"
    L2_PROXY_ADMIN="${L2_STATE_MATE_PROXY_ADMIN:-0x4c8c4A15c1e810e481c412A9B06Be5f79dC02192}"
    INITIAL_OWNER_DEFAULT="${L2_STATE_MATE_INITIAL_OWNER:-0xb5c336a5c60D3482b29d83C742C65AE8351b91a8}"

    cleanup() { rm -rf "$STATE_MATE_WORK_DIR"; }
    trap cleanup EXIT

    die() { echo "$*" >&2; exit 1; }
    require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
    require_env() { [[ -n "${!1:-}" ]] || die "Missing required env var: $1"; }

    read_saved_output_var() {
      local key="$1"
      local line
      [[ -f "$STATE_MATE_OUTPUT_FILE" ]] || return 1
      line="$(grep -E "^${key}=" "$STATE_MATE_OUTPUT_FILE" | tail -n 1 || true)"
      [[ -n "$line" ]] || return 1
      printf '%s\n' "${line#*=}"
    }

    resolve_rpc_url() {
      local saved_rpc_url
      if [[ -n "$RPC_URL" ]]; then
        printf '%s\n' "$RPC_URL"
        return
      fi
      if saved_rpc_url="$(read_saved_output_var L2_STATE_MATE_RPC_URL 2>/dev/null || true)" && [[ -n "$saved_rpc_url" ]]; then
        printf '%s\n' "$saved_rpc_url"
        return
      fi
      if [[ -n "$DEFAULT_RPC_URL" ]]; then
        printf '%s\n' "$DEFAULT_RPC_URL"
        return
      fi
      die "Missing RPC URL: pass [rpc_url], set L2_STATE_MATE_RPC_URL, or run migrate first."
    }

    address_from_private_key() {
      cast wallet address --private-key "$1" | tr -d '\r\n'
    }

    require_cmd cast
    require_env L2_GOVERNANCE_EXECUTOR

    RPC_URL="$(resolve_rpc_url)"

    if [[ -n "${INITIAL_OWNER_PRIVATE_KEY:-}" ]]; then
      INITIAL_OWNER_ADDRESS="$(address_from_private_key "$INITIAL_OWNER_PRIVATE_KEY")"
    elif [[ -n "${L2_INITIAL_OWNER_PRIVATE_KEY:-}" ]]; then
      INITIAL_OWNER_ADDRESS="$(address_from_private_key "$L2_INITIAL_OWNER_PRIVATE_KEY")"
    elif [[ -n "${INITIAL_OWNER:-}" ]]; then
      INITIAL_OWNER_ADDRESS="$INITIAL_OWNER"
    elif [[ -n "${L2_INITIAL_OWNER:-}" ]]; then
      INITIAL_OWNER_ADDRESS="$L2_INITIAL_OWNER"
    elif saved="$(read_saved_output_var L2_STATE_MATE_INITIAL_OWNER 2>/dev/null || true)" && [[ -n "$saved" ]]; then
      INITIAL_OWNER_ADDRESS="$saved"
    else
      INITIAL_OWNER_ADDRESS="$INITIAL_OWNER_DEFAULT"
    fi

    if [[ -n "${L2_LIDO_DEPLOYER_ADDRESS:-}" ]]; then
      L2_LIDO_DEPLOYER_ADDRESS_RESOLVED="$L2_LIDO_DEPLOYER_ADDRESS"
    elif saved="$(read_saved_output_var L2_STATE_MATE_LIDO_DEPLOYER 2>/dev/null || true)" && [[ -n "$saved" ]]; then
      L2_LIDO_DEPLOYER_ADDRESS_RESOLVED="$saved"
    elif [[ -n "${L2_LIDO_DEPLOYER_PRIVATE_KEY:-}" ]]; then
      L2_LIDO_DEPLOYER_ADDRESS_RESOLVED="$(address_from_private_key "$L2_LIDO_DEPLOYER_PRIVATE_KEY")"
    else
      die "Missing L2 deployer identity: set L2_LIDO_DEPLOYER_PRIVATE_KEY or L2_LIDO_DEPLOYER_ADDRESS."
    fi

    if [[ -n "${L2_LIQUIDITY_OWNER:-}" ]]; then
      L2_LIQUIDITY_OWNER_RESOLVED="$L2_LIQUIDITY_OWNER"
    elif saved="$(read_saved_output_var L2_STATE_MATE_LIQUIDITY_OWNER 2>/dev/null || true)" && [[ -n "$saved" ]]; then
      L2_LIQUIDITY_OWNER_RESOLVED="$saved"
    else
      L2_LIQUIDITY_OWNER_RESOLVED="$L2_GOVERNANCE_EXECUTOR"
    fi

    if [[ -n "${L2_STATE_MATE_ORACLE_POOL:-}" ]]; then
      ORACLE_POOL_ADDRESS="$L2_STATE_MATE_ORACLE_POOL"
    elif saved="$(read_saved_output_var L2_STATE_MATE_ORACLE_POOL 2>/dev/null || true)" && [[ -n "$saved" ]]; then
      ORACLE_POOL_ADDRESS="$saved"
    else
      ORACLE_POOL_ADDRESS="$(cast call "$L2_CUSTOM_SENDER" "getOraclePool()(address)" --rpc-url "$RPC_URL" | tr -d '\r\n' || true)"
      [[ "$ORACLE_POOL_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "Failed to resolve oracle pool address. Set L2_STATE_MATE_ORACLE_POOL."
    fi

    if [[ -n "${L2_STATE_MATE_SYNC_TRIGGER:-}" ]]; then
      SYNC_TRIGGER_ADDRESS="$L2_STATE_MATE_SYNC_TRIGGER"
    elif saved="$(read_saved_output_var L2_STATE_MATE_SYNC_TRIGGER 2>/dev/null || true)" && [[ -n "$saved" ]]; then
      SYNC_TRIGGER_ADDRESS="$saved"
    else
      die "Failed to resolve sync trigger address. Set L2_STATE_MATE_SYNC_TRIGGER or run migrate first."
    fi

    CRE_RECEIVER_ADDRESS="${L2_STATE_MATE_CRE_RECEIVER:-}"
    if [[ -z "$CRE_RECEIVER_ADDRESS" ]]; then
      CRE_RECEIVER_ADDRESS="$(read_saved_output_var L2_STATE_MATE_CRE_RECEIVER 2>/dev/null || true)"
    fi

    rendered_config="$STATE_MATE_WORK_DIR/optimism.yaml"
    sed \
      -e "s|__L2_CUSTOM_SENDER__|${L2_CUSTOM_SENDER}|g" \
      -e "s|__L2_PROXY_ADMIN__|${L2_PROXY_ADMIN}|g" \
      -e "s|__INITIAL_OWNER__|${INITIAL_OWNER_ADDRESS}|g" \
      -e "s|__L2_GOVERNANCE_EXECUTOR__|${L2_GOVERNANCE_EXECUTOR}|g" \
      -e "s|__L2_LIQUIDITY_OWNER__|${L2_LIQUIDITY_OWNER_RESOLVED}|g" \
      -e "s|__L2_LIDO_DEPLOYER__|${L2_LIDO_DEPLOYER_ADDRESS_RESOLVED}|g" \
      -e "s|__L2_ORACLE_POOL__|${ORACLE_POOL_ADDRESS}|g" \
      -e "s|__L2_SYNC_TRIGGER__|${SYNC_TRIGGER_ADDRESS}|g" \
      -e "s|__L2_CRE_RECEIVER__|${CRE_RECEIVER_ADDRESS:-null}|g" \
      "$STATE_MATE_TEMPLATE" >"$rendered_config"
    mv "$rendered_config" "$STATE_MATE_CONFIG"
    echo "Regenerated state-mate config: ${STATE_MATE_CONFIG} (rpc: ${RPC_URL})"

[private]
_state-verify network rpc_url='':
    #!/usr/bin/env bash
    set -euo pipefail

    NETWORK="{{network}}"
    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    RPC_URL="{{rpc_url}}"

    # Map network name to default RPC env var
    case "$NETWORK" in
      optimism) DEFAULT_RPC_URL="${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_OPTIMISM_RPC_URL:-${L2_OPTIMISM_RPC_URL:-}}}" ;;
      arbitrum) DEFAULT_RPC_URL="${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_ARBITRUM_RPC_URL:-${L2_ARBITRUM_RPC_URL:-}}}" ;;
      base)     DEFAULT_RPC_URL="${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_BASE_RPC_URL:-${L2_BASE_RPC_URL:-}}}" ;;
      linea)    DEFAULT_RPC_URL="${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_LINEA_RPC_URL:-${L2_LINEA_RPC_URL:-}}}" ;;
      *)        echo "Unknown network: $NETWORK" >&2; exit 1 ;;
    esac

    STATE_MATE_OUTPUT_FILE="${L2_STATE_MATE_OUTPUT_FILE:-${TMPDIR:-/tmp}/${NETWORK}-l2-state-mate.env}"
    STATE_MATE_DIR="$ROOT_DIR/lib/state-mate"
    STATE_MATE_CONFIG="$ROOT_DIR/script/${NETWORK}/state-mate/${NETWORK}.yaml"
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${NETWORK}-l2-state-verify.XXXXXX")"
    STATE_MATE_LOG="$WORK_DIR/state-mate.log"

    cleanup() { rm -rf "$WORK_DIR"; }
    trap cleanup EXIT

    die() { echo "$*" >&2; exit 1; }

    read_saved_output_var() {
      local key="$1"
      local line
      [[ -f "$STATE_MATE_OUTPUT_FILE" ]] || return 1
      line="$(grep -E "^${key}=" "$STATE_MATE_OUTPUT_FILE" | tail -n 1 || true)"
      [[ -n "$line" ]] || return 1
      printf '%s\n' "${line#*=}"
    }

    resolve_rpc_url() {
      local saved_rpc_url
      if [[ -n "$RPC_URL" ]]; then
        printf '%s\n' "$RPC_URL"
        return
      fi
      if saved_rpc_url="$(read_saved_output_var L2_STATE_MATE_RPC_URL 2>/dev/null || true)" && [[ -n "$saved_rpc_url" ]]; then
        printf '%s\n' "$saved_rpc_url"
        return
      fi
      if [[ -n "$DEFAULT_RPC_URL" ]]; then
        printf '%s\n' "$DEFAULT_RPC_URL"
        return
      fi
      die "Missing RPC URL: pass [rpc_url], set L2_STATE_MATE_RPC_URL, or run migrate first."
    }

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

    RPC_URL="$(resolve_rpc_url)"
    echo "Running state-mate checks for $NETWORK against ${RPC_URL}"

    set +e
    (
      cd "$STATE_MATE_DIR"
      env -u NO_COLOR L2_STATE_MATE_RPC_URL="$RPC_URL" FORCE_COLOR=3 CLICOLOR_FORCE=1 "${YARN_CMD[@]}" start "$STATE_MATE_CONFIG" --only "l2"
    ) 2>&1 | tee "$STATE_MATE_LOG"
    STATE_MATE_EXIT="${PIPESTATUS[0]}"
    set -e

    echo ""
    echo "----- state-mate full output -----"
    perl -pe 's/\r/\n/g' "$STATE_MATE_LOG"
    echo "----- end state-mate output -----"

    [[ "$STATE_MATE_EXIT" -eq 0 ]] || die "state-mate checks failed for $NETWORK"
    echo "$NETWORK state verification passed"

# ──────────────────────────────────────────────────────────────────
# Optimism acceptance test: full migration + state-mate + forge tests
#
# Same recipes work for:
#   - Local fork testing:  just test-optimism-acceptance
#   - Live network:        just test-optimism-upgrade-state-migrate $RPC ...
#
# Env vars (all optional for the fork-based acceptance test):
#   L2_LIDO_DEPLOYER_PRIVATE_KEY  — deployer key (generated if missing on Anvil)
#   L2_GOVERNANCE_EXECUTOR        — governance executor address
#   L1_RPC_URL / L2_OPTIMISM_RPC_URL — upstream RPCs for forking
# ──────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────
# Full acceptance test: all networks, shared L1 migration
# ──────────────────────────────────────────────────────────────────

[private]
_acceptance-test:
    #!/usr/bin/env bash
    set -euo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/acceptance.XXXXXX")"
    ANVIL_BALANCE="0x3635C9ADC5DEA00000" # 1000 ETH
    BASE_PORT="${ACCEPTANCE_BASE_PORT:-8650}"

    # L1 constants (shared across all networks)
    INITIAL_OWNER="0xb5c336a5c60D3482b29d83C742C65AE8351b91a8"
    LIDO_DAO_AGENT="0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c"
    L1_RECEIVER="0x6F357d53d6bE3238180316BA5F8f11467e164588"
    L1_PROXY_ADMIN_ADDR="0x88a45d2760b63c1500E3D2E3552b28e5Cdaa37BD"
    ZERO_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"

    # Network count and per-network config (parallel arrays, bash 3 compatible)
    NET_NAMES=(    optimism                         arbitrum                         base                             linea)
    NET_RPC_ENVS=( L2_OPTIMISM_RPC_URL              L2_ARBITRUM_RPC_URL              L2_BASE_RPC_URL                  L2_LINEA_RPC_URL)
    NET_GOVS=(     0xEfa0dB536d2c8089685630fafe88CF7805966FC3 0x1dcA41859Cd23b526CBe74dA8F48aC96e14B1A29 0x2897A1b134050c01503843db48e034d4C9e2b18c 0x2897A1b134050c01503843db48e034d4C9e2b18c)
    NET_SCRIPTS=(  "script/optimism/OptimismL2Upgrade.s.sol:OptimismL2UpgradeScript" \
                   "script/arbitrum/ArbitrumL2Upgrade.s.sol:ArbitrumL2UpgradeScript" \
                   "script/base/BaseL2Upgrade.s.sol:BaseL2UpgradeScript" \
                   "script/linea/LineaL2Upgrade.s.sol:LineaL2UpgradeScript")
    NET_TESTS=(    "OptimismPoolUpgradeTest|OptimismCREIntegrationTest" \
                   "ArbitrumPoolUpgradeTest|ArbitrumCREIntegrationTest" \
                   "BasePoolUpgradeTest|BaseCREIntegrationTest" \
                   "LineaPoolUpgradeTest|LineaCREIntegrationTest")
    NET_SM_DIRS=(  script/optimism/state-mate        script/arbitrum/state-mate       script/base/state-mate           script/linea/state-mate)
    NET_SM_TMPLS=( optimism-l2-upgrade.template.yaml arbitrum-l2-upgrade.template.yaml base-l2-upgrade.template.yaml  linea-l2-upgrade.template.yaml)
    NET_SENDERS=(  0x328de900860816d29D1367F6903a24D8ed40C997 0x72229141D4B016682d3618ECe47c046f30Da4AD1 0x328de900860816d29D1367F6903a24D8ed40C997 0x328de900860816d29D1367F6903a24D8ed40C997)
    NET_PROXIES=(  0x4c8c4A15c1e810e481c412A9B06Be5f79dC02192 0x5B42aEbFe95247f1d22e282831e2A513bF050217 0x4c8c4A15c1e810e481c412A9B06Be5f79dC02192 0x4c8c4A15c1e810e481c412A9B06Be5f79dC02192)
    NET_LOLS=(     0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61 0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61 0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61 0xA8EF4Db842d95DE72433a8B5b8fF40cB9C74c1B6)
    NET_COUNT=${#NET_NAMES[@]}

    die() { echo "FAIL: $*" >&2; exit 1; }

    # Validate parallel arrays have consistent length
    for arr_name in NET_RPC_ENVS NET_GOVS NET_SCRIPTS NET_TESTS NET_SM_DIRS NET_SM_TMPLS NET_SENDERS NET_PROXIES NET_LOLS; do
      eval "arr_len=\${#${arr_name}[@]}"
      [[ "$arr_len" -eq "$NET_COUNT" ]] || die "Array $arr_name has $arr_len elements, expected $NET_COUNT"
    done
    step() { echo ""; echo "═══ $1 ═══"; }
    substep() { echo "  ── $1"; }

    ANVIL_PIDS=""
    cleanup() {
      for pid in $ANVIL_PIDS; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      done
      rm -rf "$WORK_DIR"
    }
    trap cleanup EXIT

    wait_for_rpc() {
      local url="$1" name="$2" timeout="${3:-60}"
      for i in $(seq 1 "$timeout"); do
        cast chain-id --rpc-url "$url" >/dev/null 2>&1 && return 0
        sleep 1
      done
      die "$name fork failed to start within ${timeout}s"
    }

    extract_first_address() {
      local extracted
      extracted="$(printf '%s' "$1" | grep -Eo '0x[0-9a-fA-F]{40}' | head -n 1 || true)"
      [[ -n "$extracted" ]] || die "Failed to parse address from: $1"
      printf '%s\n' "$extracted"
    }

    compute_create_address() {
      local output
      output="$(cast compute-address "$1" --nonce "$2" | tr -d '\r\n')"
      extract_first_address "$output"
    }

    address_from_key() { cast wallet address --private-key "$1" | tr -d '\r\n'; }

    # ── Step 0: Preflight ──────────────────────────────────────────
    step "Step 0: Preflight checks"
    for cmd in forge cast anvil node; do
      command -v "$cmd" >/dev/null 2>&1 || die "Missing: $cmd"
    done

    L1_UPSTREAM="${L1_RPC_URL:-}"
    [[ -n "$L1_UPSTREAM" ]] || die "Set L1_RPC_URL"
    cast chain-id --rpc-url "$L1_UPSTREAM" >/dev/null 2>&1 || die "L1 RPC not reachable: $L1_UPSTREAM"
    echo "L1: $L1_UPSTREAM"

    # Collect and validate L2 RPCs
    L2_UPSTREAMS=()
    for i in $(seq 0 $((NET_COUNT - 1))); do
      rpc_env="${NET_RPC_ENVS[$i]}"
      rpc_val="${!rpc_env:-}"
      [[ -n "$rpc_val" ]] || die "Set $rpc_env"
      cast chain-id --rpc-url "$rpc_val" >/dev/null 2>&1 || die "${NET_NAMES[$i]} RPC not reachable: $rpc_val"
      L2_UPSTREAMS+=("$rpc_val")
      echo "${NET_NAMES[$i]}: $rpc_val"
    done
    echo "All RPCs OK"

    [[ -n "${L2_LIDO_DEPLOYER_PRIVATE_KEY:-}" ]] || die "Set L2_LIDO_DEPLOYER_PRIVATE_KEY"
    DEPLOYER_ADDR="$(address_from_key "$L2_LIDO_DEPLOYER_PRIVATE_KEY")"

    # ── Step 1: Spawn forks ────────────────────────────────────────
    step "Step 1: Starting Anvil forks"
    L1_PORT="$BASE_PORT"
    L1_FORK_URL="http://127.0.0.1:$L1_PORT"
    anvil --silent --auto-impersonate -p "$L1_PORT" -f "$L1_UPSTREAM" >"$WORK_DIR/l1.log" 2>&1 &
    ANVIL_PIDS="$ANVIL_PIDS $!"
    echo "L1 fork: $L1_FORK_URL"

    L2_FORK_URLS=()
    for i in $(seq 0 $((NET_COUNT - 1))); do
      port=$((BASE_PORT + 1 + i))
      fork_url="http://127.0.0.1:$port"
      anvil --silent --auto-impersonate -p "$port" -f "${L2_UPSTREAMS[$i]}" >"$WORK_DIR/${NET_NAMES[$i]}.log" 2>&1 &
      ANVIL_PIDS="$ANVIL_PIDS $!"
      L2_FORK_URLS+=("$fork_url")
      echo "${NET_NAMES[$i]} fork: $fork_url"
    done

    wait_for_rpc "$L1_FORK_URL" "L1"
    for i in $(seq 0 $((NET_COUNT - 1))); do
      wait_for_rpc "${L2_FORK_URLS[$i]}" "${NET_NAMES[$i]}"
    done
    echo "All forks ready"

    # ── Step 2: L2 migrations (per-network) ────────────────────────
    CRE_RECEIVER_BYTECODE="$(forge inspect src/cre/CREReceiver.sol:CREReceiver bytecode)"

    DEPLOYED_POOLS=()
    DEPLOYED_TRIGGERS=()
    DEPLOYED_RECEIVERS=()

    for i in $(seq 0 $((NET_COUNT - 1))); do
      name="${NET_NAMES[$i]}"
      fork_url="${L2_FORK_URLS[$i]}"
      gov="${NET_GOVS[$i]}"

      step "Step 2: $name L2 migration"

      cast rpc --rpc-url "$fork_url" anvil_setBalance "$DEPLOYER_ADDR" "$ANVIL_BALANCE" >/dev/null
      cast rpc --rpc-url "$fork_url" anvil_setBalance "$INITIAL_OWNER" "$ANVIL_BALANCE" >/dev/null

      # Stage 1+2: deploy + migrate
      substep "Stages 1+2: deploy + migrate"
      deployer_nonce="$(cast nonce "$DEPLOYER_ADDR" --rpc-url "$fork_url" | tr -d '\r\n')"
      (
        cd "$ROOT_DIR"
        L2_GOVERNANCE_EXECUTOR="$gov" \
        forge script "${NET_SCRIPTS[$i]}" \
          --sig "runWithUnlockedInitialOwner()" \
          --rpc-url "$fork_url" \
          --broadcast --non-interactive \
          --unlocked --sender "$INITIAL_OWNER" 2>&1 | tail -5
      )
      pool_addr="$(compute_create_address "$DEPLOYER_ADDR" "$deployer_nonce")"
      trigger_addr="$(compute_create_address "$DEPLOYER_ADDR" "$((deployer_nonce + 1))")"
      echo "  OraclePool: $pool_addr  SyncTrigger: $trigger_addr"

      # Deploy CREReceiver
      substep "Deploy CREReceiver"
      cre_fwd="${L2_CRE_FORWARDER:-$DEPLOYER_ADDR}"
      recv_nonce="$(cast nonce "$DEPLOYER_ADDR" --rpc-url "$fork_url" | tr -d '\r\n')"
      cast send --unlocked --from "$DEPLOYER_ADDR" --rpc-url "$fork_url" \
        --create "${CRE_RECEIVER_BYTECODE}$(cast abi-encode 'x(address)' "$cre_fwd" | cut -c3-)" >/dev/null
      recv_addr="$(compute_create_address "$DEPLOYER_ADDR" "$recv_nonce")"
      echo "  CREReceiver: $recv_addr"

      # Stage 3: finalize SyncTrigger + CREReceiver
      substep "Stage 3: finalize SyncTrigger + CREReceiver"
      lol="${NET_LOLS[$i]}"
      cast send --unlocked --from "$DEPLOYER_ADDR" --rpc-url "$fork_url" \
        "$trigger_addr" "setForwarder(address)" "$recv_addr" >/dev/null
      cast send --unlocked --from "$DEPLOYER_ADDR" --rpc-url "$fork_url" \
        "$trigger_addr" "transferOwnership(address)" "$gov" >/dev/null
      cast send --unlocked --from "$DEPLOYER_ADDR" --rpc-url "$fork_url" \
        "$recv_addr" "transferOwnership(address)" "$lol" >/dev/null
      echo "  SyncTrigger: forwarder → $recv_addr, owner → $gov"
      echo "  CREReceiver: owner → $lol"

      DEPLOYED_POOLS+=("$pool_addr")
      DEPLOYED_TRIGGERS+=("$trigger_addr")
      DEPLOYED_RECEIVERS+=("$recv_addr")
    done

    # ── L1 migration (once, shared) ────────────────────────────────
    step "Step 2: L1 migration (shared)"
    cast rpc --rpc-url "$L1_FORK_URL" anvil_setBalance "$INITIAL_OWNER" "$ANVIL_BALANCE" >/dev/null
    cast send --unlocked --from "$INITIAL_OWNER" --rpc-url "$L1_FORK_URL" \
      "$L1_RECEIVER" "grantRole(bytes32,address)" "$ZERO_ROLE" "$LIDO_DAO_AGENT" >/dev/null
    cast send --unlocked --from "$INITIAL_OWNER" --rpc-url "$L1_FORK_URL" \
      "$L1_RECEIVER" "revokeRole(bytes32,address)" "$ZERO_ROLE" "$INITIAL_OWNER" >/dev/null
    cast send --unlocked --from "$INITIAL_OWNER" --rpc-url "$L1_FORK_URL" \
      "$L1_PROXY_ADMIN_ADDR" "transferOwnership(address)" "$LIDO_DAO_AGENT" >/dev/null
    echo "L1 admin → $LIDO_DAO_AGENT"

    # ── Step 3: State-mate verification (per-network) ──────────────
    step "Step 3: State-mate verification"
    STATE_MATE_DIR="$ROOT_DIR/lib/state-mate"
    if [[ ! -d "$STATE_MATE_DIR/node_modules" ]]; then
      echo "Installing state-mate dependencies"
      (cd "$STATE_MATE_DIR" && yarn install --immutable 2>/dev/null || npm install) || die "Failed to install state-mate dependencies"
    fi

    for i in $(seq 0 $((NET_COUNT - 1))); do
      name="${NET_NAMES[$i]}"
      fork_url="${L2_FORK_URLS[$i]}"
      gov="${NET_GOVS[$i]}"
      liq_owner="${NET_LOLS[$i]}"

      sm_template="$ROOT_DIR/${NET_SM_DIRS[$i]}/${NET_SM_TMPLS[$i]}"
      sm_config="$ROOT_DIR/${NET_SM_DIRS[$i]}/$name.yaml"

      substep "$name: rendering config from template"
      sed \
        -e "s|__L2_CUSTOM_SENDER__|${NET_SENDERS[$i]}|g" \
        -e "s|__L2_PROXY_ADMIN__|${NET_PROXIES[$i]}|g" \
        -e "s|__INITIAL_OWNER__|${INITIAL_OWNER}|g" \
        -e "s|__L2_GOVERNANCE_EXECUTOR__|${gov}|g" \
        -e "s|__L2_LIQUIDITY_OWNER__|${liq_owner}|g" \
        -e "s|__L2_LIDO_DEPLOYER__|${DEPLOYER_ADDR}|g" \
        -e "s|__L2_ORACLE_POOL__|${DEPLOYED_POOLS[$i]}|g" \
        -e "s|__L2_SYNC_TRIGGER__|${DEPLOYED_TRIGGERS[$i]}|g" \
        -e "s|__L2_CRE_RECEIVER__|${DEPLOYED_RECEIVERS[$i]}|g" \
        "$sm_template" >"$sm_config"

      substep "$name: running state-mate checks"
      (
        cd "$STATE_MATE_DIR"
        L2_STATE_MATE_RPC_URL="$fork_url" yarn start "$sm_config" --only "l2" 2>&1 | tail -8
      ) || die "$name state-mate failed"
    done
    echo "All state-mate checks passed"

    # ── Step 4: Forge integration tests ────────────────────────────
    step "Step 4: Forge integration tests (all networks)"
    all_tests=""
    for i in $(seq 0 $((NET_COUNT - 1))); do
      all_tests="${all_tests:+$all_tests|}${NET_TESTS[$i]}"
    done
    (
      cd "$ROOT_DIR"
      forge test --match-contract "$all_tests" -vv
    )

    # ── Step 5: Report ─────────────────────────────────────────────
    step "PASS: Full acceptance test complete"
    echo "  L1 fork: $L1_FORK_URL"
    for i in $(seq 0 $((NET_COUNT - 1))); do
      echo "  ${NET_NAMES[$i]}: pool=${DEPLOYED_POOLS[$i]} trigger=${DEPLOYED_TRIGGERS[$i]} receiver=${DEPLOYED_RECEIVERS[$i]}"
    done

# Run the full acceptance test: all 4 L2 networks + shared L1 migration
test-acceptance:
    @just _acceptance-test

# Run acceptance for a single network (e.g., just test-acceptance-single optimism)
test-optimism-acceptance:
    @just _acceptance-test

# ── Individual sub-recipes (usable standalone against any RPC) ──

# Run only the Optimism L2 migration against an RPC (or env-provided default RPC)
test-optimism-upgrade-state-migrate rpc_url='':
    @just _optimism-state-migrate "{{rpc_url}}"

# Regenerate script/optimism/state-mate/optimism.yaml after migration
test-optimism-upgrade-state-update-config rpc_url='':
    @just _optimism-state-update-config "{{rpc_url}}"

# Verify post-migration state-mate checks against an arbitrary RPC
test-optimism-upgrade-state-verify rpc_url='':
    @just _state-verify optimism "{{rpc_url}}"

test-arbitrum-upgrade-state-verify rpc_url='':
    @just _state-verify arbitrum "{{rpc_url}}"

test-base-upgrade-state-verify rpc_url='':
    @just _state-verify base "{{rpc_url}}"

test-linea-upgrade-state-verify rpc_url='':
    @just _state-verify linea "{{rpc_url}}"

# Legacy alias
test-optimism-upgrade-state:
    @just _acceptance-test

default:
    echo 'Hello, world!'

# Print ETH, WETH, and wstETH balances for a given address on L1
[no-exit-message]
_balances-l1 label address rpc_url weth wsteth:
    @echo "=== {{label}} {{address}} ==="
    @printf "  ETH:    "; cast balance {{address}} --ether --rpc-url "{{rpc_url}}"
    @printf "  WETH:   "; cast call {{weth}} "balanceOf(address)(uint256)" {{address}} --rpc-url "{{rpc_url}}" | awk '{print $1}' | cast from-wei
    @printf "  wstETH: "; cast call {{wsteth}} "balanceOf(address)(uint256)" {{address}} --rpc-url "{{rpc_url}}" | awk '{print $1}' | cast from-wei

# Print ETH, WETH, and wstETH balances for a given address on an L2 network
[no-exit-message]
_balances-l2 label address rpc_url weth wsteth:
    @echo "=== {{label}} {{address}} ==="
    @printf "  ETH:    "; cast balance {{address}} --ether --rpc-url "{{rpc_url}}"
    @printf "  WETH:   "; cast call {{weth}} "balanceOf(address)(uint256)" {{address}} --rpc-url "{{rpc_url}}" | awk '{print $1}' | cast from-wei
    @printf "  wstETH: "; cast call {{wsteth}} "balanceOf(address)(uint256)" {{address}} --rpc-url "{{rpc_url}}" | awk '{print $1}' | cast from-wei

# NB: stETH (rebasing) does not exist on L2s; only wstETH is bridged

balances-l1:
    @echo "--- L1 (Ethereum) ---"
    @just _balances-l1 LidoCustomReceiver "$(yq '.deployed.l1[] | select(anchor == "l1LidoCustomReceiver")' optimism.yaml)" "$L1_RPC_URL" "$(yq '.parameters[] | select(anchor == "wethL1")' optimism.yaml)" "$(yq '.parameters[] | select(anchor == "wstethL1")' optimism.yaml)"

balances-optimism:
    @echo "--- Optimism ---"
    @just _balances-l2 CustomSender "$(yq '.deployed.l2[] | select(anchor == "l2CustomSender")' optimism.yaml)" "$L2_OPTIMISM_RPC_URL" "$(yq '.parameters[] | select(anchor == "wethL2")' optimism.yaml)" "$(yq '.parameters[] | select(anchor == "wstethL2")' optimism.yaml)"
    @echo ""
    @just _balances-l2 OraclePool "$(yq '.deployed.l2[] | select(anchor == "l2OraclePool")' optimism.yaml)" "$L2_OPTIMISM_RPC_URL" "$(yq '.parameters[] | select(anchor == "wethL2")' optimism.yaml)" "$(yq '.parameters[] | select(anchor == "wstethL2")' optimism.yaml)"

balances-arbitrum:
    @echo "--- Arbitrum ---"
    @just _balances-l2 CustomSender "$(yq '.deployed.l2[] | select(anchor == "l2CustomSender")' arbitrum.yaml)" "$L2_ARBITRUM_RPC_URL" "$(yq '.parameters[] | select(anchor == "wethL2")' arbitrum.yaml)" "$(yq '.parameters[] | select(anchor == "wstethL2")' arbitrum.yaml)"
    @echo ""
    @just _balances-l2 OraclePool "$(yq '.deployed.l2[] | select(anchor == "l2OraclePool")' arbitrum.yaml)" "$L2_ARBITRUM_RPC_URL" "$(yq '.parameters[] | select(anchor == "wethL2")' arbitrum.yaml)" "$(yq '.parameters[] | select(anchor == "wstethL2")' arbitrum.yaml)"

balances-base:
    @echo "--- Base ---"
    @just _balances-l2 CustomSender "$(yq '.deployed.l2[] | select(anchor == "l2CustomSender")' base.yaml)" "$L2_BASE_RPC_URL" "$(yq '.parameters[] | select(anchor == "wethL2")' base.yaml)" "$(yq '.parameters[] | select(anchor == "wstethL2")' base.yaml)"
    @echo ""
    @just _balances-l2 OraclePool "$(yq '.deployed.l2[] | select(anchor == "l2OraclePool")' base.yaml)" "$L2_BASE_RPC_URL" "$(yq '.parameters[] | select(anchor == "wethL2")' base.yaml)" "$(yq '.parameters[] | select(anchor == "wstethL2")' base.yaml)"

balances-linea:
    @echo "--- Linea ---"
    @just _balances-l2 CustomSender "$(yq '.deployed.l2[] | select(anchor == "l2CustomSender")' linea.yaml)" "$L2_LINEA_RPC_URL" "$(yq '.parameters[] | select(anchor == "wethL2")' linea.yaml)" "$(yq '.parameters[] | select(anchor == "wstethL2")' linea.yaml)"

balances:
    @just balances-l1
    @echo ""
    @just balances-optimism
    @echo ""
    @just balances-arbitrum
    @echo ""
    @just balances-base
    @echo ""
    @just balances-linea

# ──────────────────────────────────────────────────────────────────
# CRE (Chainlink Runtime Environment) workflow commands
# ──────────────────────────────────────────────────────────────────

# Run CREReceiver unit tests (no fork required)
test-cre-receiver:
    forge test --match-contract CREReceiverTest -vvv

# Run CRE integration tests (fork-based, requires L1_RPC_URL + L2_OPTIMISM_RPC_URL)
test-cre-integration:
    forge test --match-contract CREIntegrationTest -vvv

# Run all CRE Solidity tests (unit + integration)
test-cre:
    forge test --match-contract 'CRE' -vvv

# Run CRE TypeScript workflow encoding tests
test-cre-workflow:
    cd cre-workflows/sync-automation && bun test

# Run all CRE tests (Solidity + TypeScript)
test-cre-all: test-cre test-cre-workflow

# Install CRE workflow dependencies (run once after clone)
setup-cre:
    cd cre-workflows/sync-automation && bun install

# ──────────────────────────────────────────────────────────────────
# Anvil fork helpers
# ──────────────────────────────────────────────────────────────────

rpc-start-l1:
    anvil -p 8545 -f "$L1_RPC_URL"

rpc-start-l2-optimism:
    anvil -p 8551 -f "$L2_OPTIMISM_RPC_URL"

rpc-start-l2-arbitrum:
    anvil -p 8552 -f "$L2_ARBITRUM_RPC_URL"

# ──────────────────────────────────────────────────────────────────
# Arbitrum pool upgrade
# ──────────────────────────────────────────────────────────────────

# Run the Arbitrum pool upgrade fork test
test-arbitrum-upgrade:
    # Prefer a local anvil fork when provided, otherwise run directly against the upstream RPC.
    forge test --match-contract ArbitrumPoolUpgradeTest --rpc-url "${LOCAL_L2_ARBITRUM_RPC_URL:-$L2_ARBITRUM_RPC_URL}" -vvv

# ──────────────────────────────────────────────────────────────────
# Sepolia testnet deployment
# ──────────────────────────────────────────────────────────────────

# Step 1: Deploy full CSR infrastructure to Sepolia + OP Sepolia
sepolia-deploy-csr:
    forge script script/optimism/sepolia/SepoliaCSRDeploy.s.sol:SepoliaCSRDeployScript \
        --broadcast --non-interactive -vvv

# Step 2: Run L2 upgrade on OP Sepolia (deploy OraclePool + SyncTrigger, migrate admin)
sepolia-upgrade-l2:
    forge script script/optimism/sepolia/SepoliaL2Upgrade.s.sol:SepoliaL2UpgradeScript \
        --sig "run()" \
        --rpc-url "$L2_OPTIMISM_SEPOLIA_RPC_URL" \
        --broadcast --non-interactive -vvv

# Step 3: Finalize CRE setup on OP Sepolia (set forwarder + transfer ownership)
sepolia-finalize-cre:
    forge script script/optimism/sepolia/SepoliaL2Upgrade.s.sol:SepoliaL2UpgradeScript \
        --sig "runFinalizeSyncTrigger()" \
        --rpc-url "$L2_OPTIMISM_SEPOLIA_RPC_URL" \
        --broadcast --non-interactive -vvv

# Step 4: Run L1 upgrade on Sepolia (migrate receiver admin + proxy admin)
sepolia-upgrade-l1:
    forge script script/optimism/sepolia/SepoliaL1Upgrade.s.sol:SepoliaL1UpgradeScript \
        --sig "run()" \
        --rpc-url "$L1_SEPOLIA_RPC_URL" \
        --broadcast --non-interactive -vvv

# Anvil fork of Ethereum Sepolia
rpc-start-l1-sepolia:
    anvil -p 8545 -f "$L1_SEPOLIA_RPC_URL"

# Anvil fork of Optimism Sepolia
rpc-start-l2-optimism-sepolia:
    anvil -p 8551 -f "$L2_OPTIMISM_SEPOLIA_RPC_URL"
