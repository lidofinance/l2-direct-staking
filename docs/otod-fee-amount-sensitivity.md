# Does the OtoD-leg fee depend on the bridged amount? — an FPF-structured finding

> **View — fee-tuning finding, 2026-06-17.** Stakeholder: the fee-tuning owner (the LOL
> multisig) and whoever sizes/limits a sync. Concern: *whether the per-sync CCIP fee scales
> with the bridged WETH amount, whether that could push the quote into the `maxFee` revert
> bound, and the `SyncTrigger` per-sync cap that keeps it from doing so.* **Bottom line: a
> real per-lane sensitivity (Optimism/Linea), fully contained today by the 100 WETH per-sync
> cap — a tuning coupling to respect, not a live risk.** Companion to [`docs/fees.md`](fees.md)
> (which holds the
> quantitative fee reference); this file records the **amount-sensitivity** result and the
> reasoning that produced it. Reproduce any number with `just quote-ccip-fee-by-amount`.
>
> **Structured with the First Principles Framework (FPF).** Governing patterns:
> **A.6.B** (Boundary Norm Square — every claim routed to exactly one of L / A / D / E) and
> **A.7** (Strict Distinction — Object ≠ Description ≠ Carrier; MethodDescription ≠ Method ≠
> Work). Neighbours cited: **A.6.P / C.2.P** (precision restoration), **A.10 / B.3**
> (evidence is referred to its carriers, not asserted), **A.15** (Role–Method–Work).

---

## 0. The question needed precision before it could be answered (A.6.P / C.2.P)

"Does the **OtoD fee** depend on the **amount**?" rests on two load-bearing words. Per the
precision-restoration discipline (A.6.P / C.2.P), restore them before reasoning:

- **"fee"** is overloaded — [`docs/fees.md`](fees.md) already splits it into four quantities
  (actual fee, `maxFee` bound, `gasLimit` commitment, FeeDtoO budget). Only **one**, the
  live `IRouterClient.getFee()` quote for the L2→Ethereum leg, is "the OtoD fee".
- That quote decomposes further (next section). The amount can only enter through **one of
  its three components**, so the whole question reduces to: *does the `premium` component
  move with the amount, and by how much, per lane?*

This is why the answer is **not** a single scalar — it is a set of per-lane results
(comparison stays set-valued; no hidden collapse to "the fee is X").

---

## 1. Laws & Definitions (A.6.B quadrant **L** — truth-conditional, adjudicated in-description)

> Adjudicated from the CCIP FeeQuoter semantics ([`docs/fees.md:39-68`](fees.md), vendored
> `FeeQuoter.sol:534-598`). No deontic keywords appear here (CC-A.6.B.3).

- **L-1 (fee composition).** The OtoD quote `fee ≈ (baseFee + premium + gasLimit ×
  destChainGasPrice) / feeTokenPrice`, in native-ETH wei.
- **L-2 (premium law — the only amount-bearing term).** `premium = clamp(deciBps ×
  USD-value-of-amount / 1e5, minFeeUSDCents, maxFeeUSDCents)`. Therefore `premium` is
  **piecewise** in the amount: flat at the floor below the lower knee, linear in the band,
  flat at the ceiling above the upper knee — or a flat `defaultTokenFeeUSDCents` when the
  token has no per-lane override.
- **L-3 (amount-invariant terms).** `baseFee` and `gasLimit × destChainGasPrice` price
  *destination computation and message bytes*, not value; the amount rides in `data` as a
  fixed-width `uint256`. They are constant w.r.t. the amount.
- **L-4 (OtoD is always a token transfer).** `CustomSender._ccipBuildAndSend`
  ([`CustomSender.sol:294`](../lib/chainlink-csr/contracts/senders/CustomSender.sol)) always
  populates `tokenAmounts` with the bridged WETH (`TOKEN = l2Weth`), so the quote always
  takes CCIP's `numberOfTokens > 0` branch (the `premium` law L-2), never the data-only
  `networkFeeUSDCents` path.
