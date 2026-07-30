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

# Per-network L2 preflight check. Seven checks, in order:
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
#   6. Configured SyncTrigger maxGasLimit ceiling vs the lane's LIVE CCIP
#      maxPerMsgGasLimit. The hardcoded ceiling (constant ↔ inputs.yaml ↔ deployed
#      state are cross-checked by `verify-constants-sync`/state-mate, but all three
#      mirror EACH OTHER, never CCIP). This step is the only check against the live
#      lane cap: a ceiling ABOVE it would let an over-cap feeOtoD pass setFeeOtoD
#      then revert MessageGasLimitTooHigh inside every sync (audit-scope C-1). The
#      cap lives in a different contract AND a different struct word per CCIP version,
#      so this branches on typeAndVersion and reads a version-keyed word offset (do NOT
#      decode the whole struct — it reorders across versions). Read paths, each verified
#      against the live ramps (2026-06; getOnRamp uses the ETH-mainnet selector):
#        EVM2EVMOnRamp 1.5.0 (Optimism, Linea): getDynamicConfig() word 10
#        OnRamp 1.6.0 (Base, Arbitrum): getDynamicConfig() word 1 = feeQuoter, then
#          FeeQuoter.getDestChainConfig(sel) word 3 (FeeQuoter 2.0.0) / word 4 (1.6.0)
#      An unrecognized onRamp/FeeQuoter version WARN-skips instead of reading a wrong field.
#   7. Stage signing account(s) set up + funded. For whichever signer private key is present in
#      the env — L2_LIDO_DEPLOYER_PRIVATE_KEY (Stage 1 deploy) and/or INITIAL_OWNER_PRIVATE_KEY
#      (Stage 2 / L1 migration) — derive the address and confirm it is a funded EOA on this lane.
#      The deploy/migrate recipes only assert the key var is non-empty; nothing else checks the
#      account exists or can pay gas, so an unfunded signer otherwise only fails mid-broadcast.
#      Advisory only (WARN/PASS/INFO, never fatal): zero balance / below the recommended buffer
#      (L2_DEPLOYER_MIN_BALANCE_ETH, default 0.01) WARN; skipped when no signer key is in the env,
#      so preflight stays usable as a pure read-only lane gate (just L2_RPC_URL, no keys).
#
# The 12 h window matches L2_SYNC_DELAY (minSyncDelay) configured on each
# network's SyncAutomation / SyncTrigger; past 12 h since the last sync, the
# upkeep can't have fired again and any in-flight CCIP+bridge round-trip has
# had time to settle (real CCIP latency is normally minutes-to-low-hours).
#
# Required env (loaded from the .env.<network> overlay selected via NETWORK=<network>):
#   L2_NETWORK ∈ {optimism, arbitrum, base, linea}
#   L2_RPC_URL
#
# Usage: NETWORK=<network> just preflight-check  (loads .env + .env.<network>)
preflight-check:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    # L2 RPC comes from L2_RPC_URL, defined by the selected .env.<network> overlay.
    : "${L2_RPC_URL:?Set L2_RPC_URL in .env.$L2_NETWORK}"

    case "$L2_NETWORK" in
      optimism) EXPECTED_CHAIN_ID=10    ; SENDER=0x328de900860816d29D1367F6903a24D8ed40C997 ; POOL=0x6F357d53d6bE3238180316BA5F8f11467e164588 ; OLD_SYNC=0x3776CC14ce997827F7A87091018Daa1739dc2790 ; WETH=0x4200000000000000000000000000000000000006 ; WSTETH=0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb ;;
      arbitrum) EXPECTED_CHAIN_ID=42161 ; SENDER=0x72229141D4B016682d3618ECe47c046f30Da4AD1 ; POOL=0x9c27c304cFdf0D9177002ff186A4aE0A5489Aace ; OLD_SYNC=0x7EbD06BF137077fF5EE858ca6368dBd95DB7c66A ; WETH=0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 ; WSTETH=0x5979D7b546E38E414F7E9822514be443A4800529 ;;
      base)     EXPECTED_CHAIN_ID=8453  ; SENDER=0x328de900860816d29D1367F6903a24D8ed40C997 ; POOL=0x6F357d53d6bE3238180316BA5F8f11467e164588 ; OLD_SYNC=0x3776CC14ce997827F7A87091018Daa1739dc2790 ; WETH=0x4200000000000000000000000000000000000006 ; WSTETH=0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452 ;;
      linea)    EXPECTED_CHAIN_ID=59144 ; SENDER=0x328de900860816d29D1367F6903a24D8ed40C997 ; POOL=0x6F357d53d6bE3238180316BA5F8f11467e164588 ; OLD_SYNC=0x9c27c304cFdf0D9177002ff186A4aE0A5489Aace ; WETH=0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f ; WSTETH=0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F ; LINEA_GELATO=0xFbdDDF18Bc681Ae649991f1Aced55b2252a1acAe ;;
      *) echo "Unknown L2_NETWORK: $L2_NETWORK (expected: optimism|arbitrum|base|linea)" >&2; exit 2 ;;
    esac

    # ── Output coloring. Auto-disabled when stdout is not a TTY or NO_COLOR is set, so piped/CI logs
    # stay plain (no stray escape bytes). Status lines route through these helpers — keyword colored,
    # message text plain — the same helper-function idiom as `postflight-monitor`'s OK()/WARN()/INFO().
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
      C_RST=$'\033[0m'; C_HDR=$'\033[1;36m'; C_STEP=$'\033[1m'
      C_PASS=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_FAIL=$'\033[1;31m'; C_INFO=$'\033[36m'; C_DIM=$'\033[2m'
    else
      C_RST=''; C_HDR=''; C_STEP=''; C_PASS=''; C_WARN=''; C_FAIL=''; C_INFO=''; C_DIM=''
    fi
    # pass()/warn() tally into PASS_N/WARN_N for the end-of-run summary. (Use $((x+1)), never
    # ((x++)) — the latter returns non-zero when the pre-increment value is 0 and would trip set -e.)
    PASS_N=0; WARN_N=0
    hdr()  { printf '%s%s%s\n' "$C_HDR"  "$*" "$C_RST"; }              # banner / section title (bold cyan)
    step() { printf '%s%s%s\n' "$C_STEP" "$*" "$C_RST"; }             # "[n/7] CHECK ..." step header (bold)
    pass() { PASS_N=$((PASS_N+1)); printf '      %sPASS%s %s\n' "$C_PASS" "$C_RST" "$*"; }   # green keyword
    warn() { WARN_N=$((WARN_N+1)); printf '      %sWARN%s %s\n' "$C_WARN" "$C_RST" "$*"; }   # yellow keyword
    info() { printf '      %sINFO%s %s\n' "$C_INFO" "$C_RST" "$*"; }   # cyan keyword (not tallied — purely informational)
    cmd()  { printf '      %scmd:%s %s\n' "$C_DIM"  "$C_RST" "$*"; }   # dim — the example cast invocation
    cont() { printf '           %s\n' "$*"; }                          # continuation / detail (plain, 11-sp indent)
    # Hard-stop: red FAIL banner to stderr, then exit non-zero.
    die() { printf '%sPREFLIGHT FAIL:%s %s\n' "$C_FAIL" "$C_RST" "$*" >&2; exit 1; }

    # Strip cast's "[1.234e9]" scientific-notation suffix and any whitespace.
    parse_cast_num() { local s="$1"; s="${s%%[*}"; s="${s%% *}"; printf '%s' "$s"; }

    has_code() {
      local code
      code=$(cast code "$1" --rpc-url "$L2_RPC_URL" 2>/dev/null || echo "0x")
      [[ "$code" != "0x" && -n "$code" ]]
    }

    hdr "===================================================================="
    hdr "L2 PREFLIGHT CHECK: $L2_NETWORK"
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
    hdr "===================================================================="

    step "[1/7] CHECK chain-id of RPC matches expected ($EXPECTED_CHAIN_ID)"
    cmd "cast chain-id --rpc-url <rpc>"
    actual_chain_id=$(cast chain-id --rpc-url "$L2_RPC_URL")
    if [[ "$actual_chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
      die "chain-id mismatch: got $actual_chain_id, expected $EXPECTED_CHAIN_ID for $L2_NETWORK"
    fi
    # L2_RPC_URL may point at a local anvil fork (the fork-test env); a fork preserves the
    # upstream chain id, so the check above cannot tell fork from live. A stale head block means
    # a fork or badly lagging node — refuse to gate the migration on it.
    head_ts=$(parse_cast_num "$(cast block latest --field timestamp --rpc-url "$L2_RPC_URL")")
    head_age=$(( $(date +%s) - head_ts ))
    if (( head_age > 600 )); then
      die "RPC head block is ${head_age}s old — looks like a stale fork or lagging node, not live $L2_NETWORK (check \$L2_RPC_URL)"
    fi
    pass "chain-id = $actual_chain_id (head block ${head_age}s old)"

    step "[2/7] CHECK CustomSender contract has bytecode at $SENDER"
    cmd "cast code $SENDER --rpc-url <rpc>"
    if ! has_code "$SENDER"; then
      die "CustomSender $SENDER has no code on this RPC"
    fi
    pass "bytecode present at CustomSender"

    step "[3/7] CHECK legacy SyncAutomation last execution age at $OLD_SYNC"
    if ! has_code "$OLD_SYNC"; then
      warn "no contract bytecode at $OLD_SYNC (legacy automation may already be revoked/replaced)"
    else
      cmd "cast call $OLD_SYNC 'getLastExecution()(uint48)' --rpc-url <rpc>"
      if ! last_exec_hex=$(cast call "$OLD_SYNC" "getLastExecution()(uint48)" --rpc-url "$L2_RPC_URL" 2>/dev/null); then
        warn "$OLD_SYNC has bytecode but does not respond to getLastExecution() (different contract?)"
      else
        last_exec=$(parse_cast_num "$last_exec_hex")
        now=$(date +%s)
        age=$(( now - last_exec ))
        info "last legacy sync = $last_exec ($((age/3600))h $((age%3600/60))m ago)"
        if (( age < 12*3600 )); then
          warn "last sync was <12h ago; CCIP round-trip may still be in flight (safe to proceed; see README §Migration ordering)."
        else
          pass "no auto-upkeep on this contract in >12h (legacy Chainlink path only — step 5 covers all paths)."
        fi
      fi
    fi
    if [[ "$L2_NETWORK" == "linea" ]]; then
      info "Linea also has a separate Gelato automation at $LINEA_GELATO; check Gelato dashboard"
      cont "(https://app.gelato.network/) for pending Linea upkeeps before running Stage 2."
    fi

    step "[4/7] CHECK old oracle pool token balances (WETH + wstETH)"
    if ! has_code "$POOL"; then
      warn "no contract bytecode at $POOL (old oracle pool unreachable on this RPC)"
    else
      report_balance() {
        local label="$1" token="$2"
        cmd "cast call $token 'balanceOf(address)(uint256)' $POOL --rpc-url <rpc>  # $label"
        if raw=$(cast call "$token" "balanceOf(address)(uint256)" "$POOL" --rpc-url "$L2_RPC_URL" 2>/dev/null); then
          local wei ether
          wei=$(parse_cast_num "$raw")
          ether=$(cast from-wei "$wei" 2>/dev/null || echo "?")
          info "old pool $label balance = $wei wei (~ $ether $label)"
        else
          warn "could not read $label balance for $POOL (token=$token may be wrong on this RPC)"
        fi
      }
      report_balance WETH   "$WETH"
      report_balance wstETH "$WSTETH"
    fi

    step "[5/7] CHECK CustomSender 'Sync' events in last ~12h (catches every sync path)"
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
      cmd "cast logs --json --from-block $from_block --to-block latest --address $SENDER '$SYNC_TOPIC' --rpc-url <rpc>"
      if logs_json=$(cast logs --json --from-block "$from_block" --to-block latest \
                      --address "$SENDER" "$SYNC_TOPIC" \
                      --rpc-url "$L2_RPC_URL" 2>&1); then
        count=$(printf '%s' "$logs_json" | jq 'length' 2>/dev/null || echo 0)
        if [[ "${count:-0}" -eq 0 ]]; then
          pass "0 Sync events on $SENDER in last ~12h ($twelve_h_blocks blocks scanned; 1000-block probe spanned ${ts_per_1000}s)"
        else
          warn "$count Sync event(s) on $SENDER in last ~12h — a CCIP message may still be in flight."
          last_block_hex=$(printf '%s' "$logs_json" | jq -r '.[-1].blockNumber' 2>/dev/null)
          if [[ -n "$last_block_hex" && "$last_block_hex" != "null" ]]; then
            last_block_dec=$(cast --to-dec "$last_block_hex" 2>/dev/null || echo "$last_block_hex")
            cont "most recent at block $last_block_dec; check https://ccip.chain.link/ for pending."
          fi
          cont "Proceeding is SAFE: in-flight wstETH lands in the old pool by design (see README §Migration ordering)."
        fi
      else
        warn "could not scan Sync events (RPC error or range too wide):"
        cont "$(printf '%s\n' "$logs_json" | head -n1)"
        cont "Inspect manually on the L2 block explorer:"
        cont "filter address=$SENDER topic0=$SYNC_TOPIC over the last ~$twelve_h_blocks blocks."
      fi
    else
      warn "could not derive 12h-ago block estimate (timestamp probe failed); skipping Sync event scan."
    fi

    step "[6/7] CHECK configured maxGasLimit ceiling vs live CCIP maxPerMsgGasLimit"
    # The CCIP config structs drift across versions (field order changes), so do NOT decode
    # the whole evolving tuple — extract just the one word we want by its version-keyed offset.
    # DestChainConfig / DynamicConfig are fully static structs: each field is one 32-byte word,
    # in declaration order. Print the Nth (1-based) word of raw ABI return data as decimal.
    abi_word_dec() { local raw="${1#0x}" n="$2" w; w="${raw:$(((n-1)*64)):64}"; [[ ${#w} -eq 64 ]] && cast --to-dec "0x$w"; }
    # Source the lane-specific cap and shared destination selector from their state-mate inputs.
    sm_inputs="config/state/${L2_NETWORK}.inputs.yaml"
    EXPECTED=$(awk '$2=="&maxGasLimit"{print $3; exit}' "$sm_inputs" 2>/dev/null)
    # Every L2->L1 OtoD message targets Ethereum mainnet, so getOnRamp takes the mainnet CCIP
    # selector (same for all four lanes); fall back to the literal if the anchor read fails.
    DEST_SEL=$(just _l2-input-anchor "$L2_NETWORK" ethMainnetCcipChainSelector 2>/dev/null || true)
    : "${DEST_SEL:=5009297550715157269}"
    if [[ -z "${EXPECTED:-}" || ! "$EXPECTED" =~ ^[0-9]+$ ]]; then
      warn "could not read &maxGasLimit from $sm_inputs; skipping live-cap check"
    else
      ROUTER=$(cast call "$SENDER" 'CCIP_ROUTER()(address)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
      ONRAMP=$(cast call "$ROUTER" 'getOnRamp(uint64)(address)' "$DEST_SEL" --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
      if [[ -z "$ROUTER" ]]; then
        warn "CustomSender.CCIP_ROUTER() did not respond; skipping live-cap check"
      elif [[ -z "$ONRAMP" || "$ONRAMP" == "0x0000000000000000000000000000000000000000" ]]; then
        warn "Router.getOnRamp($DEST_SEL) = ${ONRAMP:-<none>} — lane not provisioned on this RPC; skipping cap check"
      else
        # The cap lives in a different contract — and at a different word offset — per CCIP
        # version, so branch on typeAndVersion. Each known (version -> offset) pair is verified
        # against the live ramps in the recipe's doc above. `version_known` distinguishes a
        # recognized-but-undecodable ramp (RPC hiccup) from an unknown version (already warned).
        TV=$(cast call "$ONRAMP" 'typeAndVersion()(string)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
        TV="${TV%\"}"; TV="${TV#\"}"   # strip cast's surrounding quotes, if any
        LIVE_CAP=""; version_known=
        case "$TV" in
          "EVM2EVMOnRamp 1.5.0")
            # v1.5 (Optimism, Linea): maxPerMsgGasLimit is word 10 of the OnRamp DynamicConfig.
            version_known=1
            raw=$(cast call "$ONRAMP" 'getDynamicConfig()' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
            LIVE_CAP=$(abi_word_dec "$raw" 10)
            ;;
          OnRamp*)
            # v1.6 (Base, Arbitrum): the cap moved to the FeeQuoter. OnRamp.getDynamicConfig()'s
            # first field is the feeQuoter address (right-aligned word 1); the cap is then a
            # version-keyed word of FeeQuoter.getDestChainConfig (2.0.0 reordered it vs 1.6.0).
            dyn=$(cast call "$ONRAMP" 'getDynamicConfig()' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
            dyn=${dyn#0x}
            FQ="0x${dyn:24:40}"
            FQV=$(cast call "$FQ" 'typeAndVersion()(string)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
            FQV="${FQV%\"}"; FQV="${FQV#\"}"
            raw=$(cast call "$FQ" 'getDestChainConfig(uint64)' "$DEST_SEL" --rpc-url "$L2_RPC_URL" 2>/dev/null || true)
            case "$FQV" in
              "FeeQuoter 2.0.0")  version_known=1; LIVE_CAP=$(abi_word_dec "$raw" 3) ;;  # isEnabled, maxDataBytes, maxPerMsgGasLimit, ...
              "FeeQuoter 1.6.0"*) version_known=1; LIVE_CAP=$(abi_word_dec "$raw" 4) ;;  # isEnabled, maxNumTokens, maxDataBytes, maxPerMsgGasLimit
              *) warn "unrecognized FeeQuoter version '$FQV' at $FQ; cap field offset unknown — skipping (CCIP layout may have changed)" ;;
            esac
            ;;
          *)
            warn "unrecognized onRamp typeAndVersion '$TV' at $ONRAMP; cap check skipped (CCIP layout may have changed — re-verify the read path)"
            ;;
        esac
        if [[ -n "$LIVE_CAP" && "$LIVE_CAP" =~ ^[0-9]+$ ]]; then
          info "onRamp $ONRAMP ($TV); live maxPerMsgGasLimit = $LIVE_CAP, configured ceiling = $EXPECTED"
          if (( EXPECTED > LIVE_CAP )); then
            die "configured maxGasLimit ceiling $EXPECTED exceeds live CCIP cap $LIVE_CAP on $L2_NETWORK ($TV) — an over-cap feeOtoD would pass setFeeOtoD then revert MessageGasLimitTooHigh inside every sync"
          elif (( EXPECTED == LIVE_CAP )); then
            pass "ceiling == live CCIP cap = $LIVE_CAP"
          else
            warn "ceiling $EXPECTED is below live CCIP cap $LIVE_CAP (tighter than CCIP; OK, but widen if the headroom isn't intentional)"
          fi
        elif [[ -n "$version_known" ]]; then
          warn "could not decode live maxPerMsgGasLimit from $ONRAMP ($TV); skipping cap comparison"
        fi
      fi
    fi

    step "[7/7] CHECK Stage signing account(s) set up and funded for gas on $L2_NETWORK"
    # Preflight doubles as a read-only lane gate (run with only L2_RPC_URL, no keys), so this step
    # vets whichever signer key is actually present in the env — the Stage-1 deployer and the
    # Stage-2 / L1-migration Initial Owner are different cold keys. With `NETWORK=<network> just
    # preflight-check` the .env.<network> file's keys are loaded, so the signer for the stage you're
    # about to run gets checked here, before forge spends gas. Advisory only (never `die`): funding/stage
    # context is ambiguous from preflight's vantage (e.g. a deployer that already ran Stage 1 may
    # legitimately be near-empty when you're now running Stage 2), so a low/zero balance WARNs
    # loudly rather than aborting — forge itself still hard-fails an underfunded broadcast.
    MIN_ETH="${L2_DEPLOYER_MIN_BALANCE_ETH:-0.01}"
    MIN_WEI=$(cast to-wei "$MIN_ETH" ether 2>/dev/null || echo "")
    if ! [[ "$MIN_WEI" =~ ^[0-9]+$ ]]; then
      warn "L2_DEPLOYER_MIN_BALANCE_ETH='$MIN_ETH' is not a valid amount; falling back to 0.01 ETH buffer"
      MIN_ETH=0.01; MIN_WEI=10000000000000000
    fi
    # awk-double compare — same heuristic-at-wei-scale idiom as postflight-monitor's ge(); a few-wei
    # imprecision only nudges the WARN boundary (zero is matched exactly by the string test below).
    ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }
    SIGNERS_CHECKED=
    check_signer() {
      # $1 label   $2 private-key (may be empty)   $3 address override (may be empty)
      local label="$1" key="$2" addr="${3:-}"
      if [[ -n "$key" ]]; then
        if ! addr=$(cast wallet address --private-key "$key" 2>/dev/null); then
          warn "$label: key is set but invalid (cast wallet address failed); skipping"
          SIGNERS_CHECKED=1
          return 0
        fi
      fi
      [[ -n "$addr" ]] || return 0   # neither key nor address given for this role → not this stage
      SIGNERS_CHECKED=1
      if ! [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        warn "$label: resolved address '$addr' is malformed; skipping"
        return 0
      fi
      if has_code "$addr"; then
        warn "$label $addr has contract bytecode — expected an EOA signer (wrong key/address?)"
      fi
      local bal eth
      bal=$(parse_cast_num "$(cast balance "$addr" --rpc-url "$L2_RPC_URL" 2>/dev/null || echo "")")
      if ! [[ "$bal" =~ ^[0-9]+$ ]]; then
        warn "$label $addr: balance unreadable (RPC error); skipping funding check"
        return 0
      fi
      eth=$(cast from-wei "$bal" 2>/dev/null || echo "?")
      if [[ "$bal" == "0" ]]; then
        warn "$label $addr has 0 ETH — it CANNOT pay gas; fund it before broadcasting this stage"
      elif ge "$bal" "$MIN_WEI"; then
        pass "$label $addr funded = $eth ETH (>= $MIN_ETH ETH buffer)"
      else
        warn "$label $addr balance = $eth ETH is below the $MIN_ETH ETH buffer — top up before broadcasting this stage"
      fi
    }
    check_signer "Stage-1 deployer (L2_LIDO_DEPLOYER_PRIVATE_KEY)" \
      "${L2_LIDO_DEPLOYER_PRIVATE_KEY:-}" "${L2_LIDO_DEPLOYER_ADDRESS:-}"
    check_signer "Stage-2/L1 Initial Owner (INITIAL_OWNER_PRIVATE_KEY)" \
      "${INITIAL_OWNER_PRIVATE_KEY:-${L2_INITIAL_OWNER_PRIVATE_KEY:-}}" "${INITIAL_OWNER_ADDRESS:-}"
    if [[ -z "$SIGNERS_CHECKED" ]]; then
      warn "no signer key in env (L2_LIDO_DEPLOYER_PRIVATE_KEY / INITIAL_OWNER_PRIVATE_KEY); deployer funding NOT checked."
      cont "OK if you only meant this as a read-only lane gate; otherwise set the relevant key (or run with"
      cont "-E .env.$L2_NETWORK) so the signer is vetted for gas before you broadcast a deploy/migrate."
    fi

    hdr "===================================================================="
    # No hard FAILs reached here (die exits early), so this is always a PASS verdict; the WARN tally
    # tells the operator how many advisory items to eyeball. WARNs do NOT fail the gate — several are
    # explicitly "safe to proceed" (in-flight sync, already-revoked legacy automation, unfunded
    # read-only run), so a non-zero exit here would block benign cases. `die` remains the only abort.
    if (( WARN_N > 0 )); then
      printf '%sOK%s L2 preflight passed for %s — %s%d PASS%s, %s%d WARN%s (review the warnings above before proceeding).\n' \
        "$C_PASS" "$C_RST" "$L2_NETWORK" "$C_PASS" "$PASS_N" "$C_RST" "$C_WARN" "$WARN_N" "$C_RST"
    else
      printf '%sOK%s L2 preflight passed for %s — %s%d PASS, 0 WARN%s. Proceed with migration scripts.\n' \
        "$C_PASS" "$C_RST" "$L2_NETWORK" "$C_PASS" "$PASS_N" "$C_RST"
    fi
    hdr "===================================================================="

# Per-network L1 preflight check. Verifies the L1 RPC is Ethereum mainnet, the
# shared L1 LidoCustomReceiver is reachable, and that its CCIP lane wiring for
# the given L2 network (adapter + sender) matches the expected L2 CustomSender.
#
# Required env: L2_NETWORK ∈ {optimism, arbitrum, base, linea} + an Ethereum-mainnet RPC, resolved by
#   script/shared/cre-env.sh in this order: L1_RPC_URL (.env.<network>) → RPC_ETHEREUM_REMOTE (shell)
#   → RPC_ETHEREUM (local fork proxy, last — this is a LIVE check and a fork must not win silently).
#
# Usage: just -E .env.<network> preflight-check-l1
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
    # means a fork or badly lagging node — refuse to gate the migration on it.
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

# Verify that addresses/selectors duplicated outside the canonical Solidity
# *MigrationConstants.sol files stay in sync with Solidity. Solidity is the
# single source of truth; this recipe only reports drift.
#
# Compared targets per network:
#   - config/state/l2.common.inputs.yaml + {net}.inputs.yaml + {net}.deployed.yaml
#     inputs/outputs of the shared wiring config/state/l2.yaml (state-mate validators)
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
    skip_count=0

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

    # Same as expect_eq, but for anchors that live ONLY in a <stem>.deployed.yaml sibling. Those siblings
    # are deploy-time artifacts (no longer committed — see "fix: update state-mate config"): the per-lane
    # <net>.deployed.yaml is written by `just deploy-test`; deferred siblings may be produced at
    # verification time. On a pre-deploy / audit checkout the file is legitimately absent, so SKIP rather
    # than report false drift. When the file IS present the check runs exactly like expect_eq — a genuine
    # rename/missing-anchor still FAILs.
    expect_eq_deferred() { # $1 what  $2 expected  $3 actual  $4 deployed_file
      local what="$1" expected="$2" actual="$3" deployed_file="$4"
      if [[ ! -f "$deployed_file" ]]; then
        echo "      SKIP $what: $deployed_file absent (deployed-state sibling produced at deploy/verify time)"
        skip_count=$(( skip_count + 1 ))
        return
      fi
      expect_eq "$what" "$expected" "$actual"
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
      # Every anchor checked here is DEFINED in the .deployed/.inputs files (the
      # feat/separate-deployed split). The shared wiring l2.yaml only *references* them and cannot be
      # parsed standalone (dangling aliases → yq error), so scan the siblings when present; fall back
      # to the file itself only when it is self-contained (no siblings). `..` recurses every section.
      local base="${1%.yaml}" files=()
      case "$base" in
        config/state/optimism|config/state/arbitrum|config/state/base|config/state/linea)
          files+=("config/state/l2.common.inputs.yaml")
          ;;
      esac
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
    echo "  Source of truth: script/l1/L1MigrationConstants.sol"
    echo "                   script/{net}/{Net}MigrationConstants.sol"
    echo "  Compared targets:"
    echo "    - config/state/l2.yaml shared wiring (+ l2.common.inputs.yaml / {net}.{inputs,deployed}.yaml)"
    echo "    - config/state/{net}.inputs.yaml fee blobs vs FeeCodec(constants)"
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
      sm="config/state/${net}.yaml"
      # The l2CustomSender/Impl/ProxyAdmin anchors are pre-existing externals pinned in <stem>.inputs.yaml.

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
      cre_workflow_name=$(yq ".[\"production-${net}\"].user-workflow.workflow-name" cre-workflows/sync-automation/workflow.yaml)

      echo
      echo "[$net] state-mate inputs: l2.common.inputs.yaml + ${sm%.yaml}.inputs.yaml; deployed: ${sm%.yaml}.deployed.yaml"
      expect_eq "l2ChainId → ${upper}_CHAIN_ID"                                  "$sol_chain_id"      "$(yml_anchor "$sm" l2ChainId)"
      expect_eq "l2CustomSender → L2_CUSTOM_SENDER"                             "$sol_l2_sender"     "$(yml_anchor "$sm" l2CustomSender)"
      expect_eq "l2CustomSenderImpl → L2_CUSTOM_SENDER_IMPL"                    "$sol_l2_sender_impl" "$(yml_anchor "$sm" l2CustomSenderImpl)"
      expect_eq "l2ProxyAdmin → L2_PROXY_ADMIN"                                 "$sol_l2_proxy"      "$(yml_anchor "$sm" l2ProxyAdmin)"
      expect_eq "RETIRED_l2OraclePool → L2_OLD_ORACLE_POOL"                     "$sol_l2_pool"       "$(yml_anchor "$sm" RETIRED_l2OraclePool)"
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
      expect_eq "l2LidoDeployer → LIDO_DEPLOYER (L1 shared)"                     "$sol_deployer"      "$(yml_anchor "$sm" l2LidoDeployer)"
      expect_eq "ethMainnetCcipChainSelector → ETH_CCIP_CHAIN_SELECTOR (L1 shared)" "$sol_eth_selector" "$(yml_anchor "$sm" ethMainnetCcipChainSelector)"
      expect_eq "l1LidoCustomReceiverBytes32 → L1_LIDO_CUSTOM_RECEIVER (L1 shared)" "$sol_l1_recv"   "$(bytes32_to_addr "$(yml_anchor "$sm" l1LidoCustomReceiverBytes32)")"
      expect_eq "creWorkflowName → workflow.yaml production-${net}"               "$cre_workflow_name" "$(yml_anchor "$sm" creWorkflowName)"
      expect_eq "creWorkflowTag → registered workflow tag"                        "$cre_workflow_name" "$(yml_anchor "$sm" creWorkflowTag)"
      expect_eq "creDonFamily → CRE_CLI_DON_FAMILY default"                       "$cre_don_family"    "$(yml_anchor "$sm" creDonFamily)"
      if [[ "$net" == "linea" ]]; then
        sol_gelato=$(sol_addr "$sol" L2_OLD_GELATO_AUTOMATION)
        expect_eq "RETIRED_l2GelatoSyncAutomation → L2_OLD_GELATO_AUTOMATION"    "$sol_gelato" "$(yml_anchor "config/state/l2-linea-gelato.yaml" RETIRED_l2GelatoSyncAutomation)"
        expect_eq "l2CustomSender (Linea Gelato config) → L2_CUSTOM_SENDER"      "$sol_l2_sender" "$(yml_anchor "config/state/l2-linea-gelato.yaml" l2CustomSender)"
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
        expect_eq "maxNativeFee → SyncTrigger.getMaxFees()" \
          "$(fee_val MAX_NATIVE_FEE)" "$(yml_anchor "$sm" maxNativeFee)"
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
    # Receiver / impl / ProxyAdmin are PRE-EXISTING upstream contracts the L1 Stage-2 step only
    # re-owns (it deploys nothing on L1), so they are fixed externals in ethereum.inputs.yaml — checked
    # unconditionally (the receiver + ProxyAdmin are additionally cross-checked via the justfile
    # hardcodes below).
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
    echo "[CRE workflow config ↔ its measured-gas carrier]"
    # `writeGasLimit` is the gas the DON budgets for the delivered write. Its adequacy is proven by the
    # measured carrier `test_creWriteGasCarrier` (test/helpers/PoolUpgradeTests.sol), which asserts against
    # the CRE_WRITE_GAS_LIMIT constant — so a JSON bump that skipped the test would silently invalidate the
    # evidence. Pin every lane's JSON to that constant (Solidity-side is canonical, as everywhere here).
    sol_write_gas="$(sol_uint "test/helpers/PoolUpgradeTests.sol" CRE_WRITE_GAS_LIMIT)"
    for cfg in cre-workflows/sync-automation/config.deploy.*.json cre-workflows/sync-automation/config.simulate.json; do
      [[ -f "$cfg" ]] || continue
      expect_eq "$(basename "$cfg") writeGasLimit → CRE_WRITE_GAS_LIMIT" \
        "$sol_write_gas" "$(jq -r '.writeGasLimit' "$cfg")"
    done

    echo
    echo "===================================================================="
    if (( fail_count == 0 )); then
      echo "OK $pass_count duplicates in sync with Solidity."
      (( skip_count > 0 )) && echo "   ($skip_count deferred — their .deployed.yaml sibling is absent; it is produced at deploy/verify time, e.g. 'just deploy-test')"
    else
      echo "FAIL $fail_count drift(s) detected ($pass_count OK)."
      echo "     Fix the duplicate to match Solidity (canonical),"
      echo "     or update Solidity if it is the one that's wrong."
      exit 1
    fi
    echo "===================================================================="

# Verify each hand-maintained ABI mirror under config/state/abi/ that has a LOCAL src/ source stays
# faithful to `forge inspect` — the guard that would have caught the dropped
# `SyncTriggerPayInLinkNotSupported` error. state-mate consumes these JSONs as the call-ABI but only
# invokes the getters it is told to, and `verify-constants-sync` checks addresses/uints/anchors only —
# neither diffs the ABI member set, so an added/removed/renamed error, event, or function signature can
# drift silently. Two conventions live in config/state/abi/, so each mirror declares its mode:
#   exact  — the mirror is the FULL contract ABI (every function, event AND error) and must equal
#            `forge inspect` member-for-member (e.g. SyncTrigger.json; this is what catches a dropped error).
#   subset — the mirror is a CURATED read-ABI (only the view getters state-mate invokes, e.g.
#            CREReceiver.json); every member it lists must still match the source signature exactly, but
#            members absent from the mirror are allowed.
# Comparison is on canonical (key-sorted, compact) members, so forge's order vs the file's never matters.
# External/vendored mirrors (adapters, executors, upstream chainlink-csr types, legacy SyncAutomation) are
# out of scope. Pure local compute — no RPC.
#
# Usage: just verify-abi-sync
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

# Lint: every L2 state-mate `externals:` / `deployed:` ANCHOR (the contamination-prone address
# surface) must be pinned to a source-of-truth — either cross-checked in `verify-constants-sync`
# (vs *MigrationConstants.sol), or on the explicit no-constant allowlist below WITH a reason.
# Rationale: `verify-constants-sync` proves config == Solidity constant (catches drift between two
# same-team copies) but cannot catch shared contamination; the independent oracle is state-mate-vs
# -chain. A value that is in NEITHER is verified only by same-provenance equality → false-pass risk.
# This lint is exactly the guard that surfaced the dev-only `l2LidoDeployer` placeholder — now the
# real deployer, pinned to `L1MigrationConstants.LIDO_DEPLOYER` and off the allowlist below.
# (Scope: L2 lanes. L1 anchors are covered by the L1 section of `verify-constants-sync`.)
#
# Usage: just verify-externals-coverage
verify-externals-coverage:
    #!/usr/bin/env bash
    set -uo pipefail
    fail=0; ok=0
    # Anchors that legitimately have NO MigrationConstants.sol address constant (reason each):
    #   (l2LidoDeployer was here while it held a dev-fork placeholder — it is now the real deployer,
    #    constants-checked vs L1MigrationConstants.LIDO_DEPLOYER, so it needs no exemption)
    #   l2OraclePool / l2SyncTrigger / l2CreReceiver — Stage-1 deploy OUTPUTS (not deploy inputs)
    #   lidoDaoAgent    — L2 echo of the L1 DAO agent (the L1 copy IS constants-checked); pinned
    #                     on-chain via BridgeExecutor.getEthereumGovernanceExecutor
    #   ovmL2CrossDomainMessenger — OP-stack standard predeploy; pinned on-chain via BridgeExecutor
    #   lineaMessageService — Linea message-service predeploy; pinned on-chain via LineaBridgeExecutor
    #                         (Linea analogue of ovmL2CrossDomainMessenger; null on the other lanes)
    #   RETIRED_l2SyncTrigger / RETIRED_l2CreReceiver — the SUPERSEDED Stage-1 deploy outputs (same class
    #                     as l2SyncTrigger/l2CreReceiver above, one generation back). No constant pins
    #                     them because their identity is proven ON-CHAIN in shared l2.yaml, which
    #                     asserts the retired trigger's immutable SENDER / DEST_CHAIN_SELECTOR / WNATIVE
    #                     and its getForwarder → the retired receiver, so a mistyped anchor fails loudly
    #                     rather than making the de-role assertion pass vacuously.
    #   l2AutomationOwner — a migration-time CHOICE of key holder, not a fixed third-party fact, and it
    #                     was deliberately NOT promoted to a MigrationConstants constant (the address
    #                     lives in the root .env beside its signing key). Its cross-check is therefore at
    #                     runtime, not lint time: `just env-doctor` proves anchor == L2_AUTOMATION_OWNER
    #                     == the address the signing key derives to == on-chain
    #                     CREReceiver.getExpectedAuthor(), and `deploy-cre-workflow` re-proves the last
    #                     equality before it can register a workflow. Promote it to a constant (and drop
    #                     this entry) if the AO ever becomes a fixed, long-lived address.
    #   creWorkflowRegistry — Chainlink's shared Ethereum registry; independently checked on-chain
    #   creWorkflowId — content-derived workflow deployment output (zero is the fail-closed predeploy stub)
    allow=" l2OraclePool l2SyncTrigger l2CreReceiver RETIRED_l2SyncTrigger RETIRED_l2CreReceiver l2AutomationOwner creWorkflowRegistry creWorkflowId lidoDaoAgent ovmL2CrossDomainMessenger lineaMessageService "
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
    # Gelato's RETIRED_l2GelatoSyncAutomation / l2CustomSender live under misc: in
    # l2-linea-gelato.yaml (not externals:), so they are not swept here — they are pinned by the
    # explicit yml_anchor rows above.
    for net in l2.common optimism arbitrum base linea; do
      inputs="config/state/${net}.inputs.yaml"
      [[ -f "$inputs" ]] || inputs="config/state/${net}.yaml"
      deployed="config/state/${net}.deployed.yaml"
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

# Read-only combined state-mate verification for a lane. It checks both the Ethereum WorkflowRegistry
# record (identity, Automation Owner, ACTIVE) and all L2 contracts from the shared config/state/l2.yaml.
# The workflow ID is deployed state in config/state/<network>.deployed.yaml — never an env value.
# Callable by anyone (no private key needed).
#
# Usage: just -E .env.<network> verify-cre-workflow
#
# Required env: L2_NETWORK, L2_RPC_URL, plus an Ethereum-mainnet RPC resolved by cre-env.sh
#   (L1_RPC_URL → RPC_ETHEREUM_REMOTE → RPC_ETHEREUM).
verify-cre-workflow:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{justfile_directory()}}/script/shared/cre-env.sh"
    cre_env_load_secrets
    L1_RPC_URL="$(resolve_l1_rpc)"
    : "${L2_RPC_URL:?L2_RPC_URL is required; load .env.<network>}"
    : "${L2_NETWORK:?L2_NETWORK is required; load .env.<network>}"
    case "$L2_NETWORK" in optimism|arbitrum|base|linea) ;; *) echo "Unknown L2_NETWORK: $L2_NETWORK" >&2; exit 2 ;; esac
    ROOT_DIR="{{justfile_directory()}}"
    STATE_MATE_DIR="$ROOT_DIR/lib/state-mate"
    DEPLOYED="$ROOT_DIR/config/state/$L2_NETWORK.deployed.yaml"
    INPUTS="$ROOT_DIR/config/state/$L2_NETWORK.inputs.yaml"
    COMMON_INPUTS="$ROOT_DIR/config/state/l2.common.inputs.yaml"
    [[ -f "$DEPLOYED" ]] || { echo "Missing deployed state: $DEPLOYED" >&2; exit 1; }
    [[ -f "$INPUTS" ]] || { echo "Missing inputs state: $INPUTS" >&2; exit 1; }
    [[ -f "$COMMON_INPUTS" ]] || { echo "Missing common inputs state: $COMMON_INPUTS" >&2; exit 1; }
    command -v node >/dev/null 2>&1 || { echo "Missing required command: node" >&2; exit 1; }
    if command -v corepack >/dev/null 2>&1; then YARN=(corepack yarn); else YARN=(yarn); fi
    (
      cd "$STATE_MATE_DIR"
      L1_RPC_URL="$L1_RPC_URL" L2_STATE_MATE_RPC_URL="$L2_RPC_URL" \
        "${YARN[@]}" start "$ROOT_DIR/config/state/l2.yaml" \
        --inputs "$COMMON_INPUTS" --inputs "$INPUTS" --deployed "$DEPLOYED"
    )

# Persist the content-derived CRE workflow ID as state-mate deployed state.
# Replaces only deployed.l1 in config/state/<network>.deployed.yaml, preserving deployed.l2.
record-cre-workflow-id network workflow_id:
    #!/usr/bin/env bash
    set -euo pipefail
    NETWORK="{{network}}"
    WORKFLOW_ID="{{workflow_id}}"
    case "$NETWORK" in optimism|arbitrum|base|linea) ;; *) echo "Unknown network: $NETWORK" >&2; exit 2 ;; esac
    [[ "$WORKFLOW_ID" =~ ^0x[0-9a-fA-F]{64}$ ]] || {
      echo "Bad workflow ID: $WORKFLOW_ID (expected 0x + 64 hex chars)" >&2
      exit 1
    }
    [[ "$WORKFLOW_ID" != "0x$(printf '0%.0s' {1..64})" ]] || { echo "Refusing zero workflow ID" >&2; exit 1; }
    command -v yq >/dev/null 2>&1 || { echo "Missing required command: yq" >&2; exit 1; }
    OUT="{{justfile_directory()}}/config/state/$NETWORK.deployed.yaml"
    [[ -f "$OUT" ]] || { echo "Missing deployed state: $OUT" >&2; exit 1; }
    TMP="$(mktemp "${TMPDIR:-/tmp}/$NETWORK.deployed.XXXXXX.yaml")"
    trap 'rm -f "$TMP"' EXIT
    WF="$WORKFLOW_ID" yq \
      '(.deployed.l1) = [strenv(WF)] | .deployed.l1[0] anchor = "creWorkflowId"' \
      "$OUT" > "$TMP"
    mv "$TMP" "$OUT"
    trap - EXIT
    echo "Recorded $NETWORK CRE workflow ID in $OUT"

# Rewrite the CRE workflow config for the current network with the deployed SyncTrigger
# + CREReceiver addresses. Run after the canary deploy (`deploy-test`) before `deploy-cre-workflow`.
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
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it in .env.$L2_NETWORK from deploy-test output}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required; populate it in .env.$L2_NETWORK from deploy-test output}"

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

