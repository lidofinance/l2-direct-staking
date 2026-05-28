# Alerts Specification

Post-migration monitoring for the Lido Direct Staking CSR deployment.

**Scope:** Ethereum L1 Receiver + 4 L2 deployments (Optimism, Arbitrum, Base, Linea). Signals marked **(×4)** apply per-network; all four must be watched.

**Severities**

| Severity     | Meaning                                            | Response                      |
| ------------ | -------------------------------------------------- | ----------------------------- |
| **CRITICAL** | Fund loss or access-control breach                 | Page on-call immediately      |
| **HIGH**     | Sync stalled, funds stuck, or ops-visible incident | Business-hours response       |
| **MEDIUM**   | Capacity headroom eroding (will fail later)        | Investigate before exhaustion |

Implementation note: the state-polling rows map directly to the state-mate YAMLs in `script/<network>/state-mate/`. The event-subscription rows should be wired into an indexer (Tenderly, Dune, or similar). Thresholds in parentheses are starting points; tune after first week of observation.

---

## 1. Access-control invariants — CRITICAL

Any deviation = key compromise or unintended governance action.

### State to poll

| Contract | Getter | Expected |
|---|---|---|
| L1 Receiver | `hasRole(DEFAULT_ADMIN_ROLE, LidoDaoAgent)` | `true` |
| L1 Receiver | `getRoleMemberCount(DEFAULT_ADMIN_ROLE)` | `1` |
| L1 ProxyAdmin | `owner()` | Lido DAO Agent |
| L2 CustomSender (×4) | `hasRole(DEFAULT_ADMIN_ROLE, L2GovExecutor)` | `true` |
| L2 CustomSender (×4) | `getRoleMemberCount(DEFAULT_ADMIN_ROLE)` | `1` |
| L2 CustomSender (×4) | `hasRole(SYNC_ROLE, newSyncTrigger)` | `true` |
| L2 CustomSender (×4) | `getRoleMemberCount(SYNC_ROLE)` | `1` |
| L2 CustomSender (×4) | `getOraclePool()` | new OraclePool |
| L2 ProxyAdmin (×4) | `owner()` | L2 Gov Executor |
| SyncTrigger (×4) | `owner()` | L2 Gov Executor |
| SyncTrigger (×4) | `getForwarder()` | CREReceiver |
| CREReceiver (×4) | `owner()` | LOL multisig |
| CREReceiver (×4) | `getForwarder()` | CRE Forwarder |
| CREReceiver (×4) | `getExpectedAuthor()` | Lido Deployer |
| CREReceiver (×4) | `isCallAllowed(SyncTrigger, 0x340b2b0b)` | `true` |
| OraclePool (×4) | `owner()` | LOL multisig |

### Events — alert on any emit (push-style detection)

| Contract | Event |
|---|---|
| L1 Receiver, L2 CustomSender (×4) | `RoleGranted`, `RoleRevoked` |
| L1 ProxyAdmin, L2 ProxyAdmin (×4), SyncTrigger (×4), CREReceiver (×4), OraclePool (×4) | `OwnershipTransferred` |
| CREReceiver (×4) | `ForwarderUpdated`, `ExpectedAuthorUpdated`, `AllowedCallUpdated` |

---

## 2. Trapped / unexpected funds — CRITICAL

| Signal | Expected | Recovery |
|---|---|---|
| L1 Receiver ETH balance | ~0 (transient during stake only — alert if > 1 ETH for > 1 h) | Lido DAO governance |
| L1 Receiver stETH / wstETH balance | ~0 (transient) | Lido DAO governance |
| L1 Receiver any unexpected ERC20 | 0 | `recoverTokens` via governance |
| CCIP OffRamp manual-execution queue (sender → L1 Receiver, ×4) | empty | [ccip.chain.link](https://ccip.chain.link/) → manual exec with higher gas |
| Arbitrum retryable auto-redeem failures | 0 | [retryable-dashboard.arbitrum.io](https://retryable-dashboard.arbitrum.io/) (≤ 7-day manual redeem window, then lost) |

---

## 3. Sync liveness — HIGH

Fund-safety does not degrade if sync stalls, but user experience does: fastStake WETH accumulates and wstETH liquidity depletes.

| Signal | Expected |
|---|---|
| Time since `SyncTrigger.getLastExecution()` advance (×4) | < 24 h while pool WETH ≥ `minSyncAmount` |
| OraclePool WETH balance (×4) | drains on each sync; alert if growing continuously > 24 h despite accrual |
| `CustomSender.Sync(_, _, messageId, _)` (L2) ↔ `LidoCustomReceiver.MessageSucceeded(messageId)` (L1) | 1:1 within CCIP SLA (~20 min); a missing pair = stuck or failed message |
| L1 Adapter bridge call ↔ new OraclePool wstETH increase (L2) | 1:1 within bridge SLA (per-network) |
| `CREReceiver.CallExecuted` rate (×4) | ≥ 1 per `syncDelay` (12 h) when pool WETH ≥ `minSyncAmount` |
| CREReceiver revert rate (via CRE Forwarder, ×4) | 0 |
| OraclePool `Paused` event (×4) | subscribe; any emit = ops incident (blocks fastStake) |

---

## 4. CRE workflow health — HIGH

| Signal | Expected |
|---|---|
| `WorkflowRegistry.getWorkflowById(id).owner` (×4) | Lido Deployer |
| `WorkflowRegistry` workflow status (×4) | `ACTIVE` (enum value 0) |
| CRE credit / LINK balance (workflow owner) | > top-up threshold (top-up is administrative — no `cre fund` / `deposit` command exists during Early Access; see [`LEVERS.md` billing model](LEVERS.md#off-chain-cre-platform-sync-workflow) for the procedure) |

---

## 5. Capacity / headroom — MEDIUM

Alert on ≥ 2 consecutive crossings to filter transient spikes.

| Signal | Expected | Action |
|---|---|---|
| actual CCIP fee / `SyncTrigger.getFeeOtoD().maxFee` (×4) | < 80% | raise `maxFee` before exhaustion |
| `ccipReceive` gas used / `FeeOtoD.gasLimit` (×4) | < 80% | raise `gasLimit` before OOG reverts |
| Arbitrum auto-redeem success rate | 100% | raise `maxGas` / `gasPriceBid` |

---

## Intentionally excluded (not alerts)

- **Old OraclePool residual balance** — expected > 0 until the Initial Liquidity Owner (`0x2897A1…b18c`, current `owner()` of all four old pools) sweeps once; not an ongoing signal.
- **Legacy `SyncAutomation` / Gelato upkeep registration status** — one-shot cleanup; revocation asserted by state-mate at migration time.
- **Lido DAO votes touching L1 Receiver / ProxyAdmin** — expected governance activity, visible on-chain.
- **Fork-test / CI results** — development concern, not production monitoring.
