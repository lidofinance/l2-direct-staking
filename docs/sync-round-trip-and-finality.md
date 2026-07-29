# The sync round trip and why lane latency differs (Linea vs OP Stack)

**Status:** measured 2026-07-23, from the mainnet canary syncs on Base, Optimism and
Linea. All three round trips completed. All times UTC. Claims are labelled
`CONFIRMED` (read from chain), `INFERRED` (mechanism fit, not directly read), or
`OPEN` — see [§8](#8-evidence-posture).

> **TL;DR.** All three lanes completed: Base 24m56s, Optimism 21m18s, **Linea
> 1h20m48s**. Linea is ~3.5× slower, and *both* of its legs are slower — the CCIP
> leg out (63 min vs 20–24 min) and the native return leg back (18 min vs ~1 min).
>
> **An earlier draft of this document claimed Linea's latency was caused by waiting
> for Linea's L1 validity-proof finalization. That was wrong and is retracted
> ([§6.1](#61-retracted-the-proof-finality-explanation-is-falsified)).** The message
> was delivered to L1 while its source block was — and still is — unfinalized. What
> actually sets the 63 min remains `OPEN`.

---

## 1. What the sync does

One repeatable operation: **rebalance an L2 pool by converting accumulated WETH
into bridged wstETH** (`DOC.md` §5). It crosses two bridges — CCIP out (L2→L1),
the canonical native bridge back (L1→L2).

## 2. Actors and roles

Modelled as `Holder#Role:Context` (FPF `A.2.1`). The role never acts by itself;
work is attributed to a holder under a role assignment (`A.15`, CC-A15-3).

| Holder | Role | Context | Owns latency? |
|---|---|---|---|
| CRE workflow (WASM, 5-min poll) | `SyncObserver` — observes and *proposes* | off-chain | no |
| CRE Forwarder | `ReportCarrier` | off-chain → L2 | no |
| `CREReceiver` `0x29113eD7…` | `Admission` (forwarder + author + allow-list) | L2 | no |
| `SyncTrigger` `0x1594705D…` | **`SYNC_ROLE` — the accountable caller** | L2 | no |
| `CustomSender` `0x328de900…` | `MessageOriginator` | L2 | no |
| Chainlink CCIP DON | `Transport` | lane | **yes — stage 3** |
| `LidoCustomReceiver` `0x6F357d53…` | `Staker` | L1 | no |
| L1 adapter + canonical bridge | `ReturnCarrier` | L1 → L2 | **yes — stages 5–7 on Linea** |

Both latency-owning holders sit **outside** this project's role taxonomy — no role
held here can advance a message once `sync()` has fired.

## 3. Statuses — due vs admissible

`SyncTrigger` splits two different predicates, which is what prevents a
due-but-blocked stall:

| Predicate | Question | Inputs |
|---|---|---|
| `shouldSyncAmount()` (`src/SyncTrigger.sol:198`) | is the work **due**? | pool WETH ≥ `minAmount`, `delay` elapsed |
| `canSync()` (`src/SyncTrigger.sol:243`) | is the trigger in a state that **admits** the work? | fee float ≥ `getMaxFees()`, `SYNC_ROLE` held, pool not paused |

Role-state set for `SyncTrigger#SYNC_ROLE:L2` (FPF `A.2.5` — only `Ready` admits work):

```
Unfunded → Funded → Ready (due ∧ admissible) → Cooling (delay window)
                      ↘ Blocked (paused / role revoked / float drained)
```

## 4. Stages

Stages 3–7 are phases of **one** occurrence (FPF `A.14` `PhaseOf`), not steps this
project executes:

| # | Stage | Advanced by | Observable predicate |
|---|---|---|---|
| 1 | Due + admissible | `shouldSync ∧ canSync` | both true on-chain |
| 2 | Report admitted → `sync()` | `CREReceiver.onReport` (`0x805f2132`) | `Sync(user, selector, messageId, amount)` emitted |
| 3 | **CCIP transport L2→L1** | CCIP DON | log carrying `messageId` at `LidoCustomReceiver` |
| 4 | Delivery + stake WETH→wstETH | `LidoCustomReceiver` | same tx as stage 3 |
| 5 | Return leg → canonical bridge | adapter `delegatecall` | bridge send (same tx) |
| 6 | **Bridge transport L1→L2** | native bridge / message service | — |
| 7 | Mint into L2 pool | native bridge | wstETH `Transfer` from `0x0` → pool |

## 5. The measurement — a controlled three-lane comparison

The three canary syncs form a natural experiment: **same code, same method, same
amount, same signer, all within 7 minutes.** Differences are attributable to the lane.

Constants across all three: deployer `0xBeed…D50c`; new pool
`0xac143bF41BBA4a8014b4Ef5a5F46b39a36AE40A8`; seed 0.0005 WETH; return
40321732721620264 wei (≈0.0403 wstETH) — identical on all three.

| | Base | Optimism | Linea |
|---|---|---|---|
| stage-2 `onReport` tx | `0xd3ea9c4111a37ab82a96ce80a1b79935d99399ba7656783a43a6ac7d0cd8835c` | `0xba3d72770cfd1af39e33c33a28c15f119e21c00d0c59f41a61fba7fb8b9374f9` | `0xa2da411dba3bcdd8aababce7110bb39fba54003f0f2176d7d90ff579a4bb30c1` |
| L2 block | 49015691 | 154611177 | 31491466 |
| L2 time | 15:32:09 | 15:38:51 | 15:34:24 |
| CCIP `messageId` | `0xc22a12e6172a0cd365ef6614578a6f0e5b6d8db26d29ac5e76d356d2f476c210` | `0xf643f2da75c142172947240af331d1d6db50b5ed981ee9a89720435ec3a3bb00` | `0xca62c2d0e2b5cb9efe8953a8ec4d5f38f5a3ff8954c6143e21e50a338b658818` |
| stage-3/4 L1 delivery tx | `0xc0edf8d4f45667645a142e731da98ab75ba573203be91555159d275e4160b02f` | `0xeee4ae61ad69df5b0a81c935ba23afd6fc9b02b3b129152c1378a92bf527892a` | `0x35fffe90b83daf2f89d29b861085bcb49bebc41322e02a7443e1a2dc6edd707f` |
| L1 time | 15:56:11 | 15:58:59 | 16:37:23 |
| stage-7 pool mint tx | `0xf252ab46b9190fb00c2b3b3699dc6f31570a7b613ebefb15709a30c5667e527e` | `0xdb411bff633ed6e65c54b1a6233c86c38e466888f31c9cdc21a6e6f2385caf24` | `0xc87d2098a56fad3517050a8c43dcaec98f8fca2877b2d24add7d88695a09d992` |
| L2 time | 15:57:05 | 16:00:09 | 16:55:12 |
| **leg out (L2→L1)** | **24m 02s** | **20m 08s** | **62m 59s** |
| **leg back (L1→L2)** | **54 s** | **70 s** | **17m 49s** |
| **total** | **24m 56s** | **21m 18s** | **1h 20m 48s** |

Every row is read from chain. The Linea delivery is confirmed as ours by
`messageId` `0xca62c2d0…8818` appearing in the L1 delivery tx, and by the Linea
chain-selector `4627098889531055414` in its logs.

**Both** Linea legs are slower, in different proportions: the leg out by ~2.6–3×,
the leg back by ~15–20×. The leg out is the larger absolute term (63 of 81 minutes).

## 6. Why Linea is slower

### 6.1 Retracted: the proof-finality explanation is falsified

An earlier draft argued that CCIP could not move the message until Linea submitted
a validity proof to L1 covering block 31491466, and it recorded this falsifiable
prediction:

> *The L1 delivery of messageId `0xca62c2d0…8818` will occur shortly after the
> first `DataFinalizedV3` whose `endBlockNumber ≥ 31491466`, and not before.*

**The prediction failed.** `CONFIRMED`:

| Fact | Value |
|---|---|
| L1 delivery of `0xca62c2d0…8818` | 16:37:23 (L1 block 25596667) |
| Linea finalized head at that moment | **31489783** |
| Linea finalized head at time of writing | **31491112** |
| Source block needing finalization | **31491466** |

The message was delivered to L1 — staked, bridged and minted into the pool — while
its source block was unfinalized, **and that block remains unfinalized now**. CCIP
therefore does **not** gate this lane on `LineaRollup.currentL2BlockNumber()`.
The mechanism claimed in the earlier draft is wrong and is withdrawn.

This also reverses a second, earlier retraction: the Linea **return** leg *is*
materially slow (17m49s vs ~1 min), consistent with the Linea message-service
postman claim rather than the OP-Stack messenger. That factor is real; it is simply
not the dominant term.

### 6.2 What is actually established

`CONFIRMED`:

- Linea's leg out took 62m59s against 20m08s / 24m02s on OP-Stack lanes, under
  identical code, amount and timing.
- Linea's leg back took 17m49s against 54s / 70s.
- Neither leg waited on Linea's L1 proof finalization.

`OPEN` — **what sets the 63 minutes is not established.** Plausible candidates, none
verified here:

- a larger configured confirmation depth or soft-finality heuristic for the
  Linea→Ethereum lane in the DON's off-chain config;
- a per-lane commit batching or scheduling cadence on the DON side;
- Linea's slower block production (~6–9 blocks/min observed vs 30/min on OP-Stack)
  making any depth-based threshold take proportionally longer in wall-clock.

The third is arithmetically attractive — Linea produces blocks ~4× slower, and the
leg out was ~2.6–3× slower — but confirming it requires reading the DON's per-lane
finality configuration, which was not done. **Do not repeat the previous mistake of
promoting a plausible mechanism to an explanation without reading the config.**

### 6.3 Context: Linea does batch-finalize (but it did not cause this)

Retained because it is true, measured, and useful for reasoning about *withdrawal*
and proof-dependent flows — **not** about this sync's latency.

`LineaRollup` (`0xd19d4B5d358258f05D7B411E21A1460D11B0876F`) advances
`currentL2BlockNumber()` in discrete proof batches. Measured `DataFinalizedV3`
events, 2026-07-23:

| L1 time | finalized L2 range | batch size | gap since previous |
|---|---|---|---|
| 00:42:47 | 31482011..31483246 | 1236 | — |
| 03:26:35 | 31483247..31484577 | 1331 | 2h44m |
| 06:31:23 | 31484578..31485936 | 1359 | 3h05m |
| 09:18:11 | 31485937..31487286 | 1350 | 2h47m |
| 11:57:23 | 31487287..31488615 | 1329 | 2h39m |
| 15:37:47 | 31488616..31489783 | 1168 | 3h40m |
| 16:44:23 | 31489784..31491112 | 1329 | 1h07m |

Batch size 1168–1359 (mean ≈1300); interval 1h07m–3h40m (mean ≈2h40m). The
finalized head trails the live head by ~1000–2300 blocks continuously.

The sync completed end-to-end **without** this sequence ever reaching block
31491466 — which is precisely the evidence that falsified §6.1.

## 7. Operational implications

1. **A Linea round trip takes roughly 3–4× an OP-Stack one** — ~1h20m measured
   against ~21–25 min. Plan canary verification asynchronously, but this is *not*
   the multi-hour operation an earlier draft claimed.
2. **Do not use finalization lag as a health check for a pending sync.** A pending
   Linea sync is expected to complete while unfinalized;
   `currentL2BlockNumber() < syncBlock` is **not** evidence of a stall. The only
   reliable liveness signal is the `messageId` appearing at `LidoCustomReceiver`.
3. **Budget both legs on Linea.** Unlike OP-Stack, the return leg is not free —
   ~18 min, subject to the sponsored-postman path (`docs/fees.md:204`).
4. The `12 h` sync delay dwarfs even Linea's round trip, so lane latency does not
   threaten the delay gate or the cutover quiet-window logic (`DOC.md` §5, §6.4).

## 8. Evidence posture

| Claim | Status | Basis |
|---|---|---|
| All stage-2/3/7 txs, blocks, times, amounts, messageIds (§5) | `CONFIRMED` | read from chain |
| Linea delivery is our message | `CONFIRMED` | `messageId` + lane selector in the L1 tx |
| Linea leg out 62m59s, leg back 17m49s, total 1h20m48s | `CONFIRMED` | measured |
| Delivery occurred with source block unfinalized | `CONFIRMED` | delivery 16:37:23 vs finalized head 31489783 |
| **CCIP gates the Linea lane on L1 proof finality** | **`FALSIFIED`** | see §6.1 — retracted |
| Linea finalization cadence + batch sizes (§6.3) | `CONFIRMED` | 7 × `DataFinalizedV3` |
| **What sets Linea's 63-minute leg out** | **`OPEN`** | not established; candidates in §6.2 |
| OP/Base do not wait the 7-day challenge window | `INFERRED` | 20–24 min measured is far below it |

**Sampling limitation.** Historical lane samples are sparse: ~20 days of Linea
history contains **one** `Sync` event (ours); Base one; Optimism two. This is a
single round per lane. A second Linea round trip should be measured before treating
any of these durations as a distribution rather than a data point.

**Method note.** The falsification in §6.1 was caught only because the earlier draft
recorded a dated, checkable prediction. Keep doing that.

## 9. Reproduction

```bash
# Pool funded?
cast call --rpc-url "$RPC_LINEA_REMOTE" \
  0xB5beDd42000b71FddE22D3eE8a79Bd49A568fC8F 'balanceOf(address)(uint256)' \
  0xac143bF41BBA4a8014b4Ef5a5F46b39a36AE40A8

# Find a sync's CCIP messageId  (topic0 = Sync(address,uint64,bytes32,uint256))
cast logs --rpc-url "$RPC_<NET>_REMOTE" --from-block <N> --to-block latest \
  --address 0x328de900860816d29D1367F6903a24D8ed40C997 \
  0x2826f7440c9ba1050bcd2c586a60551875ac8951ec73f01df55ef00b59ae1a9c

# Did it reach L1?  (the liveness signal — scan the receiver, grep the messageId)
cast logs --rpc-url "$RPC_ETHEREUM_REMOTE" --from-block <N> --to-block latest \
  --address 0x6F357d53d6bE3238180316BA5F8f11467e164588

# Linea finalization batches (topic0 = DataFinalizedV3) — context only, NOT a
# health check for a pending sync (see §7.2)
cast logs --rpc-url "$RPC_ETHEREUM_REMOTE" --from-block <N> --to-block latest \
  --address 0xd19d4B5d358258f05D7B411E21A1460D11B0876F \
  0xa0262dc79e4ccb71ceac8574ae906311ae338aa4a2044fd4ec4b99fad5ab60cb

# Pool top-ups (wstETH Transfer → pool; a mint shows from = 0x0)
cast logs --rpc-url "$RPC_<NET>_REMOTE" --from-block <N> --to-block latest \
  --address <L2_WSTETH> \
  0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef \
  "" 0x000000000000000000000000ac143bf41bba4a8014b4ef5a5f46b39a36ae40a8
```

## 10. Next step

Resolve the `OPEN` item in §6.2 by reading the CCIP per-lane finality configuration
for Linea→Ethereum, and measure a second Linea round trip to test whether the
~63-minute leg out is stable or variable. Until then, no mechanism should be stated
as the cause.
