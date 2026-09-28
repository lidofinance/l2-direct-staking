# Sync Fees and Limits

The Automation Multisig owns fee, amount, and delay settings on SyncTrigger.
The LOL Safe owns pool liquidity. [Architecture](../DOC.md) defines the boundary.

## The four budgets

| Quantity | Meaning | Where it is paid |
| --- | --- | --- |
| `FeeOtoD.maxFee` | Ceiling on the actual CCIP send fee | Native ETH fronted by SyncTrigger; unused OtoD allowance refunds on L2 |
| `FeeOtoD.gasLimit` | Execution gas committed for the L1 receiver | Included in the CCIP quote; increasing it can increase actual cost |
| `FeeDtoO` | Lane-specific native return-bridge parameters | Passed through the L1 receiver to its adapter |
| CRE `writeGasLimit` | Gas budget for delivery to the L2 CREReceiver | CRE report execution; separate from the CCIP L1 gas budget |

A fee ceiling is not an actual expense. Conversely, unused execution-gas commitment
or return-bridge allowance must not be assumed to refund to SyncTrigger.

## Configured values

These are repository defaults, not a live gas quote. Solidity lane constants and
`config/state/<network>.inputs.yaml` contain the exact encoded values;
`just verify-constants-sync` compares them.

| Parameter | Optimism | Arbitrum | Base | Linea |
| --- | --- | --- | --- | --- |
| OtoD maxFee | 0.125 ETH | 0.125 ETH | 0.125 ETH | 0.125 ETH |
| OtoD gasLimit | 1,000,000 | 1,000,000 | 1,000,000 | 500,000 |
| Configured gas ceiling | 7,000,000 | 7,000,000 | 7,000,000 | 3,000,000 |
| Return execution gas | 100,000 | 100,000 | 100,000 | Adapter-defined |
| Return native allowance | 0 | 0.001005 ETH | 0 | 0 |

All lanes use native payment, a 5 WETH minimum, a 100 WETH maximum, and a 12-hour
minimum interval. The workflow polls hourly; the trigger independently enforces
its interval. The absolute contract delay floor is one minute.

## Encoding

Use the lane's `FeeCodec` function; do not hand-substitute one bridge's format
for another. The common prefix is `uint128 feeAmount | bool payInLink`.

| Blob | Encoder | Length | Additional fields |
| --- | --- | --- | --- |
| OtoD, every lane | `encodeCCIP(maxFee, false, gasLimit)` | 21 bytes | `uint32 gasLimit` |
| DtoO, Optimism | `encodeOptimismL1toL2(l2Gas)` | 21 bytes | `uint32 l2Gas`; zero feeAmount |
| DtoO, Base | `encodeBaseL1toL2(l2Gas)` | 21 bytes | `uint32 l2Gas`; zero feeAmount |
| DtoO, Arbitrum | `encodeArbitrumL1toL2(maxSubmissionCost, maxGas, gasPriceBid)` | 29 bytes | `uint32 maxGas`, `uint64 gasPriceBid` |
| DtoO, Linea | `encodeLineaL1toL2()` | 17 bytes | No extra fields; zero feeAmount |

Arbitrum's feeAmount is `maxSubmissionCost + maxGas × gasPriceBid`.
The configured inputs are 0.001 ETH, 100,000 gas, and 0.05 gwei respectively.

`setFeeOtoD` requires exactly 21 bytes, native payment, and a gasLimit between
the sender's `MIN_PROCESS_MESSAGE_GAS` and the stored ceiling. `setMaxGasLimit`
cannot lower the ceiling below the already configured gasLimit.

`setFeeDtoO` checks the common prefix and rejects LINK payment. It does **not**
validate the lane-specific length or amount constraints. A wrong-lane blob can
be accepted on L2 and fail at the L1 adapter. Validate against the selected adapter
before an owner submits the change.

## Funding the float

SyncTrigger fronts `getMaxFees()` on each sync. Its ETH balance must cover that
entire amount even when the eventual net fee is lower. `canSync()` returns false
below the floor; `triggerSync()` raises `SyncTriggerInsufficientFloat`.

Anyone can send native ETH to SyncTrigger. Its owner can recover excess using
`sweep`. Keep at least two worst-case sends available as an operational buffer,
and choose further runway from observed actual fees and expected cadence.
`just balances` reports the float; pool WETH/wstETH and CRE account credit are
separate balances.

## Tuning

```sh
just quote-ccip-fees
just quote-ccip-fee-by-amount
just measure-fee-gas
```

Inspect each recipe's environment requirements with `just --show <recipe>`.
Quotes and measurements depend on lane, block, amount, price inputs, and runtime.

- Quote the fee across the intended amount range before raising `maxAmount`.
  Amount-sensitive CCIP pricing can make `maxFee` insufficient even without a
  gas-price change. Use the live lane configuration rather than a remembered
  fee schedule.
- Size the L1 execution budget using the real receiver/adapter path. Increasing
  gasLimit can increase the CCIP quote even if execution uses less gas.
- Compare the configured ceiling with the live lane cap. A locally valid value
  above the remote cap makes sync revert inside CCIP.
- On OP Stack lanes, return `l2Gas` influences L1 bridge execution cost and thus
  the outer OtoD budget. Measure them together.
- On Arbitrum, inspect retryable refund recipients before assuming excess return
  allowance is recoverable. The L1 receiver's aliased refund address is not the
  SyncTrigger fee payer. Monitor auto-redemption and ticket expiry separately.

The fork test's fixed 1.25 projection is not hardfork conformance evidence;
[development](development.md#validation-limits) records the measurement limits.
After changing parameters, update state expectations, rerun consistency checks,
and observe a complete round trip. [Operations](../RUNBOOK.md) covers failures.
