# LEVERS (Post-Migration)

State-mutating contract calls ("levers") and who can invoke them after migration finalization.

## Assumed Post-Migration State

- `L2 Governance Executor` — owner/admin on L2 governance surfaces (`L2CustomSender` admin role, `L2SyncTrigger` owner, `L2ProxyAdmin` owner).
- `LOL multisig` — owner of `L2PoolNew` and `CREReceiver`. Linea uses a different multisig than Optimism/Arbitrum/Base (see README).
- `LidoDaoAgent` — owner/admin on L1 control surfaces (`L1Receiver` admin role, `L1ProxyAdmin` owner).
- `L2SyncTrigger` has `SYNC_ROLE` on `L2CustomSender`.
- `CREReceiver` is configured as the forwarder on `L2SyncTrigger`.
- `initialOwner` no longer has admin/owner rights on migrated contracts.

---

## By Actor

### L2 Governance Executor

**`L2CustomSender`** (has `DEFAULT_ADMIN_ROLE`):
- `setOraclePool(oraclePool)` — changes the pool used by fast stake/sync logic.
- `setReceiver(destChainSelector, receiver)` — changes trusted destination receiver per chain selector.
- `grantRole` / `revokeRole` — manages AccessControl roles (including `SYNC_ROLE`, `DEFAULT_ADMIN_ROLE`).

**`L2SyncTrigger`** (owner):
- `setForwarder(forwarder)` — changes authorized caller (CREReceiver).
- `setDelay(delay)` — updates minimum delay between sync runs.
- `setAmounts(minAmount, maxAmount)` — updates sync min/max thresholds.
- `setFeeOtoD(fee)` / `setFeeDtoO(fee)` — updates CCIP fee configs.
- `sweep(token, recipient, amount)` — withdraws tokens/native balance.

**`L2ProxyAdmin`** (owner):
- `upgradeAndCall(proxy, implementation, data)` — upgrades L2 transparent proxies (including `L2CustomSender`).

### LOL Multisig

**`L2PoolNew`** (owner):
- `pause()` / `unpause()` — pauses/unpauses `swap` and `pull`.
- `sweep(token, recipient, amount)` — withdraws pool token balances (WETH/wstETH or others).

**`CREReceiver`** (owner):
- `setForwarder(newForwarder)` — changes authorized CRE Forwarder address.
- `setExpectedAuthor(author)` — sets expected workflow author for metadata validation (`address(0)` disables check).
- `withdrawETH(to, amount)` — rescues ETH accidentally sent to the contract.

### LidoDaoAgent

**`L1Receiver`** (has `DEFAULT_ADMIN_ROLE`):
- `recoverTokens(message, to)` — admin recovery path for failed-message tokens.
- `setSender(destChainSelector, sender)` — updates trusted source sender per chain selector.
- `setAdapter(destChainSelector, adapter)` — updates bridge adapter per chain selector.
- `grantRole` / `revokeRole` — manages AccessControl roles on `L1Receiver`.

**`L1ProxyAdmin`** (owner):
- `upgradeAndCall(proxy, implementation, data)` — upgrades L1 transparent proxies (including `L1Receiver`).

### Automated / Infrastructure

**`L2SyncTrigger`** (has `SYNC_ROLE` on `L2CustomSender`):
- `L2CustomSender.sync(destChainSelector, amount, feeOtoD, feeDtoO)` — pulls TOKEN from `L2PoolNew` and sends CCIP sync message.

**`CREReceiver`** (set as forwarder on `L2SyncTrigger`):
- `L2SyncTrigger.triggerSync()` — executes sync when thresholds/time are met.

**CRE Forwarder** (authorized on `CREReceiver`):
- `CREReceiver.onReport(metadata, report)` — decodes report and executes `target.call(data)`.

**CCIP Router** (configured in `L1Receiver`):
- `L1Receiver.ccipReceive(message)` — entry for inbound CCIP messages; validates sender and processes or stores failure hash.

**`L2CustomSender`** (immutably set as SENDER on `L2PoolNew`):
- `L2PoolNew.swap(recipient, amountIn, minAmountOut)` — swaps TOKEN_IN for TOKEN_OUT using oracle price.
- `L2PoolNew.pull(token, amount)` — pulls TOKEN_IN from pool for sync flow.

### Permissionless

**`L2CustomSender`:**
- `fastStake(token, amount, minAmountOut)` — instant swap via `L2PoolNew`.
- `fastStakeReferral(token, amount, minAmountOut, referral)` — same as `fastStake` plus `Referral` event.
- `slowStake(destChainSelector, token, amount, feeOtoD, feeDtoO)` — starts slow-stake CCIP flow.

**`L1Receiver`:**
- `retryFailedMessage(message)` — retries a previously failed message if hash matches.

**Funding (native transfers):**
- `L2SyncTrigger.receive()` — funds CCIP fee payments.
- `CREReceiver.receive()` — allows the contract to receive ETH.
- Anyone can provide `L2PoolNew` liquidity by transferring wstETH directly to pool address.

---

## Standard Ownership Levers

Every `Ownable` contract (`L2PoolNew`, `L2SyncTrigger`, `CREReceiver`, `L2ProxyAdmin`, `L1ProxyAdmin`) exposes:
- `transferOwnership(newOwner)` — transfers ownership to a new address.
- `renounceOwnership()` — permanently removes owner, disabling all owner-only functions.

Every `AccessControl` contract (`L2CustomSender`, `L1Receiver`) exposes:
- `renounceRole(role, callerConfirmation)` — role holder self-removes a role.

These are invocable by the respective owner/role-holder listed above.

---

## Notes

- `setOracle` and `setFee` are intentionally disabled on `PausableImmutableOraclePool` (always revert).
- `L1Receiver.processMessage` is internal-only (`onlySelf`), called within `ccipReceive`.
- `L1Receiver.receive()` accepts native only from the `WNATIVE` contract (during message processing).
- Linea uses a different LOL multisig address than Optimism/Arbitrum/Base (see README).
