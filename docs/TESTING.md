# Testing the migration

Four independent layers of pre-prod validation, in increasing realism:

| Layer | What it exercises | Recipe |
|---|---|---|
| **Forge fork tests + Chainlink Local CCIP simulator** (this doc, below) | Per-network L2/L1 migration logic + CCIP routing + CRE allow-list, against forks of mainnet state | `just test-acceptance`, `just test-<network>-upgrade`, `just test-cre-integration` |
| **State-mate post-condition diff** | ≥45 live-RPC assertions per network against a canonical `*.yaml` (admin/role layout, OraclePool / SyncTrigger / CREReceiver immutables, allow-list entries) | `just test-<network>-upgrade-state-verify <rpc>` (mainnet); `just -E .env.sepolia test-sepolia-upgrade-state-verify` (testnet) |
| **Per-network anvil-fork dress rehearsal** ([§ below](#per-network-dress-rehearsal-on-anvil-forks)) | The exact `deploy-stage1` → `verify-stage1` → `migrate-stage2` → state-mate verify recipe sequence, on an anvil fork of one L2 + L1. Stresses the operator's mainnet command surface (impersonating Initial Owner where the cold key is unavailable). | Manual sequence — see [§ Per-network dress rehearsal on anvil forks](#per-network-dress-rehearsal-on-anvil-forks). |
| **Sepolia rehearsal** | Real Sepolia + Optimism Sepolia state, same `runDeploy` / `runVerifyStage1` / `runMigrate` shape as the four mainnet scripts. Catches script-wiring + state-mate-yaml regressions. Does *not* cover per-network adapters / DAO vote / LOL handoff — see [`README.md` §Sepolia as a rehearsal of the mainnet migration](../README.md#sepolia-as-a-rehearsal-of-the-mainnet-migration). | `just -E .env.sepolia sepolia-deploy-csr` → `sepolia-deploy-stage1` → `sepolia-verify-stage1` → `sepolia-migrate-stage2` → `sepolia-upgrade-l1` → `test-sepolia-upgrade-state-verify` |

The remainder of this doc covers layer 1 (the original Optimism-focused CCIP fork test) and layer 3 (per-network anvil-fork dress rehearsal); layers 2 and 4 are described inline in the root `README.md`.

# Testing Upgrade with Chainlink Local (CCIP)

Primary files:
- `/Users/arwer/projects/lido-direct-staking/test/OptimismPoolUpgrade.t.sol`
- `/Users/arwer/projects/lido-direct-staking/test/helpers/OptimismUpgradeTestBase.sol`
- `/Users/arwer/projects/lido-direct-staking/script/optimism/OptimismMigrationConstants.sol`

Primary end-to-end test:
- `test_upgradeSyncRoutesAcrossL2AndL1CCIPLayer`

## 1. Setup

1. Install dependencies:
   ```sh
   git submodule update --init --recursive
   just setup
   ```
2. Ensure `.env` contains:
   ```env
   L1_RPC_URL=...
   L2_OPTIMISM_RPC_URL=...
   ```

## 2. Run

1. Run only the CCIP upgrade test:
   ```sh
   forge test --match-test test_upgradeSyncRoutesAcrossL2AndL1CCIPLayer -vv
   ```
2. Run the full upgrade suite:
   ```sh
   forge test --match-contract OptimismPoolUpgradeTest -vv
   ```

## 3. How CCIP is mocked (official fork pattern)

The test follows the Chainlink Local forked simulator flow:

1. Create L1 and L2 forks with `vm.createFork(...)`.
2. Deploy `CCIPLocalSimulatorFork` in `setUp()` and keep it alive across forks:
   - `vm.makePersistent(address(ccipLocalSimulatorFork))`
3. Register network details for chain IDs `1` (Ethereum) and `10` (Optimism) using:
   - `ccipLocalSimulatorFork.setNetworkDetails(...)`
4. Execute upgrade steps on L2 and L1.
5. On L2, perform `fastStake` to accumulate WETH in the pool.
6. On L2, call `sync(...)` and capture CCIP logs:
   - `vm.recordLogs()`
7. Route the recorded CCIP message to L1 using:
   - `ccipLocalSimulatorFork.switchChainAndRouteMessage(l1Fork)`
8. Verify on L1:
   - message processed (`getFailedMessageHash(messageId) == 0`)
   - receiver stakes and increases wstETH balance
   - adapter dispatch event is emitted

## 4. Notes

- This is the **Chainlink Local fork simulator** approach (not hand-built `Any2EVMMessage` injection).
- It validates upgrade behavior together with actual router/off-ramp execution path on forked state.
- The tested L1->L2 return path on Optimism uses `OptimismLegacyAdapterL1toL2` because Lido is configured with a dedicated L1 token bridge (`0x76943C0D61395d8F2edF9060e1533529cAe05dE6`) rather than a generic OP-stack `L1StandardBridge` adapter.

## 5. Troubleshooting

- If Foundry crashes with `SCDynamicStoreBuilder` on macOS, run tests outside restricted sandbox/container environments.

# Per-network dress rehearsal on anvil forks

Distinct from `just test-acceptance` (which runs the combined `runWithUnlockedInitialOwner()` Stage 1+2 entrypoint across all four networks at once), this layer exercises the **exact recipe sequence** the operator will run on mainnet — `deploy-stage1` → `verify-stage1` → `migrate-stage2` → `test-<net>-upgrade-state-verify` — against an anvil fork of one L2 + Ethereum mainnet. Use it before launching the real per-network migration to confirm:

- the recipes wire env vars / args correctly end-to-end with no copy-paste hazard,
- Stage-1 broadcast JSON parsing (the `export L2_ORACLE_POOL=…` lines) emits the right addresses,
- `verify-stage1` accepts the just-deployed contracts,
- `migrate-stage2` lands clean post-conditions on top of live mainnet state,
- the canonical `script/<net>/state-mate/<net>.yaml` (rendered from the template with the rehearsal addresses) passes against the post-migration fork.

The walkthrough below uses **Linea** (the most-recently-validated lane). Substitute `linea` → `optimism` / `arbitrum` / `base` and the corresponding env / address constants from `script/<net>/<Net>MigrationConstants.sol` to rehearse the others.

## Prerequisites

- `.env` with `L1_RPC_URL` (Ethereum mainnet) and `L2_LINEA_RPC_URL` (Linea mainnet upstream) set.
- `L2_LIDO_DEPLOYER_PRIVATE_KEY` set — any funded EOA works on a fork; anvil's first dev key (`0xac09...ff80` → `0xf39F…2266`) is the convention used by the existing `_acceptance-test`.
- Tools: `forge`, `cast`, `anvil`, `jq`, `yq`, `node`, `yarn` (or `corepack`).
- `lib/state-mate/node_modules` populated — `corepack yarn install --immutable` inside `lib/state-mate` if not.

## 0. Read-only sanity checks (no fork yet)

Run these against the upstream RPCs before spinning up forks. They must all be green before there is any value in the rehearsal.

```sh
# Forge fork tests (Linea pool upgrade + CRE integration) — 26 tests
forge test --match-contract 'LineaPoolUpgradeTest|LineaCREIntegrationTest' \
  --fork-url "$L2_LINEA_RPC_URL" -vv

# Constants drift check — Solidity ↔ state-mate yaml ↔ justfile case blocks
just verify-constants-sync

# Read-only L2 + L1 preflights against real Linea + Ethereum mainnet.
# Both recipes read L2_NETWORK + L2_RPC_URL / L1_RPC_URL from .env.linea; ensure the file
# sets L2_NETWORK=linea and pins L2_RPC_URL=$L2_LINEA_RPC_URL (and L1_RPC_URL=$L1_RPC_URL)
# so they target the right upstreams for the dress rehearsal.
just -E .env.linea preflight-check
just -E .env.linea preflight-check-l1
```

## 1. Spawn anvil forks

```sh
# L1 (Ethereum mainnet) on port 8650 — the L1 LidoCustomReceiver lives here.
anvil --silent --auto-impersonate -p 8650 -f "$L1_RPC_URL" \
  >/tmp/linea-rehearsal-l1.log 2>&1 &

# Linea fork on port 8651 — the L2 CustomSender + new contracts deploy here.
anvil --silent --auto-impersonate -p 8651 -f "$L2_LINEA_RPC_URL" \
  >/tmp/linea-rehearsal-l2.log 2>&1 &

# Wait until both forks are responsive
until cast chain-id --rpc-url http://127.0.0.1:8650 >/dev/null 2>&1 \
   && cast chain-id --rpc-url http://127.0.0.1:8651 >/dev/null 2>&1; do
  sleep 1
done
```

Expected: `cast chain-id --rpc-url http://127.0.0.1:8650` → `1`, port 8651 → `59144`.

(The `just rpc-start-l2-linea` recipe wraps the L2 anvil at port 8554 if you prefer it — but the rehearsal walkthrough below assumes 8651 to avoid colliding with anything an operator might already have running.)

Fund the three actors so they can broadcast:

```sh
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266    # Lido Deployer (L2_LIDO_DEPLOYER_PRIVATE_KEY)
INITIAL_OWNER=0xb5c336a5c60D3482b29d83C742C65AE8351b91a8  # cold key holder, impersonated on the fork
LIDO_DAO_AGENT=0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c # L1 admin recipient

for url in http://127.0.0.1:8650 http://127.0.0.1:8651; do
  cast rpc --rpc-url "$url" anvil_setBalance "$DEPLOYER"      0x3635C9ADC5DEA00000 >/dev/null
  cast rpc --rpc-url "$url" anvil_setBalance "$INITIAL_OWNER" 0x3635C9ADC5DEA00000 >/dev/null
  cast rpc --rpc-url "$url" anvil_setBalance "$LIDO_DAO_AGENT" 0x3635C9ADC5DEA00000 >/dev/null
done
```

## 2. Stage 1 — `deploy-stage1` on Linea fork

```sh
export L2_NETWORK=linea
export L2_GOVERNANCE_EXECUTOR=0x2897A1b134050c01503843db48e034d4C9e2b18c   # LineaMigrationConstants
export L2_CRE_FORWARDER=0x000000000000000000000000000000000000dEaD          # placeholder — real CRE Forwarder isn't exercised on a fork

L2_RPC_URL=http://127.0.0.1:8651 just deploy-stage1
```

The recipe broadcasts `runDeploy()` and parses `broadcast/LineaL2Upgrade.s.sol/59144/runDeploy-latest.json` to print the three deployed addresses as export-ready lines. Paste them into the shell:

```sh
export L2_ORACLE_POOL=0x...
export L2_SYNC_TRIGGER=0x...
export L2_CRE_RECEIVER=0x...
```

## 3. Verify Stage 1 (read-only, anyone)

```sh
L2_RPC_URL=http://127.0.0.1:8651 just verify-stage1
```

`L2_NETWORK`, `L2_ORACLE_POOL`, `L2_SYNC_TRIGGER`, `L2_CRE_RECEIVER` come from your shell exports above; `L2_RPC_URL` is inlined to point at the fork.

A clean exit means all 18 Stage-1 post-condition reads passed (OraclePool + SyncTrigger + CREReceiver immutables, allow-list, expectedAuthor, plus guardrails that Stage 2 has *not* yet run).

## 4. Stage 2 — `migrate-stage2` on the fork (impersonated Initial Owner)

The mainnet `just migrate-stage2` recipe broadcasts `runMigrate()` and requires the cold-key `INITIAL_OWNER_PRIVATE_KEY`. On a fork we don't have that key, so we call `runMigrateUnlocked()` directly via `forge script` with `anvil_impersonateAccount`:

```sh
export INITIAL_OWNER=0xb5c336a5c60D3482b29d83C742C65AE8351b91a8
cast rpc --rpc-url http://127.0.0.1:8651 anvil_impersonateAccount "$INITIAL_OWNER" >/dev/null

ALLOW_UNSAFE_COMBINED_RUN=1 \
forge script script/linea/LineaL2Upgrade.s.sol:LineaL2UpgradeScript \
  --sig 'runMigrateUnlocked()' \
  --rpc-url http://127.0.0.1:8651 \
  --broadcast --non-interactive \
  --unlocked --sender "$INITIAL_OWNER"
```

`ALLOW_UNSAFE_COMBINED_RUN=1` is required because the script's production guard (`L2UpgradeSingleRunUnsafe`) trips on the mainnet chain-id (59144) inherited by the fork. `runMigrateUnlocked()` itself only runs Stage 2 — Stage 1 already happened in §2.

Successful broadcast lands the seven on-chain post-conditions checked inside `executeMigrationSteps`: new pool wired, `SYNC_ROLE` rotated, `DEFAULT_ADMIN` rotated, ProxyAdmin owner transferred.

## 5. State-mate verification against the fork

`just test-linea-upgrade-state-verify` runs against `script/linea/state-mate/linea.yaml`. That file pins production-target addresses (the CRE workflow / mainnet rehearsal output), so it won't match the fork's freshly-deployed contracts. Render the template into a temp dir instead, copy the ABI, and run state-mate directly:

```sh
mkdir -p /tmp/linea-rehearsal
cp -R script/linea/state-mate/abi /tmp/linea-rehearsal/

sed \
  -e "s|__L2_CUSTOM_SENDER__|0x328de900860816d29D1367F6903a24D8ed40C997|g" \
  -e "s|__L2_PROXY_ADMIN__|0x4c8c4A15c1e810e481c412A9B06Be5f79dC02192|g" \
  -e "s|__INITIAL_OWNER__|$INITIAL_OWNER|g" \
  -e "s|__L2_GOVERNANCE_EXECUTOR__|$L2_GOVERNANCE_EXECUTOR|g" \
  -e "s|__L2_LIQUIDITY_OWNER__|0xA8EF4Db842d95DE72433a8B5b8fF40cB9C74c1B6|g" \
  -e "s|__L2_LIDO_DEPLOYER__|$DEPLOYER|g" \
  -e "s|__L2_ORACLE_POOL__|$L2_ORACLE_POOL|g" \
  -e "s|__L2_SYNC_TRIGGER__|$L2_SYNC_TRIGGER|g" \
  -e "s|__L2_CRE_RECEIVER__|$L2_CRE_RECEIVER|g" \
  script/linea/state-mate/linea-l2-upgrade.template.yaml \
  > /tmp/linea-rehearsal/linea.yaml

(cd lib/state-mate \
 && L2_STATE_MATE_RPC_URL=http://127.0.0.1:8651 \
    corepack yarn start /tmp/linea-rehearsal/linea.yaml --only l2)
```

Expected tail: `✔ Total: 46 checks passed` (5 `getForwarder` / fee-blob / timestamp checks emit `⚠ skipped` because they're set after CRE workflow deploy, which the fork rehearsal does not cover).

## 6. L1 admin migration on the L1 fork

`just migrate-l1` requires `INITIAL_OWNER_PRIVATE_KEY` (no impersonated variant in `L1UpgradeScript`). Mirror what `_acceptance-test` does and issue the three underlying calls via `cast send --unlocked`:

```sh
L1_RECEIVER=0x6F357d53d6bE3238180316BA5F8f11467e164588
L1_PROXY_ADMIN_ADDR=0x88a45d2760b63c1500E3D2E3552b28e5Cdaa37BD
ZERO_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000

cast rpc --rpc-url http://127.0.0.1:8650 anvil_impersonateAccount "$INITIAL_OWNER" >/dev/null

cast send --unlocked --from "$INITIAL_OWNER" --rpc-url http://127.0.0.1:8650 \
  "$L1_RECEIVER" "grantRole(bytes32,address)" "$ZERO_ROLE" "$LIDO_DAO_AGENT"
cast send --unlocked --from "$INITIAL_OWNER" --rpc-url http://127.0.0.1:8650 \
  "$L1_RECEIVER" "revokeRole(bytes32,address)" "$ZERO_ROLE" "$INITIAL_OWNER"
cast send --unlocked --from "$INITIAL_OWNER" --rpc-url http://127.0.0.1:8650 \
  "$L1_PROXY_ADMIN_ADDR" "transferOwnership(address)" "$LIDO_DAO_AGENT"
```

Spot-check the post-conditions (these are what the script's `_requireL1PostCondition` would assert):

```sh
cast call "$L1_RECEIVER" "hasRole(bytes32,address)(bool)" "$ZERO_ROLE" "$LIDO_DAO_AGENT" --rpc-url http://127.0.0.1:8650   # → true
cast call "$L1_RECEIVER" "hasRole(bytes32,address)(bool)" "$ZERO_ROLE" "$INITIAL_OWNER"  --rpc-url http://127.0.0.1:8650   # → false
cast call "$L1_PROXY_ADMIN_ADDR" "owner()(address)"       --rpc-url http://127.0.0.1:8650                                  # → 0x3e40…9C8c (LIDO_DAO_AGENT)
```

## 7. Cleanup

```sh
pkill -f 'anvil .*-p 8650'
pkill -f 'anvil .*-p 8651'
rm -rf /tmp/linea-rehearsal /tmp/linea-rehearsal-l1.log /tmp/linea-rehearsal-l2.log
```

## What the rehearsal does and does NOT cover

Covers:
- The exact `just deploy-stage1` / `verify-stage1` / `migrate-stage2` recipe surface that runs on mainnet.
- All on-chain post-conditions (Solidity-internal in §2/§4, plus 46 state-mate reads in §5, plus 3 hand-checks in §6).
- That the canonical state-mate template renders cleanly with the live deployed addresses.

Does **not** cover (these match the gaps `just test-acceptance` and the Sepolia rehearsal also have):
- The CRE workflow deployment (`just deploy-cre-workflow`) and registration (`just verify-cre-workflow`) — these target the real Chainlink `WorkflowRegistry` on Ethereum mainnet and a live CRE DON, neither of which exists on the fork. The fork uses the `0x…dEaD` placeholder for `L2_CRE_FORWARDER`; `getForwarder` checks therefore appear as state-mate `⚠ skipped`.
- A real CCIP send → L1 receive (the forge fork tests in §0 cover this via the Chainlink Local simulator).
- LOL multisig wstETH transfer to the new `OraclePool` (off-chain, post-Stage 2).
- The Aragon DAO vote that hands `LIDO_DAO_AGENT` its powers — the fork just impersonates the address.
