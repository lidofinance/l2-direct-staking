# Documentation

Index of all project documentation. Root [`README.md`](../README.md) remains the technical runbook; everything below is a companion.

## Migration operators

- [`ops_plan.md`](./ops_plan.md) — end-to-end operations plan (roles, gates, per-stage runbook, mid-migration incident response)
- [`TESTNET.md`](./TESTNET.md) — Sepolia rehearsal procedure
- [`optimism-pool-upgrade.md`](./optimism-pool-upgrade.md) — Optimism-specific upgrade notes

## Governance and authority

- [`LEVERS.md`](./LEVERS.md) — state-mutating calls, who can invoke each, on-chain and off-chain (incl. CRE workflow)
- [`FLOW.md`](./FLOW.md) — fast-stake and sync flow diagrams

## Security and risk

- [`SECURITY.md`](./SECURITY.md) — security risk analysis, invariants, mitigation roadmap
- [`report-4.7.md`](./report-4.7.md) — full security + operational review, including the 38-alert monitoring runbook

## Architecture and rationale

- [`cre-guide.html`](./cre-guide.html) — interactive explainer for CRE architecture (open in a browser)
- [`CRE-in-place-of-CLA.md`](./CRE-in-place-of-CLA.md) — original CLA→CRE migration planning doc (superseded in places by the current runbook; kept for history)
- [`report.md`](./report.md) — fee-parameter reference (FeeOtoD / FeeDtoO encoding across networks)

## Testing

- [`TESTING.md`](./TESTING.md) — fork-test setup and CCIP-local walkthrough

## External references

- [Chainlink CCIP Direct Staking quickstart](https://docs.chain.link/quickstarts/ccip-direct-staking)
- [Chainlink Runtime Environment (CRE) — docs](https://docs.chain.link/cre)
- [CRE — Deploying Workflows](https://docs.chain.link/cre/guides/operations/deploying-workflows)
- [CRE — Monitoring Workflows](https://docs.chain.link/cre/guides/operations/monitoring-workflows)
- [CRE `WorkflowRegistry` on Ethereum Mainnet](https://etherscan.io/address/0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5)
- [Direct Staking on Linea — Lido blog](https://blog.lido.fi/direct-staking-on-linea-powered-by-chainlink/)
