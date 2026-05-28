# Deploy parameters

Tunable parameters subject to review. Each entry: **constant / var name** · **value** · **why this value, what changes if you turn the dial**.

System contract addresses (WETH, wstETH, CCIP routers, governance executors, adapters, proxies, old pools/automations, etc.), chain ids, role hashes, and external selectors are NOT listed here — those are verification facts, checked elsewhere (state-mate, on-chain reads), not discussion items.

Compile-time constants live in `script/l1/L1MigrationConstants.sol` and `script/<net>/<Net>MigrationConstants.sol`. Off-chain CRE params are set when registering the workflow.

---

## Shared across all 4 L2 lanes — sync defaults

These five constants have identical values in every per-network `*MigrationConstants.sol` file (Optimism / Arbitrum / Base / Linea); the per-L2 sections below omit them. Each constants file still declares them locally — duplication is intentional (constants files are self-contained) — but the values must move in lockstep across all four lanes.

`L2_SYNC_DESTINATION_GAS_LIMIT` is also tunable but per-network: `1_000_000` on Optimism / Arbitrum / Base; `500_000` on Linea (leaner Message Service path). See the per-network sections.

### `L2_SYNC_DESTINATION_MAX_FEE = 0.125e18` (= 0.125 ETH)

CCIP fee cap on the L2→L1 message: SyncTrigger refuses to call `ccipSend` if the router quotes more than this for one sync.

- **+25% from prior 0.1e18** as Glamsterdam pre-hardening — covers worst-case CCIP fee spikes during L1 base-fee congestion plus the new EIP-7904/8038 cost regime that bumps `getFee` quotes proportionally to gas-limit cost.
- The amount is **transient**: SyncTrigger pulls native from its balance for `ccipSend`, and `TokenHelper.refundExcessNative` returns any leftover to the contract. So raising the cap has zero per-sync cost when actual fee is below it.
- **If too low**: sync reverts when actual CCIP fee exceeds the cap → WETH backlog accumulates on the L2 OraclePool → next attempt occurs after `L2_SYNC_DELAY` elapses again. Recoverable but observable as a stalled-sync alert.
- **If too high**: no real downside aside from a larger transient native commitment per send. Treated as a sanity ceiling, not an economic dial.
- **Audit signal**: state-mate pins the encoded `getFeeOtoD` blob (21 bytes), so any change must update the per-network yamls in lockstep.

### `L2_SYNC_DESTINATION_PAY_IN_LINK = false`

CCIP supports paying fees in either LINK or native (wrapped) token; we pay in **native ETH**.

- Avoids running a LINK-balance top-up loop on every L2 SyncTrigger. The sync flow already moves WETH, so the contract has access to native ETH; no LINK liquidity to monitor or refill.
- LINK pricing inside CCIP is sometimes marginally cheaper than native, but ops cost (4 separate LINK balances to monitor & refill) outweighs the saving.
- **If flipped to `true`**: every SyncTrigger needs a sustained LINK balance + a refill mechanism + a monitoring alert. Not worth re-introducing for the marginal fee delta.

### `L2_SYNC_MIN_AMOUNT = 5e18` (= 5 WETH)

Floor amount on the OraclePool below which `shouldSync()` returns false; the CRE workflow does not emit a report.

- At a typical ETH price, 5 WETH per sync makes CCIP round-trip fees a sub-percent fraction of the synced amount.
- **If too low**: cross-chain fees become a meaningful drag on yield. A 5% fee fraction on a 0.5 WETH sync is real money.
- **If too high**: deposits accumulate longer in OraclePool before staking → user funds sit idle, missing Lido yield. Tail risk: large balance parked on L2 during an L2 incident.
- 5 WETH is the post-migration value; the pre-migration floor was lower. Worth re-evaluating per-lane if traffic patterns turn out very asymmetric (Linea typically sees less flow than Optimism).

### `L2_SYNC_MAX_AMOUNT = 100e18` (= 100 WETH)

Cap on the WETH amount per single sync. SyncTrigger clamps the actual sync amount to this if the pool balance is higher; the residual remains on L2 for the next sync.

