> **View — post-migration monitoring & alerts.** Stakeholder: on-call / SRE.
> Concern: the *ongoing* signals to watch once a network is live (access-control
> invariants, trapped funds, sync liveness, CRE health, capacity) — distinct from
> the one-time migration *recipe* in [`RUNBOOK.md`](../RUNBOOK.md), whose §Watch
> section is the action-trigger tether into this canonical alert table. Doc map:
> [`README.md` §Documentation](../README.md#documentation).

# Monitoring & alerts (post-migration)

Post-migration monitoring for the shared L1 Receiver + the 4 L2 deployments. Signals marked **(×4)** apply per network; all four must be watched. The state-polling rows map directly to the state-mate configs in `config/state/` (shared `l2.yaml` wiring + per-network `.inputs`/`.deployed` siblings); the event-subscription rows should be wired into an indexer (Tenderly, Dune, or similar). Thresholds in parentheses are starting points — tune after the first week of observation.

| Severity | Meaning | Response |
| --- | --- | --- |
| **CRITICAL** | Fund loss or access-control breach | Page on-call immediately |
| **HIGH** | Sync stalled, funds stuck, or ops-visible incident | Business-hours response |
| **MEDIUM** | Capacity headroom eroding (will fail later) | Investigate before exhaustion |

## 1. Access-control invariants — CRITICAL

Any deviation = key compromise or unintended governance action.

| Contract | Getter | Expected |
|---|---|---|
| L1 Receiver | `hasRole(DEFAULT_ADMIN_ROLE, LidoDaoAgent)` / `getRoleMemberCount(DEFAULT_ADMIN_ROLE)` | `true` / `1` |
| L1 ProxyAdmin | `owner()` | Lido DAO Agent |
| L2 CustomSender (×4) | `hasRole(DEFAULT_ADMIN_ROLE, L2GovExecutor)` / `getRoleMemberCount` | `true` / `1` |
| L2 CustomSender (×4) | `hasRole(SYNC_ROLE, newSyncTrigger)` / `getRoleMemberCount(SYNC_ROLE)` | `true` / `1` |
| L2 CustomSender (×4) | `getOraclePool()` | new OraclePool |
| L2 ProxyAdmin (×4) | `owner()` | L2 Gov Executor |
| SyncTrigger (×4) | `owner()` | LOL multisig |
| SyncTrigger (×4) | `getForwarder()` | CREReceiver |
| CREReceiver (×4) | `owner()` / `getForwarder()` / `getExpectedAuthor()` | LOL multisig / CRE Forwarder / **LOL multisig** (owner == expectedAuthor == CRE workflow owner; ADR-0001) |
| CREReceiver (×4) | `isCallAllowed(SyncTrigger, 0x340b2b0b)` | `true` |
| OraclePool (×4) | `owner()` | LOL multisig |

**Events — alert on any emit:** `RoleGranted` / `RoleRevoked` (L1 Receiver, L2 CustomSender ×4); `OwnershipTransferred` (every ProxyAdmin, SyncTrigger, CREReceiver, OraclePool); `ForwarderUpdated` / `ExpectedAuthorUpdated` / `AllowedCallUpdated` (CREReceiver ×4).

## 2. Trapped / unexpected funds — CRITICAL

| Signal | Expected | Recovery |
|---|---|---|
| L1 Receiver ETH / stETH / wstETH balance | ~0 (transient during stake; alert if > 1 ETH for > 1 h) | Lido DAO governance |
| L1 Receiver any unexpected ERC20 | 0 | `recoverTokens` via governance |
| `LidoCustomReceiver.MessageFailed` (L1) | **none — page on-call** | `retryFailedMessage` (anyone) or `recoverTokens` (DAO) |
| CCIP OffRamp manual-execution queue (×4) | empty | [ccip.chain.link](https://ccip.chain.link/) → manual exec, higher gas |
| Arbitrum retryable auto-redeem failures | 0 | [retryable-dashboard.arbitrum.io](https://retryable-dashboard.arbitrum.io/) (≤ 7-day manual redeem, then lost) |

## 3. Sync liveness — HIGH

Fund-safety does not degrade if sync stalls, but UX does: `fastStake` WETH accumulates and wstETH liquidity depletes.

| Signal | Expected |
|---|---|
| Time since `SyncTrigger.getLastExecution()` advance (×4) | < 24 h while pool WETH ≥ `minSyncAmount` |
| OraclePool WETH balance (×4) | drains each sync; alert if growing > 24 h despite accrual |
| `CustomSender.Sync(messageId)` (L2) ↔ `LidoCustomReceiver.MessageSucceeded(messageId)` (L1) | 1:1 within CCIP SLA (~20 min); a missing pair = stuck/failed message. Anchor on `MessageSucceeded` (not `ccipReceive`) so a defensive-catch failure breaks the invariant cleanly — the catch path emits `MessageFailed`, not `MessageSucceeded`. |
| L1 Adapter bridge call ↔ new OraclePool wstETH increase (L2) | 1:1 within bridge SLA (per network) |
| `CREReceiver.CallExecuted` rate (×4) | ≥ 1 per `syncDelay` (12 h) when pool WETH ≥ `minSyncAmount` |
| CREReceiver revert rate via CRE Forwarder (×4) | 0 |
| `SyncTrigger.shouldSync()` true while `canSync()` false (×4) | none sustained — `shouldSync` (due-ness) true while `canSync` (executability) false means **due but not executable**: a **stall the DON suppresses silently** (it logs `blocked` and emits **no** report, so §3 `CallExecuted` stays flat with no revert spam). Root cause is one of: float < `getMaxFees().maxNativeFee` (§5), `SYNC_ROLE` revoked (§1), or OraclePool paused (below). The pairing `shouldSync() && !canSync()` (also `getAmountToSync() > 0`) **distinguishes a *blocked* lane from a merely *idle* one** |
| CCIP lane: dest-chain allow-list (`IRouterClient.isChainSupported(DEST_CHAIN_SELECTOR)`) + RMN curse state (×4) | supported / uncursed. **`canSync` deliberately does NOT gate on these** (unlike float / `SYNC_ROLE` / pause — see its NatSpec; the RMN curse has no single stable view to mirror, and the allow-list is omitted too to keep the predicate free of CCIP-version coupling). So a CCIP **de-allow-list or RMN curse** leaves both `shouldSync` and `canSync` returning `true` and every `triggerSync` reverts INSIDE the router — this surfaces as **revert-spam** (the `CREReceiver revert rate` row above spikes), NOT a clean due-but-`!canSync` stall. Subscribe to CCIP allow-list / RMN curse events and page on-call; the lane self-heals once re-allow-listed / un-cursed (`_lastExecution` rolls back on each revert, so it stays armed) |
| OraclePool `Paused` event (×4) | subscribe; any emit = ops incident (blocks fastStake) |

## 4. CRE workflow health & funding — HIGH

The workflow owner is the **LOL multisig (Safe)** (ADR-0001), so the owner-identity and funding signals below are checked against the **Safe address / the Safe's CRE account**, never an EOA.

| Signal | Expected | How / where |
|---|---|---|
| `WorkflowRegistry.getWorkflowById(id).owner` (×4) | **LOL multisig (Safe)** address | `just -E .env.<network> verify-cre-workflow` (anchors to the on-chain `CREReceiver.getExpectedAuthor()`); alert on any change — a non-Safe owner = mis-deploy or registry tamper. **This confirms only the *registry owner* field — NOT that the DON embeds the Safe in report metadata** (see the author-gate caveat below) |
| `CREReceiver.CallExecuted` observed at least once (×4) — **the only proof the author gate passes** | seen after the first due sync | The registry-owner check above and `getExpectedAuthor()` are *different surfaces* from the DON-embedded `metadata.workflowOwner`. If the DON embeds a different address (CRE Early-Access residual (a), [ADR-0001](adr/0001-cre-workflow-owner-multisig.md)), every report is rejected (`InvalidAuthor`) and **syncs silently never fire** despite a green registry-owner check. A single observed `CallExecuted` from the live DON path is the proof the pin matches — gate on it before trusting the lane (see RUNBOOK G2) |
| `WorkflowRegistry` workflow status (×4) | `ACTIVE` (enum 0) | same read; `PAUSED` = syncs stopped (intentional pause or owner action) |
| `WorkflowRegistry` `OwnershipTransferRequested`/`-Accepted` / `WorkflowPaused` / `WorkflowDeleted` events (×4) | none unexpected | subscribe on L1 `0x4Ac5…E7e5`; any emit not preceded by a known LOL-Safe tx = page on-call |
| **CRE credit balance** for the workflow owner's account (the LOL Safe) | **> top-up threshold** (tune after week 1) | [CRE dashboard](https://cre.chain.link/workflows). Credits are **off-chain and opaque**: the CRE CLI exposes **no** `fund` / `deposit` / `withdraw` / `balance` command (Early Access, verified April 2026), so there is **no on-chain signal** — observability is **dashboard-only**, watched manually / by scraping the dashboard. Depletion → DON stops executing → silent sync stall (shows up indirectly as §3 liveness: `getLastExecution` not advancing while pool WETH ≥ min). Coordinate top-up with Chainlink against the **Safe's** account before the threshold; re-verify the funding mechanism before GA |

> **Funding observability caveat.** Because credit is administrative and dashboard-only during Early Access, treat §3 sync-liveness (`getLastExecution` advance + `CallExecuted` rate) as the **on-chain proxy** for "is the workflow funded and running." A liveness stall with healthy fees and a funded SyncTrigger float points at **credit starvation** — check the CRE dashboard balance for the LOL Safe account first. The Lido Deployer EOA holds **no** CRE credits and is not a funding surface to watch.

## 5. Capacity / headroom — MEDIUM

Alert on ≥ 2 consecutive crossings to filter transient spikes.

| Signal | Expected | Action |
|---|---|---|
| actual CCIP fee / `SyncTrigger.getFeeOtoD().maxFee` (×4) | < 80% | raise `maxFee` before exhaustion. On **Optimism/Linea** this ratio also climbs with **sync size** (CCIP charges 5 bps, uncapped — not only L1 gas price); the 100 WETH `maxAmount` cap holds it to ~40%, so a higher reading suggests `maxAmount` was raised — see [fee amount-sensitivity](otod-fee-amount-sensitivity.md). |
| `ccipReceive` gas used / `FeeOtoD.gasLimit` (×4) | < 80% | raise `gasLimit` before OOG reverts (kept ≤ `getMaxGasLimit()` — `setFeeOtoD` rejects an over-cap bump with `SyncTriggerGasLimitAboveMax`) |
| `SyncTrigger.getMaxGasLimit()` (×4) vs lane FeeQuoter `maxPerMsgGasLimit` | equal (3M Linea / 7M others) — the config-time ceiling mirrors the live cap | subscribe to `MaxGasLimitSet`; if CCIP changes a lane cap, re-seed via `setMaxGasLimit` so the guard stays aligned with `sync`-time reality |
| SyncTrigger ETH balance / `getMaxFees().maxNativeFee` (×4) | ≥ 2× (1× is the hard floor — below it the next sync reverts with the named `SyncTriggerInsufficientFloat` and `canSync()` returns `false`, so the lane stalls but the DON stops submitting) | top up — permissionless ETH send to the trigger ([Funding the float](fees.md#feeotodmaxfee-free-per-sync-but-it-is-the-per-sync-blast-radius-bound)). Depletion is monotonic (~`actualFee` per sync), so this **will** cross eventually |
| Arbitrum auto-redeem success rate | 100% | raise `maxGas` / `gasPriceBid` |

## Intentionally excluded (not alerts)

- **Old OraclePool residual balance** — expected > 0 until the Initial Liquidity Owner (`0x2897A1…b18c`) sweeps once; not an ongoing signal.
- **Legacy `SyncAutomation` / Gelato upkeep status** — one-shot cleanup; revocation asserted by state-mate at migration time.
- **Lido DAO votes touching L1 Receiver / ProxyAdmin** — expected governance activity, visible on-chain.
- **Fork-test / CI results** — development concern, not production monitoring.