- **L-5 (per-sync amount is capped).** `SyncTrigger._getAmountToSync` clamps each sync to
  `amount = min(poolWETH, maxAmount)` with `maxAmount = 100 WETH` on all four lanes
  ([`SyncTrigger.sol:312-313`](../src/SyncTrigger.sol); owner-set via `setAmounts`,
  `onlyOwner`). So the amount entering the premium law L-2 is **≤ 100 WETH per sync** by
  construction — the protocol-level bound on the CCIP-level (un)cap.

**Consequence (definitional).** "Does the fee depend on the amount?" ≡ "is `deciBps > 0` and
is the amount's USD value inside `[minFeeUSDCents/deciBps, maxFeeUSDCents/deciBps]`?" — a
per-lane, on-chain fact (quadrant E) — *bounded by L-5 to amounts ≤ 100 WETH.*

---

## 2. Admissibility & Gates (A.6.B quadrant **A** — runtime predicate, in-work)

> Predicate form, no deontic keywords (CC-A.6.B.3); references L only, never D (CC-A.6.B.7).

- **A-1 (`maxFee` gate).** A sync is admissible **iff** `getFee(message) ≤ maxFee`
  (`= 0.125 ETH` on every lane); otherwise `CustomSender.sync` reverts
  `CCIPSenderExceedsMaxFee` ([`CCIPSenderUpgradeable.sol:82`](../lib/chainlink-csr/contracts/ccip/CCIPSenderUpgradeable.sol)).
  Combined with L-2/L-3, this gate is breachable by the amount only when `premium` is not
  effectively capped below `maxFee` — and per **L-5** the largest amount that can reach it is
  **100 WETH**, at which the Optimism/Linea quote sits at ~40% of `maxFee` (E-1, E-4). So the
  gate is **not** amount-breachable at the current `(maxAmount, maxFee)` setting.

---

## 3. Work-Effects & Evidence (A.6.B quadrant **E** — measured, in-work; A.10 / B.3)

> Each E-claim names its **observation conditions**, its **carrier**, and its **consumer**
> (CC-A.6.B.5). Evidence is referred to its carrier, not asserted (A.10).

**Measurement method (A.15 / A.7:5.3).** *MethodDescription* = the `just
quote-ccip-fee-by-amount` recipe; *Method* = sweep the bridged `amount` through live
`Router.getFee` (version-agnostic ground truth) and, where the struct layout is stable, read
the configured policy. *Work* = the dated runs below; *carriers* = the recipe's stdout / the
on-chain `getFee` return values.
**Observation conditions:** mainnet, 2026-06-17, via `RPC_<NET>_REMOTE` (drpc upstreams),
dest selector `5009297550715157269`, message identical to production except the swept
`tokenAmounts[0].amount`.
**Consumer:** the fee-tuning owner (§4 duties).

| E-id | Lane | CCIP transfer-fee source | Observed amount-sensitivity | Fee at the 100 WETH cap (L-5) / breakeven |
|---|---|---|---|---|
| **E-1** | **Optimism** | `EVM2EVMOnRamp v1.5`; `deciBps=50` (**5.0 bps**), min $0.50, **max `4294967295`¢ = $42,949,672.95 = uint32 sentinel ⇒ effectively uncapped** | **scales linearly** ~0.0005 ETH/WETH | ~0.0502 ETH = **40% maxFee** / breach at ~250 WETH (2.5× the cap) |
| **E-2** | **Arbitrum** | `FeeQuoter 2.0.0` @ `0x0cd18bcdc13db7465b2ff5728ca045adec1d182f` | **flat** ~`0.001000478934704750` ETH across 0.001–100000 WETH | ~0.0010 ETH = 0.8% maxFee / never |
| **E-3** | **Base** | `FeeQuoter 2.0.0` @ `0x0352750e6e37e3af39e314d26eb75b950eb3cb62` | **flat** ~`0.000442551628178366` ETH | ~0.00044 ETH = 0.35% maxFee / never |
| **E-4** | **Linea** | `EVM2EVMOnRamp v1.5`; `deciBps=50` (**5.0 bps**), min $1.50, **max uint32 sentinel ⇒ uncapped** | **scales linearly** ~0.0005 ETH/WETH | ~0.0502 ETH = **40% maxFee** / breach at ~250 WETH (2.5× the cap) |

