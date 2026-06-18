# https://just.systems

set dotenv-load

# Default recipe: list all available recipes (runs on bare `just`).
default:
    @just --list

# Helper: extract an address from a YAML anchor
_ya file anchor:
    @yq '.[] | select(anchor == "{{anchor}}")' {{file}}

# Helper: map L2 network name → forge `<file>:<contract>` target for the upgrade script.
[private]
_l2-script-target network:
    #!/usr/bin/env bash
    case "{{network}}" in
      optimism) echo "script/optimism/OptimismL2Upgrade.s.sol:OptimismL2UpgradeScript" ;;
      arbitrum) echo "script/arbitrum/ArbitrumL2Upgrade.s.sol:ArbitrumL2UpgradeScript" ;;
      base)     echo "script/base/BaseL2Upgrade.s.sol:BaseL2UpgradeScript" ;;
      linea)    echo "script/linea/LineaL2Upgrade.s.sol:LineaL2UpgradeScript" ;;
      *) echo "Unknown network: {{network}} (expected: optimism|arbitrum|base|linea)" >&2; exit 2 ;;
    esac

# Install chainlink-csr dependencies (run once after clone)
setup:
    cd chainlink-csr && npm install --ignore-scripts && forge install

# Per-network L2 preflight check. Five checks, in order:
#   1. RPC chain-id matches expected.
#   2. CustomSender contract has bytecode at the expected address.
#   3. Legacy SyncAutomation.getLastExecution() age (Chainlink-Automation upkeep
#      only — does NOT cover manual sync(), Linea Gelato, or the new SyncTrigger).
#      Linea also gets a reminder about its separate Gelato bot.
#   4. Old oracle-pool WETH + wstETH balances (Initial Liquidity Owner's pre-/post-migration position).
#   5. CustomSender.Sync(...) events in the last ~12 h via cast logs — the
#      authoritative "is a sync in flight" gate. The Sync event fires regardless
#      of caller, so this catches every code path: legacy upkeep, Gelato,
#      manual sync(), and the future SyncTrigger.
#
# The 12 h window matches L2_SYNC_DELAY (minSyncDelay) configured on each
# network's SyncAutomation / SyncTrigger; past 12 h since the last sync, the
# upkeep can't have fired again and any in-flight CCIP+bridge round-trip has
# had time to settle (real CCIP latency is normally minutes-to-low-hours).
#
# Required env: L2_NETWORK + one of:
#   RPC_<NET>  (shell export: RPC_OPTIMISM / RPC_ARBITRUM / RPC_BASE / RPC_LINEA)
#   L2_RPC_URL (legacy, loaded from .env.<network>)
#   L2_NETWORK ∈ {optimism, arbitrum, base, linea}
#
# Usage: just preflight-check              (with RPC_<NET> in env)
#        just -E .env.<network> preflight-check  (legacy .env file)
preflight-check:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    # Resolve L2 RPC: prefer RPC_<NET> (shell env), fall back to L2_RPC_URL (legacy .env file).
    _net_upper=$(echo "$L2_NETWORK" | tr '[:lower:]' '[:upper:]')
    _rpc_var="RPC_${_net_upper}"
    L2_RPC_URL="${!_rpc_var:-${L2_RPC_URL:-}}"
    : "${L2_RPC_URL:?Set ${_rpc_var} (or legacy L2_RPC_URL) for $L2_NETWORK}"

    case "$L2_NETWORK" in
      optimism) EXPECTED_CHAIN_ID=10    ; SENDER=0x328de900860816d29D1367F6903a24D8ed40C997 ; POOL=0x6F357d53d6bE3238180316BA5F8f11467e164588 ; OLD_SYNC=0x3776CC14ce997827F7A87091018Daa1739dc2790 ; WETH=0x4200000000000000000000000000000000000006 ; WSTETH=0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb ;;
      arbitrum) EXPECTED_CHAIN_ID=42161 ; SENDER=0x72229141D4B016682d3618ECe47c046f30Da4AD1 ; POOL=0x9c27c304cFdf0D9177002ff186A4aE0A5489Aace ; OLD_SYNC=0x7EbD06BF137077fF5EE858ca6368dBd95DB7c66A ; WETH=0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 ; WSTETH=0x5979D7b546E38E414F7E9822514be443A4800529 ;;
      base)     EXPECTED_CHAIN_ID=8453  ; SENDER=0x328de900860816d29D1367F6903a24D8ed40C997 ; POOL=0x6F357d53d6bE3238180316BA5F8f11467e164588 ; OLD_SYNC=0x3776CC14ce997827F7A87091018Daa1739dc2790 ; WETH=0x4200000000000000000000000000000000000006 ; WSTETH=0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452 ;;
      linea)    EXPECTED_CHAIN_ID=59144 ; SENDER=0x328de900860816d29D1367F6903a24D8ed40C997 ; POOL=0x6F357d53d6bE3238180316BA5F8f11467e164588 ; OLD_SYNC=0x9c27c304cFdf0D9177002ff186A4aE0A5489Aace ; WETH=0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f ; WSTETH=0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F ; LINEA_GELATO=0xFbdDDF18Bc681Ae649991f1Aced55b2252a1acAe ;;
      *) echo "Unknown L2_NETWORK: $L2_NETWORK (expected: optimism|arbitrum|base|linea)" >&2; exit 2 ;;
    esac

    echo "===================================================================="
    echo "L2 PREFLIGHT CHECK: $L2_NETWORK"
    echo "  RPC URL:            $L2_RPC_URL"
    echo "  Expected chain-id:  $EXPECTED_CHAIN_ID"
    echo "  CustomSender:       $SENDER"
    echo "  Old oracle pool:    $POOL"
    echo "  Pool WETH:          $WETH"
    echo "  Pool wstETH:        $WSTETH"
    echo "  Legacy SyncAuto:    $OLD_SYNC"
    if [[ "$L2_NETWORK" == "linea" ]]; then
      echo "  Legacy Gelato:      $LINEA_GELATO"
    fi
    echo "===================================================================="

    die() { echo "PREFLIGHT FAIL: $*" >&2; exit 1; }

    # Strip cast's "[1.234e9]" scientific-notation suffix and any whitespace.
    parse_cast_num() { local s="$1"; s="${s%%[*}"; s="${s%% *}"; printf '%s' "$s"; }

    has_code() {
      local code
      code=$(cast code "$1" --rpc-url "$L2_RPC_URL" 2>/dev/null || echo "0x")
      [[ "$code" != "0x" && -n "$code" ]]
    }

    echo "[1/5] CHECK chain-id of RPC matches expected ($EXPECTED_CHAIN_ID)"
    echo "      cmd: cast chain-id --rpc-url <rpc>"
    actual_chain_id=$(cast chain-id --rpc-url "$L2_RPC_URL")
    if [[ "$actual_chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
      die "chain-id mismatch: got $actual_chain_id, expected $EXPECTED_CHAIN_ID for $L2_NETWORK"
    fi
    # RPC_<NET> shares its name with the fork-test env (local anvil forks of these networks);
    # a fork preserves the upstream chain id, so the check above cannot tell fork from live.
    # A stale head block means a fork or badly lagging node — refuse to gate the migration on it.
    head_ts=$(parse_cast_num "$(cast block latest --field timestamp --rpc-url "$L2_RPC_URL")")
    head_age=$(( $(date +%s) - head_ts ))
    if (( head_age > 600 )); then
      die "RPC head block is ${head_age}s old — looks like a stale fork or lagging node, not live $L2_NETWORK (check \$${_rpc_var})"
    fi
    echo "      PASS chain-id = $actual_chain_id (head block ${head_age}s old)"

    echo "[2/5] CHECK CustomSender contract has bytecode at $SENDER"
    echo "      cmd: cast code $SENDER --rpc-url <rpc>"
    if ! has_code "$SENDER"; then
      die "CustomSender $SENDER has no code on this RPC"
    fi
    echo "      PASS bytecode present at CustomSender"

    echo "[3/5] CHECK legacy SyncAutomation last execution age at $OLD_SYNC"
    if ! has_code "$OLD_SYNC"; then
      echo "      WARN no contract bytecode at $OLD_SYNC (legacy automation may already be revoked/replaced)"
    else
      echo "      cmd: cast call $OLD_SYNC 'getLastExecution()(uint48)' --rpc-url <rpc>"
      if ! last_exec_hex=$(cast call "$OLD_SYNC" "getLastExecution()(uint48)" --rpc-url "$L2_RPC_URL" 2>/dev/null); then
        echo "      WARN $OLD_SYNC has bytecode but does not respond to getLastExecution() (different contract?)"
      else
        last_exec=$(parse_cast_num "$last_exec_hex")
        now=$(date +%s)
        age=$(( now - last_exec ))
        echo "      INFO last legacy sync = $last_exec ($((age/3600))h $((age%3600/60))m ago)"
        if (( age < 12*3600 )); then
          echo "      WARN last sync was <12h ago; CCIP round-trip may still be in flight (safe to proceed; see README §Migration ordering)."
        else
          echo "      PASS no auto-upkeep on this contract in >12h (legacy Chainlink path only — step 5 covers all paths)."
        fi
      fi
    fi
    if [[ "$L2_NETWORK" == "linea" ]]; then
      echo "      INFO Linea also has a separate Gelato automation at $LINEA_GELATO; check Gelato dashboard"
      echo "           (https://app.gelato.network/) for pending Linea upkeeps before running Stage 2."
    fi

    echo "[4/5] CHECK old oracle pool token balances (WETH + wstETH)"
    if ! has_code "$POOL"; then
      echo "      WARN no contract bytecode at $POOL (old oracle pool unreachable on this RPC)"
    else
      report_balance() {
        local label="$1" token="$2"
        echo "      cmd: cast call $token 'balanceOf(address)(uint256)' $POOL --rpc-url <rpc>  # $label"
        if raw=$(cast call "$token" "balanceOf(address)(uint256)" "$POOL" --rpc-url "$L2_RPC_URL" 2>/dev/null); then
          local wei ether
          wei=$(parse_cast_num "$raw")
          ether=$(cast from-wei "$wei" 2>/dev/null || echo "?")
          echo "      INFO old pool $label balance = $wei wei (~ $ether $label)"
        else
          echo "      WARN could not read $label balance for $POOL (token=$token may be wrong on this RPC)"
        fi
      }
      report_balance WETH   "$WETH"
      report_balance wstETH "$WSTETH"
    fi

    echo "[5/5] CHECK CustomSender 'Sync' events in last ~12h (catches every sync path)"
    # topic0 of ICustomSender.Sync(address,uint64,bytes32,uint256); see lib/chainlink-csr/selectors.txt
    SYNC_TOPIC=0x2826f7440c9ba1050bcd2c586a60551875ac8951ec73f01df55ef00b59ae1a9c
    latest_block=$(cast block-number --rpc-url "$L2_RPC_URL" | tr -d '\r\n')
    older_block=$(( latest_block - 1000 ))
    latest_ts=$(parse_cast_num "$(cast block "$latest_block" --rpc-url "$L2_RPC_URL" --field timestamp 2>/dev/null || true)")
    older_ts=$(parse_cast_num  "$(cast block "$older_block"  --rpc-url "$L2_RPC_URL" --field timestamp 2>/dev/null || true)")
    if [[ -n "$latest_ts" && -n "$older_ts" && "$latest_ts" -gt "$older_ts" ]]; then
      # Compute 12h-window blocks directly to avoid integer division zeroing out
      # for sub-second block times (Arbitrum: ~0.25s, Optimism: 2s, Linea: variable).
      ts_per_1000=$(( latest_ts - older_ts ))
      (( ts_per_1000 > 0 )) || ts_per_1000=2000
      twelve_h_blocks=$(( 12 * 3600 * 1000 / ts_per_1000 ))
      from_block=$(( latest_block - twelve_h_blocks ))
      echo "      cmd: cast logs --json --from-block $from_block --to-block latest --address $SENDER '$SYNC_TOPIC' --rpc-url <rpc>"
      if logs_json=$(cast logs --json --from-block "$from_block" --to-block latest \
                      --address "$SENDER" "$SYNC_TOPIC" \
                      --rpc-url "$L2_RPC_URL" 2>&1); then
        count=$(printf '%s' "$logs_json" | jq 'length' 2>/dev/null || echo 0)
        if [[ "${count:-0}" -eq 0 ]]; then
          echo "      PASS 0 Sync events on $SENDER in last ~12h ($twelve_h_blocks blocks scanned; 1000-block probe spanned ${ts_per_1000}s)"
        else
          echo "      WARN $count Sync event(s) on $SENDER in last ~12h — a CCIP message may still be in flight."
          last_block_hex=$(printf '%s' "$logs_json" | jq -r '.[-1].blockNumber' 2>/dev/null)
          if [[ -n "$last_block_hex" && "$last_block_hex" != "null" ]]; then
            last_block_dec=$(cast --to-dec "$last_block_hex" 2>/dev/null || echo "$last_block_hex")
            echo "           most recent at block $last_block_dec; check https://ccip.chain.link/ for pending."
          fi
          echo "           Proceeding is SAFE: in-flight wstETH lands in the old pool by design (see README §Migration ordering)."
        fi
      else
        echo "      WARN could not scan Sync events (RPC error or range too wide):"
        echo "           $(printf '%s\n' "$logs_json" | head -n1)"
        echo "           Inspect manually on the L2 block explorer:"
        echo "           filter address=$SENDER topic0=$SYNC_TOPIC over the last ~$twelve_h_blocks blocks."
      fi
    else
      echo "      WARN could not derive 12h-ago block estimate (timestamp probe failed); skipping Sync event scan."
    fi

    echo "===================================================================="
    echo "OK L2 preflight passed for $L2_NETWORK. Proceed with migration scripts."
    echo "===================================================================="

# Per-network L1 preflight check. Verifies the L1 RPC is Ethereum mainnet, the
# shared L1 LidoCustomReceiver is reachable, and that its CCIP lane wiring for
# the given L2 network (adapter + sender) matches the expected L2 CustomSender.
#
# Required env: L2_NETWORK + one of:
#   RPC_ETHEREUM  (shell export)
#   L1_RPC_URL    (legacy, loaded from .env.<network>)
#   L2_NETWORK ∈ {optimism, arbitrum, base, linea}
#
# Usage: just preflight-check-l1              (with RPC_ETHEREUM in env)
#        just -E .env.<network> preflight-check-l1  (legacy .env file)
preflight-check-l1:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    # Resolve L1 RPC: prefer RPC_ETHEREUM (shell env), fall back to L1_RPC_URL (legacy .env file).
    L1_RPC_URL="${RPC_ETHEREUM:-${L1_RPC_URL:-}}"
    : "${L1_RPC_URL:?Set RPC_ETHEREUM (or legacy L1_RPC_URL)}"

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

    echo "===================================================================="
    echo "L1 PREFLIGHT CHECK: $L2_NETWORK"
    echo "  L1 RPC URL:            $L1_RPC_URL"
    echo "  Expected chain-id:     $EXPECTED_CHAIN_ID (Ethereum Mainnet)"
    echo "  L1 LidoCustomReceiver: $L1_RECEIVER"
    echo "  L2 CCIP selector:      $L2_CHAIN_SELECTOR"
    echo "  Expected L2 sender:    $EXPECTED_SENDER"
    echo "===================================================================="

    die() { echo "L1 PREFLIGHT FAIL: $*" >&2; exit 1; }
    norm() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

    echo "[1/4] CHECK L1 RPC chain-id matches Ethereum Mainnet ($EXPECTED_CHAIN_ID)"
    echo "      cmd: cast chain-id --rpc-url <l1-rpc>"
    actual_chain_id=$(cast chain-id --rpc-url "$L1_RPC_URL")
    if [[ "$actual_chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
      die "L1 chain-id mismatch: got $actual_chain_id, expected $EXPECTED_CHAIN_ID"
    fi
    # RPC_ETHEREUM shares its name with the fork-test env (local anvil mainnet fork); a fork
    # preserves chain id 1, so the check above cannot tell fork from live. A stale head block
    # means a fork or badly lagging node — refuse to gate the migration on it.
    head_ts=$(cast block latest --field timestamp --rpc-url "$L1_RPC_URL"); head_ts="${head_ts%%[*}"
    head_age=$(( $(date +%s) - head_ts ))
    if (( head_age > 600 )); then
      die "L1 RPC head block is ${head_age}s old — looks like a stale fork or lagging node, not live mainnet (check \$RPC_ETHEREUM)"
    fi
    echo "      PASS chain-id = $actual_chain_id (head block ${head_age}s old)"

    echo "[2/4] CHECK L1 LidoCustomReceiver has bytecode at $L1_RECEIVER"
    echo "      cmd: cast code $L1_RECEIVER --rpc-url <l1-rpc>"
    code=$(cast code "$L1_RECEIVER" --rpc-url "$L1_RPC_URL")
    if [[ "$code" == "0x" || -z "$code" ]]; then
      die "L1 receiver $L1_RECEIVER has no code"
    fi
    echo "      PASS bytecode present at L1 receiver"

    echo "[3/4] CHECK L1 receiver has non-zero adapter for L2 selector $L2_CHAIN_SELECTOR"
    echo "      cmd: cast call $L1_RECEIVER 'getAdapter(uint64)(address)' $L2_CHAIN_SELECTOR --rpc-url <l1-rpc>"
    adapter=$(cast call "$L1_RECEIVER" "getAdapter(uint64)(address)" "$L2_CHAIN_SELECTOR" --rpc-url "$L1_RPC_URL")
    if [[ "$(norm "$adapter")" == "$ZERO_ADDR" ]]; then
      die "no adapter set on L1 receiver for selector $L2_CHAIN_SELECTOR"
    fi
    echo "      PASS adapter = $adapter"

    echo "[4/4] CHECK L1 receiver's sender for L2 selector $L2_CHAIN_SELECTOR matches $EXPECTED_SENDER"
    echo "      cmd: cast call $L1_RECEIVER 'getSender(uint64)(bytes)' $L2_CHAIN_SELECTOR --rpc-url <l1-rpc>"
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
    echo "      PASS sender = $decoded_sender (raw bytes: $sender_bytes)"

    echo "===================================================================="
    echo "OK L1 preflight passed for $L2_NETWORK."
    echo "===================================================================="

# Verify that addresses/selectors duplicated outside the canonical Solidity
# *MigrationConstants.sol files stay in sync with Solidity. Solidity is the
# single source of truth; this recipe only reports drift.
#
# Compared targets per network:
#   - config/state/l2-{net}.inputs.yaml + l2-{net}.deployed.yaml siblings of the shared
#     wiring config/state/l2.yaml   (state-mate validators)
#   - justfile preflight-check / preflight-check-l1 case blocks
#
# Exits non-zero on any drift. Run after editing any duplicate, or in CI.
#
# Usage: just verify-constants-sync
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
      # Every anchor checked here is DEFINED in the .deployed/.inputs siblings (the
      # feat/separate-deployed split). The wiring <net>.yaml only *references* them and cannot be
      # parsed standalone (dangling aliases → yq error), so scan the siblings when present; fall back
      # to the file itself only when it is self-contained (no siblings). `..` recurses every section.
      local base="${1%.yaml}" files=()
      [[ -f "$base.deployed.yaml" ]] && files+=("$base.deployed.yaml")
      [[ -f "$base.inputs.yaml" ]] && files+=("$base.inputs.yaml")
      [[ "${#files[@]}" -eq 0 ]] && files=("$1")
      yq ".. | select(anchor == \"$2\")" "${files[@]}" 2>/dev/null | tr -d '"' | head -n1
    }
    just_field() {
      grep -E "^[[:space:]]+$1\)" justfile \
        | grep -oE "[[:space:];]$2=[^[:space:];]+" | head -n1 | sed -E "s/^[[:space:];]$2=//"
    }
    just_global() {
      grep -E "^[[:space:]]+$1=" justfile \
        | sed -E 's/.*=[[:space:]]*"?(0x[a-fA-F0-9]+)"?.*/\1/' | sort -u
    }
    bytes32_to_addr() {
      local hex="${1#0x}"
      [[ "${#hex}" -eq 64 ]] || { printf '%s' "$1"; return; }
      printf '0x%s' "${hex: -40}"
    }

    L1_SOL=script/l1/L1MigrationConstants.sol
    L1_YAML=config/state/l1-mainnet.yaml
    sol_l1_recv=$(sol_addr "$L1_SOL" L1_LIDO_CUSTOM_RECEIVER)
    sol_l1_recv_impl=$(sol_addr "$L1_SOL" L1_LIDO_CUSTOM_RECEIVER_IMPL)
    sol_initial_owner=$(sol_addr "$L1_SOL" INITIAL_OWNER)
    sol_dao_agent=$(sol_addr "$L1_SOL" LIDO_DAO_AGENT)
    sol_l1_proxy=$(sol_addr "$L1_SOL" L1_PROXY_ADMIN)
    sol_l1_weth=$(sol_addr "$L1_SOL" L1_WETH)
    sol_l1_wsteth=$(sol_addr "$L1_SOL" L1_WSTETH)
    sol_l1_router=$(sol_addr "$L1_SOL" L1_CCIP_ROUTER)
    sol_eth_selector=$(sol_uint "$L1_SOL" ETH_CCIP_CHAIN_SELECTOR)

    echo "===================================================================="
    echo "VERIFY CONSTANTS SYNC"
    echo "  Source of truth: script/l1/L1MigrationConstants.sol"
    echo "                   script/{net}/{Net}MigrationConstants.sol"
    echo "  Compared targets:"
    echo "    - config/state/l2.yaml shared wiring (+ config/state/l2-{net}.deployed.yaml / l2-{net}.inputs.yaml siblings)"
    echo "    - config/state/l2-{net}.inputs.yaml fee blobs vs FeeCodec(constants)"
    echo "    - justfile preflight-check / preflight-check-l1 case blocks"
    echo "===================================================================="

    for net in optimism arbitrum base linea; do
      case "$net" in
        optimism) cap=Optimism ; upper=OPTIMISM ;;
        arbitrum) cap=Arbitrum ; upper=ARBITRUM ;;
        base)     cap=Base     ; upper=BASE ;;
        linea)    cap=Linea    ; upper=LINEA ;;
      esac
      sol="script/${net}/${cap}MigrationConstants.sol"
      # The wiring is now shared (config/state/l2.yaml); the per-lane anchor VALUES live
      # in these siblings. yml_anchor strips `.yaml` and scans <stem>.inputs.yaml/<stem>.deployed.yaml,
      # so this stem still resolves the anchors even though the per-lane wiring file is gone.
      sm="config/state/l2-${net}.yaml"

      sol_l2_sender=$(sol_addr   "$sol" L2_CUSTOM_SENDER)
      sol_l2_sender_impl=$(sol_addr "$sol" L2_CUSTOM_SENDER_IMPL)
      sol_l2_proxy=$(sol_addr    "$sol" L2_PROXY_ADMIN)
      sol_l2_pool=$(sol_addr     "$sol" L2_OLD_ORACLE_POOL)
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

      echo
      echo "[$net] state-mate siblings: ${sm%.yaml}.{inputs,deployed}.yaml (shared wiring: config/state/l2.yaml)"
      expect_eq "l2ChainId → ${upper}_CHAIN_ID"                                  "$sol_chain_id"      "$(yml_anchor "$sm" l2ChainId)"
      expect_eq "l2CustomSender → L2_CUSTOM_SENDER"                              "$sol_l2_sender"     "$(yml_anchor "$sm" l2CustomSender)"
      expect_eq "l2CustomSenderImpl → L2_CUSTOM_SENDER_IMPL"                     "$sol_l2_sender_impl" "$(yml_anchor "$sm" l2CustomSenderImpl)"
      expect_eq "l2ProxyAdmin → L2_PROXY_ADMIN"                                  "$sol_l2_proxy"      "$(yml_anchor "$sm" l2ProxyAdmin)"
      expect_eq "l2OldOraclePool → L2_OLD_ORACLE_POOL"                           "$sol_l2_pool"       "$(yml_anchor "$sm" l2OldOraclePool)"
      expect_eq "l2GovernanceExecutor → LIDO_L2_GOVERNANCE_EXECUTOR"             "$sol_l2_gov"        "$(yml_anchor "$sm" l2GovernanceExecutor)"
      expect_eq "l2CreForwarder → CRE_FORWARDER"                                 "$sol_l2_fwd"        "$(yml_anchor "$sm" l2CreForwarder)"
      expect_eq "l2LiquidityOwner → LIQUIDITY_OWNER"                             "$sol_l2_liq"        "$(yml_anchor "$sm" l2LiquidityOwner)"
      expect_eq "l2OldSyncAutomation → L2_OLD_CHAINLINK_AUTOMATION"              "$sol_l2_oldsync"    "$(yml_anchor "$sm" l2OldSyncAutomation)"
      expect_eq "l2Weth → L2_WETH"                                               "$sol_l2_weth"       "$(yml_anchor "$sm" l2Weth)"
      expect_eq "l2Wsteth → L2_WSTETH"                                           "$sol_l2_wsteth"     "$(yml_anchor "$sm" l2Wsteth)"
      expect_eq "l2LinkToken → L2_LINK_TOKEN"                                    "$sol_l2_link"       "$(yml_anchor "$sm" l2LinkToken)"
      expect_eq "l2CcipRouter → L2_CCIP_ROUTER"                                  "$sol_l2_router"     "$(yml_anchor "$sm" l2CcipRouter)"
      expect_eq "l2PriceOracle → L2_PRICE_ORACLE"                                "$sol_l2_oracle"     "$(yml_anchor "$sm" l2PriceOracle)"
      expect_eq "initialOwner → INITIAL_OWNER (L1 shared)"                       "$sol_initial_owner" "$(yml_anchor "$sm" initialOwner)"
      expect_eq "ethMainnetCcipChainSelector → ETH_CCIP_CHAIN_SELECTOR (L1 shared)" "$sol_eth_selector" "$(yml_anchor "$sm" ethMainnetCcipChainSelector)"
      expect_eq "l1LidoCustomReceiverBytes32 → L1_LIDO_CUSTOM_RECEIVER (L1 shared)" "$sol_l1_recv"   "$(bytes32_to_addr "$(yml_anchor "$sm" l1LidoCustomReceiverBytes32)")"
      if [[ "$net" == "linea" ]]; then
        sol_gelato=$(sol_addr "$sol" L2_OLD_GELATO_AUTOMATION)
        expect_eq "l2OldGelatoSyncAutomation → L2_OLD_GELATO_AUTOMATION"          "$sol_gelato" "$(yml_anchor "config/state/l2-linea-extras.yaml" l2OldGelatoSyncAutomation)"
        expect_eq "preflight-check LINEA_GELATO → L2_OLD_GELATO_AUTOMATION"       "$sol_gelato" "$(just_field linea LINEA_GELATO)"
      fi

      # Fee blobs + derived maxFees are NOT plain constants — they are FeeCodec-encoded from the
      # Solidity sub-params. Verify the .inputs anchors match the deploy's OWN encoding via
      # runPrintFeeParams (it reuses the exact config builder, so this is the static Solidity→.inputs guard).
      if command -v forge >/dev/null 2>&1; then
        fee_script="$(just _l2-script-target "$net")"
        fee_out="$(forge script "$fee_script" --sig 'runPrintFeeParams()' 2>/dev/null || true)"
        # Pull one KEY=value line out of the captured runPrintFeeParams output.
        fee_val() { printf '%s\n' "$fee_out" | sed -n "s/^[[:space:]]*$1=//p" | head -n1; }
        expect_eq "feeOtoD → FeeCodec.encodeCCIP(maxFee,payInLink,gasLimit)" \
          "$(fee_val FEE_OTO_D)"      "$(yml_anchor "$sm" feeOtoD)"
        expect_eq "feeDtoO → FeeCodec.encode${cap}L1toL2(...)" \
          "$(fee_val FEE_DTO_O)"      "$(yml_anchor "$sm" feeDtoO)"
        expect_eq "maxNativeFee → SyncTrigger.getMaxFees().maxNativeFee" \
          "$(fee_val MAX_NATIVE_FEE)" "$(yml_anchor "$sm" maxNativeFee)"
        expect_eq "maxLinkFee → SyncTrigger.getMaxFees().maxLinkFee" \
          "$(fee_val MAX_LINK_FEE)"   "$(yml_anchor "$sm" maxLinkFee)"
        expect_eq "maxGasLimit → SyncTrigger.getMaxGasLimit() (L2_SYNC_MAX_GAS_LIMIT)" \
          "$(fee_val MAX_GAS_LIMIT)"  "$(yml_anchor "$sm" maxGasLimit)"
      else
        echo "  WARN forge not found — skipping fee-blob cross-check (feeOtoD/feeDtoO/maxFees/maxGasLimit)"
      fi

      echo "[$net] justfile preflight-check / preflight-check-l1 case blocks"
      expect_eq "preflight-check SENDER → L2_CUSTOM_SENDER"                      "$sol_l2_sender"   "$(just_field "$net" SENDER)"
      expect_eq "preflight-check POOL → L2_OLD_ORACLE_POOL"                      "$sol_l2_pool"     "$(just_field "$net" POOL)"
      expect_eq "preflight-check OLD_SYNC → L2_OLD_CHAINLINK_AUTOMATION"         "$sol_l2_oldsync"  "$(just_field "$net" OLD_SYNC)"
      expect_eq "preflight-check WETH → L2_WETH"                                 "$sol_l2_weth"     "$(just_field "$net" WETH)"
      expect_eq "preflight-check WSTETH → L2_WSTETH"                             "$sol_l2_wsteth"   "$(just_field "$net" WSTETH)"
      expect_eq "preflight-check EXPECTED_CHAIN_ID → ${upper}_CHAIN_ID"          "$sol_chain_id"    "$(just_field "$net" EXPECTED_CHAIN_ID)"
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
    expect_eq "l1LidoCustomReceiver → L1_LIDO_CUSTOM_RECEIVER"                   "$sol_l1_recv"       "$(yml_anchor "$L1_YAML" l1LidoCustomReceiver)"
    expect_eq "l1LidoCustomReceiverImpl → L1_LIDO_CUSTOM_RECEIVER_IMPL"          "$sol_l1_recv_impl"  "$(yml_anchor "$L1_YAML" l1LidoCustomReceiverImpl)"
    expect_eq "l1ProxyAdmin → L1_PROXY_ADMIN"                                    "$sol_l1_proxy"      "$(yml_anchor "$L1_YAML" l1ProxyAdmin)"
    expect_eq "lidoDaoAgent → LIDO_DAO_AGENT"                                    "$sol_dao_agent"     "$(yml_anchor "$L1_YAML" lidoDaoAgent)"
    expect_eq "initialOwner → INITIAL_OWNER"                                     "$sol_initial_owner" "$(yml_anchor "$L1_YAML" initialOwner)"
    expect_eq "l1Weth → L1_WETH"                                                 "$sol_l1_weth"       "$(yml_anchor "$L1_YAML" l1Weth)"
    expect_eq "l1Wsteth → L1_WSTETH"                                             "$sol_l1_wsteth"     "$(yml_anchor "$L1_YAML" l1Wsteth)"
    expect_eq "l1CcipRouter → L1_CCIP_ROUTER"                                    "$sol_l1_router"     "$(yml_anchor "$L1_YAML" l1CcipRouter)"
    # ethMainnetCcipChainSelector is verified per-L2 above (line: "ethMainnetCcipChainSelector → ...").
    # It is intentionally ABSENT from l1-mainnet.inputs.yaml: no L1 check references it, and an
    # unreferenced anchor is a fatal error under the .inputs full-delegation invariant.

    # L2 wstETH addresses surface on the L1 adapter's L2_TOKEN immutable (Optimism + Base only).
    sol_op_wsteth=$(sol_addr  "script/optimism/OptimismMigrationConstants.sol" L2_WSTETH)
    sol_base_wsteth=$(sol_addr "script/base/BaseMigrationConstants.sol"        L2_WSTETH)
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

