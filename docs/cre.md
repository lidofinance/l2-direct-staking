> **View — CRE workflow operations.** Stakeholder: CRE operator (workflow-owner Safe
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
  ├── Four CronCapability triggers (hourly, staggered at :00/:15/:30/:45)
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

**`writeGasLimit` is measured, not assumed.** `config.deploy.json` budgets **750 000** gas for the
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
| `cre-workflows/sync-automation/main.ts`                      | **The whole workflow, one file** (merged 2026-08-25 from `main`/`lanes`/`encoding`/`abi`): SyncTrigger ABI, the `lanes[]` config contract, the lane plan, the pure encoders, the per-lane handler and the entry. Everything above the handler section is runtime-free and driven directly by `bun test` |
| `cre-workflows/sync-automation/config.deploy.<network>.json` | Retained per-network configs used only while retiring the old registrations |
| `cre-workflows/sync-automation/config.deploy.json`           | **Consolidated** config for the single four-lane workflow: shared receiver/target/gas + one `lanes[]` entry per lane, hourly and staggered |
| `cre-workflows/sync-automation/config.simulate.json`         | Local simulation config                                              |
| `cre-workflows/project.yaml` · `sync-automation/workflow.yaml` | CLI targets: simulation, consolidated production, and retained retirement targets |
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
NETWORK=optimism just cre account list-key
```

The consolidated Safe is already linked. Do not use this wrapper to link it: `account link-key` signs
with the uploader EOA, so it would link that EOA rather than the Safe. Confirm the committed Safe with
`just cre-registry-status`; linking a replacement Safe requires calldata executed by that Safe.

**Environment — derived, not duplicated.** Never set a `CRE_*` variable by hand. The recipes source
[`script/shared/cre-env.sh`](../script/shared/cre-env.sh), which derives every spelling the CLI and
`project.yaml` want from the repo's canonical variables and aborts if they disagree:

| CLI / project.yaml wants | derived from | canonical home |
|---|---|---|
| `CRE_ETH_PRIVATE_KEY` | `L2_AUTOMATION_OWNER_PRIVATE_KEY` / `_PK`; authenticates artifact upload but does not own the unsigned registration | root `.env` |
| production `workflow-owner-address` | Test Automation Safe literal; the CLI does not interpolate owner fields | `cre-workflows/project.yaml` |
| `${L1_RPC_URL}` | `L1_RPC_URL` → `RPC_ETHEREUM_REMOTE` → `RPC_ETHEREUM` (fork proxy last) | root `.env` / environment |
| `${L2_<NET>_RPC_URL}` | explicit alias → `RPC_<NET>_REMOTE` | root `.env` / environment |

The shim checks the uploader key against `L2_AUTOMATION_OWNER`, exports all four live RPC aliases, and
never prints their URLs. The production target contains all four L2 RPCs because one workflow creates
four EVM clients. The old `production-<net>` targets remain only for pausing or deleting the retired
per-lane registrations.

Every workflow owner must be linked before registration (`isOwnerLinked` is checked at registration),
and registry transactions land on **Ethereum mainnet**, so the Safe executor needs mainnet ETH.
`cre account unlink-key` is destructive: it deletes every workflow associated with the address.

## Deployment

CREReceiver is deployed once per L2, but the CRE registration is shared. Deploy only after all four
receivers point `getExpectedAuthor()` at the Test Automation Safe:

1. Confirm the Safe is linked and has quota on `zone-a` with `just cre-registry-status`.
2. Run `just verify-constants-sync` and `just cre-workflow-hash`. The latter checks the byte-exact
   `config.deploy.json` and `main.ts` pins used by the dashboard.
3. Run `just deploy-cre-workflow`. It selects the shared `production` target, requires all four
   `RPC_<NET>_REMOTE` bindings, checks every receiver's author gate, uploads one build, and emits
   unsigned `WorkflowRegistry.upsertWorkflow` calldata for the Safe.
4. Run `just cre-attach-params`, paste the emitted upsert calldata, then paste the rewritten result into
   the dashboard's CRE Calldata tab. Execute that calldata from the Safe after every field passes.
5. Record the same workflow ID in each lane with `just record-cre-workflow-id <network> <workflow-id>`,
   then run `NETWORK=<network> just verify-cre-workflow` for all four lanes.

See [Per-call levers (DOC.md §3)](../DOC.md#3-access-control--ownership--the-final-state) for CREReceiver admin functions.

## Funding and billing

Two distinct concerns; the migration scripts touch neither, by design.

- **Owner gas (one-time, negligible).** Every `WorkflowRegistry` lifecycle transaction lands on Ethereum mainnet. The Test Automation Safe executes the unsigned calldata and pays that gas; the uploader key only authenticates the CLI artifact upload.
- **Workflow execution credits (ongoing).** CRE bills DON execution as opaque credits tracked on the [CRE dashboard](https://cre.chain.link/workflows), not as an on-chain LINK balance. Credits belong to the Test Automation Safe's CRE account. During Early Access, coordinate allocation with Chainlink and re-verify the model before GA.

Alert on the credit balance per [Monitoring & alerts §4](monitoring.md#4-cre-workflow-health--funding--high).

## CRE platform levers (workflow lifecycle)

The sync workflow is off-chain WASM; its only on-chain footprint is `WorkflowRegistry 2.0.0` on Ethereum mainnet (`0x4Ac5…E7e5`). The Test Automation Safe owns the consolidated registration, so every lifecycle action is a Safe transaction:

| Action | Caller | Effect |
|---|---|---|
| `cre workflow deploy --unsigned` | Test Automation Safe | Compile, upload, and emit `WorkflowRegistry` calldata; the Safe executes it |
| `cre workflow pause` / `activate` | Test Automation Safe | Stop / start DON execution |
| `cre workflow delete` | Test Automation Safe | Retire the workflow |
| `cre account link-key` / `unlink-key` | Test Automation Safe | Associate / disassociate the owner; unlinking also deletes its workflows |
| hourly lane tick | CRE DON | Runs one lane at :00/:15/:30/:45 and writes only when `shouldSyncAmount()` is nonzero and `canSync()` is true |

- The owner's EVM address (the **Safe address**) is propagated into every report as `metadata.workflowOwner` (bytes `[42:62]`); `CREReceiver._extractWorkflowOwner` reads it and, if `expectedAuthor != 0`, the two must match.
- The report's `workflowName`/`workflowId` are deliberately **not** checked — authentication is `(forwarder, workflowOwner)` only (an owner-scoped label adds no defence against owner compromise, and the argument-less call-lock already bounds the blast radius; see [DOC.md §2.6](../DOC.md#26-credibility--security-of-the-application-layer-contracts)).
- Updating the WASM under the same owner does **not** change `metadata.workflowOwner`, so `expectedAuthor` keeps accepting reports after a routine code update.
- Rotating a Safe signer without changing the Safe address needs no `setExpectedAuthor` re-pin and no workflow redeploy. Moving to a different owner address requires a new registration and four author re-pins.
- CRE-side pause is instant but depends on Chainlink infra; the authoritative kill switches are on-chain — `LOL → CREReceiver.setForwarder(0x…dead)` / `SyncTrigger.setForwarder(0x…dead)`, and the independent `GovExec → CustomSender.revokeRole(SYNC_ROLE, syncTrigger)`. Neither the CRE DON nor the Forwarder is controllable by this project.
- The pinned CRE Forwarder is the ERC-165-gating, 2-arg-`onReport(bytes,bytes)` "Router" build that `CREReceiver` speaks — **verified on-chain (all 4 lanes)**; re-check read-only with `just verify-cre-forwarder`. ⚠ It reports the *stale* `typeAndVersion` label `"KeystoneForwarder 1.0.0"` (not the legacy 3-arg `onReport(bytes32,address,bytes)` contract) — discriminate on the ABI/EXTCODEHASH, never the version string (see [audit-scope §B](audit-scope.md#b-delivery-integrity--forwarder--erc-165-gate)).

## Workflow-owner key — lost vs compromised (consequences & recovery)

The consolidated registration is owned by the Test Automation Safe
`0xede1750ac52156e10be2b41d8b8df816d58bafe1`. It currently has threshold 1 and one signer, so the Safe
address is stable but its present signer setup still has a single-key failure mode.

- Losing the signer does not stop an already active DON workflow, but it blocks pause, update, delete,
  credit administration, and signer rotation.
- Compromise gives the attacker those lifecycle controls. It does not bypass the receiver's forwarder,
  author, target, selector, or `SyncTrigger` amount/delay gates.
- Rotating the signer while the Safe remains controllable keeps the same workflow owner and needs no
  redeploy or author re-pin.
- Moving to a new owner requires a linked replacement owner, a new registration, and
  `setExpectedAuthor(newOwner)` on all four receivers. Use the independent GovExec
  `CustomSender.revokeRole(SYNC_ROLE, syncTrigger)` containment path before recovery if integrity is in
  doubt.
