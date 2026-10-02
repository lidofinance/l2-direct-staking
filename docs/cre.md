# CRE Workflow Operations

One `direct-staking-sync` workflow serves all four lanes. The Automation Multisig owns
the workflow and the L2 automation contracts. [Architecture](../DOC.md#ownership-and-access-control)
defines the identities and permissions.

## Configuration

| File | Purpose |
| --- | --- |
| `cre-workflows/project.yaml` | RPC bindings and production workflow owner |
| `cre-workflows/sync-automation/workflow.yaml` | Production and simulation targets |
| `cre-workflows/sync-automation/main.ts` | ABI, lane planning, report encoding, handler, and entrypoint |
| `cre-workflows/sync-automation/config.deploy.json` | Four hourly staggered lanes and shared call parameters |
| `cre-workflows/sync-automation/config.simulate.json` | Local simulation parameters |

The workflow reads `shouldSyncAmount()` and `canSync()`. Due and executable lanes
produce an argument-less `triggerSync()` report; blocked lanes are logged and
skipped. L2 contract checks still apply when the report arrives.

`writeGasLimit` is 750,000 in the configuration and is checked against the
`CRE_WRITE_GAS_LIMIT` test constant by `just verify-constants-sync`.
`test_creWriteGasCarrier` measures the receiver-to-sync path on each lane. It does
not include the forwarder's report/signature verification; retain headroom for
that work. The separate baseline regression check and budget check serve different
purposes. See [development](development.md#validation-limits).

## Setup

```sh
just setup-cre
just setup-cre-cli
just test-cre-workflow
just cre login
```

Bun installs the workflow SDK; the CLI is a separate binary. `setup-cre-cli`
installs the pinned release from `justfile`, verifies its checksum, and writes
under the ignored `.cre/` directory. `just cre …` runs from the project root and
resolves environment aliases through `script/shared/cre-env.sh`.

The CLI upload key authenticates artifact upload. It is not the production
workflow owner. The production target uses an explicit Safe owner and unsigned
registry calldata.

## Registration

1. Confirm the Automation Multisig is linked and has workflow quota on `zone-a` with
   `just cre-registry-status`.
2. Check all lane addresses in `config.deploy.json`. The shared target and receiver
   must match every lane. Run `just verify-constants-sync` and `just cre-workflow-hash`.
3. Run `just deploy-cre-workflow`. It requires all four RPC bindings, checks the
   receivers' expected authors, uploads the build, and emits unsigned
   `WorkflowRegistry.upsertWorkflow` calldata for the Safe.
4. Run `just cre-attach-params`, paste the calldata, and review the rewritten result
   in the dashboard's CRE Calldata tab. Execute it from the Automation Multisig.
5. Record the workflow ID with `just record-cre-workflow-id <workflow-id>` and run
   `NETWORK=<network> just verify-cre-workflow` on every lane.
6. Observe live `CallExecuted` and a complete sync round trip before relying on
   registration status as an operational signal.

The workflow ID depends on the compiled binary, configuration, and registration
identity. Preserve the ID actually returned by registration. Source/config hashes
in registration attributes identify artifacts; a locally rebuilt binary is not
assumed to reproduce the registered ID. The dashboard distinguishes repository
source from registered source.

## Funding and lifecycle

Maintain three separate budgets: Safe transaction gas, CRE account credit, and
L2 SyncTrigger ETH float. Credit is checked through the CRE service/account;
`just balances` does not establish that the workflow has execution credit.

Use `just cre workflow --help` with the pinned CLI for lifecycle commands, selecting
`--target=production` for this workflow. Review Safe calldata before execution.
Pausing a workflow affects scheduling; it does not revoke on-chain SYNC_ROLE or
remove the receiver's allowed call.

## Recovery

If delivery stops, compare registry ownership/linkage/status with each receiver's
expected author, configured forwarder, and allowed call. An ACTIVE record and a
matching owner do not prove successful delivery. Check live execution events and
service credit separately.

For a lost Safe signer, recover signing access through the Safe's remaining quorum
where possible. If control of the owning Safe is unavailable, governance can
replace the automation infrastructure and reassign SYNC_ROLE. The pool remains
under the LOL Safe's separate control.

For compromised automation control, contain the incident through governance's
SYNC_ROLE revocation or the LOL Safe's pool pause. Rotating only the workflow
author is insufficient when the attacker also controls the receiver owner and
can change it back. Re-establish trusted contract ownership, report permissions,
and workflow registration before resuming. See [operations](../RUNBOOK.md).