# Lint: every L2 state-mate `externals:` / `deployed:` ANCHOR (the contamination-prone address
# surface) must be pinned to a source-of-truth — either cross-checked in `verify-constants-sync`
# (vs *MigrationConstants.sol), or on the explicit no-constant allowlist below WITH a reason.
# Rationale: `verify-constants-sync` proves config == Solidity constant (catches drift between two
# same-team copies) but cannot catch shared contamination; the independent oracle is state-mate-vs
# -chain. A value that is in NEITHER is verified only by same-provenance equality → false-pass risk.
# This lint is exactly the guard that would have surfaced the dev-only `l2LidoDeployer` placeholder.
# (Scope: L2 lanes. L1 anchors are covered by the L1 section of `verify-constants-sync`.)
#
# Usage: just verify-externals-coverage
verify-externals-coverage:
    #!/usr/bin/env bash
    set -uo pipefail
    fail=0; ok=0
    # Anchors that legitimately have NO MigrationConstants.sol address constant (reason each):
    #   l2LidoDeployer  — dev-fork Anvil acct; real mainnet deployer supplied via env, never committed
    #                     (its hasRole==false check is vacuous on mainnet — see the inputs.yaml note)
    #   l2OraclePool / l2SyncTrigger / l2CreReceiver — Stage-1 deploy OUTPUTS (not deploy inputs)
    #   lidoDaoAgent    — L2 echo of the L1 DAO agent (the L1 copy IS constants-checked); pinned
    #                     on-chain via BridgeExecutor.getEthereumGovernanceExecutor
    #   ovmL2CrossDomainMessenger — OP-stack standard predeploy; pinned on-chain via BridgeExecutor
    #   lineaMessageService — Linea message-service predeploy; pinned on-chain via LineaBridgeExecutor
    #                         (Linea analogue of ovmL2CrossDomainMessenger; null on the other lanes)
    allow=" l2LidoDeployer l2OraclePool l2SyncTrigger l2CreReceiver lidoDaoAgent ovmL2CrossDomainMessenger lineaMessageService "
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
    # per-lane state-mate file ("$sm", which yml_anchor expands to l2-<net>.inputs/.deployed) or from a
    # literal config/state/l2-*.yaml path.
    covered=" $(grep -oE 'yml_anchor "(\$sm|config/state/l2-[^"]+)" [A-Za-z0-9]+' justfile \
                  | awk '{print $NF}' | sort -u | tr '\n' ' ')"
    echo "===================================================================="
    echo "VERIFY EXTERNALS COVERAGE  (every L2 external/deployed anchor pinned to a source-of-truth)"
    echo "===================================================================="
    # `linea-extras` = the separate Linea-only Gelato-de-role config (l2-linea-extras.*); its anchors
    # (l2OldGelatoSyncAutomation, l2CustomSender) are constants-checked in verify-constants-sync.
    for net in optimism arbitrum base linea linea-extras; do
      inputs="config/state/l2-${net}.inputs.yaml"
      deployed="config/state/l2-${net}.deployed.yaml"
      anchors="$( { awk '/^externals:/{f=1;next} /^[a-z]/{f=0} f&&/- &/{print}' "$inputs"; \
                    grep -hE '^[[:space:]]*- &' "$deployed" 2>/dev/null; } \
                  | grep -oE '&[A-Za-z0-9]+' | tr -d '&' | sort -u )"
      for a in $anchors; do
        case "$covered" in *" $a "*) ok=$(( ok + 1 )); continue;; esac
        case "$allow"   in *" $a "*) ok=$(( ok + 1 )); continue;; esac
        echo "  UNCOVERED [$net] $a — add a verify-constants-sync row, or allowlist it here with a reason"
        fail=$(( fail + 1 ))
      done
    done
    echo "===================================================================="
    if [[ $fail -eq 0 ]]; then
      echo "OK every L2 external/deployed anchor is constants-checked or allowlisted ($ok anchors)."
    else
      echo "FAIL $fail uncovered anchor(s): a value pinned only by same-provenance equality is a false-pass risk."
      exit 1
    fi
    echo "===================================================================="

