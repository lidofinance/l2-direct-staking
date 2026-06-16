# ADR-0001 — CRE workflow owner is the LOL multisig (Safe), not an EOA

- **Status:** Accepted — 2026-06-04
- **Scope:** The on-chain owner of the `sync-automation` CRE workflow on Chainlink
  `WorkflowRegistry 2.0.0` (`0x4Ac5…E7e5`, Ethereum mainnet) and, in lock-step, the
  `CREReceiver._expectedAuthor` pin on each of the four L2s (Optimism, Arbitrum, Base, Linea).
- **Related:** [DOC.md §3.2](../../DOC.md) (owners/actors), [DOC.md §3.4](../../DOC.md) (kill switches),
  [README "Workflow-owner key"](../../README.md) and [README "make the workflow owner a multisig (Safe)"](../../README.md),
  [RUNBOOK.md](../../RUNBOOK.md) (deploy + recover).

## Context

The sync workflow is off-chain WASM on Chainlink's CRE platform. Its only on-chain footprint is a
record in `WorkflowRegistry 2.0.0`, which holds no funds. The DON propagates the workflow owner's EVM
address into every signed report as `metadata.workflowOwner`; each L2 `CREReceiver` re-checks it against
a pinned `_expectedAuthor`. So the **workflow owner** and the **`expectedAuthor` pin must be the same
address** for the path to be live.

Two facts make the *choice of owner* load-bearing:

1. **The owner is fixed at registration and not transferable.** `WorkflowRegistry 2.0.0` exposes **no
   per-workflow ownership-transfer function**. Whatever account is recorded at `cre workflow deploy` time
   owns the workflow for its life. Changing it requires deploying a *new* workflow and re-pinning
   `setExpectedAuthor` on all four L2s (the "redeploy + re-pin" primitive below).
2. **The owner key does not sign reports.** The DON signs; the owner address only travels as metadata.
   A key incident therefore does not, by itself, stop an already-`ACTIVE` workflow — but it does control
   the workflow *lifecycle* (`deploy` / `pause` / `activate` / `delete` / update-WASM / `link-key`) and is
   the CRE-account credential through which **CRE credit** allocation is administered.

The blast radius of owner-key *misuse* is bounded by the CREReceiver's three gates (forwarder +
`expectedAuthor` + `(target, selector)` allow-list), the argument-less call-lock, and `SyncTrigger`'s
on-chain amount/delay re-check: the worst an owner can force is an *already-admissible, rate-limited,
nullary* `triggerSync()` — **no fund extraction, no recipient change, no arbitrary calldata**
([DOC.md §2.6](../../DOC.md)). The risk that remains is therefore **availability** (lose the key →
eventually lose pause/patch/credit control) and **integrity of lifecycle control** (compromise → DoS via
`pause`/`delete`), not value at risk.

The strict distinctions that frame the decision (A.7): the failure kinds **lost** (availability) ≠
**compromised** (integrity); and the key's hats — **workflow owner** ≠ **`expectedAuthor` pin** ≠
**Stage-1 broadcast signer** — must not be conflated.

## Decision

**Register the `sync-automation` workflow under the LOL multisig (Safe) — the same Safe that already owns
each `CREReceiver` — and pin `expectedAuthor` to that Safe address on all four L2s.**

- The Stage-1 deploy scripts pin `CREReceiver._expectedAuthor = cfg.liquidityOwner` (the LOL multisig),
  *not* the Lido Deployer EOA (`script/shared/L2UpgradeScriptBase.s.sol::_deployAll`).
