# Tracking a Sync Round Trip

A sync converts accumulated L2 pool WETH into bridged wstETH. It has three separate
completion observations: an L2 send, successful L1 application execution, and a
native-bridge credit back to the pool.

## Stages and evidence

| Stage | Observation | What it establishes |
| --- | --- | --- |
| Due | `shouldSyncAmount() > 0` | Amount and interval conditions hold |
| Locally executable | `canSync()` | Role, pool, and fee-float checks pass |
| Report executed | `CREReceiver.CallExecuted` | The authenticated allowed call returned successfully |
| Sent | `CustomSender.Sync` | Message ID, amount, and destination for the CCIP send |
| L1 application completed | `LidoCustomReceiver.MessageSucceeded` for that ID | Receiver staking/adapter call succeeded |
| Returned | Lane bridge completion and pool wstETH transfer | Liquidity reached the selected recipient |

`MessageFailed` is an application failure even when CCIP itself delivered the
message. L1 success does not establish that the asynchronous return bridge has
completed. A pool balance increase alone may be an LP top-up; correlate the
bridge message and transfer when attributing it to a particular sync.

## Investigation

Read addresses from `config/state/` and choose explicit block windows for each
chain. Record transaction hashes and message IDs while investigating an incident.

```sh
# Replace addresses and block bounds with the lane's values.
cast logs --rpc-url "$L2_RPC_URL" --from-block <start> --to-block <end> \
  --address <CustomSender> 'Sync(address,uint64,bytes32,uint256)'

cast logs --rpc-url "$L1_RPC_URL" --from-block <start> --to-block <end> \
  --address 0x6F357d53d6bE3238180316BA5F8f11467e164588

cast call <wstETH> 'balanceOf(address)(uint256)' <pool> --rpc-url "$L2_RPC_URL"
```

Follow the CCIP message to L1, then the adapter's native-bridge message to L2.
Use [operations](../RUNBOOK.md#failed-l1-application-message) for application retries.

## Latency and finality

Measure the outbound and return legs separately. Lane latency depends on CCIP
processing and the selected native bridge; it cannot be inferred from the chain's
proof-finalization mechanism alone. A delayed message needs its own status check.

The workflow's hourly polling cadence, the trigger's minimum sync interval, and
cross-chain delivery latency are different quantities. An idle lane need not emit
reports. A due-but-blocked lane is skipped by the workflow until its local
preconditions recover.

Changing the configured pool does not change an in-flight message's return
recipient. Reconcile credits to the pool selected at send time.
