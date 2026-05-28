# Documentation

Root [`README.md`](../README.md) is the technical runbook. Companion docs in this directory:

- [`OPS-PLAN.md`](./OPS-PLAN.md) — migration operations plan (sequence, actors, commands, safe-to-abort checkpoints, monitoring)
- [`concise-ops-plan.md`](./concise-ops-plan.md) — TL;DR per-actor command sequence (one-screen reference)
- [`runbook.md`](./runbook.md) — actor-centric bash command reference, copy-pasteable per stage
- [`alerts-spec.md`](./alerts-spec.md) — post-migration monitoring specification (signals + severities)
- [`LEVERS.md`](./LEVERS.md) — state-mutating calls, who can invoke each (on-chain + CRE workflow)
- [`LEVERS-short.md`](./LEVERS-short.md) — condensed actor-grouped view of the same levers (TL;DR companion to `LEVERS.md`)
- [`FLOW.md`](./FLOW.md) — fast-stake and sync flow diagrams
- [`sync-fees.md`](./sync-fees.md) — `_feeOtoD` / `_feeDtoO` deep-dive: entities, contracts, byte layouts, refund mechanics, failure modes, EIP-7904/8038 implications
- [`deploy-params.md`](./deploy-params.md) — single-stop reference: compile-time constants, per-stage env vars, CRE workflow params, state-mate pinning, mainnet/Sepolia differences
- [`deploy-params-shorter.md`](./deploy-params-shorter.md) — table-format TL;DR of the same constants (one-screen reference)
- [`optimism-pool-upgrade.md`](./optimism-pool-upgrade.md) — Optimism-specific upgrade notes
- [`TESTING.md`](./TESTING.md) — fork-test setup, CCIP-local walkthrough, and per-network anvil-fork dress rehearsal

## External references

- [Chainlink CCIP Direct Staking quickstart](https://docs.chain.link/quickstarts/ccip-direct-staking)
- [Chainlink Runtime Environment (CRE)](https://docs.chain.link/cre) · [Deploying Workflows](https://docs.chain.link/cre/guides/operations/deploying-workflows) · [Monitoring Workflows](https://docs.chain.link/cre/guides/operations/monitoring-workflows)
- [CRE `WorkflowRegistry` on Ethereum Mainnet](https://etherscan.io/address/0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5)
- [Direct Staking on Linea — Lido blog](https://blog.lido.fi/direct-staking-on-linea-powered-by-chainlink/)