- The workflow is registered with `cre workflow deploy … --unsigned`
  (`workflow-owner-address: ${CRE_WORKFLOW_OWNER}` in `cre-workflows/project.yaml`,
  `CRE_WORKFLOW_OWNER` = the network's LOL multisig). `--unsigned` makes the CLI emit raw
  `WorkflowRegistry` calldata, which is **executed from the Safe**, so the Safe address becomes the
  on-chain owner. A throwaway `CRE_ETH_PRIVATE_KEY` is still needed for RPC-client init but **never signs**
  the owner transaction.
- The Lido Deployer EOA keeps a single, smaller hat: it broadcasts the Stage-1 contract deploy and funds
  the SyncTrigger float. Post-migration it holds **zero on-chain power** over Lido contracts and is **not**
  the workflow owner.

End-state invariant (asserted by tests, monitored in production): for each L2,
`WorkflowRegistry.owner == CREReceiver.getExpectedAuthor() == CREReceiver.owner() == LOL multisig`.

We use the **LOL Safe** (not a *separate* dedicated Safe). Across the candidate set {shared Stage-1 EOA ·
dedicated cold EOA · LOL Safe · dedicated Safe} the comparator is *loss/compromise resilience* ×
*update latency* × *trust-domain separation* (A.19 / G.5 — stated, not scalarized). The two EOA options
are dominated on resilience. LOL Safe and dedicated Safe are **incomparable** (operational simplicity vs a
cleaner separation of "who is the author" from "who re-pins the author"). Given the near-zero on-chain blast
radius and that the authoritative kill switches were *already* LOL-Safe actions, the marginal value of a
separate Safe over the LOL Safe is low — so we pick the LOL Safe.

## Consequences

**Positive**

- The single-EOA loss/compromise vector is removed. A lost or compromised *signer* key is handled by
  **rotating that signer inside the Safe** (`addOwner` / `swapOwner` / `removeOwner`). The workflow-owner
  address (the Safe) never changes, so **no redeploy and no `setExpectedAuthor` re-pin**. The "irreplaceable
  registry binding" problem evaporates: you no longer need an ownership transfer.
- You lose the workflow only by losing ≥ threshold Safe signers at once — the same event that already loses
  every other LOL-held lever (`OraclePool.pause`, `CREReceiver.setForwarder(0x…dead)`, `setExpectedAuthor`).
  The risk folds into one already accepted everywhere else.
- No standby cold CRE key / minutes-MTTR pre-staging is required (those existed only to soften the EOA cliff).

**Negative / costs**

- Routine workflow changes (WASM bug-fix, cron tweak) become m-of-n Safe ceremonies, not one-key pushes —
  workflow updates move at governance pace. Bounded: the urgent kill switches were already Safe actions, so
  only non-urgent, infrequent code updates slow down.
- Concentration: the LOL Safe is both "the author" and "who re-pins the author." The independent
  **GovExec backstop** (`CustomSender.revokeRole(SYNC_ROLE, syncTrigger)`) stays in a *different* trust domain
  and can dark-out the path without LOL quorum, so a separate dedicated Safe is not warranted here — but the
  concentration is noted.

**Residuals to confirm before relying on it** (CRE is Early Access — test on a throwaway testnet workflow
first): (a) that the **Safe address is what the DON embeds as `metadata.workflowOwner`** so
`expectedAuthor = Safe` actually matches (the multi-sig guide implies but does not state it); (b) the auth
model of the **off-chain artifact upload** under `--unsigned` (on-chain owner is the Safe; the binary/config
uploader may be the throwaway EOA); (c) per-lane DON / Forwarder compatibility.
Refs: [CRE multi-sig guide](https://docs.chain.link/cre/guides/operations/using-multisig-wallets),
[deploying workflows](https://docs.chain.link/cre/guides/operations/deploying-workflows).

> **Why (a) is the critical one — and the contingency if it's false.** The author gate compares the
> DON-embedded `metadata.workflowOwner` against the pinned `expectedAuthor`. That embedded value is a
> *different surface* from the `WorkflowRegistry.owner` field — so `verify-cre-workflow` (which reads the
> registry owner) can be green while the DON still embeds a different address. If residual (a) is false,
> pinning `expectedAuthor = Safe` makes **every report fail `InvalidAuthor` and all syncs silently stall**.
> The only proof the gate passes is a live `CREReceiver.CallExecuted` (RUNBOOK gate **G2-author**); exercise
> it on testnet before mainnet. **Contingency:** if the DON turns out to embed the `--unsigned` artifact
> uploader (residual (b)) rather than the Safe, the system still works — but `expectedAuthor` must then be
> set to *that* uploader address via `LOL setExpectedAuthor(...)`, not the Safe. In that case the
> author-identity and the workflow-*ownership* identity diverge: ownership/lifecycle stays with the Safe
> (`WorkflowRegistry.owner`), while the author pin tracks whatever the DON embeds. Decide the uploader's
> custody accordingly before relying on it.

## Alternatives considered

### A. Single EOA owner (the rejected baseline — what it looks like)

Deploy the workflow under one EOA (either the **shared Stage-1 deployer key**, or a **dedicated cold key**
backed up via hardware / MPC / Shamir). This is what the project previously documented. It is rejected, but
recorded here in full because it is the fallback if the Safe residuals above fail to hold, and because an
already-EOA-owned workflow can only be moved to a Safe by running the "redeploy + re-pin" primitive once.

**Lost vs compromised (single EOA).**

| Dimension | Key **lost** (gone, no adversary) | Key **compromised** (adversary holds it) |
|---|---|---|
| Failure kind (A.7) | availability | integrity |
| Running sync *now* | unaffected — DON keeps executing the `ACTIVE` workflow; `expectedAuthor` still matches | unaffected on funds — attacker can at most fire already-admissible, rate-limited `triggerSync()` |
| Worst the holder can do | nothing (key is gone) | DoS: `pause`/`delete` → syncs stop; burn the EOA's ETH + CRE credits; spam *admissible* syncs (still ≤2/day/lane) |
| Protocol funds at risk | no | no |
| In-place fix? | no — registry has no ownership transfer | no — same |
| Recovery hinge | LOL `setExpectedAuthor(new)` ×4 + redeploy workflow | LOL `setForwarder(0x…dead)` to contain, then `setExpectedAuthor(new)` ×4 + redeploy |
| Authority needed | LOL multisig only — *no DAO / GovExec motion* | LOL multisig (GovExec backstop available) |
| Urgency | low → medium (credit runway / next change) | high — contain now |

**Recovery primitive — "redeploy + re-pin" (shared by both EOA scenarios; also the one-time EOA→Safe move).**

| # | Duty — role *SHALL* | Gate / Evidence |
|---|---|---|
| R1 | Lido ops provision a *new* owner (for EOA→Safe: the LOL Safe via `--unsigned`); `cre workflow deploy` a fresh workflow → new `metadata.workflowOwner`; capture `CRE_WORKFLOW_ID` | — |
| R2 | *(gate before R3)* `verify-cre-workflow` → status `ACTIVE`, owner = new author | `VerifyCREWorkflow` 3-assert read. Do **not** re-pin to a not-yet-live author |
| R3 | LOL multisig `setExpectedAuthor(newOwner)` on **all 4** L2 `CREReceiver`s | Monitoring §1: `getExpectedAuthor` = new on all 4 + `ExpectedAuthorUpdated` ×4 |
| R4 | Lido ops re-baseline `.env`, the pinned-author constant, and the `config/state/l2-<net>.inputs.yaml` siblings in lock-step | state-mate §1/§4 green against the new author |

R3 needs **only the LOL multisig** — not a DAO / Aragon / GovExec motion. That is the payoff of the
`expectedAuthor` indirection: recovery never touches value-path governance. Adopting the Safe owner from the
start (this ADR) makes the *signer-loss* case never reach this primitive at all — only a catastrophic
whole-Safe compromise does, which is already the protocol-wide worst case.

Why rejected: both EOA variants are dominated on loss/compromise resilience by a Safe owner, at no benefit
the Safe lacks (the EOA's only edge — one-key-fast updates — is exactly the property a Safe trades away on
purpose). The dedicated-cold-EOA variant narrows the *shared-key* exposure but still has a single point of
failure for an irrecoverable binding.

### B. Dedicated (non-LOL) Safe

A separate Safe, distinct from the LOL Safe, owns the workflow. Keeps "who is the author" independent from
"who re-pins the author" / owns the CREReceiver, preserving the two-domain separation of
[DOC.md §2.7](../../DOC.md). Incomparable to the LOL Safe on the comparator (separation vs simplicity).
Rejected for *this* credential because the on-chain blast radius is near-zero and the GovExec backstop
already provides an independent kill switch, so the marginal value of a second Safe is low. Revisit if the
workflow ever gains broader authority.