# Read-only verification that Stage 1 deploy is complete, correct, and Stage 2 has NOT yet run.
# Run after `runDeploy` and before `runMigrate`. Callable by anyone (no private key needed).
#
# Usage: just -E .env.<network> verify-stage1
#
# Required env (all loaded from .env.<network>): L2_NETWORK, L2_RPC_URL, L2_ORACLE_POOL,
#   L2_SYNC_TRIGGER, L2_CRE_RECEIVER, L2_GOVERNANCE_EXECUTOR, and
#   L2_LIQUIDITY_OWNER (the LOL multisig pinned as CREReceiver.expectedAuthor; defaults to the
#   network LOL multisig when unset). The CRE Forwarder is pinned per network in code.
verify-stage1:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${L2_ORACLE_POOL:?L2_ORACLE_POOL is required; populate it in .env.$L2_NETWORK from deploy-stage1 output}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it in .env.$L2_NETWORK from deploy-stage1 output}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required; populate it in .env.$L2_NETWORK from deploy-stage1 output}"

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runVerifyStage1()' --rpc-url "$L2_RPC_URL"

# Read-only verification that a CRE workflow is registered on the Chainlink WorkflowRegistry
# (Ethereum mainnet) and owned by the LOL multisig (Safe). Run after `cre workflow deploy` (executed
# from the Safe) for each network. Callable by anyone (no private key needed).
#
# Usage: just -E .env.<network> verify-cre-workflow
#
# Required env (all loaded from .env.<network>): L1_RPC_URL, CRE_WORKFLOW_ID (0x + 64 hex chars,
#   non-zero). The expected owner is read from the live on-chain CREReceiver.getExpectedAuthor()
#   when L2_RPC_URL + L2_CRE_RECEIVER are available (authoritative — anchors to what Stage 1 pinned);
#   otherwise falls back to L2_LIQUIDITY_OWNER.
verify-cre-workflow:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L1_RPC_URL:?L1_RPC_URL is required; set it in .env.<network> or export it before running}"
    : "${CRE_WORKFLOW_ID:?CRE_WORKFLOW_ID is required; populate it in .env.<network> from `cre workflow deploy` output}"
    [[ "$CRE_WORKFLOW_ID" =~ ^0x[0-9a-fA-F]{64}$ ]] \
      || { echo "Bad CRE_WORKFLOW_ID: $CRE_WORKFLOW_ID (expected 0x + 64 hex chars)" >&2; exit 1; }
    [[ "$CRE_WORKFLOW_ID" != "0x$(printf '0%.0s' {1..64})" ]] \
      || { echo "Refusing zero CRE_WORKFLOW_ID" >&2; exit 1; }

    # Anchor the expected owner to the authoritative on-chain pin when we can reach L2; this is
    # immune to a drifted L2_LIQUIDITY_OWNER env value. NOTE: this confirms the *registry owner*
    # matches the pin — the report-author gate (DON-embedded metadata.workflowOwner) is only proven
    # by observing a live CREReceiver.CallExecuted (see Monitoring §4 / RUNBOOK).
    if [[ -n "${L2_RPC_URL:-}" && -n "${L2_CRE_RECEIVER:-}" ]]; then
      command -v cast >/dev/null 2>&1 || { echo "Missing 'cast' (foundry)" >&2; exit 1; }
      export CRE_EXPECTED_AUTHOR="$(cast call "$L2_CRE_RECEIVER" 'getExpectedAuthor()(address)' --rpc-url "$L2_RPC_URL" | tr -d '\r\n')"
      echo "Expected owner (on-chain CREReceiver.expectedAuthor): $CRE_EXPECTED_AUTHOR"
    else
      : "${L2_LIQUIDITY_OWNER:?Set L2_RPC_URL + L2_CRE_RECEIVER (preferred, on-chain), or L2_LIQUIDITY_OWNER (the LOL multisig)}"
      echo "Expected owner (env L2_LIQUIDITY_OWNER fallback): $L2_LIQUIDITY_OWNER"
    fi

    forge script script/l1/VerifyCREWorkflow.s.sol:VerifyCREWorkflow \
      --sig 'run(bytes32)' "$CRE_WORKFLOW_ID" --rpc-url "$L1_RPC_URL"

