## Who controls what after the migration

After the migration finalizes, control of the Lido-on-L2 stack is split across **five actor identities** plus a few automated paths. No single actor can drain the pool, change trust roots, or upgrade contracts on their own.

### The five actors

#### 1. Lido DAO Agent (on Ethereum)

Everything on the **L1 receiver** that bridges wstETH back from each L2 answers to the DAO:

- Upgrade the L1 contract.
- Point the L1 receiver at a different trusted L2 sender or a different bridge adapter.
- Recover any wstETH stuck in a failed cross-chain message.
- Grant/revoke admin roles on the L1 receiver.

#### 2. L2 Governance Executor (one per L2)

The on-chain endpoint of Lido governance on each L2 (Optimism / Arbitrum / Base / Linea). It's how a DAO vote on mainnet ends up touching contracts on the L2. It owns:

- **Upgrades**: the L2 ProxyAdmin — can swap implementations of the L2 contracts (`CustomSender`, etc.).
- **Trust roots**: switching the on-chain pool contract that backs fast-staking, or the L1 destination receiver.
- **Sync tuning**: minimum / maximum sync size, delay between syncs, CCIP fee parameters.
- **Admin roles** on `CustomSender` (including `SYNC_ROLE`).

#### 3. LOL multisig — Lido on L2 (operational, on each L2)

 It owns:

- **The new pool** (`PausableImmutableOraclePool`): can **pause** swap+pull, **unpause**, and **sweep** liquidity out.
- **The CRE receiver** (the contract that accepts cron-triggered sync reports): can rotate its trusted CRE forwarder, rotate the pinned workflow author, edit the (target, selector) allow-list, and rescue any ETH sent to it by mistake.

The new pool is the funded contract on each L2.

NB: Linea uses a different multisig than Optimism / Arbitrum / Base.

#### 4. Lido Deployer (CRE workflow owner; off-chain)

An off-chain Chainlink CRE account, not a Lido multisig. It controls **only the off-chain WASM workflow** that calls "trigger sync" on a 5-minute cron (`0 */5 * * * *`, set in `cre-workflows/sync-automation/config.deploy.<net>.json`):

- Register / replace / pause / activate / delete the workflow.
- Associate / disassociate wallet addresses with the CRE account (`cre account link-key` / `unlink-key`).

It has no on-chain authority. If this key is compromised, the LOL multisig can rotate its on-chain pin (`setExpectedAuthor`) on each L2 and lock the old workflow out.

