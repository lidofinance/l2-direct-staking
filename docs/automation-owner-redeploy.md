> **View — the plan for moving the automation layer to a dedicated Automation Owner.**
> Stakeholder: the migration owner deciding it, plus the three actors who execute it (Lido
> Deployer, **Automation Owner**, Initial Owner) and the LOL Safe that keeps the pool. Concern:
> *what is true on-chain today, what exactly changes, in which order, by whose signature, and how
> each step is evidenced* — for adopting [`DOC.md` §4.2](../DOC.md#42-diagram-b--ownership--access-control)
> by **redeploying** `SyncTrigger` + `CREReceiver` under a new Automation Owner EOA instead of
> transferring the existing pair. The resulting-state architecture stays in
> [`DOC.md`](../DOC.md); the operator recipe in [`RUNBOOK.md`](../RUNBOOK.md); CRE lifecycle in
> [`docs/cre.md`](cre.md). Doc map: [`README.md` §Documentation](../README.md#documentation).
>
> **Status: plan, not a run.** Nothing in §4–§7 has been executed. §1–§3 are verified facts as of
> **2026-07-28**, block-pinned.

# Automation-layer redeploy under a dedicated Automation Owner

## 0. Decision record

Shaped per `C.11` (`CC-C11.14`) so the choice is inspectable rather than implied.

| Field | Value |
|---|---|
| **Chooser** | Lido DAO contributors owning this migration (the request this plan answers). |
| **Question** | Who holds `SyncTrigger.owner`, `CREReceiver.owner`, `CREReceiver.expectedAuthor` and the CRE workflow owner? |
| **Option set** | {`4.2.A` — LOL Safe holds all four · `4.2.B` — a dedicated **Automation Owner** EOA holds all four}. Closed set; the pool owner is not in question in either. The labels are the two options' original DOC.md section numbers; `4.2.B` is now [`DOC.md` §4.2](../DOC.md#42-diagram-b--ownership--access-control) and `4.2.A` is [archived](archive/ownership-lol-owned-automation.md). |
| **Comparison basis** | incident-response latency · single-key compromise exposure · what any one compromised holder reaches · CRE registration ergonomics · routine-tuning friction. |
| **ChoiceRule** | chooser's judgment on the stated basis. |
| **ChoiceResult** | **`choose now` = 4.2.B.** Superseded the `probe again` DOC.md carried; since 2026-07-29 [`DOC.md` §4.2](../DOC.md#42-diagram-b--ownership--access-control) records this result and the losing option is [archived](archive/ownership-lol-owned-automation.md) rather than deleted (`A.16.2`). |
| **Probe status** | The four probes DOC.md listed as settling the tie are **still unanswered** — they did not gate the choice, so they become residual-risk items, not blockers: see §8 Q1–Q4. |

A **second, separate decision** rides along and is *not* the one above: **how** to get to 4.2.B —
`transfer` the deployed pair or `redeploy` it. DOC.md's original route was transfer ("no redeploy");
it now records the redeploy route this plan carries. The request chose redeploy. That choice is defensible but **not forced** — see §2.1. Everything from
§3 on is written for **redeploy**.

## 1. Verified starting state

Reads are live `cast` calls at the blocks below, reproducible with the read-only
`just audit-ownership` recipe added for this verification (no keys, no writes; all four lanes).
Design-time facts (source, config, git) are marked as such — kept in a separate table per `CC-B3.8`,
because "the code says X" and "the chain says X" are different claims.

**Block pins (the carrier of every run-time value in §1.1):** Optimism 154835122 · Arbitrum
488710143 · Base 49239857 · Linea 31549765 · Ethereum 1 (registry reads, same session).

### 1.1 Run-time state — what the chain says

Addresses are identical on all four lanes for the three deployed contracts (deterministic
nonce-ordered deploys; ⚠ the same hex is a *different* contract per chain for other roles).

| Fact | Value | Lanes |
|---|---|---|
| New `PausableImmutableOraclePool` | `0xac143bF41BBA4a8014b4Ef5a5F46b39a36AE40A8` — `owner()` = LOL `0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6` | all 4 |
| `SyncTrigger` (v1) | `0x1594705D5f9BbDb36453ACF15C94d041c0E02c62` — `owner()` = LOL, `getForwarder()` = CREReceiver v1, `SENDER()` = that lane's CustomSender | all 4 |
| `CREReceiver` (v1) | `0x29113eD7AE4C97Ee2F20A5511C852aa37C0d6b85` — `owner()` = LOL, `getForwarder()` = that lane's real CRE forwarder, `getExpectedAuthor()` = LOL, `isCallAllowed(trigger v1, triggerSync())` = true | all 4 |
| `CustomSender.getOraclePool()` | = the new pool → the new pool **is** the live selection | all 4 |
| `hasRole(SYNC_ROLE, SyncTrigger v1)` | **true** | all 4 |
| `hasRole(SYNC_ROLE, predecessor automation)` | **true** — `0x3776CC14ce997827F7A87091018Daa1739dc2790` (OP, Base), `0x7EbD06BF137077fF5EE858ca6368dBd95DB7c66A` (Arb), Gelato `0xFbdDDF18Bc681Ae649991f1Aced55b2252a1acAe` (Linea). Linea's Chainlink automation `0x9c27c304cFdf0D9177002ff186A4aE0A5489Aace` is already **false**. | see cells |
| `hasRole(DEFAULT_ADMIN_ROLE, Initial Owner 0xb5c336a5c60D3482b29d83C742C65AE8351b91a8)` | **true** | all 4 |
| `hasRole(DEFAULT_ADMIN_ROLE, gov executor)` | **false** — OP `0xEfa0dB536d2c8089685630fafe88CF7805966FC3`, Arb `0x1dcA41859Cd23b526CBe74dA8F48aC96e14B1A29`, Base `0x0E37599436974a25dDeEdF795C848d30Af46eaCF`, Linea `0x74Be82F00CC867614803ffd7f36A2a4aF0405670` | all 4 |
| `hasRole(DEFAULT_ADMIN_ROLE, ·)` for LOL and for the Deployer | **false** | all 4 |
| `L2ProxyAdmin.owner()` | = **Initial Owner** `0xb5c336a5c60D3482b29d83C742C65AE8351b91a8` | all 4 |
| `SyncTrigger v1` ETH float | **0** (swept to the Deployer at `handoff`, by design). `getMaxFees()` = 0.125 ETH; 0.126005 ETH on Arbitrum | all 4 |
| `CREReceiver v1` ETH balance | **0** | all 4 |
| New pool balances | **0 WETH / 0 wstETH**; the predecessor pools still hold the whole position — [`docs/funds-snapshot-2026-07-28.md`](funds-snapshot-2026-07-28.md) | all 4 |
| `WorkflowRegistry 2.0.0` `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5` (L1) | `getWorkflowListByOwner(LOL,0,50)` → **empty array**; `isOwnerLinked(LOL)` → **false**; `isOwnerLinked(Deployer)` → **false**; `totalLinkedOwners()` = 140 | L1 |
| `CREReceiver v1` allow-list history | Exactly **one** `AllowedCallUpdated` event ever emitted: `(trigger v1, 0x340b2b0b, true)`. Verified on Optimism from block 137000000; the other three came from the same deploy call, unread. | OP verified |
| Lido Deployer `0xBeedf0c72D63eE8f8784eDB4A9326Fb43b69D50c` nonce | **19** on Optimism, Base, Linea · **29** on Arbitrum | all 4 |

**The five statements that matter most, read off the table:**

1. `activate` + `handoff` are **done** on all four lanes; `finalize` is **not started** anywhere.
   The Initial Owner still holds `DEFAULT_ADMIN_ROLE` on every `CustomSender` **and** owns every L2
   `ProxyAdmin`.
2. The whole automation surface (both contracts, both owner slots, the author pin) is held by the
   **LOL Safe**, i.e. exactly the 4.2.A arrangement.
3. **No CRE workflow has ever existed.** No workflow is registered under LOL, and LOL is not even a
   *linked owner* in the registry. The `config.deploy.<net>.json` files still carry
   `0xYOUR_CRE_RECEIVER_ADDRESS` placeholders.
4. **Nothing is running.** Floats are 0, the live pool is empty, and there is no workflow to drive a
   sync. Every lane is wired but idle.
5. Statement 4 is the single most useful fact in this document: **this redeploy carries no service
   risk, because there is no service to interrupt.** Its cost is re-doing config/evidence, not
   downtime.

### 1.2 Design-time state — what the repo says

| Fact | Evidence |
|---|---|
| `SyncTrigger`'s only immutables are `SENDER`, `DEST_CHAIN_SELECTOR`, `WNATIVE`. Owner is a constructor **argument** (`initialOwner`), and every operational parameter has an `onlyOwner` setter. | `src/SyncTrigger.sol:88-90,124,307-331` |
| `CREReceiver` has **no** immutables. `forwarder`, `expectedAuthor` and the allow-list are all `onlyOwner`-settable; the owner is `Ownable(msg.sender)` — the **broadcaster**, not a parameter. | `src/cre/CREReceiver.sol:76-79,92-107,174-194` |
| Neither contract overrides `renounceOwnership`; neither can self-destruct. | `src/SyncTrigger.sol`, `src/cre/CREReceiver.sol` |
| `CustomSender.sync()` is gated on `SYNC_ROLE` **alone** — caller identity beyond the role is irrelevant. | `lib/chainlink-csr/contracts/senders/CustomSender.sol:190-196` |
| `deploySyncInfrastructure(cfg, creForwarder, expectedAuthor, deployOwner, fundFloat)` already deploys the pair with an **arbitrary** owner ≠ broadcaster: receiver first, trigger second, allow-list seeded while the broadcaster still owns the receiver, then ownership transferred. | `script/shared/L2UpgradeActions.s.sol:202-226` |
| No build-relevant change since the deploy commits (`ecbfcf5` for Arb/Base/Linea, `730cf53` for OP): `git log <commit>..HEAD -- src lib foundry.toml remappings.txt foundry.lock` is **empty** for both. A redeploy today ships **identical bytecode**, differing only in constructor arguments. | git |
| `WorkflowRegistry 2.0.0` exposes **no per-workflow ownership transfer**; the owner is fixed at registration. Changing it = new workflow + re-pin. | `docs/adr/0001-cre-workflow-owner-multisig.md`, `script/l1/VerifyCREWorkflow.s.sol:13-33` |
| Migration actors (gov executor, CRE forwarder, predecessor pool) are sourced **only** from per-network constants, never env, with a revert-if-unpinned hook. | `script/shared/L2UpgradeScriptBase.s.sol:63-148` |
| state-mate binds automation ownership through one anchor: `syncTrigger.owner`, `creReceiver.owner`, `creReceiver.getExpectedAuthor` and `oraclePool.owner` **all** read `*l2LiquidityOwner`. | `config/state/l2.yaml:154,177,195,197` |

## 2. The request's claims, checked

### 2.1 "The new architecture would require redeployment of `CREReceiver` and `SyncTrigger`"

**Not required — chosen.** Both contracts reach the 4.2.B end state through their existing owner
setters: `Ownable.transferOwnership` on each, plus `setExpectedAuthor(automationOwner)`. Nothing about
the owner is immutable (§1.2), and the bytecode a redeploy would produce is byte-identical to what is
already live (§1.2, git). This is also what DOC.md originally prescribed ("**Getting from A to B** —
no redeploy") before it was updated to the route chosen below.

So the real choice is a route, on a stated basis:

| Basis | **T — transfer the deployed pair** | **R — redeploy under the new owner** (chosen) |
|---|---|---|
| LOL Safe signatures | **Required**: `transferOwnership` ×2 per lane (batchable → 4 Safe txs) | **None required** |
| Initial Owner (external party) signatures | **None** | **Required**: `grantRole(SYNC_ROLE, v2)` + `revokeRole(SYNC_ROLE, v1)` — 1 broadcast per lane |
| Automation Owner signatures | `setExpectedAuthor` ×4 | none at deploy (owner + author set in-constructor) |
| Deployer cost | none | 2 CREATEs per lane + float funding |
| Addresses | unchanged → every doc/config/`.env`/explorer/diffyscan artifact stays valid | **change**; all of the above must be regenerated |
| Retired-contract handling | none — same contracts | v1 pair must be de-roled and disposed (§6) |
| Provenance | pair was Deployer-owned → old LOL Safe (Arb/Base) → LOL Safe → Automation Owner | Automation Owner from birth, one owner ever |
| Failure mode of the change itself | `transferOwnership` is 1-step and irreversible on a typo → bricks the contract | a wrong-address deploy is discarded; nothing is bricked |
| Service risk | none (nothing is running) | none (nothing is running) |
| Code/config churn | anchor split only | anchor split + new script entry points + constants + `.deployed.yaml` + tests + docs |

Neither dominates. **R buys** independence from LOL Safe quorum, clean single-owner provenance, and a
change with no bricking edge. **T buys** far less work and zero address churn, at the cost of needing
the Safe. Proceeding with **R** as requested; if the LOL Safe is readily available to sign, T is the
cheaper route and remains open until §4 S3 runs.

### 2.2 "The new pool does not need redeployment — it is owned by the proper LOL multisig"

**Confirmed.** `owner()` = `0xFc832dA3D688352C0aB1A32136c7fABbB16d66E6` on all four lanes, it is the
live `getOraclePool()` target, and 4.2.B leaves the liquidity domain with LOL unchanged. Its
parameters (`SENDER`, tokens, oracle, fee) are immutable-or-reverting, so there is nothing to re-point
inside it. The pool is empty, which is a funding item, not a redeploy reason.

### 2.3 "Initial Owner would need to change `CustomSender`'s `SYNC_ROLE` to the new `SyncTrigger`"

**Confirmed, and time-boxed.** `SYNC_ROLE`'s admin is `DEFAULT_ADMIN_ROLE`, held **today** by the
Initial Owner on all four lanes; the gov executor holds nothing yet. So the grant/revoke is a single
external-party broadcast per lane **now**, and becomes a **DAO vote per lane** the moment `finalize`
runs.

> **Scheduling constraint.** Every automation-layer swap must land **before** `finalize`. This is the
> strongest ordering constraint in the plan and the reason §4 puts `finalize` last.

Two sharp edges on this step:

- OZ `revokeRole` is a **silent no-op** when the account lacks the role. A mistyped v1 address
  revokes nothing while looking successful — the same false-pass class `migrateSenderAdmin` already
  guards with a pre-condition. The new step must assert `hasRole(SYNC_ROLE, v1) == true` **before**
  and `== false` **after**.
- Grant and revoke belong in **one** transaction, so the window in which two triggers hold
  `SYNC_ROLE` is zero-length.

### 2.4 "The currently deployed `CREReceiver` and `SyncTrigger` can make no harm"

**True today, but only contingently — and one contingency is exactly what 4.2.B is buying.**

Why they are harmless right now: the v1 receiver's allow-list contains exactly one entry (§1.1), so
the only call it can ever make is the nullary `triggerSync()`; its author gate is pinned to LOL; and
**no workflow exists under LOL**, so the CRE path cannot produce a report that passes. Both contracts
hold 0 ETH. The v1 trigger's float is 0, so even a successful `triggerSync()` reverts
`SyncTriggerInsufficientFloat`.

Why that is not a property you can rely on after the switch: **v1 keeps `SYNC_ROLE`**, and the LOL
Safe still owns v1 outright. LOL can `setForwarder` on the v1 trigger to any address — including
itself — and then call `triggerSync()` directly; the receiver is not even needed. Funding the float is
permissionless. So while v1 holds `SYNC_ROLE`, **the LOL Safe retains a live automation capability**,
and a Safe compromise (DOC.md §4.2.2 case **(b)**) reaches the automation domain again — the precise
coupling 4.2.B exists to break. Its §4.2.2(b) claim, "under 4.2.B it is confined to the pool", is
**false as long as the v1 revoke is skipped**.

Consequence for the plan: `revokeRole(SYNC_ROLE, trigger v1)` is not tidy-up, it is **load-bearing**
(§4 S6). Everything else in §6 is optional hygiene.

### 2.5 "The Automation Owner will deploy the CRE workflow and thus own it"

**Confirmed mechanically, with one prerequisite and one consequence.**

- Mechanism: the workflow owner is whichever address is recorded at `cre workflow deploy`. An EOA
  signs natively, so the `--unsigned` → execute-from-Safe detour of ADR-0001 becomes unnecessary.
- **Prerequisite:** the owner address must be a **linked owner** in the registry
  (`cre account link-key`). `isOwnerLinked` is **false** for both LOL and the Deployer today, so this
  step has never been done for anyone and must be done for the Automation Owner.
- **Consequence:** CRE **credits are administered against the workflow owner's CRE account**
  ([`docs/cre.md`](cre.md#funding-and-billing)). Adopting 4.2.B moves billing/credit administration —
  and `pause`/`activate`/`delete`/update-WASM — onto that EOA's account. That is a real operational
  hand-over, not just an address change (§8 Q5).

### 2.6 "Only when all is good and CRE is tested, Initial Owner transfers ownership to Lido DAO"

**Correct, and it is the right gate** — with one correction of expectation: because no workflow has
ever existed, "CRE is tested" has **never happened** in this project. The first live, DON-driven sync
is §4 S8, and it is a new milestone, not a re-run. The existing canary only proved the on-chain chain
with the Deployer *standing in* for the forwarder; the real forwarder + DON + workflow leg is untested.

One more item belongs in that final gate: `finalizeGovernanceSeal` **asserts** the automation owner is
`cfg.liquidityOwner` today. Left unchanged it will **revert** once the automation layer is
Automation-Owner-owned. It fails closed, which is the desired direction, but it must be updated as
part of §4 S1 or `finalize` cannot run at all.

## 3. Target end state

Delta only; everything not listed is unchanged from [the archived arrangement](archive/ownership-lol-owned-automation.md).

| Slot | Today | After |
|---|---|---|
| `OraclePool.owner` | LOL Safe | **LOL Safe** (unchanged) |
| `SyncTrigger.owner` | LOL Safe, on trigger **v1** | **Automation Owner**, on trigger **v2** |
| `CREReceiver.owner` | LOL Safe, on receiver **v1** | **Automation Owner**, on receiver **v2** |
| `CREReceiver.getExpectedAuthor` | LOL Safe | **Automation Owner** |
| CRE workflow owner | *(none registered)* | **Automation Owner**, signed directly |
| `hasRole(SYNC_ROLE, trigger v2)` | — | **true** |
| `hasRole(SYNC_ROLE, trigger v1)` | true | **false** |
| `hasRole(SYNC_ROLE, predecessor automation)` | true | **false** (revoked by `finalize`) |
| `CustomSender` `DEFAULT_ADMIN_ROLE` | Initial Owner | **gov executor** (at `finalize`) |
| `L2ProxyAdmin.owner` | Initial Owner | **gov executor** (at `finalize`) |
| Retired v1 pair | LOL-owned, v1 trigger holds `SYNC_ROLE` | de-roled; disposition per §6 |
| state-mate anchor | one `*l2LiquidityOwner` for 4 assignments | `*l2LiquidityOwner` (pool) + **`*l2AutomationOwner`** (3 assignments) |

**Role ≠ key ≠ run** (`A.15`, `A.7`): "Automation Owner" is a **role** in this architecture; the EOA
is the **carrier** that currently fills it; the transactions below are the **work**. §8 Q1 is about the
carrier's custody and does not change the role.

## 4. The plan

Per lane unless marked *once*. Actor column is who signs. Every stage names its **gate** — the
evidence that must exist before the next stage starts (`A.10`: evidence referred, not asserted).

### S0 — Prerequisites *(no chain writes)*

| # | Item | Owner |
|---|---|---|
| S0.1 | Create the Automation Owner EOA; record its address; settle custody terms (§8 Q1). | requester |
| S0.2 | `cre account link-key` for that EOA → `isOwnerLinked(AO)` must read **true** on `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`. | Automation Owner |
| S0.3 | Fund the Automation Owner with a small gas balance on all four L2s (it signs setter txs, not deploys). | requester |
| S0.4 | Decide who funds the four 0.5 ETH floats (§8 Q6). Deployer balances today: OP 0.2489 / Arb 0.0769 / Base 0.2258 / Linea 0.2470 ETH — **insufficient**; top up by ≥ 2 ETH + gas if the Deployer funds them. Funding is permissionless, so the Automation Owner or LOL can fund instead. | requester |

**Gate:** AO address fixed, linked, gas-funded; float funder decided.

### S1 — Code + config changes *(no chain writes)*

Design notes, chosen to minimize diff against audited paths:

1. **Automation Owner as a pinned constant, not env.** Add `AUTOMATION_OWNER` to
   `script/l1/L1MigrationConstants.sol` (lane-invariant, like `INITIAL_OWNER` / `LIDO_DEPLOYER`) plus
   an `_expectedAutomationOwner()` hook with the revert-if-unpinned pattern of
   `_expectedGovernanceExecutor`. Rationale: this is a migration actor baked into an irreversible
   constructor argument — the class the repo already refuses to read from env.
2. **Retired pair as pinned constants**: `L2_RETIRED_SYNC_TRIGGER` /
   `L2_RETIRED_CRE_RECEIVER` per network (same treatment as `L2_OLD_SYNC_AUTOMATION`), because a
   mistyped revoke target is a silent no-op (§2.3).
3. **No new deploy primitive.** `deploySyncInfrastructure(cfg, creForwarder, expectedAuthor,
   deployOwner, fundFloat)` already does exactly what is needed. Only a thin script entry point is new.
4. **Assertion split via additive overloads.** `_assertSyncInfrastructure`, `verifyCanaryStage2` and
   `finalizeGovernanceSeal` currently take one `expectedOwner`. Add overloads carrying an explicit
   `automationOwner`, leaving the existing signatures delegating with `cfg.liquidityOwner` so the
   already-exercised paths stay byte-unchanged.

| # | Change | File(s) |
|---|---|---|
| S1.1 | `AUTOMATION_OWNER` constant + `_expectedAutomationOwner()` hook (+ per-network overrides) | `script/l1/L1MigrationConstants.sol`, `script/shared/L2UpgradeScriptBase.s.sol`, `script/{optimism,arbitrum,base,linea}/*L2Upgrade.s.sol` |
| S1.2 | `L2_RETIRED_SYNC_TRIGGER` / `L2_RETIRED_CRE_RECEIVER` constants | `script/*/`*`MigrationConstants.sol` |
| S1.3 | New entry point `runDeployAutomation()` — Deployer broadcast, **production** cfg: `deploySyncInfrastructure(cfg, _creForwarder(), _automationOwner(), _automationOwner(), false)` | `script/shared/L2UpgradeScriptBase.s.sol` |
| S1.4 | **Done 2026-07-29**, shipped as `repointSyncRole(cfg, retired, next, admin, strictTarget)` + entry points `runRepointSyncRole()` / `runRepointSyncRoleUnlocked()` / `runPrintRepointSyncRoleCalldata()` and recipes `just repoint-sync-role <new> [<retired>]` / `repoint-sync-role-calldata`. Named for what it does (rotate `SYNC_ROLE`) rather than the planned `runRepointAutomation`, which read as if it moved the whole automation layer. Gates before the first write: `hasRole(SYNC_ROLE, retired) == true` (the §2.3 silent-no-op guard), `retired != next`, `hasRole(DEFAULT_ADMIN_ROLE, admin)`, `getRoleAdmin(SYNC_ROLE) == DEFAULT_ADMIN_ROLE`, and — new, not in the plan — `next.SENDER()` / `next.DEST_CHAIN_SELECTOR()` must match the lane (both immutable, so a wrong-lane pair can only be replaced; waive with `L2_REPOINT_ALLOW_ANY_TARGET=true`). Asserted after: both roles flipped, `DEFAULT_ADMIN_ROLE` unchanged, oracle-pool pointer unchanged, predecessors untouched. **Deviation from §4 S6 / §7.6:** grant and revoke are TWO transactions, not one — `forge script` broadcasts one per call. Grant-first is chosen so a failed second transaction leaves both triggers armed (redundant, delay-throttled) rather than neither (outage); `repoint-sync-role-calldata` emits both calls for an operator who wants them batched atomically. Retired holder resolves from `L2_RETIRED_SYNC_TRIGGER`, else `L2_SYNC_TRIGGER`. Rehearsed on anvil forks of all four lanes (deploy v2 → rotate → assert → re-run refused) plus 7 fork tests per lane in `PoolUpgradeTests`. | `script/shared/L2UpgradeScriptBase.s.sol`, `script/shared/L2UpgradeActions.s.sol`, `justfile`, `test/helpers/PoolUpgradeTests.sol` |
| S1.5 | Additive `automationOwner` overloads for `_assertSyncInfrastructure` / `verifyCanaryStage2` / `finalizeGovernanceSeal`; production callers switch to them | `script/shared/L2UpgradeActions.s.sol` |
| S1.6 | New anchor `&l2AutomationOwner`; new `&l2RetiredSyncTrigger` / `&l2RetiredCreReceiver` | `config/state/l2-{optimism,arbitrum,base,linea}.inputs.yaml` |
| S1.7 | `syncTrigger.owner`, `creReceiver.owner`, `creReceiver.getExpectedAuthor` → `*l2AutomationOwner`; `oraclePool.owner` stays `*l2LiquidityOwner`; add `hasRole: [[*SYNC_ROLE, *l2RetiredSyncTrigger] → false]` alongside the existing `l2OldSyncAutomation` row | `config/state/l2.yaml:154,177,195,197` and `:92-95` |
| S1.8 | Canary overlay: it currently redefines `*l2LiquidityOwner` → Deployer, which after S1.7 would assert the **pool** is Deployer-owned. Drop the two address overrides; keep (or re-scope) only `syncMinAmount` / `syncDelay` for the S8 live test. Mind the "override must differ from base" and "no new labels" rules. | `config/state/l2.inputs.test-stage.yaml` |
| S1.9 | Extend `verify-constants-sync` + `verify-externals-coverage` to the three new anchors; add the new constants to the pinned-constants guard | `justfile`, `test/L2PinnedConstantsGuard.t.sol` |
| S1.10 | New recipes: `deploy-automation` (**done**), `repoint-sync-role` + `repoint-sync-role-calldata` (**done 2026-07-29**, see S1.4); `deploy-cre-workflow` gains a **signed** path (drop `--unsigned`, owner = AO, keep the `getExpectedAuthor()` cross-check) — still open | `justfile`, `cre-workflows/project.yaml` |
| S1.11 | Update fork/integration tests to the split owner (they assert LOL owns all three) | `test/helpers/*`, `test/CREReceiverTest.t.sol` |
| S1.12 | **ADR-0002** superseding ADR-0001 (owner = AO EOA, `--unsigned` retired, credit account moves); mark ADR-0001 *Superseded* | `docs/adr/` |
| S1.13 | Docs. **Done 2026-07-29:** DOC.md (§4.2 = the adopted arrangement with the redeploy route and the `choose now` record; §2.2, §2.6, §2.7, §3.2, §3.4, §4.1, §6.3 re-pointed to the Automation Owner; the losing option moved to `docs/archive/ownership-lol-owned-automation.md` per `A.16.2`) and the README doc table. **Still open:** RUNBOOK, `docs/cre.md`, `docs/monitoring.md` (owner-expectation rows), `docs/canary-deploy.md` (its "addresses identical across chains" claim breaks — see S3), `docs/audit-scope.md` | as listed |

**Gate:** `just verify-constants-sync`, `just verify-abi-sync`, `just verify-externals-coverage`, unit
tests and the state-mate override tests all green; nothing broadcast.

### S2 — Dress rehearsal on forks

Run the full S3→S6 sequence on an anvil fork per lane using the existing `*Unlocked` twins and
fork-acceptance suites, ending in a `finalize` rehearsal so the S1.5 assertion split is proven before
any mainnet write.

**Gate:** all four lanes green end-to-end on forks, including a rehearsed `finalize`.

### S3 — Deploy the v2 pair · *Actor: Lido Deployer*

```sh
just -E .env.<network> deploy-automation      # runDeployAutomation()
```

Deploys receiver v2 (allow-list empty), then trigger v2 (`initialOwner` = AO, production
delay/amounts/fees), seeds the allow-list with `(trigger v2, triggerSync())`, then transfers the
receiver to AO — all in one broadcast, with `_assertSyncInfrastructure` as the in-broadcast guardrail.
Regenerate `config/state/l2-<net>.deployed.yaml` keeping the **existing pool** anchor and replacing the
two automation anchors.

> **Addresses will no longer be lane-invariant.** The Deployer's nonce is 19 on Optimism/Base/Linea
> but **29 on Arbitrum**, so Arbitrum's v2 pair gets different addresses. Do not carry the
> "same address on all four lanes" convenience into any config or doc; treat every address as
> per-lane and let `.deployed.yaml` be the source of truth.

**Gate:** broadcast `status 0x1`; `.deployed.yaml` regenerated per lane; `just audit-ownership` shows
v2 owner = AO, author = AO, forwarder = real CRE forwarder, `SyncTrigger.getForwarder()` = receiver v2.

### S4 — Verify the v2 pair

| Check | Command |
|---|---|
| Live state vs pinned anchors | `just test-<net>-upgrade-state-verify` (state-mate; production profile) |
| Explorer source publication | `just -E .env.<network> verify-sources` (re-run for the new addresses) |
| Bytecode diff vs GitHub | `just -E .env.<network> diffyscan` (still blocked on a repo-granted PAT) |
| Forwarder identity | `just verify-cre-forwarder` |

**Gate:** state-mate green except the documented `finalize`-gated errors; sources published on all four
explorers.

### S5 — Fund the v2 float · *Actor: per S0.4*

0.5 ETH per lane (`just -E .env.<network> fund-trigger`, or a plain transfer — funding is
permissionless). **Gate:** `SyncTrigger v2` balance ≥ `getMaxFees()` on all four lanes.

### S6 — Re-point `SYNC_ROLE` · *Actor: Initial Owner (external)* — **the load-bearing step**

```sh
just -E .env.<network> repoint-sync-role <trigger-v2>     # runRepointSyncRole()
```

`grantRole(SYNC_ROLE, trigger v2)` **and** `revokeRole(SYNC_ROLE, trigger v1)` per lane, with the
has-role assertions of §2.3 before and after (plus the lane-identity guard on v2 — see S1.4). This is
what makes v2 live and what actually severs LOL's automation capability (§2.4).

**Two transactions, not one.** §7.6 asks for a single transaction so the window in which two triggers
hold `SYNC_ROLE` is zero-length; `forge script` cannot deliver that — it broadcasts one transaction per
call. The recipe grants **before** it revokes, so the failure mode of a second transaction that does not
land is *both* triggers armed (redundant automation, throttled by the shared per-sender delay) rather
than *neither* (an automation outage). If the zero-length window is worth the extra handling, take the
two calls from `just -E .env.<network> repoint-sync-role-calldata <trigger-v2>` and submit them as one
multisend; that recipe is also the route for the external Initial Owner, who does not broadcast from
this repo, and the only route at all once S10 has sealed the admin to the governance executor.

**Gate:** `just audit-ownership` shows `hasRole(SYNC_ROLE, v2) = true` **and**
`hasRole(SYNC_ROLE, v1) = false` on all four lanes. Do not proceed to S10 until this reads clean
everywhere.

### S7 — Register the CRE workflow under the Automation Owner · *Actor: Automation Owner*

1. `just -E .env.<network> update-cre-config` — writes receiver v2 / trigger v2 into
   `cre-workflows/sync-automation/config.deploy.<net>.json` (still placeholders today).
2. `just -E .env.<network> deploy-cre-workflow` on the new **signed** path: `CRE_WORKFLOW_OWNER` = AO,
   no `--unsigned`, keeping the abort-on-mismatch cross-check against the on-chain
   `getExpectedAuthor()`.
3. Record `CRE_WORKFLOW_ID` in `.env.<network>`; run `just -E .env.<network> verify-cre-workflow`.

**Gate:** `getWorkflowById` shows owner = AO, status `ACTIVE`, non-empty `binaryUrl`; registry owner ==
`CREReceiver v2.getExpectedAuthor()` == `CREReceiver v2.owner()`.

### S8 — First live DON-driven sync *(the "CRE is tested" milestone)* · *Actors: AO + a WETH seeder*

1. Optionally lower the gates for a cheap first sync — the AO owns the trigger, so
   `setDelay(60)` / `setAmounts(0.0002e18, …)` is a single signature with **no handoff involved**. This
   replaces the old Deployer-owned canary entirely.
2. Seed the live pool with WETH ≥ the active `minAmount` (a plain transfer; the pool is LOL-owned, so
   any residue is LOL's to `sweep` afterwards — or simply left for production).
3. Let the DON fire on schedule. Observe: `CREReceiver.CallExecuted` on L2 → `Sync` on L2 →
   `MessageSucceeded` on L1 → wstETH back in the live pool.
4. Restore production values (`setDelay(43200)`, `setAmounts(5e18, 100e18)`); re-run state-mate under
   the production profile.

**Gate:** ≥ 1 `CallExecuted` observed (the only proof the DON-embedded author matches the pin) and one
complete round-trip; production values restored and state-mate green.

### S9 — Dispose of the retired v1 pair · *Actor: LOL Safe* — see §6 for the option set

**Gate:** whichever disposition §8 Q7 selects, recorded with its transactions.

### S10 — Governance seal · *Actor: Initial Owner*

`just -E .env.<network> verify-stage2` → `just -E .env.<network> finalize` per lane, then
`just migrate-l1` *once*. This revokes the predecessor automations, moves `CustomSender`
`DEFAULT_ADMIN_ROLE` and the L2 `ProxyAdmin` to the gov executor, and closes the window in which the
Initial Owner can re-point `SYNC_ROLE` without a DAO vote.

**Gate:** state-mate green with **zero** errors on all four lanes; `audit-ownership` shows gov
executor as admin and `ProxyAdmin` owner, Initial Owner revoked, every retired/predecessor automation
`false` on `SYNC_ROLE`.

## 5. Ordering constraints (the only ones that are not preference)

1. **S6 before S10.** After `finalize`, `SYNC_ROLE` changes need a DAO vote per lane.
2. **S1.5 before S10.** `finalizeGovernanceSeal` asserts the old single-owner shape and will revert.
3. **S5 before S8.** Zero float ⇒ `triggerSync` reverts `SyncTriggerInsufficientFloat`.
4. **S0.2 before S7.** An unlinked owner cannot register a workflow.
5. **S3 before S7.** `update-cre-config` and the author cross-check need the v2 addresses on-chain.
6. **S6 grant before revoke.** The `repoint-sync-role` recipe cannot make the pair atomic (§S6), so the
   ordering carries the constraint instead: grant-first means an interrupted run leaves two triggers
   holding `SYNC_ROLE` (redundant, delay-throttled) rather than none. Batch the
   `repoint-sync-role-calldata` output through a multisend if the concurrent-holder window must be
   zero-length.

## 6. Disposing of the retired pair

Facts that bound the options: both v1 contracts hold **0 ETH**; the v1 receiver's allow-list holds
exactly one entry; neither contract can be destroyed; `renounceOwnership` is available on both and is
**irreversible**.

| Option | Actions (LOL Safe) | Result |
|---|---|---|
| **D0 — de-role only** | none beyond S6 | v1 inert: `triggerSync` reverts inside `CustomSender` for want of `SYNC_ROLE`. LOL still owns two configurable-but-powerless contracts. |
| **D1 — de-role + neutralize** (recommended) | `receiver v1.setAllowedCall(trigger v1, triggerSync(), false)`; optionally `setExpectedAuthor(0x…dead)` / `setForwarder(0x…dead)` | Same, plus the receiver cannot dispatch anything even if `SYNC_ROLE` were ever re-granted. Reversible by LOL. |
| **D2 — D1 + `renounceOwnership` on both** | `renounceOwnership()` ×2 | Configuration frozen forever; provably nobody can revive them. Also destroys the cold-spare option below. |

**Recommendation: D1, and keep ownership.** With `SYNC_ROLE` revoked, v1 is already harmless; leaving
LOL as owner preserves a genuinely useful fallback — if the Automation Owner key is **lost** (DOC.md
§4.2.2 case **(c)**), the recovery is "re-grant `SYNC_ROLE` to a live trigger", and a
production-configured LOL-owned trigger already exists. After `finalize` that re-grant is a DAO vote
either way, so the spare costs nothing to keep and saves a redeploy. D2 buys a cleaner story and
forecloses that. Note the flip side, stated plainly: keeping the spare means a compromised LOL Safe
still owns a trigger that a *future* `SYNC_ROLE` grant could arm — the spare is only as safe as the
revoke that de-roled it. §8 Q7.

Whichever is chosen, keep the retired addresses **pinned** in `.inputs.yaml` with a state-mate
`hasRole(SYNC_ROLE, retired) == false` assertion (S1.7) so the revoke is continuously re-verified
rather than remembered.

## 7. Risks this route introduces or changes

| Risk | Bound / mitigation |
|---|---|
| **v1 keeps `SYNC_ROLE`** if S6 is skipped or silently no-ops → LOL Safe compromise re-reaches the automation domain, invalidating DOC.md §4.2.2(b) | Has-role assertions both sides of the revoke (§2.3); state-mate `false` row; the S6 gate |
| **Initial Owner is external** (`0xb5c336a5c60D3482b29d83C742C65AE8351b91a8`, DOC.md §6.4) and route R **adds** a required interaction with them | Sequence S6 before S10; if they stall, the v1 pair still holds `SYNC_ROLE` and remains the working (LOL-owned) automation — the lane is not stranded |
| **Address churn** — new per-lane addresses invalidate `.env`, `.deployed.yaml`, explorer verification, diffyscan artifacts, monitoring dashboards, and the "identical across lanes" claim in `docs/canary-deploy.md` | S1.13 + S4; treat `.deployed.yaml` as the only source of truth |
| **Single-key blast radius** on the automation domain (DOC.md §4.2.2(d)): forced syncs at ≥ 1-minute intervals up to the pool's whole WETH balance, plus the float | Unchanged by *how* we get to 4.2.B; ceiling is the ~0.5 ETH float per lane, no principal. The only attacker-proof stop is `revokeRole(SYNC_ROLE)` — §8 Q3 |
| **`renounceOwnership` is not overridden** on v2 either — the AO can freeze a mis-set config permanently | Inherited from 4.2.A; the answer stays "redeploy the pair", which this plan now has a rehearsed recipe for |
| **CRE credit + lifecycle move to the AO's CRE account** | §2.5, §8 Q5 |
| **Two live-looking receivers** on explorers per lane, one obsolete | D1 neutralization + docs table of retired addresses |
| **`finalize` has never run anywhere**, and S1.5 modifies the very function that performs the irreversible seal | S2 fork rehearsal of `finalize` on all four lanes is mandatory, not optional |

## 8. Questions to settle

Ordered by how much they change the work. Each states the default this plan assumes if unanswered.

**Q1 — Automation Owner key custody.** HSM, cloud KMS, or plain hot key? Rotation policy, who can
sign, and is a compromise detectable? *(DOC.md probe 1 — the largest term in the
compromise-exposure axis, and the one fact that would have settled the A-vs-B comparison.)*
**Default assumed:** a Lido-operated hot key on a single signer.

**Q2 — Measured LOL quorum latency.** How long has a Safe transaction actually taken to assemble?
*(probe 2)* This is what 4.2.B's latency case rests on, and it also decides whether route **T**
(§2.1) was the cheaper path after all. **Default assumed:** slow enough that avoiding Safe signatures
is worth the redeploy.

**Q3 — Is `revokeRole(SYNC_ROLE)` pre-authorized and rehearsed?** *(probe 3)* Under 4.2.B it is the
**only** switch a compromised AO key cannot re-open, and after S10 it is a DAO vote. If it is not
rehearsed with a known latency, 4.2.B's faster kill switches are partly illusory.
**Default assumed:** not rehearsed — flagged as an adoption precondition, not a blocker.

**Q4 — Has the `--unsigned` path actually caused friction?** *(probe 4)* It has never been exercised
(no workflow was ever registered), so this advantage of 4.2.B is currently **theoretical**.
**Default assumed:** ergonomics count as a real benefit.

**Q5 — CRE account, credits, and workflow lifecycle.** Is Lido content for `pause`/`activate`/
`delete`/update-WASM **and CRE credit administration** to sit under the Automation Owner EOA's CRE
account? Who tops up credits, and who is the break-glass contact if that account is unreachable?
**Default assumed:** yes, all of it moves to the AO.

**Q6 — Who funds the four 0.5 ETH floats, and from where?** The Deployer is short ~1.75 ETH across
lanes today (§S0.4). Funding is permissionless, so AO or LOL can do it directly.
**Default assumed:** top up the Deployer and keep using `fund-trigger`.

**Q7 — Retired-pair disposition: D0, D1, or D2?** (§6) Concretely: **keep the LOL-owned v1 trigger as
a de-roled cold spare, or renounce and close the door?**
**Default assumed:** D1 — neutralize, keep ownership.

**Q8 — One EOA for all four lanes, or one per lane?** One address keeps state-mate lane-invariant
(one `*l2AutomationOwner` anchor, one CRE account) but makes a single key compromise a four-lane
event. **Default assumed:** one EOA for all four lanes, matching the LOL Safe's shape.

**Q9 — Does the automation-only redeploy need its own review/audit pass?** The contracts are
byte-identical to what is live (§1.2), so the delta is entirely in `script/` + `config/` +
assertions. **Default assumed:** internal review of the S1 diff, no external audit round.

**Q10 — Is route T still open?** If the LOL Safe can sign 4 batched transactions this week, T reaches
the same end state with no address churn, no Initial-Owner interaction, and no retired pair (§2.1).
**Default assumed:** no — proceed with R as requested.

**Q11 — Should the v2 deploy be broadcast by the Automation Owner instead of the Deployer?** Then AO
owns the receiver from `msg.sender` with no in-broadcast transfer at all, at the cost of putting deploy
gas (and the deploy itself) on the hot key. **Default assumed:** the Deployer broadcasts; AO is passed
as `initialOwner` and receives the receiver in the same transaction.