# Rewrite the CRE workflow config for the current network with the deployed SyncTrigger
# + CREReceiver addresses. Run after Stage 1 (`runDeploy`) before `cre workflow deploy`.
#
# Usage: just -E .env.<network> update-cre-config
#
# Required env (all loaded from .env.<network>): L2_NETWORK, L2_SYNC_TRIGGER, L2_CRE_RECEIVER.
update-cre-config:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"

    case "$L2_NETWORK" in
      optimism|arbitrum|base|linea) ;;
      *) echo "Unknown L2_NETWORK: $L2_NETWORK" >&2; exit 2 ;;
    esac

    command -v jq >/dev/null 2>&1 || { echo "Missing required command: jq" >&2; exit 1; }
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it in .env.$L2_NETWORK from deploy-stage1 output}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required; populate it in .env.$L2_NETWORK from deploy-stage1 output}"

    CONFIG="cre-workflows/sync-automation/config.deploy.$L2_NETWORK.json"
    [[ -f "$CONFIG" ]] || { echo "Missing config: $CONFIG" >&2; exit 1; }

    # Hex-address sanity. Rejects 0xYOUR_... placeholders and zero addresses.
    for addr in "$L2_SYNC_TRIGGER" "$L2_CRE_RECEIVER"; do
      [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]] \
        || { echo "Bad address: $addr (expected 0x + 40 hex chars)" >&2; exit 1; }
      [[ "$addr" != "0x0000000000000000000000000000000000000000" ]] \
        || { echo "Refusing zero address: $addr" >&2; exit 1; }
    done

    tmp=$(mktemp)
    jq --arg r "$L2_CRE_RECEIVER" --arg t "$L2_SYNC_TRIGGER" \
      '.receiverAddress = $r | .targetAddress = $t' "$CONFIG" > "$tmp"
    mv "$tmp" "$CONFIG"

    # Verify no "0xYOUR_" placeholder survived.
    if grep -q '0xYOUR_' "$CONFIG"; then
      echo "Placeholder still present in $CONFIG — refusing to proceed" >&2
      exit 1
    fi

    echo "Updated $CONFIG:"
    jq . "$CONFIG"

# Stage 1 — deploy new OraclePool, SyncTrigger, CREReceiver (per network).
# Actor: Lido Deployer. After forge broadcast, the recipe parses the broadcast
# JSON and prints the three deployed addresses as export-ready KEY=VALUE lines
# so the operator can copy them straight into .env.<network> for verify-stage1 /
# update-cre-config / migrate-stage2.
#
# Required env (all loaded from .env.<network>): L2_NETWORK, L2_RPC_URL,
#   L2_LIDO_DEPLOYER_PRIVATE_KEY, L2_GOVERNANCE_EXECUTOR.
#   (The CRE Forwarder is pinned per network in code — see _expectedCREForwarder — not an env var.)
# Optional env: L2_LIQUIDITY_OWNER (defaults to network LOL multisig).
#
# Usage: just -E .env.<network> deploy-stage1
deploy-stage1:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${L2_LIDO_DEPLOYER_PRIVATE_KEY:?required for runDeploy(); export it before running}"
    : "${L2_GOVERNANCE_EXECUTOR:?required for runDeploy()}"
    for c in jq yq cast; do command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; exit 1; }; done

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runDeploy()' --rpc-url "$L2_RPC_URL" --broadcast

    chain_id=$(cast chain-id --rpc-url "$L2_RPC_URL" | tr -d '\r\n')
    bcast="broadcast/$(basename "${SCRIPT%:*}")/${chain_id}/runDeploy-latest.json"
    if [[ -f "$bcast" ]]; then
      pool=$(jq -r '[.transactions[] | select(.contractName == "PausableImmutableOraclePool")][0].contractAddress' "$bcast")
      trigger=$(jq -r '[.transactions[] | select(.contractName == "SyncTrigger")][0].contractAddress' "$bcast")
      receiver=$(jq -r '[.transactions[] | select(.contractName == "CREReceiver")][0].contractAddress' "$bcast")
      echo
      echo "===================================================================="
      echo "Stage 1 deployed for $L2_NETWORK — copy these into .env.$L2_NETWORK:"
      echo "  export L2_ORACLE_POOL=$(cast to-check-sum-address "$pool")"
      echo "  export L2_SYNC_TRIGGER=$(cast to-check-sum-address "$trigger")"
      echo "  export L2_CRE_RECEIVER=$(cast to-check-sum-address "$receiver")"
      echo "===================================================================="

      # Regenerate the committed state-mate `.deployed.yaml` sibling. The pre-existing addresses
      # (CustomSender proxy/impl + ProxyAdmin) are stable and carried over from the existing file;
      # only the three Stage-1 outputs are refreshed from the broadcast JSON above.
      deployed_file="config/state/l2-$L2_NETWORK.deployed.yaml"
      if [[ -f "$deployed_file" ]]; then
        preserved=()
        for anchor in l2CustomSender l2CustomSenderImpl l2ProxyAdmin; do
          preserved+=("$(yq ".. | select(anchor == \"$anchor\")" "$deployed_file" 2>/dev/null | tr -d '"' | head -n1)")
        done
        bash script/shared/write-deployed-yaml.sh "$deployed_file" "${preserved[@]}" "$pool" "$trigger" "$receiver"
        echo "  → updated $deployed_file — review the diff and commit it alongside the migration."
      else
        echo "WARN $deployed_file not found; skipping .deployed.yaml generation." >&2
      fi
    else
      echo "WARN broadcast JSON not found at $bcast; record addresses from the forge log above." >&2
    fi

# Deploy the CRE workflow for <network> via the `cre` CLI, OWNED BY THE LOL MULTISIG (Safe).
# Run after `update-cre-config` has populated the deploy config with the live SyncTrigger and
# CREReceiver addresses.
#
# The workflow owner is the LOL multisig — NOT the EOA running the CLI (ADR-0001, DOC.md §3.2).
# `--unsigned` makes the CLI emit raw WorkflowRegistry calldata instead of broadcasting: you then
# execute that calldata FROM THE SAFE, so the Safe address becomes the on-chain workflow owner and
# the `CREReceiver.expectedAuthor` pin. A throwaway CRE_ETH_PRIVATE_KEY is still needed for RPC-client
# init but never signs the owner transaction.
#
# Required env (loaded from .env.<network>): L2_NETWORK, L2_RPC_URL, L2_CRE_RECEIVER, and
#   CRE_WORKFLOW_OWNER (the LOL multisig; defaults to L2_LIQUIDITY_OWNER when unset). Before emitting
#   the calldata the recipe reads CREReceiver.getExpectedAuthor() on-chain and ABORTS if it does not
#   equal CRE_WORKFLOW_OWNER — so a workflow can never be registered under an owner that the pinned
#   author gate will reject (which would silently brick every sync).
#
# Usage: just -E .env.<network> deploy-cre-workflow
deploy-cre-workflow:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK (used to read CREReceiver.getExpectedAuthor())}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required; populate it in .env.$L2_NETWORK from deploy-stage1 output}"

    case "$L2_NETWORK" in
      optimism|arbitrum|base|linea) ;;
      *) echo "Unknown L2_NETWORK: $L2_NETWORK" >&2; exit 2 ;;
    esac

    command -v cre >/dev/null 2>&1 || { echo "Missing 'cre' CLI" >&2; exit 1; }
    command -v cast >/dev/null 2>&1 || { echo "Missing 'cast' (foundry)" >&2; exit 1; }

    # The workflow owner is the LOL multisig (Safe). Default to L2_LIQUIDITY_OWNER so .env.<network>
    # is the single source of truth; project.yaml interpolates ${CRE_WORKFLOW_OWNER}.
    export CRE_WORKFLOW_OWNER="${CRE_WORKFLOW_OWNER:-${L2_LIQUIDITY_OWNER:-}}"
    [[ "$CRE_WORKFLOW_OWNER" =~ ^0x[0-9a-fA-F]{40}$ ]] \
      || { echo "CRE_WORKFLOW_OWNER (LOL multisig / Safe) must be set to a 0x+40-hex address; got '${CRE_WORKFLOW_OWNER}'. Set CRE_WORKFLOW_OWNER or L2_LIQUIDITY_OWNER in .env.$L2_NETWORK." >&2; exit 1; }
    [[ "$CRE_WORKFLOW_OWNER" != "0x0000000000000000000000000000000000000000" ]] \
      || { echo "Refusing zero CRE_WORKFLOW_OWNER" >&2; exit 1; }

    # Cross-check against the on-chain pin: the workflow owner we are about to register MUST equal the
    # already-deployed CREReceiver.expectedAuthor, or the author gate rejects every report (silent
    # sync stall). Compare checksummed forms so case differences don't cause a false mismatch.
    PINNED="$(cast call "$L2_CRE_RECEIVER" 'getExpectedAuthor()(address)' --rpc-url "$L2_RPC_URL" | tr -d '\r\n')"
    OWNER_CS="$(cast to-check-sum-address "$CRE_WORKFLOW_OWNER")"
    PINNED_CS="$(cast to-check-sum-address "$PINNED")"
    if [[ "$OWNER_CS" != "$PINNED_CS" ]]; then
      echo "ABORT: CRE_WORKFLOW_OWNER ($OWNER_CS) != on-chain CREReceiver.getExpectedAuthor() ($PINNED_CS)." >&2
      echo "Registering the workflow under $OWNER_CS would make every report fail the author gate." >&2
      echo "Fix: set CRE_WORKFLOW_OWNER / L2_LIQUIDITY_OWNER to the pinned author, or re-pin via LOL setExpectedAuthor first." >&2
      exit 1
    fi
    echo "Cross-check OK: CRE_WORKFLOW_OWNER == CREReceiver.expectedAuthor ($OWNER_CS)."

    CONFIG="config.deploy.$L2_NETWORK.json"
    [[ -f "cre-workflows/sync-automation/$CONFIG" ]] \
      || { echo "Missing cre-workflows/sync-automation/$CONFIG. Run 'just -E .env.$L2_NETWORK update-cre-config' first." >&2; exit 1; }

    echo "Deploying CRE workflow owned by LOL multisig $CRE_WORKFLOW_OWNER (--unsigned: execute the emitted calldata FROM THE SAFE)."
    cd cre-workflows/sync-automation && cre workflow deploy . --config "$CONFIG" --target=production-settings --unsigned
    echo
    echo "===================================================================="
    echo "Next: execute the WorkflowRegistry calldata printed above FROM THE LOL SAFE ($CRE_WORKFLOW_OWNER)."
    echo "The Safe address becomes the workflow owner == CREReceiver.expectedAuthor."
    echo "Then record CRE_WORKFLOW_ID= in .env.$L2_NETWORK and run 'just -E .env.$L2_NETWORK verify-cre-workflow'."
    echo "===================================================================="

