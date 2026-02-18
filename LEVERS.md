# LEVERS (Post-Migration)

State-mutating contract calls ("levers") and who can invoke them after migration finalization.

## Assumed Post-Migration State

- `L2 Governance Executor` is the owner/admin on L2 governance surfaces (`L2CustomSender` admin role, `L2SyncTrigger` owner, `L2ProxyAdmin` owner).
- `LOL multisig` is the owner of `L2PoolNew` (controls pause/unpause, sweep, ownership transfer). See README for per-network addresses — Linea uses a different multisig than Optimism/Arbitrum/Base.
- `LOL multisig` is the owner of `CREReceiver` (controls forwarder and expected-author settings). Operational admin — may need quick forwarder updates for CRE infra rotation.
- `LidoDaoAgent` is the owner/admin on L1 control surfaces (`L1Receiver` admin role, `L1ProxyAdmin` owner).
- `L2SyncTrigger` has `SYNC_ROLE` on `L2CustomSender`.
- `CREReceiver` is configured as the forwarder on `L2SyncTrigger`.
- `initialOwner` no longer has admin/owner rights on migrated contracts.

## L2: `L2CustomSender`

| Lever (mutating call)                                           | Who can invoke after migration                       | Effect                                                                     |
| --------------------------------------------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------------- |
| `sync(destChainSelector, amount, feeOtoD, feeDtoO)`             | `L2SyncTrigger` by default; any address with `SYNC_ROLE` | Pulls `TOKEN` from `L2PoolNew` and sends CCIP sync message.          |
| `setOraclePool(oraclePool)`                                     | `L2 Governance Executor` (has `DEFAULT_ADMIN_ROLE` on `L2CustomSender`) | Changes the pool used by fast stake/sync logic.                     |
| `setReceiver(destChainSelector, receiver)`                      | `L2 Governance Executor` (has `DEFAULT_ADMIN_ROLE` on `L2CustomSender`) | Changes trusted destination receiver per chain selector.            |
| `grantRole(role, account)`                                      | `L2 Governance Executor` (or any account with that role's admin role) | Grants AccessControl roles (including `SYNC_ROLE` / `DEFAULT_ADMIN_ROLE`). |
| `revokeRole(role, account)`                                     | `L2 Governance Executor` (or any account with that role's admin role) | Revokes AccessControl roles.                                      |
| `renounceRole(role, callerConfirmation)`                        | Role holder itself                                   | Self-removes a role.                                                       |
| `slowStake(destChainSelector, token, amount, feeOtoD, feeDtoO)` | Any account                                          | Starts slow-stake CCIP flow; moves user funds and emits `SlowStake`.       |
| `fastStake(token, amount, minAmountOut)`                        | Any account                                          | Executes fast stake via `L2PoolNew.swap`; emits `FastStake`.               |
| `fastStakeReferral(token, amount, minAmountOut, referral)`      | Any account                                          | Same as `fastStake` plus `Referral` event emission.                        |

## L2: `L2PoolNew`

| Lever (mutating call)                           | Who can invoke after migration | Effect                                                                   |
| ----------------------------------------------- | ------------------------------ | ------------------------------------------------------------------------ |
| `swap(recipient, amountIn, minAmountOut)`       | `L2CustomSender` only (set immutable) | Swaps `TOKEN_IN` for `TOKEN_OUT` using oracle price; used by fast stake. |
| `pull(token, amount)`                           | `L2CustomSender` only (set immutable) | Pulls `TOKEN_IN` from pool to `L2CustomSender`; used by sync flow.       |
| `pause()`                                       | `LOL multisig` (owner)         | Pauses `swap`/`pull`.                                                    |
| `unpause()`                                     | `LOL multisig` (owner)         | Unpauses `swap`/`pull`.                                                  |
| `sweep(token, recipient, amount)`               | `LOL multisig` (owner)         | Withdraws pool token balances (`WETH`/`wstETH` or others) to recipient.  |
| `transferOwnership(newOwner)`                   | `LOL multisig` (owner)         | Transfers pool ownership.                                                |
| `renounceOwnership()`                           | `LOL multisig` (owner)         | Removes owner, disabling owner-only functions.                           |
| adding liquidity (regular WETH/wstETH transfer) | anyone                         | Only owner (LOL multisig) can withdraw the liquidity                     |

Notes:
- `setOracle` and `setFee` are intentionally disabled on `PausableImmutableOraclePool` (always revert).
- Any account can still provide liquidity by transferring `wstETH` directly to pool address (token transfer, not a pool method).
- Linea uses a different LOL multisig address than Optimism/Arbitrum/Base (see README).

## L2: `L2SyncTrigger`

| Lever (mutating call) | Who can invoke after migration | Effect |
| --- | --- | --- |
| `triggerSync()` | `CREReceiver` only (set as forwarder) | Executes sync when thresholds/time are met; calls `L2CustomSender.sync`. |
| `receive()` (native transfer) | Any account | Increases native balance held by `L2SyncTrigger` (used to fund CCIP fee payments). |
| `setForwarder(forwarder)` | `L2 Governance Executor` (owner) | Changes authorized caller (CREReceiver). |
| `setDelay(delay)` | `L2 Governance Executor` (owner) | Updates minimum delay between sync runs. |
| `setAmounts(minAmount, maxAmount)` | `L2 Governance Executor` (owner) | Updates sync min/max thresholds. |
| `setFeeOtoD(fee)` | `L2 Governance Executor` (owner) | Updates origin->destination fee config. |
| `setFeeDtoO(fee)` | `L2 Governance Executor` (owner) | Updates destination->origin fee config. |
| `sweep(token, recipient, amount)` | `L2 Governance Executor` (owner) | Withdraws tokens/native balance held by `L2SyncTrigger`. |
| `transferOwnership(newOwner)` | `L2 Governance Executor` (owner) | Transfers `L2SyncTrigger` ownership. |
| `renounceOwnership()` | `L2 Governance Executor` (owner) | Removes owner, disabling owner-only controls. |

## L2: `CREReceiver`

| Lever (mutating call) | Who can invoke after migration | Effect |
| --- | --- | --- |
| `onReport(metadata, report)` | CRE Forwarder only | Decodes report into `(address target, bytes data)` and executes `target.call(data)`. |
| `setForwarder(newForwarder)` | `LOL multisig` (owner) | Changes authorized CRE Forwarder address. |
| `setExpectedAuthor(author)` | `LOL multisig` (owner) | Sets expected workflow author for metadata validation (address(0) disables check). |
| `transferOwnership(newOwner)` | `LOL multisig` (owner) | Transfers `CREReceiver` ownership. |
| `renounceOwnership()` | `LOL multisig` (owner) | Removes owner, disabling admin functions. |
| `withdrawETH(to, amount)` | `LOL multisig` (owner) | Rescues ETH accidentally sent to the contract. |
| `receive()` (native transfer) | Any account | Allows the contract to receive ETH. |

## L1: `L1Receiver`

| Lever (mutating call) | Who can invoke after migration | Effect |
| --- | --- | --- |
| `ccipReceive(message)` | CCIP router configured in `L1Receiver` | Entry for inbound CCIP messages; validates sender and processes or stores failure hash. |
| `processMessage(message)` | `L1Receiver` itself only (`onlySelf`) | Internal processing step invoked by `ccipReceive`. |
| `receive()` (native transfer) | `WNATIVE` contract only | Accepts unwrapped native during message processing. |
| `retryFailedMessage(message)` | Any account | Retries a previously failed message if hash matches. |
| `recoverTokens(message, to)` | `LidoDaoAgent` (has `DEFAULT_ADMIN_ROLE` on `L1Receiver`) | Admin recovery path for failed-message tokens. |
| `setSender(destChainSelector, sender)` | `LidoDaoAgent` (has `DEFAULT_ADMIN_ROLE` on `L1Receiver`) | Updates trusted source sender per chain selector. |
| `setAdapter(destChainSelector, adapter)` | `LidoDaoAgent` (has `DEFAULT_ADMIN_ROLE` on `L1Receiver`) | Updates bridge adapter per chain selector. |
| `grantRole(role, account)` | `LidoDaoAgent` (or any account with that role's admin role) | Grants AccessControl roles on `L1Receiver`. |
| `revokeRole(role, account)` | `LidoDaoAgent` (or any account with that role's admin role) | Revokes AccessControl roles on `L1Receiver`. |
| `renounceRole(role, callerConfirmation)` | Role holder itself | Self-removes a role. |

## Proxy Admin Levers

### L2: `L2ProxyAdmin`

| Lever (mutating call) | Who can invoke after migration | Effect |
| --- | --- | --- |
| `upgradeAndCall(proxy, implementation, data)` | `L2 Governance Executor` (owner) | Upgrades L2 transparent proxies administered by `L2ProxyAdmin` (including `L2CustomSender`). |
| `transferOwnership(newOwner)` | `L2 Governance Executor` (owner) | Transfers `L2ProxyAdmin` ownership. |
| `renounceOwnership()` | `L2 Governance Executor` (owner) | Removes owner, disabling admin upgrades via `L2ProxyAdmin`. |

### L1: `L1ProxyAdmin`

| Lever (mutating call) | Who can invoke after migration | Effect |
| --- | --- | --- |
| `upgradeAndCall(proxy, implementation, data)` | `LidoDaoAgent` (owner) | Upgrades L1 transparent proxies administered by `L1ProxyAdmin` (including `L1Receiver`). |
| `transferOwnership(newOwner)` | `LidoDaoAgent` (owner) | Transfers `L1ProxyAdmin` ownership. |
| `renounceOwnership()` | `LidoDaoAgent` (owner) | Removes owner, disabling admin upgrades via `L1ProxyAdmin`. |
