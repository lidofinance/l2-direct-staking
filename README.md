# Lido L2 Direct Staking

Direct Staking on Optimism, Arbitrum, Base, and Linea exchanges users' ETH/WETH
for pool wstETH. A shared CRE workflow replenishes each pool by sending accumulated
WETH to Ethereum for Lido staking and bridging wstETH back.

The repository describes the configured system. Contract code and
`config/state/` define behavior and expected wiring; live validation establishes
whether a deployment satisfies those expectations.

## Documentation

| Document | Purpose |
| --- | --- |
| [Architecture](DOC.md) | Components, ownership, trust boundaries, and sync flow |
| [Operations](RUNBOOK.md) | Routine checks and incident response |
| [Liquidity provider](docs/runbook-liquidity-provider.md) | Pool funding, monitoring, and liquidity recovery |
| [CRE](docs/cre.md) | Workflow configuration, registration, funding, and recovery |
| [Fees](docs/fees.md) | Fee encoding, float, limits, and tuning |
| [Monitoring](docs/monitoring.md) | Signals, expected values, and responses |
| [Development](docs/development.md) | Setup, commands, tests, and validation limits |
| [Audit scope](docs/audit-scope.md) | Security boundaries and review checklist |
| [Compiler checks](docs/compiler-bug-exposure.md) | Build conditions and provenance checks |
| [Sync tracking](docs/sync-round-trip-and-finality.md) | Following a sync across CCIP and the return bridge |

## Development

Initialize submodules, install the tools in the [developer guide](docs/development.md),
and run:

```sh
forge build
forge test --match-contract '^(SyncTriggerTest|CREReceiverTest|CCIPForkRouterTest)$'
just test-cre-workflow
```

`just --list` lists the command interface. `site/` contains the monitoring dashboard.
