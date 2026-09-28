# Liquidity Provider Runbook

The LOL Safe owns each OraclePool. The Automation Multisig owns SyncTrigger,
CREReceiver, and the CRE workflow. Pool liquidity and automation fee funding are
separate responsibilities and balances.

## Addresses and preconditions

Read pool and trigger addresses from `config/state/<network>.deployed.yaml` and
token addresses from the lane inputs. Validate the active sender's `getOraclePool()`
before funding; do not rely only on a copied address.

```sh
NETWORK=optimism just verify-optimism-state
just balances
just audit-ownership
```

Repeat the lane validation for Arbitrum, Base, and Linea. Confirm pool ownership,
WETH/wstETH identity, sender wiring, pause state, trigger ownership, and CRE wiring.
Do not seed an unexpected or paused pool without resolving the discrepancy.

## Seed and top up

1. Transfer wstETH on the selected L2 to the active pool. The ordinary token transfer
   supplies liquidity; no token approval to SyncTrigger or CREReceiver is needed.
2. Confirm the pool's wstETH balance and a successful small user stake.
3. Maintain enough liquidity for expected demand while WETH is in the round trip.
   The configured 100 WETH sync cap limits one batch, not total pool capacity.
4. Confirm trigger ETH covers `getMaxFees()`. Native ETH can be sent directly to
   SyncTrigger by any funder. The Automation Multisig controls excess recovery.
5. Observe a due sync and the returning wstETH credit using [sync tracking](sync-round-trip-and-finality.md).

For an optional scripted smoke test:

```sh
NETWORK=optimism just smoke-stake
```

Inspect `just --show smoke-stake` and `script/commands/smoke-stake.sh` for its
execution flag and signer requirements before sending transactions. The check
uses a small wstETH seed and a user stake; it is not a substitute for a complete
sync round trip.

## Routine operation

```sh
just balances
just postflight-monitor
```

Watch available wstETH, accumulated WETH, sync due-ness, execution status, and
return-bridge progress. Below-threshold WETH is normal. Due-but-blocked sync needs
investigation; repeatedly adding liquidity without fixing rebalancing only delays
depletion. [Monitoring](monitoring.md) owns alert thresholds and [fees](fees.md)
owns fee calculations.

## Pause and recovery

The LOL Safe can `pause()` the pool, `unpause()` it, and use its owner-only `sweep()`
to recover balances. Read the pool ABI for exact arguments and transaction values.
Pausing affects user staking and automated sync. The LOL Safe does not own the
trigger's settings or administer sender SYNC_ROLE.

For an incident, coordinate with the Automation Multisig and governance using
[operations](../RUNBOOK.md#containment-and-resumption). Do not assume that stopping
new syncs cancels messages already sent.

## Exit

1. Coordinate stopping new activity and pause the pool.
2. Record outstanding sync message IDs and their fixed return recipients.
3. Reconcile L1 execution and return-bridge completion.
4. Sweep available pool assets from the LOL Safe to the intended recipient.
5. Continue watching for late credits and recover them as they arrive.

A balance snapshot of zero does not prove that no bridge message remains in flight.
Changing the sender's pool does not redirect existing messages. Asset recovery and
any sender reconfiguration require their respective owners.
