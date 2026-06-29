# Lido L2 Direct Staking — CRE sync automation. Audit scope

## TL;DR

`CREReceiver` and `SyncTrigger` are two single-purpose, non-upgradeable, owner-gated
contracts that form the **automation layer** for [Lido L2 Direct
Staking](https://blog.lido.fi/). They let users stake on an L2 and receive `wstETH`
without manually bridging to Ethereum L1: user-supplied WETH accumulates in an L2
`OraclePool`, and this automation periodically **syncs** it — bridging it to L1 via
Chainlink CCIP, staking it into Lido, and bridging the resulting `wstETH` back to the
originating L2 pool.

The goal of this repo is to perform — on **four L2s (Optimism, Arbitrum, Base, Linea)** —
the migration of this automation to:
- **Lido ownership** — the Lido L2 governance executor and the LOL multisig, instead of the
  old owner;
- **CRE automation** — Chainlink Runtime Environment, instead of the retired Chainlink
  Automation (and Gelato on Linea).

The two in-scope contracts *are* that new automation layer; the migration itself — deploying
them, wiring roles, and the irreversible owner/admin handover — is a Foundry-scripted operation
run once per each L2 and for L1 (see [Actors & privileges](#actors--privileges)).

## Scope

**Repository**: `l2-direct-staking`
**Audit revision**: `main @ a2a3d0c54c56` (2026-06-11). Pin the exact
freeze-commit hash here once it lands, and re-run the measurements in [Build & verify](#build--verify)
against that commit (the Slither/coverage figures below are bound to it).
**Compiler**: `solc 0.8.34`, `evm_version = osaka`.
**Framework**: Foundry (`forge 1.7.1`).
**Upgradeability**: none — non-upgradeable `Ownable`.


### Primary targets

| File | nSLOC | Notes |
|------|------:|-------|
| [`src/cre/CREReceiver.sol`](../src/cre/CREReceiver.sol) | ~135 | Receives DON-signed CRE reports via the Keystone forwarder; dispatches a whitelisted, argument-less call (production: `SyncTrigger.triggerSync()`). New, Lido-authored. License: MIT. |
| [`src/SyncTrigger.sol`](../src/SyncTrigger.sol) | ~141 | Decides *when* and *how much* to sync; calls `CustomSender.sync()`, funding the CCIP native fee from its own balance. Includes the inlined fee-denomination split `_maxFees` (formerly the standalone `FeeSplit` library; the deploy script's `runPrintFeeParams` keeps a byte-identical mirror, pinned by `verify-constants-sync` + a fee-split equivalence test). Adapted from upstream `SyncAutomation` (Keeper→CRE refactor). License: Apache-2.0. |

**Total in-scope ≈ 276 nSLOC** (re-measured 2026-06-10 at `145affb`, then +6 on 2026-06-18 when the
former `FeeSplit` helper was inlined into `SyncTrigger` as `_maxFees`; the growth vs the earlier
≈230 figure is mostly a multi-line formatting pass on `CREReceiver` plus three new owner-setter
guards — logic delta is ~10 lines), 2 non-upgradeable `Ownable` contracts, **0
permissionless state-mutating function entry points** (the payable `receive()` fallbacks accept
ETH from anyone — the intended, harmless float-funding path; see [D. Fee configuration &
liveness](#d-fee-configuration--liveness)).

### Supporting references

| File                                               | Notes                                                                                                                                                                                                                                                                                     |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/cre/interfaces/IReceiver.sol`                 | Keystone receiver interface — `onReport`-only; **its `interfaceId` (`0x805f2132`) is load-bearing** (a one-selector mistake silently bricks delivery). The file is reference, but the id **match** is asserted in the in-scope `CREReceiver.supportsInterface` and is an audit-focus item (§B).                                                                                                                                    |
| `lib/chainlink-csr/**` @ `62108f7`                 | Upstream `CustomSender`, `OraclePool`, `FeeCodec`, `TokenHelper` — **out of scope** (relied-on upstream code). `SyncTrigger`'s fee/native/LINK accounting is *adapted from* (not byte-for-byte) upstream `SyncAutomation` at this commit. **Caveat — load-bearing for scope size:** upstream `SyncAutomation` is **not known to be audited** (no audit report vendored in `lib/chainlink-csr`; Chainlink's Direct-Staking reference template is published "AS IS … has not been audited"). So "adapted from audited upstream" must **not** be used to exclude this logic. Until (a) a concrete upstream audit reference and (b) an equivalence `git diff` of the shared accounting between `SyncTrigger` and `SyncAutomation` at the pinned commits are attached, treat the shared accounting as **in-scope by default**. |
| `lib/chainlink-local/**` (vendored `ccip@eb419a0`) | CCIP routers, `KeystoneForwarder` / `IReceiver` — out of scope.                                                                                                                                                                                                                           |
| `lib/openzeppelin-contracts{,-upgradeable}/**`     | `Ownable`, `SafeERC20`, `IERC165` — out of scope (relied-on upstream).                                                                                                                                                                                                                    |
| `script/**`                                        | L1/L2 migration & deploy Foundry scripts — separate operational track; they *configure* the in-scope contracts (role wiring, irreversible admin handover). Relevant as context — summarised under [Migration & operations plan](#migration--operations-plan).                              |
| `test/**`, mocks                                   | Unit + fork suites — out of scope; see [Build & verify](#build--verify).                                                                                                                                                                                                                  |

### Third-party Chainlink dependencies — source, audit status & deployed addresses

All Chainlink (and Chainlink-derived) code below is **out of scope** (relied-on upstream — see
[Supporting references](#supporting-references)); this records its provenance, audit status, and
live addresses, since they underpin the scope rationale in §G. The takeaway: the only set that is in
the production path *and* unaudited *and* **not** official Chainlink is **chainlink-csr** (authored
by an individual, "Aphyla", not `smartcontractkit`). CCIP transport is official Chainlink; the
CRE/Keystone forwarder is Chainlink-operated infra. **None ship a publicly linkable audit report.**
Source links are pinned to the vendored submodule commits.

**Source & audit**

| Contract (deployed type → source)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Origin                                                                          | Audit             |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ----------------- |
| [`CustomSenderReferral`](https://github.com/Aphyla/chainlink-csr/blob/62108f7b6cc664e36dbc8100c4b48974d59f572e/contracts/senders/CustomSenderReferral.sol) — L2 sender, extends [`CustomSender`](https://github.com/Aphyla/chainlink-csr/blob/62108f7b6cc664e36dbc8100c4b48974d59f572e/contracts/senders/CustomSender.sol)                                                                                                                                                                                                                                                                                                      | `Aphyla/chainlink-csr` @`62108f7` — community repo, **not** official Chainlink  | None              |
| [`LidoCustomReceiver`](https://github.com/Aphyla/chainlink-csr/blob/62108f7b6cc664e36dbc8100c4b48974d59f572e/contracts/receivers/LidoCustomReceiver.sol) — L1 receiver, extends [`CustomReceiver`](https://github.com/Aphyla/chainlink-csr/blob/62108f7b6cc664e36dbc8100c4b48974d59f572e/contracts/receivers/CustomReceiver.sol)                                                                                                                                                                                                                                                                                                | ″                                                                               | None              |
| [`PausableImmutableOraclePool`](https://github.com/Aphyla/chainlink-csr/blob/62108f7b6cc664e36dbc8100c4b48974d59f572e/contracts/utils/PausableImmutableOraclePool.sol) — L2 pool, extends [`OraclePool`](https://github.com/Aphyla/chainlink-csr/blob/62108f7b6cc664e36dbc8100c4b48974d59f572e/contracts/utils/OraclePool.sol)                                                                                                                                                                                                                                                                                                  | ″                                                                               | None              |
| libraries [`FeeCodec`](https://github.com/Aphyla/chainlink-csr/blob/62108f7b6cc664e36dbc8100c4b48974d59f572e/contracts/libraries/FeeCodec.sol), [`TokenHelper`](https://github.com/Aphyla/chainlink-csr/blob/62108f7b6cc664e36dbc8100c4b48974d59f572e/contracts/libraries/TokenHelper.sol)                                                                                                                                                                                                                                                                                                                                      | ″                                                                               | None              |
| CCIP bases (inherited) [`CCIPSenderUpgradeable`](https://github.com/Aphyla/chainlink-csr/blob/62108f7b6cc664e36dbc8100c4b48974d59f572e/contracts/ccip/CCIPSenderUpgradeable.sol), [`CCIPTrustedSenderUpgradeable`](https://github.com/Aphyla/chainlink-csr/blob/62108f7b6cc664e36dbc8100c4b48974d59f572e/contracts/ccip/CCIPTrustedSenderUpgradeable.sol), [`CCIPDefensiveReceiverUpgradeable`](https://github.com/Aphyla/chainlink-csr/blob/62108f7b6cc664e36dbc8100c4b48974d59f572e/contracts/ccip/CCIPDefensiveReceiverUpgradeable.sol)                                                                                      | ″                                                                               | None              |
| CCIP transport [`Router`](https://github.com/smartcontractkit/ccip/blob/eb419a097bd11846ff2d82d25c447eee1f911b38/contracts/src/v0.8/ccip/Router.sol) (+ [`FeeQuoter`](https://github.com/smartcontractkit/ccip/blob/eb419a097bd11846ff2d82d25c447eee1f911b38/contracts/src/v0.8/ccip/FeeQuoter.sol), [`EVM2EVMOnRamp`](https://github.com/smartcontractkit/ccip/blob/eb419a097bd11846ff2d82d25c447eee1f911b38/contracts/src/v0.8/ccip/onRamp/EVM2EVMOnRamp.sol), [`EVM2EVMOffRamp`](https://github.com/smartcontractkit/ccip/blob/eb419a097bd11846ff2d82d25c447eee1f911b38/contracts/src/v0.8/ccip/offRamp/EVM2EVMOffRamp.sol)) | `smartcontractkit/ccip` @`eb419a0` — official Chainlink                         | No public report¹ |
| [`KeystoneForwarder`](https://github.com/smartcontractkit/ccip/blob/eb419a097bd11846ff2d82d25c447eee1f911b38/contracts/src/v0.8/keystone/KeystoneForwarder.sol) — CRE/Keystone forwarder                                                                                                                                                                                                                                                                                                                                                                                                                                        | `smartcontractkit/ccip` @`eb419a0` — official; deployed copy Chainlink-operated | None found²       |
| [`WorkflowRegistry`](https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.8/workflow/WorkflowRegistry.sol) — CRE workflow ownership                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | `smartcontractkit/chainlink` — official; not vendored/pinned here³              | None found        |

¹ Official Chainlink production code; Chainlink states CCIP was audited before mainnet but does not
  publish the reports — no linkable URL, so "audited" is vendor-asserted.
² The repo vendors two incompatible `KeystoneForwarder` variants — the legacy
  `onReport(bytes32,address,bytes)` (no ERC-165 gate) and the ERC-165-gating `onReport(bytes,bytes)`
  "Router" build that `CREReceiver` implements; the production forwarder must be the latter. **Verified
  on-chain (all 4 lanes, 2026-06-19): it is** — identical EXTCODEHASH
  `0x2b21870eb5ea9013a781ed3db7d5fab742b612b2ac8de0990ac9d95b22f795fc` + the Router ABI. ⚠ The live
  forwarder reports the **stale** `typeAndVersion` label `"KeystoneForwarder 1.0.0"`, so the version
  string is NOT the discriminator (the ABI/ERC-165 behaviour is) — see §B and `just verify-cre-forwarder`.
  Its per-network address is Chainlink-published, **not** pinned in the repo (see below).
³ Not vendored or pinned at a commit here (the link is the `develop` branch, BSL-1.1); referenced
  only by the end-state ownership invariant (W-1, §E).

**Deployed addresses** (mainnet; verified against the shared `config/state/l2.yaml` with
each lane's `.inputs`/`.deployed` siblings, and `script/<lane>/<Lane>MigrationConstants.sol`). ⚠ **Address reuse:** the same hex is a *different*
contract per chain (deterministic deploys) — e.g. `0x328de9…C997` is `CustomSenderReferral` on
Base/OP/Linea but the L1 Optimism adapter on mainnet; `0x6F35…4588` is the L1 `LidoCustomReceiver`
but the *old* OraclePool on the three OP-stack L2s. Always resolve via the lane's own constants file
(§F, [Where the addresses live](#where-the-addresses-live)).

| Contract | Ethereum L1 | Arbitrum | Base | Optimism | Linea |
| --- | --- | --- | --- | --- | --- |
| `CustomSenderReferral` (proxy) | — | `0x72229141D4B016682d3618ECe47c046f30Da4AD1` | `0x328de900860816d29D1367F6903a24D8ed40C997` | `0x328de900860816d29D1367F6903a24D8ed40C997` | `0x328de900860816d29D1367F6903a24D8ed40C997` |
| `LidoCustomReceiver` (proxy, shared) | `0x6F357d53d6bE3238180316BA5F8f11467e164588` | — | — | — | — |
| `PausableImmutableOraclePool` (live)⁴ | — | `0x4C7D20565687A308135a7B38eA0b26a5e292B4c4` | `0x9C74E3B8ceC764Aa6E977F81A7F7c478a440Be28` | `0x534115F4afAa64da3F6F1e79b295F1702Bc6e8e8` | `0x5067457698Fd6Fa1C6964e416b3f42713513B3dD` |
| CCIP `Router` | `0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D` | `0x141fa059441E0ca23ce184B6A78bafD2A517DdE8` | `0x881e3A65B4d4a04dD529061dd0071cf975F58bCD` | `0x3206695CaE29952f4b0c22a169725a865bc8Ce0f` | `0x549FEB73F2348F6cD99b9fc8c69252034897f06C` |
| `KeystoneForwarder` (CRE) | n/a | not pinned⁵ | not pinned⁵ | not pinned⁵ | not pinned⁵ |

`FeeCodec` / `TokenHelper` are internal libraries (embedded in consumers' bytecode — no standalone
address); `WorkflowRegistry` is a Chainlink-operated singleton whose address is not pinned in the repo.

⁴ New pool — `CustomSender.getOraclePool()` points here post-Stage-2. The pre-migration pool is
  orphaned (Arbitrum `0x9c27c304cFdf0D9177002ff186A4aE0A5489Aace`; Base/OP/Linea
  `0x6F357d53d6bE3238180316BA5F8f11467e164588`) and kept under state-mate as `oldOraclePool`.
⁵ Pinned per network in `<Lane>MigrationConstants.CRE_FORWARDER` (from the Chainlink production
  forwarder directory) and cross-checked against the `l2CreForwarder` state-mate anchor by
  `verify-constants-sync` — see §B and [Where the addresses live](#where-the-addresses-live).
  L1 has no CRE forwarder.

## Build & verify

Prerequisites: Foundry (`forge 1.7.1`), git + submodules. Compiler `solc 0.8.34`,
`evm_version = osaka` (bumped at `c50b224`; the in-scope contracts pin `pragma solidity 0.8.34`). Licenses: `CREReceiver` MIT · `SyncTrigger` Apache-2.0.

```bash
git clone <repo> && cd l2-direct-staking
git checkout <audit-rev>                 # the frozen audit revision (TBD — see Scope)
forge install                            # or: git submodule update --init --recursive
forge build                              # builds clean (lint warnings only)

# Unit suite — no RPC needed; this is the in-scope coverage:
forge test --match-path "test/{CREReceiverTest,SyncTriggerTest,L2PinnedConstantsGuard}.t.sol"

# Fork suites (test/*PoolUpgrade.t.sol, CREIntegrationTest)
# exercise the migration scripts against forked chains and need RPC env vars:
#   L1_RPC_URL, L2_{OPTIMISM,ARBITRUM,BASE,LINEA}_RPC_URL
# Point these at LOCAL forks, not public RPCs.
forge test
```

**Static analysis & coverage** (Slither figures measured 2026-06-04 — re-confirm on the audit
revision; since then guard branches and their tests churned — zero-recipient `withdrawETH` and the
`setFeeOtoD` gas-limit floor were added, a `MIN_DELAY` (1 minute) floor was added to `setDelay`/the
constructor (delay can no longer be 0 — see I-4), `shouldSync()` became `shouldSyncAmount() → uint256`
(absorbing the removed `getAmountToSync`), and `withdrawETH` gained an `amount==0` no-op short-circuit —
and the toolchain was bumped to solc 0.8.34 / osaka. The unit and full
suites pass; re-measure the test counts (previously **94** unit / 214 full) and the coverage figures
(last taken at `c50b224`, 2026-06-11) on the audit revision):

- Slither 0.11.5 (`--exclude-dependencies`, filtered to `src/`) + `forge lint`: **14 results, all
  Low / Informational — 0 High, 0 Medium**, each triaged as accepted-by-design or a minor nit.
- The unit suite gives **100% line / statement / branch / function** coverage on both in-scope
  contracts.
- **Methodology gaps to weigh:** **0 stateful-fuzz / 0 invariant** tests over the fee split or the
  3-layer auth — exactly where they pay off. Unit tests `vm.prank` the forwarder and call
  `onReport` directly, **bypassing the real ERC-165 delivery gate** — the blind spot that let the
  original delivery bug ship.

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

1. The Chainlink CRE workflow decides off-chain (`eth_call` probes of `shouldSyncAmount()`
   and `canSync()`) whether a sync is due and executable and, if both, the DON signs a report.
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

### Actors & privileges

The whole point of the repo is to *change* who holds the keys, so three things are kept
strictly distinct below: the **role** (an authority slot — e.g. "owner of `SyncTrigger`"), the
**holder** (the concrete address filling the slot, which moves from a deploy-time EOA to a Lido
principal *during migration*), and the **gated capability** (the functions that holder may
call). The deploy/handover steps that move a holder are the migration itself — and the
highest-risk operational events in this repo (per the `DOC.md §6.4` severity table).

Both in-scope contracts end up **owned by the LOL multisig**; the high-authority levers around
them (`SYNC_ROLE` administration, the `CustomSender` admin, the L2 `ProxyAdmin`) stay with the
**Lido L2 governance executor** — two trust domains, do not conflate them:

| Role (authority slot) | Holder: deploy → post-migration | Gated capability |
| --- | --- | --- |
| **`SyncTrigger` owner** | **Lido Deployer** (canary test) → **LOL multisig** (Safe, at `handoff`) | `setForwarder`, `setDelay`, `setAmounts`, `setFeeOtoD`, `setFeeDtoO`, `setMaxGasLimit`, `sweep` — `sweep` moves any ERC-20 *or* native balance (incl. the fee float) to an arbitrary recipient |
| **`CREReceiver` owner** | **Lido Deployer** (canary test) → **LOL multisig** (Safe, at `handoff`) | `setForwarder`, `setExpectedAuthor`, `setAllowedCall`, `withdrawETH` — `withdrawETH` moves native balance (normally ~0) to an arbitrary recipient |
| **`CREReceiver` forwarder** (`_forwarder`) | **Lido Deployer** during the canary test (simulated CRE — drives `onReport` directly) → **Chainlink CRE Keystone forwarder** (per-L2, restored at `handoff`) | sole caller of `onReport`; the production value is **pinned per network** in code (`_expectedCREForwarder()` → `<Lane>MigrationConstants.CRE_FORWARDER`, not env-supplied — see §B), with **no on-chain version/ABI assertion** |
| **`SyncTrigger` forwarder** (`_forwarder`) | the deployed **`CREReceiver`** instance | sole caller of `triggerSync` — note "forwarder" denotes a *different* contract on each in-scope contract |
| **`expectedAuthor` pin** | **Lido Deployer** during the canary test → **LOL multisig** (Safe, at `handoff`) = registered CRE `WorkflowRegistry` owner = `CREReceiver` owner | not a method — the report-author identity that `onReport` checks `==` against; re-pointable only via `setExpectedAuthor` (owner-only), and bound to an *address*, not a *workflow* name/id |
| **`SYNC_ROLE` on `CustomSender`** (upstream) | old Chainlink Automation → the new **`SyncTrigger`** | lets the `triggerSync → sync` call actually pull WETH from the pool; granted/revoked in Stage 2 — **admin = the Lido L2 governance executor** (`CustomSender` `DEFAULT_ADMIN_ROLE`), the independent sync kill switch |

**End-state invariant** (asserted by tests, monitored in prod), per L2:
`WorkflowRegistry.owner == CREReceiver.getExpectedAuthor() == CREReceiver.owner() == LOL multisig`
(see [ADR-0001](adr/0001-cre-workflow-owner-multisig.md)).

**Two trust domains.** The **LOL multisig** holds the *operational* authority — it **owns both
in-scope contracts** (`SyncTrigger` and `CREReceiver`), plus the L2 `OraclePool` (upstream), the
CRE workflow, and the `expectedAuthor` pin. The **Lido L2 governance executor** holds the
*protocol-governance* authority — the `CustomSender` `DEFAULT_ADMIN_ROLE` (which grants/revokes
`SyncTrigger`'s `SYNC_ROLE`, the independent sync kill switch) and the L2 `ProxyAdmin`.

These holders are put in place by a **canary, multi-signer migration**
([docs/mainnet-simulated-cre-test.md](mainnet-simulated-cre-test.md)), run once per L2: the **Lido
Deployer** deploys the new contracts **owned by itself** and stands in for the CRE forwarder + author
to drive a simulated `onReport` sync (a live test before any handoff), then restores the production
config (real forwarder + LOL author + production delay/amounts) and **transfers ownership to LOL** at
`handoff`; the **Initial Owner** (the old admin, `L1MigrationConstants.INITIAL_OWNER`) performs the
*reversible* activation (`setOraclePool` + `grantSyncRole`) and later the *irreversible* governance
seal on the pre-existing upstream contracts — note it is an **external, non-Lido party** (see
[Invariants and attention points](#invariants-and-attention-points), "E. Migration handoff &
wiring"). Post-migration the Lido Deployer and the Initial Owner hold **zero on-chain power** over
these contracts. Full sequence, gates, and failure modes:
[Migration & operations plan](#migration--operations-plan).

### Migration & operations plan

The migration is **not atomic**: it is a sequence of separate transactions run **once per L2**, by
**three signers** (Lido Deployer · external Initial Owner · LOL Safe), so the scripts bracket every
irreversible write with on-chain assertions and keep the irreversible step **last**. The new
contracts are deployed **deployer-owned** and a live sync is tested *before* any handoff — the full
state machine (`0→1→2→3→4` with a `1→0` rollback) is in
[docs/mainnet-simulated-cre-test.md](mainnet-simulated-cre-test.md). Each stage is a separate broadcast
by its own signer — there is no combined deploy+migrate entrypoint.

1. **0→1 deploy — `runDeployTest()`** (Lido Deployer). Deploy `OraclePool` / `SyncTrigger` /
   `CREReceiver` **owned by the deployer**, with the deployer as the `CREReceiver` forwarder **and**
   author and a **low test** `minAmount`/`delay`; fund the float. Touches **only the new contracts** —
   fully reversible by discarding them. Self-reverts (`_assertSyncInfrastructure`, `expectedOwner =
   deployer`, which still reads back `DEST_CHAIN_SELECTOR`, `WNATIVE`, delay, amounts, `feeDtoO`,
   `feeOtoD`) on any wrong wire/parameter — a botched deploy leaves the live (old) system untouched.
2. **0→1 activate — `runActivate()`** (Initial Owner). `setOraclePool(new)` + `grantSyncRole(new
   SyncTrigger)`. **Reversible** — the Initial Owner keeps `DEFAULT_ADMIN_ROLE` and the legacy
   automation keeps `SYNC_ROLE`, so `runRollback()` (`setOraclePool(old)` + revoke) fully restores the
   predecessor system.
3. **Stage 1 test — `runSimulateSync()`** (Lido Deployer). Seed the pool with WETH, then call
   `CREReceiver.onReport` directly (deployer = forwarder + author): exercises `onReport → triggerSync →
   CustomSender.sync` and a real CCIP forward leg, **without** the real Keystone forwarder or DON (a
   deliberate residual — see §B and §E).
4. **Gate — `runVerifyTest()`** (anyone, read-only). Confirms the canary state: infra deployer-owned,
   pool repointed, `SYNC_ROLE` granted, Initial Owner still admin (seal not run).
5. **1→2 handoff — `runHandoff()`** (Lido Deployer). Sweep test residue; **restore production config**
   (`setForwarder(real)`, `setExpectedAuthor(LOL)`, `setDelay(12h)`, `setAmounts(5e18,100e18)`); top up
   the float; `transferOwnership(→ LOL)` on all three. A closing `_assertSyncInfrastructure` against
   **production** values (`expectedOwner = LOL`) reverts the whole handoff if any restore was missed —
   the guardrail that a misconfigured production system cannot ship. LOL then registers the production
   CRE workflow; `runVerifyStage2()` confirms the post-handoff, pre-seal state.
6. **2→3 seal — `runFinalize()`** (Initial Owner). The irreversible cutover, in order:
   `revokeSyncRole`(old Chainlink [+ Gelato on Linea]) → `migrateSenderAdmin` (grant gov-exec, revoke
   Initial Owner) → `transferProxyAdminOwnership`(gov-exec). It **first** re-asserts the LOL-owned,
   production-configured infra as an **interlock** (refuses to seal unless `handoff` completed);
   `migrateSenderAdmin` then asserts the configured `initialOwner` *actually holds* `DEFAULT_ADMIN_ROLE`
   (OZ `revokeRole` is a silent no-op on a non-holder, so without this a mis-set `initialOwner` would
   produce a phantom revoke the postcondition passes trivially); it ends with `_assertMigrationSteps`
   re-reading every write/revoke. Caveat: `CustomSender` is not `AccessControlEnumerable`, so there is
   **no on-chain proof the executor is the *sole* admin** — only the two touched addresses are
   asserted; any pre-existing third admin must be ruled out off-chain.

**If the seal stops mid-way** (the dangerous window): the Initial Owner still holds
`DEFAULT_ADMIN_ROLE` until the penultimate step, so most partial states are **re-runnable** —
re-issue the remaining idempotent `revoke`/`grant` calls. (Note the old-automation `SYNC_ROLE` is
revoked here in `finalize`, not at activation, so the old pool stays syncable for a clean rollback
through Stage 1.) The final step (`ProxyAdmin → gov-exec`) is the point of no return — afterwards only
governance can re-administer the lane.

**Rollback posture:** the canary is freely abandonable through Stage 1 — `runRollback()` restores the
old pool + revokes the new `SYNC_ROLE` while the Initial Owner still holds admin. Reversibility is
**control-plane only**: wstETH already synced to L1 and in-flight CCIP messages cannot be undone (they
are `sweep`-recoverable from the test pool). After `handoff` the contracts are LOL's; after `finalize`
the lane is committed — there is **no on-chain undo**, recovery is a fresh governance action.

### Trust surface

- Only the relevant **owner** can call the setters, `SyncTrigger.sweep()`, and
  `CREReceiver.withdrawETH()` — the **LOL multisig** owns both (`SyncTrigger`'s `SYNC_ROLE` is
  separately grant/revocable by the Lido L2 governance executor; see [Actors & privileges](#actors--privileges)). There is **no
  pause, no upgrade, and no recovery beyond owner-only setters/sweeps**.
- The **CRE Keystone forwarder** is an *assumed-honest trust boundary* — relied on to route
  only DON-validated reports. It is the sole caller of `onReport` (`onlyForwarder`), and is
  distinct from the owner roles. `CREReceiver` is in turn the sole caller of
  `SyncTrigger.triggerSync()`.
- `_expectedAuthor` binds the report to an owner **key** (address), not to a specific
  **workflow** name/id — a deliberate, document-only choice whose blast radius is contained
  by the nullary-only allow-list.
- The migration handovers (Stage-1 `transferOwnership` on the in-scope contracts; the Stage-2
  `DEFAULT_ADMIN_ROLE` / `ProxyAdmin` handover on the upstream contracts) are the highest-risk
  operational steps (`DOC.md §6.4` severity table): irreversible and gated by the Stage-1 wiring
  precondition — detailed under
  [Actors & privileges](#actors--privileges).

### Where the addresses live

Every lane-specific holder, role address, and tunable is a Solidity constant in a per-lane file —
**not** a literal buried in the scripts. Always resolve an address through the lane's *own* file;
never reuse a string seen on another lane (the chain-blindness footgun — see **F. Chain-blindness**
below):

| Where | What it holds |
| --- | --- |
| `script/{optimism,arbitrum,base,linea}/<Lane>MigrationConstants.sol` | Per-lane `LIDO_L2_GOVERNANCE_EXECUTOR`, `LIQUIDITY_OWNER`, `L2_SYNC_TRIGGER_INITIAL_FLOAT`, `L2_SYNC_DESTINATION_GAS_LIMIT`, sender / pool / old-automation addresses. |
| `script/l1/L1MigrationConstants.sol` | `INITIAL_OWNER` (the external Stage-2 signer) plus the **shared** L1 receiver / `ProxyAdmin`. |
| Deploy-time env | `L2_SYNC_TRIGGER_INITIAL_FLOAT` echoed for the broadcast-time guard. The governance executor, predecessor OraclePool, CRE forwarder, and Lido DAO Agent are **not** deploy-time env: each is pinned per lane in `<Lane>MigrationConstants.sol` / `L1MigrationConstants.sol` and read directly by the scripts (`_expectedGovernanceExecutor()` / `_expectedOldOraclePool()` / `_expectedCREForwarder()`, see §B). |
| `config/state/l2.yaml` (one shared wiring for all 4 L2 lanes; + per-lane generated `.deployed.yaml` / static `.inputs.yaml` siblings) | Deployed-state verification oracle; the encoded fee blobs (`getFeeOtoD`/`getFeeDtoO`/`getMaxFees`) are now asserted against the `.inputs.yaml` anchors, themselves cross-checked vs `FeeCodec(constants)` by `verify-constants-sync`. |

Cross-references: `DOC.md §1` (Networks) and `DOC.md §6.1` (the two different "initial" accounts).

### Per-network differences

The four lanes are **not** interchangeable. Linea is the consistent outlier; Arbitrum has its own
return-leg quirk. A uniform change applied to all four is a footgun — **G-1** (gov-executor pin)
sources the executor only from the per-network constant (an unpinned lane reverts,
`L2UpgradeGovernanceExecutorNotPinned`), guarding against this
class of mistake, and **C-1** (per-lane FeeQuoter cap) is **now also a config-time guard**: `setFeeOtoD`
rejects `gasLimit > getMaxGasLimit()` (`SyncTriggerGasLimitAboveMax`), where the owner-set
`getMaxGasLimit()` ceiling is seeded per lane to the FeeQuoter `maxPerMsgGasLimit` at deploy (the F-3
`MIN_PROCESS_MESSAGE_GAS` floor is the lower bound; this adds the upper bound). The ceiling is a static
mirror of the live cap, so a chain-blind over-bump fails loudly at config time, while the FeeQuoter stays
the source of truth at `sync`-time (`MessageGasLimitTooHigh`) — re-seed via `setMaxGasLimit` if CCIP ever
changes a cap, and verify the deployed value out-of-band:

| Aspect | Optimism / Base | Arbitrum | Linea |
| --- | --- | --- | --- |
| Old automation revoked in Stage 2 | Chainlink only | Chainlink only | Chainlink **+ Gelato** (`L2_OLD_GELATO_AUTOMATION`) |
| `FeeOtoD.gasLimit` baseline (`L2_SYNC_DESTINATION_GAS_LIMIT`) | `1_000_000` | `1_000_000` | **`500_000`** (leaner Message Service adapter) |
| FeeQuoter `maxPerMsgGasLimit` (invariant **C-1**) | 7M | 7M | **3M** |
| CCIP OnRamp (ETH-destination), verified on-chain | Optimism **v1.5** / Base **v1.6** | v1.6 | **v1.5** |
| `ccipReceive` gas headroom (measured 2026-06-10, post-Glamsterdam ×1.25) | **tight**: Optimism ~86%, Base ~83% of 1M | comfortable (~41%) | ~67% of 500k (previously unverified; v1.5 lanes now measurable) |
| Return-leg loss / stall mode | under-gassed `finalizeDeposit`, permissionlessly replayable | retryable **must be redeemed ≤ ~7 days or the wstETH is lost** | messages > 250k gas drop the postman auto-claim |
| `FeeDtoO` over-payment | `l2Gas` burn ~1:1, coupled to `FeeOtoD` | **1:1 burn to an unreachable L2 alias** (verified on-chain) | — |
| `LIQUIDITY_OWNER` | per-lane | per-lane | distinct |

Details and on-chain evidence: `docs/fees.md` (§`FeeOtoD.gasLimit`, §`FeeDtoO`, §Failure modes) and
`DOC.md §1`.

### Invariants and attention points

This section consolidates what a reviewer should **confirm**, **scrutinize**, and **be aware
of** for the two in-scope contracts. It folds together three previously separate lists —
formal invariants, suggested audit focus, and the residual risks the repo's own documentation
(`DOC.md`, `docs/fees.md`, `RUNBOOK.md`, `docs/adr/0001-…`, inline NatSpec) flags. It is organised
by theme (A–H); **each theme follows the same outline**:

- **Invariants** — checkable properties, each tagged with where it is checkable (*source* /
  *deployed instance* / *off-chain ops*), because several cannot be verified from the repo alone.
- **Audit focus** — what to actively probe for bypass, widening, or regression.
- **Residual risks** — concerns that are mostly **operational, off-chain, or deployed-instance**
  and cannot be discharged from the two in-scope contracts' source alone; a reviewer should
  confirm the reasoning holds and the mitigations are real. Each cites where it is documented.

Not every theme carries all three sub-lists.

#### A. The report gate — authentication & authorization on `onReport`

- **Invariants**
  - **I-3** (*source*): only nullary calls dispatch through `onReport` — a single
    `data.length != 4` check (`NonNullaryCall`, applied *before* selector extraction) covers both
    too-short (0–3, which would otherwise zero-pad into a bogus selector) and argument-carrying
    (5+) calldata; it subsumes the former separate `ReportTooShort` guard (removed).
- **Audit focus**
  - The report gate — two *who* checks (`onlyForwarder`, then report `workflowOwner ==
    _expectedAuthor`) plus two *what* checks (the decoded `(target, selector)` must be
    allow-listed, and the call must be argument-less, `data.length == 4`): confirm it cannot be
    bypassed, widened, or made to dispatch anything beyond the intended rate-limited
    `triggerSync()`. (`expectedAuthor` binds an owner **key**, not a workflow — the deliberate
    choice whose blast radius the nullary allow-list contains; see [Trust surface](#trust-surface).)

#### B. Delivery integrity — forwarder & ERC-165 gate

- **Residual risks**
  - **ERC-165 `interfaceId` is load-bearing.** A one-selector mistake makes the forwarder reject
    the receiver — reports are never delivered, WETH accumulates on L2, never staked, **with no
    revert**. This was a real, since-fixed delivery bug; the id **match** lives in the in-scope
    `CREReceiver.supportsInterface`. (`DOC.md §2.6.B`.)
  - **Forwarder ABI/version not asserted in-contract.** The forwarder address is **pinned per lane**
    in `<Lane>MigrationConstants.CRE_FORWARDER` and used directly by `_expectedCREForwarder()` /
    `L2UpgradeScriptBase._creForwarder()` (sourced ONLY from the constant, never env; an unpinned lane
    reverts `L2UpgradeCREForwarderNotPinned`), and cross-checked vs the `l2CreForwarder` state-mate
    anchor by `verify-constants-sync`. That pins the *address*; `CREReceiver` does **not** assert the
    forwarder's *ABI/version* at runtime. The two vendored Keystone forwarders are ABI-incompatible —
    the deployed one must be the ERC-165-gating `onReport(bytes,bytes)` "Router" build, not the legacy
    `onReport(bytes32,address,bytes)` variant. **Verified on-chain (all 4 lanes, 2026-06-19): it is** —
    identical EXTCODEHASH `0x2b21870eb5ea9013a781ed3db7d5fab742b612b2ac8de0990ac9d95b22f795fc` + the
    Router ABI fingerprint (`isForwarder` + 3-arg `getTransmitter` present, legacy 2-arg absent);
    `just verify-cre-forwarder` re-checks this read-only, per lane. ⚠ **The version string is NOT the
    discriminator:** the live forwarder reports the *stale* label `"KeystoneForwarder 1.0.0"` while
    being the Router build — gating on the string (as `RUNBOOK.md §1.c` once did) would false-reject
    the correct forwarder. Discriminate on the ABI/ERC-165 behaviour + EXTCODEHASH.
    (`RUNBOOK.md §1.c`; [Where the addresses live](#where-the-addresses-live).)
  - **DON-embedded author vs registry owner.** `verify-cre-workflow` confirms only the
    `WorkflowRegistry.owner` (plus, since `145affb`: non-zero `workflowId`/`expectedAuthor` inputs
    — closing a false-green against a non-existent workflow — and a non-empty `binaryUrl`); the
    DON-embedded `metadata.workflowOwner` is a **different surface**.
    If the DON embeds a different address (a CRE Early-Access residual), every report fails
    `InvalidAuthor` and all syncs silently stall. The only proof is a live `CREReceiver.CallExecuted`
    — exercise on a throwaway testnet workflow first. (`RUNBOOK.md` gate G2-author; `ADR-0001`.)

#### C. Rate-limiting, deactivation & reentrancy

- **Invariants**
  - **I-2** (*source*): the `delay` window is computed in `uint256` (`uint256(_lastExecution) + _delay`),
    so even the largest representable `delay` cannot overflow/revert — `shouldSyncAmount()` and
    `triggerSync()` stay TOTAL and the off-chain CRE `eth_call` probe gets a clean `0` (no sync) rather
    than a revert. No `delay` value is special-cased.
  - **I-4** (*source*): `delay` is a rate-limiter with a hard floor — `setDelay` and the constructor
    reject any value below `MIN_DELAY` (1 minute), so the rate-limiter cannot be disabled and no two
    syncs can land in the same block/minute (a `delay` of `0` would make the time gate
    `block.timestamp < _lastExecution + delay` permanently false). Above the floor `delay` is a plain
    duration over the rest of the `uint48` range with **no** special value — there is no deactivation
    sentinel; deactivation is via `setForwarder(0x…dead)` or `revokeRole(SYNC_ROLE)`. Confirm no caller
    assumes a specific `getDelay()` value.
  - **R-1** (*source*): reentrancy — `onReport`'s `target.call` and the `sync → refundExcessNative →
    SyncTrigger.receive()` path are non-reentrant via `onlyForwarder` + empty `receive()`.

#### D. Fee configuration & liveness

- **Invariants**
  - **F-1** (*deployed instance + off-chain ops — operating assumption, not a source invariant*):
    fee sufficiency — `SyncTrigger` native balance ≥
    the per-sync fee. Depletion is monotonic (~`actualFee`/sync) with **no on-chain refill** — a
    liveness assumption, not a guarded invariant. Below `getMaxFees()` the next
    `triggerSync` reverts at the value transfer **with no named error**. Funding is permissionless;
    recovery (`sweep`) is owner-only (LOL multisig).
  - **F-2** (*source + config*): deploy-time float floor — Stage 1 reverts (`L2UpgradeFloatBelowFloor`)
    if `L2_SYNC_TRIGGER_INITIAL_FLOAT < maxFee + feeDtoO` — the seeded float must cover one
    worst-case sync.
  - **C-1** (*deployed instance + config*): per-lane CCIP `gasLimit` (`FeeOtoD`) is ≤ that lane's
    FeeQuoter `maxPerMsgGasLimit` (7M on OP/Arb/Base, **3M on Linea**); above it, `getFee` reverts
    `MessageGasLimitTooHigh` inside `sync` → the lane halts until an owner `setFeeOtoD` (now a LOL multisig transaction). A uniform
    "bump all lanes for safety" passes everywhere **except Linea** — a chain-blind footgun.
    (`docs/fees.md §Consequences > FeeOtoD.gasLimit`.)
  - **F-3** (*source*): `setFeeOtoD` enforces, at set-time, that the encoded `gasLimit` is ≥
    `CustomSender.MIN_PROCESS_MESSAGE_GAS()` (in addition to the exact-21-byte decode check) — a
    decodable config below the sender's floor would otherwise make every `sync` revert
    `CustomSenderInsufficientGas` while `shouldSyncAmount`/`canSync` stay positive/true, so the CRE DON
    would submit a reverting tx every tick.
- **Residual risks**
  - **Gas-limit headroom is tight on Optimism/Base post-Glamsterdam.** The fork harness now
    isolates `ccipReceive` on **all four lanes** (the v1.5 lanes — Optimism, Linea — use the same
    direct-inject path as v1.6 since `145affb`). Measured 2026-06-10: under the EIP-7904/8038
    repricing (×1.25), **Optimism is the tightest lane at ~86%** of its 1M limit and **Base ~83%**
    — both at or above the 80% headroom target (to restore it: raise Optimism to ~1.07M, Base to
    ~1.04M); Arbitrum is comfortable (~41%) and Linea's 500k — previously unverified — measures
    **~67%** post-repricing. No lane out-of-gases. Figures move ±~10% with fork block / Lido buffer
    state. (`docs/fees.md §Glamsterdam fee headroom`, `§Measured ccipReceive gas`.)
  - **Over-provisioning consequences differ per quantity.** `maxFee` excess is refunded intra-tx, but
    raising it **weakens a guard** (it is the worst-case spend a single spurious-but-authorized sync
    can burn from the float). Arbitrum `FeeDtoO` over-payment is a **per-sync 1:1 burn** to the L1
    receiver's unreachable L2 alias (verified on-chain). OP/Base `l2Gas` couples to `FeeOtoD.gasLimit`
    ~1:1 and ~300k of slack alone crosses the OOG cliff. (`docs/fees.md §FeeOtoD.maxFee`, `§FeeDtoO
    (Arbitrum)`, `§FeeDtoO.l2Gas (Optimism/Base)`.)
  - **`maxFee` guard adequacy is coupled to `maxAmount` on OP/Linea.** The OtoD quote scales with the
    bridged amount on Optimism/Linea (CCIP charges 5 bps with an uncapped, uint32-sentinel ceiling;
    Arbitrum/Base are flat ≈0 bps for WETH). So `maxFee`'s adequacy there is tied to the 100 WETH
    `maxAmount` cap: the current setting leaves ~2.5× margin (a full 100 WETH sync quotes ~40% of
    `maxFee`), but a `setAmounts` raise past ~250 WETH or a `setFeeOtoD` `maxFee` cut on those two lanes
    would make a full-size sync revert `CCIPSenderExceedsMaxFee`. Measured/reproducible via
    `just quote-ccip-fee-by-amount`. (`docs/otod-fee-amount-sensitivity.md`.)
  - **Return-leg loss/stall paths.** Arbitrum: if the L1→L2 retryable does not auto-redeem, it must
    be **manually redeemed within ~7 days or the wstETH is lost** — the one return path that can lose
    funds. OP/Base: under-gassed `finalizeDeposit` is permissionlessly replayable. Linea: messages
    >250k gas drop the postman auto-claim. L1: under-gassed `ccipReceive` parks funds for permissionless
    `retryFailedMessage`. (`docs/fees.md §Failure modes`.)
  - **F-4 — `feeDtoO` serialization boundary (deliberately off-chain; *not* an on-chain invariant).**
    `setFeeDtoO` validates the generic 17-byte prefix (`FeeCodec.decodeFee`: `len>=17`) and rejects
    `payInLink == true` (`SyncTriggerPayInLinkNotSupported` — LINK fee payment is not supported), but
    **not** the lane-specific shape the L1 adapter enforces (Arbitrum 29B with `feeAmount != 0`;
    Optimism/Base 21B with `feeAmount == 0`; Linea 17B; all `payInLink == false`, now enforced on-chain).
    This is the lone fee-blob asymmetry: `feeOtoD` is uniform (CCIP 21-byte) and fully guarded (**F-3**
    floor + **C-1** ceiling + exact-21), whereas a lane-mismatched `feeDtoO` (wrong lane length, or nonzero
    `feeAmount` on OP/Base/Linea — but NOT `payInLink == true`, which is now rejected at set-time) passes
    set-time **and** L2 (`CustomSender`
    also decodes it only with the generic `decodeFee`), crosses to L1, and reverts inside the adapter →
    defensive catch parks it in `failedHashes`; `retryFailedMessage` re-runs the same frozen bytes
    (deterministic re-revert), so only `recoverTokens` (L1 `DEFAULT_ADMIN_ROLE`) frees the stranded WETH.
    Reused every cycle, it restrands a fresh batch (≤`maxAmount`) per `delay` with **no L2 signal**. Left
    unguarded on-chain **by design**: the format is immutable-per-lane (pinned in `chainlink-csr@62108f7`
    + the immutable L1 adapter, changeable only via a coordinated L1-governance `setAdapter`), so an
    on-chain check would couple the L2 trigger to a format it cannot re-bind; the failure is owner-gated
    (`onlyOwner` = LOL multisig) and L1-recoverable, not a loss; and the encoded bytes are already pinned
    off-chain at deploy (`verify-test` keccak vs the migration constants; live state-mate `getFeeDtoO`).
    Residual exposure is a **manual post-deploy `setFeeDtoO` retune** (expected for Arbitrum gas params).
    Precedent: the predecessor SyncAutomation on Arbitrum was set to a 21-byte CCIP `feeDtoO` (a
    "configuration anomaly", `script/arbitrum/ArbitrumMigrationConstants.sol:45-53`) that would revert
    `decodeArbitrumL1toL2` (expects 29). (`docs/fees.md §FeeDtoO encoding`, `§Plan: when reality outgrows
    a limit`.)

#### E. Migration handoff & wiring

- **Invariants**
  - **W-1** (*deployed instance, per lane*): end-state wiring + ownership — `SyncTrigger._forwarder
    == CREReceiver` and the allow-list holds `(SyncTrigger, triggerSync.selector)`; and
    `WorkflowRegistry.owner == CREReceiver.getExpectedAuthor() == CREReceiver.owner() ==
    SyncTrigger.owner == LOL multisig` (with the `CustomSender` `SYNC_ROLE` admin == gov executor).
    Owner-set — confirmable only on a deployed instance.
  - **G-1** (*source + config*): gov-executor pin — the `runDeployTest` / `runActivate` /
    `runHandoff` / `runFinalize` entrypoints source the executor ONLY from the per-network
    `LIDO_L2_GOVERNANCE_EXECUTOR` constant (never env), so a wrong executor cannot be baked into the
    `CustomSender` admin / `ProxyAdmin` handover (at `finalize`; the canary deploys `SyncTrigger`
    deployer-owned, then hands it to the LOL multisig at `handoff`, never the executor). An unpinned
    network reverts (`L2UpgradeGovernanceExecutorNotPinned`).
- **Residual risks** — the highest-risk, off-chain track.
  - **External Initial Owner & non-atomic, no-forcing-function cutover.** Stage 2 is run by the
    **external, non-Lido** `INITIAL_OWNER` (upstream chainlink-csr admin) as **≥5 independent
    broadcasts** across 5 chains (4× `runFinalize()` + 1× L1 seal), with **no atomicity and no on-chain
    forcing function**. If that party stalls (lost key, dispute, bad faith), Lido **cannot
    self-complete** the handoff. Independently confirm the address *and the party that controls it*
    before Stage 2. (`DOC.md §6.1, §6.4`.)
  - **L1-last security-critical window.** L2-first / L1-last sequencing leaves the external owner
    holding `ProxyAdmin` over the **shared** L1 `LidoCustomReceiver` until the final seal — upgrade
    power over the one contract that stakes/bridges value for **every** lane. The "all L2s migrated
    but L1 not sealed" window is **high-severity and must be kept short** (pre-sign / pre-queue the L1
    seal). The §3.4 kill-switches do **not** cover a retained external `ProxyAdmin` — it can upgrade
    around a pause. (`DOC.md §6.4` severity table; `RUNBOOK.md` §2.) The transient intra-`finalize`
    windows are liveness-only (no loss) and detailed in
    [Migration & operations plan](#migration--operations-plan).
  - **Canary deferred-seal & deployer-simulated CRE.** The flow defers the irreversible seal
    (`finalize`) until *after* a live, deployer-driven sync test, so activation (`setOraclePool` +
    `grantSyncRole`) is **reversible** while the Initial Owner keeps admin (`runRollback`). Review
    consequences: (i) the Initial Owner's external-admin window now also spans the per-lane canary test
    (Stages 1–2) — bound it; (ii) `runHandoff` must restore the real forwarder + LOL author + production
    delay/amounts before transferring to LOL — the load-bearing failure, caught by the production
    `_assertSyncInfrastructure` in `runHandoff` and again by `state-mate`; (iii) the canary's
    `simulate-sync` stands in for the Keystone forwarder + DON (deployer as forwarder+author), so the
    **real** forwarder/ERC-165 gate (§B) and the DON author gate are **not** exercised pre-go-live —
    first proven by the first production `CREReceiver.CallExecuted` (RUNBOOK **G2-author**). Full state
    machine: [docs/mainnet-simulated-cre-test.md](mainnet-simulated-cre-test.md).

#### F. Chain-blindness — per-lane, not interchangeable

- **Residual risks**
  - **Address reuse across lanes/roles.** Deterministic deploys make the same string mean different
    contracts per `(chain, role)` — the footgun behind the earlier wrong gov-executor mistake. Always
    resolve via the lane's own `<Lane>MigrationConstants.sol`. The code-enforced broadcast-/config-time
    guard against this class is invariant **G-1** (gov-executor, §E); **C-1** (FeeQuoter cap, §D) is a
    deployed-instance/off-chain check only — not enforced in the contracts or scripts (see §Per-network
    differences).
    (`DOC.md §1`, §6.1; [Where the addresses live](#where-the-addresses-live).)
  - **Linea is the odd one out** (Gelato revoke, distinct `LIQUIDITY_OWNER`, half the `gasLimit`,
    lowest FeeQuoter cap). (See [Per-network differences](#per-network-differences).)

#### G. Scope boundary & upstream assurance

- **Residual risks**
  - **Upstream `SyncAutomation` is not known to be audited.** `SyncTrigger`'s shared fee/native
    accounting is *adapted from* (not byte-for-byte) upstream — so "adapted from audited upstream"
    cannot be used to exclude it. It is **in-scope by default** until an upstream audit reference + an
    equivalence `git diff` at the pinned commits land. Deployed-bytecode source-verification is also
    not pinned (state-mate pins the impl *address*, not verified source) — confirm per explorer.
    (`DOC.md §2.2, §2.6`; [Supporting references](#supporting-references).)

#### H. Containment & recovery

- **Audit focus**
  - Owner self-harm via `withdrawETH` / `sweep` is bounded by a zero-recipient guard on **both**
    paths (`CREReceiver.withdrawETH` → `InvalidRecipientAddress`; `SyncTrigger.sweep` →
    `SyncTriggerInvalidRecipient`): a low-level call to the code-less `address(0)` succeeds, so
    without the guard a native transfer would silently burn the balance. A zero `amount` moves no
    funds on either path (`sweep` short-circuits to a no-op).
- **Residual risks**
  - **No pause/upgrade/recovery beyond owner setters + kill-switches.** A whole-LOL-Safe compromise
    loses every LOL-held lever at once; recovery from a bad `expectedAuthor`/forwarder binding is a
    one-time "redeploy + re-pin" across all 4 L2s plus a GovExec containment backstop
    (`CustomSender.revokeRole(SYNC_ROLE, syncTrigger)`) from the independent domain. The
    `WorkflowRegistry` exposes **no** per-workflow ownership transfer. (`ADR-0001`; `DOC.md §3.2, §3.4`.)

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
| **`payInLink`** | Flag in a fee buffer: pay the CCIP fee in LINK instead of native. `SyncTrigger` rejects `true` — LINK payment is not supported. |
| **nullary** | A call with no arguments — calldata is exactly the 4-byte selector (`data.length == 4`). |
| **LOL** | Liquidity Observation Lab — the Lido liquidity multisig (Safe). Post-migration it owns `SyncTrigger`, `CREReceiver`, and the `OraclePool`, and is the CRE workflow owner pinned as `expectedAuthor`. (Distinct from the Lido L2 **governance executor**, which administers `SyncTrigger`'s `SYNC_ROLE` and owns the `CustomSender` admin + `ProxyAdmin`.) |
| **WETH / wstETH** | Wrapped ether (the asset users supply on L2) / wrapped staked ETH (minted on L1, bridged back). |
| **nSLOC** | Normalized source lines of code (comments/blank lines excluded). |
| **state-mate** | Lido's YAML-oracle deploy-verification tool; out of scope. |