# ───────────────────────── Canary test flow (deployer-simulated CRE) ─────────────────────────
# State machine: Stage 0 (initial) → 1 (canary testing) → 2 (pre-ownership migration) →
#   3 (final.unvalidated) → 4 (final.validated), with a 1→0 rollback. The new contracts deploy
#   DEPLOYER-OWNED, with the Deployer standing in for the CRE Keystone forwarder + workflow author so it
#   can drive CREReceiver.onReport directly; after a clean test the Deployer restores the real CRE config
#   + production params and hands ownership to LOL, then the Initial Owner ("Aphyla") seals governance.
#   Each recipe is a single broadcast by one actor — do NOT co-locate keys.
#
#   The governance executor, predecessor OraclePool, and Lido DAO Agent are pinned per network in the
#   script/{net}/{Net}MigrationConstants.sol contracts (cross-checked to config/state/*.inputs.yaml by
#   `just verify-constants-sync`) and read directly by the forge scripts — they are NEVER set in .env.

# Stage 0→1 (Deployer): deploy pool + SyncTrigger + CREReceiver owned by the Lido Deployer, with the
# deployer as the CREReceiver forwarder AND author. Uses the TEST min-amount/delay overrides so a small
# WETH seed triggers a sync promptly; production values are restored at `handoff`.
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL, L2_LIDO_DEPLOYER_PRIVATE_KEY.
# Optional env: L2_SYNC_MIN_AMOUNT_TEST / L2_SYNC_DELAY_TEST (defaults: 0.0002 WETH / 60 seconds;
#   an explicit env value wins), L2_LIQUIDITY_OWNER.
#
# Usage: just -E .env.<network> deploy-test
deploy-test:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${L2_LIDO_DEPLOYER_PRIVATE_KEY:?required for runDeployTest(); export it before running}"
    for c in jq cast; do command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; exit 1; }; done
    : "${L2_SYNC_MIN_AMOUNT_TEST:=200000000000000}"
    : "${L2_SYNC_DELAY_TEST:=60}"
    export L2_SYNC_MIN_AMOUNT_TEST L2_SYNC_DELAY_TEST
    echo "Canary test min-amount: ${L2_SYNC_MIN_AMOUNT_TEST} wei; delay: ${L2_SYNC_DELAY_TEST} s (production values restored at handoff)"

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runDeployTest()' --rpc-url "$L2_RPC_URL" --broadcast

    chain_id=$(cast chain-id --rpc-url "$L2_RPC_URL" | tr -d '\r\n')
    bcast="broadcast/$(basename "${SCRIPT%:*}")/${chain_id}/runDeployTest-latest.json"
    if [[ -f "$bcast" ]]; then
      pool=$(jq -r '[.transactions[] | select(.contractName == "PausableImmutableOraclePool")][0].contractAddress' "$bcast")
      trigger=$(jq -r '[.transactions[] | select(.contractName == "SyncTrigger")][0].contractAddress' "$bcast")
      receiver=$(jq -r '[.transactions[] | select(.contractName == "CREReceiver")][0].contractAddress' "$bcast")
      echo
      echo "===================================================================="
      echo "Canary Stage 1 deployed for $L2_NETWORK — copy these into .env.$L2_NETWORK:"
      echo "  export L2_ORACLE_POOL=$(cast to-check-sum-address "$pool")"
      echo "  export L2_SYNC_TRIGGER=$(cast to-check-sum-address "$trigger")"
      echo "  export L2_CRE_RECEIVER=$(cast to-check-sum-address "$receiver")"
      echo "  export L2_TEST_DEPLOYER=$(cast wallet address --private-key "$L2_LIDO_DEPLOYER_PRIVATE_KEY")"
      echo "Next: just -E .env.$L2_NETWORK activate   (Initial Owner repoints the pool + grants SYNC_ROLE)"
      echo "===================================================================="

      # Generate the state-mate `.deployed.yaml` sibling so the 3→4 `state-mate` step has a current target
      # (the canary IS the production deploy path). This file holds ONLY the three Stage-1 outputs from the
      # broadcast JSON above — the pre-existing CustomSender proxy/impl + ProxyAdmin are externals in
      # l2-$L2_NETWORK.inputs.yaml, so this is always regenerable with no pre-existing seed.
      deployed_file="config/state/$L2_NETWORK.deployed.yaml"
      bash script/shared/write-deployed-yaml.sh "$deployed_file" "$pool" "$trigger" "$receiver"
      echo "  → wrote $deployed_file — review the diff and commit it alongside the migration."
    else
      echo "WARN broadcast JSON not found at $bcast; record addresses from the forge log above." >&2
    fi

# Automation-layer redeploy (Automation Owner): deploy a FRESH CREReceiver + SyncTrigger pair owned by a
# dedicated Automation Owner EOA. See docs/automation-owner-redeploy.md §S3.
#
# This stands OUTSIDE the canary state machine above and is deliberately narrow:
#   - the OraclePool is NOT redeployed and NOT touched — it stays live and LOL-owned;
#   - PRODUCTION config (12 h delay, 5/100 ETH amounts) by default, or CANARY config (0.0002 WETH min +
#     60 s delay) when `L2_DEPLOY_CANARY_PARAMS=true` — same knobs as deploy-test; real CRE forwarder +
#     Automation Owner ownership either way;
#   - the float is NOT funded (run `fund-trigger` after, or transfer directly — funding is permissionless);
#   - SYNC_ROLE is NOT granted to the new trigger and NOT revoked from the old one. Until that separate
#     Initial-Owner transaction runs, the pair deployed here is INERT and nothing about the live lane changes.
#
# The Automation Owner signs this itself, so it owns the CREReceiver from msg.sender with no in-broadcast
# ownership hop, and is also the SyncTrigger's initialOwner and the CREReceiver's expectedAuthor. The
# declared L2_AUTOMATION_OWNER and the signing key are cross-checked both here and inside the forge script:
# the SyncTrigger's owner is a constructor argument, so a typo'd owner is unrecoverable, not fixable.
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL, L2_ORACLE_POOL (the EXISTING pool, carried into
#   the regenerated .deployed.yaml), L2_AUTOMATION_OWNER, and L2_AUTOMATION_OWNER_PRIVATE_KEY (or
#   L2_AUTOMATION_OWNER_PK — either spelling is accepted, here and in the forge script).
# Optional env: L2_LIQUIDITY_OWNER; L2_DEPLOY_CANARY_PARAMS=true (defaults to 0.0002 WETH / 60 seconds,
#   overridable via L2_SYNC_MIN_AMOUNT_TEST / L2_SYNC_DELAY_TEST).
#
# Usage: just -E .env.<network> deploy-automation
#        L2_DEPLOY_CANARY_PARAMS=true just -E .env.<network> deploy-automation
deploy-automation:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${L2_ORACLE_POOL:?L2_ORACLE_POOL is required — the EXISTING pool address, carried unchanged into the regenerated .deployed.yaml}"
    : "${L2_AUTOMATION_OWNER:?L2_AUTOMATION_OWNER is required — the address that will own the new SyncTrigger + CREReceiver}"
    # Accept either spelling of the key variable, matching _envAutomationOwnerPrivateKey() in the script
    # (.env currently carries the _PK form). Neither has a default: this key signs a real deploy.
    ao_key="${L2_AUTOMATION_OWNER_PRIVATE_KEY:-${L2_AUTOMATION_OWNER_PK:-}}"
    : "${ao_key:?L2_AUTOMATION_OWNER_PRIVATE_KEY (or L2_AUTOMATION_OWNER_PK) is required; the Automation Owner signs its own deploy}"
    for c in jq cast; do command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; exit 1; }; done

    # Same cross-check the forge script enforces, run BEFORE any RPC round-trip so a typo costs nothing.
    key_addr=$(cast wallet address --private-key "$ao_key")
    declared=$(cast to-check-sum-address "$L2_AUTOMATION_OWNER")
    if [[ "$key_addr" != "$declared" ]]; then
      echo "L2_AUTOMATION_OWNER ($declared) is not the address of L2_AUTOMATION_OWNER_PRIVATE_KEY ($key_addr)." >&2
      echo "Refusing to deploy: the SyncTrigger owner is a constructor argument and cannot be corrected afterwards." >&2
      exit 1
    fi
    bal=$(cast balance "$declared" --rpc-url "$L2_RPC_URL")
    if [[ "$bal" == "0" ]]; then
      echo "Automation Owner $declared holds 0 wei on $L2_NETWORK — fund it for gas before deploying." >&2
      exit 1
    fi
    echo "Deploying the automation pair on $L2_NETWORK owned by $declared (gas balance: $(cast from-wei "$bal") ETH)"
    if [[ "${L2_DEPLOY_CANARY_PARAMS:-false}" == "true" ]]; then
      : "${L2_SYNC_MIN_AMOUNT_TEST:=200000000000000}"
      : "${L2_SYNC_DELAY_TEST:=60}"
      export L2_SYNC_MIN_AMOUNT_TEST L2_SYNC_DELAY_TEST L2_DEPLOY_CANARY_PARAMS=true
      echo "Canary config: min-amount ${L2_SYNC_MIN_AMOUNT_TEST} wei; delay ${L2_SYNC_DELAY_TEST} s"
    else
      export L2_DEPLOY_CANARY_PARAMS=false
      echo "Production config (12 h delay, 5 WETH min); pool untouched; float NOT funded; SYNC_ROLE NOT granted."
    fi

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runDeployAutomation()' --rpc-url "$L2_RPC_URL" --broadcast

    chain_id=$(cast chain-id --rpc-url "$L2_RPC_URL" | tr -d '\r\n')
    bcast="broadcast/$(basename "${SCRIPT%:*}")/${chain_id}/runDeployAutomation-latest.json"
    if [[ -f "$bcast" ]]; then
      trigger=$(jq -r '[.transactions[] | select(.contractName == "SyncTrigger")][0].contractAddress' "$bcast")
      receiver=$(jq -r '[.transactions[] | select(.contractName == "CREReceiver")][0].contractAddress' "$bcast")
      echo
      echo "===================================================================="
      echo "Automation pair redeployed for $L2_NETWORK — replace these in .env.$L2_NETWORK:"
      echo "  export L2_SYNC_TRIGGER=$(cast to-check-sum-address "$trigger")"
      echo "  export L2_CRE_RECEIVER=$(cast to-check-sum-address "$receiver")"
      echo "(keep L2_ORACLE_POOL=$(cast to-check-sum-address "$L2_ORACLE_POOL") — the pool was not redeployed)"
      echo
      echo "Record the address the PREVIOUS pair had before overwriting .env — the retired trigger is the"
      echo "target of the SYNC_ROLE revoke, and OZ revokeRole is a SILENT no-op on a wrong address."
      echo "===================================================================="

      # Regenerate the state-mate `.deployed.yaml` sibling: the EXISTING pool anchor is carried through
      # unchanged (it was not redeployed) and only the two automation anchors move. Sourcing the pool from
      # env rather than a broadcast is what makes this correct — this broadcast contains no pool deploy.
      deployed_file="config/state/$L2_NETWORK.deployed.yaml"
      DEPLOYED_YAML_GENERATOR="just deploy-automation" \
        bash script/shared/write-deployed-yaml.sh "$deployed_file" "$L2_ORACLE_POOL" "$trigger" "$receiver"
      echo "  → wrote $deployed_file — review the diff and commit it alongside the redeploy."
      echo
      echo "WARN state-mate will now report OWNER MISMATCHES on this lane: config/state/l2.yaml still binds" >&2
      echo "     syncTrigger.owner / creReceiver.owner / creReceiver.getExpectedAuthor to *l2LiquidityOwner," >&2
      echo "     which the redeployed pair deliberately no longer satisfies. Splitting that anchor into a" >&2
      echo "     separate *l2AutomationOwner is a follow-up change (docs/automation-owner-redeploy.md §S1.7)." >&2
    else
      echo "WARN broadcast JSON not found at $bcast; record addresses from the forge log above." >&2
    fi
    echo
    echo "Next: fund the float (fund-trigger or a bare transfer), publish sources (verify-sources), then"
    echo "grant SYNC_ROLE to the new trigger + revoke it from the old one (Initial Owner; §S6). Confirm with"
    echo "'just audit-ownership' — it reads the .deployed.yaml just regenerated."

# ──────────────────────────────────────────────────────────────────
# SYNC_ROLE rotation (CustomSender role admin)
# ──────────────────────────────────────────────────────────────────