# Stage 2 — migrate L2 admin (per network). Atomically: setOraclePool(new pool);
# grant SYNC_ROLE to new SyncTrigger and revoke from legacy automation(s);
# rotate DEFAULT_ADMIN on CustomSender from Initial Owner to L2 Governance Executor;
# transfer L2 ProxyAdmin ownership to L2 Governance Executor.
# Actor: Initial Owner (cold key).
#
# Usage: just -E .env.<network> migrate-stage2
#
# Required env (all loaded from .env.<network>): L2_NETWORK, L2_RPC_URL, L2_ORACLE_POOL,
#   L2_SYNC_TRIGGER, L2_CRE_RECEIVER, INITIAL_OWNER_PRIVATE_KEY, L2_GOVERNANCE_EXECUTOR.
#   (The CRE Forwarder is pinned per network in code — see _expectedCREForwarder.)
# Optional env: L2_LIQUIDITY_OWNER (defaults to network LOL multisig).
# (runMigrate() reads L2_CRE_RECEIVER for executeMigrationSteps' Stage-1-completeness precondition.)
migrate-stage2:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${INITIAL_OWNER_PRIVATE_KEY:?required for runMigrate(); export it before running}"
    : "${L2_GOVERNANCE_EXECUTOR:?required for runMigrate()}"
    : "${L2_ORACLE_POOL:?L2_ORACLE_POOL is required; populate it in .env.$L2_NETWORK from deploy-stage1 output}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it in .env.$L2_NETWORK from deploy-stage1 output}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required by runMigrate(); populate it in .env.$L2_NETWORK from deploy-stage1 output}"

    for addr in "$L2_ORACLE_POOL" "$L2_SYNC_TRIGGER" "$L2_CRE_RECEIVER"; do
      [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ && "$addr" != "0x0000000000000000000000000000000000000000" ]] \
        || { echo "Bad address: $addr (expected 0x + 40 hex chars, non-zero)" >&2; exit 1; }
    done

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runMigrate()' --rpc-url "$L2_RPC_URL" --broadcast

# L1 admin migration (runs ONCE — shared across all networks). Grants DEFAULT_ADMIN
# on the L1 LidoCustomReceiver to the Lido DAO Agent and revokes from the Initial
# Owner; transfers L1 ProxyAdmin ownership to the Lido DAO Agent. The L1 Receiver
# is shared across all four L2 networks, so this is a one-time post-rollout step.
# Actor: Initial Owner (cold key).
#
# Required env: L1_RPC_URL (loaded from any .env.<network> — it's identical across the four),
#               INITIAL_OWNER_PRIVATE_KEY, LIDO_DAO_AGENT (or LIDO_NEW_OWNER)
#
# Usage: just -E .env.<any-network> migrate-l1
migrate-l1:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L1_RPC_URL:?L1_RPC_URL is required; set it in .env.<network> or export it before running}"
    : "${INITIAL_OWNER_PRIVATE_KEY:?required for L1 migration; export it before running}"
    [[ -n "${LIDO_DAO_AGENT:-}" || -n "${LIDO_NEW_OWNER:-}" ]] \
      || { echo "LIDO_DAO_AGENT (or LIDO_NEW_OWNER) required for L1 migration" >&2; exit 1; }
    forge script script/l1/L1UpgradeScript.s.sol:L1UpgradeScript \
        --rpc-url "$L1_RPC_URL" --broadcast

# Run the Optimism pool upgrade fork test
test-optimism-upgrade:
    forge test --match-contract OptimismPoolUpgradeTest --rpc-url "$LOCAL_L2_OPTIMISM_RPC_URL" -vvv

