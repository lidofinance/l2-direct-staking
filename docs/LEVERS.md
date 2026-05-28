# LEVERS (Post-Migration)

State-mutating contract calls ("levers") and who can invoke them after migration finalization.

## Assumed Post-Migration State

- **L2 Governance Executor** — owner/admin on L2 governance surfaces (`CustomSender` admin role, `SyncTrigger` owner, L2 `ProxyAdmin` owner).
- **LOL multisig** — owner of `PausableImmutableOraclePool` and `CREReceiver`. Linea uses a different multisig than Optimism/Arbitrum/Base (see [`README.md`](../README.md)).
- **LidoDaoAgent** — owner/admin on L1 control surfaces (`LidoCustomReceiver` admin role, L1 `ProxyAdmin` owner).
- **Lido Deployer** — off-chain CRE workflow owner; controls the workflow registered on the Chainlink CRE platform.
- `SyncTrigger` has `SYNC_ROLE` on `CustomSender`.
- `CREReceiver` is configured as the forwarder on `SyncTrigger`.
- `CREReceiver._expectedAuthor` is pinned to the Lido Deployer's CRE workflow-owner address at construction and cannot be set to `address(0)`.
- `CREReceiver` allow-list is seeded at construction with `(SyncTrigger, triggerSync.selector)`; any other `(target, selector)` pair must be added explicitly by the LOL multisig via `setAllowedCall`.
- `initialOwner` no longer has admin/owner rights on migrated contracts.

## Actor Legend

| Short   | Full Name              | Context                                             |
|---------|------------------------|-----------------------------------------------------|
| GovExec | L2 Governance Executor | `DEFAULT_ADMIN_ROLE` on `CustomSender`, owner of `SyncTrigger` and L2 `ProxyAdmin` |
| LOL     | LOL multisig           | Owner of `PausableImmutableOraclePool` and `CREReceiver` |
| DAO     | LidoDaoAgent           | `DEFAULT_ADMIN_ROLE` on `LidoCustomReceiver`, owner of L1 `ProxyAdmin` |
| LidoDep | Lido Deployer          | Stage 1 contract deployer; also CRE workflow owner (off-chain identity on the Chainlink CRE platform) |
| Sender  | `CustomSender`         | Immutably set as SENDER on `PausableImmutableOraclePool` |
| Sync    | `SYNC_ROLE` holders    | `SyncTrigger` by default                            |
| CREFwd  | CRE Forwarder          | Authorized on `CREReceiver`                         |
| CRERx   | `CREReceiver`          | Set as forwarder on `SyncTrigger`                   |
| CREDon  | CRE DON                | Chainlink committee that executes the workflow WASM and signs reports |
| Router  | CCIP Router            | Configured in `LidoCustomReceiver`                  |
| Any     | Any account            | Permissionless                                      |

---

## L2

### `CustomSender`

| Lever                                                         | GovExec | Sync | Any | Effect                                              |
|---------------------------------------------------------------|:-------:|:----:|:---:|-----------------------------------------------------|
| `sync(destChainSelector, amount, feeOtoD, feeDtoO)`           |         |  x   |     | Pulls TOKEN from pool, sends CCIP sync message      |
| `setOraclePool(oraclePool)`                                   |    x    |      |     | Changes pool used by fast stake / sync              |
| `setReceiver(destChainSelector, receiver)`                    |    x    |      |     | Changes trusted destination receiver per chain      |
| `grantRole(role, account)` / `revokeRole(role, account)`      |    x    |      |     | Manages AccessControl roles (SYNC_ROLE, admin, ...) |
| `slowStake(destChainSelector, token, amount, feeOtoD, feeDtoO)` |       |      |  x  | Starts slow-stake CCIP flow                         |
| `fastStake(token, amount, minAmountOut)`                      |         |      |  x  | Instant swap via pool; emits `FastStake`            |
| `fastStakeReferral(token, amount, minAmountOut, referral)`    |         |      |  x  | Same as `fastStake` + `Referral` event              |

### `PausableImmutableOraclePool`

