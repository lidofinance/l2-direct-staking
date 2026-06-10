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
**Audit revision**: to be frozen — candidate `main @ 145affb` (2026-06-10). Pin the exact
freeze-commit hash here once it lands, and re-run the measurements in [Build & verify](#build--verify)
against that commit (the Slither/coverage figures below are bound to it).
**Compiler**: `solc 0.8.20`, `evm_version = paris`.
**Framework**: Foundry (`forge 1.7.1`).
**Upgradeability**: none — non-upgradeable `Ownable`.


### Primary targets

| File | nSLOC | Notes |
|------|------:|-------|
| [`src/cre/CREReceiver.sol`](../src/cre/CREReceiver.sol) | ~135 | Receives DON-signed CRE reports via the Keystone forwarder; dispatches a whitelisted, argument-less call (production: `SyncTrigger.triggerSync()`). New, Lido-authored. License: MIT. |
| [`src/SyncTrigger.sol`](../src/SyncTrigger.sol) | ~135 | Decides *when* and *how much* to sync; calls `CustomSender.sync()`, funding the CCIP native fee from its own balance. Adapted from upstream `SyncAutomation` (Keeper→CRE refactor). License: Apache-2.0. |

**Total in-scope ≈ 270 nSLOC** (re-measured 2026-06-10 at `145affb`; the growth vs the earlier
≈230 figure is mostly a multi-line formatting pass on `CREReceiver` plus three new owner-setter
guards — logic delta is ~10 lines), 2 non-upgradeable `Ownable` contracts, **0
permissionless state-mutating function entry points** (the payable `receive()` fallbacks accept
ETH from anyone — the intended, harmless float-funding path; see [D. Fee configuration &
liveness](#d-fee-configuration--liveness)).

### Supporting references

| File                                               | Notes                                                                                                                                                                                                                                                                                     |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/cre/interfaces/IReceiver.sol`                 | Keystone receiver interface — `onReport`-only; **its `interfaceId` (`0x805f2132`) is load-bearing** (a one-selector mistake silently bricks delivery). The file is reference, but the id **match** is asserted in the in-scope `CREReceiver.supportsInterface` and is an audit-focus item (§B).                                                                                                                                    |
| `src/interfaces/ISyncTrigger.sol`                  | Interface / events / errors for `SyncTrigger`.                                                                                                                                                                                                                                            |
| `lib/chainlink-csr/**` @ `62108f7`                 | Upstream `CustomSender`, `OraclePool`, `FeeCodec`, `TokenHelper` — **out of scope** (relied-on upstream code). `SyncTrigger`'s fee/native/LINK accounting is *adapted from* (not byte-for-byte) upstream `SyncAutomation` at this commit. **Caveat — load-bearing for scope size:** upstream `SyncAutomation` is **not known to be audited** (no audit report vendored in `lib/chainlink-csr`; Chainlink's Direct-Staking reference template is published "AS IS … has not been audited"). So "adapted from audited upstream" must **not** be used to exclude this logic. Until (a) a concrete upstream audit reference and (b) an equivalence `git diff` of the shared accounting between `SyncTrigger` and `SyncAutomation` at the pinned commits are attached, treat the shared accounting as **in-scope by default**. |
| `lib/chainlink-local/**` (vendored `ccip@eb419a0`) | CCIP routers, `KeystoneForwarder` / `IReceiver` — out of scope.                                                                                                                                                                                                                           |
| `lib/openzeppelin-contracts{,-upgradeable}/**`     | `Ownable`, `SafeERC20`, `IERC165` — out of scope (relied-on upstream).                                                                                                                                                                                                                    |
| `script/**`                                        | L1/L2 migration & deploy Foundry scripts — separate operational track; they *configure* the in-scope contracts (role wiring, irreversible admin handover). Relevant as context — summarised under [Migration & operations plan](#migration--operations-plan).                              |
| `test/**`, mocks                                   | Unit + fork suites — out of scope; see [Build & verify](#build--verify).                                                                                                                                                                                                                  |

## Build & verify

Prerequisites: Foundry (`forge 1.7.1`), git + submodules. Compiler `solc 0.8.20`,
`evm_version = paris`. Licenses: `CREReceiver` MIT · `SyncTrigger` Apache-2.0.

```bash
git clone <repo> && cd l2-direct-staking
git checkout <audit-rev>                 # the frozen audit revision (TBD — see Scope)
forge install                            # or: git submodule update --init --recursive
forge build                              # builds clean (lint warnings only)

# Unit suite — no RPC needed; this is the in-scope coverage:
forge test --match-path "test/{CREReceiverTest,SyncTriggerTest}.t.sol"

# Fork suites (test/*PoolUpgrade.t.sol, CREIntegrationTest, L2GovernanceExecutorGuard)
# exercise the migration scripts against forked chains and need RPC env vars:
#   L1_RPC_URL, L2_{OPTIMISM,ARBITRUM,BASE,LINEA}_RPC_URL
# Point these at LOCAL forks, not public RPCs.
forge test
```

**Static analysis & coverage** (team prep, measured 2026-06-04 — re-confirm on the audit
revision; since then three guard branches and their tests were added — zero-recipient
`withdrawETH`, `setDelay(0)`, `setFeeOtoD` gas-limit floor — and the full 80-test unit suite
passes at `145affb`):

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

### Actors & privileges

The whole point of the repo is to *change* who holds the keys, so three things are kept
strictly distinct below: the **role** (an authority slot — e.g. "owner of `SyncTrigger`"), the
**holder** (the concrete address filling the slot, which moves from a deploy-time EOA to a Lido
principal *during migration*), and the **gated capability** (the functions that holder may
call). The deploy/handover steps that move a holder are the migration itself — and the
highest-risk operational events in this repo (per the `DOC.md §6.4` severity table).

The two in-scope contracts end up under **two different** Lido principals — do not conflate
them:

| Role (authority slot) | Holder: deploy → post-migration | Gated capability |
| --- | --- | --- |
| **`SyncTrigger` owner** | Lido Deployer EOA → **Lido L2 governance executor** (per-L2 bridge executor, e.g. `OptimismBridgeExecutor`; runs proposals bridged from the L1 Lido DAO) | `setForwarder`, `setDelay`, `setAmounts`, `setFeeOtoD`, `setFeeDtoO`, `sweep` — `sweep` moves any ERC-20 *or* native balance (incl. the fee float) to an arbitrary recipient |
| **`CREReceiver` owner** | Lido Deployer EOA → **LOL multisig** (Safe) | `setForwarder`, `setExpectedAuthor`, `setAllowedCall`, `withdrawETH` — `withdrawETH` moves native balance (normally ~0) to an arbitrary recipient |
| **`CREReceiver` forwarder** (`_forwarder`) | **Chainlink CRE Keystone forwarder** (per-L2, Chainlink-operated) | sole caller of `onReport`; set via `L2_CRE_FORWARDER` at deploy, **no on-chain version/ABI assertion** (the deploy script can anchor the address via `_expectedCREForwarder()` — see §B; per-lane pins **not yet populated**) |
| **`SyncTrigger` forwarder** (`_forwarder`) | the deployed **`CREReceiver`** instance | sole caller of `triggerSync` — note "forwarder" denotes a *different* contract on each in-scope contract |
| **`expectedAuthor` pin** | **LOL multisig** (Safe) = registered CRE `WorkflowRegistry` owner = `CREReceiver` owner | not a method — the report-author identity that `onReport` checks `==` against; re-pointable only via `setExpectedAuthor` (owner-only), and bound to an *address*, not a *workflow* name/id |
| **`SYNC_ROLE` on `CustomSender`** (upstream) | old Chainlink Automation → the new **`SyncTrigger`** | lets the `triggerSync → sync` call actually pull WETH from the pool; granted/revoked in Stage 2 |

**End-state invariant** (asserted by tests, monitored in prod), per L2:
`WorkflowRegistry.owner == CREReceiver.getExpectedAuthor() == CREReceiver.owner() == LOL multisig`
(see [ADR-0001](adr/0001-cre-workflow-owner-multisig.md)).

**Two hats, cleanly split.** The **LOL multisig** holds the *liquidity / workflow* authority —
`CREReceiver`, the L2 `OraclePool` (upstream), the CRE workflow, and the `expectedAuthor` pin.
The **Lido L2 governance executor** holds the *protocol-governance* authority — `SyncTrigger`,
the `CustomSender` `DEFAULT_ADMIN_ROLE`, and the L2 `ProxyAdmin`.

These holders are put in place by a **two-stage, two-signer migration**, run once per L2: the Lido
Deployer EOA deploys the new contracts and transfers their ownership to the principals above
(Stage 1); the **Initial Owner** (the old admin, `L1MigrationConstants.INITIAL_OWNER`) performs the
irreversible cutover on the pre-existing upstream contracts (Stage 2) — note it is an **external,
non-Lido party** (see [Invariants and attention points](#invariants-and-attention-points),
"E. Migration handoff & wiring"). Post-migration the Lido Deployer EOA and the Initial Owner
hold **zero on-chain power** over these contracts. Full sequence, gates, and failure modes:
[Migration & operations plan](#migration--operations-plan).

### Migration & operations plan

The migration is **not atomic**: each stage is a sequence of separate transactions, run **once per
L2**. Between and within stages the system can sit in a partially-migrated state, so the scripts
bracket every irreversible write with on-chain assertions and keep the irreversible step **last**.
The two stages are run by **different signers**; combining them in one broadcast is blocked on all
four mainnets unless `ALLOW_UNSAFE_COMBINED_RUN=1`.

1. **Stage 1 — `runDeploy()`** (Lido Deployer EOA). Deploy the new `OraclePool` / `SyncTrigger` /
   `CREReceiver`, configure, wire, fund the float, and **transfer ownership** to the post-migration
   holders (`SyncTrigger → gov executor`, `CREReceiver → LOL multisig`). Touches **only the new
   contracts** — fully reversible by discarding them. The broadcast self-reverts
   (`_assertSyncInfrastructure`) if any wire **or operational parameter** is wrong — the in-broadcast
   assert now also reads back `DEST_CHAIN_SELECTOR`, `WNATIVE`, delay, amounts, `feeDtoO` and
   `feeOtoD`, so a typo'd `MigrationConstants` value cannot ship green — and a botched Stage 1
   leaves the live (old) system untouched.
2. **Gate — `runVerifyStage1()`** (anyone, read-only). Confirms Stage 1 is complete and correct
   **and that Stage 2 has not run** (checks `CustomSender.getOraclePool()` still points at the old
   pool, `SYNC_ROLE` is not yet granted, and — a pool/trigger-**independent** tripwire — the gov
   executor does not yet hold `DEFAULT_ADMIN_ROLE`, which catches a completed Stage 2 even against a
   *different* pool/trigger pair from a repeated `runDeploy`). Run before signing Stage 2.
3. **Stage 2 — `runMigrate()`** (Initial Owner). The irreversible cutover on the **pre-existing**
   sender, in order: `setOraclePool` → `grantSyncRole`(new) → `revokeSyncRole`(old Chainlink
   [+ Gelato on Linea]) → `migrateSenderAdmin` (grant gov-exec, revoke Initial Owner) →
   `transferProxyAdminOwnership`(gov-exec). `migrateSenderAdmin` first asserts the configured
   `initialOwner` *actually holds* `DEFAULT_ADMIN_ROLE` — OZ `revokeRole` is a silent no-op on a
   non-holder, so without this a mis-set `initialOwner` would produce a phantom revoke that the
   postcondition passes trivially, leaving the real admin in place. The broadcast ends with
   `_assertMigrationSteps`, which re-reads every write/revoke and reverts if any did not land.
   Caveat it documents: `CustomSender` is not `AccessControlEnumerable`, so there is **no on-chain
   proof the executor is the *sole* admin** — only the two addresses the migration touches are
   asserted; any pre-existing third admin must be ruled out off-chain before migration.

**If Stage 2 stops mid-way** (the dangerous window): the Initial Owner still holds
`DEFAULT_ADMIN_ROLE` until the penultimate step, so most partial states are **re-runnable** —
re-issue the remaining idempotent `set`/`grant`/`revoke` calls. Two transient states to watch:
between `setOraclePool` and `grantSyncRole` **no automation can sync the new pool** (WETH
accumulates — liveness only, no loss); between `grantSyncRole` and the old-automation `revoke`
**both old and new automations hold `SYNC_ROLE`**. The final step (`ProxyAdmin → gov-exec`) is the
point of no return — afterwards only governance can re-administer the lane.

**Rollback posture:** abandonable up to step 3; committed once Stage 2 completes. There is **no
on-chain undo** — recovery after a bad cutover is a fresh governance / Initial-Owner action, not a
script flag.

### Trust surface

- Only the relevant **owner** can call the setters, `SyncTrigger.sweep()`, and
  `CREReceiver.withdrawETH()` — the Lido L2 governance executor for `SyncTrigger`, the LOL
  multisig for `CREReceiver` (see [Actors & privileges](#actors--privileges)). There is **no
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
| `script/optimism/sepolia/SepoliaMigrationConstants.sol` | Testnet equivalents (opts out of the gov-executor guard; smaller float). |
| `script/l1/L1MigrationConstants.sol` | `INITIAL_OWNER` (the external Stage-2 signer) plus the **shared** L1 receiver / `ProxyAdmin`. |
| Deploy-time env | `L2_CRE_FORWARDER` (Chainlink-operated; not in any constants file — anchored at read-time against the per-network `_expectedCREForwarder()` pin when populated, see §B), with `LIDO_L2_GOVERNANCE_EXECUTOR` / `L2_SYNC_TRIGGER_INITIAL_FLOAT` echoed for the broadcast-time guards. |
| `script/<net>/state-mate/<net>.yaml` | Deployed-state verification oracle; fee bytes left `null` ("set during migration"). |

Cross-references: `DOC.md §1` (Networks) and `DOC.md §6.1` (the two different "initial" accounts).

### Per-network differences

The four lanes are **not** interchangeable. Linea is the consistent outlier; Arbitrum has its own
return-leg quirk. A uniform change applied to all four is a footgun — invariants **C-1** (per-lane
FeeQuoter cap) and **G-1** (gov-executor guard) are the broadcast-/config-time guards against
exactly this class of mistake:

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
  - **Forwarder ABI/version not pinned on-chain.** `L2_CRE_FORWARDER` is set with no
    `typeAndVersion` or ABI assertion; the repo vendors two incompatible Keystone forwarders. A
    *script-level* anchor now exists — `L2UpgradeScriptBase._envCREForwarder()` rejects an env
    value that differs from the per-network `_expectedCREForwarder()` pin
    (`L2UpgradeWrongCREForwarder`) before it is baked immutably into `CREReceiver` — but the
    per-lane pins are **not yet populated** (every lane currently returns `address(0)` = opt-out),
    so the guard is dormant until each production forwarder address is pinned. The
    deployed one must be the CCIP `"Forwarder and Router 1.0.0"` (`onReport(bytes,bytes)`), not the
    legacy `onReport(bytes32,address,bytes)` variant — confirm each lane's production forwarder is
    the ERC-165-gated one with the `workflowId(32) | workflowName(10) | workflowOwner(20)` metadata
    layout. (`RUNBOOK.md §1.c`; [Where the addresses live](#where-the-addresses-live).)
  - **DON-embedded author vs registry owner.** `verify-cre-workflow` confirms only the
    `WorkflowRegistry.owner` (plus, since `145affb`: non-zero `workflowId`/`expectedAuthor` inputs
    — closing a false-green against a non-existent workflow — and a non-empty `binaryUrl`); the
    DON-embedded `metadata.workflowOwner` is a **different surface**.
    If the DON embeds a different address (a CRE Early-Access residual), every report fails
    `InvalidAuthor` and all syncs silently stall. The only proof is a live `CREReceiver.CallExecuted`
    — exercise on a throwaway testnet workflow first. (`RUNBOOK.md` gate G2-author; `ADR-0001`.)

#### C. Rate-limiting, deactivation & reentrancy

- **Invariants**
  - **I-2** (*source*): deactivated `SyncTrigger` (`_delay == type(uint48).max`) returns "no sync":
    the threshold is computed in `uint256`, so the max delay is simply unreachable — it cannot
    overflow/revert. Confirm the off-chain CRE `eth_call` probe relies on this clean `(false, 0)`
    rather than tolerating a revert.
  - **I-4** (*source*): `setDelay(0)` reverts (`SyncTriggerInvalidDelay`) — `_delay == 0` would make
    the time gate `block.timestamp >= _lastExecution + 0` always true, permanently defeating the
    rate limiter (a sync would fire every forwarder invocation once the pool crosses `minAmount`,
    draining the fee float at the CRE cron cadence). Deactivation uses `type(uint48).max`, never 0.
  - **R-1** (*source*): reentrancy — `onReport`'s `target.call` and the `sync → refundExcessNative →
    SyncTrigger.receive()` path are non-reentrant via `onlyForwarder` + empty `receive()`.

#### D. Fee configuration & liveness

- **Invariants**
  - **F-1** (*deployed instance + off-chain ops — operating assumption, not a source invariant*):
    fee sufficiency — `SyncTrigger` native balance ≥
    the per-sync fee. Depletion is monotonic (~`actualFee`/sync) with **no on-chain refill** — a
    liveness assumption, not a guarded invariant. Below `getMaxFees().maxNativeFee` the next
    `triggerSync` reverts at the value transfer **with no named error**. Funding is permissionless;
    recovery (`sweep`) is GovExec-only.
  - **F-2** (*source + config*): deploy-time float floor — Stage 1 reverts (`L2UpgradeFloatBelowFloor`)
    if `L2_SYNC_TRIGGER_INITIAL_FLOAT < maxFee + feeDtoO` — the seeded float must cover one
    worst-case sync.
  - **C-1** (*deployed instance + config*): per-lane CCIP `gasLimit` (`FeeOtoD`) is ≤ that lane's
    FeeQuoter `maxPerMsgGasLimit` (7M on OP/Arb/Base, **3M on Linea**); above it, `getFee` reverts
    `MessageGasLimitTooHigh` inside `sync` → the lane halts until a GovExec round-trip. A uniform
    "bump all lanes for safety" passes everywhere **except Linea** — a chain-blind footgun.
    (`docs/fees.md §Consequences > FeeOtoD.gasLimit`.)
  - **F-3** (*source*): `setFeeOtoD` enforces, at set-time, that the encoded `gasLimit` is ≥
    `CustomSender.MIN_PROCESS_MESSAGE_GAS()` (in addition to the exact-21-byte decode check) — a
    decodable config below the sender's floor would otherwise make every `sync` revert
    `CustomSenderInsufficientGas` while `shouldSync` stays true, so the CRE DON would submit a
    reverting tx every tick.
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
  - **Return-leg loss/stall paths.** Arbitrum: if the L1→L2 retryable does not auto-redeem, it must
    be **manually redeemed within ~7 days or the wstETH is lost** — the one return path that can lose
    funds. OP/Base: under-gassed `finalizeDeposit` is permissionlessly replayable. Linea: messages
    >250k gas drop the postman auto-claim. L1: under-gassed `ccipReceive` parks funds for permissionless
    `retryFailedMessage`. (`docs/fees.md §Failure modes`.)

#### E. Migration handoff & wiring

- **Invariants**
  - **W-1** (*deployed instance, per lane*): end-state wiring + ownership — `SyncTrigger._forwarder
    == CREReceiver` and the allow-list holds `(SyncTrigger, triggerSync.selector)`; and
    `WorkflowRegistry.owner == CREReceiver.getExpectedAuthor() == CREReceiver.owner() == LOL
    multisig`, with `SyncTrigger.owner == gov executor`. Owner-set — confirmable only on a deployed
    instance.
  - **G-1** (*source + config*): gov-executor guard — both stages revert
    (`L2UpgradeWrongGovernanceExecutor`) unless the env-supplied executor equals the per-network
    `LIDO_L2_GOVERNANCE_EXECUTOR` constant (Sepolia opts out) — a wrong-but-nonzero executor cannot
    be baked into `SyncTrigger` ownership or the admin / `ProxyAdmin` handover.
- **Residual risks** — the highest-risk, off-chain track.
  - **External Initial Owner & non-atomic, no-forcing-function cutover.** Stage 2 is run by the
    **external, non-Lido** `INITIAL_OWNER` (upstream chainlink-csr admin) as **≥5 independent
    broadcasts** across 5 chains (4× `runMigrate()` + 1× L1 seal), with **no atomicity and no on-chain
    forcing function**. If that party stalls (lost key, dispute, bad faith), Lido **cannot
    self-complete** the handoff. Independently confirm the address *and the party that controls it*
    before Stage 2. (`DOC.md §6.1, §6.4`.)
  - **L1-last security-critical window.** L2-first / L1-last sequencing leaves the external owner
    holding `ProxyAdmin` over the **shared** L1 `LidoCustomReceiver` until the final seal — upgrade
    power over the one contract that stakes/bridges value for **every** lane. The "all L2s migrated
    but L1 not sealed" window is **high-severity and must be kept short** (pre-sign / pre-queue the L1
    seal). The §3.4 kill-switches do **not** cover a retained external `ProxyAdmin` — it can upgrade
    around a pause. (`DOC.md §6.4` severity table; `RUNBOOK.md` Stage 2.) The two transient
    intra-Stage-2 windows are liveness-only (no loss) and detailed in
    [Migration & operations plan](#migration--operations-plan).

#### F. Chain-blindness — per-lane, not interchangeable

- **Residual risks**
  - **Address reuse across lanes/roles.** Deterministic deploys make the same string mean different
    contracts per `(chain, role)` — the footgun behind the earlier wrong gov-executor mistake. Always
    resolve via the lane's own `<Lane>MigrationConstants.sol`. The broadcast-/config-time guards
    against this class are invariants **C-1** (FeeQuoter cap, §D) and **G-1** (gov-executor, §E).
    (`DOC.md §1`, §6.1; [Where the addresses live](#where-the-addresses-live).)
  - **Linea is the odd one out** (Gelato revoke, distinct `LIQUIDITY_OWNER`, half the `gasLimit`,
    lowest FeeQuoter cap). (See [Per-network differences](#per-network-differences).)

#### G. Scope boundary & upstream assurance

- **Residual risks**
  - **Upstream `SyncAutomation` is not known to be audited.** `SyncTrigger`'s shared fee/native/LINK
    accounting is *adapted from* (not byte-for-byte) upstream — so "adapted from audited upstream"
    cannot be used to exclude it. It is **in-scope by default** until an upstream audit reference + an
    equivalence `git diff` at the pinned commits land. Deployed-bytecode source-verification is also
    not pinned (state-mate pins the impl *address*, not verified source) — confirm per explorer.
    (`DOC.md §2.2, §2.6`; [Supporting references](#supporting-references).)

#### H. Containment & recovery

- **Audit focus**
  - Owner self-harm via `withdrawETH` / `sweep`. `withdrawETH` now rejects a zero recipient
    (`InvalidRecipientAddress` — a call to `address(0)` succeeds, silently burning the ETH);
    `SyncTrigger.sweep` still guards **neither** a zero recipient nor a zero amount, and neither
    function guards a zero `amount`.
- **Residual risks**
  - **No pause/upgrade/recovery beyond owner setters + kill-switches.** A whole-LOL-Safe compromise
    loses every LOL-held lever at once; recovery from a bad `expectedAuthor`/forwarder binding is a
    one-time "redeploy + re-pin" across all 4 L2s plus a GovExec containment backstop
    (`SyncTrigger.setForwarder(0)` / `setDelay(max)`) from the independent domain. The
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
| **`payInLink`** | Flag in a fee buffer: pay the CCIP fee in LINK instead of native. |
| **nullary** | A call with no arguments — calldata is exactly the 4-byte selector (`data.length == 4`). |
| **LOL** | Liquidity Observation Lab — the Lido liquidity multisig (Safe). Post-migration it owns `CREReceiver` and the `OraclePool`, and is the CRE workflow owner pinned as `expectedAuthor`. (Distinct from the Lido L2 **governance executor**, which owns `SyncTrigger`.) |
| **WETH / wstETH** | Wrapped ether (the asset users supply on L2) / wrapped staked ETH (minted on L1, bridged back). |
| **nSLOC** | Normalized source lines of code (comments/blank lines excluded). |
| **state-mate** | Lido's YAML-oracle deploy-verification tool; out of scope. |
