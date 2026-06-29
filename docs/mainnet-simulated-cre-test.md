> **View — the canary mainnet deploy flow.** Stakeholder: migration operator
> (Lido Deployer + Initial Owner) and LOL. Concern: deploying the new pool +
> `SyncTrigger` + `CREReceiver` **deployer-owned**, validating a full on-chain
> sync with the deployer standing in for the CRE forwarder, then handing off to
> LOL and sealing governance. The actor model + final-state invariants live in
> [`DOC.md` §3.2](../DOC.md); the CRE workflow lifecycle in
> [`docs/cre.md`](cre.md); the operator gate checklist in
> [`RUNBOOK.md`](../RUNBOOK.md). Doc map:
> [`README.md` §Documentation](../README.md#documentation).

# Mainnet migration as a 5-state machine (deployer-simulated CRE)

The migration runs as a state machine `0 → 1 → 2 → 3 → 4` with a `1 → 0` rollback. The new contracts are deployed **owned by the Lido Deployer**, with the deployer standing in for the Chainlink Keystone forwarder *and* the workflow author so it can drive `CREReceiver.onReport()` directly and exercise the whole on-chain sync chain. After a clean test the deployer restores the **real** CRE config + production sync params and transfers ownership to LOL; LOL brings up the production CRE workflow; the Initial Owner seals governance; LOL funds the pool. Production sync params are unchanged (`delay = 12h`, `minSyncAmount = 5e18`).

```
                      ┌──────────── 1→0 roll back ────────────┐
                      ▼            (Aphyla)                     │
 ┌─────────┐  0→1   ┌──────────┐  1→2   ┌──────────────┐  2→3   ┌──────────────┐  3→4   ┌──────────────┐
 │ Stage 0 │ ─────▶ │ Stage 1  │ ─────▶ │   Stage 2    │ ─────▶ │   Stage 3    │ ─────▶ │   Stage 4    │
 │ initial │        │  canary  │        │ pre-ownership│        │    final.    │        │    final.    │
 │  state  │        │ testing  │        │  migration   │        │ unvalidated  │        │  validated   │
 └─────────┘        └──────────┘        └──────────────┘        └──────────────┘        └──────────────┘
```

## Actors

- **Deployer** — Lido Deployer EOA (`L2_LIDO_DEPLOYER_PRIVATE_KEY`). Deploys the three contracts; is the `CREReceiver` forwarder **and** author during the test; drives `onReport`; sweeps test residue; restores production config; transfers ownership to LOL. No standing on-chain power after handoff.
- **Aphyla** — the **current owner / Initial Owner** (external admin holding `CustomSender` `DEFAULT_ADMIN_ROLE` + L2 ProxyAdmin + the L1 Receiver admin/ProxyAdmin). Repoints the oracle pool, grants/revokes `SYNC_ROLE`, can roll back, and performs the irreversible governance seal (L2 + L1). Fully revoked after the seal.
- **LOL** — Liquidity Owner Safe. Receives ownership of pool/`SyncTrigger`/`CREReceiver` (passive — OZ single-step `Ownable`); **signs/registers the CRE workflow** from the Safe; **funds the pool** with production liquidity.

## States — on-chain invariants

| State | Invariants |
|---|---|
| **0 initial** | old pool active; old automation has `SYNC_ROLE`; Aphyla = `CustomSender` admin + L2 ProxyAdmin; L1 Receiver admin + ProxyAdmin = Aphyla; no new contracts |
| **1 canary testing** | pool + `SyncTrigger` + `CREReceiver` deployed on all 4 networks, **deployer-owned**; `CREReceiver.forwarder = expectedAuthor = deployer`, allow-list seeded; `SyncTrigger` has **test** `delay`/`minAmount` + funded float; `CustomSender` repointed to the new pool; `SyncTrigger` holds `SYNC_ROLE`; **Aphyla still admin, old automation still syncable** |
| **2 pre-ownership migration** | test passed + swept; the three contracts **LOL-owned**; `CREReceiver` = **real forwarder + LOL author**; production `delay`/`minSyncAmount`; **CRE workflow registered + active (LOL)**; **but** admin + ProxyAdmin still = Aphyla; old automation still has `SYNC_ROLE`; pool unfunded |
| **3 final.unvalidated** | governance sealed — L2 admin + ProxyAdmin = Gov Executor; old automation revoked; L1 = Lido DAO. `state-mate` not yet run; pool unfunded |
| **4 final.validated** | `state-mate` green on all networks + L1; pool funded by LOL; `fastStake` live; production CRE driving syncs |

## Transitions — every actor's actions (recipe ⇒ entrypoint)

Each recipe is one broadcast by one actor: `just -E .env.<network> <recipe>`.

### 0 → 1 — deploy + activate (repeat per network ×4)
- Pre-reqs: Deployer funded with ETH (fees + float + test WETH); `preflight-check`, `preflight-check-l1`, `verify-constants-sync` green.
- **Deployer:** `deploy-test` ⇒ `runDeployTest()` — deploy the three contracts deployer-owned, `CREReceiver` forwarder + author = deployer, `SyncTrigger` test `delay`/`minAmount` + funded float. Then `verify-test` ⇒ `runVerifyTest()`.
- **Deployer (off the critical path):** `verify-sources` — publish the three contracts' Solidity source to the lane explorer (Etherscan v2; one `ETHERSCAN_API_KEY` covers all 4 lanes). Re-runnable + idempotent and recovers the **actual** on-chain constructor args via `--guess-constructor-args` (so it matches the deployer-owned/test-valued canary build); the same contracts persist through `handoff`, so this also verifies the production deploy. Changes no on-chain state.
- **Aphyla:** `activate` ⇒ `runActivate()` — `setOraclePool(newPool)` + `grantRole(SYNC_ROLE, syncTrigger)`. Leaves admin + old automation intact. *(Reversible.)*

### Stage 1 — canary testing (Deployer)
- `seed-test-weth` — deposit ETH→WETH and transfer ≥ test `minAmount` to the pool.
- `simulate-sync` ⇒ `runSimulateSync()` — craft Keystone `metadata` (workflowOwner = deployer) + `report` (`abi.encode(syncTrigger, triggerSync.selector)`) and call `CREReceiver.onReport`. Runs `onReport → triggerSync → CustomSender.sync` (fee fronted from the SyncTrigger float — no value on the call, exactly like production). Validate `CallExecuted` + `Sync` + wstETH returns to the pool.
- **Non-destructive fork rehearsal (keyless, CI):** `just -E .env.<net> test-<net>-canary-acceptance` runs the same `onReport → triggerSync → CustomSender.sync` value-flow on an **in-process fork** of the live chain (`test_canarySyncOnDeployedAddresses`). It binds to the real on-chain canary addresses from `config/state/l2-<net>.deployed.yaml` — auto-detected as deployer-owned via `verifyCanaryStage1` — and **skips the deploy**; with no `.deployed.yaml` it falls back to a fresh on-fork deploy (so the same recipe runs pre- and post-`deploy-test`). Costs no gas, needs no key, mutates no real state: the CI-runnable sibling of `simulate-sync` (which broadcasts for real). Point its RPC at a mainnet upstream; it also forks L1, so `L1_RPC_URL` is required. Refuses to run (loud `require`) if the supplied addresses are deployed but past the canary stage (handed off / sealed).

### 1 → 0 — roll back (Aphyla)
- `rollback` ⇒ `runRollback()` — `setOraclePool(oldPool)` + `revokeRole(SYNC_ROLE, syncTrigger)`. The old automation was never revoked, so the predecessor system is fully restored.

### 1 → 2 — handoff (Deployer) + CRE workflow (LOL)
- **Deployer:** `handoff` ⇒ `runHandoff()` — sweep test residue; restore production config (`setForwarder(realCRE)`, `setExpectedAuthor(LOL)`, `setDelay(12h)`, `setAmounts(5e18,100e18)`); top the float back up; `transferOwnership(→ LOL)` on all three. The closing assertion against **production** values reverts the whole handoff if any restore was missed.
- **LOL:** `update-cre-config` + `deploy-cre-workflow` — register the production CRE workflow from the Safe (workflow owner = LOL = `expectedAuthor`); verify it now owns the three contracts.
- Gate: `verify-stage2` ⇒ `runVerifyStage2()`.

### 2 → 3 — governance seal (Aphyla, irreversible)
- `finalize` ⇒ `runFinalize()` — revoke old automation(s) `SYNC_ROLE`; `migrateSenderAdmin` (→ Gov Executor); `transferProxyAdminOwnership` (→ Gov Executor). Refuses to run unless the infra is already LOL-owned + production-configured. Then `migrate-l1` once after all 4 L2s.

### 3 → 4 — validate + go-live
- **LOL:** fund the pool with production wstETH liquidity (so `fastStake` is live and the pool accumulates WETH for real syncs).
- **Operator:** run `state-mate` + the verify recipes on all 4 networks + L1; **monitor the first production CRE sync** via `postflight-monitor`.

## What this tests vs. skips

- **Tests:** pool + `CREReceiver` (forwarder/author/allow-list/nullary guards) + `SyncTrigger` (predicates/delay/float/`canSync`) + `CustomSender.sync` + CCIP forward leg + L1 staking + wstETH bridge-back.
- **Skips (accepted):** the **real** Keystone forwarder's ERC-165 gating and the DON delivering a report — covered by `just verify-cre-forwarder` + the `supportsInterface` tests, and by close monitoring of the first production sync.

## state-mate: production default + `--overrides` canary overlay

`config/state/l2.yaml` ships the **production profile**: the 7 checks that `handoff` restores reference the production anchors (`*l2LiquidityOwner`, `*l2CreForwarder`, `*syncDelay`, `*syncMinAmount`), all defined in `config/state/l2-<net>.inputs.yaml`. The final (post-handoff, 3→4) run verifies these **directly — no overlay, no edits**.

For the **pre-handoff canary** state, apply the shared overlay `config/state/l2.inputs.test-stage.yaml` via state-mate's `--overrides` (or use the `test-<net>-upgrade-state-verify-canary` recipes). It redefines those four anchors to the deployer/test values the canary sets: `l2LiquidityOwner` + `l2CreForwarder` → the deployer (it owns the infra and stands in for the CRE forwarder + author), `syncMinAmount` → `0.05e18`, `syncDelay` → `60`. One file serves all four lanes (the canary values are lane-invariant). state-mate enforces, per lane, that every overlay label already exists in the base, keeps its section, and changes value; `just verify-externals-coverage` mirrors all three pre-commit (no RPC).

The `customSender` ACL + `proxyAdmin.owner` flip at `finalize` (not `handoff`), so they stay production-pinned here and pass only post-seal — at Stage 1 the Solidity `verify-test` (`runVerifyTest`) covers them.

- **Validate the canary at Stage 1:** `just -E .env.<net> test-<net>-upgrade-state-verify-canary` (adds `--overrides config/state/l2.inputs.test-stage.yaml`). For a **mainnet** canary, set the overlay's two deployer addresses (`l2LiquidityOwner` / `l2CreForwarder`) to the real deployer (`L2_TEST_DEPLOYER` from `deploy-test`) **locally and uncommitted** first.
- **After `handoff`:** drop `--overrides` (run the plain `test-<net>-upgrade-state-verify`) for the 3→4 production run. The deployer ≠ LOL, so a stale overlay fails loudly — it cannot false-pass.

| `l2.yaml` check | production anchor (base) | canary value (overlay) |
|---|---|---|
| `oraclePool.owner` | `*l2LiquidityOwner` | deployer |
| `syncTrigger.owner` | `*l2LiquidityOwner` | deployer |
| `syncTrigger.getDelay` | `*syncDelay` (12h) | `60` |
| `syncTrigger.getAmounts[0]` | `*syncMinAmount` (5e18) | `0.05e18` |
| `creReceiver.owner` | `*l2LiquidityOwner` | deployer |
| `creReceiver.getForwarder` | `*l2CreForwarder` | deployer |
| `creReceiver.getExpectedAuthor` | `*l2LiquidityOwner` | deployer |

## Safety notes

- **`fastStake` downtime during Stage 1:** the repointed new pool is un-seeded, so user `fastStake` reverts until LOL funds it at 3→4. Keep Stage 1 short.
- **Reversibility is control-plane only:** a test sync moves real ETH — already-bridged wstETH and in-flight CCIP messages can't be undone (the wstETH is `sweep`-recoverable from the test pool). Rollback is offered only from Stage 1; after 1→2 the contracts are LOL's.
- **Keep the old automation's `SYNC_ROLE` until `finalize`** so 1→0 fully restores today's system.
- **Handoff config-restore is load-bearing:** forgetting the real forwarder / LOL author / 12h / 5e18 before transfer misconfigures production — caught by the production assertion in `handoff` and by `state-mate` at 3→4.
- **Aphyla's external-admin window** spans Stages 1–2 — bound it explicitly.
