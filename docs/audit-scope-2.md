# Lido L2 Direct Staking — CRE sync automation. Audit scope

## TL;DR

`CREReceiver` and `SyncTrigger` are two single-purpose, non-upgradeable, owner-gated
contracts that form the **automation layer** for [Lido L2 Direct
Staking](https://blog.lido.fi/). They let users stake on an L2 and receive `wstETH`
without manually bridging to Ethereum L1: user-supplied WETH accumulates in an L2
`OraclePool`, and this automation periodically **syncs** it — bridging it to L1 via
Chainlink CCIP, staking it into Lido, and bridging the resulting `wstETH` back to the
originating L2 pool.

The goal of this repo is to facilitate migration to:
- Lido owner - instead of the old owner;
- CRE automation - instead of Chainlink Automation.

This is a **rate-limited automation trigger**, not a value-custody contract: neither
contract holds user funds in the steady state (`SyncTrigger` holds only its own native-fee
float). Both are non-upgradeable `Ownable` with **no permissionless entry points** — every
state-changing function is `onlyOwner` or `onlyForwarder`. The owner is expected to be the
Lido-on-L2 (LOL) governance multisig post-migration. There is no pause and no upgrade
mechanism; the owner escape hatches are `SyncTrigger.sweep(token, recipient, amount)` (moves
any ERC-20 *or* native balance out of `SyncTrigger`, including its fee float, to an arbitrary
recipient), `CREReceiver.withdrawETH(to, amount)` (sends the receiver's native balance —
normally ~0 — to an arbitrary recipient), plus the re-pointing setters.

## Scope

**Repository**: `l2-direct-staking`
**Audit revision**: `TBD` (2026-06-05) on `main`.
**Compiler**: `solc 0.8.20`, `evm_version = paris`.
**Framework**: Foundry (`forge 1.7.1`).
**Upgradeability**: none — non-upgradeable `Ownable`.


### Primary targets

| File | nSLOC | Notes |
|------|------:|-------|
| [`src/cre/CREReceiver.sol`](../src/cre/CREReceiver.sol) | 99 | Receives DON-signed CRE reports via the Keystone forwarder; dispatches a whitelisted, argument-less call (production: `SyncTrigger.triggerSync()`). New, Lido-authored. License: MIT. |
| [`src/SyncTrigger.sol`](../src/SyncTrigger.sol) | 131 | Decides *when* and *how much* to sync; calls `CustomSender.sync()`, funding the CCIP native fee from its own balance. Adapted from upstream `SyncAutomation` (Keeper→CRE refactor). License: Apache-2.0. |

**Total in-scope ≈ 226 nSLOC**, 2 non-upgradeable `Ownable` contracts, **0 permissionless
entry points**.

### Supporting references

| File                                               | Notes                                                                                                                                                                                                                                                                                     |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/cre/interfaces/IReceiver.sol`                 | Keystone receiver interface — `onReport`-only; **its `interfaceId` (`0x805f2132`) is load-bearing** (a one-selector mistake silently bricks delivery).                                                                                                                                    |
| `src/interfaces/ISyncTrigger.sol`                  | Interface / events / errors for `SyncTrigger`.                                                                                                                                                                                                                                            |
| `lib/chainlink-csr/**` @ `62108f7`                 | Upstream `CustomSender`, `OraclePool`, `FeeCodec`, `TokenHelper` — **out of scope** (relied-on upstream code). `SyncTrigger`'s fee/native/LINK accounting is *adapted from* (not byte-for-byte) upstream `SyncAutomation` at this commit. **Caveat — load-bearing for scope size:** upstream `SyncAutomation` is **not known to be audited** (no audit report vendored in `lib/chainlink-csr`; Chainlink's Direct-Staking reference template is published "AS IS … has not been audited"). So "adapted from audited upstream" must **not** be used to exclude this logic. Until (a) a concrete upstream audit reference and (b) an equivalence `git diff` of the shared accounting between `SyncTrigger` and `SyncAutomation` at the pinned commits are attached, treat the shared accounting as **in-scope by default**. Full note: `docs/audit-scope.md` §1. |
| `lib/chainlink-local/**` (vendored `ccip@eb419a0`) | CCIP routers, `KeystoneForwarder` / `IReceiver` — out of scope.                                                                                                                                                                                                                           |
| `script/**`                                        | L1/L2 migration & deploy Foundry scripts — separate operational track; they *configure* the in-scope contracts (role wiring, irreversible admin handover). Relevant as context.                                                                                                           |

## Architecture

The two in-scope contracts sit between Chainlink's off-chain CRE workflow and the upstream
chainlink-csr `CustomSender`. **`CREReceiver`** is the authenticated entry point — it accepts
DON-signed reports from the Keystone forwarder and dispatches one whitelisted, argument-less
call. **`SyncTrigger`** is the rate-limited decision/execution contract — it decides *when* and
*how much* to sync and fronts the CCIP native fee from its own balance. Everything downstream of
`CustomSender.sync()` (CCIP transport, L1 staking, the return bridge) is upstream and out of
scope.

```text
CRE DON ──signs report──► CRE Keystone forwarder (L2, Chainlink-operated)
                              │  ERC-165 delivery gate: supportsInterface(0x805f2132) && (0x01ffc9a7)
                              ▼
                     CREReceiver.onReport(metadata, report)        [onlyForwarder]
                              │  who : workflowOwner == _expectedAuthor
                              │  what: (target, selector) allow-listed + nullary (data.length == 4)
                              ▼
                     SyncTrigger.triggerSync()                      [onlyForwarder = CREReceiver]
                              │  re-checks delay window + pool WETH balance
                              ▼
                     CustomSender.sync{value: nativeFee}(...)  ───► CCIP → L1 stake → wstETH back to L2
                                                                    └────── upstream / out of scope ──────┘
```

A single sync proceeds as:

1. The Chainlink CRE workflow decides off-chain (an `eth_call` `shouldSync()` probe)
   whether a sync is due and, if so, the DON signs a report.
2. The Chainlink CRE Keystone forwarder validates the report and — only after the ERC-165
   delivery gate (`supportsInterface(0x805f2132)` **and** `0x01ffc9a7`) — calls
   `CREReceiver.onReport()`.
3. `CREReceiver` applies two authentication checks (*who may cause a call*) —
   `onlyForwarder`, then report `workflowOwner == _expectedAuthor` — and two
   authorization checks (*what may be called*) — the decoded `(target, selector)` must be
   owner-allow-listed, and the call must be argument-less (`data.length == 4`) — then
   dispatches the single whitelisted call.
4. That call is `SyncTrigger.triggerSync()` (the only allow-listed target). It re-checks
   the delay window and the pool's WETH balance, then calls
   `CustomSender.sync{value: nativeFee}(...)`, fronting the CCIP native fee from its own
   balance.
5. `CustomSender` pulls WETH from the `OraclePool` and bridges it via CCIP to L1; L1 stakes
   into Lido and bridges `wstETH` back to the L2 pool to back user `fastStake` /
   `slowStake`.

## Context and specification

### Trust surface

- Only the **owner** (LOL governance multisig post-migration) can call the
  setters, `SyncTrigger.sweep()`, and `CREReceiver.withdrawETH()`. There is **no pause, no
  upgrade, and no recovery beyond owner-only setters/sweeps**.
- The **CRE Keystone forwarder** is an *assumed-honest trust boundary* — relied on to route
  only DON-validated reports. It is the sole caller of `onReport` (`onlyForwarder`), and is
  distinct from the owner roles. `CREReceiver` is in turn the sole caller of
  `SyncTrigger.triggerSync()`.
- `_expectedAuthor` binds the report to an owner **key** (address), not to a specific
  **workflow** name/id — a deliberate, document-only choice whose blast radius is contained
  by the nullary-only allow-list.
- The owner→multisig handover during migration (`transferOwnership`) is the single
  highest-risk operational step: it is irreversible and gated by the Stage-1 wiring
  precondition above.

### Suggested audit focus

- The report gate on `CREReceiver.onReport` — two *who* checks (`onlyForwarder`, then report
  `workflowOwner == _expectedAuthor`) plus two *what* checks (the decoded `(target, selector)`
  must be allow-listed, and the call must be argument-less, `data.length == 4`): confirm it
  cannot be bypassed, widened, or made to dispatch anything beyond the intended rate-limited
  `triggerSync()`.
- The `IReceiver` `interfaceId` / `supportsInterface` ERC-165 gate being load-bearing — a
  one-selector mistake silently makes the forwarder reject the receiver, so reports are
  never delivered and WETH accumulates on L2, never staked (this was a real, since-fixed delivery bug).
- The fee-config length-domain coupling between `SyncTrigger` setters and downstream
  `CustomSender` decoders (`decodeCCIP == 21` / `decodeFee >= 17`).
- `uint48` delay-overflow behaviour in the "deactivated" state, and whether the off-chain
  CRE `eth_call` probe tolerates a revert vs requiring a clean `(false, 0)`.
- `SyncTrigger`'s fee/native/LINK split and the `CustomSender.sync` call: confirm it
  forwards the right value, strands none, and that the no-on-chain-refill native-fee
  funding model is acceptable as a liveness assumption.
- The `SyncTrigger` ↔ upstream `SyncAutomation` equivalence: the shared accounting is
  **in-scope by default** until an upstream audit reference + an equivalence `git diff` land
  (upstream is not known to be audited — see `docs/audit-scope.md` §1).
- Reentrancy of `onReport`'s `target.call` and the `sync → refundExcessNative →
  SyncTrigger.receive()` path; storage-writer authorization; owner self-harm via
  `withdrawETH` / `sweep` (neither guards a zero `to`/`recipient` or zero `amount`).
- Forwarder ABI/version pinning: the forwarder is set from `L2_CRE_FORWARDER` with **no
  on-chain version or ABI assertion**. Confirm each lane's production-deployed forwarder is the
  ERC-165-gated CRE/Keystone forwarder exposing `onReport(bytes,bytes)` with the
  `workflowId(32) | workflowName(10) | workflowOwner(20)` metadata layout — and that its
  `typeAndVersion` matches the deployment Chainlink actually operates on that lane.

### External contracts for interaction

Addresses are **per-L2 lane**; the table shows the **Optimism** lane as the concrete
example (`script/optimism/OptimismMigrationConstants.sol` + `script/l1/L1MigrationConstants.sol`).
Arbitrum / Base / Linea have analogous constants in their respective `*MigrationConstants.sol`.

| Component | Optimism (example lane) |
|-----------|-------------------------|
| `CustomSender` (`SyncTrigger.SENDER`, L2) | [`0x328de900860816d29D1367F6903a24D8ed40C997`](https://optimistic.etherscan.io/address/0x328de900860816d29D1367F6903a24D8ed40C997) |
| Lido L2 governance executor (post-migration owner) | [`0xEfa0dB536d2c8089685630fafe88CF7805966FC3`](https://optimistic.etherscan.io/address/0xEfa0dB536d2c8089685630fafe88CF7805966FC3) |
| Liquidity owner (LOL multisig) | [`0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61`](https://optimistic.etherscan.io/address/0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61) |
| L2 OraclePool (legacy; new pool deployed at migration) | [`0x6F357d53d6bE3238180316BA5F8f11467e164588`](https://optimistic.etherscan.io/address/0x6F357d53d6bE3238180316BA5F8f11467e164588) |
| `WNATIVE` / WETH (L2) | [`0x4200000000000000000000000000000000000006`](https://optimistic.etherscan.io/address/0x4200000000000000000000000000000000000006) |
| LINK token (L2) | [`0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6`](https://optimistic.etherscan.io/address/0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6) |
| CCIP Router (L2) | [`0x3206695CaE29952f4b0c22a169725a865bc8Ce0f`](https://optimistic.etherscan.io/address/0x3206695CaE29952f4b0c22a169725a865bc8Ce0f) |
| L1 Lido Custom Receiver | [`0x6F357d53d6bE3238180316BA5F8f11467e164588`](https://etherscan.io/address/0x6F357d53d6bE3238180316BA5F8f11467e164588) |
| L1 CCIP Router | [`0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D`](https://etherscan.io/address/0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D) |
| CRE Keystone forwarder (L2) | **Deploy-time, Chainlink-operated — not yet pinned.** Set via the `L2_CRE_FORWARDER` env var; **no on-chain version or ABI assertion.** The receiver assumes the modern CRE/Keystone forwarder ABI `onReport(bytes,bytes)` with metadata layout `workflowId(32) \| workflowName(10) \| workflowOwner(20)`. Confirm the production forwarder on each lane against Chainlink's Forwarder Directory — both its on-chain `typeAndVersion` *and* that it is the ERC-165-gated forwarder, not an older variant whose `onReport` ABI differs (e.g. `onReport(bytes32,address,bytes)`). |
| `CREReceiver` / `SyncTrigger` instances | **deployed at migration — not yet pinned** (placeholders in `cre-workflows/sync-automation/config.deploy.*.json`). |

> ⚠️ The same address string can resolve to different contracts across lanes (deterministic
> deploys). Confirm each address against the lane being reviewed, not by string equality.

> ⚠️ **Two distinct `_forwarder` values — do not conflate.** `CREReceiver._forwarder` is the
> **Chainlink CRE Keystone forwarder** (sole caller of `onReport`). `SyncTrigger._forwarder` is
> the **`CREReceiver`** (sole caller of `triggerSync`). The word "forwarder" means different
> things on each contract.

## Glossary

| Term | Meaning |
|------|---------|
| **CRE** | Chainlink Runtime Environment — off-chain workflow platform that emits DON-signed reports. |
| **DON** | Decentralized Oracle Network — the node set that signs CRE reports. |
| **CCIP** | Chainlink Cross-Chain Interoperability Protocol — the L2↔L1 messaging/token rails used by `sync`. |
| **Keystone forwarder** | On-chain Chainlink contract that validates a DON report and calls `onReport` on the receiver, after an ERC-165 gate. |
| **`onReport`** | The single forwarder→receiver entry point; its selector defines `type(IReceiver).interfaceId == 0x805f2132`. |
| **workflowOwner / workflowName / workflowId** | CRE report metadata: the owner key (pinned by `_expectedAuthor`), an owner-scoped label, and a content hash of the workflow. |
| **`CustomSender`** | Upstream chainlink-csr contract that performs the CCIP send (`sync`); out of scope. |
| **`OraclePool`** | L2 pool that accumulates user WETH awaiting sync; out of scope. |
| **sync** | The L2→L1 operation: pull WETH from the pool, bridge to L1 for staking, bridge `wstETH` back. |
| **OtoD / DtoO** | Origin-to-Destination / Destination-to-Origin CCIP fee legs (`feeOtoD` / `feeDtoO`). |
| **`payInLink`** | Flag in a fee buffer: pay the CCIP fee in LINK instead of native. |
| **nullary** | A call with no arguments — calldata is exactly the 4-byte selector (`data.length == 4`). |
| **LOL** | Lido-on-L2 — the governance multisig that owns the contracts post-migration. |
| **WETH / wstETH** | Wrapped ether (the asset users supply on L2) / wrapped staked ETH (minted on L1, bridged back). |
| **nSLOC** | Normalized source lines of code (comments/blank lines excluded). |
| **state-mate** | Lido's YAML-oracle deploy-verification tool; out of scope. |
