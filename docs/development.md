# Development

## Setup

Required tools: Foundry (`forge`, `cast`, `anvil`), `just`, Bun, Node/npm, `jq`,
and Mike Farah's `yq`. The configured Foundry runtime must support the
`amsterdam` hardfork. Compiler and EVM settings live in `foundry.toml`.

```sh
git submodule update --init --recursive
just setup
just setup-cre
forge build
```

`lib/` contains pinned dependencies. Do not treat dependency code as a second copy
of repository-owned contracts. `src/` owns SyncTrigger and CREReceiver;
`cre-workflows/sync-automation/main.ts` owns the workflow implementation.

## Environment

[Operations](../RUNBOOK.md#environment) describes dotenv and RPC bindings.
`script/shared/cre-env.sh` resolves aliases for tools. `just env-doctor` checks
resolution without displaying private keys. Direct shell-script invocations use
the exported environment; `just` also applies the configured dotenv files.

## Tests and consistency checks

```sh
# RPC-free Solidity suites
forge test --match-contract '^(SyncTriggerTest|CREReceiverTest|CCIPForkRouterTest)$'

# Workflow logic
just test-cre-workflow

# Configuration, ABI, and artifact consistency
just verify-constants-sync
just verify-abi-sync
just verify-externals-coverage
just cre-workflow-hash
```

| Layer | Entry point | What it checks |
| --- | --- | --- |
| Contract unit tests | `test/SyncTriggerTest.t.sol`, `test/CREReceiverTest.t.sol` | Guards, report decoding, fees, timing, and owner controls |
| Routing format guard | `test/CCIPForkRouterTest.t.sol` | Supported OnRamp versions and explicit rejection of unsupported formats |
| TypeScript tests | `just test-cre-workflow` | Lane planning and encoding |
| Pool fork suites | `test/*Pool.t.sol` | Pool behavior, role wiring, and sync through CCIP |
| CRE integration | `just test-cre-integration` | Forwarder → receiver → trigger path on forks |
| Fork behavior | `just test-forks [network]` | Pool and CRE behavior for one or all lanes |
| State-mate | `just verify-<network>-state [rpc_url]` | RPC state against configured expectations |

Fork suites need `L1_RPC_URL` and the relevant
`L2_{OPTIMISM,ARBITRUM,BASE,LINEA}_RPC_URL` values. Run them against local forks
when available. `forge test` runs the complete Solidity suite, including forks.
Use `forge test --list` for the current test inventory rather than a fixed test count.

## Configuration and fork fixtures

`script/<network>/*Constants.sol` defines lane identities and sync parameters.
Test-only fee float is defined in `PoolTests.sol`; production funding follows
the [fee guide](fees.md#funding-the-float). The corresponding `*Config.s.sol` builds
encoded fee values for `just verify-constants-sync`; it does not broadcast transactions.

`test/helpers/PoolTestBase.sol` deploys current pool, SyncTrigger, and CREReceiver
sources on forks, using distinct liquidity and automation owners. The configured
governance executor wires the fixture through the existing CustomSender.
The fixtures require the configured L1 and L2 governance authorities to be active.
They check source behavior against forked dependencies; state-mate checks the
configured deployed instances.

```sh
just test-forks           # All four lanes
just test-forks optimism # One lane
NETWORK=optimism just verify-optimism-state
```

The fork runner resolves RPCs from the lane overlay, Foundry aliases, or machine
bindings. It requires no signing keys and changes only fork state. State checks
use their explicit RPC argument or environment bindings.

Long shell recipes belong in `script/commands/`; shared helpers belong in
`script/shared/`. Use multiline functions and conditionals, two-space indentation,
and comments that explain RPC precedence or transaction constraints.

## Validation limits

The CCIP routing helper decodes OnRamp 1.5.x and 1.6.x events. It rejects other
versions explicitly; routing tests require a supported fork or a helper updated
for the upstream event format. Gas baselines and budget assertions remain active
when upstream behavior changes.

Fork tests and simulations establish behavior only for their configured state,
RPC block, and execution engine. A successful local simulation does not establish
CRE registration, account credit, DON delivery, or native-bridge finality.

`just measure-fee-gas` uses the real adapter path, but its fixed 1.25 gas projection
is a planning bound, not proof of hardfork gas-schedule conformance. Test actual
execution and nested-call headroom under the intended runtime before changing
fee budgets. Acceptance of `--hardfork amsterdam` alone does not establish that
the installed engine implements the required gas schedule.

`just cre-workflow-hash` checks the dashboard's byte-exact config and source pins.
Even a comment change to `main.ts` changes the source digest. Keep registered
artifact identity distinct from repository source identity.

[Compiler checks](compiler-bug-exposure.md) describe the local build conditions
and the scope of deployed metadata comparison.