# Rotate SYNC_ROLE on the lane's CustomSender: grant it to SyncTrigger v2 and revoke it from v1. This is
# the automation cutover — the step that makes a redeployed SyncTrigger live and the predecessor inert
# (docs/automation-owner-redeploy.md §S6). Run it once PER LANE, on all four.
#
# Addresses are read from committed state-mate YAML (no CLI args):
#   v2 (grant target)  ← config/state/<net>.deployed.yaml          (&l2SyncTrigger)
#   v1 (revoke target) ← config/state/<net>.deployed.yaml (&RETIRED_l2SyncTrigger)
#
# Actor: the CustomSender's role admin — DEFAULT_ADMIN_ROLE, since SYNC_ROLE has no dedicated manager
# (getRoleAdmin(SYNC_ROLE) == 0x00, asserted). Note CustomSender has NO owner(): "the owner of the
# CustomSender" is this role. It is the Initial Owner until `finalize` seals it to the L2 governance
# executor; after that seal this recipe can no longer be signed at all and the rotation needs a DAO vote —
# use `repoint-sync-role-calldata` to produce the two calls for that route.
#
# Scope is deliberately narrow: it touches SYNC_ROLE and nothing else. The oracle-pool pointer, every
# contract's owner(), and the PREDECESSOR automations' roles are all left exactly as they are (revoking the
# predecessors is `finalize`'s job) — the script asserts that afterwards.
#
# NOT atomic: forge broadcasts one transaction per call, grant first, then revoke. That order is chosen so a
# second transaction that fails to land leaves BOTH triggers armed (redundant, and throttled by the shared
# per-sender sync delay) rather than NEITHER (an automation outage). If the zero-length two-holder window
# matters, batch the calldata from `repoint-sync-role-calldata` through a multisend instead.
#
# Guards, all evaluated before the first transaction (here in bash, then again on-chain in the script):
#   - the retired holder MUST currently hold SYNC_ROLE — OZ revokeRole is a SILENT no-op otherwise, so a
#     mistyped address would report success while leaving the old holder armed;
#   - v2 != v1 — if deploy-automation has not yet regenerated the .deployed.yaml sibling, both anchors can
#     still point at the same address, which would grant then revoke one account and de-automate the lane;
#   - the signing key MUST hold DEFAULT_ADMIN_ROLE;
#   - v2 MUST be a SyncTrigger whose immutable SENDER + DEST_CHAIN_SELECTOR match this lane (waive with
#     L2_REPOINT_ALLOW_ANY_TARGET=true to arm something that is deliberately not one, e.g. an EOA for a
#     manual sync() — the identity guard is then gone).
#
# Signing follows the same key-or-impersonate rule as `_acceptance-test`: with INITIAL_OWNER_PRIVATE_KEY (or
# L2_INITIAL_OWNER_PRIVATE_KEY) set it signs for real; without one it runs runRepointSyncRoleUnlocked() and
# impersonates the role admin, which works ONLY against an anvil fork — that is the dress rehearsal.
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL.
# Optional env: INITIAL_OWNER_PRIVATE_KEY / L2_INITIAL_OWNER_PRIVATE_KEY (real broadcast; without it, anvil
#   impersonation), L2_SENDER_ADMIN (the role admin address, when it is no longer the Initial Owner — also
#   honoured as INITIAL_OWNER / L2_INITIAL_OWNER; defaults to the lane's pinned initialOwner anchor),
#   L2_REPOINT_ALLOW_ANY_TARGET.
#
# Usage: just -E .env.<network> repoint-sync-role
repoint-sync-role:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    for c in cast forge yq; do command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; exit 1; }; done

    next="$(just _repoint-next-sync-trigger)"
    retired="$(just _repoint-retired-sync-trigger)"
    if [[ "$next" == "$retired" ]]; then
      echo "SyncTrigger v2 and v1 resolve to the SAME address ($next)." >&2
      echo "config/state/$L2_NETWORK.deployed.yaml may not yet carry the v2 pair — run deploy-automation first." >&2
      exit 1
    fi

    # Actor resolution, mirroring `_acceptance-test`: real key when present, else impersonate on anvil.
    owner_key="${INITIAL_OWNER_PRIVATE_KEY:-${L2_INITIAL_OWNER_PRIVATE_KEY:-}}"
    if [[ -n "$owner_key" ]]; then
      admin="$(cast wallet address --private-key "$owner_key")"
      sig="runRepointSyncRole()"
      forge_actor_args=()
    else
      admin="${L2_SENDER_ADMIN:-${INITIAL_OWNER:-${L2_INITIAL_OWNER:-$(just _repoint-anchor "$L2_NETWORK" initialOwner)}}}"
      [[ -n "$admin" ]] || { echo "No INITIAL_OWNER_PRIVATE_KEY and could not resolve the admin address (need yq, or set INITIAL_OWNER)." >&2; exit 1; }
      admin="$(cast to-check-sum-address "$admin")"
      sig="runRepointSyncRoleUnlocked()"
      forge_actor_args=(--unlocked --sender "$admin")
      echo "No INITIAL_OWNER_PRIVATE_KEY — DRESS REHEARSAL mode: impersonating $admin (anvil forks only)."
      cast rpc --rpc-url "$L2_RPC_URL" anvil_impersonateAccount "$admin" >/dev/null 2>&1 \
        || { echo "Impersonation refused: $L2_RPC_URL is not an anvil fork. Set INITIAL_OWNER_PRIVATE_KEY to broadcast for real." >&2; exit 1; }
      cast rpc --rpc-url "$L2_RPC_URL" anvil_setBalance "$admin" 0xde0b6b3a7640000 >/dev/null 2>&1 || true
    fi

    just _repoint-sync-role-preflight "$next" "$retired" "$admin"
    echo "  broadcasting grant, then revoke — TWO transactions, in that order."

    export L2_SYNC_TRIGGER_NEW="$next" L2_RETIRED_SYNC_TRIGGER="$retired" INITIAL_OWNER="$admin"
    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig "$sig" --rpc-url "$L2_RPC_URL" --broadcast --non-interactive "${forge_actor_args[@]+"${forge_actor_args[@]}"}"
    echo
    echo "Next: 'just audit-ownership' must show hasRole(SYNC_ROLE, $next) = true AND"
    echo "hasRole(SYNC_ROLE, $retired) = false on this lane. Update L2_SYNC_TRIGGER in"
    echo ".env.$L2_NETWORK and the l2SyncTrigger anchor in config/state/$L2_NETWORK.deployed.yaml."

# Read-only companion to `repoint-sync-role`: run every entry gate against live state and print the two
# CustomSender calls, for a role admin that does not broadcast from this repo (the Initial Owner is an
# external party; after `finalize` the admin is a bridge executor reachable only by a DAO vote). Emitting
# both calls is also how they get batched into ONE transaction — the only route to a zero-length window in
# which two triggers hold SYNC_ROLE.
#
# Broadcasts nothing and needs no key. The admin whose gates are checked defaults to the lane's pinned
# initialOwner anchor; set L2_SENDER_ADMIN once that is no longer the admin (post-`finalize` it is the
# governance executor).
#
# Usage: just -E .env.<network> repoint-sync-role-calldata
repoint-sync-role-calldata:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    for c in cast forge yq; do command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; exit 1; }; done
    next="$(just _repoint-next-sync-trigger)"
    retired="$(just _repoint-retired-sync-trigger)"
    if [[ "$next" == "$retired" ]]; then
      echo "SyncTrigger v2 and v1 resolve to the SAME address ($next)." >&2
      echo "config/state/$L2_NETWORK.deployed.yaml may not yet carry the v2 pair — run deploy-automation first." >&2
      exit 1
    fi
    admin="${L2_SENDER_ADMIN:-${INITIAL_OWNER:-${L2_INITIAL_OWNER:-$(just _repoint-anchor "$L2_NETWORK" initialOwner)}}}"
    [[ -n "$admin" ]] || { echo "Could not resolve the role admin address (need yq, or set INITIAL_OWNER)." >&2; exit 1; }
    admin="$(cast to-check-sum-address "$admin")"

    just _repoint-sync-role-preflight "$next" "$retired" "$admin"

    export L2_SYNC_TRIGGER_NEW="$next" L2_RETIRED_SYNC_TRIGGER="$retired" INITIAL_OWNER="$admin"
    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runPrintRepointSyncRoleCalldata()' --rpc-url "$L2_RPC_URL"

# Read one checksummed address from a state-mate `.deployed.yaml` sibling by anchor name.
[no-exit-message]
_repoint-deployed-anchor file anchor:
    #!/usr/bin/env bash
    set -euo pipefail
    file='{{file}}'; anchor='{{anchor}}'
    [[ -f "$file" ]] || { echo "missing $file" >&2; exit 1; }
    v=$(yq ".deployed.l2[] | select(anchor == \"$anchor\")" "$file" 2>/dev/null | tr -d '"' | head -n1)
    [[ "$v" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "anchor &$anchor not found in $file" >&2; exit 1; }
    cast to-check-sum-address "$v"

# SyncTrigger v2 — the live automation pair from `just deploy-automation` (grant target).
[no-exit-message]
_repoint-next-sync-trigger:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network>}"
    just _repoint-deployed-anchor "config/state/$L2_NETWORK.deployed.yaml" l2SyncTrigger

# SyncTrigger v1 — the retired pair (revoke target) from the lane's primary .deployed sibling.
[no-exit-message]
_repoint-retired-sync-trigger:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network>}"
    just _repoint-deployed-anchor "config/state/$L2_NETWORK.deployed.yaml" RETIRED_l2SyncTrigger

# Resolve one scalar anchor from the effective L2 inputs (common + lane delta). Exactly one definition
# is required, so operational readers enforce the same no-shadowing rule as state-mate.
[no-exit-message]
_l2-input-anchor net anchor:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{net}}" in optimism|arbitrum|base|linea) ;; *) echo "unknown L2 network: {{net}}" >&2; exit 2 ;; esac
    common="config/state/l2.common.inputs.yaml"
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

# Repoint compatibility wrapper: empty (not an error) when yq is absent, so callers can degrade to
# the forge script's own on-chain gates.
[no-exit-message]
_repoint-anchor net anchor:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v yq >/dev/null 2>&1 || exit 0
    just _l2-input-anchor "{{net}}" "{{anchor}}"

# Read-only gates for `repoint-sync-role`, run BEFORE the broadcast so a mistake costs no gas. Duplicates
# the forge script's on-chain gates on purpose (same rationale as deploy-automation's key cross-check): a
# failed `cast call` here is a readable sentence, a reverted broadcast is a selector.
[no-exit-message]
_repoint-sync-role-preflight next retired admin:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    next='{{next}}'; retired='{{retired}}'; admin='{{admin}}'

    sender="$(just _repoint-anchor "$L2_NETWORK" l2CustomSender)"
    if [[ -z "$sender" ]]; then
      echo "Could not read the l2CustomSender anchor (need yq); the script's own gates still apply." >&2
      exit 0
    fi
    sender="$(cast to-check-sum-address "$sender")"

    sync_role="$(cast keccak 'SYNC_ROLE')"
    admin_role="0x0000000000000000000000000000000000000000000000000000000000000000"
    rd () { cast call "$@" --rpc-url "$L2_RPC_URL"; }

    echo "════ $L2_NETWORK ════ CustomSender $sender"
    echo "  SYNC_ROLE: $retired (retired)  →  $next (new)"
    echo "  signed by: $admin"

    role_admin="$(rd "$sender" 'getRoleAdmin(bytes32)(bytes32)' "$sync_role")"
    [[ "$role_admin" == "$admin_role" ]] || { echo "getRoleAdmin(SYNC_ROLE) = $role_admin — a DEDICATED SYNC_ROLE manager exists; investigate before rotating." >&2; exit 1; }
    [[ "$(rd "$sender" 'hasRole(bytes32,address)(bool)' "$admin_role" "$admin")" == "true" ]] \
      || { echo "$admin does NOT hold DEFAULT_ADMIN_ROLE on $sender — wrong key, or 'finalize' already sealed this lane to the governance executor (then the rotation needs a DAO vote: use repoint-sync-role-calldata)." >&2; exit 1; }
    [[ "$(rd "$sender" 'hasRole(bytes32,address)(bool)' "$sync_role" "$retired")" == "true" ]] \
      || { echo "$retired does NOT currently hold SYNC_ROLE — revokeRole would be a SILENT no-op, leaving the real holder armed. Check the retired address ('just audit-ownership')." >&2; exit 1; }
    if [[ "$(rd "$sender" 'hasRole(bytes32,address)(bool)' "$sync_role" "$next")" == "true" ]]; then
      echo "  NOTE $next already holds SYNC_ROLE — the grant is a no-op and only the revoke will change state."
    fi

    if [[ "${L2_REPOINT_ALLOW_ANY_TARGET:-}" == "true" ]]; then
      echo "  WARN L2_REPOINT_ALLOW_ANY_TARGET=true — the SENDER/selector identity guard on $next is WAIVED." >&2
    else
      target_sender="$(rd "$next" 'SENDER()(address)' 2>/dev/null || echo '')"
      [[ -n "$target_sender" ]] \
        || { echo "$next does not answer SENDER() — it is not a deployed SyncTrigger. Set L2_REPOINT_ALLOW_ANY_TARGET=true only if arming a non-trigger account is intended." >&2; exit 1; }
      [[ "$(cast to-check-sum-address "$target_sender")" == "$sender" ]] \
        || { echo "$next.SENDER() = $target_sender, not this lane's CustomSender $sender — that trigger belongs to another lane (SENDER is immutable and cannot be fixed)." >&2; exit 1; }
    fi
    echo "  preflight OK — the retired holder is armed, the target is lane-matched, the actor is admin."

# Publish the three deployed contracts' Solidity SOURCE to the lane's block explorer (Etherscan v2).
# This is explorer source-publishing — NOT the on-chain state/config checks the other `verify-*`
# recipes do (those compare live state against pinned constants; this only affects the explorer).
#
# Re-runnable and decoupled from `deploy-test`: it reads the deployed addresses from env and recovers
# each contract's ACTUAL constructor args from chain via forge's --guess-constructor-args. The canary
# deploys with deployer-owned infra + test values, so re-deriving args from production constants
# would NOT match the deployed bytecode — let forge read what was actually deployed. Compiler settings
# (solc 0.8.34 / evm osaka / default optimizer) come from foundry.toml automatically, so the standard
# JSON matches the deployed bytecode by construction — do not set a different FOUNDRY_PROFILE.
#
# If a lane's explorer endpoint ever regresses, add: --verifier-url 'https://api.etherscan.io/v2/api'
# (Linea, chain 59144, is the most likely to need a re-run.) Verification is idempotent — safe to re-run.
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL, L2_ORACLE_POOL, L2_SYNC_TRIGGER,
#   L2_CRE_RECEIVER, ETHERSCAN_API_KEY (an etherscan.io v2 key; one key covers all 4 lanes via --chain).
#
# Usage: just -E .env.<network> verify-sources
verify-sources:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${L2_ORACLE_POOL:?L2_ORACLE_POOL is required; populate it from deploy-test output}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it from deploy-test output}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required; populate it from deploy-test output}"
    : "${ETHERSCAN_API_KEY:?ETHERSCAN_API_KEY is required; export an etherscan.io v2 API key before running}"
    for c in cast forge; do command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; exit 1; }; done

    chain_id=$(cast chain-id --rpc-url "$L2_RPC_URL" | tr -d '\r\n')
    echo "Publishing canary sources for $L2_NETWORK (chain $chain_id) to the Etherscan v2 explorer:"
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

# Third-party check of the explorer-published canary sources: diffyscan (lidofinance/diffyscan)
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

# Stage 0→1 verify (read-only): canary infra deployed + deployer-owned, pool repointed, SYNC_ROLE
# granted, seal not run. Run right after `activate`, before `simulate-sync` (it asserts the full float).
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL, L2_ORACLE_POOL, L2_SYNC_TRIGGER, L2_CRE_RECEIVER,
#   L2_TEST_DEPLOYER. Optional: L2_SYNC_MIN_AMOUNT_TEST / L2_SYNC_DELAY_TEST
#   (defaults: 0.0002 WETH / 60 seconds).
#
# Usage: just -E .env.<network> verify-test
verify-test:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${L2_ORACLE_POOL:?L2_ORACLE_POOL is required; populate it from deploy-test output}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it from deploy-test output}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required; populate it from deploy-test output}"
    : "${L2_TEST_DEPLOYER:?L2_TEST_DEPLOYER is required; populate it from deploy-test output}"

    : "${L2_SYNC_MIN_AMOUNT_TEST:=200000000000000}"
    : "${L2_SYNC_DELAY_TEST:=60}"
    export L2_SYNC_MIN_AMOUNT_TEST L2_SYNC_DELAY_TEST

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runVerifyTest()' --rpc-url "$L2_RPC_URL"

# Stage 0→1 (Initial Owner): reversible activation — repoint CustomSender at the new pool and grant the
# new SyncTrigger SYNC_ROLE. Admin + the old automation's SYNC_ROLE are left intact so `rollback` is clean.
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL, INITIAL_OWNER_PRIVATE_KEY,
#   L2_ORACLE_POOL, L2_SYNC_TRIGGER.
#
# Usage: just -E .env.<network> activate
activate:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${INITIAL_OWNER_PRIVATE_KEY:?required for runActivate(); export it before running}"
    : "${L2_ORACLE_POOL:?L2_ORACLE_POOL is required; populate it from deploy-test output}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it from deploy-test output}"

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runActivate()' --rpc-url "$L2_RPC_URL" --broadcast

# Stage 1 (Deployer): fund the deployed SyncTrigger's native fee float (L2_SYNC_TRIGGER_INITIAL_FLOAT).
# Split out of `deploy-test` so the deploy and the float funding are distinct transactions. Run ONCE after
# `deploy-test` and before `verify-test`/`simulate-sync` (both require the funded float). Sends the FULL
# configured float (not a top-up — re-running over-funds; excess is owner-only `sweep`-recoverable);
# reverts (L2UpgradeFloatBelowFloor) only if that float is below the worst-case floor.
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL, L2_LIDO_DEPLOYER_PRIVATE_KEY, L2_SYNC_TRIGGER.
#
# Usage: just -E .env.<network> fund-trigger
fund-trigger:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${L2_LIDO_DEPLOYER_PRIVATE_KEY:?required for runFundTrigger(); export it before running}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it from deploy-test output}"

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runFundTrigger()' --rpc-url "$L2_RPC_URL" --broadcast

# Stage 1 (Deployer): seed the pool with WETH so a sync becomes due, and send the SyncTrigger a minimal
# fee float. Deposits ETH→WETH and transfers it to the pool (WETH is read from the pool's TOKEN_IN,
# authoritative), then transfers the float to L2_SYNC_TRIGGER.
#
# NB the amounts are deliberately minimal: the seed equals the test minAmount (shouldSyncAmount uses
# `>=`, so exactly 0.0002 is due), and the 0.13 float clears getMaxFees() on every network
# (floor = 0.125 on OP/Base/Linea, ≈0.1266 on Arbitrum) — enough for ONE sync. It is BELOW the
# configured L2_SYNC_TRIGGER_INITIAL_FLOAT (0.5), so `verify-test` fails its "syncTrigger fee float"
# assert unless `fund-trigger` also ran.
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL, L2_LIDO_DEPLOYER_PRIVATE_KEY, L2_ORACLE_POOL,
#   L2_SYNC_TRIGGER.
# Optional env: L2_TEST_WETH_SEED (wei, default 5e14 = 0.0005 WETH; must be >=
#   L2_SYNC_MIN_AMOUNT_TEST, whose default is 0.0002 WETH);
#   L2_TEST_TRIGGER_FLOAT (wei, default 1.3e17 = 0.13 ETH; must be >= SyncTrigger.getMaxFees()).
#
# Usage: just -E .env.<network> seed-test-weth
seed-test-weth:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${L2_LIDO_DEPLOYER_PRIVATE_KEY:?required to fund/seed; export it before running}"
    : "${L2_ORACLE_POOL:?L2_ORACLE_POOL is required; populate it from deploy-test output}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it from deploy-test output}"
    command -v cast >/dev/null 2>&1 || { echo "Missing 'cast' (foundry)" >&2; exit 1; }
    SEED="${L2_TEST_WETH_SEED:-500000000000000}"
    FLOAT="${L2_TEST_TRIGGER_FLOAT:-130000000000000000}"
    WETH="$(cast call "$L2_ORACLE_POOL" 'TOKEN_IN()(address)' --rpc-url "$L2_RPC_URL" | tr -d '\r\n')"
    echo "Seeding $SEED wei of WETH ($WETH) into pool $L2_ORACLE_POOL"
    cast send "$WETH" 'deposit()' --value "$SEED" --rpc-url "$L2_RPC_URL" --private-key "$L2_LIDO_DEPLOYER_PRIVATE_KEY"
    cast send "$WETH" 'transfer(address,uint256)' "$L2_ORACLE_POOL" "$SEED" --rpc-url "$L2_RPC_URL" --private-key "$L2_LIDO_DEPLOYER_PRIVATE_KEY"
    echo "Sending $FLOAT wei fee float to SyncTrigger $L2_SYNC_TRIGGER"
    cast send "$L2_SYNC_TRIGGER" --value "$FLOAT" --rpc-url "$L2_RPC_URL" --private-key "$L2_LIDO_DEPLOYER_PRIVATE_KEY"
    MAXFEES="$(cast call "$L2_SYNC_TRIGGER" 'getMaxFees()(uint256)' --rpc-url "$L2_RPC_URL" | awk '{print $1}')"
    BAL="$(cast balance "$L2_SYNC_TRIGGER" --rpc-url "$L2_RPC_URL")"
    echo "Pool WETH balance: $(cast call "$WETH" 'balanceOf(address)(uint256)' "$L2_ORACLE_POOL" --rpc-url "$L2_RPC_URL")"
    echo "SyncTrigger balance: $BAL (getMaxFees: $MAXFEES)"
    [[ "$BAL" -ge "$MAXFEES" ]] || echo "WARNING: SyncTrigger balance < getMaxFees() — canSync will be false (due-but-blocked stall)" >&2

# Stage 1 (Deployer): simulate a CRE-driven sync by calling CREReceiver.onReport directly (the deployer is
# the configured forwarder + author). Runs onReport → triggerSync → CustomSender.sync. Seed WETH and wait
# the test delay (L2_SYNC_DELAY_TEST) first.
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL, L2_LIDO_DEPLOYER_PRIVATE_KEY, L2_SYNC_TRIGGER,
#   L2_CRE_RECEIVER.
#
# Usage: just -E .env.<network> simulate-sync
simulate-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${L2_LIDO_DEPLOYER_PRIVATE_KEY:?required for runSimulateSync(); export it before running}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it from deploy-test output}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required; populate it from deploy-test output}"

    delay="${L2_SYNC_DELAY_TEST:-60}"
    echo "Reminder: a sync only fires once the canary delay (${delay}s) has elapsed since the last execution." >&2

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runSimulateSync()' --rpc-url "$L2_RPC_URL" --broadcast

# Stage 1 (Deployer): full canary test loop — preflight-check → seed-test-weth → simulate-sync — for
# optimism, arbitrum and linea in sequence. Each network re-invokes `just` with NETWORK=<net> so the
# per-network dotenv (.env + .env.<net>) is loaded fresh (see `set dotenv-filename` at the top).
# Stops at the first failing step. NB simulate-sync fires only if the canary delay
# (L2_SYNC_DELAY_TEST, default 60 seconds) has elapsed since that network's last execution.
#
# Usage: just test-sync-all
test-sync-all:
    #!/usr/bin/env bash
    set -euo pipefail
    for net in optimism arbitrum linea; do
      echo "=== [$net] preflight-check → seed-test-weth → simulate-sync ==="
      NETWORK="$net" just preflight-check seed-test-weth simulate-sync
    done
    echo "=== test-sync-all: all networks done ==="

# Stage 1→0 (Initial Owner): roll back the activation — repoint CustomSender at the old pool and revoke the
# new SyncTrigger's SYNC_ROLE. The old automation was never touched, so the predecessor system is restored.
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL, INITIAL_OWNER_PRIVATE_KEY, L2_SYNC_TRIGGER.
#   (The predecessor OraclePool to restore is pinned per network in code, not env.)
#
# Usage: just -E .env.<network> rollback
rollback:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${INITIAL_OWNER_PRIVATE_KEY:?required for runRollback(); export it before running}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it from deploy-test output}"

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runRollback()' --rpc-url "$L2_RPC_URL" --broadcast

# Stage 1→2 (Deployer): sweep the test residue back to the deployer (pool WETH/wstETH + the SyncTrigger's
# ENTIRE ETH float — the trigger is handed over empty), restore production config (real CRE forwarder +
# LOL author + production delay/amounts), and transfer pool + SyncTrigger + CREReceiver to LOL. The
# in-broadcast assertion against production values reverts if any restore was missed. Fund the production
# float afterwards (permissionless) — until then canSync() is false and no production sync can fire.
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL, L2_LIDO_DEPLOYER_PRIVATE_KEY,
#   L2_ORACLE_POOL, L2_SYNC_TRIGGER, L2_CRE_RECEIVER. Optional: L2_LIQUIDITY_OWNER.
#
# Usage: just -E .env.<network> handoff
handoff:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${L2_LIDO_DEPLOYER_PRIVATE_KEY:?required for runHandoff(); export it before running}"
    : "${L2_ORACLE_POOL:?L2_ORACLE_POOL is required; populate it from deploy-test output}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it from deploy-test output}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required; populate it from deploy-test output}"

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runHandoff()' --rpc-url "$L2_RPC_URL" --broadcast
    echo
    echo "Next: LOL registers the production CRE workflow (just -E .env.$L2_NETWORK update-cre-config && deploy-cre-workflow),"
    echo "then 'just -E .env.$L2_NETWORK verify-stage2' before 'finalize'."

# Stage 2 verify (read-only): post-handoff, pre-seal — infra LOL-owned + production-configured, pool active,
# SYNC_ROLE held, Initial Owner still admin (seal not run).
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL, L2_ORACLE_POOL, L2_SYNC_TRIGGER, L2_CRE_RECEIVER.
#   Optional: L2_LIQUIDITY_OWNER.
#
# Usage: NETWORK=<network> just verify-stage2
verify-stage2:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${L2_ORACLE_POOL:?L2_ORACLE_POOL is required; populate it from deploy-test output}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it from deploy-test output}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required; populate it from deploy-test output}"
    command -v yq >/dev/null 2>&1 || { echo "Missing required command: yq" >&2; exit 1; }
    : "${L2_AUTOMATION_OWNER:=$(just _l2-input-anchor "$L2_NETWORK" l2AutomationOwner)}"
    : "${L2_AUTOMATION_OWNER:?missing l2AutomationOwner anchor in effective L2 inputs}"
    export L2_AUTOMATION_OWNER

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runVerifyStage2()' --rpc-url "$L2_RPC_URL"

