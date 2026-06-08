# Goal

Migrate Direct Staking ownership, admin roles, and liquidity management to Lido governance across four L2 networks (Optimism, Arbitrum, Base, Linea), deploying new pool and sync infrastructure and replacing Chainlink Automation with CRE workflows.

**Networks:** Optimism, Arbitrum, Base, Linea — all sharing a single L1 Receiver on Ethereum (`0x6F357d53d6bE3238180316BA5F8f11467e164588`).

**Contracts mutated** (per network):
- **L1** (shared): `LidoCustomReceiver` — admin → Lido DAO Agent; `ProxyAdmin` — owner → Lido DAO Agent
- **L2**: `CustomSenderReferral` — admin → L2 Governance Executor, oracle pool swapped, legacy automation(s) revoked from `SYNC_ROLE`; `ProxyAdmin` — owner → L2 Governance Executor; old `OraclePool` — no longer wired into the sender, ownership unchanged: Initial Liquidity Owner `0x2897A1…b18c` retains full control via `sweep()` to settle pre-migration liquidity and any wstETH that lands from a sync round-trip in flight at the migration boundary (the round-trip's recipient pool is fixed at `sync()`-time and immutable thereafter, so in-flight wstETH lands in the **old** pool and is recovered by its owner via `sweep()` — see [`DOC.md` §5.1](DOC.md#51-in-flight-round-trips-are-correct-by-design)). LOL multisig owns only the **new** pool.

**Contracts deployed** (per network): new `OraclePool`, `SyncTrigger`, `CREReceiver`

# Documentation

The docs are **one multi-view set** over a single subject — the Lido CCIP
Direct-Staking system and its migration — split by **viewpoint** (who reads it,
for what), with **one canonical home per topic** (no duplication). Start with the
viewpoint that matches your task:

| Doc | Viewpoint — stakeholder · concern | Canonical content |
|---|---|---|
| **[RUNBOOK.md](RUNBOOK.md)** | Operator · the migration *recipe / run* | 3-phase checklist (pre-live checks → live run → post-migration validation) with gates `G1–G4`, duties, evidence, and the migration sequence diagram. |
| **[DOC.md](DOC.md)** | Architect / reviewer · the *resulting state* | Networks, components & provenance, access control & ownership, diagrams, the sync operation, fee **rationale** (§5.2), migration safety notes. |
| **[docs/fees.md](docs/fees.md)** | Fee-tuning governance · economics reference | The four fee quantities, byte layouts, the Glamsterdam headroom bump, and each bridge's refund/failure behavior. |
| **[docs/cre.md](docs/cre.md)** | CRE operator · workflow lifecycle | CRE workflow setup / deploy / funding / levers + the workflow-owner lost-vs-compromised recovery procedure. |
| **[docs/development.md](docs/development.md)** | Developer · build / test / scripts | The direct `forge script` reference and the four test layers (unit / CRE / fork-integration / dress rehearsal). |
| **[docs/monitoring.md](docs/monitoring.md)** | On-call / SRE · post-migration alerts | The ongoing Signal · Expected · Severity→Response table once a network is live. |
| **[docs/adr/0001-…](docs/adr/0001-cre-workflow-owner-multisig.md)** | Decision record | Why the CRE workflow owner is the LOL multisig (Safe), the rejected EOA alternative, and the recovery primitive. |

> **Recipe ≠ run ≠ state.** [`RUNBOOK.md`](RUNBOOK.md) is the *recipe* (what an
> operator runs); the broadcast transactions are the *run*; [`DOC.md`](DOC.md)
> describes the *resulting state* (final ownership and roles). The four
> `docs/*.md` are the *reference* behind the recipe's values and checks — the
> *why*.

**FPF note.** The doc set is one `U.MultiViewDescribing` family (E.17.0): each
file declares a single viewpoint (MVD-1), each claim has exactly one canonical
home (E.11) and is **referred** to elsewhere rather than restated (A.10 /
A.6.3.CR), and the table above is the family's CorrespondenceModel (MVD-4).
Within RUNBOOK, gates `G1–G4` read as A.6.B admissibility predicates and the
"recipe ≠ run ≠ state" spine is A.7 (Object ≠ Description ≠ Work).

External references: [Chainlink CCIP Direct Staking quickstart](https://docs.chain.link/quickstarts/ccip-direct-staking) · [Chainlink Runtime Environment (CRE)](https://docs.chain.link/cre) ([deploying](https://docs.chain.link/cre/guides/operations/deploying-workflows) · [monitoring](https://docs.chain.link/cre/guides/operations/monitoring-workflows)) · [CRE `WorkflowRegistry`](https://etherscan.io/address/0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5) · [Direct Staking on Linea — Lido blog](https://blog.lido.fi/direct-staking-on-linea-powered-by-chainlink/)