- **Bounds CCIP fee exposure**: if the router or fee oracle is mispriced or hostile, no single message can drain more than 100 WETH worth of misquoted fee.
- **Bounds Lido `submit` impact**: 100 ETH is well inside Lido's daily staking limit; no risk of `submit` reverting due to limit exhaustion, no measurable Curve/Balancer pool impact on stETH liquidity.
- **Bounds L1→L2 bridge exposure**: if any L1→L2 path (OP standard bridge, Arbitrum retryable, Linea Message Service) has a transient incident, only ≤100 wstETH per send is in flight at a time.
- **If too low**: many small syncs, each paying CCIP overhead → cost-inefficient under heavy traffic. Pool drains slowly during deposit bursts.
- **If too high**: single-message risk grows; under bursty deposits the OraclePool would still drain fully across a few syncs, just less granularly.

### `L2_SYNC_DELAY = 12 hours`

Minimum wall-clock time between two successful syncs on a given lane.

- **Trades freshness vs cost**: more frequent sync = more CCIP messages + more L1→L2 bridge dispatches = more native fees per day.
- 12 h was chosen as a balance — at most 2 paid syncs/day per lane (≤8 syncs/day across 4 lanes) and L2 deposits stay un-staked for at most 12 h.
- Approximately aligns with Lido's daily oracle reporting cadence, minimizing "almost missed today's rewards" cases without forcing same-block staking.
- **Shorter (e.g. 1 h)**: better UX (less idle capital) but ~12× more sync events → ~12× more CCIP+bridge fees per lane; aggregate yield drag goes up.
- **Longer (e.g. 24 h)**: cheaper but increases tail risk of OraclePool holding large balances during an L2 incident; users wait longer for staking yield to start accruing.

---

## Optimism — `script/optimism/OptimismMigrationConstants.sol`

### `L2_SYNC_DESTINATION_GAS_LIMIT = 1_000_000` (= `0xf4240`)

L1-side gas budget passed inside the CCIP message; CCIP Router enforces it as the cap on `LidoCustomReceiver.ccipReceive` execution.

