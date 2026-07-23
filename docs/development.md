> **View — developer guide.** Stakeholder: a developer working in this repo.
> Concern: building, the direct `forge script` reference for debugging, and the
> test layers (unit / CRE / fork-integration / dress rehearsal). The migration
> *recipe* an operator runs lives in [`RUNBOOK.md`](../RUNBOOK.md); this is the
> developer-facing toolbox behind it. Doc map:
> [`README.md` §Documentation](../README.md#documentation).

# Script reference (direct `forge script` / debugging)

The operator procedure is in **[`RUNBOOK.md`](../RUNBOOK.md)**. This table is only the network → script-path mapping for direct `forge script` invocations or debugging. The L1 `LidoCustomReceiver` is one contract shared by all four lanes, so its admin migration is shared — `script/l1/L1UpgradeScript.s.sol:L1UpgradeScript`, run once via `just migrate-l1`.

| Network  | L2 Script                                                          | Env file        |
|----------|--------------------------------------------------------------------|-----------------|
| Optimism | `script/optimism/OptimismL2Upgrade.s.sol:OptimismL2UpgradeScript`  | `.env.optimism` |
| Arbitrum | `script/arbitrum/ArbitrumL2Upgrade.s.sol:ArbitrumL2UpgradeScript`  | `.env.arbitrum` |
| Base     | `script/base/BaseL2Upgrade.s.sol:BaseL2UpgradeScript`              | `.env.base`     |
| Linea    | `script/linea/LineaL2Upgrade.s.sol:LineaL2UpgradeScript`           | `.env.linea`    |

# Tests

## Pool upgrade tests (fork-based)

- Shared harness:
  - `test/helpers/UpgradeTestBase.sol`
  - `test/helpers/PoolUpgradeTests.sol`
- Network-specific suites (20 tests each):
  - `test/OptimismPoolUpgrade.t.sol`
  - `test/ArbitrumPoolUpgrade.t.sol`
  - `test/BasePoolUpgrade.t.sol`
  - `test/LineaPoolUpgrade.t.sol`
- Network-specific bases:
  - `test/helpers/OptimismUpgradeTestBase.sol`
  - `test/helpers/ArbitrumUpgradeTestBase.sol`
  - `test/helpers/BaseUpgradeTestBase.sol`
  - `test/helpers/LineaUpgradeTestBase.sol`
- Coverage includes: L1/L2 role and ownership migration, fast/slow stake behavior after pool swap, old pool isolation, liquidity provision/sweep, and sync path across CCIP routing.

```sh
# All networks (requires L1_RPC_URL + respective L2 RPC)
forge test

# Individual networks
just test-optimism-upgrade
just test-arbitrum-upgrade
```

Notes:
- Each fork suite requires a working `L1_RPC_URL` and the corresponding `L2_*_RPC_URL`.
- `just test-arbitrum-upgrade` prefers `LOCAL_L2_ARBITRUM_RPC_URL` when present and otherwise falls back to `L2_ARBITRUM_RPC_URL`.

## CRE tests

- `test/CREReceiverTest.t.sol` — 40 unit tests for the CREReceiver contract (no fork required; incl. the argument-less call-lock)
- `test/CREIntegrationTest.t.sol` — 10 fork-based integration tests per network (Optimism, Arbitrum, Base, Linea = 40 total), covering the full CRE Forwarder → CREReceiver → SyncTrigger → sync path. Includes `test_productionExpectedAuthorIsLolMultisig`, which asserts the production deploy pins `expectedAuthor` to the **LOL multisig** (== owner == CRE workflow owner, ≠ the Stage-1 deployer EOA) and that a Safe-authored report is accepted while a deployer-authored report is rejected (ADR-0001)
- `test/helpers/CREIntegrationTests.sol` — shared CRE test logic (same pattern as `PoolUpgradeTests.sol`)
- `cre-workflows/sync-automation/main.test.ts` — 9 TypeScript tests for workflow encoding/decoding logic
- `test/L2PinnedConstantsGuard.t.sol` — RPC-free guard test: the governance executor, predecessor OraclePool, and CRE forwarder resolve straight from the per-network constants (never env); a production lane returns its pinned values and an unpinned network reverts — see [DOC.md §6.3](../DOC.md#63-how-the-final-state-is-verified)

```sh
# Unit tests only (no RPC required)
just test-cre-receiver

# Integration tests (requires L1_RPC_URL + L2_OPTIMISM_RPC_URL)
just test-cre-integration

# All Solidity CRE tests
just test-cre

# TypeScript workflow tests
just test-cre-workflow

# Everything (Solidity + TypeScript)
just test-cre-all
```

Note: the workflow tests shell out to `bun test`, so Bun must be installed and available on `PATH`.

## Optimism state-mate command split

The upgrade-state flow is split into dedicated commands:
- `just test-optimism-upgrade-state-migrate [rpc_url]`
- `just test-optimism-upgrade-state-update-config [rpc_url]`
- `just test-optimism-upgrade-state-verify` — reads `L2_RPC_URL` (or legacy `L2_STATE_MATE_RPC_URL` / `LOCAL_L2_OPTIMISM_RPC_URL` / `L2_OPTIMISM_RPC_URL`) from env; no positional

And one glue command that runs all phases on a dedicated nested fork:
- `just test-optimism-upgrade-state`

Purpose of each phase:
- `migrate`: executes `OptimismL2UpgradeScript` against the target RPC and persists migration outputs.
- `update-config`: regenerates the deployed-address sibling `config/state/l2-optimism.deployed.yaml` from the resolved addresses (the shared wiring `config/state/l2.yaml` and the `l2-optimism.inputs.yaml` sibling are static, hand-maintained).
- `verify`: runs `state-mate` checks against an arbitrary RPC.

Required env:
- `L2_LIDO_DEPLOYER_PRIVATE_KEY`

(The governance executor is pinned in `OptimismMigrationConstants.sol` and read by the recipe/script — not env.)

RPC env:
- For `test-optimism-upgrade-state`: one upstream source: `L2_STATE_MATE_UPSTREAM_RPC_URL` or `LOCAL_L2_OPTIMISM_RPC_URL` or `L2_OPTIMISM_RPC_URL`.
- For split commands: pass `[rpc_url]`, or set `L2_STATE_MATE_RPC_URL` (fallback: migration output file, then `LOCAL_L2_OPTIMISM_RPC_URL`, `L2_OPTIMISM_RPC_URL`).

Optional env:
- `L2_LIQUIDITY_OWNER` (defaults to the pinned `LIDO_L2_GOVERNANCE_EXECUTOR` constant)
- `INITIAL_OWNER_PRIVATE_KEY` (if omitted, migration uses unlocked/impersonated `INITIAL_OWNER` on anvil-compatible RPCs)
- `INITIAL_OWNER` (defaults to `OptimismMigrationConstants.INITIAL_OWNER`)
- `L2_STATE_MATE_FORK_PORT` (default: `8651`)
- `L2_STATE_MATE_OUTPUT_FILE` (default: `/tmp/optimism-l2-state-mate.env`)
- `L2_STATE_MATE_SYNC_TRIGGER` (needed for `update-config` if not available in output file)

Run all phases on dedicated fork:

```sh
just test-optimism-upgrade-state
```

Operational notes:
- The glue command prefers `L2_STATE_MATE_UPSTREAM_RPC_URL`, then `LOCAL_L2_OPTIMISM_RPC_URL`, then `L2_OPTIMISM_RPC_URL`.
- If `LOCAL_L2_OPTIMISM_RPC_URL` is set but no local fork is listening there, the nested Anvil fork will fail to start; either run `just rpc-start-l2-optimism` first or override `L2_STATE_MATE_UPSTREAM_RPC_URL`.
- `test-optimism-upgrade-state-update-config` rewrites the tracked file `config/state/l2-optimism.deployed.yaml`, so expect a worktree diff after running it.

## Test layers (overview)

Four independent layers of pre-prod validation, increasing in realism:

| Layer | Exercises | Recipe |
| --- | --- | --- |
| Forge fork tests + Chainlink Local CCIP simulator | Per-network L2/L1 migration logic + CCIP routing + CRE allow-list against mainnet forks | `just test-acceptance`, `just test-<net>-upgrade`, `just test-cre-integration` |
| state-mate post-condition diff | ≥45 live-RPC assertions per network vs the shared `config/state/l2.yaml` + per-lane `.inputs`/`.deployed` siblings | `just test-<net>-upgrade-state-verify` |
| Per-network anvil-fork dress rehearsal (below) | The exact canary recipe sequence (`deploy-test → verify-test → activate → simulate-sync → handoff → finalize → state-verify`) on an anvil fork of one L2 + L1 | manual (below) |

## CCIP fork simulation (Chainlink Local)

The pool-upgrade end-to-end test (`test_upgradeSyncRoutesAcrossL2AndL1CCIPLayer`) drives a real CCIP round-trip across L1/L2 forks via the Chainlink Local simulator: create both forks, `makePersistent` the `CCIPLocalSimulatorFork`, register chain details, `fastStake` to accrue WETH, `sync()` with `recordLogs`, route the message to L1, then assert the receiver stakes + the adapter dispatch event fires.

**Why the test carries its own v1.6 router (`test/helpers/CCIPv16ForkRouter.sol`).** `lib/chainlink-local` is pinned at v0.2.3, whose `switchChainAndRouteMessage` matches **only** the legacy v1.5 OnRamp event (`CCIPSendRequested`). The Arbitrum/Base/Optimism mainnet L2→L1 lanes have migrated to CCIP **v1.6** (`CCIPMessageSent` — a different topic), so the simulator silently fails to decode, the receiver never runs, and `_assertAndGetAdapterDispatch` fails. Linea still works (still v1.5). Bumping to v0.2.5+ isn't viable: those versions expect `@chainlink/contracts-ccip` import paths that conflict with `chainlink-csr`'s remapping. The helper papers over this for v1.6 lanes by `deal`-ing the destination tokens and calling `ccipReceive` directly via `vm.prank(L1_CCIP_ROUTER)` — same `msg.sender` + message struct the receiver would see from a real off-ramp. If `chainlink-local` is ever bumped to ≥v0.2.5 (and import paths reconciled), delete the helper and restore the direct simulator call.

## Per-network anvil-fork dress rehearsal

Distinct from `just test-acceptance` (which drives the canary state machine across all four networks at once), this exercises the **exact recipe sequence** an operator runs on mainnet — `deploy-test → verify-test → activate → simulate-sync → handoff → finalize → test-<net>-upgrade-state-verify` — against an anvil fork of one L2 + Ethereum mainnet. It confirms the recipes wire env/args correctly end-to-end, that the deploy broadcast-JSON parsing emits the right `export` addresses, and that the canonical state-mate template renders + passes against the post-finalize fork. The walkthrough uses **Linea** (substitute the network + its `script/<net>/<Net>MigrationConstants.sol` to rehearse the others). On a fork the cold Initial-Owner key is absent, so the Initial-Owner steps (`activate`, `finalize`) call the `*Unlocked` script entrypoints directly under an impersonated sender instead of the keyed recipes.

**Prereqs:** `.env` with `L1_RPC_URL` + `L2_LINEA_RPC_URL`; `L2_LIDO_DEPLOYER_PRIVATE_KEY` (any funded EOA works on a fork — anvil dev key `0xf39F…2266` is the convention); `forge`/`cast`/`anvil`/`jq`/`yq`/`node`/`yarn`; `lib/state-mate/node_modules` populated (`corepack yarn install --immutable` inside `lib/state-mate`).

**0. Read-only sanity (no fork yet)** — all green before there is any value in rehearsing:

```sh
forge test --match-contract 'LineaPoolUpgradeTest|LineaCREIntegrationTest' --fork-url "$L2_LINEA_RPC_URL" -vv
just verify-constants-sync
just -E .env.linea preflight-check
just -E .env.linea preflight-check-l1
```

**1. Spawn forks** (L1 on :8650, Linea on :8651) and fund the three actors:

```sh
anvil --silent --auto-impersonate -p 8650 -f "$L1_RPC_URL"       >/tmp/rehearsal-l1.log 2>&1 &
anvil --silent --auto-impersonate -p 8651 -f "$L2_LINEA_RPC_URL" >/tmp/rehearsal-l2.log 2>&1 &
until cast chain-id --rpc-url http://127.0.0.1:8650 >/dev/null 2>&1 \
   && cast chain-id --rpc-url http://127.0.0.1:8651 >/dev/null 2>&1; do sleep 1; done
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266       # Lido Deployer (L2_LIDO_DEPLOYER_PRIVATE_KEY)
INITIAL_OWNER=0xb5c336a5c60D3482b29d83C742C65AE8351b91a8  # cold key holder, impersonated on the fork
LIDO_DAO_AGENT=0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c # L1 admin recipient
for url in http://127.0.0.1:8650 http://127.0.0.1:8651; do
  for a in "$DEPLOYER" "$INITIAL_OWNER" "$LIDO_DAO_AGENT"; do
    cast rpc --rpc-url "$url" anvil_setBalance "$a" 0x3635C9ADC5DEA00000 >/dev/null; done; done
```

Expected: chain-id on :8650 → `1`, on :8651 → `59144`.

**2. Stage 0→1 — `deploy-test`** (Lido Deployer) on the Linea fork (paste the printed `export` lines into the shell):

```sh
export L2_NETWORK=linea
# Governance executor, old pool, and CRE forwarder are pinned per network in code (LineaMigrationConstants) — no env needed
L2_RPC_URL=http://127.0.0.1:8651 just deploy-test
# → export L2_ORACLE_POOL=…  L2_SYNC_TRIGGER=…  L2_CRE_RECEIVER=…  L2_TEST_DEPLOYER=…
```

The three contracts are deployed **deployer-owned**, with the deployer wired as the `CREReceiver` forwarder + author and the **test** `minAmount`/`delay` from the `config/state/l2.inputs.test-stage.yaml` overlay, so the deployer can drive a real sync before any handoff.

**3. Verify Stage 0→1** (read-only): `L2_RPC_URL=http://127.0.0.1:8651 just verify-test` — a clean exit means the canary post-condition reads passed (immutables, allow-list, deployer-as-forwarder/author, pool repointed not yet, seal not run).

**4. Stage 0→1 — `activate`** (impersonated Initial Owner): repoint CustomSender at the new pool and grant the new SyncTrigger `SYNC_ROLE`. The fork lacks the cold key, so call `runActivateUnlocked()` directly:

```sh
export INITIAL_OWNER=0xb5c336a5c60D3482b29d83C742C65AE8351b91a8
cast rpc --rpc-url http://127.0.0.1:8651 anvil_impersonateAccount "$INITIAL_OWNER" >/dev/null
forge script script/linea/LineaL2Upgrade.s.sol:LineaL2UpgradeScript \
  --sig 'runActivateUnlocked()' --rpc-url http://127.0.0.1:8651 \
  --broadcast --non-interactive --unlocked --sender "$INITIAL_OWNER"
```

This is reversible — `runRollbackUnlocked()` (repoint old pool + revoke `SYNC_ROLE`) undoes it without governance.

**5. Stage 1 — simulate a sync** (Lido Deployer): seed the pool past the test `minAmount`, wait the test `delay`, then drive `CREReceiver.onReport` directly (the deployer is the canary forwarder + author):

```sh
L2_RPC_URL=http://127.0.0.1:8651 just seed-test-weth
cast rpc --rpc-url http://127.0.0.1:8651 evm_increaseTime 61 >/dev/null
cast rpc --rpc-url http://127.0.0.1:8651 evm_mine >/dev/null
L2_RPC_URL=http://127.0.0.1:8651 just simulate-sync
```

A successful broadcast runs `onReport → triggerSync → CustomSender.sync` — the end-to-end proof the canary exists to provide.

**6. Stage 1→2 — `handoff`** (Lido Deployer): sweep test residue, restore production config (real CRE forwarder + LOL author + production delay/amounts), top up the float, and transfer all three contracts to the LOL multisig:

```sh
L2_RPC_URL=http://127.0.0.1:8651 just handoff
# optional: L2_RPC_URL=http://127.0.0.1:8651 just verify-stage2   (LOL-owned + production-configured, seal not run)
```

**7. Stage 2→3 — `finalize`** (impersonated Initial Owner): the irreversible governance seal — revoke old automation(s), migrate CustomSender admin + L2 ProxyAdmin to the governance executor. Call `runFinalizeUnlocked()` directly:

```sh
forge script script/linea/LineaL2Upgrade.s.sol:LineaL2UpgradeScript \
  --sig 'runFinalizeUnlocked()' --rpc-url http://127.0.0.1:8651 \
  --broadcast --non-interactive --unlocked --sender "$INITIAL_OWNER"
```

**8. State-mate against the fork.** All four lanes share one wiring file, `config/state/l2.yaml`, parametrized per lane by its `--inputs`/`--deployed` siblings. The committed `l2-linea.deployed.yaml` holds the production-target addresses; for the fork, write the freshly-deployed addresses to a throwaway `.deployed.yaml` and override the committed sibling with `--deployed` (the static `l2-linea.inputs.yaml` must be passed explicitly, since sibling auto-discovery is basename-keyed for the shared file; the `abi/` dir is auto-discovered from the shared config's directory):

```sh
mkdir -p /tmp/linea-rehearsal
bash script/shared/write-deployed-yaml.sh /tmp/linea-rehearsal/linea.deployed.yaml \
    0x328de900860816d29D1367F6903a24D8ed40C997 0xBf96561e4519182CFA4cebBf95494D9CA5a316f9 0x4c8c4A15c1e810e481c412A9B06Be5f79dC02192 \
    "$L2_ORACLE_POOL" "$L2_SYNC_TRIGGER" "$L2_CRE_RECEIVER"
ROOT="$(git rev-parse --show-toplevel)"
(cd lib/state-mate && L2_STATE_MATE_RPC_URL=http://127.0.0.1:8651 \
  corepack yarn start "$ROOT/config/state/l2.yaml" \
    --inputs "$ROOT/config/state/l2-linea.inputs.yaml" \
    --deployed /tmp/linea-rehearsal/linea.deployed.yaml --only l2)
```

Expected: all L2 checks pass against the **production** profile (this is the post-`finalize` state — LOL-owned, governance-sealed, real CRE forwarder, production delay/amounts). `getFeeOtoD`/`getFeeDtoO`/`getForwarder` are asserted; only deployment-time/runtime values (`getLastExecution`, the governance action-set counters) emit `⚠ skipped`.

**9. L1 admin migration** on the L1 fork (no impersonated variant in `L1UpgradeScript`, so issue the three calls via `cast send --unlocked`):

```sh
L1_RECEIVER=0x6F357d53d6bE3238180316BA5F8f11467e164588
L1_PROXY_ADMIN_ADDR=0x88a45d2760b63c1500E3D2E3552b28e5Cdaa37BD
ZERO_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
cast rpc --rpc-url http://127.0.0.1:8650 anvil_impersonateAccount "$INITIAL_OWNER" >/dev/null
cast send --unlocked --from "$INITIAL_OWNER" --rpc-url http://127.0.0.1:8650 "$L1_RECEIVER" "grantRole(bytes32,address)" "$ZERO_ROLE" "$LIDO_DAO_AGENT"
cast send --unlocked --from "$INITIAL_OWNER" --rpc-url http://127.0.0.1:8650 "$L1_RECEIVER" "revokeRole(bytes32,address)" "$ZERO_ROLE" "$INITIAL_OWNER"
cast send --unlocked --from "$INITIAL_OWNER" --rpc-url http://127.0.0.1:8650 "$L1_PROXY_ADMIN_ADDR" "transferOwnership(address)" "$LIDO_DAO_AGENT"
```

**10. Cleanup:** `pkill -f 'anvil .*-p 8650'; pkill -f 'anvil .*-p 8651'; rm -rf /tmp/linea-rehearsal /tmp/rehearsal-l*.log`

**The rehearsal does NOT cover** (same gaps as `test-acceptance`): the CRE workflow deploy + registration (real `WorkflowRegistry` + live DON — `handoff` rewires the receiver to the per-network pinned forwarder constant, but no live DON originates reports on the fork); a real CCIP send → L1 receive (the step-0 forge fork tests cover that via the Chainlink Local simulator); the LOL multisig wstETH seed; the Aragon DAO vote (the fork just impersonates `LIDO_DAO_AGENT`).
