# Migration Operations Plan

Migrates each L2 from the legacy `SyncAutomation` to a CRE-driven `SyncTrigger` + `CREReceiver`, and transfers L1/L2 admin rights from the Initial Owner to Lido DAO governance. Identical sequence for each of **Optimism, Arbitrum, Base, Linea** — networks are independent and may be migrated in any order. The per-network sequence below is linear within a network but fully parallelizable across networks for each actor (Lido Deployer can run Stage 1 on all four concurrently; Initial Owner can fan out Stage 2 the same way). L1 migration runs exactly once.

## Actors

| Actor | Key | Role |
|---|---|---|
| **Lido Deployer** | hot | Stage 1 L2 broadcast; CRE workflow owner (off-chain) |
| **Initial Owner** | cold | Stage 2 L2 + L1 admin-transfer broadcast |
| **Lido DAO Agent** | n/a | Receives `DEFAULT_ADMIN` on L2 CustomSender / L1 Receiver; new owner of L1 ProxyAdmin |
| **L2 Governance Executor** | n/a | Receives `DEFAULT_ADMIN` on L2 CustomSender; new owner of L2 ProxyAdmin, SyncTrigger |

## Pre-flight (once, all networks)

1. Dry-run end-to-end on forks + state-mate: `just test-acceptance`. All 4 networks green ⇒ approved to proceed.
2. Constants drift check: `just verify-constants-sync`. Confirms the state-mate yamls and justfile preflight case blocks still match the canonical `*MigrationConstants.sol` libraries — must be green before any per-network step.
3. *Optional, recommended before the first per-network mainnet run* — per-network anvil-fork dress rehearsal. Runs the exact `deploy-stage1` → `verify-stage1` → `migrate-stage2` → state-mate verify recipe sequence on an anvil fork of the chosen L2 + Ethereum mainnet, with `INITIAL_OWNER` impersonated. Distinct from step 1, which uses the combined `runWithUnlockedInitialOwner()` entrypoint across all four networks at once; this stresses the per-network operator command surface. Walkthrough (Linea, generalizable to the other three): [`TESTING.md` §Per-network dress rehearsal on anvil forks](TESTING.md#per-network-dress-rehearsal-on-anvil-forks).
4. *Optional* Sepolia rehearsal (against real Sepolia + Optimism Sepolia state, not just forks): exercises the same `runDeploy` / `runVerifyStage1` / `runMigrate` shape as the four mainnet scripts, plus the same state-mate validator engine via `just -E .env.sepolia test-sepolia-upgrade-state-verify`. See [`README.md` §Sepolia testnet deployment](../README.md#sepolia-testnet-deployment) for the full sequence and the [`README.md` §Sepolia as a rehearsal of the mainnet migration](../README.md#sepolia-as-a-rehearsal-of-the-mainnet-migration) for what the rehearsal does and does not cover (script wiring + post-condition shape: yes; per-network adapters + DAO/Aragon vote + LOL handoff: no).

## Per-network sequence

1. **Preflight** (read-only)
   ```sh
   just -E .env.<network> preflight-check
   just -E .env.<network> preflight-check-l1
   ```
   Both recipes read `L2_NETWORK` plus `L2_RPC_URL` / `L1_RPC_URL` from `.env.<network>`.
   `preflight-check` runs five checks: (1) chain-id, (2) CustomSender bytecode, (3) legacy `SyncAutomation.getLastExecution()` age (Chainlink-Automation upkeep only — for Linea also reminds about the separate Gelato bot), (4) old oracle-pool WETH + wstETH balances, (5) `cast logs` scan of `CustomSender.Sync(...)` events over the last ~12 h — the authoritative "is a sync in flight" gate, since `Sync` fires on every code path. `<12 h` ⇒ waiting is best-practice but not required (proceeding is safe — see [README §Migration ordering and in-flight transactions](../README.md#migration-ordering-and-in-flight-transactions)). `preflight-check-l1` confirms the shared L1 `LidoCustomReceiver` has a non-zero adapter and the expected sender wired up for this network's CCIP chain selector. The 12 h window matches `L2_SYNC_DELAY` (= `minSyncDelay`).

2. **Stage 1 — deploy new contracts** · *Actor: Lido Deployer*
   ```sh
   env (from .env.<network>): L2_NETWORK, L2_RPC_URL, L2_LIDO_DEPLOYER_PRIVATE_KEY, L2_GOVERNANCE_EXECUTOR, L2_CRE_FORWARDER
   just -E .env.<network> deploy-stage1
   ```
   Deploys new `OraclePool`, `SyncTrigger`, `CREReceiver`. `CREReceiver.expectedAuthor` is pinned to the Lido Deployer address at construction. Record the three addresses from the forge broadcast JSON (`broadcast/<Network>L2Upgrade.s.sol/<chainId>/runDeploy-latest.json`).

3. **Verify Stage 1** (read-only, callable by anyone — no private key)
   ```sh
   just -E .env.<network> verify-stage1
   ```
   Reads `L2_ORACLE_POOL` / `L2_SYNC_TRIGGER` / `L2_CRE_RECEIVER` from `.env.<network>`. Reverts with a descriptive key on any mismatch. Covers 18 on-chain checks: OraclePool immutables (SENDER, TOKEN_IN/OUT, oracle, fee, owner, unpaused); SyncTrigger immutables + config (SENDER, DEST_CHAIN_SELECTOR, WNATIVE, delay, amounts, feeOtoD/DtoO byte-match); CREReceiver forwarder/expectedAuthor/allow-list/owner; guardrails that Stage 2 has NOT yet run. Fails loudly if deploy was configured wrong or if Stage 2 executed prematurely.

4. **Update CRE workflow config**
   ```sh
   just -E .env.<network> update-cre-config
   ```
   Reads `L2_SYNC_TRIGGER` / `L2_CRE_RECEIVER` from `.env.<network>`. Rewrites `cre-workflows/sync-automation/config.deploy.<network>.json`. Refuses zero/placeholder addresses.

5. **Deploy CRE workflow** · *Actor: Lido Deployer (off-chain)*
   ```sh
   just -E .env.<network> deploy-cre-workflow
   ```
   Workflow owner recorded on `WorkflowRegistry` (Ethereum mainnet) = Lido Deployer = `CREReceiver.expectedAuthor`, so the authorization check passes at runtime. The workflow fires on schedule but reverts inside `SyncTrigger.triggerSync()` until step 7 grants `SYNC_ROLE`. Capture the `workflowId` from the CLI output and paste it as `CRE_WORKFLOW_ID=…` into `.env.<network>`.

6. **Verify CRE workflow registration** (read-only, on Ethereum L1 `WorkflowRegistry`)
   ```sh
   just -E .env.<network> verify-cre-workflow
   ```
   Reads `CRE_WORKFLOW_ID` from `.env.<network>`. Queries `WorkflowRegistry 2.0.0` at `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5` via `getWorkflowById(workflowId)`. Asserts: workflow is registered, `owner == L2_LIDO_DEPLOYER_ADDRESS`, `status == ACTIVE`. Reverts with a descriptive key on any mismatch; prints full metadata (name, tag, donFamily, configUrl, createdAt) for visual inspection.

7. **Stage 2 — migrate admin** · *Actor: Initial Owner*
   ```sh
   env (from .env.<network>): L2_NETWORK, L2_RPC_URL, INITIAL_OWNER_PRIVATE_KEY, L2_GOVERNANCE_EXECUTOR, L2_ORACLE_POOL, L2_SYNC_TRIGGER
   just -E .env.<network> migrate-stage2
   ```
   Atomically: points `CustomSender.getOraclePool` → new pool; grants `SYNC_ROLE` to new SyncTrigger; revokes `SYNC_ROLE` from legacy automation(s); grants `DEFAULT_ADMIN` on CustomSender to L2 Governance Executor and revokes from Initial Owner; transfers L2 ProxyAdmin ownership to L2 Governance Executor. 7 on-chain post-condition reads; broadcast reverts on any mismatch.

8. **State-mate verification**
   ```sh
   just -E .env.<network> test-<network>-upgrade-state-verify
   ```
   Runs ≥45 live-RPC checks: new OraclePool set; `SYNC_ROLE` held only by new SyncTrigger (revoked from legacy); `DEFAULT_ADMIN` held only by Governance Executor; L2 ProxyAdmin owned by Governance Executor; `CREReceiver.getExpectedAuthor` = Lido Deployer; allow-list `(syncTrigger, triggerSync()) = true`.

## L1 migration (once, shared across all networks)

```sh
env (from any .env.<network>): L1_RPC_URL, INITIAL_OWNER_PRIVATE_KEY, LIDO_DAO_AGENT
just -E .env.<any-network> migrate-l1
```

Grants `DEFAULT_ADMIN` on L1 `LidoCustomReceiver` to the Lido DAO Agent and revokes from Initial Owner; transfers L1 `ProxyAdmin` ownership to Lido DAO Agent. The L1 Receiver is shared across all L2s, so this runs **once**; the recipe invokes the shared `script/l1/L1UpgradeScript.s.sol:L1UpgradeScript`.

## Safe-to-abort checkpoints

- **Between step 1 and step 2** — no on-chain state changed; safe to defer indefinitely.
- **Between step 2 and step 5** — new contracts are deployed but idle (no pool liquidity, no role); the legacy path is still authoritative. Re-run from step 2 later with fresh addresses, or leave dangling.
- **After step 5** — legacy automation's `SYNC_ROLE` is revoked atomically in the same broadcast. A failed post-condition reverts the whole broadcast; simply fix the issue and re-run step 5.

## Monitoring (ongoing, per-network)

| Signal | Source | Expectation |
|---|---|---|
| Workflow firing | `CREReceiver.CallExecuted` event | one per scheduled tick |
| Sync emitted | `CustomSender.Sync(user, destChainSelector, messageId, amount)` (fires inside `triggerSync()` → `CustomSender.sync()`) | follows each tick |
| CCIP delivery | [ccip.chain.link](https://ccip.chain.link/) (sender → L1 Receiver) | `Success` within lane SLA |
| CRE credit balance | CRE dashboard (workflow owner) | top up before depletion — allocation is administrative during Early Access (no CLI command); coordinate with Chainlink. See [`LEVERS.md` Off-chain (CRE Platform)](LEVERS.md#off-chain-cre-platform-sync-workflow) for the billing model. |