# Automation Owner: after the live v2 canary, restore the production 12h delay and 5/100 WETH bounds.
# The forge action checks the signing key, trigger owner, and lane-bound SENDER before writing.
#
# Usage: NETWORK=<network> just promote-automation
promote-automation:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required}"
    : "${L2_RPC_URL:?L2_RPC_URL is required}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required}"
    : "${L2_AUTOMATION_OWNER:?L2_AUTOMATION_OWNER is required}"
    [[ -n "${L2_AUTOMATION_OWNER_PRIVATE_KEY:-${L2_AUTOMATION_OWNER_PK:-}}" ]] \
      || { echo "L2_AUTOMATION_OWNER_PRIVATE_KEY (or L2_AUTOMATION_OWNER_PK) is required" >&2; exit 1; }
    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runPromoteAutomation()' --rpc-url "$L2_RPC_URL" --broadcast

# Stage 2→3 (Initial Owner): the IRREVERSIBLE governance seal — revoke the retired SyncTrigger plus
# predecessor Chainlink/Gelato automation(s), migrate CustomSender admin + L2 ProxyAdmin to the governance
# executor. Refuses to run unless the pool is LOL-owned and the production SyncTrigger + CREReceiver are
# owned/authored by the Automation Owner. Run `migrate-l1` once after all 4 lanes are sealed.
#
# Required env (.env.<network>): L2_NETWORK, L2_RPC_URL, INITIAL_OWNER_PRIVATE_KEY,
#   L2_ORACLE_POOL, L2_SYNC_TRIGGER, L2_CRE_RECEIVER. Automation Owner and retired-trigger addresses are
#   resolved from config/state/<network>.{inputs,deployed}.yaml and exported to the forge script.
# Optional: L2_LIQUIDITY_OWNER.
#
# Usage: NETWORK=<network> just finalize
finalize:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK or export it before running}"
    : "${INITIAL_OWNER_PRIVATE_KEY:?required for runFinalize(); export it before running}"
    : "${L2_ORACLE_POOL:?L2_ORACLE_POOL is required; populate it from deploy-test output}"
    : "${L2_SYNC_TRIGGER:?L2_SYNC_TRIGGER is required; populate it from deploy-test output}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required; populate it from deploy-test output}"
    command -v yq >/dev/null 2>&1 || { echo "Missing required command: yq" >&2; exit 1; }
    : "${L2_AUTOMATION_OWNER:=$(just _l2-input-anchor "$L2_NETWORK" l2AutomationOwner)}"
    : "${L2_RETIRED_SYNC_TRIGGER:=$(yq '.. | select(anchor == "RETIRED_l2SyncTrigger")' "config/state/$L2_NETWORK.deployed.yaml" | tr -d '"' | head -n1)}"
    : "${L2_AUTOMATION_OWNER:?missing l2AutomationOwner anchor in effective L2 inputs}"
    : "${L2_RETIRED_SYNC_TRIGGER:?missing RETIRED_l2SyncTrigger anchor in config/state/$L2_NETWORK.deployed.yaml}"
    export L2_AUTOMATION_OWNER L2_RETIRED_SYNC_TRIGGER

    SCRIPT=$(just _l2-script-target "$L2_NETWORK") || exit
    forge script "$SCRIPT" --sig 'runFinalize()' --rpc-url "$L2_RPC_URL" --broadcast

# Deploy the CRE workflow for <network> via the `cre` CLI, OWNED BY THE AUTOMATION OWNER.
# Run after `update-cre-config` has populated the deploy config with the live SyncTrigger and
# CREReceiver addresses.
#
# The workflow owner is the Automation Owner EOA, which signs the WorkflowRegistry transaction itself
# (DOC.md §4.2) — the key and owner address are derived from the repo's canonical variables by
# script/shared/cre-env.sh, so no CRE_* value is hand-copied. Set CRE_DEPLOY_UNSIGNED=true to emit raw
# calldata instead (the route for a Safe/multi-sig owner, which must then execute it).
#
# Required env: L2_NETWORK, L2_RPC_URL, L2_CRE_RECEIVER (.env.<network>) + L2_AUTOMATION_OWNER and its
#   key (root .env). Before registering, the recipe reads CREReceiver.getExpectedAuthor() on-chain and
#   ABORTS if it does not equal the workflow owner — so a workflow can never be registered under an
#   owner that the pinned author gate will reject (which would silently brick every sync).
#
# Usage: just -E .env.<network> deploy-cre-workflow
deploy-cre-workflow:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    : "${L2_RPC_URL:?L2_RPC_URL is required; set it in .env.$L2_NETWORK (used to read CREReceiver.getExpectedAuthor())}"
    : "${L2_CRE_RECEIVER:?L2_CRE_RECEIVER is required; populate it in .env.$L2_NETWORK from deploy-test output}"

    case "$L2_NETWORK" in
      optimism|arbitrum|base|linea) ;;
      *) echo "Unknown L2_NETWORK: $L2_NETWORK" >&2; exit 2 ;;
    esac

    CRE="$(just _cre-bin)"
    command -v cast >/dev/null 2>&1 || { echo "Missing 'cast' (foundry)" >&2; exit 1; }

    # Derives CRE_ETH_PRIVATE_KEY + CRE_WORKFLOW_OWNER (and cross-checks the key against the address).
    source "{{justfile_directory()}}/script/shared/cre-env.sh"
    cre_env_export

    # Cross-check against the on-chain pin: the workflow owner we are about to register MUST equal the
    # already-deployed CREReceiver.expectedAuthor, or the author gate rejects every report (silent
    # sync stall). Compare checksummed forms so case differences don't cause a false mismatch.
    PINNED="$(cast call "$L2_CRE_RECEIVER" 'getExpectedAuthor()(address)' --rpc-url "$L2_RPC_URL" | tr -d '\r\n')"
    OWNER_CS="$(cast to-check-sum-address "$CRE_WORKFLOW_OWNER")"
    PINNED_CS="$(cast to-check-sum-address "$PINNED")"
    if [[ "$OWNER_CS" != "$PINNED_CS" ]]; then
      echo "ABORT: CRE_WORKFLOW_OWNER ($OWNER_CS) != on-chain CREReceiver.getExpectedAuthor() ($PINNED_CS)." >&2
      echo "Registering the workflow under $OWNER_CS would make every report fail the author gate." >&2
      echo "Fix: set L2_AUTOMATION_OWNER (root .env) to the pinned author, or re-pin via setExpectedAuthor first." >&2
      exit 1
    fi
    echo "Cross-check OK: CRE_WORKFLOW_OWNER == CREReceiver.expectedAuthor ($OWNER_CS)."

    # Per-lane target: chain-name + workflow-name + config-path all live in the target, so the lane can
    # never be mixed up by a stray --config, and the four lanes cannot collide on one workflow name.
    TARGET="production-$L2_NETWORK"
    CONFIG="config.deploy.$L2_NETWORK.json"
    [[ -f "cre-workflows/sync-automation/$CONFIG" ]] \
      || { echo "Missing cre-workflows/sync-automation/$CONFIG. Run 'just -E .env.$L2_NETWORK update-cre-config' first." >&2; exit 1; }
    grep -q '0xYOUR_' "cre-workflows/sync-automation/$CONFIG" \
      && { echo "Placeholder addresses still in $CONFIG. Run 'just -E .env.$L2_NETWORK update-cre-config' first." >&2; exit 1; } || true

    # Run from the PROJECT root (cre-workflows/, holding project.yaml) and pass the workflow folder by
    # NAME: the CLI resolves <workflow-folder-path> against the project root it discovers, so `.` from
    # inside sync-automation/ resolves back to cre-workflows/ and it looks for workflow.yaml there.
    if [[ "${CRE_DEPLOY_UNSIGNED:-false}" == "true" ]]; then
      echo "Emitting UNSIGNED WorkflowRegistry calldata for owner $CRE_WORKFLOW_OWNER (target $TARGET)."
      cd cre-workflows && "$CRE" workflow deploy sync-automation --target="$TARGET" --unsigned
      echo
      echo "===================================================================="
      echo "Next: execute the WorkflowRegistry calldata printed above FROM $CRE_WORKFLOW_OWNER."
      echo "That address becomes the workflow owner == CREReceiver.expectedAuthor."
    else
      echo "Registering CRE workflow owned by the Automation Owner $CRE_WORKFLOW_OWNER (target $TARGET, signed)."
      cd cre-workflows && "$CRE" workflow deploy sync-automation --target="$TARGET"
      echo
      echo "===================================================================="
    fi
    echo "Then run 'just record-cre-workflow-id $L2_NETWORK <workflow-id>' with the returned ID,"
    echo "followed by 'just -E .env.$L2_NETWORK verify-cre-workflow'."
    echo "===================================================================="

# L1 admin migration (runs ONCE — shared across all networks). Grants DEFAULT_ADMIN
# on the L1 LidoCustomReceiver to the Lido DAO Agent and revokes from the Initial
# Owner; transfers L1 ProxyAdmin ownership to the Lido DAO Agent. The L1 Receiver
# is shared across all four L2 networks, so this is a one-time post-rollout step.
# Actor: Initial Owner (cold key).
#
# Required env: an Ethereum-mainnet RPC resolved by cre-env.sh (L1_RPC_URL, bound in every
#               .env.<network> — it's identical across the four), and INITIAL_OWNER_PRIVATE_KEY.
#               (The Lido DAO Agent recipient is pinned in code — see L1MigrationConstants — not env.)
#
# Usage: just -E .env.<any-network> migrate-l1
migrate-l1:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{justfile_directory()}}/script/shared/cre-env.sh"
    L1_RPC_URL="$(resolve_l1_rpc)"
    export L1_RPC_URL
    : "${INITIAL_OWNER_PRIVATE_KEY:?required for L1 migration; export it before running}"
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
# Nothing is hardcoded: lane-specific constants are resolved from config/state/<net>.inputs.yaml,
# while universal constants come from config/state/l2.common.inputs.yaml. Both are operator review
# surfaces kept in lockstep with the Solidity constants by `just verify-constants-sync`, and every
# resolved value is echoed up front so the quote is auditable —
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

