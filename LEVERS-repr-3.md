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

| Column    | Actor                  | Access basis                                        |
|-----------|------------------------|-----------------------------------------------------|
| GovExec   | L2 Governance Executor | `DEFAULT_ADMIN_ROLE` / owner on L2 contracts        |
| LOL       | LOL multisig           | Owner of `PausableImmutableOraclePool`, `CREReceiver` |
| LidoDAO   | LidoDaoAgent           | `DEFAULT_ADMIN_ROLE` / owner on L1 contracts        |
| Sender    | `CustomSender`         | Immutably set as SENDER on `PausableImmutableOraclePool` |
| SyncRole  | `SYNC_ROLE` holders    | `SyncTrigger` by default                            |
| CREFwd    | CRE Forwarder          | Authorized on `CREReceiver`                         |
| CRERx     | `CREReceiver`          | Set as forwarder on `SyncTrigger`                   |
| Router    | CCIP Router            | Configured in `LidoCustomReceiver`                  |

## L2 Access Matrix

| Lever                                                    | GovExec | LOL | Sender | SyncRole | CREFwd | CRERx |
| -------------------------------------------------------- | ------- | --- | ------ | -------- | ------ | ----- |
| **`CustomSender`**                                       |         |     |        |          |        |       |
| `sync(destChainSelector, amount, feeOtoD, feeDtoO)`      |         |     |        | x        |        |       |
| `setOraclePool(oraclePool)`                              | x       |     |        |          |        |       |
| `setReceiver(destChainSelector, receiver)`               | x       |     |        |          |        |       |
| `grantRole(role, account)` / `revokeRole(role, account)` | x       |     |        |          |        |       |
| **`PausableImmutableOraclePool`**                        |         |     |        |          |        |       |
| `swap(recipient, amountIn, minAmountOut)`                |         |     | x      |          |        |       |
| `pull(token, amount)`                                    |         |     | x      |          |        |       |
| `pause()`                                                |         | x   |        |          |        |       |
| `unpause()`                                              |         | x   |        |          |        |       |
| `sweep(token, recipient, amount)`                        |         | x   |        |          |        |       |
| **`SyncTrigger`**                                        |         |     |        |          |        |       |
| `triggerSync()`                                          |         |     |        |          |        | x     |
| `setForwarder(forwarder)`                                | x       |     |        |          |        |       |
| `setDelay(delay)`                                        | x       |     |        |          |        |       |
| `setAmounts(minAmount, maxAmount)`                       | x       |     |        |          |        |       |
| `setFeeOtoD(fee)` / `setFeeDtoO(fee)`                    | x       |     |        |          |        |       |
| `sweep(token, recipient, amount)`                        | x       |     |        |          |        |       |
| **`CREReceiver`**                                        |         |     |        |          |        |       |
| `onReport(metadata, report)`                             |         |     |        |          | x      |       |
| `setForwarder(newForwarder)`                             |         | x   |        |          |        |       |
| `setExpectedAuthor(author)`                              |         | x   |        |          |        |       |
| `withdrawETH(to, amount)`                                |         | x   |        |          |        |       |
| **L2 `ProxyAdmin`**                                      |         |     |        |          |        |       |
| `upgradeAndCall(proxy, implementation, data)`            | x       |     |        |          |        |       |

### L2 Permissionless

- `CustomSender.slowStake(destChainSelector, token, amount, feeOtoD, feeDtoO)` — starts slow-stake CCIP flow.
- `CustomSender.fastStake(token, amount, minAmountOut)` — instant swap via `PausableImmutableOraclePool`.
- `CustomSender.fastStakeReferral(token, amount, minAmountOut, referral)` — same as `fastStake` + `Referral` event.
- `SyncTrigger.receive()` — funds CCIP fee payments (native transfer).
- `CREReceiver.receive()` — allows the contract to receive ETH (native transfer).
- Direct wstETH / WETH transfer to `PausableImmutableOraclePool` — adds liquidity (only owner can withdraw via `sweep`).