| Lever                                   | LOL | Sender | Any | Effect                                            |
|-----------------------------------------|:---:|:------:|:---:|---------------------------------------------------|
| `swap(recipient, amountIn, minAmountOut)` |   |   x    |     | Swaps TOKEN_IN for TOKEN_OUT at oracle price      |
| `pull(token, amount)`                   |     |   x    |     | Pulls TOKEN_IN from pool to `CustomSender`        |
| `pause()`                               |  x  |        |     | Pauses `swap` and `pull`                          |
| `unpause()`                             |  x  |        |     | Unpauses `swap` and `pull`                        |
| `sweep(token, recipient, amount)`       |  x  |        |     | Withdraws pool token balances to recipient        |
| direct wstETH / WETH transfer           |     |        |  x  | Adds liquidity (only owner can withdraw via sweep)|

Notes:
- `setOracle()` and `setFee()` are permanently disabled (always revert).

### Sync Automation

On-chain (`SyncTrigger`, `CREReceiver`) and off-chain (CRE workflow) surfaces that drive periodic `CustomSender.sync(...)` calls.

#### `SyncTrigger`

| Lever                                | GovExec | CRERx | Any | Effect                                          |
|--------------------------------------|:-------:|:-----:|:---:|------------------------------------------------ |
| `triggerSync()`                      |         |   x   |     | Executes sync when thresholds/time are met      |
| `setForwarder(forwarder)`            |    x    |       |     | Changes authorized caller (`CREReceiver`)       |
| `setDelay(delay)`                    |    x    |       |     | Updates minimum delay between sync runs         |
| `setAmounts(minAmount, maxAmount)`   |    x    |       |     | Updates sync min/max thresholds                 |
| `setFeeOtoD(fee)` / `setFeeDtoO(fee)` |  x    |       |     | Updates CCIP fee configs                        |
| `sweep(token, recipient, amount)`    |    x    |       |     | Withdraws tokens / native balance               |
| `receive()` (native transfer)        |         |       |  x  | Funds CCIP fee payments                         |

#### `CREReceiver`

| Lever                              | LOL | CREFwd | Any | Effect                                          |
|------------------------------------|:---:|:------:|:---:|-------------------------------------------------|
| `onReport(metadata, report)`       |     |   x    |     | Decodes report; enforces author match and `(target, selector)` allow-list; executes `target.call(data)` |
| `setForwarder(newForwarder)`       |  x  |        |     | Changes authorized CRE Forwarder address (reverts on `address(0)`) |
| `setExpectedAuthor(author)`        |  x  |        |     | Rotates the pinned workflow author (reverts on `address(0)`) |
| `setAllowedCall(target, selector, allowed)` | x |    |     | Whitelists / revokes a callable `(target, selector)` pair |
| `withdrawETH(to, amount)`          |  x  |        |     | Rescues ETH accidentally sent to contract       |
| `receive()` (native transfer)      |     |        |  x  | Allows the contract to receive ETH              |

Views: `getForwarder`, `getExpectedAuthor`, `isCallAllowed(target, selector)`, `supportsInterface`.

#### Off-chain (CRE Platform): Sync Workflow

