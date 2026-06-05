# Audit Prep Package — `CREReceiver` & `SyncTrigger`

> Lido L2 Direct Staking. Audit scope + preparation package for the **two repo-original
> contracts**: `src/cre/CREReceiver.sol` (new, Lido-authored) and `src/SyncTrigger.sol`
> (Lido-authored, **adapted from upstream `SyncAutomation`** — see §1). Structured per
> Trail of Bits' audit-preparation checklist.

| | |
| --- | --- |
| **Repo** | `l2-direct-staking` |
| **Frozen commit** | `369acb056d9cf84a71d31012b1059feebef21c93` (2026-06-03) on branch `feat/more-ops-on-lido` — tag a dedicated `audit-*` branch before handoff |
| **Compiler** | `solc 0.8.20`, `evm_version = paris` |
| **Framework** | Foundry (`forge 1.7.1`) |
| **License** | `CREReceiver` MIT · `SyncTrigger` Apache-2.0 |
| **Upgradeability** | None — non-upgradeable `Ownable` contracts |
| **Prepared** | 2026-06-04 |

---

## Intro

**Lido L2 Direct Staking** lets users stake on an L2 and receive `wstETH` without
manually bridging to Ethereum L1. User-supplied WETH accumulates in an L2 `OraclePool`;
periodically that balance is **synced** — bridged to L1 via Chainlink CCIP, staked into
Lido (minting `wstETH`), and the resulting `wstETH` is bridged back to the originating L2
pool to back user `fastStake` / `slowStake` redemptions. The overall goal of the repo is
to make this L2→L1 staking loop **automatic, rate-limited, and authenticated**, so it runs
without a privileged operator pushing each sync by hand.

This repository contributes the **automation layer** — the two repo-original contracts
that decide *when* and *how much* to sync and authenticate the trigger:

- `src/SyncTrigger.sol` — the rate-limited decision/execution contract. It reads the
  pool's WETH balance against a delay window and calls `CustomSender.sync()`, fronting the
  CCIP native fee from its own balance.
- `src/cre/CREReceiver.sol` — receives DON-signed reports from the Chainlink CRE Keystone
  forwarder and dispatches a single whitelisted, argument-less call (in production,
  `SyncTrigger.triggerSync()`).

Everything else on the L2→L1 path (`CustomSender`, `OraclePool`, `FeeCodec`, the CCIP
routers, and the Keystone forwarder) is upstream dependency code — relied on for external
assurance and out of scope here (see §1). Both in-scope contracts are non-upgradeable
`Ownable` with **no permissionless entry points**: every state-changing function is
`onlyOwner` or `onlyForwarder`.

---

## 1. Code scope

### In scope

| File | nSLOC | Role |
| --- | --- | --- |
| `src/cre/CREReceiver.sol` | 99 | Receives DON-signed CRE reports via the Keystone forwarder; dispatches a whitelisted, argument-less call (production: `SyncTrigger.triggerSync()`). |
| `src/SyncTrigger.sol` | 131 | Decides *when* and *how much* to sync; calls `CustomSender.sync()`, funding the CCIP native fee from its own balance. |
| `src/cre/interfaces/IReceiver.sol` | 4 | Keystone receiver interface — `onReport`-only; **its `interfaceId` (`0x805f2132`) is load-bearing**. |
| `src/interfaces/ISyncTrigger.sol` | 31 | Interface / events / errors for `SyncTrigger`. |

**Total in-scope ≈ 226 nSLOC**, 2 non-upgradeable `Ownable` contracts, **0 permissionless
entry points** (every state-changing fn is `onlyOwner` or `onlyForwarder`).

### Out of scope — upstream dependencies (relied-on external assurance, NOT reviewed here)

These are *not asserted correct by this document* — we are choosing not to re-review code
whose assurance belongs to its upstream maintainer. Pinned carriers:

- `lib/chainlink-csr/**` @ `62108f7` (2025-10-23) — `CustomSender`, `OraclePool`,
  `FeeCodec`, `TokenHelper`, `IOraclePool`, `ICustomSender` (Aphyla/chainlink-csr).
- `lib/chainlink-local/**` (incl. vendored `ccip@eb419a0`) — CCIP routers, Keystone
  `KeystoneForwarder` / `IReceiver`.
- `lib/openzeppelin-contracts{,-upgradeable}/**` — `Ownable`, `SafeERC20`, `IERC165`.
- `lib/state-mate/**` — deploy-verification oracle.

