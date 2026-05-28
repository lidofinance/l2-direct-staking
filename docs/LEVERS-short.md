## LEVERS — Short (ACL by Actor)

Who can call what after migration finalization. Grouped by actor; each actor's rights split into two threat tiers.

### Threat tiers

- **Core** — affect L1↔L2 trust roots, pool funds, upgrades, role management. Compromise puts user funds or bridge integrity at risk. Multisig/governance-controlled.
- **Sync automation** — control the automated cron-sync path (`SyncTrigger`, `CREReceiver`, off-chain CRE workflow). Compromise degrades automation (sync halts, miscalibrated thresholds, wrong forwarder) but funds are bounded:
  - `SYNC_ROLE` only gates `CustomSender.sync`, which routes through CCIP to the trusted `LidoCustomReceiver` (recoverable on L1).
  - `CREReceiver`'s allow-list is seeded with only `(SyncTrigger, triggerSync.selector)`; new pairs require the LOL multisig via `setAllowedCall`.
  - `SyncTrigger.setAmounts` caps per-sync amount.

See [`LEVERS.md`](LEVERS.md) for full per-contract tables and detailed notes.

### Contracts (by chain)

| Chain | Lido contracts                                                                            |
| ----- | ----------------------------------------------------------------------------------------- |
| L1    | `LidoCustomReceiver`, `ProxyAdmin`                                                        |
| L2    | `CustomSender`, `PausableImmutableOraclePool`, `SyncTrigger`, `CREReceiver`, `ProxyAdmin` |

External / off-chain actors referenced below: CCIP Router (Chainlink, per-chain), CRE Forwarder + CRE DON (Chainlink, off-chain), `WorkflowRegistry` (Ethereum Mainnet).

### Actors

| Identity                                      | Tier        | Scope                                       |
| --------------------------------------------- | ----------- | ------------------------------------------- |
| LidoDaoAgent                                  | Core        | L1 admin                                    |
| L2 Governance Executor                        | Core + Sync | L2 admin                                    |
| LOL multisig (Linea uses a separate multisig) | Core + Sync | Pool + `CREReceiver` owner (both L2)        |
| Lido Deployer (CRE workflow owner, off-chain) | Sync        | CRE workflow lifecycle                      |
| `SYNC_ROLE` holders on `CustomSender` (L2)    | Sync        | Triggers `CustomSender.sync`                |
| `CREReceiver` (L2)                            | Sync        | Triggers `SyncTrigger.triggerSync` (L2)     |
| CRE Forwarder (Chainlink infra)               | Sync        | Calls `CREReceiver.onReport` (L2)           |
| CRE DON (Chainlink infra)                     | Sync        | Executes WASM, signs reports                |
| `CustomSender` (L2, immutable on Pool)        | Core + Sync | Calls `Pool.swap` / `Pool.pull` (L2)        |
| CCIP Router (per-chain; here the L1 router)   | Core        | Calls `LidoCustomReceiver.ccipReceive` (L1) |
| Permissionless                                | Core + Sync | User-facing + top-up calls (L1 + L2)        |

---

### LidoDaoAgent (L1 admin)

*Lido DAO governance executor on L1. Holds `DEFAULT_ADMIN_ROLE` on `LidoCustomReceiver` and owns L1 `ProxyAdmin`.*

**Core**
- `ProxyAdmin.upgradeAndCall` — upgrade L1 proxies (incl. `LidoCustomReceiver`)
- `ProxyAdmin.transferOwnership / renounceOwnership` — transfer or renounce L1 `ProxyAdmin` ownership
- `LidoCustomReceiver.setSender(destChainSelector, sender)` — trusted source per chain
- `LidoCustomReceiver.setAdapter(destChainSelector, adapter)` — bridge adapter per chain
- `LidoCustomReceiver.recoverTokens(message, to)` — recover failed-message tokens
- `LidoCustomReceiver.grantRole / revokeRole` — manage AccessControl roles
- `LidoCustomReceiver.renounceRole(role, callerConfirmation)` — self-renounce a held role