**Can this role be transferred to a different EVM address?** No — not in-place. The Chainlink `WorkflowRegistry 2.0.0` deployed at `0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5` on Ethereum Mainnet exposes no workflow-ownership-transfer function: `transferWorkflowOwnership`, `setWorkflowOwner`, `changeWorkflowOwner`, `setOwner`, `reassignWorkflow`, and `updateWorkflow(...,address)` are all absent from the deployed bytecode. (The `transferOwnership(address)` present on the registry is the registry's own contract-admin lever, owned by Chainlink, not per-workflow.) A workflow's owner is set at `upsertWorkflow` time and propagated into every signed report as `metadata.workflowOwner` — that field is the basis for the `_expectedAuthor` check on each L2 `CREReceiver`.

Rotation therefore requires a co-ordinated swap, not a transfer:

1. The **new** key registers a new workflow under its own CRE account (`cre workflow deploy`).
2. The **LOL multisig** calls `CREReceiver.setExpectedAuthor(newOwner)` on each of the four L2s.
3. The **old** key pauses / deletes the previous workflow (`cre workflow pause` / `delete`).

Linked wallets (`cre account link-key`) do **not** substitute for re-deploying. They associate additional EVM addresses with the CRE account (the registry tracks this via `isOwnerLinked(address)`), but `metadata.workflowOwner` in each signed report is captured when `upsertWorkflow` runs and is unchanged by later link/unlink — that field is what `_expectedAuthor` is matched against, so linking cannot redirect the author check to a different address.

#### 5. Initial Liquidity Owner (legacy, on each L2 — old pool only)

Same address on all four L2s (`0x2897A1…b18c`). Owns the **old** `OraclePool` on each chain. The migration deliberately leaves this ownership untouched, because:

- The old pool may still hold pre-migration **WETH** (the Initial Liquidity Owner's seed inventory) plus **wstETH** that lands there from any sync round-trip that was in flight when Stage 2 ran (correct-by-design — the new pool isn't yet wired into in-flight messages, so they settle into the old pool).
- The Initial Liquidity Owner can call `sweep(token, recipient, amount)` to recover both at their convenience.

No other power: the old pool is no longer wired into `CustomSender`, no longer receives syncs, no longer takes user fast-stake swaps. It's an orphan, on purpose, until the Initial Liquidity Owner sweeps it dry. Once swept, this actor has nothing left to do.

### The automatic parts (no actor in the loop)

- **`SyncTrigger`** — *L2 contract that gates each sync by amount range, a min delay, and a single authorized forwarder.* Holds `SYNC_ROLE` on `CustomSender` and is the only thing that calls `CustomSender.sync(...)`.
- **`CREReceiver`** — *L2 contract that accepts signed CRE reports, validates the workflow author and the (target, selector) allow-list, then executes the call.* Set as the forwarder on `SyncTrigger` — the only contract allowed to call `triggerSync()`. Its allow-list at deploy is exactly one entry: `(SyncTrigger, triggerSync)`. Anything else has to be added by the LOL multisig.
- **Chainlink CRE DON** — *Off-chain Chainlink-operated committee that runs the workflow WASM on its cron tick and signs each report.* Shared Chainlink infrastructure; not Lido-controlled and not triggerable early.
- **Chainlink CRE Forwarder** — *Chainlink-managed L2 contract that delivers the DON's signed reports to consumer contracts like `CREReceiver`.* Authorized per-`CREReceiver` via `setForwarder`; rotatable by the LOL multisig but the underlying contract is Chainlink's.
- **CCIP Router** — *Chainlink's cross-chain message dispatcher; the L1 router is the only authorized caller of `LidoCustomReceiver.ccipReceive(...)`.* All sync messages from any L2 land on L1 through it.

### What anyone can do (permissionless)

- **Stake**: `fastStake`, `fastStakeReferral`, `slowStake` on `CustomSender`.
- **Add liquidity** to the new pool: send WETH or wstETH straight to it (only the LOL multisig can ever sweep it out).
- **Retry a failed bridge message** on L1 (input must hash-match the original failure).
- **Top up the sync fee balance** (send ETH to `SyncTrigger` or `CREReceiver`).

### Emergency stops (one transaction each, on every L2)

| Problem                                  | What to do                                                       | Actor                  |
| ---------------------------------------- | ---------------------------------------------------------------- | ---------------------- |
| Something off with the new pool / oracle | Pause the pool                                                   | LOL multisig           |
| Suspected CRE workflow key compromise    | `CREReceiver.setExpectedAuthor(newAuthor)`                       | LOL multisig           |
| CRE infrastructure misbehaving           | `CREReceiver.setForwarder(<dead address>)`                       | LOL multisig           |
| `SyncTrigger` misconfigured              | `SyncTrigger.setForwarder(0)` *or* `setDelay(max)`               | L2 Governance Executor |

These are **authoritative on-chain switches** — they work even if Chainlink CRE is down or the off-chain workflow is acting up. The new-pool pause directly halts `swap` and `pull` on the funded pool.

### What the initial deployer can no longer do

After migration finalizes, the `initialOwner` (the address that broadcast Stage 1) has **no admin or owner rights on any migrated contract**. All authority has moved to one of the five actors above.

### Permanently disabled

The new pool has two functions — `setOracle()` and `setFee()` — that always revert. By design: the migration locks in the oracle and the zero-fee policy and no actor can change them, ever. Changing oracle or fee would require deploying a new pool and pointing `CustomSender.setOraclePool(...)` at it (an L2 Governance Executor action).