# Requires RPC_ETHEREUM + RPC_{OPTIMISM,ARBITRUM,BASE,LINEA} (forked mainnet, same env as the
# acceptance test; legacy L1_RPC_URL / L2_<NET>_RPC_URL are still honoured as fallbacks).
# Base/Arbitrum (v1.6 CCIP lanes) report a measured number; Optimism/Linea route
# through the v1.5 simulator path, which this harness cannot isolate (printed as "not isolated").
# Regenerates the table in README §"Measured ccipReceive gas".
# Measure REAL per-lane L1 ccipReceive gas — the work FeeOtoD.gasLimit budgets.
measure-fee-gas:
    #!/usr/bin/env bash
    set -uo pipefail

    # Resolve RPCs: prefer RPC_<NET> from the current env, fall back to the legacy names
    # the Solidity tests read (L1_RPC_URL / L2_<NET>_RPC_URL) if already exported.
    L1_RPC_URL="${RPC_ETHEREUM:-${L1_RPC_URL:-}}"
    [[ -n "$L1_RPC_URL" ]] || { echo "Set RPC_ETHEREUM (or legacy L1_RPC_URL)" >&2; exit 1; }
    cast chain-id --rpc-url "$L1_RPC_URL" >/dev/null 2>&1 \
      || { echo "L1 RPC not reachable: $L1_RPC_URL (RPC_ETHEREUM)" >&2; exit 1; }
    export L1_RPC_URL

    SPECS=(    OptimismPoolUpgrade ArbitrumPoolUpgrade BasePoolUpgrade LineaPoolUpgrade)
    RPC_ENVS=( RPC_OPTIMISM        RPC_ARBITRUM        RPC_BASE        RPC_LINEA)
    # Legacy env-var names the tests read via vm.envString — consulted as fallbacks.
    L2_ENVS=(  L2_OPTIMISM_RPC_URL L2_ARBITRUM_RPC_URL L2_BASE_RPC_URL L2_LINEA_RPC_URL)

    rc=0
    for i in $(seq 0 $(( ${#SPECS[@]} - 1 ))); do
      spec="${SPECS[$i]}"; rpc_env="${RPC_ENVS[$i]}"; l2_env="${L2_ENVS[$i]}"
      echo "──── ${spec} ────"
      rpc_val="${!rpc_env:-}"
      [[ -n "$rpc_val" ]] || rpc_val="${!l2_env:-}"
      if [[ -z "$rpc_val" ]]; then
        echo "  (skipped — set ${rpc_env} or legacy ${l2_env})"; rc=1
        continue
      fi
      if ! cast chain-id --rpc-url "$rpc_val" >/dev/null 2>&1; then
        echo "  (skipped — ${rpc_env} not reachable: ${rpc_val})"; rc=1
        continue
      fi
      env "${l2_env}=${rpc_val}" \
        forge test --match-path "test/${spec}.t.sol" --match-test test_ccipReceiveGasRealAdapter -vv 2>&1 \
        | grep -E "FeeOtoD.gasLimit carrier|measured ccipReceive|configured FeeOtoD|utilization|Glamsterdam-proj|\[(PASS|FAIL)\]" \
        || { echo "  (no carrier output — forge test produced none; rerun without the grep filter)"; rc=1; }
    done
    exit $rc

# Quote the LIVE CCIP forward-leg fee (L2→L1, "FeeOtoD") on each lane via Router.getFee — the
# native-ETH amount SyncTrigger.triggerSync() pays the CCIP Router every sync
# (CCIPSenderUpgradeable._ccipSendTo → IRouterClient.getFee). This is the ONLY CCIP fee in the
# system: the return leg (L1→L2) rides each L2's native bridge, not CCIP. The reconstructed
# message mirrors what CustomSender builds — dest selector, receiver, one 1-WETH token transfer,
# EVMExtraArgsV1 carrying the lane's gasLimit, all-zero data of the real payload length (the
# quote is gasLimit-dominated; see docs/fees.md "Evidence & reproduction").
#
# This is the live Router quote, NOT the configured ceiling that `runPrintFeeParams()` prints.
# Nothing is hardcoded: every per-lane constant is resolved from config/state/l2-<net>.inputs.yaml
# (the operator review surface, kept in lockstep with the Solidity constants by
# `just verify-constants-sync`) and echoed up front so the quote is auditable —
#   router   ← &l2CcipRouter      selector ← &ethMainnetCcipChainSelector    weth ← &l2Weth
#   receiver ← &l1LidoCustomReceiverBytes32  (already abi.encode(address))
#   gasLimit, maxFee ← decoded from &feeOtoD (encodeCCIP layout: maxFee[16] payInLink[1] gasLimit[4])
#   data length      ← 52 + len(&feeDtoO)   (recipient[20] + amount[32] + feeDtoO)
# Each quote is reported against that lane's own maxFee — the bound that trips
# CCIPSenderExceedsMaxFee; the §monitoring alert fires at 80% utilization.
#
# Required env (per lane, either name): RPC_<NET> (RPC_OPTIMISM/RPC_ARBITRUM/RPC_BASE/RPC_LINEA)
# or legacy L2_<NET>_RPC_URL. Use a live upstream RPC — the local :2800x fork proxies are often
# down. Lanes with a missing/unreachable RPC are skipped (recipe then exits non-zero).
#
# Usage: just quote-ccip-fees
quote-ccip-fees:
    #!/usr/bin/env bash
    set -uo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    command -v yq >/dev/null 2>&1 || { echo "yq (mikefarah) is required" >&2; exit 1; }
    SIG="getFee(uint64,(bytes,bytes,(address,uint256)[],address,bytes))(uint256)"
    # All six per-lane anchors pulled in ONE yq pass per file (vs one process per anchor). The
    # .inputs.yaml entries are anchored list items addressed by recursive descent (`.[]` misses
    # them); the `[..][0]` form pins output order to query order so the positional read is safe.
    ANCHORS='[.. | select(anchor=="l2CcipRouter")][0],
      [.. | select(anchor=="ethMainnetCcipChainSelector")][0],
      [.. | select(anchor=="l1LidoCustomReceiverBytes32")][0],
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

    # ── Resolve every per-lane constant from config/state/l2-<net>.inputs.yaml (one yq pass each) ──
    declare -a ROUTER SELECTOR RECEIVER WETH GASLIM MAXFEE DATALEN
    echo "Resolved from config/state/l2-<net>.inputs.yaml:"
    for i in "${!NETS[@]}"; do
      f="${ROOT_DIR}/config/state/l2-${NETS[$i]}.inputs.yaml"
      [[ -f "$f" ]] || { echo "  ${NAMES[$i]}: inputs file not found: $f" >&2; exit 1; }
      { IFS= read -r ROUTER[$i]; IFS= read -r SELECTOR[$i]; IFS= read -r RECEIVER[$i]
        IFS= read -r WETH[$i];   IFS= read -r otod;        IFS= read -r dtoo
      } < <(yq "$ANCHORS" "$f")
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
        echo "  (skipped — set ${rpc_env} or legacy ${l2_env})"; rc=1
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
      # utilization in bps of this lane's maxFee. Compute in awk: bash `$(( ))` is signed 64-bit (wraps a
      # maxFee/fee >= 2^63 wei) and the old `fee_wei / (MAXFEE/10000)` form divided by ZERO for a maxFee
      # in [1,9999] wei. The ratio is tiny so awk's double precision is ample; MAXFEE/fee_wei stay exact
      # decimal strings for the `cast from-wei` displays. A 0 maxFee (malformed) is flagged, not divided by.
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

# Does the OtoD-leg fee depend on the bridged amount? Sweeps the amount through the live
# `IRouterClient.getFee` (ground truth, version-agnostic) and reports the fee-vs-amount curve, the
# marginal bps, and the breakeven amount where the fee would cross the 0.125 ETH `maxFee` revert bound.
# Also shows the configured token-transfer policy where decodable (v1.5 EVM2EVMOnRamp = OP/Linea); the
# newer FeeQuoter behind v1.6 OnRamps (Arb/Base) has a version-specific struct, so it is NOT decoded —
# the sweep is authoritative. Only the bridged `amount` is swept (the Arbitrum DtoO +~0.001 ETH budget
# is a fixed addend, CustomSender.sol:294). Needs RPC_<NET> (or legacy L2_<NET>_RPC_URL).
# Does the OtoD fee scale with the bridged amount? Sweeps live getFee + reports marginal bps & the maxFee breakeven.
quote-ccip-fee-by-amount:
    #!/usr/bin/env bash
    set -uo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    command -v yq >/dev/null 2>&1 || { echo "yq (mikefarah) is required" >&2; exit 1; }
    SIG="getFee(uint64,(bytes,bytes,(address,uint256)[],address,bytes))(uint256)"
    AMTS_WETH=( 0.001 0.01 0.1 1 10 100 1000 10000 100000 )   # geometric sweep of the bridged amount
    # Same anchors / yq pass as quote-ccip-fees (feeDtoO kept only for the DATALEN computation).
    ANCHORS='[.. | select(anchor=="l2CcipRouter")][0],
      [.. | select(anchor=="ethMainnetCcipChainSelector")][0],
      [.. | select(anchor=="l1LidoCustomReceiverBytes32")][0],
      [.. | select(anchor=="l2Weth")][0],
      [.. | select(anchor=="feeOtoD")][0],
      [.. | select(anchor=="feeDtoO")][0]'

    NETS=( optimism arbitrum base linea )
    declare -a NAMES RPC_ENVS L2_ENVS
    for net in "${NETS[@]}"; do
      u="$(echo "$net" | tr '[:lower:]' '[:upper:]')"
      NAMES+=("${u:0:1}${net:1}"); RPC_ENVS+=("RPC_$u"); L2_ENVS+=("L2_${u}_RPC_URL")
    done

    # ── Resolve every per-lane constant from config/state/l2-<net>.inputs.yaml (one yq pass each) ──
    declare -a ROUTER SELECTOR RECEIVER WETH GASLIM MAXFEE DATALEN
    echo "Resolved from config/state/l2-<net>.inputs.yaml:"
    for i in "${!NETS[@]}"; do
      f="${ROOT_DIR}/config/state/l2-${NETS[$i]}.inputs.yaml"
      [[ -f "$f" ]] || { echo "  ${NAMES[$i]}: inputs file not found: $f" >&2; exit 1; }
      { IFS= read -r ROUTER[$i]; IFS= read -r SELECTOR[$i]; IFS= read -r RECEIVER[$i]
        IFS= read -r WETH[$i];   IFS= read -r otod;        IFS= read -r dtoo
      } < <(yq "$ANCHORS" "$f")
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
        echo "  (skipped — set ${rpc_env} or legacy ${l2_env})"; rc=1
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
      # Anvil forks inherit mainnet chain-id, so opt out of the production combined-run guard.
      ALLOW_UNSAFE_COMBINED_RUN=1 \
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
    STATE_MATE_DEPLOYED="$ROOT_DIR/config/state/l2-optimism.deployed.yaml"
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

    # Read EIP-1967 implementation slot from the proxy.
    EIP1967_IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
    IMPL_RAW="$(cast storage "$L2_CUSTOM_SENDER" "$EIP1967_IMPL_SLOT" --rpc-url "$RPC_URL" | tr -d '\r\n')"
    L2_CUSTOM_SENDER_IMPL="0x$(printf '%s' "${IMPL_RAW#0x}" | tail -c 40)"
    [[ "$L2_CUSTOM_SENDER_IMPL" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "Failed to read implementation slot for $L2_CUSTOM_SENDER"
    L2_CUSTOM_SENDER_IMPL="$(cast to-check-sum-address "$L2_CUSTOM_SENDER_IMPL")"

    bash "$ROOT_DIR/script/shared/write-deployed-yaml.sh" "$STATE_MATE_DEPLOYED" \
      "$L2_CUSTOM_SENDER" "$L2_CUSTOM_SENDER_IMPL" "$L2_PROXY_ADMIN" \
      "$ORACLE_POOL_ADDRESS" "$SYNC_TRIGGER_ADDRESS" "$CRE_RECEIVER_ADDRESS"
    echo "Regenerated state-mate .deployed sibling: ${STATE_MATE_DEPLOYED} (rpc: ${RPC_URL})"

[private]
_state-verify network rpc_url='':
    #!/usr/bin/env bash
    set -euo pipefail

    NETWORK="{{network}}"
    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    RPC_URL="{{rpc_url}}"

    # Map network name to default RPC env var + state-mate yaml location.
    # Priority: positional [rpc_url] > L2_RPC_URL (from .env.<net>) > legacy fallbacks.
    # The four mainnet L2 lanes share ONE wiring file (config/state/l2.yaml) and pass
    # their per-lane siblings explicitly (auto-discovery is basename-keyed, so a bare l2.yaml would
    # look for l2.inputs.yaml/l2.deployed.yaml). Sepolia keeps its own self-contained config whose
    # siblings are auto-discovered by basename.
    SHARED_L2_CONFIG="config/state/l2.yaml"
    case "$NETWORK" in
      optimism) DEFAULT_RPC_URL="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_OPTIMISM_RPC_URL:-${L2_OPTIMISM_RPC_URL:-}}}}"
                STATE_MATE_CONFIG_PATH="$SHARED_L2_CONFIG" ;;
      arbitrum) DEFAULT_RPC_URL="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_ARBITRUM_RPC_URL:-${L2_ARBITRUM_RPC_URL:-}}}}"
                STATE_MATE_CONFIG_PATH="$SHARED_L2_CONFIG" ;;
      base)     DEFAULT_RPC_URL="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_BASE_RPC_URL:-${L2_BASE_RPC_URL:-}}}}"
                STATE_MATE_CONFIG_PATH="$SHARED_L2_CONFIG" ;;
      linea)    DEFAULT_RPC_URL="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_LINEA_RPC_URL:-${L2_LINEA_RPC_URL:-}}}}"
                STATE_MATE_CONFIG_PATH="$SHARED_L2_CONFIG" ;;
      sepolia)  DEFAULT_RPC_URL="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_OPTIMISM_SEPOLIA_RPC_URL:-${L2_OPTIMISM_SEPOLIA_RPC_URL:-}}}}"
                STATE_MATE_CONFIG_PATH="config/state/sepolia.yaml" ;;
      *)        echo "Unknown network: $NETWORK" >&2; exit 1 ;;
    esac

    STATE_MATE_OUTPUT_FILE="${L2_STATE_MATE_OUTPUT_FILE:-${TMPDIR:-/tmp}/${NETWORK}-l2-state-mate.env}"
    STATE_MATE_DIR="$ROOT_DIR/lib/state-mate"
    STATE_MATE_CONFIG="$ROOT_DIR/$STATE_MATE_CONFIG_PATH"

    # When using the shared wiring, point it at this lane's siblings explicitly (absolute paths,
    # since the runner cd's into lib/state-mate). Sepolia's self-contained config auto-discovers.
    STATE_MATE_SIBLING_ARGS=()
    if [[ "$STATE_MATE_CONFIG_PATH" == "$SHARED_L2_CONFIG" ]]; then
      STATE_MATE_SIBLING_ARGS=(
        --inputs   "$ROOT_DIR/config/state/l2-$NETWORK.inputs.yaml"
        --deployed "$ROOT_DIR/config/state/l2-$NETWORK.deployed.yaml"
      )
    fi
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
      env -u NO_COLOR L2_STATE_MATE_RPC_URL="$RPC_URL" FORCE_COLOR=3 CLICOLOR_FORCE=1 "${YARN_CMD[@]}" start "$STATE_MATE_CONFIG" "${STATE_MATE_SIBLING_ARGS[@]+"${STATE_MATE_SIBLING_ARGS[@]}"}" --only "l2"
    ) 2>&1 | tee "$STATE_MATE_LOG"
    STATE_MATE_EXIT="${PIPESTATUS[0]}"
    set -e

    echo ""
    echo "----- state-mate full output -----"
    perl -pe 's/\r/\n/g' "$STATE_MATE_LOG"
    echo "----- end state-mate output -----"

    [[ "$STATE_MATE_EXIT" -eq 0 ]] || die "state-mate checks failed for $NETWORK"
    echo "$NETWORK state verification passed"

    # Linea-only extras (legacy Gelato keeper de-role) — a separate config run IN ADDITION to the
    # shared l2.yaml; it auto-discovers its own l2-linea-extras.{inputs,deployed}.yaml siblings.
    if [[ "$NETWORK" == "linea" ]]; then
      echo "Running Linea-only state-mate extras (Gelato de-role) against ${RPC_URL}"
      set +e
      (
        cd "$STATE_MATE_DIR"
        env -u NO_COLOR L2_STATE_MATE_RPC_URL="$RPC_URL" FORCE_COLOR=3 CLICOLOR_FORCE=1 "${YARN_CMD[@]}" start "$ROOT_DIR/config/state/l2-linea-extras.yaml" --only "l2"
      ) 2>&1 | tee -a "$STATE_MATE_LOG"
      EXTRAS_EXIT="${PIPESTATUS[0]}"
      set -e
      [[ "$EXTRAS_EXIT" -eq 0 ]] || die "Linea extras state-mate checks failed"
      echo "linea extras state verification passed"
    fi

