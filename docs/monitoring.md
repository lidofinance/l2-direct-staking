# Monitoring and Alerts

Monitor all four lanes and the shared Ethereum receiver. `just postflight-monitor`
is a read-only spot check with best-effort recent event scans. It exits nonzero on
WARN/ALERT/SKIP and does not replace continuous event indexing or service-credit
monitoring. `MONITOR_WINDOW_HOURS` selects its event window (default 24).

## Access control and wiring — critical

Compare RPC state with `config/state/` using the state-mate commands in
[operations](../RUNBOOK.md#routine-checks); `just monitor-state all` runs them for every
network from environment RPCs. Severity comments (`ALERT: HIGH|WARN`) in those files guide
the response but do not change state-mate's exit behavior.

| Contract | Expected |
| --- | --- |
| L1 receiver / ProxyAdmin | DAO Agent admin / owner |
| L2 sender / ProxyAdmin | Governance Executor admin / owner |
| L2 sender | Configured pool and receiver; SyncTrigger holds SYNC_ROLE; obsolete holders do not |
| OraclePool | LOL Safe owner |
| SyncTrigger | Automation Multisig owner; CREReceiver forwarder |
| CREReceiver | Automation Multisig owner and expected author; lane CRE Forwarder; allowed `triggerSync()` call |
| WorkflowRegistry | Shared configured workflow ID; Automation Multisig owner; ACTIVE status |

Index `RoleGranted`, `RoleRevoked`, `OwnershipTransferred`, receiver configuration
changes, and trigger fee/amount/delay changes. Page on unexpected authority or
wiring changes. CustomSender uses non-enumerable access control: selected
`hasRole` reads, including state-mate's `ozNonEnumerableAcl` checks, only cover
named holders. Reconstruct membership from complete `RoleGranted`/`RoleRevoked`
event history to detect unexpected holders.

## Funds and delivery — critical

| Signal | Response |
| --- | --- |
| L1 `MessageFailed` | Investigate application failure; use the retry procedure in operations |
| Persistent unexpected L1 ETH/tokens | Reconcile messages; governance controls receiver recovery |
| CCIP execution failure | Inspect message execution status and manual-execution options |
| Native return-bridge failure | Inspect the lane's bridge status and recovery deadline |
| Arbitrum retryable not redeemed | Resolve before ticket expiry |

Do not infer successful application execution from CCIP delivery alone. Match the
L2 message ID to L1 `MessageSucceeded`, then track the return-pool credit.

## Sync liveness — high

Use 24 hours as an initial stall threshold while pool WETH is above the configured
minimum; tune to lane behavior and operational requirements.

| Observation | Interpretation / response |
| --- | --- |
| `shouldSyncAmount() == 0` | Not due: inspect amount and interval before declaring a stall |
| Due and `canSync() == false` | Check float, SYNC_ROLE, pool availability and pause |
| Due and executable, no `CallExecuted` | Check workflow status/linkage, credit, author, forwarder, and allowed call |
| Repeated report execution failures | Inspect revert reason, live fee adequacy, CCIP allow-list, and RMN state |
| L2 `Sync` without matching L1 success | Trace CCIP and L1 application status |
| L1 success without pool credit | Trace the native return bridge |

The contract's `canSync()` does not check live CCIP fee, allow-list, or RMN status.
A healthy local predicate cannot establish end-to-end liveness.

## Workflow and capacity — high / medium

Read registry ownership, account linkage, quota, and workflow status with
`just cre-registry-status`. Validate each receiver with `verify-cre-workflow`.
Observe live report delivery independently: a registered ACTIVE workflow can
still fail its author gate or have no execution credit.

Monitor CRE account credit through the service. Alert on unexpected workflow
pause, deletion, or ownership-transfer events. Workflow credit, Safe gas, and
trigger fee float require separate funding checks.

Suggested starting capacity thresholds:

| Signal | Threshold / action |
| --- | --- |
| Trigger ETH / `getMaxFees()` | Top up below 2×; below 1× blocks sync |
| Actual CCIP fee / maxFee | Investigate sustained utilization above 80% |
| L1 execution gas / configured gasLimit | Investigate sustained utilization above 80% |
| Configured gas ceiling vs live CCIP cap | Reconcile any mismatch before retuning |
| Pool wstETH vs expected staking demand | Top up before depletion |

Use [fees](fees.md) for tuning and the [LP runbook](runbook-liquidity-provider.md)
for liquidity. Missing RPC/event data is unknown, never evidence of a healthy lane.
