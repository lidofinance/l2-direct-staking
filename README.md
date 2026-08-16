# Goal

Migrate Direct Staking ownership, admin roles, and liquidity management to Lido governance across four L2 networks (Optimism, Arbitrum, Base, Linea), deploying new pool and sync infrastructure and replacing Chainlink Automation with CRE workflows.

**Networks:** Optimism, Arbitrum, Base, Linea — all sharing a single L1 Receiver on Ethereum (`0x6F357d53d6bE3238180316BA5F8f11467e164588`).

**Contracts mutated** (per network):
- **L1** (shared): `LidoCustomReceiver` — admin → Lido DAO Agent; `ProxyAdmin` — owner → Lido DAO Agent
- **L2**: `CustomSenderReferral` — admin → L2 Governance Executor, oracle pool swapped, legacy automation(s) revoked from `SYNC_ROLE`; `ProxyAdmin` — owner → L2 Governance Executor; old `OraclePool` — no longer wired into the sender, ownership unchanged: Initial Liquidity Owner `0x2897A1…b18c` retains full control via `sweep()` to settle pre-migration liquidity and any wstETH that lands from a sync round-trip in flight at the migration boundary (the round-trip's recipient pool is fixed at `sync()`-time and immutable thereafter, so in-flight wstETH lands in the **old** pool and is recovered by its owner via `sweep()` — see [`DOC.md` §5.1](DOC.md#51-in-flight-round-trips-are-correct-by-design)). Of the two pools, the LOL multisig owns the **new** one (not the old).

**Contracts deployed** (per network): new `OraclePool` — owned by the **LOL multisig**; `SyncTrigger`, `CREReceiver` — owned by a dedicated **Automation Owner** EOA in the target state ([`DOC.md` §4.2](DOC.md#42-diagram-b--ownership--access-control); LOL-owned on-chain today, transition in [`docs/automation-owner-redeploy.md`](docs/automation-owner-redeploy.md)). `SyncTrigger`'s `SYNC_ROLE` on `CustomSender` stays admin'd by the L2 Governance Executor either way.

# Documentation

The docs are **one multi-view set** over a single subject — the Lido CCIP
Direct-Staking system and its migration — split by **viewpoint** (who reads it,
for what), with **one canonical home per topic** (no duplication). Start with the
viewpoint that matches your task:

| Doc | Viewpoint — stakeholder · concern | Canonical content |
|---|---|---|
| **[RUNBOOK.md](RUNBOOK.md)** | Operator · the migration *recipe / run* | 3-phase checklist (pre-live checks → live run → post-migration validation) with gates `G1–G4`, duties, evidence, and the migration sequence diagram. |
| **[docs/runbook-liquidity-provider.md](docs/runbook-liquidity-provider.md)** | Liquidity provider (LOL Safe) · new-pool operations | Seed, monitor, top up, and recover wstETH liquidity on the new OraclePool — FPF-structured LP runbook with gates `LP-G0–G4`, duties, and sunset procedure. |
| **[DOC.md](DOC.md)** | Architect / reviewer · the *resulting state* | Networks, components & provenance, access control & ownership, diagrams, the sync operation, fee **rationale** (§5.2), migration safety notes. |
| **[docs/fees.md](docs/fees.md)** | Fee-tuning owner (LOL) · economics reference | The four fee quantities, byte layouts, the Glamsterdam headroom bump, and each bridge's refund/failure behavior. |
| **[docs/otod-fee-amount-sensitivity.md](docs/otod-fee-amount-sensitivity.md)** | Fee-tuning owner (LOL) · fee-vs-amount finding | Whether the OtoD fee scales with the bridged amount (yes on OP/Linea at 5 bps uncapped, flat on Arb/Base), how the 100 WETH cap contains it, and the `maxAmount`↔`maxFee` tuning coupling. |
| **[docs/cre.md](docs/cre.md)** | CRE operator · workflow lifecycle | CRE workflow setup / deploy / funding / levers + the workflow-owner lost-vs-compromised recovery procedure. |
| **[docs/mainnet-simulated-cre-test.md](docs/mainnet-simulated-cre-test.md)** | Migration operator · the canary deploy flow | The 5-state deploy machine (deployer-owned test → simulated CRE sync → handoff to LOL → governance seal) with per-actor transitions and the 1→0 rollback. |
| **[docs/automation-owner-redeploy.md](docs/automation-owner-redeploy.md)** | Migration owner · the automation-layer ownership change | Plan for reaching the [DOC.md §4.2](DOC.md#42-diagram-b--ownership--access-control) target by redeploying `SyncTrigger` + `CREReceiver` under a dedicated Automation Owner EOA: verified starting state (block-pinned), the redeploy-vs-transfer comparison, ordered stages S0–S10 with actors and gates, retired-pair disposal, and the open questions. Reproduce §1 with `just audit-ownership`. |
| **[docs/archive/ownership-lol-owned-automation.md](docs/archive/ownership-lol-owned-automation.md)** | Reviewer · the ownership option that lost | The retired arrangement (former DOC.md §4.2.A) in which the LOL Safe holds all four automation assignments: its diagram, the axis on which it still wins, the superseded `probe again` decision record with the four probes that were never run, and the unevaluated middle variant. Retired as a *target* on 2026-07-29 — still what the chain runs today. |
| **[docs/compiler-bug-exposure.md](docs/compiler-bug-exposure.md)** | Audit reviewer · known-`solc`-bug exposure | Whether the two `solc` bugs whose version windows include the pinned `0.8.34` (`InheritanceOrderReversalOnStorageEndWarning`, `UnsoundSpillInMutualRecursion`) can reach the deployed `SyncTrigger` / `CREReceiver`: **neither can** — each falsified by a machine-checked necessary condition, with the deployed bytecode proven to be this build. No recompile or redeploy warranted. Reproduce with `just verify-compiler-provenance`. |
| **[docs/development.md](docs/development.md)** | Developer · build / test / scripts | The direct `forge script` reference and the four test layers (unit / CRE / fork-integration / dress rehearsal). |
| **[docs/funds-snapshot-2026-07-28.md](docs/funds-snapshot-2026-07-28.md)** | Migration operator · block-pinned treasury snapshot | Deployer EOA / SyncTrigger fee float / new-OraclePool balances on L1 + all 4 lanes at 2026-07-28, what the zeros mean, and the funding actions implied. Reproduce with `just balances`. |
| **[docs/monitoring.md](docs/monitoring.md)** | On-call / SRE · post-migration alerts | The ongoing Signal · Expected · Severity→Response table once a network is live. |
| **[docs/dashboard-automation-tab.md](docs/dashboard-automation-tab.md)** | On-call / SRE · the dashboard's CRE view | Plan + claim set for the `Automation` tab of `index.html`: the three planes the CRE story splits into (registration record / author gate / delivery evidence) and why a green `ACTIVE` tile must never carry the lane verdict, each row classified L/A/D/E with its settling call, the browser-side limits (no DON heartbeat, artifact URLs are 403-gated, rejections leave no log), and the block-pinned 2026-08-16 starting state. Reproduce §1 with `just cre-registry-status`. |
| **[docs/adr/0001-…](docs/adr/0001-cre-workflow-owner-multisig.md)** | Decision record | Why the CRE workflow owner is the LOL multisig (Safe), the rejected EOA alternative, and the recovery primitive. |

> **Recipe ≠ run ≠ state.** [`RUNBOOK.md`](RUNBOOK.md) is the *recipe* (what an
> operator runs); the broadcast transactions are the *run*; [`DOC.md`](DOC.md)
> describes the *resulting state* (final ownership and roles). The four
> `docs/*.md` are the *reference* behind the recipe's values and checks — the
> *why*.

External references: [Chainlink CCIP Direct Staking quickstart](https://docs.chain.link/quickstarts/ccip-direct-staking) · [Chainlink Runtime Environment (CRE)](https://docs.chain.link/cre) ([deploying](https://docs.chain.link/cre/guides/operations/deploying-workflows) · [monitoring](https://docs.chain.link/cre/guides/operations/monitoring-workflows)) · [CRE `WorkflowRegistry`](https://etherscan.io/address/0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5) · [Direct Staking on Linea — Lido blog](https://blog.lido.fi/direct-staking-on-linea-powered-by-chainlink/)