Per-lane routers / WETH (full values, for reproduction):
Optimism router `0x3206695CaE29952f4b0c22a169725a865bc8Ce0f`, WETH `0x4200000000000000000000000000000000000006`;
Arbitrum router `0x141fa059441E0ca23ce184B6A78bafD2A517DdE8`, WETH `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1`;
Base router `0x881e3A65B4d4a04dD529061dd0071cf975F58bCD`, WETH `0x4200000000000000000000000000000000000006`;
Linea router `0x549FEB73F2348F6cD99b9fc8c69252034897f06C`, WETH `0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f`.

- **E-5 (cross-check, A-1 ↔ L-2).** On Arbitrum the `FeeQuoter 2.0.0` *does* price WETH at
  ~$1794.93 (`getTokenPrice`), yet `getFee` stays flat — so the flatness is a **0-bps policy
  for WETH on that lane**, not a missing price feed.
- **E-6 (v1.5 self-consistency).** On Optimism/Linea the configured `deciBps=50` (5.0 bps)
  matches the sweep-implied marginal slope (~5.00 bps) — config (a Description) and `getFee`
  (Work evidence) agree, so the v1.5 read is corroborated.

**Answer (from E + L).** *Does the OtoD fee depend on the bridged amount?* **Yes on Optimism &
Linea** (linear 5 bps, CCIP-uncapped); **no on Arbitrum & Base** (≈0 bps, flat). *Can that
breach `maxFee`?* **Not in production:** the `maxAmount = 100 WETH` per-sync cap (L-5) holds
the worst-case Optimism/Linea quote to ~0.05 ETH ≈ **40% of `maxFee`** (E-1, E-4) — a ~2.5×
margin to the ~250 WETH breakeven. It becomes reachable only if a config change raises
`maxAmount` past ~250 WETH or lowers `maxFee` on those two lanes (the coupling in §4).

---

## 4. Deontics & Commitments (A.6.B quadrant **D** — accountable role; references A/E by id)

> Each duty names an accountable role and cites the gate/evidence it rests on (CC-A.6.B.3,
> CC-A.6.B.4). These are *the tuning discipline surfaced by the finding* — no fix is due now.

- **D-1 (the coupling to respect — the real takeaway).** When changing `setAmounts` or
  `setFeeOtoD` on **Optimism/Linea**, the **LOL multisig** SHALL keep
  `premium(maxAmount) + baseFee + gasTerm < maxFee` — i.e. on those lanes hold `maxAmount`
  below ~250 WETH at `maxFee = 0.125 ETH` (refs A-1, E-1, E-4, L-5). The current setting
  (100 WETH / 0.125 ETH) clears it with ~2.5× margin; **raising `maxAmount` toward 250 WETH
  or lowering `maxFee` erodes it**. Arbitrum/Base carry no such coupling (≈0 bps, E-2/E-3) —
  `maxAmount` tuning there does not move the OtoD fee.
- **D-2 (read the `maxFee` alert as two-driver on OP/Linea).** The **monitoring owner** SHOULD
  treat the §5 `actual fee / maxFee` alert as capturing **amount-driven** growth on
  Optimism/Linea, not only L1 gas-price spikes (E-1, E-4). At the 100 WETH cap those lanes
  sit at ~40%, comfortably under the 80% threshold.
- **D-3 (resolved — no liveness trap at the current setting).** Because each sync is capped at
  100 WETH (L-5, enforced in `_getAmountToSync`, `SyncTrigger.sol:312-313`),
  `canSync()` gating on balance/float rather than a live `getFee ≤ maxFee` check (A-1) is
  **benign** today; the amount-driven `CCIPSenderExceedsMaxFee` revert is reachable only if
  D-1's coupling is violated by a config change.