# Run state-mate against the shared L1 mainnet yaml. Post-Stage-2 L1 verification
# (LidoCustomReceiver DEFAULT_ADMIN rotation, ProxyAdmin ownership, per-lane wiring).
# Shared across all four L2 lanes — runs once.
#
# Usage: just verify-l1-state-mate [l1_rpc_url]
verify-l1-state-mate l1_rpc_url='':
    #!/usr/bin/env bash
    set -euo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    RPC_URL="{{l1_rpc_url}}"
    [[ -n "$RPC_URL" ]] || RPC_URL="${L1_RPC_URL:-}"
    [[ -n "$RPC_URL" ]] || { echo "Missing RPC URL: pass [l1_rpc_url] or set L1_RPC_URL" >&2; exit 1; }

    STATE_MATE_DIR="$ROOT_DIR/lib/state-mate"
    STATE_MATE_CONFIG="$ROOT_DIR/config/state/l1-mainnet.yaml"

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
#   RPC_ETHEREUM / RPC_OPTIMISM / RPC_ARBITRUM / RPC_BASE / RPC_LINEA — upstream RPCs for forking
#     (legacy L1_RPC_URL / L2_<NET>_RPC_URL are still honoured as fallbacks)
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
    NET_RPC_ENVS=( RPC_OPTIMISM                     RPC_ARBITRUM                     RPC_BASE                         RPC_LINEA)
    # Legacy env-var names, consulted as fallbacks when the RPC_<NET> var is unset.
    NET_RPC_ENVS_LEGACY=( L2_OPTIMISM_RPC_URL        L2_ARBITRUM_RPC_URL              L2_BASE_RPC_URL                  L2_LINEA_RPC_URL)
    NET_GOVS=(     0xEfa0dB536d2c8089685630fafe88CF7805966FC3 0x1dcA41859Cd23b526CBe74dA8F48aC96e14B1A29 0x0E37599436974a25dDeEdF795C848d30Af46eaCF 0x74Be82F00CC867614803ffd7f36A2a4aF0405670)
    NET_SCRIPTS=(  "script/optimism/OptimismL2Upgrade.s.sol:OptimismL2UpgradeScript" \
                   "script/arbitrum/ArbitrumL2Upgrade.s.sol:ArbitrumL2UpgradeScript" \
                   "script/base/BaseL2Upgrade.s.sol:BaseL2UpgradeScript" \
                   "script/linea/LineaL2Upgrade.s.sol:LineaL2UpgradeScript")
    NET_TESTS=(    "OptimismPoolUpgradeTest|OptimismCREIntegrationTest" \
                   "ArbitrumPoolUpgradeTest|ArbitrumCREIntegrationTest" \
                   "BasePoolUpgradeTest|BaseCREIntegrationTest" \
                   "LineaPoolUpgradeTest|LineaCREIntegrationTest")
    NET_SENDERS=(  0x328de900860816d29D1367F6903a24D8ed40C997 0x72229141D4B016682d3618ECe47c046f30Da4AD1 0x328de900860816d29D1367F6903a24D8ed40C997 0x328de900860816d29D1367F6903a24D8ed40C997)
    NET_IMPLS=(    0x65498495DdC07c52E12EEe3c44D3a1166eed8703 0x220F64A4793Bc8aca7330ceCc4ae4e2F3B5Bc664 0x65498495DdC07c52E12EEe3c44D3a1166eed8703 0xBf96561e4519182CFA4cebBf95494D9CA5a316f9)
    NET_PROXIES=(  0x4c8c4A15c1e810e481c412A9B06Be5f79dC02192 0x5B42aEbFe95247f1d22e282831e2A513bF050217 0x4c8c4A15c1e810e481c412A9B06Be5f79dC02192 0x4c8c4A15c1e810e481c412A9B06Be5f79dC02192)
    NET_LOLS=(     0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61 0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61 0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61 0xA8ef4Db842D95DE72433a8b5b8FF40CB7C74C1b6)
    NET_COUNT=${#NET_NAMES[@]}

    die() { echo "FAIL: $*" >&2; exit 1; }

    # Validate parallel arrays have consistent length
    for arr_name in NET_RPC_ENVS NET_RPC_ENVS_LEGACY NET_GOVS NET_SCRIPTS NET_TESTS NET_SENDERS NET_IMPLS NET_PROXIES NET_LOLS; do
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
      local url="$1" name="$2" timeout="${3:-180}"
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

    L1_UPSTREAM="${RPC_ETHEREUM:-${L1_RPC_URL:-}}"
    [[ -n "$L1_UPSTREAM" ]] || die "Set RPC_ETHEREUM"
    cast chain-id --rpc-url "$L1_UPSTREAM" >/dev/null 2>&1 || die "L1 RPC not reachable: $L1_UPSTREAM"
    echo "L1: $L1_UPSTREAM"

    # Collect and validate L2 RPCs (prefer RPC_<NET>, fall back to the legacy L2_<NET>_RPC_URL).
    L2_UPSTREAMS=()
    for i in $(seq 0 $((NET_COUNT - 1))); do
      rpc_env="${NET_RPC_ENVS[$i]}"
      rpc_env_legacy="${NET_RPC_ENVS_LEGACY[$i]}"
      rpc_val="${!rpc_env:-}"
      [[ -n "$rpc_val" ]] || rpc_val="${!rpc_env_legacy:-}"
      [[ -n "$rpc_val" ]] || die "Set $rpc_env"
      cast chain-id --rpc-url "$rpc_val" >/dev/null 2>&1 || die "${NET_NAMES[$i]} RPC not reachable: $rpc_val"
      L2_UPSTREAMS+=("$rpc_val")
      echo "${NET_NAMES[$i]}: $rpc_val"
    done
    echo "All RPCs OK"

    # On a fork the deployer just needs to be a funded address (the recipe tops it up via
    # anvil_setBalance below), so fall back to anvil's well-known dev key #0 when unset.
    export L2_LIDO_DEPLOYER_PRIVATE_KEY="${L2_LIDO_DEPLOYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
    DEPLOYER_ADDR="$(address_from_key "$L2_LIDO_DEPLOYER_PRIVATE_KEY")"
    echo "Deployer: $DEPLOYER_ADDR"

    # ── Step 1: Spawn forks ────────────────────────────────────────
    # Forks are spawned serially (each anvil waits for the previous to be ready,
    # plus a short cool-down) because anvil performs a burst of eth_get* calls
    # during genesis creation; 4 parallel L2 forks against one Infura key hit
    # HTTP 429 rate limits and the failing anvils exit with "failed to create
    # genesis". `wait_for_rpc` returns as soon as chain-id responds, but the
    # genesis burst is still draining for a few seconds afterwards — the
    # cool-down lets it finish before the next fork starts hammering the same
    # API key. Override with FORK_SPAWN_COOLDOWN_SECONDS=N.
    # Default 0: the RPC_<NET> upstreams are local anvil forks that don't rate-limit, so the
    # genesis burst can't trip 429s. Bump it (e.g. FORK_SPAWN_COOLDOWN_SECONDS=10) when pointing
    # the legacy L2_<NET>_RPC_URL fallbacks at a shared remote key like Infura.
    FORK_SPAWN_COOLDOWN_SECONDS="${FORK_SPAWN_COOLDOWN_SECONDS:-0}"
    # Wall-clock budget from spawn (not an additive sleep): if wait_for_rpc already
    # burned the budget on a slow Infura day, skip the sleep. Applied to L1 too —
    # L1 and L2 RPCs share an Infura key in some setups, so the first L2 spawning
    # back-to-back with L1's genesis burst can race.
    spawn_with_cooldown() {
      local fork_url="$1" name="$2" upstream="$3" port="$4" log="$5" cooldown="$6"
      local spawn_t=$SECONDS
      anvil --silent --auto-impersonate -p "$port" -f "$upstream" >"$log" 2>&1 &
      ANVIL_PIDS="$ANVIL_PIDS $!"
      echo "$name fork: $fork_url"
      wait_for_rpc "$fork_url" "$name"
      if (( cooldown > 0 )); then
        local remaining=$(( cooldown - (SECONDS - spawn_t) ))
        (( remaining > 0 )) && sleep "$remaining"
      fi
    }

    step "Step 1: Starting Anvil forks"
    L1_PORT="$BASE_PORT"
    L1_FORK_URL="http://127.0.0.1:$L1_PORT"
    spawn_with_cooldown "$L1_FORK_URL" "L1" "$L1_UPSTREAM" "$L1_PORT" "$WORK_DIR/l1.log" "$FORK_SPAWN_COOLDOWN_SECONDS"

    L2_FORK_URLS=()
    L2_FORK_SNAPSHOTS=()
    for i in $(seq 0 $((NET_COUNT - 1))); do
      port=$((BASE_PORT + 1 + i))
      fork_url="http://127.0.0.1:$port"
      # Skip cool-down after the last L2 — nothing else spawns after it.
      cooldown=$FORK_SPAWN_COOLDOWN_SECONDS
      (( i == NET_COUNT - 1 )) && cooldown=0
      spawn_with_cooldown "$fork_url" "${NET_NAMES[$i]}" "${L2_UPSTREAMS[$i]}" "$port" "$WORK_DIR/${NET_NAMES[$i]}.log" "$cooldown"
      L2_FORK_URLS+=("$fork_url")
      # Snapshot the pristine fork. Step 2 (migrate) + Step 3 (state-mate) then exercise it,
      # which warms anvil's upstream-state cache; Step 4 reverts to this snapshot to hand the
      # forge tests a CLEAN-but-WARM fork — so they re-run the migration themselves yet avoid
      # cold-fetching mainnet state through flaky L2 RPC backends (Base's drpc lane in particular).
      snap="$(cast rpc --rpc-url "$fork_url" evm_snapshot | tr -d '"\r\n')"
      L2_FORK_SNAPSHOTS+=("$snap")
    done
    echo "All forks ready"

    # ── Step 2: L2 migrations (per-network) ────────────────────────
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
      # ALLOW_UNSAFE_COMBINED_RUN=1 opts out of the production guard in L2UpgradeScriptBase
      # (block.chainid is the upstream mainnet id because this is an anvil fork).
      # The CRE Forwarder is pinned per network in code (see _expectedCREForwarder), so no
      # L2_CRE_FORWARDER env is needed; the real forwarder isn't exercised here anyway because CRE
      # reports would need the actual off-chain DON to originate.
      substep "Stages 1+2: deploy + migrate"
      (
        cd "$ROOT_DIR"
        L2_GOVERNANCE_EXECUTOR="$gov" \
        ALLOW_UNSAFE_COMBINED_RUN=1 \
        forge script "${NET_SCRIPTS[$i]}" \
          --sig "runWithUnlockedInitialOwner()" \
          --rpc-url "$fork_url" \
          --broadcast --non-interactive \
          --unlocked --sender "$INITIAL_OWNER" 2>&1 | tail -5
      )
      # Read the actual deployed addresses from the forge broadcast JSON (robust against
      # adding / removing intermediate setter txs that would shift nonces).
      script_file="${NET_SCRIPTS[$i]%:*}"
      script_base="$(basename "$script_file")"
      chain_id="$(cast chain-id --rpc-url "$fork_url" | tr -d '\r\n')"
      bcast_json="$ROOT_DIR/broadcast/${script_base}/${chain_id}/runWithUnlockedInitialOwner-latest.json"
      [[ -f "$bcast_json" ]] || die "Missing forge broadcast JSON: $bcast_json"
      pool_addr="$(jq -r '[.transactions[] | select(.contractName == "PausableImmutableOraclePool")][0].contractAddress' "$bcast_json")"
      trigger_addr="$(jq -r '[.transactions[] | select(.contractName == "SyncTrigger")][0].contractAddress' "$bcast_json")"
      recv_addr="$(jq -r '[.transactions[] | select(.contractName == "CREReceiver")][0].contractAddress' "$bcast_json")"
      pool_addr="$(cast to-check-sum-address "$pool_addr")"
      trigger_addr="$(cast to-check-sum-address "$trigger_addr")"
      recv_addr="$(cast to-check-sum-address "$recv_addr")"
      echo "  OraclePool: $pool_addr  SyncTrigger: $trigger_addr  CREReceiver: $recv_addr"

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

      sm_config="$ROOT_DIR/config/state/l2.yaml"
      sm_inputs="$ROOT_DIR/config/state/l2-$name.inputs.yaml"
      # Fork redeploys land at addresses that differ from the committed (mainnet-expected) ones, so
      # write the fork's ACTUAL deployed addresses to a throwaway .deployed.yaml and override the
      # committed sibling via --deployed. The static <net>.inputs.yaml (governance actors, tokens,
      # fee blobs) needs no override — the fork reuses the canonical NET_GOVS/NET_LOLS and the anvil
      # dev deployer (= the committed l2LidoDeployer) — but it MUST be passed explicitly since the
      # shared l2.yaml's basename-keyed auto-discovery would otherwise look for l2.inputs.yaml.
      fork_deployed="$WORK_DIR/$name.deployed.yaml"
      substep "$name: writing fork .deployed.yaml"
      bash "$ROOT_DIR/script/shared/write-deployed-yaml.sh" "$fork_deployed" \
        "${NET_SENDERS[$i]}" "${NET_IMPLS[$i]}" "${NET_PROXIES[$i]}" \
        "${DEPLOYED_POOLS[$i]}" "${DEPLOYED_TRIGGERS[$i]}" "${DEPLOYED_RECEIVERS[$i]}"

      substep "$name: running state-mate checks"
      (
        cd "$STATE_MATE_DIR"
        L2_STATE_MATE_RPC_URL="$fork_url" yarn start "$sm_config" --inputs "$sm_inputs" --deployed "$fork_deployed" --only "l2" 2>&1 | tail -8
      ) || die "$name state-mate failed"
      # Linea-only Gelato de-role — separate config; its static siblings (deterministic CustomSender +
      # the Gelato addr) match the fork, so no per-fork override is needed.
      if [[ "$name" == "linea" ]]; then
        substep "$name: running Linea-only state-mate extras (Gelato de-role)"
        (
          cd "$STATE_MATE_DIR"
          L2_STATE_MATE_RPC_URL="$fork_url" yarn start "$ROOT_DIR/config/state/l2-linea-extras.yaml" --only "l2" 2>&1 | tail -8
        ) || die "$name extras state-mate failed"
      fi
    done
    echo "All L2 state-mate checks passed"

    substep "L1: running state-mate checks against fork"
    (
      cd "$STATE_MATE_DIR"
      L1_RPC_URL="$L1_FORK_URL" yarn start "$ROOT_DIR/config/state/l1-mainnet.yaml" --only "l1" 2>&1 | tail -12
    ) || die "L1 state-mate failed"
    echo "L1 state-mate checks passed"

    # ── Step 4: Forge integration tests ────────────────────────────
    # Each forge suite re-runs the full deploy+migrate itself (pranking INITIAL_OWNER), so it needs
    # PRE-migration state; against a migrated fork those steps revert with AccessControl/Ownable-
    # unauthorized because INITIAL_OWNER's roles were already moved. So point the suites at:
    #   • L2 — the Step-1 forks ($L2_FORK_URLS), first reverted to their pristine pre-migration
    #     snapshot (the loop below). evm_revert rolls back Step 2's migration but keeps the
    #     upstream-state cache anvil warmed in Steps 2–3 (it only unwinds local diffs, not the fork
    #     backend cache) — so the suites get clean state without cold-fetching mainnet through the
    #     flaky L2 backends.
    #   • L1 — the clean $L1_UPSTREAM, NOT the Step-1 L1 fork ($L1_FORK_URL), which Step 2 migrated
    #     (there is no L1 snapshot to revert).
    # vm.createFork is in-memory, so the suites never mutate these shared forks.
    substep "Reverting L2 forks to pristine snapshots (clean + warm) for forge tests"
    for i in $(seq 0 $((NET_COUNT - 1))); do
      cast rpc --rpc-url "${L2_FORK_URLS[$i]}" evm_revert "${L2_FORK_SNAPSHOTS[$i]}" >/dev/null \
        || die "${NET_NAMES[$i]} evm_revert to snapshot ${L2_FORK_SNAPSHOTS[$i]} failed"
    done

    # Run per-network, sequentially, against the now clean+warm local L2 forks ($L2_FORK_URLS[i]) and
    # the clean L1 upstream. Each suite reads the network-specific L2_<NET>_RPC_URL (and the LOCAL_
    # alias some bases prefer). Sequential is deliberate — four suites at once multiplies any residual
    # cold-fetch demand on the slower backends. A generous ETH_RPC_TIMEOUT absorbs the occasional
    # slow upstream read on the flakier lanes.
    step "Step 4: Forge integration tests (per network)"
    for i in $(seq 0 $((NET_COUNT - 1))); do
      name="${NET_NAMES[$i]}"
      l2_env="${NET_RPC_ENVS_LEGACY[$i]}"
      substep "$name: forge tests (${NET_TESTS[$i]})"
      (
        cd "$ROOT_DIR"
        export L1_RPC_URL="$L1_UPSTREAM"
        export "$l2_env=${L2_FORK_URLS[$i]}"
        export "LOCAL_$l2_env=${L2_FORK_URLS[$i]}"
        export ETH_RPC_TIMEOUT="${ETH_RPC_TIMEOUT:-120}"
        forge test --match-contract "${NET_TESTS[$i]}" -vv
      ) || die "$name forge tests failed"
    done

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

# Regenerate config/state/l2-optimism.deployed.yaml after migration
test-optimism-upgrade-state-update-config rpc_url='':
    @just _optimism-state-update-config "{{rpc_url}}"

# Verify post-migration state-mate checks. Reads L2_RPC_URL from .env.<network>
# (or legacy fallbacks: L2_STATE_MATE_RPC_URL / LOCAL_L2_<NET>_RPC_URL / L2_<NET>_RPC_URL).
# Usage: just -E .env.<network> test-<network>-upgrade-state-verify
test-optimism-upgrade-state-verify:
    @just _state-verify optimism ""

test-arbitrum-upgrade-state-verify:
    @just _state-verify arbitrum ""

test-base-upgrade-state-verify:
    @just _state-verify base ""

test-linea-upgrade-state-verify:
    @just _state-verify linea ""

# Verify post-migration state-mate checks for Sepolia (Optimism Sepolia testnet)
# against the canonical config/state/sepolia.yaml. Use this after
# `sepolia-deploy-csr` + `sepolia-deploy-stage1` + `sepolia-migrate-stage2` to confirm the
# rehearsal landed the same on-chain post-conditions as the mainnet flow would.
# Usage: just -E .env.sepolia test-sepolia-upgrade-state-verify
test-sepolia-upgrade-state-verify:
    @just _state-verify sepolia ""

# Legacy alias
test-optimism-upgrade-state:
    @just _acceptance-test

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

# Addresses/tokens read from the state-mate config/state/ siblings: deployed addrs from
# <net>.deployed.yaml (.deployed.l1/.l2 anchors), tokens from <net>.inputs.yaml (.externals anchors).
balances-l1:
    @echo "--- L1 (Ethereum) ---"
    @just _balances-l1 LidoCustomReceiver "$(yq '.deployed.l1[] | select(anchor == "l1LidoCustomReceiver")' config/state/l1-mainnet.deployed.yaml)" "$L1_RPC_URL" "$(yq '.externals[] | select(anchor == "l1Weth")' config/state/l1-mainnet.inputs.yaml)" "$(yq '.externals[] | select(anchor == "l1Wsteth")' config/state/l1-mainnet.inputs.yaml)"

# Print CustomSender + OraclePool balances for one L2 lane. Deployed addrs come from
# config/state/l2-<net>.deployed.yaml; WETH/wstETH token addrs from l2-<net>.inputs.yaml
# (read once and reused for both sub-calls).
[no-exit-message]
_balances-net net label rpc_url:
    #!/usr/bin/env bash
    set -euo pipefail
    dep="config/state/l2-{{net}}.deployed.yaml"
    inp="config/state/l2-{{net}}.inputs.yaml"
    weth="$(yq '.externals[] | select(anchor == "l2Weth")' "$inp")"
    wsteth="$(yq '.externals[] | select(anchor == "l2Wsteth")' "$inp")"
    echo "--- {{label}} ---"
    just _balances-l2 CustomSender "$(yq '.deployed.l2[] | select(anchor == "l2CustomSender")' "$dep")" "{{rpc_url}}" "$weth" "$wsteth"
    echo ""
    just _balances-l2 OraclePool "$(yq '.deployed.l2[] | select(anchor == "l2OraclePool")' "$dep")" "{{rpc_url}}" "$weth" "$wsteth"

balances-optimism:
    @just _balances-net optimism Optimism "$L2_OPTIMISM_RPC_URL"

balances-arbitrum:
    @just _balances-net arbitrum Arbitrum "$L2_ARBITRUM_RPC_URL"

balances-base:
    @just _balances-net base Base "$L2_BASE_RPC_URL"

balances-linea:
    @just _balances-net linea Linea "$L2_LINEA_RPC_URL"

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

rpc-start-l2-base:
    anvil -p 8553 -f "$L2_BASE_RPC_URL"

rpc-start-l2-linea:
    anvil -p 8554 -f "$L2_LINEA_RPC_URL"

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

# Step 0: Deploy full CSR infrastructure to Sepolia + OP Sepolia
# (mainnet has CSR already deployed by Chainlink; testnet must bootstrap from scratch).
# Required env: DEPLOYER_PRIVATE_KEY, L1_SEPOLIA_RPC_URL, L2_OPTIMISM_SEPOLIA_RPC_URL.
sepolia-deploy-csr:
    forge script script/optimism/sepolia/SepoliaCSRDeploy.s.sol:SepoliaCSRDeployScript \
        --broadcast --non-interactive -vvv

# Stage 1: Lido Deployer deploys new OraclePool + SyncTrigger + CREReceiver and configures them.
# Mirrors `just deploy-stage1 <network>` on mainnet — same `runDeploy()` entrypoint, same env contract.
# Required env: L2_LIDO_DEPLOYER_PRIVATE_KEY, L2_GOVERNANCE_EXECUTOR, L2_CRE_FORWARDER,
#               L2_CUSTOM_SENDER, L2_PROXY_ADMIN, L2_PRICE_ORACLE, L2_BOOTSTRAP_SYNC_AUTOMATION,
#               L2_OPTIMISM_SEPOLIA_RPC_URL.
# Optional env: L2_LIQUIDITY_OWNER (defaults to L2_GOVERNANCE_EXECUTOR), L2_INITIAL_OWNER.
sepolia-deploy-stage1:
    forge script script/optimism/sepolia/SepoliaL2Upgrade.s.sol:SepoliaL2UpgradeScript \
        --sig "runDeploy()" \
        --rpc-url "$L2_OPTIMISM_SEPOLIA_RPC_URL" \
        --broadcast --non-interactive -vvv

# Stage-1 read-only verification: 18 post-state assertions inherited from L2UpgradeScriptBase.
# Mirrors `just verify-stage1 <network>` on mainnet. Callable by anyone (no private key needed).
# Required env: L2_ORACLE_POOL, L2_SYNC_TRIGGER, L2_CRE_RECEIVER, L2_GOVERNANCE_EXECUTOR,
#               L2_CRE_FORWARDER. The CREReceiver.expectedAuthor pin is the CRE workflow owner =
#               L2_LIQUIDITY_OWNER (on testnet this defaults to L2_GOVERNANCE_EXECUTOR).
sepolia-verify-stage1:
    forge script script/optimism/sepolia/SepoliaL2Upgrade.s.sol:SepoliaL2UpgradeScript \
        --sig "runVerifyStage1()" \
        --rpc-url "$L2_OPTIMISM_SEPOLIA_RPC_URL" \
        --non-interactive -vvv

# Stage 2: Initial Owner migrates L2 admin/role state. Wraps `executeMigrationSteps` with
# bootstrap-automation neutralization (extras) and bootstrap-pool retirement (sweep + pause +
# transfer). Mirrors `just migrate-stage2 <network>` on mainnet.
# Required env: L2_OPTIMISM_SEPOLIA_RPC_URL, INITIAL_OWNER_PRIVATE_KEY, L2_GOVERNANCE_EXECUTOR,
#               L2_BOOTSTRAP_SYNC_AUTOMATION, L2_ORACLE_POOL, L2_SYNC_TRIGGER, L2_CRE_RECEIVER,
#               L2_CRE_FORWARDER, L2_CUSTOM_SENDER, L2_PROXY_ADMIN, L2_PRICE_ORACLE.
sepolia-migrate-stage2:
    #!/usr/bin/env bash
    set -euo pipefail
    # Mirror the mainnet migrate-stage2 guards: fail upfront with a clear just-level error rather than
    # mid-simulation when SepoliaL2Upgrade.runMigrate -> _runMigrateBody reads any of these via
    # vm.envAddress (L2_CRE_RECEIVER among them — SepoliaL2Upgrade.s.sol).
    : "${L2_OPTIMISM_SEPOLIA_RPC_URL:?required; set it in .env.sepolia or export it before running}"
    : "${INITIAL_OWNER_PRIVATE_KEY:?required for runMigrate(); export it before running}"
    : "${L2_GOVERNANCE_EXECUTOR:?required (final L2 admin; also the default liquidity owner on Sepolia)}"
    : "${L2_BOOTSTRAP_SYNC_AUTOMATION:?required; the bootstrap SyncAutomation to neutralize + de-role}"
    : "${L2_ORACLE_POOL:?required; populate from sepolia-deploy-stage1 output}"
    : "${L2_SYNC_TRIGGER:?required; populate from sepolia-deploy-stage1 output}"
    : "${L2_CRE_RECEIVER:?required by runMigrate() (Stage-1-completeness precondition); populate from sepolia-deploy-stage1 output}"
    : "${L2_CRE_FORWARDER:?required; the CRE forwarder Stage 1 wired into the CREReceiver}"
    : "${L2_CUSTOM_SENDER:?required; the CSR CustomSender (SepoliaCSRDeploy output)}"
    : "${L2_PROXY_ADMIN:?required; the CustomSender ProxyAdmin (SepoliaCSRDeploy output)}"
    : "${L2_PRICE_ORACLE:?required; the price oracle (SepoliaCSRDeploy output)}"

    for addr in "$L2_GOVERNANCE_EXECUTOR" "$L2_BOOTSTRAP_SYNC_AUTOMATION" "$L2_ORACLE_POOL" \
                "$L2_SYNC_TRIGGER" "$L2_CRE_RECEIVER" "$L2_CRE_FORWARDER" "$L2_CUSTOM_SENDER" \
                "$L2_PROXY_ADMIN" "$L2_PRICE_ORACLE"; do
      [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ && "$addr" != "0x0000000000000000000000000000000000000000" ]] \
        || { echo "Bad address: $addr (expected 0x + 40 hex chars, non-zero)" >&2; exit 1; }
    done

    forge script script/optimism/sepolia/SepoliaL2Upgrade.s.sol:SepoliaL2UpgradeScript \
        --sig "runMigrate()" \
        --rpc-url "$L2_OPTIMISM_SEPOLIA_RPC_URL" \
        --broadcast --non-interactive -vvv

# Run L1 upgrade on Sepolia (migrate receiver admin + proxy admin to LIDO_DAO_AGENT).
# Required env: INITIAL_OWNER_PRIVATE_KEY, LIDO_DAO_AGENT, L1_LIDO_CUSTOM_RECEIVER,
#               L1_PROXY_ADMIN, L1_SEPOLIA_RPC_URL.
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
