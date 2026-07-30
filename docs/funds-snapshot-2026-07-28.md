# Funds snapshot — Deployer, SyncTriggers, new OraclePools (2026-07-28)

> **View — treasury/readiness snapshot, 2026-07-28.** Stakeholder: whoever funds the migration
> (the Lido Deployer's operator) and whoever must make a live sync succeed (the LOL multisig,
> `0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6`). Concern: *how much value sits on the Deployer
> EOA, on each `SyncTrigger` fee float, and in each new `OraclePool`, right now.* **Bottom line:
> the Deployer holds ~0.856 ETH total plus dust; every `SyncTrigger` fee float is 0 ETH and every
> new `OraclePool` is empty on all four lanes — so no lane can currently sync or serve a stake.**
> Point-in-time and block-pinned: reproduce with `just balances` (which now covers the Deployer
> and the SyncTriggers as well as the pools).

## 1. Block pins (the carrier of every number below)

| Chain | Block |
| --- | --- |
| Ethereum (L1) | 25632296 |
| Optimism | 154827356 |
| Arbitrum | 488647972 |
| Base | 49232078 |
| Linea | 31547706 |

Reads are `cast balance` (native ETH) and `ERC20.balanceOf` against the `l2Weth` / `l2Wsteth`
effective externals in `config/state/l2.common.inputs.yaml` plus `config/state/<net>.inputs.yaml`.
stETH is not bridged to L2 — only wstETH exists there.

## 2. Lido Deployer EOA — `0xBeedf0c72D63eE8f8784eDB4A9326Fb43b69D50c`

Same address on L1 and all four L2s (`l2LidoDeployer` anchor).

| Chain | ETH | WETH | wstETH |
| --- | --- | --- | --- |
| Ethereum (L1) | 0.057864041845938460 | 0 | 0 |
| Optimism | 0.248895688603316698 | 0.000001230000000000 | 0.040321732721620264 |
| Arbitrum | 0.076869750627351432 | 0.050002460000000000 | 0.080643465443240529 |
| Base | 0.225846233990247100 | 0.000001230000000000 | 0.040321732721620264 |
| Linea | 0.246979598350241755 | 0.000890000000000000 | 0.040321732721620264 |
| **Total** | **0.856455313417095445** | **0.050894920000000000** | **0.201608663608101321** |

- The WETH/wstETH holdings are leftover canary/smoke-test dust, not working capital. The
  ~0.0403 wstETH repeated verbatim on Optimism/Base/Linea (and 2× that on Arbitrum) is the
  signature of identical dust-sized test stakes, not a coincidence to investigate.
- L1 ETH (0.0579) is thin for an L1 migration transaction; L2 gas budgets (~0.08–0.25 ETH/lane)
  are comfortable.

## 3. SyncTrigger fee float — `0x1594705D5f9BbDb36453ACF15C94d041c0E02c62` (same address, all 4 lanes)

| Chain    | ETH (the float) | WETH | wstETH | `getMaxFees()` = cost of ONE sync | Syncs affordable |
| -------- | --------------- | ---- | ------ | --------------------------------- | ---------------- |
| Optimism | **0**           | 0    | 0      | 0.125000000000000000              | 0                |
| Arbitrum | **0**           | 0    | 0      | 0.126005000000000000              | 0                |
| Base     | **0**           | 0    | 0      | 0.125000000000000000              | 0                |
| Linea    | **0**           | 0    | 0      | 0.125000000000000000              | 0                |

- The trigger **fronts CCIP fees from its own native balance** and floors the required amount at
  `getMaxFees()`, so 0 ETH means **`sync()` cannot succeed on any lane today**. This is the one
  actionable item in this snapshot.
- Target float is `L2_SYNC_TRIGGER_INITIAL_FLOAT = 0.5e18` per lane (per-network migration
  constants) → **2.0 ETH total** to bring all four lanes to spec, 0.504 ETH for a bare
  one-sync-per-lane minimum. Fund via `just -E .env.<network> fund-trigger`.
- Zero WETH/wstETH is the *expected* reading: the trigger never custodies tokens, so a non-zero
  value there would be stranded dust rather than float.

## 4. New OraclePool — `0xac143bF41BBA4a8014b4Ef5a5F46b39a36AE40A8` (same address, all 4 lanes)

| Chain | ETH | WETH | wstETH |
| --- | --- | --- | --- |
| Optimism | 0 | 0 | 0 |
| Arbitrum | 0 | 0 | 0 |
| Base | 0 | 0 | 0 |
| Linea | 0 | 0 | 0 |

Empty on every lane: no wstETH reserve to serve `fastStake`, and no WETH awaiting a sync. The
liquidity handoff from the old oracle pools has not happened.

For contrast, the **old** oracle pools still hold the entire position (same block pins):

| Chain | Old pool | WETH | wstETH |
| --- | --- | --- | --- |
| Optimism | `0x6F357d53d6bE3238180316BA5F8f11467e164588` | 0 | 31.478780143467029130 |
| Arbitrum | `0x9c27c304cFdf0D9177002ff186A4aE0A5489Aace` | 14.889843424935608464 | 19.354138736593175920 |
| Base | `0x6F357d53d6bE3238180316BA5F8f11467e164588` | 6.069112707680013708 | 26.409810718243117661 |
| Linea | `0x6F357d53d6bE3238180316BA5F8f11467e164588` | 0.074628041250134873 | 19.741789141351622752 |

L1 `LidoCustomReceiver` (`0x6F357d53d6bE3238180316BA5F8f11467e164588`) holds 0 ETH,
0.001254699339001600 WETH, 0 wstETH — residual, consistent with a receiver that forwards rather
than custodies.

## 5. Why these zeros are facts, not a failed read

Fourteen consecutive zeros across four chains is the shape a *contaminated oracle* produces (wrong
address, no bytecode, wrong token, dead RPC) — the same false-pass class as the earlier wrong
gov-executor address. Evidence that the reads are sound, gathered before recording them:

1. **Bytecode present** at both addresses on all four chains — `SyncTrigger` 23819 hex chars,
   `OraclePool` 11957, byte-identical per contract across lanes (deterministic deploys, the
   expected reason one address string is valid on four chains).
2. **`owner()` resolves to the LOL multisig** `0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6` on all
   eight contracts — so these are the real, already-handed-off production instances, not
   look-alikes or stale canary addresses.
3. **Positive control on the same code path**: the *old* pool balances (§4) read non-zero via the
   identical RPC + token address + `balanceOf` path on every lane. A dead RPC or wrong token
   address could not produce those numbers.

What is *not* established here: whether each `SyncTrigger` was ever funded and has since spent its
float, or was never funded at all. Both produce a 0 balance; distinguishing them needs transfer
history, which this snapshot does not read. It does not change the action (fund it).

## 6. Actions implied

1. **Fund the four `SyncTrigger` floats** — 0.5 ETH each, 2.0 ETH total, via
   `just -E .env.<network> fund-trigger`. Until then no lane can sync.
2. **Seed the new `OraclePool` wstETH reserves** (liquidity handoff from the old pools) before any
   lane is expected to serve `fastStake`.
3. **Top up the Deployer on L1** if an L1 migration transaction is still pending — 0.0579 ETH is
   thin.
