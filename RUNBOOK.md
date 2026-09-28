# Direct Staking Operations

Use this runbook for the configured four-lane system. [Architecture](DOC.md)
defines ownership; [monitoring](docs/monitoring.md) defines expected signals.

## Environment

Install dependencies as described in [development](docs/development.md).
Keep secrets in the ignored root `.env`; committed `.env.<network>` files supply
lane bindings. `NETWORK=<network> just <command>` loads both files. Using
`just -E <file>` replaces that default dotenv selection.

Provide machine RPC bindings `RPC_ETHEREUM_REMOTE`, `RPC_OPTIMISM_REMOTE`,
`RPC_ARBITRUM_REMOTE`, `RPC_BASE_REMOTE`, and `RPC_LINEA_REMOTE`.
`script/shared/cre-env.sh` resolves tool-specific aliases. Run `just env-doctor`
to check bindings, address expectations, and key/address consistency.
Read-only checks do not require transaction signing keys.

## Routine checks

```sh
just balances
just audit-ownership
just postflight-monitor
just cre-registry-status
```

Validate each lane's complete expected state:

```sh
NETWORK=optimism just verify-optimism-state
NETWORK=arbitrum just verify-arbitrum-state
NETWORK=base just verify-base-state
NETWORK=linea just verify-linea-state
just verify-l1-state-mate
```

State-mate assertions are expectations, and failures require investigation rather than changing the
expectations to match an unexplained result.

Check workflow registration and delivery separately:

```sh
NETWORK=optimism just verify-cre-workflow
# Repeat for arbitrum, base, and linea.
```

Confirm a live `CREReceiver.CallExecuted`, its L2 `CustomSender.Sync`, the matching
L1 `MessageSucceeded`, and the return-pool wstETH credit. Registry ACTIVE status
alone is insufficient. A lane can be idle because it is below the amount threshold.

## Sync stall triage

1. Read `shouldSyncAmount()`, `canSync()`, last execution, delay, and pool balances.
2. If due but blocked, check pool pause, trigger SYNC_ROLE, and trigger ETH against
   `getMaxFees()`. Top up float as needed; the [LP runbook](docs/runbook-liquidity-provider.md)
   covers funding.
3. If due and executable but no report lands, inspect CRE account credit, registry
   linkage/status, expected author, forwarder, and allowed call. Use [CRE recovery](docs/cre.md#recovery).
4. If execution reverts, inspect its reason and live CCIP fee/lane availability.
   `canSync()` does not cover those external conditions.
5. If the send succeeded, follow its message ID through [sync tracking](docs/sync-round-trip-and-finality.md).

## Failed L1 application message

```sh
just retry-failed-message <L1-transaction-hash>
```

The default `dry-run` checks the receiver's `MessageFailed` event and stored hash,
simulates a retry, and prints calldata. Supply a message ID when the receipt has
multiple failures. Correct the underlying failure before submitting a retry:

```sh
just retry-failed-message <L1-transaction-hash> send <message-id>
```

Sending requires `RETRY_PRIVATE_KEY` and L1 gas. Both modes attach zero ETH.
Already handled messages are rejected. Governance controls receiver token recovery.
CCIP delivery failure and native-bridge failure have different recovery paths;
do not treat an application retry as a universal cross-chain retry.

## Containment and resumption

| Authority | Containment action |
| --- | --- |
| Automation Multisig | Pause the CRE workflow; remove the receiver's allowed trigger call |
| L2 governance | Revoke trigger SYNC_ROLE on CustomSender |
| LOL Safe | Pause the pool |

Choose the action for the affected component. A registry pause stops workflow
scheduling but does not prove that reports already in flight cannot arrive.
Pool pause affects user staking as well as sync.

Before resuming, verify ownership/wiring, available liquidity, fee float, and the
specific fault's resolution. Observe a successful live round trip after resumption.

## Configuration changes

Use [fees](docs/fees.md) for fee/amount/delay tuning and [CRE](docs/cre.md) for workflow
registration. Update the corresponding state expectations and validate each lane.
Use the contract owner for owner-only calls. Pool liquidity operations belong to
the LOL Safe; automation controls belong to the Automation Multisig.