## L1 Access Matrix

| Lever                                                    | LidoDAO | Router |
| -------------------------------------------------------- | ------- | ------ |
| **`LidoCustomReceiver`**                                 |         |        |
| `ccipReceive(message)`                                   |         | x      |
| `recoverTokens(message, to)`                             | x       |        |
| `setSender(destChainSelector, sender)`                   | x       |        |
| `setAdapter(destChainSelector, adapter)`                 | x       |        |
| `grantRole(role, account)` / `revokeRole(role, account)` | x       |        |
| **L1 `ProxyAdmin`**                                      |         |        |
| `upgradeAndCall(proxy, implementation, data)`            | x       |        |

### L1 Permissionless

- `LidoCustomReceiver.retryFailedMessage(message)` — retries a previously failed message if hash matches.

## Lever Effects

**`CustomSender`:**
- `sync` — pulls TOKEN from `PausableImmutableOraclePool` and sends CCIP sync message to L1.
- `setOraclePool` — changes the pool used by fast stake and sync.
- `setReceiver` — changes trusted destination receiver per chain selector.
- `grantRole` / `revokeRole` — manages AccessControl roles (`SYNC_ROLE`, `DEFAULT_ADMIN_ROLE`, etc.).
- `slowStake` — starts slow-stake CCIP flow; moves user funds.
- `fastStake` / `fastStakeReferral` — instant swap via pool; referral variant emits `Referral` event.

**`PausableImmutableOraclePool`:**
- `swap` — swaps TOKEN_IN for TOKEN_OUT at oracle price; used by fast stake.
- `pull` — pulls TOKEN_IN from pool to `CustomSender`; used by sync.
- `pause` / `unpause` — pauses/unpauses `swap` and `pull`.
- `sweep` — withdraws pool token balances (WETH/wstETH or others) to recipient.
- `setOracle` and `setFee` are permanently disabled (always revert).

**`SyncTrigger`:**
- `triggerSync` — executes sync when thresholds and time delay are met; calls `CustomSender.sync`.
- `setForwarder` — changes authorized caller (`CREReceiver`).
- `setDelay` — updates minimum delay between sync runs.
- `setAmounts` — updates sync min/max thresholds.
- `setFeeOtoD` / `setFeeDtoO` — updates CCIP fee configs (origin-to-dest, dest-to-origin).
- `sweep` — withdraws tokens or native balance.

**`CREReceiver`:**
- `onReport` — decodes report into `(address target, bytes data)` and executes `target.call(data)`.
- `setForwarder` — changes authorized CRE Forwarder address.
- `setExpectedAuthor` — sets expected workflow author for metadata validation (`address(0)` disables).
- `withdrawETH` — rescues ETH accidentally sent to the contract.

**`LidoCustomReceiver`:**
- `ccipReceive` — entry for inbound CCIP messages; validates sender and processes or stores failure hash.
- `retryFailedMessage` — retries a previously failed message if hash matches.
- `recoverTokens` — admin recovery path for failed-message tokens.
- `setSender` — updates trusted source sender per chain selector.
- `setAdapter` — updates bridge adapter per chain selector.
- `processMessage` is internal-only (`onlySelf`), called within `ccipReceive`.
- `receive()` accepts native only from the WNATIVE contract during message processing.

**`ProxyAdmin`:**
- `upgradeAndCall` — upgrades transparent proxies (`CustomSender` on L2, `LidoCustomReceiver` on L1).

## Standard Ownership Levers (all contracts)

Every `Ownable` contract (`PausableImmutableOraclePool`, `SyncTrigger`, `CREReceiver`, both `ProxyAdmin` instances) exposes `transferOwnership(newOwner)` and `renounceOwnership()`, callable by the respective owner listed above.

Every `AccessControl` contract (`CustomSender`, `LidoCustomReceiver`) exposes `renounceRole(role, callerConfirmation)`, callable by the role holder themselves.