---

## 5. The false-pass we caught — a Strict-Distinction collapse (A.7)

The first version of the recipe **silently printed garbage** for Arbitrum/Base
(`deciBps=32, max=$1200`) — a textbook **Object ≠ Description ≠ Carrier** failure (A.7:5.5,
A.7:5.9):

- **Object** (`EntityOfConcern`): the on-chain token-transfer fee config of `FeeQuoter 2.0.0`.
- **Carrier**: the raw 32-byte words returned by `getTokenTransferFeeConfig`.
- **Description**: my decode — which assumed the **vendored `FeeQuoter 1.6`** struct layout.

The defect was a **describing morphism applied outside its admissible scope** (violating the
DESC-1N "declared, admissible describing trace" law, CC-A7.14): the v1.6 layout is not an
admissible Description of a v2.0.0 Object, so the decoded `deciBps/max` were meaningless yet
*looked* confirmed. This is precisely the contaminated-oracle / false-pass class — a
plausible Finding with a broken Grounding (B.3 / A.10).

**Why it surfaced and how it was repaired (A.15 + A.7):**

- The **`getFee` sweep is Work** (a dated occurrence) by a system, producing **evidence
  carriers** (the quotes). It is version-agnostic ground truth — `Router.getFee` is identical
  across v1.5 and v2.0.0.
- The **config decode is a Description** of the Object. The repair (CC-A7.4: keep
  MethodDescription/Method/Work distinct; CC-A7.14: admissible describing trace) was to
  **decode only the stable v1.5 `EVM2EVMOnRamp` layout** and, for the newer FeeQuoter,
  **print its `typeAndVersion` and defer to the sweep** rather than emit an unfounded
  Description.
- The two were then **triangulated** (E-6): config `deciBps` cross-checked against the
  sweep slope. Disagreement is now flagged, not hidden.

Secondary defect (also A.7-adjacent): fees exceed `2^63` wei at the top of the sweep (50 ETH
at 100000 WETH), so bash 64-bit arithmetic overflowed the Δ column. Fix: all fee arithmetic
moved to `awk` (doubles).

---

## 6. Conformance checklist (what this writeup relied on)

| CC item | Where applied |
|---|---|
| **CC-A.6.B.1 / .2** (atomicity, routing) | Every finding is one atomic claim in exactly one of L / A / D / E (§1–§4). |
| **CC-A.6.B.3** (form) | L/A carry no deontic keywords; D names an accountable role; E avoids "guarantees". |
| **CC-A.6.B.4 / .7** (explicit refs, no upward deps) | D-1…D-3 cite A-1 / E-* by id; L cites nothing; A cites L; E cites A/L. |
| **CC-A.6.B.5** (E adjudicability) | §3 states observation conditions + carrier + consumer. |
| **CC-A7.3** (episteme non-agency) | The recipe/docs do not "decide"; a system runs the Method and cites carriers. |
| **CC-A7.4** (MethodDescription ≠ Method ≠ Work) | §3, §5 separate the recipe, the sweep/decode methods, and the dated runs. |
| **CC-A7.6** (carrier reference) | Findings point to the `getFee` returns / recipe output and source lines. |
| **CC-A7.14** (admissible describing trace) | §5 — the v1.6-on-v2.0.0 decode was an inadmissible Description; repaired. |

---

## Appendix — reproduce

```sh
RPC_OPTIMISM=$RPC_OPTIMISM_REMOTE RPC_ARBITRUM=$RPC_ARBITRUM_REMOTE \
RPC_BASE=$RPC_BASE_REMOTE RPC_LINEA=$RPC_LINEA_REMOTE \
just quote-ccip-fee-by-amount
```

Per lane it prints the configured policy (decoded only where the layout is stable, i.e.
v1.5 — else the FeeQuoter version, deferring to the sweep), the fee-vs-amount curve, the
marginal bps, and the breakeven amount versus `maxFee`.