> ⚠️ **Provenance claim requiring a carrier (do not rely on as-is).** `SyncTrigger`'s
> fee/native/LINK accounting (`_getAmountToSync`, `getMaxFees`, the `nativeAmount` split,
> and the `CustomSender.sync` call) is **logically equivalent to** upstream
> `SyncAutomation` (`lib/chainlink-csr/contracts/automations/SyncAutomation.sol` @
> `62108f7`) — but `SyncTrigger` is a **refactor, not byte-for-byte**: the Chainlink
> Keeper surface (`checkUpkeep`/`performUpkeep`, `AutomationCompatibleInterface`,
> `cannotExecute`) was replaced with the CRE `triggerSync()` / `onlyForwarder` surface.
> **The upstream `SyncAutomation` is not known to be audited.** No audit report is vendored
> in `lib/chainlink-csr/**` (no `audits/` dir, no reference in its README), and the upstream
> is the reference implementation behind Chainlink's official Direct Staking template, whose
> documentation explicitly disclaims it: *"This template is provided 'AS IS' and 'AS
> AVAILABLE' without warranties of any kind, **has not been audited**…"*
> ([Chainlink CCIP Direct Staking guide](https://docs.chain.link/quickstarts/ccip-direct-staking),
> retrieved 2026-06-04). Lido's own [audits index](https://docs.lido.fi/security/audits/) lists
> no audit for direct staking / CCIP / Custom Sender. **So the "audited upstream" framing used
> elsewhere should not be relied on.** Before any audit-exclusion based on upstream provenance
> can be claimed, the team must attach: (a) a concrete upstream audit report ref + hash (if one
> ever exists), and (b) a `git diff` of the shared accounting between `SyncTrigger` and
> `SyncAutomation` at the pinned commits. Until then the fee accounting is
> *unverified-by-this-document*, and the auditor should treat the shared logic as
> in-scope-by-default.

### Out of scope — separate track

- `script/**` — L1/L2 migration & deploy Foundry scripts (18 files). Bulk of
  *operational* risk (irreversible admin handover, role wiring); covered internally.
  They *configure* the in-scope contracts — relevant as context only.
- `test/**`, `*.t.sol`, mocks.

### Boilerplate / forked code

`CREReceiver` is fully new. `SyncTrigger` is adapted from upstream `SyncAutomation`
(Keeper→CRE refactor; see the provenance note above). Net-new effort should weight the
CRE receiver and the `SyncTrigger` trigger-decision / forwarder-wiring logic; the shared
fee accounting is in-scope until the equivalence diff + upstream-audit carrier land.

---

## 2. Build & verification

Prerequisites: Foundry (`forge 1.7.1`), git, submodules.

```bash
git clone <repo> && cd l2-direct-staking
git checkout 369acb056d9cf84a71d31012b1059feebef21c93   # frozen commit
forge install                                            # or: git submodule update --init --recursive
forge build                                              # ✓ verified: builds clean (lint warnings only)
forge test --match-path "test/{CREReceiverTest,SyncTriggerTest}.t.sol"   # unit suite, no RPC needed
```

Fork suites (`test/*PoolUpgrade.t.sol`) require per-chain RPC env
(`L1_RPC_URL`, `L2_{OPTIMISM,ARBITRUM,LINEA,BASE}_RPC_URL`) — see `foundry.toml`
`[rpc_endpoints]`. **Verified 2026-06-04:** `forge build` = BUILD OK.

---

## 3. Static analysis

Slither 0.11.5 (`--exclude-dependencies`, filtered to `src/`) and `forge lint` were run on
the frozen commit: **14 results, all Low / Informational — 0 High, 0 Medium**, each
triaged as accepted-by-design or a minor consistency nit.

---

## 4. Test coverage (measured 2026-06-04, unit suite)

`forge coverage --match-path "test/{CREReceiverTest,SyncTriggerTest}.t.sol"`:

| File | % Lines | % Statements | % Branches | % Funcs |
| --- | --- | --- | --- | --- |
| `src/cre/CREReceiver.sol` | **100%** (54/54) | **100%** (59/59) | **100%** (14/14) | **100%** (12/12) |
| `src/SyncTrigger.sol` | **100%** (81/81) | **100%** (74/74) | **100%** (10/10) | **100%** (24/24) |

- Both in-scope contracts now have **full line, statement, branch, and function
  coverage** from the unit suites (`CREReceiverTest` 35 fns, `SyncTriggerTest` 40 fns).
- `SyncTrigger` was raised from 80% lines / 60% branches by adding `triggerSync`
  happy-path tests across all `payInLink` permutations (native / LINK / mixed), the
  max-amount cap, the rate-limit re-trigger guard, `getMaxFees`, and the
  `getAmountToSync` wrapper — the previously-dead fee-decoding paths. The gap had been
  caused by tests setting sub-17-byte fee buffers (`hex"deadbeef"`) that
  `FeeCodec.decodeFeeMemory` could never decode.
- **Methodology gaps (carry-over):** **0 stateful fuzz / 0 invariant / 0 formal** tests
  for the fee split or the 3-layer auth — exactly where they pay off. Unit tests
  `vm.prank` the forwarder and call `onReport` directly, **bypassing the real ERC-165
  delivery gate** (the blind spot that let the original delivery bug ship).

---

## 5. Architecture & call flow

```
CRE DON  ──signs report──►  CRE Keystone Forwarder (L2, Chainlink-operated)
                                     │  gate: supportsInterface(0x805f2132) && supportsInterface(0x01ffc9a7)
                                     ▼
                            CREReceiver.onReport(metadata, report)            [onlyForwarder]
                                     │  1. workflowOwner == _expectedAuthor
                                     │  2. (target, selector) allow-listed
                                     │  3. data.length == 4   (nullary only)
                                     ▼
                            target.call(data)  ──►  SyncTrigger.triggerSync()  [onlyForwarder = CREReceiver]
                                                          │  re-checks delay + pool WETH balance
                                                          ▼
                            CustomSender.sync{value: nativeFee}(dstSelector, amount, feeOtoD, feeDtoO)
                                                          │  pulls WETH from OraclePool, bridges via CCIP
                                                          ▼
                                              L1 staking → wstETH bridged back to L2
```

> ⚠️ Two distinct `_forwarder` values — do not conflate:
> `CREReceiver._forwarder` = the **Chainlink CRE Keystone forwarder**;
> `SyncTrigger._forwarder` = the **`CREReceiver`** (sole authorized `triggerSync` caller).

---

## 6. Actors & privileges

Separated per FPF A.15 (Role ≠ RoleAssignment ≠ Method/capability ≠ Work): the **role**
is the authority slot, the **holder** is the concrete on-chain address filling it (which
*changes* at migration — that handover Work event is itself the highest migration risk), and the
**gated methods** are the capability the holder may enact.

| Role | Holder (RoleAssignment): deploy → post-migration | Gated methods (capability) | Handover (Work event) |
| --- | --- | --- | --- |
| **`CREReceiver` owner** | deployer EOA → **LOL multisig** | `setForwarder`, `setExpectedAuthor`, `setAllowedCall`, `withdrawETH` (re-points the whole automation; `withdrawETH` moves value to an arbitrary recipient) | `transferOwnership` in Stage-2 migration |
| **`SyncTrigger` owner** | deployer EOA → **LOL multisig** | `setForwarder`, `setDelay`, `setAmounts`, `setFeeOtoD`, `setFeeDtoO`, `sweep` (`sweep` moves value to an arbitrary recipient) | `transferSyncTriggerOwnership` in Stage-1/2 |
| **CRE Keystone forwarder** | Chainlink-operated (per-L2 address) | sole caller of `onReport` | set via `L2_CRE_FORWARDER` env at deploy |
| **`_expectedAuthor`** | **LOL multisig / Safe** = registered `WorkflowRegistry.owner` | report-author identity (no method; it is the pinned `==` target in `onReport`) | `setExpectedAuthor` (owner-only); bound to an *address*, not a *workflow* |
| **`CREReceiver`** | the deployed receiver instance | sole `triggerSync` caller (= `SyncTrigger._forwarder`) | holds no other on-chain privilege by design |

> **Trust stance.** The CRE Keystone forwarder is an **assumed-honest trust boundary**
> (relied on to route only DON-validated reports), distinct from the owner roles, which
> are *held by* a governance multisig and constrained on-chain.

---

## 7. On-chain / off-chain assumptions & trust boundaries

- **Forwarder honesty & ABI/version:** `onReport`'s `metadata[42:62]` slice and
  `onReport(bytes,bytes)` ABI are correct **only** for the CRE/Keystone v1.0.0
  forwarder (`workflowId(32) | workflowName(10) | workflowOwner(20)`). The repo also
  vendors an older brownie `KeystoneForwarder` with a different
  `onReport(bytes32,address,bytes)` ABI. The forwarder is set from `L2_CRE_FORWARDER`
  env with **no on-chain version assertion**. **Residual:** confirm each L2's
  *production-deployed* forwarder (Arbitrum/Base/Linea/Optimism) is this same gated
  `KeystoneForwarder` (Chainlink Forwarder Directory).
- **Off-chain probe:** the CRE workflow calls `shouldSync()` off-chain via `eth_call`
  to decide whether to emit a report — sensitive to the deactivated-delay overflow revert.
- **Native-fee funding:** `SyncTrigger` must hold ≥ `nativeAmount` ETH per sync;
  `CREReceiver` calls `triggerSync` with zero value, so there is **no on-chain refill
  path** — an off-chain operator must keep `SyncTrigger` funded.
- **Cross-chain mirror:** `CREReceiver._expectedAuthor` (L2) is meant to equal the L1
  `WorkflowRegistry.owner`; the deploy checks read the same operator env on both sides
  (tautological) — reconcile against the actual on-chain L1 registry owner.
- **OraclePool liquidity:** the destination pool must be funded for user `fastStake`;
  no on-chain enforcement on mainnet lanes.

---

## 8. Invariants to confirm

> **Statement classification (FPF A.6.B Boundary Norm Square).** Each row is one atomic
> claim routed to exactly one quadrant — **L** Law/definition · **A** Admissibility/gate ·
> **D** Deontic/obligation · **E** Work-effect/evidence. Cite the row ID (`I-1`, `X-1`, …)
> rather than re-paraphrasing. The **E** evidence for these claims lives in §2 (build), §3
> (Slither), and §4 (coverage).

| ID | Q | Claim | Adjudicated against |
| --- | --- | --- | --- |
| **I-1** | L | `CREReceiver._expectedAuthor != address(0)` always (ctor + setter). | source/Description |
| **I-2** | A | Deactivated `SyncTrigger` (`_delay == type(uint48).max`) returns "no sync": `_getAmountToSync` computes the threshold in `uint256`, so the max delay is simply unreachable and cannot overflow/revert. | source + behaviour |
| **I-3** | A | Only nullary calls dispatch through `onReport` (`data.length == 4`). | source |
| **I-4** | L | `_forwarder != address(0)`: enforced in **both** `CREReceiver.setForwarder` and `SyncTrigger.setForwarder` (each rejects `address(0)`), so the forwarder cannot be zeroed into a permanent `triggerSync` brick. | source |
| **X-1** | A | Wiring: `SyncTrigger._forwarder == CREReceiver` **and** the allow-list contains `(SyncTrigger, triggerSync.selector)`. Owner-set; confirmable only against a **deployed instance**, not source. | **deployed Object** |
| **E-1** | L | Rate limit: ≤ `maxAmount` WETH synced per `delay` window (depends on I-2 + config). | source + behaviour |
| **F-S** | A | Fee sufficiency: `SyncTrigger` native balance ≥ `nativeAmount` per sync. | **deployed Object** + off-chain ops |
| **R-1** | L | Reentrancy: `onReport`'s `target.call` and `sync → refundExcessNative → SyncTrigger.receive()` non-reentrant via `onlyForwarder` + empty `receive()`. | source |

---

## 9. Glossary

| Term | Meaning |
| --- | --- |
| **CRE** | Chainlink Runtime Environment — off-chain workflow platform that emits signed reports. |
| **DON** | Decentralized Oracle Network — the node set that signs CRE reports. |
| **Keystone forwarder** | On-chain Chainlink contract that validates a DON report and calls `onReport` on the receiver (after an ERC-165 gate). |
| **`onReport`** | The single forwarder→receiver entry point; its selector `0x805f2132` defines the `IReceiver` interfaceId. |
| **workflowOwner / workflowName / workflowId** | CRE report metadata: the owner key, an owner-scoped label, and a content hash of the workflow. |
| **`CustomSender`** | Upstream chainlink-csr contract that performs the CCIP send (`sync`). |
| **`OraclePool`** | L2 pool that accumulates user WETH awaiting sync. |
| **sync** | The L2→L1 operation: pull WETH from the pool, bridge to L1 for staking, bridge wstETH back. |
| **OtoD / DtoO** | Origin-to-Destination / Destination-to-Origin CCIP fee legs (`feeOtoD` / `feeDtoO`). |
| **`payInLink`** | Flag in a fee buffer: pay the CCIP fee in LINK (vs native). |
| **LOL** | Lido-on-L2 (operator/governance multisig that owns the contracts post-migration). |
| **Forwarder (SyncTrigger)** | The `CREReceiver` — the only address allowed to call `triggerSync`. |
| **state-mate** | Lido's YAML-oracle deploy-verification tool. |
