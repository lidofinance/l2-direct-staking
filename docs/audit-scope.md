# Audit Prep Package — `CREReceiver` & `SyncTrigger`

> Lido L2 Direct Staking. Audit scope + preparation package for the **two repo-original
> contracts**: `src/cre/CREReceiver.sol` (new, Lido-authored) and `src/SyncTrigger.sol`
> (Lido-authored, **adapted from upstream `SyncAutomation`** — see §2). Structured per
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

## 1. Review goals

**Overall objective.** Gain assurance that the L2→L1 staking automation cannot be
made to (a) move funds the report author/owner did not intend, (b) be silently bricked
into never syncing, or (c) hand control to an unintended party.

**Security objectives**
1. The CRE report-authentication boundary (`onlyForwarder` → `workflowOwner` →
   `(target, selector)` allow-list → nullary-only) cannot be bypassed or widened.
2. A DON-signed report can never cause anything beyond the intended, rate-limited
   `SyncTrigger.triggerSync()`.
3. `SyncTrigger`'s fee/native/LINK handling forwards the right value and strands none.
4. No single owner misconfiguration permanently and irrecoverably bricks sync.

**Areas of concern** (auditor: weight effort here)
1. `CREReceiver.onReport` / `_extractWorkflowOwner` / `supportsInterface` — #1 churn and
   attack surface; the report-auth boundary and the ERC-165 forwarder gate.
2. The `IReceiver` interfaceId being load-bearing (F-1) — a one-selector mistake silently
   bricks the whole system with no revert.
3. The fee-config length-domain mismatch between `SyncTrigger` and downstream
   `CustomSender` (L-2).
4. `uint48` delay-overflow behaviour in the "deactivated" state (L-1 / I-2).

**Worst-case scenarios**
- A report author or compromised owner key causes an out-of-intent call → funds moved.
- `supportsInterface` / forwarder ABI mismatch → reports silently never delivered →
  WETH accumulates on L2, never staked (this *was* live as F-1).
- `setForwarder(0)` or a mis-wired forwarder permanently bricks `triggerSync` with
  recovery only via slow governance.

**Questions for the auditors**
- Is binding the report author to an owner *key* (not the specific *workflow*
  name/id) sound under owner-key-compromise threat modeling? (F-3)
- Does the off-chain CRE `eth_call` probe tolerate the `uint48`-overflow revert in the
  deactivated state, or does it require a clean `(false, 0)`? (L-1 / I-2)
- Is the no-on-chain-refill native-fee funding model for `SyncTrigger` acceptable as a
  liveness assumption? (L-5)
- Should the generic `(target, selector)` dispatcher be hardened to a single hard-coded
  target/selector given only `triggerSync` is ever used? (F-2)

---

## 2. Code scope

### In scope

| File | nSLOC | Role |
| --- | --- | --- |
| `src/cre/CREReceiver.sol` | 99 | Receives DON-signed CRE reports via the Keystone forwarder; dispatches a whitelisted, argument-less call (production: `SyncTrigger.triggerSync()`). |
| `src/SyncTrigger.sol` | 131 | Decides *when* and *how much* to sync; calls `CustomSender.sync()`, funding the CCIP native fee from its own balance. |
| `src/cre/interfaces/IReceiver.sol` | 4 | Keystone receiver interface — `onReport`-only; **its `interfaceId` (`0x805f2132`) is load-bearing** (F-1). |
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
  *operational* risk (irreversible admin handover, role wiring); covered internally
  (FINDINGS F-4, L-6…L-12). They *configure* the in-scope contracts — relevant as
  context only.
- `test/**`, `*.t.sol`, mocks.

### Boilerplate / forked code

`CREReceiver` is fully new. `SyncTrigger` is adapted from upstream `SyncAutomation`
(Keeper→CRE refactor; see the provenance note above). Net-new effort should weight the
CRE receiver and the `SyncTrigger` trigger-decision / forwarder-wiring logic; the shared
fee accounting is in-scope until the equivalence diff + upstream-audit carrier land.

---

