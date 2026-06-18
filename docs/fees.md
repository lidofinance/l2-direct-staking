> **View — fee economics reference.** Stakeholder: the fee-tuning owner (the LOL
> multisig that re-encodes `setFeeOtoD` / `setFeeDtoO`). Concern: *why
> the fee values are what they are* — the four quantities, byte layouts, the
> Glamsterdam headroom bump, and each bridge's refund/failure behavior. This is the
> **canonical** quantitative fee reference; [`DOC.md` §5.2](../DOC.md#52-fee-parameters-per-chain--and-why-they-are-set-this-way)
> keeps the architecture-altitude rationale and defers here. Doc map:
> [`README.md` §Documentation](../README.md#documentation).

# Sync fee parameters (FeeOtoD / FeeDtoO)

## TL;DR — for whoever pays the fees

- **How much.** Net cost per sync ≈ **0.005–0.007 ETH** (actual CCIP fee + Arbitrum's ~0.001 ETH bridge budget; OP/Base/Linea return legs are free). At ≤2 syncs/day/lane that's ≤ ~0.013 ETH/day/lane (~$10–20/day across all 4 chains at current prices). The headline `maxFee` of 0.125 ETH is a revert cap, *not* a cost — the unspent excess refunds automatically in the same transaction. Every production sync to date corroborates these magnitudes (and shows the fee is mostly the amount-driven premium, not gas) — [Historical actuals](#historical-actuals--every-production-sync-on-chain).
- **What you pay for.** Two legs per sync: (1) **FeeOtoD** — CCIP delivery of WETH from the L2 to Ethereum plus the committed L1 `gasLimit` for staking it through Lido (you pay for the *commitment*, unused gas is never refunded); (2) **FeeDtoO** — the native-bridge return of wstETH to the L2 (only Arbitrum charges ETH; the Arbitrum excess is burned to an unreachable alias).
- **Who pays / how to maintain.** Each lane's **SyncTrigger holds the float** and fronts every sync; nothing refills it automatically. Funding is permissionless (just send ETH to the trigger), but withdrawing excess is owner-only (`sweep()`, the LOL multisig), so size deposits as `getMaxFees().maxNativeFee` + ~30 days runway ≈ **0.5 ETH/lane**, not "fill it up".
- **How to check all is good.** Watch the [§5 monitoring alerts](monitoring.md#5-capacity--headroom--medium) — they fire at **80% utilization** of `gasLimit` and `maxFee`, before anything breaks. Check `cast balance <trigger>` ≥ `getMaxFees().maxNativeFee`, and re-measure gas on demand with `just measure-fee-gas`.
- **Caveats.**
  - Balance below `maxFee + feeDtoO` → `triggerSync` reverts with the named **`SyncTriggerInsufficientFloat(required, available)`**, and **`canSync()` returns `false`** so the DON stops submitting (no revert spam); check the trigger balance first when diagnosing a stalled sync. Liveness only — self-heals once topped up.
  - `gasLimit` too low → L1 message OOGs; funds park at the L1 receiver until a permissionless `retryFailedMessage` (parked, not lost). Too high → linear overpayment every sync, and above the lane cap (7M; **3M on Linea**) — now **rejected at config time** by `setFeeOtoD` (`SyncTriggerGasLimitAboveMax`, vs the owner-set `getMaxGasLimit()` ceiling) instead of bricking sync.
  - Arbitrum FeeDtoO overpayment is a **1:1 burn**; OP/Base `l2Gas` slack burns L1 gas ~1:1 and eats `gasLimit` headroom.
  - Fee changes are now **LOL multisig transactions** (Safe coordination, not a days-long governance round-trip) — act from the 80% alert, not the breach, and update the constants in `script/<net>/<Net>MigrationConstants.sol` in lockstep.

The sync operation moves accumulated WETH from an L2 OraclePool to Ethereum (via CCIP), stakes it through Lido, and bridges the resulting wstETH back to the L2 pool. Two encoded fee blobs govern the costs of each leg:

| Fee blob | Direction | What it pays for | Set by |
|----------|-----------|------------------|--------|
| **FeeOtoD** | L2 → Ethereum (CCIP) | CCIP message delivery + `ccipReceive` execution on Ethereum | `SyncTrigger.setFeeOtoD()` |
| **FeeDtoO** | Ethereum → L2 (native bridge) | L1 adapter bridge call that sends wstETH back to L2 | `SyncTrigger.setFeeDtoO()` |

## Fee denomination, the four quantities, and when money moves

**What the CCIP fee is nominated in.** One CCIP fee exists per sync — the OtoD leg. It is quoted and
charged in the message's `feeToken`: `payInLink ? LINK_TOKEN : address(0)`
(`lib/chainlink-csr/contracts/ccip/CCIPSenderUpgradeable.sol:77`), where `address(0)` means the sending
chain's native token. All four lanes set `payInLink = false` ([Current mainnet values](#current-mainnet-values)),
so the fee is **native ETH of the originating L2, in wei**, fixed by `IRouterClient.getFee()` at send time
(`CCIPSenderUpgradeable.sol:81`) and transferred to the Router at `ccipSend{value: fee}` (`:94`). The LINK
rail (~10% discount) exists in the codec but is unused. Internally CCIP composes the quote as
≈ `baseFee + premium + gasLimit × destChainGasPrice × tokenConversion`
([billing model](#glamsterdam-fee-headroom-bump-may-2026)), but on-chain it is a single native-wei number.

**What the `≈` smooths over.** The live quote is CCIP's `FeeQuoter.getValidatedFee` (vendored at
`lib/chainlink-local/lib/ccip/contracts/src/v0.8/ccip/FeeQuoter.sol:534-598`, v1.6; mainnet runs CCIP's
deployed copy — same decomposition). Four things the shorthand merges:

- **`baseFee` is a label coined here, not a CCIP field.** It is the gas-priced overhead in `executionCost`
  *other than* your `gasLimit` — `destGasOverhead + data.length × destGasPerPayloadByte + tokenTransferGas`
  (`:588-592`) — priced like the `gasLimit` term (same gas price, same multiplier) but fixed w.r.t. the limit
  you commit. CCIP's fourth component, `dataAvailabilityCost` (`:566-579`), folds in here and is **0 on these
  lanes**: it is charged only when the destination is a rollup posting calldata to a DA layer
  (`destDataAvailabilityMultiplierBps > 0`), and the destination is Ethereum L1.
- **`premium` is the token-transfer fee, not the flat network fee.** The OtoD message always carries a token
  (`amount [+ feeAmountDtoO]`, `lib/chainlink-csr/contracts/senders/CustomSender.sol:294`), so the quote takes
  the `numberOfTokens > 0` branch (`:556-558` → `_getTokenTransferCost`, `:647-705`): `deciBps` of the bridged
  USD value (`:681`), clamped to `[minFeeUSDCents, maxFeeUSDCents]` (`:689-697`), or a flat
  `defaultTokenFeeUSDCents` for a token with no per-lane override (`:662`). The flat `networkFeeUSDCents` path
  (`:561`) is the data-only case and is **not** taken here. Either branch is independent of gas price and of
  `gasLimit` — **but the `deciBps` branch scales with the bridged amount.** Measured live (2026-06-17):
  Optimism/Linea charge **5 bps — i.e. 0.05% of the bridged WETH amount — with an uncapped
  (uint32-sentinel) ceiling**, so their fee grows ~0.0005 ETH/WETH (0.05 WETH per 100 WETH bridged); Arbitrum/Base (FeeQuoter 2.0.0) charge ≈0 bps for WETH and stay flat (they were
  *also* 5 bps under CCIP v1.5 until migrated to FeeQuoter 2.0.0 — every historical Base/Arbitrum send
  is 5 bps; the 0-bps regime is `getFee`-predicted, never yet sent: [Historical actuals](#historical-actuals--every-production-sync-on-chain)). The `SyncTrigger`
  **100 WETH** per-sync cap ([DOC §5.2](../DOC.md#52-fee-parameters-per-chain--and-why-they-are-set-this-way))
  holds the OP/Linea quote to ~40% of `maxFee`, so this is a **tuning coupling** (`maxAmount`↔`maxFee`), not a
  live breach — full treatment in [`otod-fee-amount-sensitivity.md`](otod-fee-amount-sensitivity.md)
  (sweep any lane: `just quote-ccip-fee-by-amount`).
- **`destChainGasPrice` hides a per-lane multiplier.** The real factor is
  `executionGasPrice × gasMultiplierWeiPerEth` (`:592`) — a configurable execution surcharge (1e18-based;
  `1.1e18` = +10%) applied to *both* `baseFee` and the `gasLimit` term.
- **`tokenConversion` is the `/ feeTokenPrice` division applied to the whole sum** (`:597-598`), not a factor on
  the `gasLimit` term alone: it converts the USD-denominated `(premium + executionCost + dataAvailabilityCost)`
  into fee-token wei — here native L2 ETH, at ETH's USD price.

Every knob above (`destGasOverhead`, `destGasPerPayloadByte`, `deciBps`, `min`/`maxFeeUSDCents`,
`gasMultiplierWeiPerEth`, `premiumMultiplierWeiPerEth`) is CCIP-owned per-lane on-chain config, set nowhere in
this repo — which is why the fee is read live via `getFee` instead of reconstructed.

**Four quantities hide under the word "fee" — only one is a CCIP fee.**
([DOC.md §5.2](../DOC.md#52-fee-parameters-per-chain--and-why-they-are-set-this-way) splits the *parameters*
by economic kind — cap / commitment / payment; this table splits the *quantities* a sync actually touches.)

| Quantity | CCIP fee? | What it actually is |
|---|---|---|
| FeeOtoD **actual fee** | **yes — the only one** | the `getFee()` quote charged for the L2→L1 leg: flat premium + the L1 `gasLimit` execution commitment |
| FeeOtoD **`maxFee`** | no — a revert bound | slippage guard: quote > `maxFee` ⇒ `CCIPSenderExceedsMaxFee` (`CCIPSenderUpgradeable.sol:82`), nothing charged. Never charged as such |
| **FeeDtoO** | no — a native-bridge budget | the return leg rides each L2's native bridge, not CCIP ([why the legs differ](#l1l2-vs-l2l1--why-the-two-legs-differ)): Arbitrum retryable `maxSubmissionCost + gasPriceBid × maxGas` ≈ 0.001 ETH; OP/Base/Linea 0 |
| FeeOtoD **`gasLimit`** | a component *inside* the actual fee | priced on the *committed* limit, not actual usage — unspent gas is never refunded ([Consequences](#consequences-of-unnecessarily-high-feeotod--feedtoo-limits)) |

**When the money moves** — all of it from the SyncTrigger's own float (it is the fee
[treasury](#feeotodmaxfee-free-per-sync-but-it-is-the-per-sync-blast-radius-bound); stakers' deposits and
the synced WETH are never touched — the user-initiated `slowStake` path fronts its own fees separately):

1. **t₀ — L2, one transaction.** `triggerSync` forwards `maxFeeOtoD + feeAmountDtoO` native ETH from the
   trigger's balance (`src/SyncTrigger.sol:247`). The Router quotes `getFee`; above `maxFee` the whole
   tx reverts with nothing charged; otherwise **exactly the quote** is paid at `ccipSend`
   (`CCIPSenderUpgradeable.sol:81-94`). The DtoO budget is wrapped and **added to the CCIP token transfer**
   (`amount + feeAmountDtoO`, `lib/chainlink-csr/contracts/senders/CustomSender.sol:294`) — it leaves at t₀
   too. Everything unspent refunds to the trigger before the tx ends (`CustomSender.sol:208`).
2. **t₀ + ~20 min — L1, inside `ccipReceive`.** The DtoO budget is *consumed*: Arbitrum pays the Inbox as
   `msg.value`; OP/Base burn L1 gas ~1.016:1 for the `l2Gas` commitment; Linea pays nothing.

CRE ticks themselves move no money — most are free staticcalls; fees are paid only when a sync is both
due (`shouldSync()`) and executable (`canSync()`) (≤2 paid syncs/day/lane — [cadence](#sync-thresholds--cadence--why-these-values)).

**Three different "excesses".** The `maxFee` row below says "excess is not spent" — that is true for
exactly one of the three quantities that answer to "excess":

| Excess | Fate |
|---|---|
| `maxFee − actualFee` | **refunded intra-tx** (`CustomSender.sol:208`) — genuinely never spent |
| `gasLimit` committed − gas actually used | **spent at t₀, never refunded** — recurring linear overpayment ([Consequences](#consequences-of-unnecessarily-high-feeotod--feedtoo-limits)) |
| Arbitrum FeeDtoO budget − actual bridge cost | **burned** — "refunded" on L2 to the unreachable alias `0x80467D…5699`, ~0.001 ETH/sync ([proven on-chain](#consequences-of-unnecessarily-high-feeotod--feedtoo-limits)) |

## How fees flow through the system

```
SyncTrigger.triggerSync()
  │  reads _feeOtoD, _feeDtoO from storage
  │  calculates native ETH needed: sum of non-LINK fee amounts
  │
  ├─► CustomSender.sync{value: nativeETH}(destSelector, amount, feeOtoD, feeDtoO)
  │     │  decodes feeDtoO → pulls fee tokens (ETH or LINK) from caller
  │     │  decodes feeOtoD → extracts maxFee, payInLink, gasLimit
  │     │  packs feeDtoO into CCIP message data alongside recipient + amount
  │     │
  │     ├─► CCIP Router.ccipSend()  ← pays feeOtoD here (only the *actual* fee)
  │     │     │  routes message to Ethereum
  │     │     │
  │     │     └─► LidoCustomReceiver.ccipReceive()  ← gasLimit governs this execution
  │     │           │  unpacks feeDtoO from message data
  │     │           │  stakes ETH in Lido → receives wstETH
  │     │           │
  │     │           └─► L1 Adapter.sendToken(wstETH, feeDtoO)  ← pays feeDtoO here
  │     │                 │  decodes feeDtoO per network format
  │     │                 └─► native bridge (Arbitrum Gateway / OP Bridge / Linea Bridge)
  │     │                       └─► wstETH arrives on L2 pool
  │     │
  │     └─► TokenHelper.refundExcessNative(msg.sender)  ← automatic, last line of sync()
  │           refunds maxFee − actualFee back to the SyncTrigger, same tx (never called manually)
```

## Excess CCIP-fee refund (`refundExcessNative`) — automatic, never manual

`TokenHelper.refundExcessNative` is **not an operator action** — there is no manual call to make and no scheduled job to run, and it is impossible to invoke directly because it is an `internal` library function, not an external entrypoint (`lib/chainlink-csr/contracts/libraries/TokenHelper.sol:34`).

**When it runs:** unconditionally, as the **last statement** of every send — `CustomSender.sync()`, `slowStake()`, and `fastStake()` (`CustomSender.sol:208`, `:137`, `:174`). It sweeps the sender's *entire* native balance to `msg.sender` **in the same transaction** as the send, after the CCIP fee has already been paid. For a sync, `msg.sender` is the SyncTrigger, so the `maxFee − actualFee` excess lands back in the trigger's float via its bare `receive()` (`src/SyncTrigger.sol:54`) **before `triggerSync()` even returns**. The float therefore depletes by the *actual* cost, never the fronted maximum (see [Funding the float](#feeotodmaxfee-free-per-sync-but-it-is-the-per-sync-blast-radius-bound) and [Cost framing](#cost-framing)).

**Don't confuse it with the two refunds/recoveries that *are* manual:**

| Mechanism | Manual? | What it does |
|---|---|---|
| `TokenHelper.refundExcessNative` | **No** — internal, automatic, intra-tx | Returns `maxFee − actualFee` to the SyncTrigger after each send |
| `SyncTrigger.sweep()` | **Yes** — owner-only (LOL multisig), `src/SyncTrigger.sol:288` | Withdraws the trigger's accumulated float |
| `LidoCustomReceiver.retryFailedMessage` | **Yes** — re-drives a stuck L1 message | Recovers an OOG'd `processMessage` (not a fee refund) |

This refund covers only the CCIP-fee excess (`FeeOtoD.maxFee`). The *other* two "excesses" are spent or burned, not refunded — see [Fee denomination](#fee-denomination-the-four-quantities-and-when-money-moves) and the Arbitrum [burned-refund](#feedtoo-arbitrum-overpayment-is-refunded-to-an-address-nobody-controls) case.

## FeeOtoD encoding (CCIP, all networks)

Encoded with `FeeCodec.encodeCCIP(maxFee, payInLink, gasLimit)` — 21 bytes.

| Field       | Type      | Description                                                                                                                                            |
| ----------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `maxFee`    | `uint128` | Slippage guard — reverts if actual CCIP fee exceeds this. Only the actual fee is charged; the `maxFee − actualFee` excess is refunded intra-tx — [the other two "excesses" are spent or burned](#fee-denomination-the-four-quantities-and-when-money-moves). |
| `payInLink` | `bool`    | `true` = pay in LINK (~10% discount), `false` = pay in native ETH.                                                                                     |
| `gasLimit`  | `uint32`  | Gas budget for `ccipReceive()` on Ethereum. Must be >= 75,000 (enforced by `CustomSender`). Covers: unpack message → Lido stake → adapter bridge call. |

**Sizing `gasLimit`:** The receiver must unpack the message, stake ETH through Lido, approve wstETH, and delegate-call the bridge adapter. Current configured value is **1,000,000** for Optimism/Arbitrum/Base and **500,000** for Linea (each network bumped +25% from its prior baseline as a Glamsterdam pre-hardening — see [§Glamsterdam fee headroom bump](#glamsterdam-fee-headroom-bump-may-2026)). If too low, the CCIP message enters a failed state and requires [manual re-execution](https://docs.chain.link/ccip/concepts/manual-execution) with a higher gas limit.

**Sizing `maxFee`:** Query `IRouterClient.getFee()` off-chain and add a 10–20% buffer for gas price fluctuation. Current configured value is **0.125 ETH** across all networks. Excess (`maxFee − actualFee`) is fully refunded on L2 by `TokenHelper.refundExcessNative`, so the cap only costs gas at the moment of the send, not over the sync's lifetime.

## FeeDtoO encoding (network-specific)

Each L2 network uses a different L1→L2 bridge with its own fee model. The L1 adapter decodes FeeDtoO and calls the native bridge accordingly.

### Arbitrum — `FeeCodec.encodeArbitrumL1toL2(maxSubmissionCost, maxGas, gasPriceBid)` — 29 bytes

| Field | Type | Description |
|-------|------|-------------|
| `maxSubmissionCost` | `uint128` | Base cost for creating a retryable ticket on L2. If too low, the L1 transaction reverts. |
| `maxGas` | `uint32` | Gas limit for L2 auto-redemption of the retryable ticket. |
| `gasPriceBid` | `uint64` | L2 gas price bid. If below L2 base fee, auto-redemption fails (ticket can be manually redeemed within ~7 days). |

Total ETH required: `feeAmount = maxSubmissionCost + (gasPriceBid × maxGas)`. Excess is "refunded" on L2
— but to the *alias* of the L1 receiver, an address nobody controls, so it is effectively burned (verified
on-chain — see [Consequences of unnecessarily high limits](#consequences-of-unnecessarily-high-feeotod--feedtoo-limits)).

Current values: `maxSubmissionCost=0.001 ETH`, `maxGas=100,000`, `gasPriceBid=0.05 gwei`.

### Optimism / Base — `FeeCodec.encodeOptimismL1toL2(l2Gas)` / `encodeBaseL1toL2(l2Gas)` — 21 bytes

| Field | Type | Description |
|-------|------|-------------|
| `feeAmount` | `uint128` | Always **0**. The adapter reverts if non-zero. Bridge cost is paid implicitly via L1 gas burn. |
| `l2Gas` | `uint32` | Minimum gas guaranteed for L2 deposit execution. L2 gas is not refundable — if too low, the deposit fails with **no recovery mechanism**. Not free either: each unit burns ~1 unit of L1 gas *inside `ccipReceive`* via the portal's resource metering ([measured 1.016:1](#consequences-of-unnecessarily-high-feeotod--feedtoo-limits)). |

Current value: `l2Gas=100,000`.

### Linea — `FeeCodec.encodeLineaL1toL2()` — 17 bytes

| Field | Type | Description |
|-------|------|-------------|
| `feeAmount` | `uint128` | Always **0**. Linea sponsors the postman fee for L1→L2 messages under 250,000 gas ([docs](https://docs.linea.build/network/build/send-receive-messages)). |

No additional parameters. The adapter reverts if `feeAmount != 0` or `payInLink == true`.

> **`SyncTrigger` does *not* enforce these per-lane shapes at set-time.** `setFeeDtoO` validates only the
> generic 17-byte prefix (`FeeCodec.decodeFee`) — it deliberately does **not** check the exact length,
> `payInLink == false`, or `feeAmount`. Encoding the correct shape (the tables above) is the operator's
> responsibility: a mismatched blob (e.g. a 21-byte CCIP blob on Arbitrum, which needs 29) is accepted on
> L2 but reverts inside the L1 adapter, parking the synced WETH for owner `recoverTokens` (recoverable,
> not lost — see [Plan: when reality outgrows a limit](#plan-when-reality-outgrows-a-limit--what-breaks-how-to-fix-it)).
> Contrast `feeOtoD`, whose uniform 21-byte CCIP shape *is* strictly validated on-chain (`setFeeOtoD`).
> Why it's left off-chain (stable immutable-per-lane format, owner-gated, deploy-time pinned):
> [`docs/audit-scope.md §D` F-4](audit-scope.md#d-fee-configuration--liveness).

## Current mainnet values

| Parameter | Optimism | Arbitrum | Base | Linea |
|-----------|----------|----------|------|-------|
| **FeeOtoD maxFee** | 0.125 ETH | 0.125 ETH | 0.125 ETH | 0.125 ETH |
| **FeeOtoD payInLink** | false | false | false | false |
| **FeeOtoD gasLimit** | 1,000,000 | 1,000,000 | 1,000,000 | 500,000 |
| **FeeDtoO format** | Optimism L1→L2 | Arbitrum L1→L2 | Base L1→L2 | Linea L1→L2 |
| **FeeDtoO feeAmount** | 0 | ~0.001 ETH* | 0 | 0 |
| **FeeDtoO l2Gas / maxGas** | 100,000 | 100,000 | 100,000 | — |

\* Arbitrum `feeAmount = maxSubmissionCost + gasPriceBid × maxGas = 0.001e18 + 0.05 gwei × 100,000 ≈ 1.005e15 wei ≈ 0.001005 ETH`.

## Glamsterdam fee headroom bump (May 2026)

The `FeeOtoD` values above include a **+25% pre-emptive bump** from the prior production baseline (`maxFee = 0.1 ETH`; `gasLimit = 800k` for Optimism/Arbitrum/Base, `400k` for Linea). The bump is a one-shot hardening ahead of the Ethereum **Glamsterdam** upgrade, which ships [EIP-7904](https://eips.ethereum.org/EIPS/eip-7904) (compute opcode repricing) and [EIP-8038](https://eips.ethereum.org/EIPS/eip-8038) (state-access repricing) on L1.

### Why `gasLimit` needs more headroom

The L1 work bounded by `_feeOtoD.gasLimit` (`LidoCustomReceiver.ccipReceive` → `processMessage`) is dominated by exactly the opcodes Glamsterdam reprices:

- **EIP-8038** raises `GAS_COLD_SLOAD`, `GAS_COLD_ACCOUNT_ACCESS`, and the storage-update base. The receiver path performs many cold accesses: CSR storage namespaces, AccessControl role mappings, WETH → Lido `stETH.submit` (cold reads against `BUFFERED_ETHER`, total shares, recipient shares), wstETH wrap, the bridge adapter `delegatecall`, and the per-network L1 bridge endpoint (Optimism `L1ERC20TokenBridge`, Arbitrum `L1GatewayRouter`, Base `L1StandardBridge`, Linea `L1MessageService`).
- **EIP-7904** raises `KECCAK256` (+50%) and a few precompiles. Mild on this path (no pairings, no KZG), but every storage-slot derivation, role hash, and message envelope hash gets the +50% bump.
- Conservative estimate of impact on `processMessage`: **+15–25%** of current actual gas usage. Per the [measured carrier below](#measured-ccipreceive-gas-independent-gaslimit-carrier), the 25% bump keeps every lane within budget (no OOG), but **Optimism (~86%) and Base (~83%) land above or at the §5 80% headroom the [§5 alert](monitoring.md#5-capacity--headroom--medium) tracks** — 1M is adequate-but-tight for both OP-stack lanes.

`_feeDtoO` is **not** affected by these EIPs because it budgets L2 execution (Optimism/Base `l2Gas`, Linea postman, Arbitrum `maxGas × gasPriceBid`) — each L2 follows its own gas schedule, not L1's. (Caveat: Optimism/Base `l2Gas` *does* burn L1 gas inside `ccipReceive` via the portal's resource metering, so it indirectly consumes `_feeOtoD.gasLimit` budget — see [Consequences](#consequences-of-unnecessarily-high-feeotod--feedtoo-limits).) Arbitrum's `maxSubmissionCost` is paid as L1 `msg.value` to the Inbox; the unspent part is refunded on L2 to an unreachable aliased address (effectively burned — same section).

### Why `maxFee` is bumped too (and why it doesn't increase per-sync cost)

- CCIP's actual fee scales **linearly with `gasLimit`**: `fee ≈ baseFee + premium + gasLimit × destChainGasPrice × tokenConversion`. A 25% `gasLimit` bump raises the actual fee by the same 25% at any given L1 gas price.
- `maxFee` is a safety cap on the L2 send (`CCIPSenderUpgradeable.sol:82`). Bumping it 0.1 → 0.125 ETH preserves the spike-protection multiplier that the prior `maxFee` provided against the prior `gasLimit` (i.e., keeps the same "headroom over typical fee" ratio).
- Excess (`maxFee − actualFee`) is **fully refunded** to the SyncTrigger by `TokenHelper.refundExcessNative` after every send (`CustomSender.sol:208`). So `maxFee` bloat costs **zero per-sync ETH** — only larger transient float locked up for the duration of one transaction.

### Cost framing

| Dimension | Real per-sync cost? | Why |
|---|---|---|
| `gasLimit` bloat (+25%) | **Yes** | CCIP OffRamp is paid for the L1 gas commitment whether or not the receiver uses it all; unused gas is the executor's margin |
| `maxFee` bloat (+25%) | No (zero) | Refunded by `refundExcessNative`; only locks ETH transiently inside one tx |

Order-of-magnitude on the `gasLimit` bump: at the [measured fee slopes](#consequences-of-unnecessarily-high-feeotod--feedtoo-limits) (~0.0002–0.0003 ETH per +100k `gasLimit`), the +200k/+100k bumps cost ~0.0005 ETH (~$1.5–2.5) per sync × up to 8 syncs/day across 4 chains ≈ **$10–20/day** (scales with L1 gas price). Trade is favorable against the alternative — a post-hard-fork cliff where every sync OOGs in `processMessage`, the defensive catch stores `failedHashes[messageId]`, funds (WETH and Arbitrum's `feeAmountDtoO`) sit at `LidoCustomReceiver` until manual `retryFailedMessage`, and user-facing wstETH liquidity erodes on each L2.

### Operational handoff

- Constants live in `script/<net>/<Net>MigrationConstants.sol` (`L2_SYNC_DESTINATION_MAX_FEE`, `L2_SYNC_DESTINATION_GAS_LIMIT`).
- New SyncTrigger deploys pick up the values via the `SyncTrigger` constructor (the `feeOtoD` arg that `L2UpgradeActions.deploySyncTrigger` builds from these constants).
- For SyncTriggers already deployed before the bump, the lever is owner-only `setFeeOtoD` (the LOL multisig; per [Per-call levers (DOC.md §3)](../DOC.md#3-access-control--ownership--the-final-state)); the source-of-truth bytes are the constants in `script/<net>/<Net>MigrationConstants.sol`, which `verify-stage1` keccak-compares against `SyncTrigger`'s stored blobs (`script/shared/L2UpgradeActions.s.sol`), so any future bump must update those constants in lockstep with the on-chain change.
- The byte-for-byte fee encodings are derived from those constants by `FeeCodec` in `lib/chainlink-csr` (`encodeCCIP` for FeeOtoD, the per-network `encode*L1toL2` for FeeDtoO) and pinned by the `verify-stage1` keccak check above. state-mate also re-checks them post-migration: the shared wiring `config/state/l2.yaml` asserts `getFeeOtoD` / `getFeeDtoO` / `getMaxFees` against the per-lane `config/state/l2-<net>.inputs.yaml` anchors, which `verify-constants-sync` cross-checks against `FeeCodec(constants)` (see [DOC.md §5.2](../DOC.md#52-fee-parameters-per-chain--and-why-they-are-set-this-way)). Refund mechanics, failure modes, and per-network differences are in the [Failure modes and recovery](#failure-modes-and-recovery) and [L1→L2 vs L2→L1](#l1l2-vs-l2l1--why-the-two-legs-differ) sections above.
- **After any post-deploy `setFeeDtoO`, re-validate off-chain — the on-chain check won't catch a
  lane-mismatched blob.** `setFeeDtoO` enforces only the generic `len>=17`, so update the lane's
  `config/state/l2-<net>.inputs.yaml` `feeDtoO` anchor (and the matching `<Net>MigrationConstants.sol`
  bytes) in lockstep, then run the lane **state-mate** (live `getFeeDtoO` vs the anchor) and
  `just verify-constants-sync` (anchor vs `FeeCodec(constants)`). Otherwise a wrong blob surfaces only on
  L1 as a parked `MessageFailed`, recoverable via `recoverTokens` ([`audit-scope.md §D` F-4](audit-scope.md#d-fee-configuration--liveness)).

## Measured `ccipReceive` gas (independent `gasLimit` carrier)

`FeeOtoD.gasLimit` is justified by **measurement**, not by its prior config value. The fork test
`PoolUpgradeTests.test_ccipReceiveGasRealAdapter` executes the real L1 `LidoCustomReceiver.ccipReceive`
(Lido stake → wstETH wrap → the **real** per-network bridge adapter) and records the gas it consumes —
the exact work `gasLimit` budgets. Regenerate with **`just measure-fee-gas`** (needs the forked-mainnet
RPCs: `RPC_ETHEREUM` + each `RPC_<NET>`; legacy `L1_RPC_URL` / `L2_<NET>_RPC_URL` work as fallbacks).
The test hard-asserts the post-Glamsterdam projection
(`measured × 1.25 ≤ gasLimit`, i.e. no OOG) and logs utilization.

Measured 2026-06-10 vs latest forked mainnet (≈6 WETH synced; figures move ±~10% with fork block / Lido
buffer state — read as ranges, not constants):

| Lane         | CCIP ramp | Measured `ccipReceive` | Utilization | Post-Glamsterdam ×1.25 | Projected utilization |
| ------------ | --------- | ---------------------- | ----------- | ---------------------- | --------------------- |
| **Base**     | v1.6      | ~664k                  | ~66%        | ~830k                  | **~83%**              |
| **Arbitrum** | v1.6      | ~329k                  | ~33%        | ~411k                  | ~41%                  |
| **Optimism** | v1.5      | ~685k                  | ~69%        | ~857k                  | **~86%**              |
| **Linea**    | v1.5      | ~267k                  | ~53%        | ~334k                  | ~67%                  |

**Finding.** No lane out-of-gases (every projection < 100% of `gasLimit` — the test's hard assert).
**Optimism is the tightest lane** at ~86% post-Glamsterdam; **Base is close behind at ~83%** — both
*at* or slightly above the §5 80% headroom target. Arbitrum is comfortable (~41%); Linea has the most
headroom (~67% of its 500k limit). The measurement also confirms the earlier adapter-equivalence
inference: Optimism (~685k) is slightly higher than Base (~664k) — both use the OP-stack
`L1StandardBridge` path, and the small difference (~21k) reflects Optimism's v1.5 CCIP overhead vs
Base's v1.6. To restore the 80% headroom for Optimism under the worst-case +25% repricing, raise its
`gasLimit` to ~1.07M (`685k × 1.25 ÷ 0.80 ≈ 1.07M`); for Base ~1.04M (`664k × 1.25 ÷ 0.80`);
otherwise 1M is adequate-but-tight for both OP-stack lanes.

## Consequences of unnecessarily high `FeeOtoD` / `FeeDtoO` limits

The measured-carrier logic cuts both ways. Too low → OOG cliff (documented above). But "just set it huge"
is not a free hedge either: every lever has a distinct over-provisioning failure mode, and two of them are
**hard cliffs**, not gradual overpayment. All numbers below were measured against the live mainnet lanes /
forked mainnet on 2026-06-02.

| Lever | Cost of slack | Cliff above a threshold |
|---|---|---|
| `FeeOtoD.gasLimit` | linear fee overpayment on **every** sync (unused gas is never refunded) | > lane `maxPerMsgGasLimit` ⇒ now **rejected at config time** by `setFeeOtoD` (`SyncTriggerGasLimitAboveMax`, vs the `getMaxGasLimit()` ceiling); pre-this-guard it passed `setFeeOtoD` and bricked sync via `getFee` revert |
| `FeeOtoD.maxFee` | none per sync (excess refunded) — but raises the SyncTrigger float requirement and the worst-case per-sync spend it authorizes | — |
| `FeeDtoO.l2Gas` (OP/Base) | **burns L1 gas ~1:1 inside `ccipReceive`** — eats `FeeOtoD.gasLimit` headroom | enough slack alone pushes the lane over the OOG cliff (demonstrated below) |
| `FeeDtoO` (Arbitrum) | ~1:1 **unrecoverable** — "refunds" land at an aliased address nobody controls (proven on-chain below) | — |
| `FeeDtoO` (Linea) | n/a — nullary encoding, no lever to bloat (adapter enforces `feeAmount == 0`) | — |

### `FeeOtoD.gasLimit`: you pay for the commitment, and above the lane cap you halt

**Linear recurring cost.** CCIP prices the message on the *committed* `gasLimit`, not the gas the receiver
ends up using — the official billing model is `gas usage = gas limit + destination gas overhead + …` and
states verbatim that *"any unspent gas from this user-set limit is not refunded"*
([CCIP billing](https://docs.chain.link/ccip/billing); also [CCIP `gasLimit` best practices](https://docs.chain.link/ccip/tutorials/evm/ccipreceive-gaslimit)).
Measured via `Router.getFee` on the production lanes (native-fee quote for the real sync message shape,
2026-06-02; quotes float with L1 gas price — read as a snapshot; [reproduction below](#evidence--reproduction)):

| Lane | fee @ `gasLimit` = 1M | marginal cost per +100k `gasLimit` | lane cap `maxPerMsgGasLimit` |
|---|---|---|---|
| Optimism | ~0.0039 ETH | ~0.00024 ETH | 7,000,000 |
| Arbitrum | ~0.0051 ETH | ~0.00030 ETH | 7,000,000 |
| Base | ~0.0035 ETH | ~0.00023 ETH | 7,000,000 |
| Linea | ~0.0042 ETH | ~0.00020 ETH | **3,000,000** |

Doubling 1M → 2M raises every sync's fee by ~60% forever, buying headroom the [carrier above](#measured-ccipreceive-gas-independent-gaslimit-carrier)
proves is never used. At the ≤2 syncs/day/lane cadence this is small in absolute ETH — the real argument is
that the overpayment buys *nothing*: OOG protection comes from measured utilization staying under the §5
threshold, not from slack.

**The cap is a revert, not a ceiling.** Each lane's FeeQuoter enforces `maxPerMsgGasLimit`
([FeeQuoter.sol#L848](https://github.com/smartcontractkit/ccip/blob/5e7b2096586bc32c6e975fc13f4c411eb687f833/contracts/src/v0.8/ccip/FeeQuoter.sol#L848):
`if (evmExtraArgs.gasLimit > destChainConfig.maxPerMsgGasLimit) revert MessageGasLimitTooHigh()`) — and
measured empirically: `getFee` at cap+1 reverts with `MessageGasLimitTooHigh` (`0x4c4fc93a` =
`cast sig "MessageGasLimitTooHigh()"`; [probes below](#evidence--reproduction)). That revert fires
inside `CustomSender._ccipSendTo` (`CCIPSenderUpgradeable.sol:81`) → **every `triggerSync` reverts → the
lane's sync halts entirely.** Un-bricking requires an owner `setFeeOtoD` call (now a LOL multisig
transaction, not a cross-chain governance round-trip, [DOC.md §3](../DOC.md#3-access-control--ownership--the-final-state)), during which wstETH
liquidity on that L2 erodes. The chain-blind footgun: "set all four lanes to 5M for safety" exceeds
**only Linea**'s cap (3M vs 7M) — per-lane caps differ. **`SyncTrigger` now bounds this from above at
config time**: `setFeeOtoD` rejects `gasLimit > getMaxGasLimit()` with `SyncTriggerGasLimitAboveMax`,
where `getMaxGasLimit()` is the owner-set per-lane ceiling seeded to each lane's FeeQuoter
`maxPerMsgGasLimit` at deploy (3M Linea / 7M others). So the uniform-5M push fails loudly on the Linea
`setFeeOtoD` instead of silently bricking sync — but the ceiling is a static mirror, so if CCIP ever
lowers a lane cap, re-seed it via `setMaxGasLimit` (the live cap still governs at `sync` time).

**Monitoring blindness.** The [§5 alert](monitoring.md#5-capacity--headroom--medium) is utilization-relative
(`ccipReceive` gas / `gasLimit` < 80%). Bloating the denominator silences it: at `gasLimit` = 3M, Base's
~664k measures 22% — a +25% Glamsterdam regression moves it to 28%, nowhere near the threshold, and the
alert never fires before a *real* config problem accumulates elsewhere. A measured-tight limit is what
makes utilization a signal at all.

### `FeeOtoD.maxFee`: free per sync, but it is the per-sync blast-radius bound

Excess over the actual fee is refunded intra-transaction (see [Cost framing](#cost-framing)), so bloat
costs nothing per sync. The consequences are structural instead: `triggerSync` forwards
`maxFeeOtoD + feeAmountDtoO` of native ETH from the SyncTrigger's own balance (`src/SyncTrigger.sol:247`),
so `maxFee` sets (a) the **float** the trigger must hold to sync at all, and (b) the **worst-case spend a
single sync can authorize**. The current 0.125 ETH is already ~25× the measured ~0.005 ETH actual fee —
protective against spikes. Raising it "for safety" (say to 12.5 ETH) means a CCIP fee-token mispricing or
gas-price spike gets *paid silently* instead of reverting with `CCIPSenderExceedsMaxFee`
(`CCIPSenderUpgradeable.sol:82`) — and given the CREReceiver's nullary-call lock
(`src/cre/CREReceiver.sol:128` — a compromised forwarder can only fire argument-less, rate-limited
`triggerSync()` calls), the fee caps are exactly what bounds the damage of each
spurious-but-authorized sync. `maxFee` is the only lever where
"too high" weakens a *guard* rather than wasting ETH.

**Funding the float.** The SyncTrigger is the fee **treasury**, not a pass-through: the CRE forwarder
call carries no value, so every sync is paid from the trigger's own balance and nothing refills it
automatically. The mechanics:

- **Required balance**: ≥ `getMaxFees().maxNativeFee` (currently `maxFee` 0.125 ETH everywhere, +
  `feeAmountDtoO` ≈ 0.001005 ETH on Arbitrum). Below that, the next `triggerSync` reverts with the
  named **`SyncTriggerInsufficientFloat(required, available)`** (a pre-flight check before the value
  transfer), and **`canSync()` returns `false`** so the DON suppresses the report — see [Failure modes](#failure-modes-and-recovery).
- **Net drain per sync**: `actualFee + feeAmountDtoO` ≈ 0.005–0.007 ETH at measured fees — the
  `maxFee − actualFee` excess is refunded to the trigger intra-transaction (bare `receive()`,
  `src/SyncTrigger.sol:54`), so the float depletes by the *actual* cost, not the fronted maximum.
  At ≤2 syncs/day that is ≤ ~0.013 ETH/day/lane.
- **Funding is permissionless** (anyone can send ETH to the trigger); **recovering excess is not**
  (`sweep()` is owner-only = LOL multisig, `src/SyncTrigger.sol:288` — a Safe transaction). So
  size deposits as floor + bounded runway (e.g. `maxNativeFee` + ~30 days ≈ 0.5 ETH/lane), not
  "fill it up", and refill from the [§5 alert](monitoring.md#5-capacity--headroom--medium).
- **Initial funding is part of `deploy-stage1` itself** (`fundSyncTrigger`, `script/shared/L2UpgradeActions.s.sol`):
  the amount is pinned as `L2_SYNC_TRIGGER_INITIAL_FLOAT` in each network's `MigrationConstants` (0.5 ETH;
  Sepolia 0.15), sent from the Lido Deployer wallet during the Stage-1 broadcast. The script reverts with
  `L2UpgradeFloatBelowFloor` if the constant doesn't cover one worst-case sync (`maxFee + feeDtoO`), and
  both the in-broadcast assert and `verify-stage1` read the balance back. Fork-test coverage:
  `test_productionDeployFundsSyncTriggerFloatForFirstSync` runs the first sync on the script-funded float
  alone — no test-side `vm.deal`.
- If `payInLink` were ever enabled, the same holds for a **LINK** balance (the constructor
  pre-approves LINK to the sender, `src/SyncTrigger.sol:76`); `getMaxFees().maxLinkFee` is the floor.

### `FeeDtoO.l2Gas` (Optimism/Base): burns L1 gas inside `ccipReceive` — coupled to `FeeOtoD.gasLimit`

`feeAmount` is 0 on OP-stack lanes, but `l2Gas` is **not free**: the deposit path
(Lido `L1ERC20TokenBridge` → `CrossDomainMessenger.sendMessage` → `OptimismPortal.depositTransaction`)
buys guaranteed L2 gas by **burning L1 gas** in the portal's resource market. This is specified behavior,
not an implementation accident — the [OP guaranteed gas market spec](https://specs.optimism.io/protocol/guaranteed-gas-market.html)
says the portal *"burns an amount of L1 gas that corresponds to the L2 cost (`L2 cost / L1 base fee`)"*
with `MINIMUM_BASE_FEE = 1 gwei`, implemented in
[`ResourceMetering.sol`](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L1/ResourceMetering.sol)
(`gasCost = _amount × params.prevBaseFee / max(block.basefee, 1 gwei)`; shortfall vs gas already spent is
`Burn.gas`-ed) — and that burn happens *inside the L1 `ccipReceive` that `FeeOtoD.gasLimit` budgets*.

Measured on the Base fork (carrier test, 2026-06-02), changing only `l2Gas`:

| `FeeDtoO.l2Gas` | measured `ccipReceive` gas | carrier verdict (vs 1M `gasLimit`) |
|---|---|---|
| 100,000 (current) | 664,234 | PASS (66%) |
| 600,000 | 1,172,150 | **FAIL — would OOG in production** |

Slope: Δ507,916 / Δ500,000 = **1.016 : 1** — exactly the messenger's 64/63 dynamic overhead
([`CrossDomainMessenger.baseGas`](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/universal/CrossDomainMessenger.sol):
`MIN_GAS_DYNAMIC_OVERHEAD_NUMERATOR = 64` / `…DENOMINATOR = 63`) at the deposit
base fee's 1-gwei floor (the worst case, which is also the *current* case at sub-gwei L1 basefees; the
ratio shrinks as L1 basefee rises — see the spec formula above). Reproduce: change `l2Gas` in
`_defaultFeeDtoO` (`test/helpers/BaseUpgradeTestBase.sol:75`) and re-run the carrier
(`just measure-fee-gas`). Consequences of slack: every extra unit of `l2Gas` (a) eats
`FeeOtoD.gasLimit` headroom ~1:1 — at current configs, `l2Gas` slack of ~300k alone crosses the OOG cliff;
(b) forces `FeeOtoD.gasLimit` up to compensate, which raises every sync's CCIP fee (the levers are
coupled on OP-stack lanes — bloat one, pay on both). Size `l2Gas` to the actual L2 `finalizeDeposit` cost
plus a measured buffer, nothing more. (Too *low* is still worse: under-gassed deposits fail with no
recovery — see [Failure modes](#failure-modes-and-recovery).)

### `FeeDtoO` (Arbitrum): overpayment is "refunded" to an address nobody controls

The chain of evidence, step by step:

1. **Refund addresses = the L1 receiver.** Lido's deployed wstETH gateway
   (`0x0F25c1DC2a9922304f2eac71DCa9B07E310e8E5a`, resolved on-chain via
   `L1GatewayRouter.l1TokenToGateway(wstETH)`) builds the retryable in
   [`L1CrossDomainEnabled.sendCrossDomainMessage`](https://github.com/lidofinance/lido-l2/blob/main/contracts/arbitrum/L1CrossDomainEnabled.sol),
   which passes `sender_` — the router's caller, i.e. the **LidoCustomReceiver contract** — as both
   `excessFeeRefundAddress` and `callValueRefundAddress` of `Inbox.createRetryableTicket`.
2. **Contract refund addresses get aliased.** Per the
   [official Arbitrum docs](https://docs.arbitrum.io/how-arbitrum-works/arbos/l1-l2-messaging):
   `createRetryableTicket` *"will check if either the provided `excessFeeRefundAddress` or the
   `callValueRefundAddress` are contracts on L1; if they are … it will convert them to their address
   alias"* (`L2_Alias = L1_address + 0x1111000000000000000000000000000000001111`); implementation in
   [`AbsInbox._createRetryableTicket`](https://github.com/OffchainLabs/nitro-contracts/blob/main/src/bridge/AbsInbox.sol)
   (`AddressUpgradeable.isContract(…) → AddressAliasHelper.applyL1ToL2Alias(…)`).
3. **The refund is most of the budget.** The *actual* submission fee is
   `(1400 + 6 × dataLength) × L1 basefee`
   ([`Inbox.calculateRetryableSubmissionFee`](https://github.com/OffchainLabs/nitro-contracts/blob/main/src/bridge/Inbox.sol);
   the [Arbitrum docs](https://docs.arbitrum.io/how-arbitrum-works/arbos/l1-l2-messaging) describe it as a
   *"fixed cost, dependent only on its calldata size"*) — a few thousand gas-equivalents ≈ 10⁻⁵ ETH at
   ~1 gwei — so ~99.5% of the 0.001 ETH `maxSubmissionCost`, plus unused `maxGas × gasPriceBid`, is
   "refunded" each sync.
4. **Where it lands.** `alias(L1 receiver 0x6F35…4588)` = `0x80467D53d6be3238180316Ba5F8f11467E165699`
   on Arbitrum: an address with no code and no key. **Verified on-chain (2026-06-02): it holds
   0.01753 ETH at nonce 0** — accumulated refunds from past syncs that have never moved and cannot move
   ([commands below](#evidence--reproduction)).

Recovery would require upgrading the L1 receiver implementation to issue its own L1→L2 calls — the alias
is precisely the recovery path the Inbox aliasing is designed to leave open (per the docs, aliasing exists
*"to prevent the situation where refunds are guaranteed to be irrecoverable"*), but for a proxied,
DAO-governed receiver that is governance surgery, not operations.

Consequence: Arbitrum `FeeDtoO` over-provisioning is a **per-sync 1:1 burn**, unlike `maxFee` (refunded)
and unlike OP/Base `l2Gas` (burned as gas). The current ~0.001005 ETH/sync is the deliberate, known price
of auto-redeem reliability; 10×ing `maxSubmissionCost` "for safety" 10×es a recurring loss with zero
reliability gained (a too-low value fails *loudly* on L1 and is retryable — see
[Failure modes](#failure-modes-and-recovery)).

### `FeeDtoO` (Linea): no lever

`FeeCodec.encodeLineaL1toL2()` is nullary (`lib/chainlink-csr/contracts/libraries/FeeCodec.sol:382`) and
`LineaAdapterL1toL2._sendToken` reverts on `feeAmount != 0`
(`lib/chainlink-csr/contracts/adapters/LineaAdapterL1toL2.sol:49-50`) — there is nothing to over-provision.
Delivery rides Linea's sponsored postman: *"the postman fee for automatic claiming is only sponsored for
transactions using less than 250,000 gas"*
([Linea message-service docs](https://docs.linea.build/network/build/send-receive-messages)).

### Plan: when reality outgrows a limit — what breaks, how to fix it

The converse scenario: the limits are sized to measurement, so a regime change (Glamsterdam repricing, an
L1 gas-price era shift, a bridge/Lido code change, deposit-market congestion) can push *actual* usage past
a limit that used to be adequate. Detection first, then per-limit playbook, then the standing update
procedure.

**Detection.** The [§5 monitoring alerts](monitoring.md#5-capacity--headroom--medium) are the early warning — both fire
at **80% utilization, before anything breaks**: `ccipReceive gas / gasLimit` and `actual CCIP fee / maxFee`.
The carrier test (`just measure-fee-gas`) re-derives the gas number on demand and hard-fails acceptance
once the ×1.25 projection no longer fits. If an alert fires, fix proactively (procedure below) — every row
in the table after it describes the *reactive* case where the limit was already breached.

| Limit breached | What breaks (symptom) | Funds at risk | Interim recovery | Permanent fix |
|---|---|---|---|---|
| `FeeOtoD.gasLimit` < actual `ccipReceive` gas | `processMessage` OOGs on L1; defensive catch stores `failedHashes[messageId]` ([`CCIPDefensiveReceiverUpgradeable.sol#L200`](https://github.com/Aphyla/chainlink-csr/blob/62108f7b6cc664e36dbc8100c4b48974d59f572e/contracts/ccip/CCIPDefensiveReceiverUpgradeable.sol#L200), pinned at the vendored submodule commit); synced WETH (+ Arbitrum `feeAmountDtoO`) parks at the L1 receiver; every subsequent sync joins it | Parked, not lost | **Permissionless** `retryFailedMessage` (`:131`, no role gate) — the retry runs on the caller's own tx gas, so it succeeds with a bigger gas limit; if the *whole* `ccipReceive` reverted at CCIP level instead, use [CCIP manual execution](https://docs.chain.link/ccip/concepts/manual-execution) with a gas-limit override | Raise `gasLimit` via LOL `setFeeOtoD` (procedure below) |
| `FeeOtoD.maxFee` < actual CCIP fee | `triggerSync` reverts `CCIPSenderExceedsMaxFee` (`CCIPSenderUpgradeable.sol:82`); syncs stall, pool WETH accumulates on L2. Two drivers: an L1 gas-price spike, **or — on OP/Linea — sync size** (CCIP 5 bps, uncapped; held to ~40% of `maxFee` by the 100 WETH cap, so an amount-driven breach implies `maxAmount` was raised — [amount-sensitivity](otod-fee-amount-sensitivity.md)) | No — pure liveness; **self-heals if a gas-price spike is transient** (CRE re-attempts each tick); an amount-driven breach persists until re-tuned | Wait out a transient spike; nothing is stuck | If the fee regime shifted: raise `maxFee` via `setFeeOtoD` **and top up the SyncTrigger float** to ≥ new `maxFee + feeAmountDtoO`. If an OP/Linea breach followed a `maxAmount` raise, restore the `maxAmount`↔`maxFee` coupling instead |
| SyncTrigger ETH balance < `maxFee + feeAmountDtoO` | `triggerSync` reverts with the named **`SyncTriggerInsufficientFloat(required, available)`** (a pre-flight check, not a bare EVM balance failure), and **`canSync()` returns `false`** so the DON stops submitting; syncs stall, pool WETH accumulates. Still symptom-adjacent to the `maxFee` row, so **check `cast balance <trigger>` against `getMaxFees()` first** when diagnosing a stall | No — pure liveness | **Anyone** sends ETH to the trigger (bare `receive()`, permissionless — no governance needed); self-heals on the next CRE tick | Top up to ≥ `getMaxFees().maxNativeFee` + runway ([Funding the float](#feeotodmaxfee-free-per-sync-but-it-is-the-per-sync-blast-radius-bound)); keep deposits modest — recovering excess is `sweep()` = owner-only (LOL) |
| Arbitrum `maxSubmissionCost` < actual submission fee | L1 `outboundTransfer` reverts `InsufficientSubmissionCost` (`AbsInbox.sol:298-301`) → defensive catch → `failedHashes`, as row 1. Headroom today: breach needs L1 basefee ≳200 gwei (`0.001 ETH ÷ (1400 + 6N)` at N ≈ 350–600 bytes of retryable calldata) | Parked, not lost | `retryFailedMessage` once basefee dips — the fee bytes are frozen inside the failed message, so retry *cannot* carry a bigger budget; it only succeeds when the fee falls back under it | Raise `maxSubmissionCost` via `setFeeDtoO` for future syncs |
| Arbitrum `gasPriceBid` < L2 basefee | Ticket created but auto-redeem fails; wstETH not minted on L2 yet | **Yes if ignored**: manual-redeem window is ~7 days, then the ticket expires and the bridged wstETH is stranded ([Failure modes](#failure-modes-and-recovery)) | Manual redeem (permissionless) via the [retryable dashboard](https://retryable-dashboard.arbitrum.io/) within 7 days — redeemer pays current L2 gas | Raise `gasPriceBid` via `setFeeDtoO` |
| OP/Base `l2Gas` < actual `finalizeDeposit` gas | L2 relay's target call fails; the L2 messenger records it in `failedMessages` ([OP messengers spec](https://specs.optimism.io/protocol/messengers.html)) | Parked, not lost (Bedrock) | **Permissionless replay**: call `relayMessage` on the L2 messenger with the same params and more gas (no ETH value rides the wstETH deposit, so replay is a plain tx) | Raise `l2Gas` via `setFeeDtoO` — re-measure the `FeeOtoD.gasLimit` coupling afterwards (the burn grows ~1:1, [see above](#feedtool2gas-optimismbase-burns-l1-gas-inside-ccipreceive--coupled-to-feeotodgaslimit)) |
| Linea relay > 250k sponsored gas | Postman stops auto-claiming; wstETH waits unclaimed on L2 | Parked, not lost | Permissionless `claimMessage` on the L2 message service ([Linea docs](https://docs.linea.build/network/build/send-receive-messages)) | None on our side — the adapter pins `feeAmount = 0`, so the fix is reducing relay gas or accepting manual claims |
| `feeDtoO` wrong **format/length** (owner-misconfig, not an outgrown limit) | Passes `setFeeDtoO` (`len>=17`) **and** L2 (`CustomSender` decodes `feeDtoO` only generically); reverts inside the **L1 adapter** on the lane decode → defensive catch → `failedHashes` (`MessageFailed`); restrands each cycle, **no L2 signal** | Parked, not lost | **L1 governance** `recoverTokens` (`DEFAULT_ADMIN_ROLE`) frees the parked batch — `retryFailedMessage` re-reverts (the bad bytes are frozen in the message) | Re-encode the correct lane shape ([FeeDtoO encoding](#feedtoo-encoding-network-specific)) via `setFeeDtoO`, then re-validate off-chain ([Operational handoff](#operational-handoff)) |
| Required `gasLimit` > lane cap (7M / 3M Linea) | Cannot be fixed by `setFeeOtoD` — the cap is Chainlink's, enforced in the lane FeeQuoter | n/a (config ceiling, not an incident) | — | Escalate to Chainlink for a lane-config change, or shrink the receiver's work (architectural). At 66% of 1M vs a 7M cap, Base has ~10× runway before this is real |

**Standing update procedure** (any fee-limit change):

1. **Re-measure, don't guess**: `just measure-fee-gas` for `gasLimit` (size = `measured × 1.25 ÷ 0.80`,
   the [Finding](#measured-ccipreceive-gas-independent-gaslimit-carrier)'s formula); `Router.getFee`
   quotes for `maxFee` (size ≈ 10–25× typical, keeping the spike multiplier).
2. **Check the ceiling**: new `gasLimit` < the lane's `maxPerMsgGasLimit` (7M / 3M — per lane, not global).
3. **Re-encode** with `FeeCodec` (`encodeCCIP` / per-network `encode*L1toL2`) and ship via LOL
   `setFeeOtoD` / `setFeeDtoO` — owner-only levers ([DOC.md §3](../DOC.md#3-access-control--ownership--the-final-state)),
   so this is a LOL multisig transaction, not a full governance round-trip: **coordinate signers** and front-run it from the
   80% alert, not from the breach.
4. **Lockstep the oracle**: update the fee constants in `script/<net>/<Net>MigrationConstants.sol` — the
   bytes `verify-stage1` keccak-checks against the on-chain blobs (per [Operational handoff](#operational-handoff)) —
   **and** the matching `config/state/l2-<net>.inputs.yaml` `feeOtoD` / `feeDtoO` anchors, which the live
   state-mate run now pins (`getFeeOtoD` / `getFeeDtoO`) and `verify-constants-sync` cross-checks against
   `FeeCodec(constants)`. Keep all three in lockstep with the on-chain change.
5. **Re-run the carrier + acceptance** (`just measure-fee-gas`, `just test-acceptance`) and,
   if `maxFee` or Arbitrum `FeeDtoO` rose, **top up the SyncTrigger float** accordingly.

### Evidence & reproduction

All measured claims in this section are one command away (2026-06-02 snapshots; ETH chain selector
`5009297550715157269`, routers from `script/<net>/<Net>MigrationConstants.sol`):

```bash
# Fee-vs-gasLimit slope and lane cap (repeat per lane router + RPC; vary <GAS_LIMIT_HEX>):
# extraArgs = EVMExtraArgsV1 tag 0x97a657c9 ++ abi.encode(gasLimit)
cast call <L2_CCIP_ROUTER> \
  "getFee(uint64,(bytes,bytes,(address,uint256)[],address,bytes))(uint256)" \
  5009297550715157269 \
  "(0x000000000000000000000000<L1_RECEIVER>,0x<81 zero bytes>,[(<L2_WETH>,1000000000000000000)],0x0000000000000000000000000000000000000000,0x97a657c9<GAS_LIMIT_HEX_32B>)" \
  --rpc-url <l2-rpc>
# → linear in gasLimit; at cap+1 reverts 0x4c4fc93a (= cast sig "MessageGasLimitTooHigh()").
# Caps read back: 7,000,000 (Optimism/Arbitrum/Base), 3,000,000 (Linea).

# Arbitrum burned-refund evidence (alias of L1 receiver 0x6F35…4588 + 0x1111…1111):
cast balance 0x80467D53d6be3238180316Ba5F8f11467E165699 --rpc-url <arbitrum-rpc>  # 17534996693853952 wei
cast nonce   0x80467D53d6be3238180316Ba5F8f11467E165699 --rpc-url <arbitrum-rpc>  # 0
cast code    0x80467D53d6be3238180316Ba5F8f11467E165699 --rpc-url <arbitrum-rpc>  # 0x

# Lido wstETH Arbitrum gateway (step 1 above), resolved from the canonical router:
cast call 0x72Ce9c846789fdB6fC1f34aC4AD25Dd9ef7031ef "l1TokenToGateway(address)(address)" \
  0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 --rpc-url <l1-rpc>  # → 0x0F25c1DC…8E5a

# OP/Base l2Gas → L1 burn slope: set l2Gas in _defaultFeeDtoO
# (test/helpers/BaseUpgradeTestBase.sol:75) to 600_000, then:
just measure-fee-gas   # Base carrier: 664,234 → 1,172,150 measured ccipReceive gas (and FAILs the budget assert)
```

## Historical actuals — every production sync, on-chain

Everything above is *config* (current values), a *quote* (`Router.getFee`), or *forked-gas
measurement*. This section adds the fourth kind of evidence — **what real syncs have actually
paid** — decoded from the `feeTokenAmount` of the CCIP `CCIPSendRequested` event of every
production OtoD send. These are Automation-era sends (the trigger that preceded this repo's CRE
`SyncTrigger`), but over the **same `chainlink-csr` `CustomSender`s, the same CCIP lanes, and the
same L1 receiver `0x6F35…4588`** this repo keeps — so the OtoD economics are directly comparable.
Swept 2026-06-17 from each lane's `CustomSender` `Sync` events ([reproduction below](#reproduction)).

**Dataset — 60 production-volume sends** across three lanes (each lane's *first* send was a smoke
test, excluded from the ETH stats; Linea's lone send is itself a smoke test):

| Lane | sends | span | actual OtoD fee, ETH — min / median / max | `gasLimit` | feeToken |
|---|---|---|---|---|---|
| **Optimism** | 9 (+1 smoke) | 2024-10 → 2026-04 | 0.00274 / 0.00620 / 0.01947 | 400k → 800k | WETH |
| **Base** | 35 (+1 smoke) | 2024-10 → 2026-03 | 0.00257 / 0.00311 / 0.02277 | 400k → 800k | WETH |
| **Arbitrum** | 16 (+1 smoke) | 2024-10 → 2026-02 | 0.00281 / 0.00544 / 0.01945 | 400k → 800k | WETH |
| **Linea** | smoke only | 2025-07 | 0.01343 — one 0.002 WETH test, ~all gas | 400k | WETH |

Linea has made **exactly one** send to date — a 0.002 WETH smoke test on 2025-07-16 (fee 0.01343 ETH,
essentially all gas at the 400k limit, since the premium on 0.002 WETH is ~1 µETH). It runs
`EVM2EVMOnRamp 1.5.0` like Optimism, but that lone send is far too small to exercise the premium, so
**Linea has no production-volume fee on record** and its 5 bps ([E-4](otod-fee-amount-sensitivity.md))
stays `getFee`-derived only.

**The transaction this section started from** — Optimism, 2026-04-23,
[`0x9316…51d1`](https://optimistic.etherscan.io/tx/0x9316be0ec7de338b4467ea299cbcd2cd75004c3c0a2257d283a480b50d6451d1)
— decomposes the way every row does:

| Component | Value | Share of fee |
|---|---|---|
| Amount synced | 7.157 WETH | — |
| **Actual OtoD fee** (`feeTokenAmount`) | **0.006202052184223526 WETH** | 100% |
| ↳ amount premium = 5 bps × 7.157 | ≈ 0.003579 ETH | **≈ 58%** |
| ↳ gas part = baseFee + 800k × L1 price | ≈ 0.002624 ETH | ≈ 42% |

### Finding 1 — the amount premium is usually the *majority* of the fee

[`otod-fee-amount-sensitivity.md`](otod-fee-amount-sensitivity.md) derived the 5 bps premium from
`getFee` sweeps + on-chain config; the production record **confirms it with real sends**. The
cleanest estimator is the minimum `fee ÷ amount` per lane (the lowest-L1-gas send, where the gas
part nearly vanishes):

| Lane | min `fee ÷ amount` | matches |
|---|---|---|
| Optimism | **5.06 bps** | configured `deciBps = 50` (5.0 bps) |
| Base | **5.06 bps** | v1.5 — see Finding 2 |
| Arbitrum | **5.01 bps** | v1.5 — see Finding 2 |

**What "5 bps" means.** A basis point is 0.01%, so **5 bps = 0.05% of the bridged WETH amount** (the
volume moved) — 0.0005 WETH of premium per WETH synced: **0.05 WETH on a 100 WETH sync**, 0.005 WETH on
a 10 WETH sync, ~0.0036 WETH on the 7.157 WETH example above. (It is a fee on the *amount bridged*, not
on any profit or yield.) Because the bridged amount is itself ETH-denominated, the USD value cancels
(`premium_ETH = deciBps/1e5 × amount = 0.0005 × amount`), so **the premium is independent of the ETH
price** — and the ratio holding at ~5.0 bps from 2024→2026 through large ETH-price swings is the
on-chain proof. In low-gas periods the gas part falls to ~0.00005–0.0006 ETH and the premium is
**97–99%+** of the fee;
even at the April gas level it was ~58% (above). **So tuning the OtoD fee is mostly about the amount,
not gas** — the coupling [§4 D-1](otod-fee-amount-sensitivity.md) flags.

### Finding 2 — the 5 bps is a CCIP-*version* trait, and Base/Arbitrum have already left it

All 63 sends used **CCIP v1.5 (`EVM2EVMOnRamp`)** — *including Base and Arbitrum*, which the
amount-sensitivity table records as "≈0 bps flat" today. That flatness is **`FeeQuoter 2.0.0`
(v1.6)**, and on Base/Arbitrum it took over *after* their last production sync:

| Lane | OnRamp now (2026-06-17) | `typeAndVersion` | last v1.5 send | premium today |
|---|---|---|---|---|
| Optimism | `0xE4C51Dc0…E698` (same as the linked tx) | **EVM2EVMOnRamp 1.5.0** | still live | 5 bps |
| Linea | `0x69AbB60…20f4` | **EVM2EVMOnRamp 1.5.0** | still live | 5 bps |
| Base | `0xee85aEf…A7Ae` (new) | **OnRamp 1.6.0** | 2026-03-30 | 0 bps |
| Arbitrum | `0x76a4437…eb40` (new) | **OnRamp 1.6.0** | 2026-02-11 | 0 bps |

Two consequences for how the doc should be read:

- **Base/Arbitrum's 0-bps regime has never been exercised by a real sync** — it is `getFee`-predicted
  only ([E-2 / E-3](otod-fee-amount-sensitivity.md)). Every *actual* Base/Arbitrum OtoD fee on record
  is 5 bps; the first v1.6 send will be its first confirmation.
- **The OP/Linea `maxAmount`↔`maxFee` coupling is a "while-on-v1.5" discipline, not a permanent lane
  property.** When CCIP migrates OP/Linea to v1.6, their 5 bps will likely drop to 0 the same way,
  relaxing [D-1](otod-fee-amount-sensitivity.md) there too. **Track the OnRamp `typeAndVersion`, not
  the lane name.**

### Finding 3 — `maxFee` headroom is borne out

The 0.125 ETH `maxFee` has never been close. The two historical high-water marks have different
drivers, both far under it:

| High-water driver | Fee | % of `maxFee` |
|---|---|---|
| Largest amount ever synced — 38.6 WETH (Jan–Feb 2026) | ≈ 0.0195 ETH | ≈ 15.6% |
| Largest L1 gas spike — Base, 2025-01-24, 10 WETH | ≈ 0.0228 ETH | ≈ 18.2% |

The largest amount ever synced (**38.6 WETH**) is well below the 100 WETH cap, so the
[amount-sensitivity](otod-fee-amount-sensitivity.md) "~40% of `maxFee` at the 100 WETH cap /
breakeven ~250 WETH" projection has never been stress-tested in production — but the 5 bps slope it
rests on is confirmed.

### Operational deltas, history → now

- **Fee token was WETH, not native ETH.** Automation-era sends paid the CCIP fee in WETH
  (`feeToken = L2 WETH`); this repo's `SyncTrigger` fronts **native ETH**
  ([when the money moves](#fee-denomination-the-four-quantities-and-when-money-moves)). Magnitudes
  are 1:1 (WETH ≈ ETH); the float-funding model is what changed.
- **The first send on each lane was a smoke test, excluded above.** ≈0.01 WETH paid in LINK on
  Optimism/Base/Arbitrum (the only `payInLink = true` sends in the record); on Linea a 0.002 WETH
  WETH-paid send that is still its *only* send to date.
- **`gasLimit` history is 400k → 800k**; the [current 1M / Glamsterdam bump](#glamsterdam-fee-headroom-bump-may-2026)
  is the next step. Recent gas parts are sub-0.001 ETH, so the bump's marginal cost is real but minor
  next to the premium.

### Reproduction

(2026-06-17; per-lane `CustomSender` from `config/state/l2-<net>.deployed.yaml` — OP/Base/Linea share
`0x328de900…`, Arbitrum is `0x72229141…`.)

```bash
SENDER=0x328de900860816d29D1367F6903a24D8ed40C997   # OP/Base/Linea; Arbitrum: 0x72229141D4B016682d3618ECe47c046f30Da4AD1
SYNC=0x2826f7440c9ba1050bcd2c586a60551875ac8951ec73f01df55ef00b59ae1a9c   # cast keccak 'Sync(address,uint64,bytes32,uint256)'

# 1. every OtoD send from this CustomSender (log data = messageId ++ amount):
cast rpc eth_getLogs \
  "{\"address\":\"$SENDER\",\"topics\":[\"$SYNC\"],\"fromBlock\":\"0x1\",\"toBlock\":\"latest\"}" \
  --rpc-url <l2-rpc>

# 2. actual fee + gasLimit of one send — decode its CCIPSendRequested (v1.5 EVM2EVMMessage) log.
#    OnRamp topic 0xd0c3c799…43dddd; in the log's data hex (incl. 0x prefix):
#    word 5 = gasLimit (chars 322..386), word 9 = feeTokenAmount = the OtoD fee (chars 578..642).
D=$(cast receipt <syncTxHash> --rpc-url <l2-rpc> --json | jq -r \
  '.logs[]|select(.topics[0]=="0xd0c3c799bf9e2639de44391e7f524d229b2b55f5b1ea94b2bf7da42f7243dddd").data')
echo "gasLimit=$(cast to-dec 0x${D:322:64})  fee=$(cast from-wei $(cast to-dec 0x${D:578:64})) WETH"

# 3. live CCIP version per lane (v1.5 ⇒ 5 bps; v1.6 / FeeQuoter 2.0.0 ⇒ 0 bps for WETH):
cast call <L2_CCIP_ROUTER> "getOnRamp(uint64)(address)" 5009297550715157269 --rpc-url <l2-rpc> \
  | xargs -I{} cast call {} "typeAndVersion()(string)" --rpc-url <l2-rpc>
```

## Sync thresholds & cadence — why these values

`SyncTrigger` gates *when* and *how much* each sync moves (identical on all four lanes). Changing the amounts/delay is an owner action (`setAmounts` / `setDelay`, the LOL multisig); the cron lives in the CRE workflow config.

| Param | Value | Why this value / turn-the-dial |
| --- | --- | --- |
| `L2_SYNC_MIN_AMOUNT` | 5 WETH | Floor below which `shouldSync()` is false. Keeps round-trip fees a sub-percent fraction of the synced amount; too low → fees become a yield drag; too high → deposits sit idle missing Lido yield. |
| `L2_SYNC_MAX_AMOUNT` | 100 WETH | Per-sync cap (residual stays for the next sync). Bounds CCIP fee exposure, Lido `submit` impact, and in-flight L1→L2 bridge exposure to ≤100 wstETH. Too low → many small syncs, more overhead. |
| `L2_SYNC_DELAY` | 12 h | Min wall-clock between syncs — ≤2 paid syncs/day/lane, roughly aligned with Lido's daily oracle cadence. Shorter → ~12× more fees; longer → larger idle balances / tail risk. Doubles as the migration cutover quiet-window. |
| CRE cron | `*/5 * * * *` | DON *evaluation* cadence (most ticks return false — a cheap staticcall), not action cadence. 5 min = 1/144 of the 12 h delay → ≤5 min latency once a sync is due. Tighter → ~5× DON cost; looser → added post-delay latency. |

## L1→L2 vs L2→L1 — why the two legs differ

The forward leg (L2→L1, `FeeOtoD`) uses **Chainlink CCIP**; the return leg (L1→L2, `FeeDtoO`) uses each L2's **native bridge**. They are not symmetric:

| Aspect | L2→L1 (CCIP, `FeeOtoD`) | L1→L2 (native, `FeeDtoO`) |
|---|---|---|
| Fee paid by | L2 caller at send time | OP/Base: sequencer (free); Arbitrum: L1 receiver via `msg.value`; Linea: postman (free) |
| Excess refund | `maxFee` excess refunded; the gas commitment is **not** | OP/Base: n/a; Arbitrum: "refunded" to an unreachable aliased address (= burned, [see Consequences](#consequences-of-unnecessarily-high-feeotod--feedtoo-limits)); Linea: n/a |
| Failure / recovery | Defensive catch at L1 receiver → `retryFailedMessage` (anyone) | OP/Base: L2 deposit revert; Arbitrum: stuck retryable (≤7-day manual-redeem, then lost); Linea: re-claim |
| Time to deliver | ~20 min (CCIP SLA) | OP/Base ~1–3 min; Arbitrum ~1–15 min; Linea ~5–30 min |
| Affected by L1 EIPs (7904/8038)? | **Yes** — `gasLimit` budgets L1 work | No — budgets L2 work |

**Why not CCIP both ways?** Native L1→L2 bridges are cheaper (sequencer-subsidized or postman-free), faster (minutes vs ~20 min), and run on the L2's own trust — no extra committee dependency. CCIP earns its place on the *harder* L2→L1 direction, where it provides a programmable receiver that orchestrates the stake + bridge-back and carries the encoded `FeeDtoO`.

## Failure modes and recovery

| Leg | Failure | Cause | Recovery |
|-----|---------|-------|----------|
| CCIP (OtoD) | `CCIPSenderExceedsMaxFee` revert | `maxFee` too low vs actual CCIP fee | Increase `maxFee`, retry |
| CCIP (OtoD) | `ccipReceive` out of gas | `gasLimit` too low for stake + bridge | [Manual re-execution](https://docs.chain.link/ccip/concepts/manual-execution) with higher gas |
| Arbitrum (DtoO) | L1 tx reverts | `maxSubmissionCost` too low | Increase and retry |
| Arbitrum (DtoO) | Auto-redeem fails | `maxGas` or `gasPriceBid` too low | Manual redeem within ~7 days via [Arbitrum retryable dashboard](https://retryable-dashboard.arbitrum.io/) |
| Optimism/Base (DtoO) | L2 deposit execution fails | `l2Gas` too low | Failed relay is recorded in the L2 messenger's `failedMessages` and is **permissionlessly replayable** with more gas via `relayMessage` ([OP messengers spec](https://specs.optimism.io/protocol/messengers.html)). Replay is manual ops — still size conservatively with 20%+ buffer. |
| Linea (DtoO) | Postman won't deliver | Message uses >250k gas without fee | Manual claim or provide fee |

## References

- [CCIP gasLimit optimization](https://docs.chain.link/ccip/tutorials/evm/ccipreceive-gaslimit)
- [CCIP billing](https://docs.chain.link/ccip/billing) — incl. *"any unspent gas from this user-set limit is not refunded"*
- [CCIP manual execution](https://docs.chain.link/ccip/concepts/manual-execution)
- [CCIP FeeQuoter source](https://github.com/smartcontractkit/ccip/blob/ccip-develop/contracts/src/v0.8/ccip/FeeQuoter.sol) — `maxPerMsgGasLimit` validation / `MessageGasLimitTooHigh`
- [Arbitrum L1→L2 messaging & retryables](https://docs.arbitrum.io/how-arbitrum-works/arbos/l1-l2-messaging) — submission fee formula, refund addresses, contract-refund aliasing
- [Optimism deposit flow](https://docs.optimism.io/stack/transactions/deposit-flow)
- [OP guaranteed gas market spec](https://specs.optimism.io/protocol/guaranteed-gas-market.html) — L1 gas burn for deposit gas, `MINIMUM_BASE_FEE = 1 gwei`
- [Linea message service](https://docs.linea.build/network/build/send-receive-messages) — postman sponsorship < 250k gas