# Post-migration at-a-glance health snapshot: reads the ON-CHAIN-READABLE rows of docs/monitoring.md
# across all four lanes + L1 in ONE pass, so an operator can SEE live state before the dedicated
# monitoring/indexer system exists. A SUBSET by design — split by what is actually one-shot readable:
#   • does      — §1 access-control (a cheap, contamination-resistant subset + live wiring cross-checks),
#                 §2 L1 trapped funds, §3 sync-liveness (getLastExecution staleness, shouldSyncAmount/
#                 canSync due-but-blocked pairing, pool WETH, CCIP allow-list), §5 float headroom; plus
#                 BEST-EFFORT recent-window log scans for CallExecuted / MessageFailed / Sync.
#   • delegates — exhaustive §1 wiring → state-mate (`just … -upgrade-state-verify`); fee/gas headroom
#                 (§5) → `just quote-ccip-fees` + `preflight-check`; CRE registry owner/status (§4) →
#                 `just -E .env.<net> verify-cre-workflow`.
#   • CANNOT (prints a "wire into indexer/dashboard" footer) — access-control & lifecycle EVENT
#                 subscriptions, CRE credit balance (dashboard-only; on-chain proxy = §3 liveness),
#                 CCIP manual-exec queue, Arbitrum retryable redeems, RMN curse, continuous 1:1 pairing.
#
# WHY NOT just state-mate: state-mate asserts STABLE EQUALITIES, so it owns §1 — but it structurally
# cannot express §3/§5, which are thresholds + time-relative drift (config/state/l2.yaml even marks
# getLastExecution/canSync `null` and shouldSyncAmount valid only at the deploy instant). Those rows
# are exactly what this recipe adds; the two are complementary layers, not substitutes.
#
# Honest degradation (no false "OK"): a reverted/empty read prints WARN/SKIP, never OK. Deployed
# addresses (SyncTrigger/CREReceiver/OraclePool) come from config/state/<net>.deployed.yaml when
# present, else those rows SKIP with a "run after deploy-test" note — but CustomSender + the new pool
# are still derived LIVE (oldPool.SENDER() → getOraclePool()) and cross-checked against the file, so a
# stale/contaminated .deployed.yaml is caught, not trusted.
#
# Needs: RPC_<NET> (or legacy L2_<NET>_RPC_URL) per lane; RPC_ETHEREUM (or L1_RPC_URL) for the L1 pass.
# Optional: MONITOR_WINDOW_HOURS (default 24) bounds the best-effort event scans. Read-only; exits
# nonzero if any check is WARN/ALERT/SKIP. Full addresses always shown.
# At-a-glance on-chain health snapshot of the monitoring.md on-chain-readable rows (all 4 lanes + L1, read-only).
postflight-monitor:
    #!/usr/bin/env bash
    set -uo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    for c in yq cast jq; do command -v "$c" >/dev/null 2>&1 || { echo "$c is required" >&2; exit 1; }; done
    WINDOW_H="${MONITOR_WINDOW_HOURS:-24}"

    # ── Protocol-universal constants (same values state-mate pins inline; not lane-specific) ──
    DEFAULT_ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"
    SYNC_ROLE="0xbb1ef2b79fa8154a13ffa50bd30e5f91ed93ff9b924bd04be671240cbc9d4b71"
    TRIGGER_SYNC_SEL="0x340b2b0b"                                                            # SyncTrigger.triggerSync()
    EIP1967_ADMIN_SLOT="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
    # Event topic0s — canonical signatures verified against the compiled ABIs (out/*.json).
    T_SYNC="0x2826f7440c9ba1050bcd2c586a60551875ac8951ec73f01df55ef00b59ae1a9c"             # CustomSender.Sync(address,uint64,bytes32,uint256)
    T_CALLEXEC="0xbe82131bb3404498c769b0511da41a4ad409fa7152562c2b6669241cbe3bb884"          # CREReceiver.CallExecuted(address,bytes4,bytes)
    T_MSG_OK="0xdf6958669026659bac75ba986685e11a7d271284989f565f2802522663e9a70f"            # LidoCustomReceiver.MessageSucceeded(bytes32)
    T_MSG_FAIL="0xef8a84d7e9c9d42c79a42cba16e93688c646989f43846843e163672cc887e253"          # LidoCustomReceiver.MessageFailed(bytes32,(bytes32,uint64,bytes,bytes,(address,uint256)[]))
    # Canonical mainnet Lido stETH — the L1 receiver transiently holds ETH→stETH→wstETH while staking.
    # Not a Solidity constant in this repo, so a documented literal here (same convention as preflight-check).
    L1_STETH="0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84"
    TRAP_ALERT_WEI="1000000000000000000"                                                     # §2: alert if a balance > 1 ETH(-equiv)

    rc=0
    parse_num() { local s="$1"; s="${s%%[*}"; s="${s%% *}"; s="${s//$'\r'/}"; s="${s//$'\n'/}"; printf '%s' "$s"; }
    yq1() { yq "[.. | select(anchor==\"$2\")][0]" "$1" 2>/dev/null | tr -d '"' | tr -d '\r\n'; }
    is_addr() { [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
    is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
    lc() { printf '%s' "${1:-}" | tr 'A-F' 'a-f'; }                                          # lowercase hex (portable to macOS bash 3.2 — no ${x,,})
    eqa() { [[ "$(lc "$1")" == "$(lc "$2")" ]]; }                                            # case-insensitive address compare
    ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }                              # a>=b (awk doubles — heuristic at wei scale)
    lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0< b+0)}'; }                              # a<b
    # ── Output coloring (auto-off when stdout isn't a TTY or NO_COLOR is set). Keyword colored,
    # message text plain; the fixed-width keyword padding is preserved (ANSI codes are zero-width).
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
      C_RST=$'\033[0m'; C_OK=$'\033[1;32m'; C_INFO=$'\033[2m'; C_WARN=$'\033[1;33m'; C_ALERT=$'\033[1;31m'; C_SKIP=$'\033[36m'; C_HDR=$'\033[1;36m'
    else
      C_RST=''; C_OK=''; C_INFO=''; C_WARN=''; C_ALERT=''; C_SKIP=''; C_HDR=''
    fi
    hdr()   { printf '%s%s%s\n' "$C_HDR" "$*" "$C_RST"; }                                    # section banner / title (bold cyan)
    OK()    { printf '    %sOK%s    %s\n' "$C_OK"    "$C_RST" "$1"; }
    INFO()  { printf '    %sinfo%s  %s\n' "$C_INFO"  "$C_RST" "$1"; }
    WARN()  { printf '    %sWARN%s  %s\n' "$C_WARN"  "$C_RST" "$1"; rc=1; }
    ALERT() { printf '    %sALERT%s %s\n' "$C_ALERT" "$C_RST" "$1"; rc=1; }
    SKIP()  { printf '    %sSKIP%s  %s\n' "$C_SKIP"  "$C_RST" "$1"; rc=1; }
    # ck_addr "<label>" "<got>" "<want>" "<friendly>" — OK if got==want, ALERT on mismatch, WARN if unreadable.
    ck_addr() { if ! is_addr "$2"; then WARN "$1 unreadable"; elif eqa "$2" "$3"; then OK "$1 = $4 ($3)"; else ALERT "$1 = $2 (expected $4 $3)"; fi; }
    # ck_trap "<label>" "<wei>" — §2 trapped-funds verdict: WARN if unreadable, ALERT if > ~1 ETH-equiv, else OK.
    ck_trap() { if ! is_uint "$2"; then WARN "$1 balance unreadable"; elif ge "$2" "$TRAP_ALERT_WEI"; then ALERT "$1 = $(cast from-wei "$2") (>1 ETH-equiv ⇒ page)"; else OK "$1 = $(cast from-wei "$2")"; fi; }
    # rd url target sig [args...] -> echoes the parsed return, or empty on revert/RPC error. (Runs in a
    # command substitution, so it must signal failure through its OUTPUT — callers validate with
    # is_addr/is_uint or an explicit ==true/false; a global flag could not survive the subshell.)
    rd() { local url="$1" tgt="$2" sig="$3"; shift 3; local out
           out="$(cast call "$tgt" "$sig" "$@" --rpc-url "$url" 2>/dev/null)" || out=""; parse_num "$out"; }
    # from_block ~WINDOW_H hours back via a 1000-block timestamp probe (echo int, or empty on failure).
    blocks_back() { local url="$1" lb ob nts ots span nb
      lb="$(parse_num "$(cast block-number --rpc-url "$url" 2>/dev/null)")"; [[ "$lb" =~ ^[0-9]+$ ]] || return 1
      ob=$(( lb>1000 ? lb-1000 : 0 ))
      nts="$(parse_num "$(cast block "$lb" --field timestamp --rpc-url "$url" 2>/dev/null)")"
      ots="$(parse_num "$(cast block "$ob" --field timestamp --rpc-url "$url" 2>/dev/null)")"
      [[ "$nts" =~ ^[0-9]+$ && "$ots" =~ ^[0-9]+$ && "$nts" -gt "$ots" ]] || return 1
      span=$(( nts - ots )); (( span > 0 )) || span=2000
      nb=$(( WINDOW_H * 3600 * 1000 / span )); echo $(( lb>nb ? lb-nb : 0 )); }
    # count logs of topic0 at address since from_block; echoes integer, or "?" on RPC error.
    count_logs() { local out
      if out="$(cast logs --json --from-block "$4" --to-block latest --address "$2" "$3" --rpc-url "$1" 2>&1)"; then
        printf '%s' "$out" | jq 'length' 2>/dev/null || echo "?"; else echo "?"; fi; }

    hdr "===================================================================="
    hdr "POSTFLIGHT MONITOR — Lido L2 direct-staking (docs/monitoring.md subset)"
    echo "  event-scan window: ${WINDOW_H}h (override: MONITOR_WINDOW_HOURS) — snapshot, not coverage"
    hdr "===================================================================="

    # ════════════════════════ L1 (Ethereum mainnet) ════════════════════════
    echo
    hdr "──────────── L1 (Ethereum mainnet) ────────────"
    # Live monitor: explicit mainnet binding first, local fork proxy last (see cre-env.sh).
    L1_RPC="${L1_RPC_URL:-${RPC_ETHEREUM_REMOTE:-${RPC_ETHEREUM:-}}}"
    L1_IN="${ROOT_DIR}/config/state/ethereum.inputs.yaml"
    if [[ -z "$L1_RPC" ]]; then
      SKIP "L1 pass — set L1_RPC_URL in .env.<network> (or RPC_ETHEREUM_REMOTE)"
    elif ! cast chain-id --rpc-url "$L1_RPC" >/dev/null 2>&1; then
      SKIP "L1 pass — RPC not reachable: $L1_RPC"
    else
      # L1 receiver decoded from the bytes32 anchor in the common L2 inputs; DAO agent + wstETH
      # come from the independently verified L1 inputs (one yq pass).
      L1_RECV="$(cast parse-bytes32-address "$(just _l2-input-anchor optimism l1LidoCustomReceiverBytes32)" 2>/dev/null || true)"
      { IFS= read -r DAO; IFS= read -r INIT_OWNER; IFS= read -r L1_WSTETH; } < <(yq \
        '[.. | select(anchor=="lidoDaoAgent")][0], [.. | select(anchor=="initialOwner")][0], [.. | select(anchor=="l1Wsteth")][0]' \
        "$L1_IN" 2>/dev/null)
      if ! is_addr "$L1_RECV"; then SKIP "L1 receiver address unresolved (l1LidoCustomReceiverBytes32)"; else
        echo "  receiver = $L1_RECV"
        # §2 trapped funds — alert if any balance > 1 ETH(-equiv); the ">1h" duration is the indexer's job.
        ck_trap "§2 L1 receiver ETH" "$(parse_num "$(cast balance "$L1_RECV" --rpc-url "$L1_RPC" 2>/dev/null)")"
        for pair in "wstETH:$L1_WSTETH" "stETH:$L1_STETH"; do
          lbl="${pair%%:*}"; tok="${pair#*:}"; is_addr "$tok" || { WARN "§2 L1 receiver $lbl token address unresolved"; continue; }
          ck_trap "§2 L1 receiver $lbl" "$(rd "$L1_RPC" "$tok" 'balanceOf(address)(uint256)' "$L1_RECV")"
        done
        # §2 MessageFailed — best-effort scan
        fb="$(blocks_back "$L1_RPC" || true)"
        if [[ -n "$fb" ]]; then
          n="$(count_logs "$L1_RPC" "$L1_RECV" "$T_MSG_FAIL" "$fb")"
          if [[ "$n" == "?" ]]; then WARN "§2 MessageFailed scan failed (RPC range limit?) — check an indexer"
          elif [[ "$n" -gt 0 ]]; then ALERT "§2 $n MessageFailed in last ${WINDOW_H}h — PAGE (retryFailedMessage / recoverTokens)"
          else OK "§2 0 MessageFailed in last ${WINDOW_H}h (best-effort window)"; fi
          ok="$(count_logs "$L1_RPC" "$L1_RECV" "$T_MSG_OK" "$fb")"; INFO "§3 ${ok} MessageSucceeded in last ${WINDOW_H}h (pair vs L2 Sync below; 1:1 needs an indexer)"
        else WARN "§2/§3 L1 event scan skipped (block-window probe failed)"; fi
        # §1 L1 access-control (ACL is non-enumerable → assert hasRole pair, not getRoleMemberCount)
        r1="$(rd "$L1_RPC" "$L1_RECV" 'hasRole(bytes32,address)(bool)' "$DEFAULT_ADMIN_ROLE" "$DAO")"
        if   [[ "$r1" == "true"  ]]; then OK "§1 L1 receiver admin = Lido DAO Agent ($DAO)"
        elif [[ "$r1" == "false" ]]; then ALERT "§1 L1 receiver hasRole(admin, DAO) = false (expected true)"
        else WARN "§1 L1 receiver hasRole unreadable"; fi
        r2="$(rd "$L1_RPC" "$L1_RECV" 'hasRole(bytes32,address)(bool)' "$DEFAULT_ADMIN_ROLE" "$INIT_OWNER")"
        if   [[ "$r2" == "false" ]]; then OK "§1 L1 receiver admin NOT Initial Owner (rotated)"
        elif [[ "$r2" == "true"  ]]; then ALERT "§1 L1 receiver hasRole(admin, InitialOwner) = true (expected false)"
        else WARN "§1 L1 receiver init-owner hasRole unreadable"; fi
        INFO "§1 sole-admin count (==1) needs an enumerable ACL or RoleGranted/Revoked history — indexer"
        # §1 L1 ProxyAdmin — derived from the receiver's EIP-1967 admin slot (no hardcoded address)
        pa="$(cast parse-bytes32-address "$(cast storage "$L1_RECV" "$EIP1967_ADMIN_SLOT" --rpc-url "$L1_RPC" 2>/dev/null)" 2>/dev/null || true)"
        if is_addr "$pa"; then
          ck_addr "§1 L1 ProxyAdmin ($pa) owner" "$(rd "$L1_RPC" "$pa" 'owner()(address)')" "$DAO" "Lido DAO Agent"
        else WARN "§1 L1 ProxyAdmin not derivable from admin slot"; fi
      fi
      INFO "§4 CRE registry owner/status: run \`just -E .env.<net> verify-cre-workflow\` (registry owner == LOL Safe, status ACTIVE)"
    fi

    # ════════════════════════ L2 lanes (×4) ════════════════════════
    NETS=( optimism arbitrum base linea )
    for net in "${NETS[@]}"; do
      u="$(echo "$net" | tr '[:lower:]' '[:upper:]')"; name="${u:0:1}${net:1}"
      rpc_env="RPC_$u"; l2_env="L2_${u}_RPC_URL"
      echo; hdr "──────────── ${name} ────────────"
      INF="${ROOT_DIR}/config/state/${net}.inputs.yaml"; DEP="${ROOT_DIR}/config/state/${net}.deployed.yaml"
      [[ -f "$INF" ]] || { SKIP "${name} — inputs file not found: $INF"; continue; }
      url="${!rpc_env:-}"; [[ -n "$url" ]] || url="${!l2_env:-}"
      if [[ -z "$url" ]]; then SKIP "${name} — set ${rpc_env} (or legacy ${l2_env})"; continue; fi
      if ! cast chain-id --rpc-url "$url" >/dev/null 2>&1; then SKIP "${name} — ${rpc_env} not reachable: ${url}"; continue; fi
      FB="$(blocks_back "$url" || true)"   # one block-window probe per lane, reused by the §4 + §3 event scans

      # Resolve lane-local anchors in one yq pass, then shared anchors through the effective-input
      # resolver (which checks that common and lane files do not both define the same label).
      { IFS= read -r ROUTER; IFS= read -r WETH; IFS= read -r OLDPOOL; IFS= read -r CREFWD
        IFS= read -r INP_SENDER
      } < <(yq '[.. | select(anchor=="l2CcipRouter")][0], [.. | select(anchor=="l2Weth")][0],
        [.. | select(anchor=="RETIRED_l2OraclePool")][0], [.. | select(anchor=="l2CreForwarder")][0],
        [.. | select(anchor=="l2CustomSender")][0]' "$INF" 2>/dev/null)
      LOL="$(just _l2-input-anchor "$net" l2LiquidityOwner)"
      SEL="$(just _l2-input-anchor "$net" ethMainnetCcipChainSelector)"
      SYNCMIN="$(just _l2-input-anchor "$net" syncMinAmount)"
      # Deployed addresses (only SyncTrigger is not on-chain-discoverable). Absent file ⇒ SKIP those rows.
      DEP_TRIG="" ; DEP_RECV="" ; DEP_POOL=""
      if [[ -f "$DEP" ]]; then
        { IFS= read -r DEP_TRIG; IFS= read -r DEP_RECV; IFS= read -r DEP_POOL
        } < <(yq '[.. | select(anchor=="l2SyncTrigger")][0],
          [.. | select(anchor=="l2CreReceiver")][0], [.. | select(anchor=="l2OraclePool")][0]' "$DEP" 2>/dev/null)
      fi

      # Bootstrap CustomSender LIVE from the known old pool, cross-check vs the .inputs externals anchor.
      SENDER="$(rd "$url" "$OLDPOOL" 'SENDER()(address)')"
      if ! is_addr "$SENDER"; then SENDER="$INP_SENDER"; fi
      if is_addr "$SENDER"; then
        echo "  CustomSender = $SENDER"
        if is_addr "$DEP_TRIG"; then echo "  SyncTrigger  = $DEP_TRIG (.deployed)"; fi
        is_addr "$INP_SENDER" && { eqa "$SENDER" "$INP_SENDER" || ALERT "§1 CustomSender live=$SENDER ≠ .inputs=$INP_SENDER (stale/contaminated file)"; }
      else
        WARN "${name} — CustomSender unresolved (oldPool.SENDER() failed, no l2CustomSender in .inputs); §1/§3/§5 limited"
      fi

      # ── §1 wiring + new pool (derived live; cross-checked vs file) ──
      POOL=""
      if is_addr "$SENDER"; then
        POOL="$(rd "$url" "$SENDER" 'getOraclePool()(address)')"
        if is_addr "$POOL"; then
          if is_addr "$DEP_POOL"; then eqa "$POOL" "$DEP_POOL" && OK "§1 getOraclePool live == .deployed ($POOL)" || ALERT "§1 getOraclePool live=$POOL ≠ .deployed=$DEP_POOL (contamination)"; else INFO "§1 new OraclePool (live) = $POOL"; fi
        else WARN "§1 CustomSender.getOraclePool() unreadable"; POOL="$DEP_POOL"; fi
      fi
      if is_addr "$POOL"; then
        ck_addr "§1 OraclePool owner" "$(rd "$url" "$POOL" 'owner()(address)')" "$LOL" "LOL"
        p="$(rd "$url" "$POOL" 'paused()(bool)')"
        if   [[ "$p" == "false" ]]; then OK "§3 OraclePool not paused"
        elif [[ "$p" == "true"  ]]; then ALERT "§3 OraclePool paused (blocks fastStake)"
        else WARN "§3 OraclePool paused() unreadable"; fi
      fi

      # ── SyncTrigger-centric rows (need the deployed trigger address) ──
      if ! is_addr "$DEP_TRIG"; then
        SKIP "§1/§3/§5 SyncTrigger+CREReceiver rows — config/state/${net}.deployed.yaml absent (run after deploy-test)"
      else
        TRIG="$DEP_TRIG"
        if is_addr "$SENDER"; then
          hr="$(rd "$url" "$SENDER" 'hasRole(bytes32,address)(bool)' "$SYNC_ROLE" "$TRIG")"
          if   [[ "$hr" == "true"  ]]; then OK "§1 CustomSender SYNC_ROLE → SyncTrigger"
          elif [[ "$hr" == "false" ]]; then ALERT "§1 CustomSender hasRole(SYNC_ROLE, trigger) = false (expected true)"
          else WARN "§1 CustomSender SYNC_ROLE check unreadable"; fi
        fi
        ck_addr "§1 SyncTrigger owner" "$(rd "$url" "$TRIG" 'owner()(address)')" "$LOL" "LOL"
        # CREReceiver derived from the trigger's forwarder (live), cross-checked vs file
        RECV="$(rd "$url" "$TRIG" 'getForwarder()(address)')"
        if is_addr "$RECV"; then
          is_addr "$DEP_RECV" && { eqa "$RECV" "$DEP_RECV" || ALERT "§1 SyncTrigger.getForwarder live=$RECV ≠ .deployed CREReceiver=$DEP_RECV"; }
        else RECV="$DEP_RECV"; fi
        if is_addr "$RECV"; then
          ck_addr "§1 CREReceiver owner" "$(rd "$url" "$RECV" 'owner()(address)')" "$LOL" "LOL"
          ck_addr "§1 CREReceiver expectedAuthor" "$(rd "$url" "$RECV" 'getExpectedAuthor()(address)')" "$LOL" "LOL"
          ck_addr "§1 CREReceiver forwarder" "$(rd "$url" "$RECV" 'getForwarder()(address)')" "$CREFWD" "pinned CRE forwarder"
          ca="$(rd "$url" "$RECV" 'isCallAllowed(address,bytes4)(bool)' "$TRIG" "$TRIGGER_SYNC_SEL")"
          if   [[ "$ca" == "true"  ]]; then OK "§1 CREReceiver allows triggerSync from SyncTrigger"
          elif [[ "$ca" == "false" ]]; then ALERT "§1 CREReceiver isCallAllowed(trigger, triggerSync) = false (expected true)"
          else WARN "§1 CREReceiver isCallAllowed unreadable"; fi
        fi

        # ── §3 liveness ──
        le="$(rd "$url" "$TRIG" 'getLastExecution()(uint48)')"
        nowts="$(parse_num "$(cast block latest --field timestamp --rpc-url "$url" 2>/dev/null)")"
        poolweth=""; is_addr "$POOL" && poolweth="$(rd "$url" "$WETH" 'balanceOf(address)(uint256)' "$POOL")"
        if [[ "$le" =~ ^[0-9]+$ && "$nowts" =~ ^[0-9]+$ ]]; then
          age=$(( nowts - le )); ah=$(( age/3600 ))
          due_by_pool=0; [[ "$poolweth" =~ ^[0-9]+$ && "$SYNCMIN" =~ ^[0-9]+$ ]] && ge "$poolweth" "$SYNCMIN" && due_by_pool=1
          if (( ah > 24 )) && (( due_by_pool == 1 )); then WARN "§3 last sync ${ah}h ago while pool WETH ≥ min — investigate stall"
          else OK "§3 last sync ${ah}h ago$( (( due_by_pool==1 )) && echo " (pool WETH ≥ min)" || echo " (pool below min — idle is expected)" )"; fi
        else WARN "§3 getLastExecution unreadable"; fi
        [[ "$poolweth" =~ ^[0-9]+$ ]] && INFO "§3 OraclePool WETH = $(cast from-wei "$poolweth") (drains each sync)"

        should="$(rd "$url" "$TRIG" 'shouldSyncAmount()(uint256)')"; can="$(rd "$url" "$TRIG" 'canSync()(bool)')"
        if [[ "$should" =~ ^[0-9]+$ && ( "$can" == "true" || "$can" == "false" ) ]]; then
          if [[ "$should" != "0" && "$can" == "false" ]]; then ALERT "§3 due-but-blocked: shouldSyncAmount=$(cast from-wei "$should") WETH yet canSync=false — silent stall (float<getMaxFees / SYNC_ROLE revoked / pool paused)"
          elif [[ "$should" != "0" && "$can" == "true" ]]; then INFO "§3 due & executable (shouldSyncAmount=$(cast from-wei "$should") WETH, canSync=true) — workflow should fire"
          else OK "§3 idle (shouldSyncAmount=0, canSync=$can)"; fi
        else WARN "§3 shouldSyncAmount/canSync unreadable"; fi

        # ── §5 float headroom (≥2× recommended; <1× ⇒ next sync reverts) ──
        flo="$(parse_num "$(cast balance "$TRIG" --rpc-url "$url" 2>/dev/null)")"
        mf="$(rd "$url" "$TRIG" 'getMaxFees()(uint256)')"
        if [[ "$flo" =~ ^[0-9]+$ && "$mf" =~ ^[0-9]+$ && "$mf" != "0" ]]; then
          ratio="$(awk -v f="$flo" -v m="$mf" 'BEGIN{printf "%.2f", f/m}')"
          if lt "$flo" "$mf"; then ALERT "§5 float ${ratio}× getMaxFees (< 1× = next sync reverts, lane stalls): $(cast from-wei "$flo") / $(cast from-wei "$mf") ETH"
          elif lt "$flo" "$(awk -v m="$mf" 'BEGIN{printf "%.0f", 2*m}')"; then WARN "§5 float ${ratio}× getMaxFees (< 2× — top up): $(cast from-wei "$flo") / $(cast from-wei "$mf") ETH"
          else OK "§5 float ${ratio}× getMaxFees ($(cast from-wei "$flo") ETH)"; fi
        else WARN "§5 float / getMaxFees unreadable"; fi

        # ── §4 CallExecuted best-effort scan (the only on-chain proof the DON author-gate passes) ──
        if is_addr "$RECV"; then
          if [[ -n "$FB" ]]; then
            n="$(count_logs "$url" "$RECV" "$T_CALLEXEC" "$FB")"
            if [[ "$n" == "?" ]]; then WARN "§4 CallExecuted scan failed (RPC range limit?) — check an indexer"
            elif [[ "$n" -gt 0 ]]; then OK "§4 author gate proven ($n CallExecuted in last ${WINDOW_H}h)"
            else WARN "§4 0 CallExecuted in last ${WINDOW_H}h — idle OR author-gate failure (InvalidAuthor); confirm via longer history/indexer"; fi
          else WARN "§4 CallExecuted scan skipped (block-window probe failed)"; fi
        fi
      fi

      # ── §3 CCIP allow-list (router known; no trigger needed) + §3 Sync scan ──
      if is_addr "$ROUTER" && [[ "$SEL" =~ ^[0-9]+$ ]]; then
        sup="$(rd "$url" "$ROUTER" 'isChainSupported(uint64)(bool)' "$SEL")"
        if   [[ "$sup" == "true"  ]]; then OK "§3 CCIP dest-chain (Ethereum) allow-listed"
        elif [[ "$sup" == "false" ]]; then ALERT "§3 CCIP dest-chain de-allow-listed — every triggerSync reverts inside the router (revert-spam, not a clean stall)"
        else WARN "§3 Router.isChainSupported unreadable"; fi
      fi
      if is_addr "$SENDER"; then
        if [[ -n "$FB" ]]; then s="$(count_logs "$url" "$SENDER" "$T_SYNC" "$FB")"; [[ "$s" == "?" ]] && WARN "§3 Sync scan failed (RPC range limit?)" || INFO "§3 ${s} Sync events (L2) in last ${WINDOW_H}h (pair vs L1 MessageSucceeded; 1:1 needs an indexer)"; fi
      fi
    done

    # ════════════════════════ NOT covered here (wire into indexer / dashboard) ════════════════════════
    echo
    hdr "──────────── NOT covered here — needs an indexer / dashboard ────────────"
    echo "  • §1 events: RoleGranted/Revoked, OwnershipTransferred, Forwarder/ExpectedAuthor/AllowedCallUpdated, OraclePool Paused → Tenderly/Dune"
    echo "  • §4 CRE credit balance (LOL Safe's CRE account) — dashboard-only, no on-chain signal → https://cre.chain.link/workflows"
    echo "        on-chain proxy = the §3 liveness rows above (stale sync + healthy fees/float ⇒ suspect credit starvation)"
    echo "  • §2 CCIP manual-exec queue → https://ccip.chain.link/   • §5 Arbitrum retryable redeems → https://retryable-dashboard.arbitrum.io/"
    echo "  • RMN curse (no single stable view) + continuous 1:1 Sync↔MessageSucceeded pairing → indexer"
    echo "  • exhaustive §1 wiring → state-mate (\`just -E .env.<net> test-<net>-upgrade-state-verify\`); fee/gas headroom (§5) → \`just quote-ccip-fees\` + \`just -E .env.<net> preflight-check\`"
    echo
    hdr "===================================================================="
    if (( rc == 0 )); then printf '%sOK%s postflight-monitor: all on-chain-readable checks green (still wire the dashboard/indexer rows above).\n' "$C_OK" "$C_RST"
    else printf '%spostflight-monitor finished with WARN/ALERT/SKIP rows%s — review above (exit %s).\n' "$C_WARN" "$C_RST" "$rc"; fi
    hdr "===================================================================="
    exit $rc

# Live post-deploy "canary": stake a dust amount via CustomSender.fastStake against the NEW oracle
# pool's wstETH reserve and verify the staker actually received wstETH — a tiny end-to-end proof that
# the migrated pool services fastStake. By default it stakes against the pool's EXISTING liquidity;
# for a not-yet-funded pool set SMOKE_SEED_WSTETH>0 to first seed a little wstETH from the signer.
#
# MUST run AFTER `activate`: fastStake routes through CustomSender.getOraclePool(), which only points
# at the new pool once the canary activation has repointed it. The recipe HARD-ABORTS unless the sender points at the target new pool
# (else it would seed the new pool but stake into the old one). The pool is a WETH->wstETH swap venue —
# OraclePool.swap pays the staker out of the pool's wstETH reserve and reverts OraclePoolInsufficientTokenOut
# if it is empty — so "fund the pool" means seeding wstETH, NOT ETH, and is distinct from the SyncTrigger
# ETH float funded at deploy-test.
#
# DRY RUN BY DEFAULT: prints resolved values, runs every read-only precondition, prints the planned amounts
# and SENDS NOTHING. Re-run with SMOKE_CONFIRM=yes to actually move funds (wstETH seed tx + fastStake tx).
#
# Verification is by OBSERVATION (not assertion): the staker's wstETH balanceOf delta measured strictly
# across the fastStake tx must be > 0 and equal the emitted FastStake.amountOut, and the pool balances must
# reconcile (wstETH: before+seed-out; WETH: before+dust). Full addresses/amounts + both tx hashes are printed.
# If the stake tx fails after the seed tx lands, the seeded wstETH simply stays as pool reserve (recoverable
# only via a later swap) — not lost, but re-running adds more; size SMOKE_SEED_WSTETH accordingly.
#
# Required env: L2_NETWORK; RPC_<NET> (or legacy L2_RPC_URL); L2_SMOKE_PRIVATE_KEY (the canary signer —
#   needs only native ETH for the dust stake + gas; wstETH is required only when opting into the
#   seed step, see SMOKE_SEED_WSTETH below).
# New pool + sender: env L2_ORACLE_POOL + L2_CUSTOM_SENDER (printed by deploy-test) win; when unset the
#   new pool falls back to l2OraclePool in config/state/<net>.deployed.yaml and the CustomSender to the
#   l2CustomSender external in config/state/<net>.inputs.yaml. Tokens, chain-id and the old pool also
#   come from .inputs.yaml (no new hardcodes here, so verify-constants-sync is unaffected).
# Tunables (all wei): SMOKE_STAKE_AMOUNT (default 1e15 = 0.001), SMOKE_SEED_WSTETH (default 0),
#   SMOKE_MIN_OUT (default 0), SMOKE_GAS_BUFFER (default 1e15), SMOKE_STAKE_TOKEN=native|weth (default native).
# SMOKE_SEED_WSTETH: 0 (the default) = STAKE-ONLY — no seed tx; the [4/4] liquidity check requires the
#   pool's EXISTING wstETH reserve to cover the expected output, and the signer needs no wstETH at all.
#   Set >0 (e.g. 2e15) to first transfer that much wstETH from the signer into the pool — for a pool
#   that has not been funded yet (the original pre-LOL-seed canary flow).
#
# Usage:  just -E .env.<net> smoke-stake                    # dry run (read-only)
#         SMOKE_CONFIRM=yes just -E .env.<net> smoke-stake  # execute (moves real funds)
# Live canary: dust-fastStake against the new pool's wstETH reserve, verify wstETH received (dry-run by default; SMOKE_CONFIRM=yes moves real funds; SMOKE_SEED_WSTETH>0 seeds first).
smoke-stake:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${L2_NETWORK:?L2_NETWORK is required; set it in .env.<network> (one of: optimism|arbitrum|base|linea)}"
    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    for c in yq cast jq bc; do command -v "$c" >/dev/null 2>&1 || { echo "$c is required" >&2; exit 1; }; done

    # Resolve L2 RPC: prefer RPC_<NET> (shell env), fall back to L2_RPC_URL (legacy .env file).
    _net_upper=$(echo "$L2_NETWORK" | tr '[:lower:]' '[:upper:]')
    _rpc_var="RPC_${_net_upper}"
    L2_RPC_URL="${!_rpc_var:-${L2_RPC_URL:-}}"
    : "${L2_RPC_URL:?Set ${_rpc_var} (or legacy L2_RPC_URL) for $L2_NETWORK}"

    sm_inputs="${ROOT_DIR}/config/state/${L2_NETWORK}.inputs.yaml"
    sm_deployed="${ROOT_DIR}/config/state/${L2_NETWORK}.deployed.yaml"
    [[ -f "$sm_inputs" ]] || { echo "inputs file not found: $sm_inputs" >&2; exit 1; }

    die() { echo "SMOKE FAIL: $*" >&2; exit 1; }
    parse_num() { local s="$1"; s="${s%%[*}"; s="${s%% *}"; s="${s//$'\r'/}"; s="${s//$'\n'/}"; printf '%s' "$s"; }
    yq1() { yq "[.. | select(anchor==\"$2\")][0]" "$1" 2>/dev/null | tr -d '"' | tr -d '\r\n'; }
    is_addr() { [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
    is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
    lc() { printf '%s' "${1:-}" | tr 'A-F' 'a-f'; }
    eqa() { [[ "$(lc "$1")" == "$(lc "$2")" ]]; }
    nonzero_addr() { is_addr "$1" && [[ "$(lc "$1")" != "0x0000000000000000000000000000000000000000" ]]; }
    ge() { [[ "$(echo "$1 >= $2" | bc)" == "1" ]]; }                                         # exact big-int (wei exceeds bash 64-bit)
    # Must-succeed read: dies with context (the tolerant reads below use inline `|| true`).
    rdcall() { local out; out="$(cast call "$@" --rpc-url "$L2_RPC_URL" 2>/dev/null)" || die "cast call failed: $*"; parse_num "$out"; }

    # ── Resolve constants (no new hardcodes — single source verify-constants-sync/state-mate guard) ──
    EXPECTED_CHAIN_ID="$(yq1 "$sm_inputs" l2ChainId)"
    WETH="$(yq1 "$sm_inputs" l2Weth)"
    WSTETH="$(yq1 "$sm_inputs" l2Wsteth)"
    OLD_POOL="$(yq1 "$sm_inputs" RETIRED_l2OraclePool)"
    # CustomSender is a pre-existing external in .inputs; env (printed by deploy-test) wins.
    SENDER="${L2_CUSTOM_SENDER:-$(yq1 "$sm_inputs" l2CustomSender)}"
    # New pool: env (printed by deploy-test) wins; else the freshly-generated .deployed.yaml anchor.
    POOL="${L2_ORACLE_POOL:-$( [[ -f "$sm_deployed" ]] && yq1 "$sm_deployed" l2OraclePool || true )}"

    : "${L2_SMOKE_PRIVATE_KEY:?required — the canary signer key (needs native ETH for the dust stake + gas; wstETH only if SMOKE_SEED_WSTETH>0)}"
    SIGNER="$(cast wallet address --private-key "$L2_SMOKE_PRIVATE_KEY" 2>/dev/null | tr -d '\r\n')" || die "invalid L2_SMOKE_PRIVATE_KEY"

    STAKE_TOKEN="${SMOKE_STAKE_TOKEN:-native}"
    DUST="${SMOKE_STAKE_AMOUNT:-1000000000000000}"                                            # 1e15 = 0.001
    SEED="${SMOKE_SEED_WSTETH:-0}"                                                            # 0 = stake-only (pool already funded); set >0 to seed first
    MIN_OUT="${SMOKE_MIN_OUT:-0}"
    GAS_BUFFER="${SMOKE_GAS_BUFFER:-1000000000000000}"                                        # 1e15 = 0.001, native ETH gas headroom
    for v in DUST SEED MIN_OUT GAS_BUFFER; do is_uint "${!v}" || die "$v must be a wei integer, got '${!v}'"; done
    [[ "$DUST" != "0" ]] || die "SMOKE_STAKE_AMOUNT must be > 0 (fastStake reverts on zero)"
    [[ "$STAKE_TOKEN" == native || "$STAKE_TOKEN" == weth ]] || die "SMOKE_STAKE_TOKEN must be native|weth, got '$STAKE_TOKEN'"

    if [[ "${SMOKE_CONFIRM:-}" == "yes" ]]; then MODE="EXECUTE (moves real funds)"; else MODE="DRY RUN (set SMOKE_CONFIRM=yes to execute)"; fi
    echo "===================================================================="
    echo "SMOKE-STAKE (live canary): $L2_NETWORK    [$MODE]"
    echo "  RPC URL:        $L2_RPC_URL"
    echo "  Signer:         $SIGNER"
    echo "  New OraclePool: $POOL"
    echo "  CustomSender:   $SENDER"
    echo "  WETH:           $WETH"
    echo "  wstETH:         $WSTETH"
    if [[ "$SEED" == "0" ]]; then
      echo "  Seed wstETH:    0 (STAKE-ONLY — pool must already hold liquidity)"
    else
      echo "  Seed wstETH:    $SEED wei (~ $(cast from-wei "$SEED") wstETH)"
    fi
    echo "  Dust stake:     $DUST wei (~ $(cast from-wei "$DUST") ETH) via $STAKE_TOKEN"
    echo "  Min amount out: $MIN_OUT wei"
    echo "===================================================================="

    nonzero_addr "$POOL"   || die "new OraclePool unresolved — set L2_ORACLE_POOL or populate l2OraclePool in $sm_deployed (got '$POOL')"
    nonzero_addr "$SENDER" || die "CustomSender unresolved — set L2_CUSTOM_SENDER or populate l2CustomSender in $sm_inputs (got '$SENDER')"
    is_addr "$WETH"   || die "l2Weth unresolved from $sm_inputs"
    is_addr "$WSTETH" || die "l2Wsteth unresolved from $sm_inputs"
    is_uint "$EXPECTED_CHAIN_ID" || die "l2ChainId unresolved from $sm_inputs"

    # ── [1/4] Live, not a stale fork ──
    echo "[1/4] CHECK chain-id + head freshness (live, not a stale fork)"
    actual_chain_id="$(parse_num "$(cast chain-id --rpc-url "$L2_RPC_URL")")"
    [[ "$actual_chain_id" == "$EXPECTED_CHAIN_ID" ]] || die "chain-id mismatch: got $actual_chain_id, expected $EXPECTED_CHAIN_ID for $L2_NETWORK"
    head_ts="$(parse_num "$(cast block latest --field timestamp --rpc-url "$L2_RPC_URL")")"
    head_age=$(( $(date +%s) - head_ts ))
    (( head_age <= 600 )) || die "RPC head block is ${head_age}s old — looks like a stale fork or lagging node, not live $L2_NETWORK (check \$${_rpc_var})"
    echo "      PASS chain-id=$actual_chain_id (head ${head_age}s old)"

    # ── [2/4] Migration done: sender points at the NEW pool ──
    echo "[2/4] CHECK CustomSender.getOraclePool() == new pool (activate done)"
    live_pool="$(parse_num "$(cast call "$SENDER" 'getOraclePool()(address)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
    is_addr "$live_pool" || die "CustomSender.getOraclePool() unreadable at $SENDER (wrong sender address / RPC?)"
    if ! eqa "$live_pool" "$POOL"; then
      if is_addr "$OLD_POOL" && eqa "$live_pool" "$OLD_POOL"; then
        die "CustomSender still points at the OLD pool ($live_pool) — run activate first (fastStake would hit the old pool)"
      fi
      die "CustomSender.getOraclePool()=$live_pool != target new pool $POOL — refusing (would seed one pool, stake into another)"
    fi
    echo "      PASS sender -> new pool $POOL"

    # ── [3/4] Pool sanity ──
    echo "[3/4] CHECK new pool immutables + not paused"
    p_in="$(parse_num "$(cast call "$POOL" 'TOKEN_IN()(address)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
    p_out="$(parse_num "$(cast call "$POOL" 'TOKEN_OUT()(address)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
    p_sender="$(parse_num "$(cast call "$POOL" 'SENDER()(address)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
    p_paused="$(parse_num "$(cast call "$POOL" 'paused()(bool)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
    p_fee="$(parse_num "$(cast call "$POOL" 'getFee()(uint96)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
    is_uint "$p_fee" || p_fee=0
    eqa "$p_in"  "$WETH"   || die "pool.TOKEN_IN()=$p_in != l2Weth $WETH"
    eqa "$p_out" "$WSTETH" || die "pool.TOKEN_OUT()=$p_out != l2Wsteth $WSTETH"
    eqa "$p_sender" "$SENDER" || die "pool.SENDER()=$p_sender != $SENDER"
    [[ "$p_paused" == "false" ]] || die "pool is paused (paused()=$p_paused) — swap is whenNotPaused; unpause before the canary"
    echo "      PASS TOKEN_IN=WETH, TOKEN_OUT=wstETH, SENDER ok, paused=false, fee=$p_fee (PRECISION 1e18)"

    # Pre-seed pool snapshot (also confirms the pool balances are readable; the wstETH reserve
    # doubles as the liquidity source checked in stake-only mode).
    pool_wst0="$(rdcall "$WSTETH" 'balanceOf(address)(uint256)' "$POOL")"
    pool_weth0="$(rdcall "$WETH" 'balanceOf(address)(uint256)' "$POOL")"

    # ── [4/4] Signer funded + seed (or existing pool reserve) covers the expected output ──
    echo "[4/4] CHECK signer balances + expected output"
    sig_wst="$(rdcall "$WSTETH" 'balanceOf(address)(uint256)' "$SIGNER")"
    sig_eth="$(parse_num "$(cast balance "$SIGNER" --rpc-url "$L2_RPC_URL" 2>/dev/null || echo 0)")"
    is_uint "$sig_eth" || sig_eth=0
    # expected fastStake output (matches OraclePool.swap, integer math): (dust - dust*fee/1e18) * 1e18 / price
    oracle="$(parse_num "$(cast call "$POOL" 'getOracle()(address)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
    price=""; expected_out=""
    if is_addr "$oracle"; then
      price="$(parse_num "$(cast call "$oracle" 'getLatestAnswer()(uint256)' --rpc-url "$L2_RPC_URL" 2>/dev/null || true)")"
      if is_uint "$price" && [[ "$price" != "0" ]]; then
        expected_out="$(echo "( $DUST - $DUST * $p_fee / 1000000000000000000 ) * 1000000000000000000 / $price" | bc)"
      fi
    fi
    echo "      INFO signer wstETH=$sig_wst wei (~ $(cast from-wei "$sig_wst")); native ETH=$sig_eth wei (~ $(cast from-wei "$sig_eth"))"
    if [[ -n "$expected_out" ]]; then echo "      INFO oracle=$oracle price=$price -> expected out ~ $expected_out wei (~ $(cast from-wei "$expected_out") wstETH)"; else echo "      WARN oracle price unreadable; expected-output check skipped (verification still uses the measured delta)"; fi
    if [[ "$SEED" == "0" ]]; then
      # Stake-only: no seed tx, so the pool's LIVE reserve must cover the output — and with no seed
      # as guaranteed headroom, an unreadable oracle price is a hard stop here, not a warning.
      [[ -n "$expected_out" ]] || die "stake-only mode (SMOKE_SEED_WSTETH=0) needs a readable oracle price to size the expected output — aborting"
      echo "      INFO pool wstETH reserve=$pool_wst0 wei (~ $(cast from-wei "$pool_wst0")) [stake-only: no seed]"
      ge "$pool_wst0" "$expected_out" || die "pool wstETH reserve $pool_wst0 < expected output $expected_out — swap would revert OraclePoolInsufficientTokenOut; seed the pool (SMOKE_SEED_WSTETH>0) or lower SMOKE_STAKE_AMOUNT"
    else
      ge "$sig_wst" "$SEED" || die "signer wstETH $sig_wst < seed $SEED — acquire a little wstETH on $L2_NETWORK first (or SMOKE_SEED_WSTETH=0 to stake against existing pool liquidity)"
      if [[ -n "$expected_out" ]]; then ge "$SEED" "$expected_out" || die "seed $SEED < expected output $expected_out — raise SMOKE_SEED_WSTETH (swap would revert OraclePoolInsufficientTokenOut)"; fi
    fi
    if [[ "$STAKE_TOKEN" == native ]]; then
      ge "$sig_eth" "$(echo "$DUST + $GAS_BUFFER" | bc)" || die "signer native ETH $sig_eth < dust $DUST + gas buffer $GAS_BUFFER — top up (or lower SMOKE_GAS_BUFFER)"
    else
      ge "$sig_eth" "$GAS_BUFFER" || die "signer native ETH $sig_eth < gas buffer $GAS_BUFFER — top up for gas"
      sig_weth="$(rdcall "$WETH" 'balanceOf(address)(uint256)' "$SIGNER")"
      ge "$sig_weth" "$DUST" || die "SMOKE_STAKE_TOKEN=weth but signer WETH $sig_weth < dust $DUST — wrap some ETH->WETH or use native"
      echo "      INFO signer WETH=$sig_weth wei (~ $(cast from-wei "$sig_weth"))"
    fi
    if [[ "$SEED" == "0" ]]; then
      echo "      PASS signer funded (dust + gas) + pool reserve covers the output"
    else
      echo "      PASS signer funded (seed + dust + gas covered)"
    fi

    if [[ "${SMOKE_CONFIRM:-}" != "yes" ]]; then
      echo "===================================================================="
      echo "DRY RUN OK — all preconditions passed; no funds moved."
      echo "  Re-run to EXECUTE:  SMOKE_CONFIRM=yes just -E .env.$L2_NETWORK smoke-stake"
      if [[ "$SEED" == "0" ]]; then
        echo "  Would (1) skip the seed (stake-only — pool reserve $pool_wst0 wei wstETH covers the output)"
      else
        echo "  Would (1) transfer $SEED wei wstETH -> pool $POOL"
      fi
      echo "        (2) fastStake $DUST wei via $STAKE_TOKEN, expecting ~ ${expected_out:-?} wei wstETH to $SIGNER"
      echo "===================================================================="
      exit 0
    fi

    # ── EXECUTE (SMOKE_CONFIRM=yes) ──
    echo "EXECUTE — moving funds"
    SEND=(cast send --rpc-url "$L2_RPC_URL" --private-key "$L2_SMOKE_PRIVATE_KEY" --json)

    if [[ "$SEED" == "0" ]]; then
      seed_tx="(skipped)"
      pool_wst1="$pool_wst0"
      echo "  -> seed: skipped (SMOKE_SEED_WSTETH=0 — staking against existing pool reserve $pool_wst0 wei)"
    else
      echo "  -> seed: wstETH.transfer($POOL, $SEED)"
      seed_rcpt="$("${SEND[@]}" "$WSTETH" 'transfer(address,uint256)' "$POOL" "$SEED")" || die "seed transfer failed"
      seed_tx="$(printf '%s' "$seed_rcpt" | jq -r '.transactionHash')"
      [[ "$(printf '%s' "$seed_rcpt" | jq -r '.status')" == "0x1" ]] || die "seed tx reverted ($seed_tx)"
      pool_wst1="$(rdcall "$WSTETH" 'balanceOf(address)(uint256)' "$POOL")"
      [[ "$pool_wst1" == "$(echo "$pool_wst0 + $SEED" | bc)" ]] || die "pool wstETH after seed = $pool_wst1, expected $(echo "$pool_wst0 + $SEED" | bc) (tx $seed_tx)"
      echo "     seeded: tx=$seed_tx ; pool wstETH $pool_wst0 -> $pool_wst1"
    fi

    # Window start: staker wstETH immediately before the stake tx (= after seed).
    staker_before="$(rdcall "$WSTETH" 'balanceOf(address)(uint256)' "$SIGNER")"

    echo "  -> stake: CustomSender.fastStake($STAKE_TOKEN, $DUST, $MIN_OUT)"
    if [[ "$STAKE_TOKEN" == native ]]; then
      stake_rcpt="$("${SEND[@]}" --value "$DUST" "$SENDER" 'fastStake(address,uint256,uint256)' '0x0000000000000000000000000000000000000000' "$DUST" "$MIN_OUT")" || die "fastStake (native) failed"
    else
      echo "     approve: WETH.approve($SENDER, $DUST)"
      ap_rcpt="$("${SEND[@]}" "$WETH" 'approve(address,uint256)' "$SENDER" "$DUST")" || die "WETH approve failed"
      [[ "$(printf '%s' "$ap_rcpt" | jq -r '.status')" == "0x1" ]] || die "approve reverted"
      stake_rcpt="$("${SEND[@]}" "$SENDER" 'fastStake(address,uint256,uint256)' "$WETH" "$DUST" "$MIN_OUT")" || die "fastStake (weth) failed"
    fi
    stake_tx="$(printf '%s' "$stake_rcpt" | jq -r '.transactionHash')"
    [[ "$(printf '%s' "$stake_rcpt" | jq -r '.status')" == "0x1" ]] || die "fastStake tx reverted ($stake_tx)"

    # ── Verify by observation ──
    staker_after="$(rdcall "$WSTETH" 'balanceOf(address)(uint256)' "$SIGNER")"
    pool_wst2="$(rdcall "$WSTETH" 'balanceOf(address)(uint256)' "$POOL")"
    pool_weth2="$(rdcall "$WETH" 'balanceOf(address)(uint256)' "$POOL")"
    delta="$(echo "$staker_after - $staker_before" | bc)"

    # Corroborate against the FastStake event amountOut (2nd data word); not load-bearing.
    ft_topic="$(cast keccak 'FastStake(address,address,uint256,uint256)')"
    ev_data="$(printf '%s' "$stake_rcpt" | jq -r --arg t "$(lc "$ft_topic")" --arg a "$(lc "$SENDER")" 'first(.logs[] | select((.address|ascii_downcase)==$a and (.topics[0]|ascii_downcase)==$t) | .data) // empty' 2>/dev/null || true)"
    ev_out=""
    if [[ "$ev_data" =~ ^0x[0-9a-fA-F]+$ ]]; then d="${ev_data#0x}"; [[ ${#d} -ge 128 ]] && ev_out="$(cast to-dec "0x${d:64:64}")"; fi

    echo "     delta(staker wstETH) = $delta wei (~ $(cast from-wei "$delta"))   [tx $stake_tx]"
    [[ "$(echo "$delta > 0" | bc)" == "1" ]] || die "staker wstETH delta = $delta (expected > 0) — fastStake delivered nothing"
    if [[ -n "$ev_out" ]]; then
      [[ "$ev_out" == "$delta" ]] || die "FastStake.amountOut=$ev_out != measured staker delta=$delta"
      echo "     OK FastStake.amountOut == measured delta = $delta"
    else
      echo "     WARN could not decode FastStake event amountOut; relying on the measured balance delta"
    fi
    want_wst="$(echo "$pool_wst1 - $delta" | bc)"
    want_weth="$(echo "$pool_weth0 + $DUST" | bc)"
    [[ "$pool_wst2" == "$want_wst" ]]   || die "pool wstETH after = $pool_wst2, expected $want_wst (before+seed-out)"
    [[ "$pool_weth2" == "$want_weth" ]] || die "pool WETH after = $pool_weth2, expected $want_weth (before+dust)"

    echo "===================================================================="
    echo "OK SMOKE-STAKE PASSED — $L2_NETWORK"
    echo "  staker $SIGNER received $delta wei wstETH (~ $(cast from-wei "$delta"))"
    if [[ "$SEED" == "0" ]]; then
      echo "  seed tx:     (skipped — stake-only against existing pool reserve)"
    else
      echo "  seed tx:     $seed_tx   (+$SEED wei wstETH -> pool)"
    fi
    echo "  stake tx:    $stake_tx   ($DUST wei $STAKE_TOKEN -> fastStake)"
    if [[ "$SEED" == "0" ]]; then
      echo "  pool wstETH: $pool_wst0 -> $pool_wst2 (after stake)"
    else
      echo "  pool wstETH: $pool_wst0 -> $pool_wst1 (seed) -> $pool_wst2 (after stake)"
    fi
    echo "  pool WETH:   $pool_weth0 -> $pool_weth2 (+$DUST)"
    [[ -n "$price" ]] && echo "  oracle price: $price (expected out ~ ${expected_out:-?} wei)"
    echo "===================================================================="

# Verify each lane's pinned CRE Keystone forwarder is the ERC-165-gating, 2-arg-`onReport` "Router"
# build that `CREReceiver` speaks — the load-bearing external assumption of the whole CRE→sync path.
#
# WHY NOT typeAndVersion: the live forwarders report the STALE label "KeystoneForwarder 1.0.0" even
# though their bytecode is the newer Forwarder-and-Router build (the vendored CCIP copy of that same
# code is labelled "Forwarder and Router 1.0.0"). The version STRING is therefore NOT a safe
# discriminator — do NOT gate on it (an operator who rejected "KeystoneForwarder 1.0.0" would reject
# the CORRECT live forwarder). The real test is bytecode identity (EXTCODEHASH) + the Router ABI
# fingerprint:
#   • isForwarder(address)                    — present only in the Router build
#   • getTransmitter(address,bytes32,bytes2)  — Router 3-arg form (present)
#   • getTransmitter(address,bytes32)         — legacy 2-arg form; MUST revert (absent)
# The Router build's only delivery path is abi.encodeCall(IReceiver.onReport,(metadata,report)) (the
# 2-arg onReport) behind ERC165Checker.supportsInterface(receiver, 0x805f2132). The legacy variant
# instead calls onReport(bytes32,address,bytes) with NO ERC-165 gate → our receiver would never be
# invoked and sync would silently never fire. Known-good EXTCODEHASH (all 4 lanes, verified 2026-06-19):
#   0x2b21870eb5ea9013a781ed3db7d5fab742b612b2ac8de0990ac9d95b22f795fc
# Forwarder addresses come from config/state/<net>.inputs.yaml (l2CreForwarder anchor); the optional
# receiver cross-check reads l2CreReceiver from .deployed.yaml. Needs RPC_<NET> (or legacy
# L2_<NET>_RPC_URL). Read-only.
# Verify each lane's pinned CRE forwarder is the ERC-165-gating 2-arg-onReport Router build (read-only, 4 lanes).
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

    # `cast call` probe with transport-error retries. Sets REPLY_STATUS ∈ {ok,revert,rpcerr} + REPLY_OUT.
    # Crucially distinguishes a genuine EVM revert (selector absent / reverts — a REAL answer) from a
    # flaky-RPC transport error (retried, then surfaced as "unverified" rather than a false absent/mismatch
    # — a spurious "legacy forwarder detected!" on a 500 would be exactly the false signal we're killing).
    probe () {
      local url="$1"; shift
      local attempt out
      for attempt in 1 2 3 4; do
        if out="$(cast call "$@" --rpc-url "$url" 2>&1)"; then REPLY_STATUS=ok; REPLY_OUT="$out"; return; fi
        # Classify the failure. Transport/server errors are matched FIRST and retried — even if their body
        # happens to contain the substring "revert" (a 5xx page, proxy error, or timeout), so a flaky RPC
        # is never mis-read as a genuine EVM answer (the spurious "legacy detected!" on a 500 we are
        # killing). Only a clean execution-revert with NO transport marker is a real "selector absent /
        # reverts" answer. (Safe here because the probed selectors revert with a bare "execution reverted",
        # never a message carrying a transport phrase.)
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
      if [[ -z "$rpc_val" ]]; then echo "  (skipped — set ${rpc_env} or legacy ${l2_env})"; rc=1; continue; fi
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

# WHY THIS GATE EXISTS: the LOL multisig is ONE Safe address on all four L2s (2026-07 unification;
# per-lane constants LIQUIDITY_OWNER == the l2LiquidityOwner anchor). "Same address on every chain"
# is four independent per-chain claims, not one fact: an address string proves nothing about a given
# chain — the Safe must be DEPLOYED there (code present), must answer as a Safe (getOwners /
# getThreshold), and the four instances must hold the SAME signer set + threshold (deterministic
# deploys create them alike, but each chain's instance is mutated independently and can diverge —
# already today the owner LIST order differs between lanes, which is benign; the SET must not).
# WHY IT MATTERS: `handoff` transferOwnership()s pool + SyncTrigger + CREReceiver to this address
# ONE-WAY, and no on-chain check requires the target to have code (during the canary the legitimate
# owner IS a code-less EOA — the deployer). A handoff on a lane where the Safe was never deployed
# permanently bricks admin + sweep there (the RUNBOOK §Sunset "drain before renounce" failure mode;
# the classic multichain-Safe loss class). Run once before the FIRST handoff; idempotent, re-run freely.
# The LOL address comes from the effective common + lane inputs (l2LiquidityOwner anchor; the recipe
# also asserts all four lanes resolve to ONE address — constants↔yaml drift is verify-constants-sync's
# job). RPC per lane: RPC_<NET>, falling back to RPC_<NET>_REMOTE, then legacy L2_<NET>_RPC_URL
# (each candidate is probed — the local proxies are often down). Read-only, no keys.
# Verify the unified LOL Safe is deployed on all 4 lanes with one signer set + threshold (read-only).
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
    echo "Resolved from l2.common.inputs.yaml + config/state/<net>.inputs.yaml (l2LiquidityOwner):"
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

      # 1) deployed — the one property that stops a bricking handoff
      code="$(cast code "$LOL" --rpc-url "$rpc_val" 2>/dev/null | tr -d '\r')"
      if [[ -z "$code" ]]; then
        echo "  ⚠ code unverified (RPC error)"; unver=1
      elif [[ "$code" == "0x" ]]; then
        echo "  ✗ NO CODE at ${LOL} on this lane — a handoff here would BRICK pool/trigger/receiver admin + sweep"; pass=0
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
_optimism-state-migrate rpc_url='':
    #!/usr/bin/env bash
    set -euo pipefail

    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    RPC_URL="{{rpc_url}}"
    DEFAULT_RPC_URL="${L2_STATE_MATE_RPC_URL:-${L2_RPC_URL:-${LOCAL_L2_OPTIMISM_RPC_URL:-${L2_OPTIMISM_RPC_URL:-}}}}"
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
      die "Missing RPC URL: pass [rpc_url], or set L2_RPC_URL in .env.optimism (L2_STATE_MATE_RPC_URL / LOCAL_L2_OPTIMISM_RPC_URL / L2_OPTIMISM_RPC_URL are also honoured)."
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
    # Governance executor is pinned in the constants contract, never read from .env.
    L2_GOVERNANCE_EXECUTOR="$(grep -E 'LIDO_L2_GOVERNANCE_EXECUTOR' "$ROOT_DIR/script/optimism/OptimismMigrationConstants.sol" | grep -Eo '0x[0-9a-fA-F]{40}' | head -n1)"
    [[ -n "$L2_GOVERNANCE_EXECUTOR" ]] || die "could not read LIDO_L2_GOVERNANCE_EXECUTOR from OptimismMigrationConstants.sol"

    RPC_URL="$(resolve_rpc_url)"
    L2_LIQUIDITY_OWNER_RESOLVED="${L2_LIQUIDITY_OWNER:-$L2_GOVERNANCE_EXECUTOR}"

    # Initial-Owner-actor steps (activate, finalize): sign with the cold key when present, else
    # impersonate on anvil. Deployer-actor steps (deploy-test, handoff) always sign with the deployer key.
    OWNER_KEY="${INITIAL_OWNER_PRIVATE_KEY:-${L2_INITIAL_OWNER_PRIVATE_KEY:-}}"
    if [[ -n "$OWNER_KEY" ]]; then
      INITIAL_OWNER_ADDRESS="$(address_from_private_key "$OWNER_KEY")"
      ACTIVATE_SIG="runActivate()"; FINALIZE_SIG="runFinalize()"
      OWNER_FORGE_ARGS=()
    else
      INITIAL_OWNER_ADDRESS="${INITIAL_OWNER:-${L2_INITIAL_OWNER:-$INITIAL_OWNER_DEFAULT}}"
      ACTIVATE_SIG="runActivateUnlocked()"; FINALIZE_SIG="runFinalizeUnlocked()"
      OWNER_FORGE_ARGS=(--unlocked --sender "$INITIAL_OWNER_ADDRESS")
    fi
    export INITIAL_OWNER="$INITIAL_OWNER_ADDRESS"

    L2_LIDO_DEPLOYER_ADDRESS="$(address_from_private_key "$L2_LIDO_DEPLOYER_PRIVATE_KEY")"
    cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$INITIAL_OWNER_ADDRESS" "$ANVIL_SIGNER_BALANCE_HEX" >/dev/null 2>&1 || true
    cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$L2_LIDO_DEPLOYER_ADDRESS" "$ANVIL_SIGNER_BALANCE_HEX" >/dev/null 2>&1 || true

    if [[ ${#OWNER_FORGE_ARGS[@]} -gt 0 ]]; then
      cast rpc --rpc-url "$RPC_URL" anvil_impersonateAccount "$INITIAL_OWNER_ADDRESS" >/dev/null 2>&1 \
        || die "Impersonating the Initial Owner requires an anvil-compatible RPC. Set INITIAL_OWNER_PRIVATE_KEY for arbitrary RPC endpoints."
    fi

    SCRIPT="script/optimism/OptimismL2Upgrade.s.sol:OptimismL2UpgradeScript"
    script_base="$(basename "${SCRIPT%:*}")"
    chain_id="$(cast chain-id --rpc-url "$RPC_URL" | tr -d '\r\n')"

    echo "Running OptimismL2UpgradeScript canary migration on ${RPC_URL}"
    # Canary state machine: deploy-test → activate → handoff → finalize (the production recipe sequence).
    # The deployer signs deploy-test + handoff; the Initial Owner (cold key or impersonated) signs
    # activate + finalize. No combined run() — there is no combined-run guard left to opt out of.
    ( cd "$ROOT_DIR"; forge script "$SCRIPT" --sig "runDeployTest()" --rpc-url "$RPC_URL" --broadcast --non-interactive )

    bcast="$ROOT_DIR/broadcast/${script_base}/${chain_id}/runDeployTest-latest.json"
    [[ -f "$bcast" ]] || die "Missing broadcast JSON: $bcast"
    ORACLE_POOL_ADDRESS="$(cast to-check-sum-address "$(jq -r '[.transactions[]|select(.contractName=="PausableImmutableOraclePool")][0].contractAddress' "$bcast")")"
    SYNC_TRIGGER_ADDRESS="$(cast to-check-sum-address "$(jq -r '[.transactions[]|select(.contractName=="SyncTrigger")][0].contractAddress' "$bcast")")"
    CRE_RECEIVER_ADDRESS="$(cast to-check-sum-address "$(jq -r '[.transactions[]|select(.contractName=="CREReceiver")][0].contractAddress' "$bcast")")"
    # Export for the activate/handoff/finalize steps, which read the addresses from env.
    export L2_ORACLE_POOL="$ORACLE_POOL_ADDRESS" L2_SYNC_TRIGGER="$SYNC_TRIGGER_ADDRESS" L2_CRE_RECEIVER="$CRE_RECEIVER_ADDRESS"

    ( cd "$ROOT_DIR"; forge script "$SCRIPT" --sig "$ACTIVATE_SIG" --rpc-url "$RPC_URL" --broadcast --non-interactive "${OWNER_FORGE_ARGS[@]}" )
    ( cd "$ROOT_DIR"; forge script "$SCRIPT" --sig "runHandoff()" --rpc-url "$RPC_URL" --broadcast --non-interactive )
    ( cd "$ROOT_DIR"; forge script "$SCRIPT" --sig "$FINALIZE_SIG" --rpc-url "$RPC_URL" --broadcast --non-interactive "${OWNER_FORGE_ARGS[@]}" )

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
    DEFAULT_RPC_URL="${L2_STATE_MATE_RPC_URL:-${L2_RPC_URL:-${LOCAL_L2_OPTIMISM_RPC_URL:-${L2_OPTIMISM_RPC_URL:-}}}}"
    STATE_MATE_OUTPUT_FILE="${L2_STATE_MATE_OUTPUT_FILE:-${TMPDIR:-/tmp}/optimism-l2-state-mate.env}"
    STATE_MATE_DEPLOYED="$ROOT_DIR/config/state/optimism.deployed.yaml"
    STATE_MATE_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/optimism-l2-state-config.XXXXXX")"
    L2_CUSTOM_SENDER="${L2_STATE_MATE_CUSTOM_SENDER:-0x328de900860816d29D1367F6903a24D8ed40C997}" # only to derive the new OraclePool live
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
    # Governance executor is pinned in the constants contract, never read from .env.
    L2_GOVERNANCE_EXECUTOR="$(grep -E 'LIDO_L2_GOVERNANCE_EXECUTOR' "$ROOT_DIR/script/optimism/OptimismMigrationConstants.sol" | grep -Eo '0x[0-9a-fA-F]{40}' | head -n1)"
    [[ -n "$L2_GOVERNANCE_EXECUTOR" ]] || die "could not read LIDO_L2_GOVERNANCE_EXECUTOR from OptimismMigrationConstants.sol"

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

    # The .deployed.yaml holds only the three freshly-deployed contracts; the pre-existing CustomSender
    # proxy/impl + ProxyAdmin are externals in optimism.inputs.yaml (no slot read needed here).
    bash "$ROOT_DIR/script/shared/write-deployed-yaml.sh" "$STATE_MATE_DEPLOYED" \
      "$ORACLE_POOL_ADDRESS" "$SYNC_TRIGGER_ADDRESS" "$CRE_RECEIVER_ADDRESS"
    echo "Regenerated state-mate .deployed sibling: ${STATE_MATE_DEPLOYED} (rpc: ${RPC_URL})"

[private]
_state-verify network rpc_url='':
    #!/usr/bin/env bash
    set -euo pipefail

    NETWORK="{{network}}"
    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    source "$ROOT_DIR/script/shared/cre-env.sh"
    cre_env_load_secrets
    L1_STATE_MATE_RPC_URL="$(resolve_l1_rpc)"
    RPC_URL="{{rpc_url}}"

    # Map network name to default RPC env var.
    # Priority: positional [rpc_url] > L2_RPC_URL (from .env.<net>) > legacy fallbacks.
    case "$NETWORK" in
      optimism) DEFAULT_RPC_URL="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_OPTIMISM_RPC_URL:-${L2_OPTIMISM_RPC_URL:-}}}}" ;;
      arbitrum) DEFAULT_RPC_URL="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_ARBITRUM_RPC_URL:-${L2_ARBITRUM_RPC_URL:-}}}}" ;;
      base)     DEFAULT_RPC_URL="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_BASE_RPC_URL:-${L2_BASE_RPC_URL:-}}}}" ;;
      linea)    DEFAULT_RPC_URL="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${LOCAL_L2_LINEA_RPC_URL:-${L2_LINEA_RPC_URL:-}}}}" ;;
      *)        echo "Unknown network: $NETWORK" >&2; exit 1 ;;
    esac

    STATE_MATE_OUTPUT_FILE="${L2_STATE_MATE_OUTPUT_FILE:-${TMPDIR:-/tmp}/${NETWORK}-l2-state-mate.env}"
    STATE_MATE_DIR="$ROOT_DIR/lib/state-mate"
    # All four mainnet L2 lanes share one wiring file plus one common input file; each run adds its
    # lane input delta and deployed sibling explicitly. Absolute paths, since the runner cd's into
    # lib/state-mate.
    STATE_MATE_CONFIG="$ROOT_DIR/config/state/l2.yaml"
    STATE_MATE_SIBLING_ARGS=(
      --inputs   "$ROOT_DIR/config/state/l2.common.inputs.yaml"
      --inputs   "$ROOT_DIR/config/state/$NETWORK.inputs.yaml"
      --deployed "$ROOT_DIR/config/state/$NETWORK.deployed.yaml"
    )
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
    echo "Running combined L1 + L2 state-mate checks for $NETWORK"
    # Echo the exact invocation (cwd + argv) so an operator can replay/audit the run by hand.
    echo "+ cd $STATE_MATE_DIR"
    echo "+ L1_RPC_URL=<ethereum-rpc> L2_STATE_MATE_RPC_URL=$RPC_URL ${YARN_CMD[*]} start $STATE_MATE_CONFIG ${STATE_MATE_SIBLING_ARGS[*]+${STATE_MATE_SIBLING_ARGS[*]}}"

    set +e
    (
      cd "$STATE_MATE_DIR"
      env -u NO_COLOR L1_RPC_URL="$L1_STATE_MATE_RPC_URL" L2_STATE_MATE_RPC_URL="$RPC_URL" \
        FORCE_COLOR=3 CLICOLOR_FORCE=1 "${YARN_CMD[@]}" start "$STATE_MATE_CONFIG" \
        "${STATE_MATE_SIBLING_ARGS[@]+"${STATE_MATE_SIBLING_ARGS[@]}"}"
    ) 2>&1 | tee "$STATE_MATE_LOG"
    STATE_MATE_EXIT="${PIPESTATUS[0]}"
    set -e

    echo ""
    echo "----- state-mate full output -----"
    perl -pe 's/\r/\n/g' "$STATE_MATE_LOG"
    echo "----- end state-mate output -----"

    # NB: a failing wiring run does NOT abort here — every remaining config run still executes, so one
    # invocation reports the COMPLETE picture (a partial pass is the false-pass hazard). Exits are
    # accumulated and re-raised at the very end.
    if [[ "$STATE_MATE_EXIT" -eq 0 ]]; then
      echo "$NETWORK state verification passed"
    else
      echo "state-mate checks FAILED for $NETWORK (continuing with the remaining runs)" >&2
    fi

    # Linea alone had an additional Gelato automation. The retired CRE pair is now part of the shared
    # l2.yaml run for every lane; only this genuinely Linea-specific assertion remains separate.
    GELATO_EXIT=0
    GELATO_CONFIG=""
    [[ "$NETWORK" == "linea" ]] && GELATO_CONFIG="config/state/l2-linea-gelato.yaml"
    if [[ -n "$GELATO_CONFIG" ]]; then
      echo "Running Linea Gelato de-role check against ${RPC_URL}"
      echo "+ cd $STATE_MATE_DIR"
      echo "+ L2_STATE_MATE_RPC_URL=$RPC_URL ${YARN_CMD[*]} start $ROOT_DIR/$GELATO_CONFIG --only l2"
      set +e
      (
        cd "$STATE_MATE_DIR"
        env -u NO_COLOR L2_STATE_MATE_RPC_URL="$RPC_URL" FORCE_COLOR=3 CLICOLOR_FORCE=1 \
          "${YARN_CMD[@]}" start "$ROOT_DIR/$GELATO_CONFIG" --only "l2"
      ) 2>&1 | tee -a "$STATE_MATE_LOG"
      GELATO_EXIT="${PIPESTATUS[0]}"
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

# ──────────────────────────────────────────────────────────────────
# Optimism acceptance test: full migration + state-mate + forge tests
#
# Same recipes work for:
#   - Local fork testing:  just test-optimism-acceptance
#   - Live network:        just test-optimism-upgrade-state-migrate $RPC ...
#
# Env vars (all optional for the fork-based acceptance test):
#   L2_LIDO_DEPLOYER_PRIVATE_KEY  — deployer key (generated if missing on Anvil)
#   RPC_ETHEREUM / RPC_OPTIMISM / RPC_ARBITRUM / RPC_BASE / RPC_LINEA — upstream RPCs for forking
#   (The governance executor is pinned per network in code; the recipe's NET_GOVS array mirrors it.)
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
    # CustomSender proxy/impl + ProxyAdmin are pre-existing externals (in each <net>.inputs.yaml) and
    # exist in forked state, so the fork .deployed.yaml no longer carries them — no NET_SENDERS/IMPLS/PROXIES.
    NET_LOLS=(     0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6 0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6 0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6 0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6)
    NET_COUNT=${#NET_NAMES[@]}

    die() { echo "FAIL: $*" >&2; exit 1; }

    # Validate parallel arrays have consistent length
    for arr_name in NET_RPC_ENVS NET_RPC_ENVS_LEGACY NET_GOVS NET_SCRIPTS NET_TESTS NET_LOLS; do
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

      # Canary state machine: deploy-test → activate → handoff → finalize, mirroring the production
      # recipe sequence. Each step is a separate broadcast by its real actor — the deployer signs
      # deploy-test + handoff (its key is exported), and INITIAL_OWNER (auto-impersonated on the fork)
      # signs activate + finalize. The deployer-owned canary deploys with the test delay/min-amount;
      # handoff restores production config + transfers to the LOL multisig, and finalize performs the
      # irreversible governance seal — reaching the same sealed production state the Step-3 state-mate
      # (production profile) expects. The simulated CRE sync is exercised by the Step-4 forge suites
      # and the standalone `simulate-sync` recipe, not re-driven here.
      # The CRE Forwarder is pinned per network in code (see _expectedCREForwarder), so no
      # L2_CRE_FORWARDER env is needed; the real forwarder isn't exercised here anyway because CRE
      # reports would need the actual off-chain DON to originate.
      script_file="${NET_SCRIPTS[$i]%:*}"
      script_base="$(basename "$script_file")"
      chain_id="$(cast chain-id --rpc-url "$fork_url" | tr -d '\r\n')"
      export INITIAL_OWNER

      substep "0→1: deploy-test (deployer-owned canary)"
      ( cd "$ROOT_DIR"
        forge script "${NET_SCRIPTS[$i]}" --sig "runDeployTest()" \
          --rpc-url "$fork_url" --broadcast --non-interactive 2>&1 | tail -5 )

      # Read the actual deployed addresses from the runDeployTest broadcast JSON (robust against nonce
      # shifts) and export them for the activate/handoff/finalize steps, which read them from env.
      bcast_json="$ROOT_DIR/broadcast/${script_base}/${chain_id}/runDeployTest-latest.json"
      [[ -f "$bcast_json" ]] || die "Missing forge broadcast JSON: $bcast_json"
      pool_addr="$(jq -r '[.transactions[] | select(.contractName == "PausableImmutableOraclePool")][0].contractAddress' "$bcast_json")"
      trigger_addr="$(jq -r '[.transactions[] | select(.contractName == "SyncTrigger")][0].contractAddress' "$bcast_json")"
      recv_addr="$(jq -r '[.transactions[] | select(.contractName == "CREReceiver")][0].contractAddress' "$bcast_json")"
      pool_addr="$(cast to-check-sum-address "$pool_addr")"
      trigger_addr="$(cast to-check-sum-address "$trigger_addr")"
      recv_addr="$(cast to-check-sum-address "$recv_addr")"
      export L2_ORACLE_POOL="$pool_addr" L2_SYNC_TRIGGER="$trigger_addr" L2_CRE_RECEIVER="$recv_addr"

      substep "0→1: activate (INITIAL_OWNER repoints pool + grants SYNC_ROLE)"
      ( cd "$ROOT_DIR"
        forge script "${NET_SCRIPTS[$i]}" --sig "runActivateUnlocked()" \
          --rpc-url "$fork_url" --broadcast --non-interactive \
          --unlocked --sender "$INITIAL_OWNER" 2>&1 | tail -5 )

      substep "1→2: handoff (restore production config, transfer to LOL multisig)"
      ( cd "$ROOT_DIR"
        forge script "${NET_SCRIPTS[$i]}" --sig "runHandoff()" \
          --rpc-url "$fork_url" --broadcast --non-interactive 2>&1 | tail -5 )

      substep "2→3: finalize (irreversible governance seal)"
      ( cd "$ROOT_DIR"
        forge script "${NET_SCRIPTS[$i]}" --sig "runFinalizeUnlocked()" \
          --rpc-url "$fork_url" --broadcast --non-interactive \
          --unlocked --sender "$INITIAL_OWNER" 2>&1 | tail -5 )

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
      sm_inputs="$ROOT_DIR/config/state/$name.inputs.yaml"
      sm_common_inputs="$ROOT_DIR/config/state/l2.common.inputs.yaml"
      # Fork redeploys of the three fresh contracts land at addresses that differ from the committed
      # (mainnet-expected) ones, so write the fork's ACTUAL pool/trigger/receiver to a throwaway
      # .deployed.yaml and override via --deployed. The common inputs plus static <net>.inputs.yaml
      # need no fork override: the fork inherits those facts and reuses the canonical actors. Both
      # input files MUST be passed explicitly because l2.yaml's basename cannot select a lane.
      # The `l2LidoDeployer` anchor is the REAL mainnet deployer
      # even here: the fork signs with the anvil dev key, but the check is
      # hasRole(DEFAULT_ADMIN_ROLE, deployer)==false on the INHERITED CustomSender proxy, which holds
      # for both EOAs — so no fork-specific override is needed.
      fork_deployed="$WORK_DIR/$name.deployed.yaml"
      workflow_id="$(yq '.. | select(anchor == "creWorkflowId")' "$ROOT_DIR/config/state/$name.deployed.yaml" | tr -d '"' | head -n1)"
      retired_trigger="$(yq '.. | select(anchor == "RETIRED_l2SyncTrigger")' "$ROOT_DIR/config/state/$name.deployed.yaml" | tr -d '"' | head -n1)"
      retired_receiver="$(yq '.. | select(anchor == "RETIRED_l2CreReceiver")' "$ROOT_DIR/config/state/$name.deployed.yaml" | tr -d '"' | head -n1)"
      substep "$name: writing fork .deployed.yaml"
      bash "$ROOT_DIR/script/shared/write-deployed-yaml.sh" "$fork_deployed" \
        "${DEPLOYED_POOLS[$i]}" "${DEPLOYED_TRIGGERS[$i]}" "${DEPLOYED_RECEIVERS[$i]}" \
        "$workflow_id" "$retired_trigger" "$retired_receiver"

      substep "$name: running state-mate checks"
      (
        cd "$STATE_MATE_DIR"
        L1_RPC_URL="$L1_FORK_URL" L2_STATE_MATE_RPC_URL="$fork_url" \
          yarn start "$sm_config" --inputs "$sm_common_inputs" --inputs "$sm_inputs" --deployed "$fork_deployed" 2>&1 | tail -8
      ) || die "$name state-mate failed"
      # Linea-only Gelato de-role — separate config; its static inputs match the fork.
      if [[ "$name" == "linea" ]]; then
        substep "$name: running Linea Gelato de-role state-mate check"
        (
          cd "$STATE_MATE_DIR"
          L2_STATE_MATE_RPC_URL="$fork_url" yarn start "$ROOT_DIR/config/state/l2-linea-gelato.yaml" --only "l2" 2>&1 | tail -8
        ) || die "$name Gelato state-mate failed"
      fi
    done
    echo "All L2 state-mate checks passed"

    substep "L1: running state-mate checks against fork"
    (
      cd "$STATE_MATE_DIR"
      L1_RPC_URL="$L1_FORK_URL" yarn start "$ROOT_DIR/config/state/ethereum.yaml" --only "l1" 2>&1 | tail -12
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

# Regenerate config/state/optimism.deployed.yaml after migration
test-optimism-upgrade-state-update-config rpc_url='':
    @just _optimism-state-update-config "{{rpc_url}}"

# Verify production state-mate checks. Reads L2_RPC_URL from
# .env.<network> (or legacy fallbacks: L2_STATE_MATE_RPC_URL / LOCAL_L2_<NET>_RPC_URL / L2_<NET>_RPC_URL).
# These checks intentionally fail while the current on-chain deployment has not reached production state.
# Usage: just -E .env.<network> test-<network>-upgrade-state-verify
test-optimism-upgrade-state-verify:
    @just _state-verify optimism ""

test-arbitrum-upgrade-state-verify:
    @just _state-verify arbitrum ""

test-base-upgrade-state-verify:
    @just _state-verify base ""

test-linea-upgrade-state-verify:
    @just _state-verify linea ""

# Behavioral canary acceptance on a FORK against the real on-chain deployed addresses. Binds to the
# canary when config/state/<network>.deployed.yaml carries all three addresses AND the on-chain infra
# is deployer-owned (verifyCanaryStage1) — skipping the deploy — else deploys fresh on the fork. Reads
# the same delay/min-amount/float off-chain, so it's non-destructive + keyless: the CI sibling of the
# on-chain `simulate-sync` real-broadcast path. The RPC should be a mainnet upstream (the test forks it
# in-process); it also forks L1, so L1_RPC_URL is required.
_canary-acceptance network rpc_url='':
    #!/usr/bin/env bash
    set -euo pipefail
    NET="{{network}}"
    RPC_ARG="{{rpc_url}}"
    ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    command -v forge >/dev/null 2>&1 || { echo "Missing required command: forge" >&2; exit 1; }

    # RPC precedence mirrors _state-verify: positional [rpc_url] > L2_RPC_URL > L2_STATE_MATE_RPC_URL > L2_<NET>_RPC_URL.
    case "$NET" in
      optimism) DEFAULT_RPC="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${L2_OPTIMISM_RPC_URL:-}}}"; CONTRACT=OptimismPoolUpgradeTest ;;
      arbitrum) DEFAULT_RPC="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${L2_ARBITRUM_RPC_URL:-}}}"; CONTRACT=ArbitrumPoolUpgradeTest ;;
      base)     DEFAULT_RPC="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${L2_BASE_RPC_URL:-}}}";     CONTRACT=BasePoolUpgradeTest ;;
      linea)    DEFAULT_RPC="${L2_RPC_URL:-${L2_STATE_MATE_RPC_URL:-${L2_LINEA_RPC_URL:-}}}";     CONTRACT=LineaPoolUpgradeTest ;;
      *) echo "Unknown network: $NET (one of: optimism|arbitrum|base|linea)" >&2; exit 1 ;;
    esac
    RPC_URL="${RPC_ARG:-$DEFAULT_RPC}"
    [[ -n "$RPC_URL" ]] || { echo "Missing L2 RPC: pass [rpc_url], set L2_RPC_URL, or set the per-network L2_<NET>_RPC_URL" >&2; exit 1; }
    : "${L1_RPC_URL:?L1_RPC_URL is required (the fork test base also forks L1)}"

    # Export the per-network L2 RPC env var the fork-test base reads via _l2RpcUrl().
    case "$NET" in
      optimism) export L2_OPTIMISM_RPC_URL="$RPC_URL" ;;
      base)     export L2_BASE_RPC_URL="$RPC_URL" ;;
      linea)    export L2_LINEA_RPC_URL="$RPC_URL" ;;
      arbitrum) export L2_ARBITRUM_RPC_URL="$RPC_URL" LOCAL_L2_ARBITRUM_RPC_URL="$RPC_URL" ;; # _envOr reads LOCAL first
    esac

    # Bind to the on-chain canary IF the generated sibling carries all three addresses; else fresh-deploy.
    # (<net>.deployed.yaml is generated by deploy-test and is absent in a fresh clone/CI,
    # which is exactly when the fresh-deploy fallback is wanted.)
    dep="$ROOT_DIR/config/state/$NET.deployed.yaml"
    re='^0x[0-9a-fA-F]{40}$'
    if command -v yq >/dev/null 2>&1 && [[ -f "$dep" ]]; then
      pool="$(yq '.. | select(anchor == "l2OraclePool")'  "$dep" 2>/dev/null | tr -d '"' | head -n1)"
      trig="$(yq '.. | select(anchor == "l2SyncTrigger")' "$dep" 2>/dev/null | tr -d '"' | head -n1)"
      recv="$(yq '.. | select(anchor == "l2CreReceiver")'  "$dep" 2>/dev/null | tr -d '"' | head -n1)"
      if [[ "$pool" =~ $re && "$trig" =~ $re && "$recv" =~ $re ]]; then
        export L2_ORACLE_POOL="$pool" L2_SYNC_TRIGGER="$trig" L2_CRE_RECEIVER="$recv"
        echo "Canary acceptance ($NET): binding to on-chain addresses from $dep"
        echo "  L2_ORACLE_POOL=$pool"
        echo "  L2_SYNC_TRIGGER=$trig"
        echo "  L2_CRE_RECEIVER=$recv"
        [[ -n "${L2_TEST_DEPLOYER:-}" ]] && echo "  L2_TEST_DEPLOYER=$L2_TEST_DEPLOYER (else derived from on-chain owner)"
      else
        echo "Canary acceptance ($NET): $dep present but canary anchors empty -> fresh-deploy on fork"
      fi
    else
      echo "Canary acceptance ($NET): no $dep (or yq) -> fresh-deploy on fork"
    fi

    echo "Forking $RPC_URL (+ L1 $L1_RPC_URL); running $CONTRACT::test_canarySyncOnDeployedAddresses"
    cd "$ROOT_DIR"
    forge test --match-contract "$CONTRACT" --match-test test_canarySyncOnDeployedAddresses -vv

# Behavioral canary acceptance on a fork against the real deployed addresses (binds if present, else fresh
# deploy). Usage: just -E .env.<network> test-<network>-canary-acceptance   (or pass an upstream RPC arg)
test-optimism-canary-acceptance rpc_url='':
    @just _canary-acceptance optimism "{{rpc_url}}"

test-arbitrum-canary-acceptance rpc_url='':
    @just _canary-acceptance arbitrum "{{rpc_url}}"

test-base-canary-acceptance rpc_url='':
    @just _canary-acceptance base "{{rpc_url}}"

test-linea-canary-acceptance rpc_url='':
    @just _canary-acceptance linea "{{rpc_url}}"

# Legacy alias
test-optimism-upgrade-state:
    @just _acceptance-test

# Print ETH, WETH, and wstETH balances for a given address on L1. Lines are omitted when below
# 0.00001 (dust); the whole block is skipped when every balance is below the threshold.
[no-exit-message]
_balances-l1 label address rpc_url weth wsteth:
    #!/usr/bin/env bash
    set -euo pipefail
    MIN_WEI=10000000000000 # 0.00001 × 1e18
    addr="{{address}}"
    rpc="{{rpc_url}}"
    weth="{{weth}}"
    wsteth="{{wsteth}}"
    out=""
    append_if_above() {
      local lbl="$1" wei="$2"
      [[ -n "$wei" && "$wei" =~ ^[0-9]+$ && "$wei" -ge "$MIN_WEI" ]] || return 0
      out+="  ${lbl}: $(cast from-wei "$wei")"$'\n'
    }
    append_token_if_above() {
      local lbl="$1" token="$2"
      local wei
      wei="$(cast call "$token" "balanceOf(address)(uint256)" "$addr" --rpc-url "$rpc" 2>/dev/null | awk '{print $1}')"
      append_if_above "$lbl" "$wei"
    }
    eth_wei="$(cast balance "$addr" --rpc-url "$rpc" 2>/dev/null | awk '{print $1}')"
    append_if_above ETH "$eth_wei"
    append_token_if_above WETH "$weth"
    append_token_if_above wstETH "$wsteth"
    [[ -n "$out" ]] || exit 0
    echo "=== {{label}} $addr ==="
    printf '%s' "$out"

# Print ETH, WETH, and wstETH balances for a given address on an L2 network. Lines are omitted when
# below 0.00001 (dust); the whole block is skipped when every balance is below the threshold.
[no-exit-message]
_balances-l2 label address rpc_url weth wsteth:
    #!/usr/bin/env bash
    set -euo pipefail
    MIN_WEI=10000000000000 # 0.00001 × 1e18
    addr="{{address}}"
    rpc="{{rpc_url}}"
    weth="{{weth}}"
    wsteth="{{wsteth}}"
    out=""
    append_if_above() {
      local lbl="$1" wei="$2"
      [[ -n "$wei" && "$wei" =~ ^[0-9]+$ && "$wei" -ge "$MIN_WEI" ]] || return 0
      out+="  ${lbl}: $(cast from-wei "$wei")"$'\n'
    }
    append_token_if_above() {
      local lbl="$1" token="$2"
      local wei
      wei="$(cast call "$token" "balanceOf(address)(uint256)" "$addr" --rpc-url "$rpc" 2>/dev/null | awk '{print $1}')"
      append_if_above "$lbl" "$wei"
    }
    eth_wei="$(cast balance "$addr" --rpc-url "$rpc" 2>/dev/null | awk '{print $1}')"
    append_if_above ETH "$eth_wei"
    append_token_if_above WETH "$weth"
    append_token_if_above wstETH "$wsteth"
    [[ -n "$out" ]] || exit 0
    echo "=== {{label}} $addr ==="
    printf '%s' "$out"

# NB: stETH (rebasing) does not exist on L2s; only wstETH is bridged

# Addresses/tokens read from the state-mate config/state/ siblings: deployed addrs from
# <net>.deployed.yaml, lane-specific tokens from <net>.inputs.yaml, and universal actors from
# l2.common.inputs.yaml.
# The Lido Deployer EOA is chain-agnostic (same address on L1 + all four L2s), so its L1 row reads the
# *l2LidoDeployer anchor from the common L2 inputs rather than adding a second copy to ethereum.inputs.yaml.
balances-l1:
    #!/usr/bin/env bash
    set -euo pipefail
    inp="config/state/ethereum.inputs.yaml"
    rpc="${L1_RPC_URL:-${RPC_ETHEREUM_REMOTE:-${RPC_ETHEREUM:-}}}"
    [[ -n "$rpc" ]] || { echo "Missing L1 RPC: set L1_RPC_URL or RPC_ETHEREUM_REMOTE" >&2; exit 1; }
    weth="$(yq '.externals[] | select(anchor == "l1Weth")' "$inp")"
    wsteth="$(yq '.externals[] | select(anchor == "l1Wsteth")' "$inp")"
    echo "--- L1 (Ethereum) --- block $(cast block-number --rpc-url "$rpc")"
    any=""
    _balances_print() {
      local out
      out="$(just _balances-l1 "$1" "$2" "$rpc" "$weth" "$wsteth" 2>/dev/null || true)"
      [[ -n "$out" ]] || return 0
      [[ -n "$any" ]] && echo ""
      printf '%s\n' "$out"
      any=1
    }
    _balances_print LidoDeployer "$(just _l2-input-anchor optimism l2LidoDeployer)"
    _balances_print LidoCustomReceiver "$(yq '.externals[] | select(anchor == "l1LidoCustomReceiver")' "$inp")"

# Print LidoDeployer + Automation Owner + SyncTrigger + CustomSender + OraclePool balances for one L2
# lane. New OraclePool and SyncTrigger come from config/state/<net>.deployed.yaml; LidoDeployer,
# CustomSender and the WETH/wstETH token addrs come from <net>.inputs.yaml; LidoDeployer and
# Automation Owner come from l2.common.inputs.yaml. The values are read once and reused for every
# sub-call; L2_AUTOMATION_OWNER remains an operational fallback if the common owner cannot be read.
# The SyncTrigger row's ETH is the operational number: the trigger fronts CCIP fees from its own balance
# (see docs/fees.md), so this is the remaining fee float. Its WETH/wstETH rows should read 0 — the trigger
# never custodies tokens, so a non-zero one is stranded dust, not float.
[no-exit-message]
_balances-net net label rpc_url:
    #!/usr/bin/env bash
    set -euo pipefail
    dep="config/state/{{net}}.deployed.yaml"
    inp="config/state/{{net}}.inputs.yaml"
    weth="$(yq '.externals[] | select(anchor == "l2Weth")' "$inp")"
    wsteth="$(yq '.externals[] | select(anchor == "l2Wsteth")' "$inp")"
    automation_owner="$(just _l2-input-anchor "{{net}}" l2AutomationOwner 2>/dev/null || true)"
    if [[ -z "$automation_owner" || "$automation_owner" == "null" ]]; then
      automation_owner="${L2_AUTOMATION_OWNER:-}"
    fi
    echo "--- {{label}} --- block $(cast block-number --rpc-url "{{rpc_url}}")"
    any=""
    _balances_print() {
      local out
      out="$(just _balances-l2 "$1" "$2" "{{rpc_url}}" "$weth" "$wsteth" 2>/dev/null || true)"
      [[ -n "$out" ]] || return 0
      [[ -n "$any" ]] && echo ""
      printf '%s\n' "$out"
      any=1
    }
    _balances_print LidoDeployer "$(just _l2-input-anchor "{{net}}" l2LidoDeployer)"
    if [[ -n "$automation_owner" ]]; then
      _balances_print "Automation Owner" "$automation_owner"
    fi
    _balances_print SyncTrigger "$(yq '.deployed.l2[] | select(anchor == "l2SyncTrigger")' "$dep")"
    _balances_print CustomSender "$(yq '.externals[] | select(anchor == "l2CustomSender")' "$inp")"
    _balances_print OraclePool "$(yq '.deployed.l2[] | select(anchor == "l2OraclePool")' "$dep")"

# RPC precedence per lane: L2_<NET>_RPC_URL (fork-test convention) > RPC_<NET>_REMOTE (upstream) > RPC_<NET>
# (local fork proxy). The last is often down, so it is the fallback, not the default.
balances-optimism:
    @just _balances-net optimism Optimism "${L2_OPTIMISM_RPC_URL:-${RPC_OPTIMISM_REMOTE:-$RPC_OPTIMISM}}"

balances-arbitrum:
    @just _balances-net arbitrum Arbitrum "${L2_ARBITRUM_RPC_URL:-${RPC_ARBITRUM_REMOTE:-$RPC_ARBITRUM}}"

balances-base:
    @just _balances-net base Base "${L2_BASE_RPC_URL:-${RPC_BASE_REMOTE:-$RPC_BASE}}"

balances-linea:
    @just _balances-net linea Linea "${L2_LINEA_RPC_URL:-${RPC_LINEA_REMOTE:-$RPC_LINEA}}"

# Print the complete balance snapshot as an ASCII matrix: networks are columns, accounts are rows, and
# each cell lists every token at or above the universal 0.00001 threshold on a separate line. Amounts
# are rounded to the threshold precision (five decimal places). A cell with no qualifying balance (or
# no such account on that network) is "-", while "TOKEN ?" preserves an RPC/read failure. The threshold
# can be overridden for ad-hoc checks via BALANCES_MIN_WEI.
#
# The SyncTrigger row's ETH is the operational number: the trigger fronts CCIP fees from its own balance
# (see docs/fees.md), so this is the remaining fee float. Its WETH/wstETH cells should read "-" — the
# trigger never custodies tokens, so a non-zero one is stranded dust, not float.
#
# The five networks are read concurrently (independent endpoints), and each one's block height is in the
# footer so a snapshot can be pinned and reproduced.
balances:
    #!/usr/bin/env bash
    set -euo pipefail
    export LC_ALL=C   # numeric report: never let a locale render decimal commas

    MIN_WEI="${BALANCES_MIN_WEI:-10000000000000}"
    # One source-of-truth column list; display names and RPC env-var names are derived from it (no
    # parallel arrays to keep in lockstep), matching quote-ccip-fees' convention. Ethereum carries only
    # the two L1-relevant accounts; every other row resolves per lane and is "-" in that column.
    NETS=( ethereum optimism arbitrum base linea )
    ENTITIES=( LidoDeployer LidoCustomReceiver "Automation Owner" SyncTrigger CustomSender OraclePool )
    ASSETS=( ETH WETH wstETH )
    declare -a NAMES
    for net in "${NETS[@]}"; do
      u="$(echo "$net" | tr '[:lower:]' '[:upper:]')"
      NAMES+=("${u:0:1}${net:1}")
    done

    # Display precision follows the threshold (1e13 wei -> 5 places), derived once for the whole run.
    PLACES=18
    t="$MIN_WEI"
    while (( t > 0 && t % 10 == 0 && PLACES > 0 )); do t=$(( t / 10 )); PLACES=$(( PLACES - 1 )); done

    # RPC precedence exactly as documented for balances-<net> above: L2_<NET>_RPC_URL (fork-test
    # convention) > RPC_<NET>_REMOTE (upstream) > RPC_<NET> (local fork proxy — often down, hence last).
    # Ethereum spells its override L1_RPC_URL; the rest of the chain is the same shape.
    rpc_for() {
      local net="$1" u override v
      u="$(echo "$net" | tr '[:lower:]' '[:upper:]')"
      if [[ "$net" == ethereum ]]; then override="L1_RPC_URL"; else override="L2_${u}_RPC_URL"; fi
      for v in "$override" "RPC_${u}_REMOTE" "RPC_${u}"; do
        if [[ -n "${!v:-}" ]]; then printf '%s' "${!v}"; return; fi
      done
    }

    # Wei held by one address in one asset, or "" when unreadable: no RPC, no token address for this
    # network, or a failed call. cast annotates some outputs (" [1e18]"), so keep the leading integer.
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

    # Above-threshold amount rounded to PLACES; "" when below (the token is then omitted from its cell);
    # "?" when the read failed. Compare by digit count, then lexically: bash arithmetic is signed 64-bit
    # and would wrap a balance >= 2^63 wei (~9.22 ETH) to negative, hiding a real holding as dust.
    format_balance() {
      local wei="$1"
      [[ "$wei" =~ ^[0-9]+$ ]] || { printf '?'; return; }
      if (( ${#wei} < ${#MIN_WEI} )) || { (( ${#wei} == ${#MIN_WEI} )) && [[ "$wei" < "$MIN_WEI" ]]; }; then
        return 0
      fi
      printf '%.*f' "$PLACES" "$(cast from-wei "$wei")"
    }

    # One "net<TAB>entity<TAB>asset<TAB>value" row per asset. An unresolved address is "not applicable"
    # rather than a read failure: leave the values empty so the cell renders "-", and skip the RPC
    # round-trips entirely.
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

    # Addresses/tokens read from the state-mate config/state/ siblings: deployed addrs from
    # <net>.deployed.yaml, lane tokens/externals from <net>.inputs.yaml, and universal actors through
    # the effective-input helper. Anchors from each physical file are collected in a single yq pass
    # where practical. The anchored list items need recursive descent (`.[]` misses them), and the
    # `[..][0]` form pins output order to query order so the positional read is safe; a missing anchor
    # yields "null", which record_address treats as "not applicable".
    collect_ethereum() {
      local rpc="$1" weth wsteth receiver deployer
      { IFS= read -r weth; IFS= read -r wsteth; IFS= read -r receiver; } < <(yq '
        [.. | select(anchor=="l1Weth")][0],
        [.. | select(anchor=="l1Wsteth")][0],
        [.. | select(anchor=="l1LidoCustomReceiver")][0]' config/state/ethereum.inputs.yaml)
      # The Lido Deployer EOA is chain-agnostic (same address on L1 + all four L2s), so its L1 row reads
      # *l2LidoDeployer from the common L2 inputs rather than duplicating it in ethereum.inputs.yaml.
      deployer="$(just _l2-input-anchor optimism l2LidoDeployer)"
      record_address ethereum LidoDeployer       "$deployer" "$rpc" "$weth" "$wsteth"
      record_address ethereum LidoCustomReceiver "$receiver" "$rpc" "$weth" "$wsteth"
    }

    collect_lane() {
      local net="$1" rpc="$2" weth wsteth deployer sender owner trigger pool
      { IFS= read -r weth; IFS= read -r wsteth; IFS= read -r sender
      } < <(yq '
        [.. | select(anchor=="l2Weth")][0],
        [.. | select(anchor=="l2Wsteth")][0],
        [.. | select(anchor=="l2CustomSender")][0]' "config/state/${net}.inputs.yaml")
      deployer="$(just _l2-input-anchor "$net" l2LidoDeployer)"
      owner="$(just _l2-input-anchor "$net" l2AutomationOwner)"
      { IFS= read -r trigger; IFS= read -r pool; } < <(yq '
        [.. | select(anchor=="l2SyncTrigger")][0],
        [.. | select(anchor=="l2OraclePool")][0]' "config/state/${net}.deployed.yaml")
      [[ -n "$owner" && "$owner" != null ]] || owner="${L2_AUTOMATION_OWNER:-}"
      record_address "$net" LidoDeployer       "$deployer" "$rpc" "$weth" "$wsteth"
      record_address "$net" "Automation Owner" "$owner"    "$rpc" "$weth" "$wsteth"
      record_address "$net" SyncTrigger        "$trigger"  "$rpc" "$weth" "$wsteth"
      record_address "$net" CustomSender       "$sender"   "$rpc" "$weth" "$wsteth"
      record_address "$net" OraclePool         "$pool"     "$rpc" "$weth" "$wsteth"
    }

    # ── Collect: one background job per network. The endpoints are independent and each network is a
    # ── chain of ~16 serial reads, so wall clock is the slowest network rather than the sum of all five.
    outdir="$(mktemp -d)"
    trap 'rm -rf "$outdir"' EXIT
    for net in "${NETS[@]}"; do
      rpc="$(rpc_for "$net")"
      {
        cast block-number --rpc-url "$rpc" >"$outdir/$net.block" 2>/dev/null || true
        if [[ "$net" == ethereum ]]; then collect_ethereum "$rpc"; else collect_lane "$net" "$rpc"; fi
      } >"$outdir/$net.rows" &
    done
    wait
    for net in "${NETS[@]}"; do
      [[ -s "$outdir/$net.rows" ]] || { echo "balances: could not collect $net (see errors above)" >&2; exit 1; }
    done

    # ── Render: one awk pass keys the collected rows by (network, account, asset), so the input order
    # ── does not matter, then pads the matrix. A cell is stacked over as many physical lines as it has
    # ── qualifying assets, and the column rule is built once from the measured widths.
    cat "$outdir"/*.rows | awk -F '\t' \
      -v netlist="$(IFS=$'\t'; printf '%s' "${NETS[*]}")" \
      -v namelist="$(IFS=$'\t'; printf '%s' "${NAMES[*]}")" \
      -v entlist="$(IFS=$'\t'; printf '%s' "${ENTITIES[*]}")" \
      -v astlist="$(IFS=$'\t'; printf '%s' "${ASSETS[*]}")" '
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

# Read-only ownership + role audit of the whole migration surface, all four lanes. Answers ONE question:
# "who holds what, right now?" — the input every ownership-change decision needs (who must sign the next
# step, which stage each lane actually sits in). Complements the other verify-* recipes: they assert an
# EXPECTED end state and fail on the first mismatch; this one just REPORTS live values next to the anchor
# each is supposed to equal, so a half-migrated lane reads out fully instead of aborting at check #1.
#
# No keys and no writes — every value is a `cast call` / `cast balance` / `cast nonce` against addresses
# pinned in config/state/<net>.{inputs,deployed}.yaml (plus the Linea-only Gelato automation from
# l2-linea-gelato.yaml). Resolved anchors are echoed per lane so the report carries its own oracle.
#
# `?` in a value column means the read failed (RPC error) — never silently a zero/false.
#
# Usage: just audit-ownership        (RPC precedence per lane as in `balances`)
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
    FORWARDER="$(ext l2CreForwarder)";     OLD_AUTOMATION="$(ext l2OldSyncAutomation)"
    OLD_POOL="$(ext RETIRED_l2OraclePool)"
    POOL="$(dpl l2OraclePool)"; TRIGGER="$(dpl l2SyncTrigger)"; RECEIVER="$(dpl l2CreReceiver)"
    RETIRED_TRIGGER="$(dpl RETIRED_l2SyncTrigger)"; RETIRED_RECEIVER="$(dpl RETIRED_l2CreReceiver)"
    # Linea's predecessor ran a second (Gelato) automation; address lives under misc: in the
    # standalone gelato wiring file (no .inputs sibling — see l2-linea-gelato.yaml).
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
        "$(lc "$DEPLOYER")")       echo "Lido Deployer" ;;
        "$(lc "$INIT_OWNER")")  echo "Initial Owner" ;;
        "$(lc "$GOV_EXEC")")       echo "L2 gov executor" ;;
        "$(lc "$FORWARDER")")      echo "CRE forwarder" ;;
        "$(lc "$TRIGGER")")        echo "SyncTrigger" ;;
        "$(lc "$RECEIVER")")       echo "CREReceiver" ;;
        "$(lc "$RETIRED_TRIGGER")") echo "RETIRED SyncTrigger" ;;
        "$(lc "$RETIRED_RECEIVER")") echo "RETIRED CREReceiver" ;;
        "$(lc "$POOL")")           echo "new OraclePool" ;;
        "$(lc "$OLD_POOL")")       echo "OLD OraclePool" ;;
        "?"|"")                    echo "read failed" ;;
        *)                         echo "UNKNOWN — investigate" ;;
      esac
    }
    row () { printf '  %-46s %-42s %s\n' "$1" "$2" "$3"; }

    echo "════ {{label}} ════ block $(cast block-number --rpc-url "$rpc" 2>/dev/null || echo '?')"
    echo "  anchors (config/state/{{net}}.{inputs,deployed}.yaml):"
    printf '    %-22s %s\n' \
      CustomSender "$SENDER" ProxyAdmin "$PROXY_ADMIN" InitialOwner "$INIT_OWNER" \
      GovExecutor "$GOV_EXEC" LOL "$LOL" Deployer "$DEPLOYER" CreForwarder "$FORWARDER" \
      OraclePool "$POOL" SyncTrigger "$TRIGGER" CREReceiver "$RECEIVER" \
      RetiredSyncTrigger "$RETIRED_TRIGGER" RetiredCREReceiver "$RETIRED_RECEIVER" \
      OldAutomation "$OLD_AUTOMATION" OldOraclePool "$OLD_POOL"
    [[ -n "$OLD_GELATO" ]] && printf '    %-22s %s\n' OldGelatoAutomation "$OLD_GELATO"
    echo
    echo "  ── owner() ──"
    for pair in "OraclePool:$POOL" "SyncTrigger:$TRIGGER" "CREReceiver:$RECEIVER" \
      "RETIRED SyncTrigger:$RETIRED_TRIGGER" "RETIRED CREReceiver:$RETIRED_RECEIVER" \
      "L2ProxyAdmin:$PROXY_ADMIN"; do
      v="$(rd "${pair#*:}" 'owner()(address)')"; row "${pair%%:*}.owner()" "$v" "= $(who "$v")"
    done
    echo "  ── automation wiring ──"
    v="$(rd "$RECEIVER" 'getForwarder()(address)')";      row "CREReceiver.getForwarder()" "$v" "= $(who "$v")"
    v="$(rd "$RECEIVER" 'getExpectedAuthor()(address)')"; row "CREReceiver.getExpectedAuthor()" "$v" "= $(who "$v")"
    v="$(rd "$RECEIVER" 'isCallAllowed(address,bytes4)(bool)' "$TRIGGER" "$TRIGGER_SYNC_SEL")"
    row "CREReceiver.isCallAllowed(trigger,triggerSync)" "$v" ""
    v="$(rd "$TRIGGER" 'getForwarder()(address)')";       row "SyncTrigger.getForwarder()" "$v" "= $(who "$v")"
    v="$(rd "$RETIRED_RECEIVER" 'isCallAllowed(address,bytes4)(bool)' "$RETIRED_TRIGGER" "$TRIGGER_SYNC_SEL")"
    row "RETIRED CREReceiver.isCallAllowed(retired,triggerSync)" "$v" ""
    v="$(rd "$RETIRED_TRIGGER" 'getForwarder()(address)')"
    row "RETIRED SyncTrigger.getForwarder()" "$v" "= $(who "$v")"
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
    echo "  ── next-deploy address prediction input ──"
    row "Lido Deployer nonce" "$(cast nonce "$DEPLOYER" --rpc-url "$rpc" 2>/dev/null || echo '?')" "$DEPLOYER"


# Assert the compiler-provenance facts that docs/compiler-bug-exposure.md's verdict rests on. Answers ONE
# question: "is the deployed bytecode still the output of a build whose settings make the known solc bugs
# unreachable?" Four checks, any failure exits non-zero:
#
#   G1  via_ir = false            — the IR pipeline is the stated precondition of the whole
#                                   stack-limit-evader bug family (UnsoundSpillInMutualRecursion).
#   G2  no `layout at` specifier  — a custom storage-layout specifier is the only way to emit the
#       in the compilation           "very close to the end of storage" warning whose emission corrupted
#       closure                      `linearizedBaseContracts` (InheritanceOrderReversalOnStorageEndWarning).
#   G3  solc emits that warning   — the direct observable, not just the trigger's absence.
#       for neither contract
#   G4  on-chain CBOR metadata    — the trailer commits to the IPFS hash of the metadata JSON, which covers
#       trailer == local artifact    compiler version + EVERY setting + all source hashes. Equality is what
#       trailer, all four lanes      lets G1–G3 (facts about THIS build) speak for the DEPLOYED code.
#
# Read-only, no keys. G4 needs an RPC per lane (same precedence as `balances`); G1–G3 are offline.
# Re-run after any solc bump, any foundry.toml change, and any redeploy.
#
# Assert the known-solc-bug exposure gates G1-G4 (see docs/compiler-bug-exposure.md)
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
      echo "verify-compiler-provenance: FAILURES ABOVE — re-run docs/compiler-bug-exposure.md §5" >&2; fi
    exit "$fail"


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

# Install CRE workflow dependencies (run once after clone).
#
# This installs the `@chainlink/cre-sdk` bun deps ONLY — it yields `cre-compile` / `cre-setup`, NOT
# the `cre` CLI itself (a separate Go binary; there is no npm package for it).
#
# Usage: just setup-cre       (bun deps only — `setup-cre-cli` installs the `cre` binary)
setup-cre:
    cd cre-workflows/sync-automation && bun install

# Install the pinned `cre` CLI into the repo-local, gitignored `.cre/bin/` (run once after clone).
#
# Deliberately NOT the upstream one-liner (`curl -sSL https://app.chain.link/cre/install.sh | bash`):
# that installs into $HOME/.cre and appends a PATH line to your shell rc. This recipe keeps the whole
# footprint inside the working tree — no sudo, no /usr/local/bin, no shell-rc edit — and pins the
# release (CRE_CLI_VERSION) instead of tracking `latest`, so a CLI upgrade is a reviewable diff.
#
# The download is verified against the release's `checksums.txt` before anything is installed. (The
# GPG `.sig` assets exist for Linux only, so the SHA-256 is the portable integrity gate.)
#
# Usage: just setup-cre-cli          (idempotent — no-op when already at CRE_CLI_VERSION)
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
    #!/usr/bin/env bash
    set -uo pipefail
    ROOT_DIR="{{justfile_directory()}}"
    source "$ROOT_DIR/script/shared/cre-env.sh"
    # `just -E .env.<net>` REPLACES the dotenv path, so the root .env's secrets are not loaded by just —
    # pull them in the same way the cre recipes do, or this reports a false "key unset".
    cre_env_load_secrets
    command -v cast >/dev/null 2>&1 || { echo "Missing 'cast' (foundry)" >&2; exit 1; }
    rc=0
    OK()   { echo "  ✓ $*"; }
    BAD()  { echo "  ✗ $*"; rc=1; }
    INFO() { echo "  · $*"; }
    lc()   { printf '%s' "${1:-}" | tr 'A-Z' 'a-z'; }
    anchor() {
      local net
      net="$(basename "$1" .inputs.yaml)"
      just _l2-input-anchor "$net" "$2" 2>/dev/null
    }

    echo "===================================================================="
    echo "ENV DOCTOR — canonical variables and what they resolve to"
    echo "===================================================================="
    echo
    echo "Secrets tier (root .env — keys/tokens only):"
    for v in L2_LIDO_DEPLOYER_PRIVATE_KEY INITIAL_OWNER_PRIVATE_KEY ETHERSCAN_API_KEY GITHUB_API_TOKEN; do
      [[ -n "${!v:-}" ]] && INFO "$v = set" || INFO "$v = unset"
    done
    AO_KEY="${L2_AUTOMATION_OWNER_PRIVATE_KEY:-${L2_AUTOMATION_OWNER_PK:-}}"
    if [[ -n "$AO_KEY" ]]; then
      INFO "Automation Owner key = set (via ${L2_AUTOMATION_OWNER_PRIVATE_KEY:+L2_AUTOMATION_OWNER_PRIVATE_KEY}${L2_AUTOMATION_OWNER_PRIVATE_KEY:-L2_AUTOMATION_OWNER_PK})"
    else
      BAD "Automation Owner key unset — set L2_AUTOMATION_OWNER_PRIVATE_KEY (or L2_AUTOMATION_OWNER_PK) in the root .env"
    fi
    if [[ -n "${CRE_ETH_PRIVATE_KEY:-}" ]]; then
      BAD "CRE_ETH_PRIVATE_KEY is set in the environment — it is DERIVED from the Automation Owner key; a hand-written copy will rot on rotation. Remove it from .env."
    else
      OK "no hand-written CRE_ETH_PRIVATE_KEY (derived at call time)"
    fi
    echo
    echo "Actor addresses:"
    INFO "DEPLOYER              = ${DEPLOYER:-<unset>}"
    INFO "L2_AUTOMATION_OWNER   = ${L2_AUTOMATION_OWNER:-<unset>}"
    if [[ -n "$AO_KEY" && -n "${L2_AUTOMATION_OWNER:-}" ]]; then
      DERIVED="$(cast wallet address --private-key "$AO_KEY" 2>/dev/null || true)"
      if [[ -z "$DERIVED" ]]; then
        BAD "Automation Owner key is not a valid private key"
      elif [[ "$(lc "$DERIVED")" == "$(lc "$L2_AUTOMATION_OWNER")" ]]; then
        OK "AO key signs as $DERIVED == L2_AUTOMATION_OWNER"
      else
        BAD "AO key signs as $DERIVED but L2_AUTOMATION_OWNER = $L2_AUTOMATION_OWNER"
      fi
    fi
    if [[ -n "${L2_LIDO_DEPLOYER_PRIVATE_KEY:-}" && -n "${DEPLOYER:-}" ]]; then
      DEP_DERIVED="$(cast wallet address --private-key "$L2_LIDO_DEPLOYER_PRIVATE_KEY" 2>/dev/null || true)"
      [[ "$(lc "$DEP_DERIVED")" == "$(lc "$DEPLOYER")" ]] \
        && OK "deployer key signs as $DEP_DERIVED == DEPLOYER" \
        || BAD "deployer key signs as ${DEP_DERIVED:-<invalid>} but DEPLOYER = $DEPLOYER"
    fi
    echo
    echo "L1 (Ethereum mainnet):"
    if L1="$(resolve_l1_rpc 2>/dev/null)"; then
      SRC="L1_RPC_URL"; [[ -n "${L1_RPC_URL:-}" ]] || SRC="RPC_ETHEREUM_REMOTE/RPC_ETHEREUM (fallback)"
      INFO "resolved $(cre_env_host "$L1")  ← $SRC"
      CID="$(cast chain-id --rpc-url "$L1" 2>/dev/null || echo '?')"
      [[ "$CID" == "1" ]] && OK "chain-id 1" || BAD "chain-id $CID (expected 1) — is this the local fork proxy or a wrong endpoint?"

      # Can the Automation Owner register a workflow at all? Three independent gates, all on the
      # Chainlink WorkflowRegistry (mainnet, regardless of the lane a workflow drives):
      #   isOwnerLinked            — `cre account link-key` was executed FROM this address
      #   maxWorkflowsPerUserDON   — a non-zero per-user quota on the DON family we target (deploy access)
      #   mainnet ETH              — the owner signs the registration transaction itself
      # This does NOT prove the CRE-side org/credit state, which is dashboard-only (docs/cre.md).
      if [[ "$CID" == "1" && -n "${L2_AUTOMATION_OWNER:-}" ]]; then
        WF_REGISTRY=0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5
        DON_FAMILY="${CRE_DON_FAMILY:-zone-a}"
        LINKED="$(cast call "$WF_REGISTRY" 'isOwnerLinked(address)(bool)' "$L2_AUTOMATION_OWNER" --rpc-url "$L1" 2>/dev/null || echo '?')"
        [[ "$LINKED" == "true" ]] \
          && OK "WorkflowRegistry: owner linked (isOwnerLinked = true)" \
          || BAD "WorkflowRegistry: owner NOT linked (isOwnerLinked = $LINKED) — run 'just cre account link-key -l <label>' FROM the Automation Owner key"
        QUOTA="$(cast call "$WF_REGISTRY" 'getMaxWorkflowsPerUserDON(address,string)(uint32)' "$L2_AUTOMATION_OWNER" "$DON_FAMILY" --rpc-url "$L1" 2>/dev/null || echo '0')"
        [[ "${QUOTA%% *}" =~ ^[0-9]+$ && "${QUOTA%% *}" -gt 0 ]] \
          && OK "WorkflowRegistry: deploy quota on DON '$DON_FAMILY' = ${QUOTA%% *} workflow(s)" \
          || BAD "WorkflowRegistry: zero deploy quota on DON '$DON_FAMILY' — request access with 'just cre account access'"
        AO_WEI="$(cast balance "$L2_AUTOMATION_OWNER" --rpc-url "$L1" 2>/dev/null || echo 0)"
        [[ "$AO_WEI" -gt 0 ]] 2>/dev/null \
          && OK "Automation Owner mainnet gas: $(cast from-wei "$AO_WEI") ETH" \
          || BAD "Automation Owner has 0 mainnet ETH — it signs the WorkflowRegistry transaction itself"
        REGISTERED="$(cast call "$WF_REGISTRY" 'getWorkflowListByOwner(address,uint256,uint256)' "$L2_AUTOMATION_OWNER" 0 20 --rpc-url "$L1" 2>/dev/null || true)"
        if [[ "$REGISTERED" == 0x*0000000000000000000000000000000000000000000000000000000000000000 && ${#REGISTERED} -le 130 ]]; then
          INFO "WorkflowRegistry: no workflows registered under this owner yet"
        else
          INFO "WorkflowRegistry: workflow(s) already registered under this owner (getWorkflowListByOwner non-empty)"
        fi
      fi
    else
      BAD "no Ethereum-mainnet RPC — bind L1_RPC_URL in .env.<network> to \${RPC_ETHEREUM_REMOTE}"
    fi
    echo
    # Per-lane pass. With NETWORK set, `just` has already loaded that lane's .env.<network>, so the live
    # values are in the environment; without it, re-read each lane file for its bindings and addresses.
    LANES=(optimism arbitrum base linea)
    [[ -z "${L2_NETWORK:-}" ]] || LANES=("$L2_NETWORK")
    for net in "${LANES[@]}"; do
      echo "──────── lane: $net ────────"
      IN="$ROOT_DIR/config/state/$net.inputs.yaml"
      CRE_DEP="$ROOT_DIR/config/state/$net.deployed.yaml"
      if [[ "${L2_NETWORK:-}" == "$net" ]]; then
        L2="${L2_RPC_URL:-}"; RECV="${L2_CRE_RECEIVER:-}"; TRIG="${L2_SYNC_TRIGGER:-}"
      else
        # No dotenv overlay for this lane in-process: read the file, expanding ${RPC_*} from the shell.
        L2="$(grep -m1 '^L2_RPC_URL=' "$ROOT_DIR/.env.$net" 2>/dev/null | cut -d= -f2- || true)"
        L2="$(eval printf '%s' "\"${L2}\"" 2>/dev/null || true)"
        RECV="$(grep -m1 '^L2_CRE_RECEIVER=' "$ROOT_DIR/.env.$net" 2>/dev/null | cut -d= -f2- || true)"
        TRIG="$(grep -m1 '^L2_SYNC_TRIGGER=' "$ROOT_DIR/.env.$net" 2>/dev/null | cut -d= -f2- || true)"
        INFO "(read from .env.$net — run with NETWORK=$net for the fully loaded overlay)"
      fi
      WFID=""
      if [[ -f "$CRE_DEP" ]]; then
        WFID="$(yq '.. | select(anchor == "creWorkflowId")' "$CRE_DEP" 2>/dev/null | tr -d '"' | head -n1)"
      fi
      INFO "L2 RPC   $(cre_env_host "$L2")"
      INFO "trigger  ${TRIG:-<unset>}"
      INFO "receiver ${RECV:-<unset>}"
      # A lane that has not had its automation pair redeployed yet is still legitimately owned by the
      # LOL multisig (docs/automation-owner-redeploy.md S3 is per-lane). That is expected state, not a
      # misconfiguration — it is reported, not failed. Only an author that is NEITHER the Automation
      # Owner nor the lane's liquidity owner means something is actually wrong.
      ANCHOR_AO="$(anchor "$IN" l2AutomationOwner)"
      ANCHOR_LOL="$(anchor "$IN" l2LiquidityOwner)"
      if [[ -n "$ANCHOR_AO" && "$ANCHOR_AO" != "null" ]]; then
        if [[ -z "${L2_AUTOMATION_OWNER:-}" || "$(lc "$ANCHOR_AO")" == "$(lc "$L2_AUTOMATION_OWNER")" ]]; then
          OK "l2AutomationOwner anchor == L2_AUTOMATION_OWNER ($ANCHOR_AO)"
        else
          BAD "l2AutomationOwner anchor $ANCHOR_AO != L2_AUTOMATION_OWNER $L2_AUTOMATION_OWNER"
        fi
      else
        INFO "no l2AutomationOwner anchor yet (lane still on the LOL-owned automation pair)"
      fi
      if [[ -n "$L2" && -n "$RECV" ]]; then
        PINNED="$(cast call "$RECV" 'getExpectedAuthor()(address)' --rpc-url "$L2" 2>/dev/null | tr -d '\r\n' || true)"
        if [[ -z "$PINNED" ]]; then
          INFO "on-chain getExpectedAuthor(): unreachable (RPC down or wrong address)"
        elif [[ -n "${L2_AUTOMATION_OWNER:-}" && "$(lc "$PINNED")" == "$(lc "$L2_AUTOMATION_OWNER")" ]]; then
          OK "on-chain CREReceiver.getExpectedAuthor() == L2_AUTOMATION_OWNER ($PINNED)"
        elif [[ -n "$ANCHOR_LOL" && "$(lc "$PINNED")" == "$(lc "$ANCHOR_LOL")" ]]; then
          INFO "on-chain getExpectedAuthor() = $PINNED (LOL multisig) — lane not yet moved to the Automation Owner; deploy-cre-workflow would abort here by design"
        else
          BAD "on-chain CREReceiver.getExpectedAuthor() = $PINNED — neither L2_AUTOMATION_OWNER (${L2_AUTOMATION_OWNER:-<unset>}) nor the l2LiquidityOwner anchor (${ANCHOR_LOL:-<absent>})"
        fi
      fi
      if [[ -n "$WFID" ]]; then
        [[ "$WFID" =~ ^0x[0-9a-fA-F]{64}$ ]] \
          && OK "creWorkflowId deployed-state anchor well-formed ($WFID)" \
          || BAD "creWorkflowId malformed in $CRE_DEP: $WFID"
      else
        INFO "creWorkflowId: <unrecorded> (missing anchor in $CRE_DEP; record after workflow deploy/upsert)"
      fi
      echo
    done
    echo "===================================================================="
    [[ $rc -eq 0 ]] && echo "env-doctor: OK" || echo "env-doctor: problems above (rc=$rc)"
    echo "===================================================================="
    exit $rc

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

# Run an arbitrary `cre` command from the CRE project directory.
#
# `cre login`, `cre account …` and `cre workflow …` all require the directory that holds
# `project.yaml` (= cre-workflows/, NOT the repo root and NOT cre-workflows/sync-automation), and
# project.yaml interpolates ${L1_RPC_URL} + ${L2_OPTIMISM_RPC_URL} + ${CRE_WORKFLOW_OWNER} from the
# environment. This wrapper supplies both so the CLI cannot be run from the wrong cwd.
#
# The CLI's env spellings are DERIVED from the repo's canonical variables by
# script/shared/cre-env.sh — `CRE_ETH_PRIVATE_KEY` from `L2_AUTOMATION_OWNER_PRIVATE_KEY`/`_PK` and
# `CRE_WORKFLOW_OWNER` from `L2_AUTOMATION_OWNER`, with the key cross-checked against the address. So
# no CRE_* secret is ever hand-copied into a file, and `-e/--env` is unnecessary (the CLI reads exported
# variables); pass your own `-e` if you want it to load a file anyway.
#
# NOTE `cre account link-key` submits a transaction on ETHEREUM MAINNET (regardless of the workflow's
# target chain) signed by that key — the Automation Owner needs mainnet ETH for gas. `cre login` stores
# its session under $HOME (only the binary is repo-local).
#
# Usage: just cre login · just cre account access · NETWORK=optimism just cre account list-key
cre *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    CRE="$(just _cre-bin)"
    source "{{justfile_directory()}}/script/shared/cre-env.sh"
    cre_env_export
    echo "cre binary: $CRE"
    echo "cwd:        $(pwd)/cre-workflows"
    cd cre-workflows
    exec "$CRE" {{ARGS}}

# ──────────────────────────────────────────────────────────────────
# Anvil fork helpers
# ──────────────────────────────────────────────────────────────────

rpc-start-l1:
    anvil -p 8545 -f "$L1_RPC_URL"

rpc-start-optimism:
    anvil -p 8551 -f "$L2_OPTIMISM_RPC_URL"

rpc-start-arbitrum:
    anvil -p 8552 -f "$L2_ARBITRUM_RPC_URL"

rpc-start-base:
    anvil -p 8553 -f "$L2_BASE_RPC_URL"

rpc-start-linea:
    anvil -p 8554 -f "$L2_LINEA_RPC_URL"

# ──────────────────────────────────────────────────────────────────
# Arbitrum pool upgrade
# ──────────────────────────────────────────────────────────────────

# Run the Arbitrum pool upgrade fork test
test-arbitrum-upgrade:
    # Prefer a local anvil fork when provided, otherwise run directly against the upstream RPC.
    forge test --match-contract ArbitrumPoolUpgradeTest --rpc-url "${LOCAL_L2_ARBITRUM_RPC_URL:-$L2_ARBITRUM_RPC_URL}" -vvv