## 3. Build & verification

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

### Review-lead verification coverage

The `FINDINGS.md` review-leads that are not closed by an on-chain code change are verified
operationally; this maps each to **where** it is checked (so the residual process risk is explicit,
not silent). The first three are enforced in code (with tests); the rest are verification/operational:

| Lead | How it is addressed | Where |
| --- | --- | --- |
| **L-2** (fee-length mismatch) | `SyncTrigger` setters validate with the consumer's decoders (`decodeCCIP`==21 / `decodeFee`≥17) at set-time | code + `SyncTriggerTest` |
| **L-6** (SYNC_ROLE on mis-wired trigger) | `_assertSyncInfrastructure` asserts `SyncTrigger.SENDER()==customSender` | code + fork test |
| **L-8** (handover before Stage 1 complete) | `executeMigrationSteps` runs the full Stage-1-wiring precondition before any irreversible write | code + `test_executeMigrationStepsRevertsOnMiswiredStage1` |
| **L-3** (forwarder version coupling) | Pre-live check: confirm `L2_CRE_FORWARDER.typeAndVersion()` == `"Forwarder and Router 1.0.0"` (CCIP), **not** the legacy `"KeystoneForwarder 1.0.0"` (different `onReport`/metadata ABI) | RUNBOOK §1 pre-live |
| **L-7** (sole SYNC_ROLE holder) | `AccessControlUpgradeable` is non-enumerable on-chain; state-mate reconstructs the **complete** role-member set from logs and asserts `count(SYNC_ROLE)==1` | RUNBOOK G4 table / state-mate |
| **L-9** (L2 author pin ↔ L1 workflow owner) | Reconciled via two independent on-chain reads: live L2 `CREReceiver.getExpectedAuthor()` (the `deploy-cre-workflow` recipe aborts if the registered owner ≠ this pin) vs L1 `WorkflowRegistry.getWorkflowById(id).owner` (`VerifyCREWorkflow`); gate **G2-author** further requires a live `CallExecuted`. Manual `VerifyCREWorkflow` runs must set `CRE_EXPECTED_AUTHOR` from the on-chain L2 pin, not the `L2_LIQUIDITY_OWNER` env fallback | RUNBOOK §2/§3, `VerifyCREWorkflow.s.sol` |
| **L-5** (native fee float runs dry) | Operational: trigger fronts each sync's native fee from its own balance; monitored (`SyncTrigger` balance ≥ 2× `getMaxFees().maxNativeFee`, depletes ~0.005 ETH/sync), top up via `receive()`, recover via owner `sweep()` | RUNBOOK §3 Watch, README §Funding the float |
| **L-10** (new OraclePool unfunded) | Operational: LOL multisig seeds wstETH into each new pool post-G4; until seeded `fastStake` reverts (`sync`/slowStake unaffected) | RUNBOOK §3 Finalize |

---

## 4. Static analysis