- Covers the full L1 work: CCIP message decode → unwrap WETH → `Lido.submit` → wstETH wrap → `delegatecall` to `OptimismLegacyAdapterL1toL2` → `L1StandardBridge.depositERC20To` → outbox event.
- **+25% from prior 800k** to absorb Glamsterdam EIP-7904 (cold-account access bump) and EIP-8038 (keccak repricing) effects on `processMessage`'s storage-heavy hot path. The 800k figure had ~10% headroom over measured cost; without the bump, a tail-percentile run could OOG and stall a sync mid-flight.
- **If too low**: receiver OOG → CCIP marks the message failed; manual re-execute via the CCIP UI is possible but is an ops step. Worse, partial state changes (e.g. `submit` succeeded but bridge call OOG'd) can leave wstETH parked on the receiver awaiting a sweep.
- **If too high**: gas budget × destination gas price is folded into the L2→L1 CCIP fee quote, so excess directly inflates `feeOtoD`. CCIP doesn't refund unused gas-budget portion of the fee.
- Same value across OP-stack (Optimism / Base) and Arbitrum since the L1 work is comparable; Linea diverges because its dispatch path is leaner.

### `L2_SYNC_ORIGIN_L2_GAS = 100_000` (= `0x186a0`)

L2 gas budget passed to the OP-stack `L1StandardBridge.depositERC20To`. Funds the L2-side `finalizeBridgeERC20` call that mints/credits the wstETH on Optimism.

- **Sequencer-paid**: deposit transactions on OP-stack are system transactions where this gas is allotted as part of normal block production, not billed back to the L1 sender.
- 100k is the standard `depositERC20To` value used across OP-stack integrations; covers a single ERC20 mint + transfer + event comfortably.
- Not affected by Glamsterdam (those EIPs hit L1 only).

---

## Arbitrum — `script/arbitrum/ArbitrumMigrationConstants.sol`

### `L2_SYNC_DESTINATION_GAS_LIMIT = 1_000_000`

Same magnitude as Optimism — the L1 work is comparable. Arbitrum's L1 adapter calls `L1GatewayRouter.outboundTransfer`, which creates a retryable ticket (extra Inbox state writes) instead of an OP-stack deposit, but the cost differential vs `depositERC20To` is well within the 25% Glamsterdam buffer.

### `L2_SYNC_ORIGIN_MAX_SUBMISSION_COST = 0.001e18` (= 0.001 ETH)

Arbitrum-retryable-specific. Paid as part of L1 `msg.value` to Inbox. Covers Inbox storage of the retryable ticket calldata for the ticket's lifetime (~7 days).

- 0.001 ETH is generous vs current L1 calldata pricing for this message size; sized to absorb base-fee spikes without retuning per release.
- Excess refunded on L2 to `excessFeeRefundAddress` (the LidoCustomReceiver on L1's view of itself, mapped via aliasing).
- **If too low**: Inbox rejects ticket creation → entire L1 sync reverts → CCIP retry is needed to make progress.
- **If too high**: no economic loss (refunded) — just a transient L1 native commitment.

### `L2_SYNC_ORIGIN_MAX_GAS = 100_000` (= `0x186a0`)

Maximum L2 gas the retryable can consume on auto-redeem. Funds the wstETH credit on Arbitrum.

- 100k is sufficient for a standard ERC20 mint/transfer.
- Refunded if unused, even on partial use.

### `L2_SYNC_ORIGIN_GAS_PRICE_BID = 50_000_000` (= 0.05 gwei)

Bid for L2 gas price when scheduling the retryable. Currently set **below** Arbitrum's typical L2 base fee, so **autoredeem fails** and a **manual redeem** is required within the ~7-day retryable lifetime.

- This is intentional: keeping the bid low minimizes upfront L1 `msg.value` (`maxSubmissionCost + maxGas × gasPriceBid`).
- Manual redeem is a routine ops step (~1¢ of L2 gas to call `redeem` on the retryable) — see `docs/runbook.md`.
- **If raised to ~0.2 gwei**: autoredeem succeeds, eliminating the ops step, but `msg.value` grows by `maxGas × bid_delta` ≈ 100k × 0.15 gwei = 1.5 × 10⁻⁵ ETH per sync — negligible. Worth switching if manual-redeem misses become a recurrent ops issue.
- **Reviewer note**: this is the most operationally-visible Arbitrum-specific parameter; the manual-redeem step must be explicit in the runbook and on-call rotation.

---

## Base — `script/base/BaseMigrationConstants.sol`

### `L2_SYNC_DESTINATION_GAS_LIMIT = 1_000_000`

Identical reasoning to Optimism — Base shares OP-stack L1 dispatch path (`L1StandardBridge.depositERC20To`).

### `L2_SYNC_ORIGIN_L2_GAS = 100_000`

Identical reasoning to Optimism — sequencer-paid L2 finalization gas; standard OP-stack value.

---

## Linea — `script/linea/LineaMigrationConstants.sol`

### `L2_SYNC_DESTINATION_GAS_LIMIT = 500_000` (= `0x7a120`)

**Half** of OP/Arb/Base.

- Linea's L1 path uses `LineaMessageService.sendMessage` — a single message-dispatch call, much leaner than `L1StandardBridge.depositERC20To` (OP-stack) or `L1GatewayRouter.outboundTransfer` (Arbitrum, retryable creation).
- Lower gas budget → lower `feeOtoD` for the Linea sync vs the others; state-mate pins the encoded blob explicitly so the difference is reviewable.
- **+25% from prior 400k** for Glamsterdam, same percentage bump as OP-stack — the EIP cost shift applies to the receiver path on L1 regardless of the dispatch primitive used afterwards.

---

## CRE workflow params (off-chain, registered on Ethereum mainnet `WorkflowRegistry`)

### Cron schedule = `*/5 * * * *` (every 5 minutes)

How often the Chainlink CRE DON evaluates `SyncTrigger.shouldSync()` and emits a CCIP report when it returns true.

- DON only emits a report when `shouldSync()` returns true (delay elapsed AND amount within `[min, max]`), so the cron is **evaluation cadence**, not action cadence. Most ticks return false (cheap `staticcall`).
- 5 min is **1/144** of `L2_SYNC_DELAY` (12 h) — once the delay expires, max 5 min latency before the next evaluation triggers a report. Negligible vs the 12 h base period.
- DON evaluation is billed in CRE Subscription credits (paid in mainnet ETH). Net cost: `144 evaluations/day × 4 lanes × per-evaluation cost`. Even though most ticks return false, the volume is non-trivial — re-evaluate cadence if CRE costs spike.
- **Tighter (e.g. `*/1 * * * *`)**: shorter post-delay sync latency but ~5× DON evaluation cost. Not worth it given the 12 h base period dominates latency.
- **Looser (e.g. `*/15 * * * *`)**: cuts DON cost ~3× with up to 15 min added post-delay latency — defensible if CRE costs need trimming.