### L2 Governance Executor (L2 admin)

*Lido governance bridge endpoint on each L2. Holds `DEFAULT_ADMIN_ROLE` on `CustomSender` and owns L2 `ProxyAdmin` + `SyncTrigger`.*

**Core**
- `ProxyAdmin.upgradeAndCall` — upgrade L2 proxies (incl. `CustomSender`)
- `ProxyAdmin.transferOwnership / renounceOwnership` — transfer or renounce L2 `ProxyAdmin` ownership
- `CustomSender.setOraclePool(pool)` — change pool used by fast stake / sync
- `CustomSender.setReceiver(destChainSelector, receiver)` — trusted destination per chain
- `CustomSender.grantRole / revokeRole` — manage `SYNC_ROLE`, `DEFAULT_ADMIN_ROLE`, etc.
- `CustomSender.renounceRole(role, callerConfirmation)` — self-renounce a held role

**Sync automation**
- `SyncTrigger.setForwarder(forwarder)` — authorized caller of `triggerSync` (kill switch: set to `0`)
- `SyncTrigger.setDelay(delay)` — min delay between sync runs
- `SyncTrigger.setAmounts(min, max)` — sync min/max thresholds
- `SyncTrigger.setFeeOtoD / setFeeDtoO` — CCIP fee configs
- `SyncTrigger.sweep(token, to, amount)` — withdraw `SyncTrigger`'s tokens / native gas balance
- `SyncTrigger.transferOwnership / renounceOwnership` — transfer or renounce `SyncTrigger` ownership

### LOL multisig (signs on L2)

*Lido on L2s operations multisig. Owns `PausableImmutableOraclePool` and `CREReceiver` on each L2.*

**Core**
- `PausableImmutableOraclePool.pause()` / `unpause()` — halts/resumes `swap` and `pull`
- `PausableImmutableOraclePool.sweep(token, to, amount)` — withdraw pool balances
- `PausableImmutableOraclePool.transferOwnership / renounceOwnership` — transfer or renounce pool ownership

**Sync automation**
- `CREReceiver.setForwarder(newForwarder)` — rotates CRE Forwarder (kill switch via reassignment)
- `CREReceiver.setExpectedAuthor(author)` — rotates pinned workflow author
- `CREReceiver.setAllowedCall(target, selector, allowed)` — manages `(target, selector)` allow-list
- `CREReceiver.withdrawETH(to, amount)` — rescues ETH from `CREReceiver`
- `CREReceiver.transferOwnership / renounceOwnership` — transfer or renounce `CREReceiver` ownership

### Lido Deployer (CRE workflow owner; off-chain)

*Off-chain identity (the CRE-platform account) that owns the sync workflow. Pinned on each L2 via `CREReceiver._expectedAuthor`; rotatable by the LOL multisig.*

**Sync automation** — on-chain footprint: `WorkflowRegistry` on Ethereum Mainnet (L1)
- Workflow lifecycle: register, replace WASM, pause, activate, delete
- Manage linked signing keys for the CRE account
- Read workflow metadata and runtime logs

### `SYNC_ROLE` holders (on L2 `CustomSender`)

*AccessControl role on `CustomSender` that gates `sync(...)`. Held by `SyncTrigger` by default; an EOA holder is possible but bounded by pool balance and the trusted CCIP path to `LidoCustomReceiver`.*

**Sync automation**
- `CustomSender.sync(destChainSelector, amount, feeOtoD, feeDtoO)` — pulls TOKEN from pool, sends CCIP sync message to L1 `LidoCustomReceiver`. When called via `SyncTrigger`, bounded by `SyncTrigger.setAmounts` cap.
- `CustomSender.renounceRole(SYNC_ROLE, callerConfirmation)` — drop SYNC_ROLE (e.g., when rotating to a new trigger)

### `CREReceiver` (L2)

*L2 contract that receives signed CRE workflow reports from the CRE Forwarder, enforces the workflow-author pin and the `(target, selector)` allow-list, and executes the call. Configured as `forwarder` on `SyncTrigger`, so its only allow-listed call is `SyncTrigger.triggerSync()`.*