| Tool | Status |
| --- | --- |
| **Slither 0.11.5** (`--exclude-dependencies`, filtered to `src/`) | ✅ ran — **14 results, all Low / Informational; 0 High, 0 Medium** — triaged below |
| **`forge lint`** (in-scope `src/`) | 2 advisory warnings (subset of Slither's findings) |

### Slither triage (run 2026-06-04 on the frozen commit)

`slither . --exclude-dependencies --filter-paths "lib/|test/|script/"` → 18 contracts,
101 detectors, **14 results**. None High or Medium:

| Detector | Location | Triage |
| --- | --- | --- |
| `incorrect-equality` (strict `==`) | `SyncTrigger.triggerSync` — `amount == 0` | **Accept.** `amount` is a computed `uint256` floor; `== 0` is the intended "nothing to sync" guard, not a balance equality on attacker-set state. |
| `unused-return` | `SyncTrigger.triggerSync` ignores `CustomSender.sync(...)` return | **Note.** Matches audited upstream `SyncAutomation`. The CCIP `messageId` is dropped; consider capturing/emitting it for off-chain traceability. Auditor to confirm no required check is skipped. |
| `missing-zero-check` | `CREReceiver.withdrawETH(to)` | **Low.** Owner-only; `to == address(0)` would burn ETH (owner self-harm). Align with the contract's other zero-guards — add `if (to == address(0)) revert`. |
| `reentrancy-events` | `CREReceiver.onReport` emits `CallExecuted` after `target.call` | **Accept (benign).** Event-ordering only; the real reentrancy surface is closed by `onlyForwarder` + nullary `data.length == 4`. Matches `test_onReport_reentrancyBlocked`. |
| `timestamp` | `SyncTrigger._getAmountToSync` — `block.timestamp >= _lastExecution + _delay` | **Accept.** Validator-manipulable by seconds; immaterial for a coarse rate-limit window. (Also flagged by `forge lint`; ties to **L-1 / I-2** `uint48` overflow.) |
| `low-level-calls` | `CREReceiver.onReport` (`target.call`), `withdrawETH` (`to.call`) | **By design.** Generic dispatcher + ETH withdraw; both gated. Informational. |
| `naming-convention` | `SyncTrigger.SENDER` / `DEST_CHAIN_SELECTOR` / `WNATIVE` (immutables UPPER_CASE) + ISyncTrigger getters | **Accept.** Intentional constant-style naming on immutables; mirrors upstream. |
| `unindexed-event-address` | `ISyncTrigger.ForwarderSet(address)` not indexed | **Low / consistency.** `CREReceiver.ForwarderUpdated` *is* indexed — consider indexing `ForwarderSet` for off-chain filtering. |

**Net:** the static-analysis surface is clean — no High/Medium. The actionable items are
two consistency nits (`withdrawETH` zero-check, `ForwarderSet` indexing) and the
`unused-return` messageId observation; the rest are accepted-by-design and documented
here so the auditor isn't re-deriving them.

---

## 5. Test coverage (measured 2026-06-04, unit suite)

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
  delivery gate** (the blind spot that let F-1 ship).

---

## 6. Architecture & call flow

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

## 7. Actors & privileges

Separated per FPF A.15 (Role ≠ RoleAssignment ≠ Method/capability ≠ Work): the **role**
is the authority slot, the **holder** is the concrete on-chain address filling it (which
*changes* at migration — that handover Work event is itself the F-4 risk), and the
**gated methods** are the capability the holder may enact.

| Role | Holder (RoleAssignment): deploy → post-migration | Gated methods (capability) | Handover (Work event) |
| --- | --- | --- | --- |
| **`CREReceiver` owner** | deployer EOA → **LOL multisig** | `setForwarder`, `setExpectedAuthor`, `setAllowedCall`, `withdrawETH` (re-points the whole automation; `withdrawETH` moves value to an arbitrary recipient) | `transferOwnership` in Stage-2 migration (F-4) |
| **`SyncTrigger` owner** | deployer EOA → **LOL multisig** | `setForwarder`, `setDelay`, `setAmounts`, `setFeeOtoD`, `setFeeDtoO`, `sweep` (`sweep` moves value to an arbitrary recipient) | `transferSyncTriggerOwnership` in Stage-1/2 (F-4) |
| **CRE Keystone forwarder** | Chainlink-operated (per-L2 address) | sole caller of `onReport` | set via `L2_CRE_FORWARDER` env at deploy (L-3) |
| **`_expectedAuthor`** | **LOL multisig / Safe** = registered `WorkflowRegistry.owner` | report-author identity (no method; it is the pinned `==` target in `onReport`) | `setExpectedAuthor` (owner-only); bound to an *address*, not a *workflow* (F-3) |
| **`CREReceiver`** | the deployed receiver instance | sole `triggerSync` caller (= `SyncTrigger._forwarder`) | holds no other on-chain privilege by design |

> **Trust stance.** The CRE Keystone forwarder is an **assumed-honest trust boundary**
> (relied on to route only DON-validated reports), distinct from the owner roles, which
> are *held by* a governance multisig and constrained on-chain.

---

## 8. On-chain / off-chain assumptions & trust boundaries

- **Forwarder honesty & ABI/version:** `onReport`'s `metadata[42:62]` slice and
  `onReport(bytes,bytes)` ABI are correct **only** for the CRE/Keystone v1.0.0
  forwarder (`workflowId(32) | workflowName(10) | workflowOwner(20)`). The repo also
  vendors an older brownie `KeystoneForwarder` with a different
  `onReport(bytes32,address,bytes)` ABI. The forwarder is set from `L2_CRE_FORWARDER`
  env with **no on-chain version assertion**. (L-3) **Residual:** confirm each L2's
  *production-deployed* forwarder (Arbitrum/Base/Linea/Optimism) is this same gated
  `KeystoneForwarder` (Chainlink Forwarder Directory).
- **Off-chain probe:** the CRE workflow calls `shouldSync()` off-chain via `eth_call`
  to decide whether to emit a report — sensitive to the L-1 overflow revert.
- **Native-fee funding:** `SyncTrigger` must hold ≥ `nativeAmount` ETH per sync;
  `CREReceiver` calls `triggerSync` with zero value, so there is **no on-chain refill
  path** — an off-chain operator must keep `SyncTrigger` funded. (L-5)
- **Cross-chain mirror:** `CREReceiver._expectedAuthor` (L2) is meant to equal the L1
  `WorkflowRegistry.owner`; the deploy checks read the same operator env on both sides
  (tautological) — reconcile against the actual on-chain L1 registry owner. (L-9)
- **OraclePool liquidity:** the destination pool must be funded for user `fastStake`;
  no on-chain enforcement on mainnet lanes.

---

## 9. Invariants to confirm

> **Statement classification (FPF A.6.B Boundary Norm Square).** Each row is one atomic
> claim routed to exactly one quadrant — **L** Law/definition · **A** Admissibility/gate ·
> **D** Deontic/obligation · **E** Work-effect/evidence. Cite the row ID (`I-1`, `X-1`, …)
> rather than re-paraphrasing. The document's other quadrants live elsewhere: **D**
> obligations in §12 (checklist) and §13 (deliverables); **E** evidence in §3 (build), §4
> (Slither), §5 (coverage). The `(L-n)` tags below cross-reference `FINDINGS.md` leads —
> not the `L` quadrant.

| ID | Q | Claim | Adjudicated against |
| --- | --- | --- | --- |
| **I-1** | L | `CREReceiver._expectedAuthor != address(0)` always (ctor + setter). | source/Description |
| **I-2** | A | Deactivated `SyncTrigger` (`_delay == type(uint48).max`) should mean "no sync", but `_lastExecution + _delay` overflows `uint48` and **reverts** instead. (`L-1`) | source + behaviour |
| **I-3** | A | Only nullary calls dispatch through `onReport` (`data.length == 4`). (`F-2`) | source |
| **I-4** | L | `_forwarder != address(0)`: enforced in `CREReceiver`, **NOT** in `SyncTrigger.setForwarder` → `setForwarder(0)` permanently bricks `triggerSync`. (`L-13`) | source |
| **X-1** | A | Wiring: `SyncTrigger._forwarder == CREReceiver` **and** the allow-list contains `(SyncTrigger, triggerSync.selector)`. Owner-set; confirmable only against a **deployed instance**, not source. (`L-6`) | **deployed Object** |
| **E-1** | L | Rate limit: ≤ `maxAmount` WETH synced per `delay` window (depends on I-2 + config). | source + behaviour |
| **F-S** | A | Fee sufficiency: `SyncTrigger` native balance ≥ `nativeAmount` per sync. (`L-5`) | **deployed Object** + off-chain ops |
| **R-1** | L | Reentrancy: `onReport`'s `target.call` and `sync → refundExcessNative → SyncTrigger.receive()` non-reentrant via `onlyForwarder` + empty `receive()`. | source |

---

## 10. Prior findings (context — auditor to independently confirm)

Internal AI-assisted review (`FINDINGS.md`; Pashov `solidity-auditor` + `x-ray`,
2026-05-31). Confidence is **internal**; several "fixed" items are **uncommitted** in
the working tree — verify against the frozen commit.

| ID | Title | Status |
| --- | --- | --- |
| **F-1** | `supportsInterface` advertised wrong interfaceId (`0x21a4cdb3`) → forwarder rejects receiver → sync bricked on arrival | Fixed (verify) |
| **F-2** | `onReport` allow-list checked only `(target, selector)`; args were author-controlled | Fixed — `data.length == 4` guard |
| **F-3** | `onReport` pins author to an owner *key*, not a specific *workflow* | Deliberate won't-bind — verify rationale |
| **L-1 / I-2** | `type(uint48).max` deactivated delay reverts instead of returning false | Open lead |
| **L-2** | Decoder length-domain mismatch on `feeOtoD` (≥17 vs ==21) → self-DoS in `sync` | Open lead |
| **L-3** | `onReport` coupled to one unpinned forwarder ABI/version | Open lead |
| **L-4** | No explicit `metadata.length` guard before slicing | Open lead |
| **L-5** | `triggerSync` funds CCIP fee from own balance, no refill path | Open lead |
| **L-13** | `SyncTrigger.setForwarder` accepts `address(0)` (self-brick) | Open lead |

**Audit-readiness — per-dimension (not collapsed to one tier).** The earlier x-ray
published a single "🟠 FRAGILE" tier, which was a `min()` over three incommensurable axes
(and is now stale — the Tests input was 60% branch coverage). Reported as the vector it
is, so neither the strong axes nor the real residual is hidden:

| Dimension | Status | Basis |
| --- | --- | --- |
| **Docs** | 🟢 Hardened | this package + `DOC.md` / `README.md` / `RUNBOOK.md` |
| **Access control** | 🟡 Adequate | 0 permissionless entry points; all writers `onlyOwner`/`onlyForwarder` |
| **Tests** | 🟡 Adequate (was Fragile) | unit coverage now **100%** (§5); residual is **no fuzz / invariant / formal** for fee split + 3-layer auth |
| **Process** | 🟡 Watch | single-developer source; no in-repo peer-review signal |

**Not flagged by the internal review (absence NOT proven — `CC-A10.15`):** the CCIP
fee/native/LINK accounting (logically equivalent to upstream `SyncAutomation`; provenance
unverified — see §2 note), `_extractWorkflowOwner` offset for the v1.0.0 layout,
reentrancy, storage-writer authorization, and donation/inflation against OraclePool
(self-harm). These were *not surfaced* by the AI agents / x-ray; that is weaker than
"verified absent" — an AI-assisted pass cannot prove a vulnerability's absence.

---

## 11. Glossary

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

---

## 12. Audit prep checklist

- [x] Review goals documented (§1)
- [x] Static analysis clean/triaged — **Slither 0.11.5 run: 14 results, all Low/Info, 0 High/Medium, triaged** (§4)
- [x] Test coverage > 80% — **both contracts 100% lines/statements/branches/funcs** (§5)
- [x] Dead code removed — Slither flagged none (no `dead-code`/unused-state detector hits in scope)
- [x] Build instructions verified — `forge build` OK (§3)
- [x] Stable version identified — commit `369acb0…`; **tag a dedicated `audit-*` branch** before handoff
- [x] Flowchart / call flow (§6)
- [x] Actors & privileges (§7)
- [x] On-chain/off-chain assumptions & trust boundaries (§8)
- [x] Invariants documented (§9)
- [x] Glossary (§11)
- [ ] Stateful fuzz / invariant tests for fee split + 3-layer auth — **recommended, not present**
- [ ] Formal verification — not configured (optional)

---

## 13. Requested deliverables from the auditor

1. Confirm/refute F-1…F-3 and in-scope leads L-1…L-13 on the frozen commit.
2. Independent findings on the in-scope contracts at all severities.
3. Assessment of the 3-layer report-authentication boundary under owner-key-compromise
   and forwarder-compromise threat models.
4. Recommendations on the test-methodology gaps (fuzz / invariant / formal for fee math
   and auth).
