> **View — CRE workflow operations.** Stakeholder: CRE operator (LOL multisig
> signer / ops). Concern: the off-chain workflow lifecycle — setup, deploy,
> funding & billing, platform levers, and the **canonical** workflow-owner
> lost-vs-compromised recovery procedure. [`RUNBOOK.md` §Recover](../RUNBOOK.md)
> keeps the action checklist and [`DOC.md` §3.4](../DOC.md#34-what-the-project-still-controls-if-chainlink-misbehaves)
> keeps the kill-switch table; both tether here and to
> [ADR-0001](adr/0001-cre-workflow-owner-multisig.md). Doc map:
> [`README.md` §Documentation](../README.md#documentation).

# CRE Workflow (replaces Chainlink Automation)

Pool rebalancing is triggered by a CRE (Chainlink Runtime Environment) TypeScript workflow instead of Chainlink Automation (CLA). The workflow runs on Chainlink's Decentralized Oracle Network (DON) as compiled WASM.

## Architecture

```
CRE DON (TypeScript/WASM, off-chain)
  ├── CronCapability trigger (hourly, on the hour)
  ├── EVMClient.callContract() → SyncTrigger.shouldSyncAmount() (due? amount?) + canSync() (executable?)
  ├── If due && executable:
  │   ├── Encode triggerSync() calldata
  │   ├── Wrap in abi.encode(target, data) for CREReceiver
  │   ├── runtime.report() → sign with ECDSA/Keccak256
  │   └── EVMClient.writeReport() → CRE Forwarder
  ├── Else if due (but !executable): log "blocked" (float/SYNC_ROLE/pause) — skip, no report
  │
CRE Forwarder (on-chain; verifies signatures, ERC-165-gates the receiver)
  └── CREReceiver.onReport(metadata, report)
      └── SyncTrigger.triggerSync()
          └── CustomSender.sync() → CCIP → L1
```

**`writeGasLimit` is measured, not assumed.** `config.deploy.<net>.json` budgets **750 000** gas for the
delivered write (the last three lines above). The carrier is
`test_creWriteGasCarrier` in `test/helpers/PoolUpgradeTests.sol` — reproduce it per lane with
`forge test --match-contract <Lane>PoolUpgradeTest --match-test test_creWriteGasCarrier -vv`. Measured
2026-07-29 on mainnet forks: **Optimism 304 753 · Arbitrum 339 193 · Base 312 903 · Linea 318 392**. Those
are lower bounds — they start at `CREReceiver.onReport`, so the Forwarder's own report/signature
verification (inside the DON's transaction, outside this repo) is not counted; the ×1.25 repricing
projection on the worst lane is ~424 k, which is why 500 000 was raised to 750 000. `just
verify-constants-sync` pins every config's `writeGasLimit` to the constant the test asserts against, so
a bump cannot silently outrun its evidence.

Two independent checks guard it, deliberately: a **regression tripwire** against each lane's recorded
baseline (`CRE_WRITE_GAS_BASELINE`, set per lane in `test/helpers/<Lane>UpgradeTestBase.sol`, tolerance
+35 %), and a **budget-adequacy** floor at 80 % of `writeGasLimit`. Only the first catches our own code
getting more expensive: headroom sized for the forwarder's verification and future repricing would
otherwise absorb a real regression unnoticed. Re-measure and update the baseline when a change to
`SyncTrigger`/`CREReceiver`/the CCIP path legitimately moves the number. An under-budget write is the worst failure shape available:
the report is delivered, the write reverts out of gas, no `CallExecuted` is emitted, and it looks exactly
like a credit outage or a wrong author pin.

## Files

| Path                                                         | Purpose                                                              |
| ------------------------------------------------------------ | -------------------------------------------------------------------- |
| `src/cre/CREReceiver.sol`                                    | On-chain receiver — decodes reports and calls target contracts       |
| `src/cre/interfaces/IReceiver.sol`                           | CRE receiver interface                                               |
| `cre-workflows/sync-automation/main.ts`                      | CRE workflow entry point                                             |
| `cre-workflows/sync-automation/encoding.ts`                  | Pure encoding/decoding helpers (testable outside WASM)               |
| `cre-workflows/sync-automation/abi.ts`                       | SyncTrigger ABI definitions                                          |
| `cre-workflows/sync-automation/config.deploy.<network>.json` | Per-network production config, named by that lane's `production-<net>` target |
| `cre-workflows/sync-automation/config.simulate.json`         | Local simulation config                                              |
| `cre-workflows/project.yaml` · `sync-automation/workflow.yaml` | CLI targets: `simulate-settings` + one `production-<net>` per lane  |
| `script/shared/cre-env.sh`                                   | Derives `CRE_ETH_PRIVATE_KEY` / `CRE_WORKFLOW_OWNER` / RPC names from the canonical vars |

## Setup

```sh
# Install CRE workflow dependencies (requires Bun on PATH)
just setup-cre

# Install the pinned `cre` CLI into the repo-local, gitignored .cre/bin/
just setup-cre-cli

# Run TypeScript tests
just test-cre-workflow
```

Two distinct installs. `just setup-cre` only runs `bun install` for `@chainlink/cre-sdk`, which
provides `cre-compile` / `cre-setup` — **not** the `cre` CLI. The CLI is a separate Go binary
(`smartcontractkit/cre-cli`); there is no npm package for it. `just setup-cre-cli` downloads the
release pinned by the `CRE_CLI_VERSION` variable at the top of the `justfile`, verifies it against the
release's `checksums.txt`, and installs it to `.cre/bin/cre` inside the repo (gitignored). It is
idempotent, needs no `sudo`, and — unlike Chainlink's `curl … install.sh | bash` one-liner — writes
nothing to `$HOME` and does not edit your shell rc. Bump the CLI by editing `CRE_CLI_VERSION` and
re-running the recipe.

Run every CLI command through the `just cre …` wrapper, which resolves that binary (falling back to a
`cre` on `PATH`) and executes from `cre-workflows/` — the directory holding `project.yaml`, which
`cre login`, `cre account …` and `cre workflow …` all require as their working directory:

```sh
just cre login                  # browser auth; stores its session under $HOME
just cre account access         # deploy-access / Early-Access status
NETWORK=optimism just cre account link-key -l lido-automation-owner
NETWORK=optimism just cre account list-key
```

**Environment — derived, not duplicated.** Never set a `CRE_*` variable by hand. The recipes source
[`script/shared/cre-env.sh`](../script/shared/cre-env.sh), which derives every spelling the CLI and
`project.yaml` want from the repo's canonical variables and aborts if they disagree:

| CLI / project.yaml wants | derived from | canonical home |
|---|---|---|
| `CRE_ETH_PRIVATE_KEY` | `L2_AUTOMATION_OWNER_PRIVATE_KEY` / `_PK` (same order `_envAutomationOwnerPrivateKey()` uses) | root `.env` |
| `CRE_WORKFLOW_OWNER` | `L2_AUTOMATION_OWNER` | root `.env` |
| `${L1_RPC_URL}` | `L1_RPC_URL` → `RPC_ETHEREUM_REMOTE` → `RPC_ETHEREUM` (fork proxy last) | `.env.<network>` |
| `${L2_RPC_URL}` | `L2_RPC_URL` | `.env.<network>` |

Before anything runs, the shim checks that the AO key actually signs as `L2_AUTOMATION_OWNER` — the
duplicate `CRE_ETH_PRIVATE_KEY` this replaced could silently drift from it on a rotation. `just
env-doctor` shows the whole resolved picture, including the on-chain `getExpectedAuthor()` comparison.
The CLI's own `-e/--env` flag is therefore unnecessary (it reads exported variables); pass it yourself
if you want it to load a file anyway.

**Per-lane targets.** `production-optimism` / `-arbitrum` / `-base` / `-linea` in both
`cre-workflows/project.yaml` (chain-name + RPCs + owner) and `sync-automation/workflow.yaml`
(`workflow-name: lido-sync-automation-<net>` + its `config.deploy.<net>.json`).
`deploy-cre-workflow` selects one from `L2_NETWORK`, so the lane cannot be mixed up by a stray
`--config`, and the four lanes cannot collide on a single registered workflow name under one owner.

**Two prerequisites for `link-key`.** It must be run once per workflow owner before any workflow can
be registered (`isOwnerLinked` is checked at registration), and it always submits a transaction on
**Ethereum mainnet** regardless of the workflow's target chain — so the Automation Owner needs mainnet
ETH for gas, not just L2 gas. `cre account unlink-key` is destructive: it deletes every workflow
associated with the address.

## Deployment

CREReceiver is deployed per L2 network as part of the canary deploy (`deploy-test` / `runDeployTest`): it is deployed before the `SyncTrigger`, which is then constructed with `forwarder = CREReceiver`, and the receiver's allow-list is seeded with the trigger via `setAllowedCall` once it has code. During the canary the receiver's `expectedAuthor` is pinned to the **Lido Deployer** so the deployer can drive a test sync; `handoff` re-pins it to the **LOL multisig** — the Safe that also owns the CREReceiver, the SyncTrigger, and the CRE workflow, **not** the Lido Deployer EOA (see [ADR-0001](adr/0001-cre-workflow-owner-multisig.md)). Workflow deployment (owned by the LOL Safe) therefore happens **after `handoff`**, once `expectedAuthor` is the Safe:

1. Link the owner once: `just cre login` → `just -E .env.<network> cre account link-key -l lido-automation-owner` (mainnet tx; `isOwnerLinked` is checked at registration).
2. Rewrite `config.deploy.<network>.json` with the deployed addresses — `just -E .env.<network> update-cre-config`.
3. Register the workflow **owned by the Automation Owner**: `just -E .env.<network> deploy-cre-workflow`. It selects `--target=production-<network>`, derives owner + key from the canonical variables, aborts unless the owner equals the on-chain `CREReceiver.getExpectedAuthor()`, and the AO **signs the `WorkflowRegistry` transaction itself**. For a multi-sig owner instead, set `CRE_DEPLOY_UNSIGNED=true` and execute the emitted calldata from the Safe.
4. Repeat for each network (Optimism, Arbitrum, Base, Linea) — each gets its own workflow name.
5. Persist the returned content-derived ID with
   `just record-cre-workflow-id <network> <workflow-id>`, then verify the registered identity,
   owner, and `ACTIVE` status with `just -E .env.<network> verify-cre-workflow`.

> ⚠ The narrative below (and in [ADR-0001](adr/0001-cre-workflow-owner-multisig.md)) still describes the
> **LOL Safe** as workflow owner — superseded by [DOC.md §4.2](../DOC.md#42-diagram-b--ownership--access-control)
> (Automation Owner). Rewriting it is [S1.12/S1.13](automation-owner-redeploy.md) work, not done here;
> the recipes and the steps above are authoritative for *how* to deploy.

See [Per-call levers (DOC.md §3)](../DOC.md#3-access-control--ownership--the-final-state) for CREReceiver admin functions.

## Funding and billing

Two distinct concerns; the migration scripts touch neither, by design.

- **Owner gas (one-time, negligible).** Every `WorkflowRegistry` transaction (`cre account link-key`, `cre workflow deploy` / `pause` / `activate` / `delete`) lands on **Ethereum mainnet** — sub-cent gas per call. On the signed path the **Automation Owner** pays it and signs, so that EOA needs mainnet ETH (its L2 gas is a separate matter); on the `CRE_DEPLOY_UNSIGNED=true` path the relaying multi-sig signer pays instead and the CLI's key only initialises the RPC client. No L2 balance required either way.
- **Workflow execution credits (ongoing).** CRE bills DON execution as opaque "CRE credits" tracked on the [CRE dashboard](https://cre.chain.link/workflows), not as a LINK-funded on-chain balance. The CRE CLI exposes **no** `fund` / `deposit` / `withdraw` / `balance` commands. Credits are administered against the **workflow owner's CRE account — i.e. the LOL Safe**, not any EOA. During Early Access (verified April 2026), credit allocation is administrative — coordinate with Chainlink when the dashboard balance approaches the agreed threshold. Re-verify before GA.

Alert on the credit balance per [Monitoring & alerts §4](monitoring.md#4-cre-workflow-health--funding--high).

## CRE platform levers (workflow lifecycle)

The sync workflow is off-chain WASM on Chainlink's CRE platform; its only on-chain footprint is `WorkflowRegistry 2.0.0` (Ethereum mainnet, `0x4Ac5…E7e5`), which holds no funds. The workflow is **owned by the LOL multisig (Safe)** — registered with `cre workflow deploy --unsigned` and the emitted calldata executed *from the Safe* (ADR-0001). Every lifecycle action is therefore a Safe transaction:

| Action | Caller | Effect |
|---|---|---|
| `cre workflow deploy --unsigned` | LOL Safe (m-of-n) | Compile + emit `WorkflowRegistry` calldata; the Safe executes it (or `upsertWorkflow` on re-deploy with same name) |
| `cre workflow pause` / `activate` | LOL Safe (m-of-n) | Stop / start DON execution |
| `cre workflow delete` | LOL Safe (m-of-n) | Retire the workflow |
| `cre account link-key` / `unlink-key` | LOL Safe (m-of-n) | Associate / disassociate a wallet (owner-gated) |
| cron tick (hourly) | CRE DON | Runs the WASM; signs a report only if `shouldSyncAmount()` (amount/delay) is nonzero AND `canSync()` (float, `SYNC_ROLE`, pool-pause) is true; skips a due-but-blocked tick (`shouldSyncAmount() > 0 && !canSync()`) without a report |

- The owner's EVM address (the **Safe address**) is propagated into every report as `metadata.workflowOwner` (bytes `[42:62]`); `CREReceiver._extractWorkflowOwner` reads it and, if `expectedAuthor != 0`, the two must match.
- The report's `workflowName`/`workflowId` are deliberately **not** checked — authentication is `(forwarder, workflowOwner)` only (an owner-scoped label adds no defence against owner compromise, and the argument-less call-lock already bounds the blast radius; see [DOC.md §2.6](../DOC.md#26-credibility--security-of-the-application-layer-contracts)).
- Updating the WASM under the same owner does **not** change `metadata.workflowOwner`, so `expectedAuthor` keeps accepting reports after a routine code update.
- **Rotating a Safe *signer*** (`addOwner` / `swapOwner` / `removeOwner`) does **not** change the Safe address, so it needs **no** `setExpectedAuthor` re-pin and **no** redeploy. Only changing the workflow owner *to a different address* would require `setExpectedAuthor` ×4 — and with a Safe owner that is never needed except in the catastrophic whole-Safe-compromise case ([Workflow-owner key](#workflow-owner-key--lost-vs-compromised-consequences--recovery)).
- CRE-side pause is instant but depends on Chainlink infra; the authoritative kill switches are on-chain — `LOL → CREReceiver.setForwarder(0x…dead)` / `SyncTrigger.setForwarder(0x…dead)`, and the independent `GovExec → CustomSender.revokeRole(SYNC_ROLE, syncTrigger)`. Neither the CRE DON nor the Forwarder is controllable by this project.
- The pinned CRE Forwarder is the ERC-165-gating, 2-arg-`onReport(bytes,bytes)` "Router" build that `CREReceiver` speaks — **verified on-chain (all 4 lanes)**; re-check read-only with `just verify-cre-forwarder`. ⚠ It reports the *stale* `typeAndVersion` label `"KeystoneForwarder 1.0.0"` (not the legacy 3-arg `onReport(bytes32,address,bytes)` contract) — discriminate on the ABI/EXTCODEHASH, never the version string (see [audit-scope §B](audit-scope.md#b-delivery-integrity--forwarder--erc-165-gate)).

## Workflow-owner key — lost vs compromised (consequences & recovery)

The CRE workflow owner is the **LOL multisig (Safe)** — the same Safe that owns each `CREReceiver` and is pinned as its `expectedAuthor` ([ADR-0001](adr/0001-cre-workflow-owner-multisig.md), [DOC.md §3.2](../DOC.md#32-owners--actors-and-what-they-hold)). Registering the workflow under the Safe (`cre workflow deploy --unsigned`, calldata executed from the Safe) makes the owner **a stable address whose control is a rotatable signer set**, dissolving the single-EOA "irreplaceable admin" problem the EOA design carried. Two roles stay distinct (A.7):

1. **CRE workflow owner = `expectedAuthor` = CREReceiver owner.** All three are the **LOL Safe address**, baked into every signed report as `metadata.workflowOwner` (`[42:62]`). `WorkflowRegistry 2.0.0` (`0x4Ac5…E7e5`) still exposes **no per-workflow ownership-transfer function**, but you no longer need one: control is the Safe's **signer set**, rotatable without touching the registry binding.
2. **Stage-1 signer / float-funder (the Lido Deployer EOA).** Migration-only, and **not** the workflow owner. Post-migration it holds **zero on-chain power** over Lido contracts; state-mate asserts `hasRole = false` for this hot key everywhere ([DOC.md §6.3](../DOC.md#63-how-the-final-state-is-verified)).

The owner does **not** sign reports — the **DON** signs, and the Safe address only travels as metadata — so an owner incident does not by itself stop an already-`ACTIVE` workflow. Owner authority is workflow *lifecycle* (`deploy` / `pause` / `activate` / `delete` / update-WASM / `link-key`, each now an m-of-n Safe transaction) plus CRE-credit administration ([Funding and billing](#funding-and-billing)). Misuse is bounded to "fire an already-admissible, rate-limited, nullary `triggerSync()`" by the three gates + argument-less call-lock and `SyncTrigger`'s on-chain amount/delay re-check ([DOC.md §2.6](../DOC.md#26-credibility--security-of-the-application-layer-contracts)) — **no fund extraction, no recipient change, no arbitrary calldata.**

### Failure modes at a glance (Safe owner)

| Scenario | What happens | Fix | Authority / urgency |
|---|---|---|---|
| **One Safe signer key lost** (below threshold) | Nothing operationally — the Safe still meets quorum; the DON keeps executing the `ACTIVE` workflow; `expectedAuthor` (the Safe address) still matches | `removeOwner` / `swapOwner` inside the Safe — **no redeploy, no `setExpectedAuthor` re-pin** (the Safe address is unchanged) | LOL Safe only; low urgency |
| **One Safe signer key compromised** (below threshold) | Funds unaffected; attacker holds *one* signer, below quorum, so cannot move the Safe | `swapOwner` / `removeOwner` to evict the signer inside the Safe — no redeploy, no re-pin | LOL Safe only; medium — evict promptly |
| **Whole Safe compromised** (≥ threshold signers at once) | The same catastrophic event that already loses **every** LOL-held lever (`OraclePool.pause`, `setForwarder`, `setExpectedAuthor`). Funds still bounded by the on-chain gates + GovExec backstop | **Contain** via GovExec `CustomSender.revokeRole(SYNC_ROLE, syncTrigger)` (independent trust domain), then the one-time **"redeploy + re-pin"** primitive under a *new* Safe | GovExec backstop + new Safe; **high** |

The first two rows are the everyday cases and need **no** CRE redeploy and **no** on-chain re-pin — that is the whole point of a Safe owner (a stable address, rotatable signers). Only the third reaches the registry binding, and it coincides with the protocol-wide worst case already accepted everywhere LOL holds power.

**Procedures and rationale (single home — ADR-0001, not duplicated here):**

- **Everyday signer rotation** (signer lost/compromised below threshold) — `swapOwner` / `removeOwner` / `addOwner` inside the Safe; the Safe address is unchanged, so no CRE redeploy and no `setExpectedAuthor` re-pin, and the running workflow is never interrupted. Operator steps: [RUNBOOK → Recover](../RUNBOOK.md).
- **Whole-Safe compromise + the "redeploy + re-pin" primitive** (R1–R4 with Duty / Gate / Evidence), the GovExec containment backstop, and the **rejected single-EOA alternative** with its full lost-vs-compromised tables and the A.19 / G.5 comparator: **[ADR-0001](adr/0001-cre-workflow-owner-multisig.md)**. Contain first from the independent domain (GovExec `CustomSender.revokeRole(SYNC_ROLE, syncTrigger)`, [§3.4](../DOC.md#34-what-the-project-still-controls-if-chainlink-misbehaves)), then redeploy under a new Safe and re-arm `setExpectedAuthor` last.
- **Pre-incident hardening** — Safe threshold + diverse signer custody (so losing ≥ threshold at once is implausible), and confirm the Early-Access residuals — especially that the DON embeds the **Safe address** as `metadata.workflowOwner` so `expectedAuthor = Safe` matches: [ADR-0001 "Residuals"](adr/0001-cre-workflow-owner-multisig.md) and RUNBOOK gate G2-author.