**Sync automation**
- `SyncTrigger.triggerSync()` — executes sync when thresholds/time met

### CRE Forwarder (Chainlink off-chain)

*Chainlink-managed contract/identity that delivers signed CRE reports to consumer chains. Authorized as `forwarder` on each L2 `CREReceiver`; rotatable by the LOL multisig.*

**Sync automation** (acts on L2)
- `CREReceiver.onReport(metadata, report)` — author check + `(target, selector)` allow-list, then `target.call(data)`

### CRE DON (Chainlink off-chain)

*Chainlink Decentralized Oracle Network — the committee that runs the CRE workflow WASM on a cron tick and signs reports. Shared Chainlink infrastructure; not Lido-controlled.*

**Sync automation** (off-chain only)
- Runs WASM on cron tick (~5 min), signs report. Not user-controllable; cannot be triggered early.

### `CustomSender` (L2)

*L2 entry contract for `fastStake` / `fastStakeReferral` / `slowStake` and the sync flow. Immutably set as SENDER on `PausableImmutableOraclePool`; the only contract that can call the pool levers below.*

**Core**
- `PausableImmutableOraclePool.swap(recipient, amountIn, minOut)` — backs `fastStake` / `fastStakeReferral` user flows (`slowStake` bypasses the pool and goes straight to CCIP)

**Sync automation**
- `PausableImmutableOraclePool.pull(token, amount)` — backs `CustomSender.sync` flow

### CCIP Router (L1, when calling into receiver)

*Chainlink CCIP message dispatcher on L1. Configured in `LidoCustomReceiver` as the only authorized caller of `ccipReceive`; delivers verified cross-chain messages from CCIP after sender/adapter validation.*

**Core**
- `LidoCustomReceiver.ccipReceive(message)` — validates sender, processes or stores failure

### Permissionless

*Anyone — no role/owner check on these entry points.*

**Core**
- `CustomSender.slowStake / fastStake / fastStakeReferral` (L2) — user entry points
- `PausableImmutableOraclePool` (L2) — direct wstETH / WETH transfer adds liquidity (only the LOL multisig withdraws via `sweep`)
- `LidoCustomReceiver.retryFailedMessage(message)` (L1) — retries failed message by hash match

**Sync automation** (L2)
- `SyncTrigger.receive()` — funds CCIP fee balance
- `CREReceiver.receive()` — accepts ETH

---

### Invariants (post-migration)

**Core**
- `initialOwner` has no admin/owner rights on migrated contracts.
- `PausableImmutableOraclePool.setOracle()` and `setFee()` are permanently disabled (always revert). (L2)

**Sync automation** (all L2)
- `SyncTrigger` holds `SYNC_ROLE` on `CustomSender`.
- `CREReceiver` is the forwarder on `SyncTrigger`.
- `CREReceiver._expectedAuthor` is non-zero, pinned to the Lido Deployer's CRE workflow owner.
- `CREReceiver` allow-list is seeded with `(SyncTrigger, triggerSync.selector)`; new pairs require the LOL multisig.

### Kill switches

All authoritative actions below are on L2 (one tx per L2 chain).

| Tier | Threat                          | Authoritative on-chain action                                   | Actor                  |
|------|---------------------------------|-----------------------------------------------------------------|------------------------|
| Core | Pool drain / oracle issue       | `PausableImmutableOraclePool.pause()` (L2)                      | LOL multisig           |
| Sync | Compromised CRE workflow owner  | `CREReceiver.setExpectedAuthor(newAuthor)` on every L2          | LOL multisig           |
| Sync | CRE infra misbehaving           | `CREReceiver.setForwarder(newForwarder)` on every L2 (pin to a non-callable placeholder) | LOL multisig |
| Sync | `SyncTrigger` misconfigured     | `SyncTrigger.setForwarder(0)` or `setDelay(uint48 max)` (L2)    | L2 Governance Executor |