The sync workflow is an off-chain WASM program registered on Chainlink's CRE platform. Lifecycle is controlled by the Lido Deployer's CRE account. The only on-chain surface is the [`WorkflowRegistry`](https://etherscan.io/address/0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5) contract on Ethereum Mainnet (`0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5`), which records workflow metadata — it does **not** hold funds. See [CRE deployment docs](https://docs.chain.link/cre/guides/operations/deploying-workflows) for the full registration flow.

| Lever                                            | LidoDep | CREDon | Any | Effect                                                        |
| ------------------------------------------------ | :-----: | :----: | :-: | ------------------------------------------------------------- |
| `cre workflow deploy` (new workflow)             |    x    |        |     | Compiles WASM, uploads to CRE Storage, registers on `WorkflowRegistry` (Ethereum Mainnet tx, ETH gas) |
| `cre workflow deploy` (re-deploy with same name) |    x    |        |     | Replaces WASM / config; calls `upsertWorkflow` on the registry |
| `cre workflow pause` / `activate`                |    x    |        |     | Stops / starts DON execution via `pauseWorkflow` / `activateWorkflow` on the registry |
| `cre workflow delete`                            |    x    |        |     | Retires the workflow via `deleteWorkflow` on the registry     |
| `cre account link-key` / `unlink-key`            |    x    |        |     | Associate / disassociate a wallet address with the CRE account (owner-gated) |
| `cre workflow list` / `info` / `logs`            |    x    |        |     | View registry metadata and runtime logs                       |
| Execute cron trigger (every 5 min)               |         |   x    |     | DON runs WASM and signs a report on each tick                 |
| Trigger cron early                               |         |        |     | *Not possible* — DON scheduler is not user-controllable       |

Notes:

- **Billing model.** Per Chainlink CRE documentation (verified April 2026), there is **no public LINK-funded billing balance** for CRE workflows. Execution cost is tracked as opaque "CRE credits" on the monitoring dashboard. The CRE CLI exposes no `fund` / `deposit` / `withdraw` / `balance` commands. During Early Access, compute is allocated administratively rather than via a permissionless top-up mechanism. See [docs.chain.link/cre](https://docs.chain.link/cre) for the current state; re-verify before GA.
- **Funding requirement for the Lido Deployer.** Only ETH on Ethereum Mainnet for occasional `WorkflowRegistry` transactions (~0.00000079 ETH per tx at current gas prices — negligible).
- **Workflow identity.** The owner's EVM address is propagated into every report as `metadata.workflowOwner` (bytes [42:62] of the metadata blob). `CREReceiver._extractWorkflowOwner` reads these bytes; if `_expectedAuthor != 0`, the two must match.
- **Updating the WASM** under the same owner key does not change `metadata.workflowOwner` — `_expectedAuthor` continues to accept reports after a routine code update.
- **Rotating the workflow owner key** (planned or emergency) requires a corresponding on-chain update: the LOL multisig must call `CREReceiver.setExpectedAuthor(newOwner)` on every L2 (4 transactions).
- **CRE-side pause is instant** but depends on Chainlink infrastructure. The on-chain equivalent kill switches are `LOL → CREReceiver.setForwarder(0)` and `GovExec → SyncTrigger.setForwarder(0)` / `setDelay(uint48 max)`; these are authoritative even if CRE is degraded.
- **Neither the CRE DON nor the CRE Forwarder** can be controlled by this project — they are Chainlink infrastructure shared across CRE users.

### `ProxyAdmin` (L2)

| Lever                                          | GovExec | Effect                                       |
|------------------------------------------------|:-------:|----------------------------------------------|
| `upgradeAndCall(proxy, implementation, data)`  |    x    | Upgrades L2 proxies (incl. `CustomSender`)   |

## L1

### `LidoCustomReceiver`

| Lever                                      | DAO | Router | Any | Effect                                           |
|--------------------------------------------|:---:|:------:|:---:|--------------------------------------------------|
| `ccipReceive(message)`                     |     |   x    |     | Validates sender, processes or stores failure     |
| `retryFailedMessage(message)`              |     |        |  x  | Retries previously failed message (hash must match) |
| `recoverTokens(message, to)`              |  x  |        |     | Admin recovery for failed-message tokens          |
| `setSender(destChainSelector, sender)`     |  x  |        |     | Updates trusted source sender per chain           |
| `setAdapter(destChainSelector, adapter)`   |  x  |        |     | Updates bridge adapter per chain                  |
| `grantRole(role, account)` / `revokeRole(role, account)` | x |  |  | Manages AccessControl roles                      |

Notes:
- `processMessage(message)` is internal-only (`onlySelf`), called within `ccipReceive`.
- `receive()` accepts native only from the WNATIVE contract during message processing.

### `ProxyAdmin` (L1)

| Lever                                          | DAO | Effect                                              |
|------------------------------------------------|:---:|----------------------------------------------------|
| `upgradeAndCall(proxy, implementation, data)`  |  x  | Upgrades L1 proxies (incl. `LidoCustomReceiver`)   |

---

## Standard Ownership Levers (all contracts)

Every `Ownable` contract (`PausableImmutableOraclePool`, `SyncTrigger`, `CREReceiver`, both `ProxyAdmin` instances) exposes `transferOwnership(newOwner)` and `renounceOwnership()`, callable by the respective owner listed above.

Every `AccessControl` contract (`CustomSender`, `LidoCustomReceiver`) exposes `renounceRole(role, callerConfirmation)`, callable by the role holder themselves.
