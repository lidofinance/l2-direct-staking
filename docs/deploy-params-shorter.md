## Deploy parameters

Tunable constants subject to review. System addresses, chain IDs, role hashes, and external selectors are verification facts (state-mate / on-chain reads), not in this list.

Compile-time constants live in `script/l1/L1MigrationConstants.sol` and `script/<net>/<Net>MigrationConstants.sol`. Off-chain CRE params are set when registering the workflow.

---

### Shared L2 sync defaults

Identical across all 4 L2s; each network file redeclares them locally — keep in lockstep. `L2_SYNC_DESTINATION_GAS_LIMIT` is also tunable but per-network (see below).

| Constant                          | Value                  | What and why                                                                                                                                                                                                                                                                                                                                             |
| --------------------------------- | ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `L2_SYNC_DESTINATION_MAX_FEE`     | `0.125e18` (0.125 ETH) | CCIP fee cap on L2→L1 sync. +25% from prior `0.1e18` for Glamsterdam (EIP-7904/8038). State-mate pins the encoded `getFeeOtoD` blob (21 bytes) — changes must update per-network yamls in lockstep. **Too low:** sync reverts → WETH backlog on OraclePool → retry after next delay. **Too high:** larger transient native commitment; no economic cost. |
| `L2_SYNC_DESTINATION_PAY_IN_LINK` | `false`                | Pay CCIP fees in native ETH; sync already moves WETH so contract has access. No LINK liquidity to monitor. **If flipped to `true`:** 4 LINK balances to monitor + refill.                                                                                                                                                                                |
| `L2_SYNC_MIN_AMOUNT`              | `5e18` (5 WETH)        | Floor for `shouldSync()`; keeps CCIP round-trip fees sub-percent of synced amount. **Too low:** cross-chain fees become meaningful yield drag. **Too high:** deposits idle longer on L2; tail risk during incidents.                                                                                                                                     |
| `L2_SYNC_MAX_AMOUNT`              | `100e18` (100 WETH)    | Per-sync cap. Bounds CCIP fee exposure, Lido `submit` impact (well inside daily limit), and L1→L2 bridge in-flight risk. **Too low:** many small syncs → CCIP overhead dominates; slow drain in bursts. **Too high:** single-message risk grows.                                                                                                         |
| `L2_SYNC_DELAY`                   | `12 hours`             | Min wall-clock between syncs (≤2 paid syncs/day/lane). Aligns with Lido's daily oracle reporting cadence. **Too low (1h):** ~12× sync events → ~12× CCIP+bridge fees. **Too high (24h):** larger pool balances during incidents; yield lag.                                                                                                              |

---

### Per-network constants

| Network  | Constant                              | Value                  | What and why                                                                                                                                                                                                                 |
| -------- | ------------------------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Optimism | `L2_SYNC_DESTINATION_GAS_LIMIT`       | `1_000_000` (`0xf4240`) | L1 gas for `ccipReceive`: decode → unwrap WETH → `Lido.submit` → wstETH wrap → `delegatecall` to OP-stack adapter → `L1StandardBridge.depositERC20To`. +25% from 800k for Glamsterdam (EIP-7904/8038). OOG ⇒ CCIP failed-message + manual re-exec, partial-state risk. Too high ⇒ inflates `feeOtoD`. |
| Optimism | `L2_SYNC_ORIGIN_L2_GAS`               | `100_000` (`0x186a0`)   | L2 gas for OP-stack `finalizeBridgeERC20` (ERC20 mint + transfer). Sequencer-paid system tx; standard OP-stack value. Glamsterdam doesn't apply (L1-only).                                                                   |
| Arbitrum | `L2_SYNC_DESTINATION_GAS_LIMIT`       | `1_000_000`             | Same magnitude as OP — Arb's `L1GatewayRouter.outboundTransfer` (retryable creation) cost is within the 25% Glamsterdam buffer.                                                                                              |
| Arbitrum | `L2_SYNC_ORIGIN_MAX_SUBMISSION_COST`  | `0.001e18` (0.001 ETH)  | Inbox storage for retryable ticket (~7-day lifetime). Generous vs current L1 calldata pricing; excess refunded on L2 to `excessFeeRefundAddress` (aliased receiver). Too low ⇒ ticket rejected ⇒ entire sync reverts.        |
| Arbitrum | `L2_SYNC_ORIGIN_MAX_GAS`              | `100_000` (`0x186a0`)   | Max L2 gas on auto-redeem; covers ERC20 mint/transfer. Refunded if unused.                                                                                                                                                   |
| Arbitrum | `L2_SYNC_ORIGIN_GAS_PRICE_BID`        | `50_000_000` (0.05 gwei)| **Below typical L2 base fee → autoredeem fails → manual redeem required (~7-day window).** Intentional: minimizes upfront L1 `msg.value` = `maxSubmissionCost + maxGas × bid`. Raising to ~0.2 gwei autoredeems for ~1.5×10⁻⁵ ETH/sync extra. See `docs/runbook.md`; explicit on-call rotation step. |
| Base     | `L2_SYNC_DESTINATION_GAS_LIMIT`       | `1_000_000`             | OP-stack — identical reasoning to Optimism.                                                                                                                                                                                  |
| Base     | `L2_SYNC_ORIGIN_L2_GAS`               | `100_000`               | OP-stack — identical reasoning to Optimism.                                                                                                                                                                                  |
| Linea    | `L2_SYNC_DESTINATION_GAS_LIMIT`       | `500_000` (`0x7a120`)   | **Half of OP/Arb/Base.** `LineaMessageService.sendMessage` is leaner than OP-stack `depositERC20To` or Arb retryable creation, so `feeOtoD` is correspondingly lower. +25% from 400k for Glamsterdam (receiver-side EIP costs apply regardless of dispatch). |

---

### CRE workflow params (off-chain; registered on Ethereum mainnet `WorkflowRegistry`)

| Param         | Value                       | What and why                                                                                                                                                                                                                                                                                 |
| ------------- | --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cron schedule | `*/5 * * * *` (every 5 min) | DON **evaluation** cadence (not action — most ticks return false on cheap `staticcall`). `1/144` of `L2_SYNC_DELAY` ⇒ ≤5 min post-delay latency. Tighter (`*/1`): ~5× DON cost. Looser (`*/15`): ~3× cheaper, up to 15 min added latency. Billed in CRE Subscription credits (mainnet ETH): `144 evals/day × 4 lanes × per-eval cost`. |
