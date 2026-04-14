# LEVERS (Post-Migration)

State-mutating contract calls ("levers") and who can invoke them after migration finalization.

## Assumed Post-Migration State

- **L2 Governance Executor** — owner/admin on L2 governance surfaces (`CustomSender` admin role, `SyncTrigger` owner, L2 `ProxyAdmin` owner).
- **LOL multisig** — owner of `PausableImmutableOraclePool` and `CREReceiver`. Linea uses a different multisig than Optimism/Arbitrum/Base (see README).
- **LidoDaoAgent** — owner/admin on L1 control surfaces (`LidoCustomReceiver` admin role, L1 `ProxyAdmin` owner).
- `SyncTrigger` has `SYNC_ROLE` on `CustomSender`.
- `CREReceiver` is configured as the forwarder on `SyncTrigger`.
- `initialOwner` no longer has admin/owner rights on migrated contracts.

## Actor Legend

| Short   | Full Name              | Context                                             |
|---------|------------------------|-----------------------------------------------------|
| GovExec | L2 Governance Executor | `DEFAULT_ADMIN_ROLE` on `CustomSender`, owner of `SyncTrigger` and L2 `ProxyAdmin` |
| LOL     | LOL multisig           | Owner of `PausableImmutableOraclePool` and `CREReceiver` |
| DAO     | LidoDaoAgent           | `DEFAULT_ADMIN_ROLE` on `LidoCustomReceiver`, owner of L1 `ProxyAdmin` |
| Sender  | `CustomSender`         | Immutably set as SENDER on `PausableImmutableOraclePool` |
| Sync    | `SYNC_ROLE` holders    | `SyncTrigger` by default                            |
| CREFwd  | CRE Forwarder          | Authorized on `CREReceiver`                         |
| CRERx   | `CREReceiver`          | Set as forwarder on `SyncTrigger`                   |
| Router  | CCIP Router            | Configured in `LidoCustomReceiver`                  |
| Any     | Any account            | Permissionless                                      |

---

## L2: `CustomSender`

| Lever                                                         | GovExec | Sync | Any | Effect                                              |
|---------------------------------------------------------------|:-------:|:----:|:---:|-----------------------------------------------------|
| `sync(destChainSelector, amount, feeOtoD, feeDtoO)`           |         |  x   |     | Pulls TOKEN from pool, sends CCIP sync message      |
| `setOraclePool(oraclePool)`                                   |    x    |      |     | Changes pool used by fast stake / sync              |
| `setReceiver(destChainSelector, receiver)`                    |    x    |      |     | Changes trusted destination receiver per chain      |
| `grantRole(role, account)` / `revokeRole(role, account)`      |    x    |      |     | Manages AccessControl roles (SYNC_ROLE, admin, ...) |
| `slowStake(destChainSelector, token, amount, feeOtoD, feeDtoO)` |       |      |  x  | Starts slow-stake CCIP flow                         |
| `fastStake(token, amount, minAmountOut)`                      |         |      |  x  | Instant swap via pool; emits `FastStake`            |
| `fastStakeReferral(token, amount, minAmountOut, referral)`    |         |      |  x  | Same as `fastStake` + `Referral` event              |

## L2: `PausableImmutableOraclePool`

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

## L2: `SyncTrigger`

| Lever                                | GovExec | CRERx | Any | Effect                                          |
|--------------------------------------|:-------:|:-----:|:---:|------------------------------------------------ |
| `triggerSync()`                      |         |   x   |     | Executes sync when thresholds/time are met      |
| `setForwarder(forwarder)`            |    x    |       |     | Changes authorized caller (`CREReceiver`)       |
| `setDelay(delay)`                    |    x    |       |     | Updates minimum delay between sync runs         |
| `setAmounts(minAmount, maxAmount)`   |    x    |       |     | Updates sync min/max thresholds                 |
| `setFeeOtoD(fee)` / `setFeeDtoO(fee)` |  x    |       |     | Updates CCIP fee configs                        |
| `sweep(token, recipient, amount)`    |    x    |       |     | Withdraws tokens / native balance               |
| `receive()` (native transfer)        |         |       |  x  | Funds CCIP fee payments                         |

## L2: `CREReceiver`

| Lever                              | LOL | CREFwd | Any | Effect                                          |
|------------------------------------|:---:|:------:|:---:|-------------------------------------------------|
| `onReport(metadata, report)`       |     |   x    |     | Decodes report, executes `target.call(data)`    |
| `setForwarder(newForwarder)`       |  x  |        |     | Changes authorized CRE Forwarder address        |
| `setExpectedAuthor(author)`        |  x  |        |     | Sets workflow author validation (0x0 disables)  |
| `withdrawETH(to, amount)`          |  x  |        |     | Rescues ETH accidentally sent to contract       |
| `receive()` (native transfer)      |     |        |  x  | Allows the contract to receive ETH              |

## L1: `LidoCustomReceiver`

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

## `ProxyAdmin` (L2 and L1)

| Lever                                          | GovExec | DAO | Effect                                         |
|------------------------------------------------|:-------:|:---:|-------------------------------------------------|
| L2: `upgradeAndCall(proxy, implementation, data)` |  x   |     | Upgrades L2 proxies (incl. `CustomSender`)     |
| L1: `upgradeAndCall(proxy, implementation, data)` |      |  x  | Upgrades L1 proxies (incl. `LidoCustomReceiver`) |

---

## Standard Ownership Levers (all contracts)

Every `Ownable` contract (`PausableImmutableOraclePool`, `SyncTrigger`, `CREReceiver`, both `ProxyAdmin` instances) exposes `transferOwnership(newOwner)` and `renounceOwnership()`, callable by the respective owner listed above.

Every `AccessControl` contract (`CustomSender`, `LidoCustomReceiver`) exposes `renounceRole(role, callerConfirmation)`, callable by the role holder themselves.
