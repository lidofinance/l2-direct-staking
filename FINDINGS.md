# 🔐 Security Findings — l2-direct-staking

> Lido L2 Direct Staking — `SyncTrigger`, `CREReceiver`, and L1/L2 upgrade & migration scripts.

| | |
| --- | --- |
| **Date** | 2026-05-31 |
| **Method** | Pashov `solidity-auditor` (v2) — 8 parallel hacking agents (vector-scan, math-precision, access-control, economic-security, execution-trace, invariant, periphery, first-principles), deduplicated by `group_key` and gate-evaluated. Headline finding additionally hand-verified against the vendored forwarder. |
| **Confidence threshold** | 80 (≥80 = description + fix; below = description only) |
| **Files in scope** | `src/SyncTrigger.sol`, `src/cre/CREReceiver.sol`, and 18 `script/**` migration/deploy files (`L1*`, `L2UpgradeActions/ScriptBase`, `{Arbitrum,Base,Linea,Optimism}*`, `optimism/sepolia/*`). Excluded: `interfaces/`, `lib/`, `test/`, `*.t.sol`, mocks. |

⚠️ AI-assisted review. AI analysis cannot prove the absence of vulnerabilities. Team review, a bug-bounty, and on-chain monitoring are still recommended.

---

## Summary

| ID | Conf. | Agents | Title | Status |
|----|-------|--------|-------|--------|
| **F-1** | 95 | 2 | `CREReceiver.supportsInterface` returns the wrong interface id → CRE forwarder rejects it → `onReport` never delivered → **automated sync bricked** | 🟢 Fixed (uncommitted) |
| **F-2** | 75 | 3 | `CREReceiver.onReport` allow-list checks only `(target, selector)` — call **arguments** are report-author-controlled | 🟢 Fixed (uncommitted) |
| **F-3** | 75 | 3 | `CREReceiver.onReport` pins author to an owner **key**, not a specific **workflow** | 🟢 Resolved — documented |
| **F-4** | 75 | 2 | L2 migration trusts an unvalidated `L2_GOVERNANCE_EXECUTOR` env for irreversible admin handover | 🟢 Fixed (uncommitted) |
| **L-1 … L-13** | — | — | Leads (high-signal trails, not fully exploited) — see [Leads](#leads) and [X-Ray](#-pre-audit-x-ray-audit-readiness) | 🔵 Review |
| **X-Ray** | — | — | Audit-readiness verdict 🟠 **FRAGILE**, invariant gaps, test/process observations — see [Pre-Audit X-Ray](#-pre-audit-x-ray-audit-readiness) | 🔵 Review |

---

## Findings

### F-1 — `CREReceiver.supportsInterface` advertises the wrong interface id → CRE forwarder never delivers reports (sync bricked)

> ✅ **Fixed in the working tree (2026-06-01, uncommitted).** `src/cre/interfaces/IReceiver.sol` reduced to `onReport`-only (so `type(IReceiver).interfaceId == 0x805f2132`); `CREReceiver` now inherits `IERC165` and `supportsInterface` returns `0x805f2132 || 0x01ffc9a7`; `getForwarder` demoted to a plain accessor (out of the interface). De-contaminated all **10** `script/*/state-mate/*.yaml` oracles (now assert `0x805f2132` **and** `0x01ffc9a7`) and the `supportsInterface` unit tests (now assert both forwarder-probed ids and reject the old `0x21a4cdb3`). `forge build` clean; **34/34** `CREReceiverTest` pass. Residual unchanged: confirm the production L2 forwarder still ERC-165-gates delivery. The analysis below is retained for the record.

- **Confidence:** 95 (validated 2026-06-01 against official Chainlink CRE docs + the exact upstream source `ccip@eb419a0`; see Appendix A) · **Convergence:** periphery + first-principles agents (both as FINDING), plus a supporting lead
- **Location:** `src/cre/CREReceiver.sol:97-98`, `src/cre/interfaces/IReceiver.sol`
- **Impact:** The entire CRE → `onReport` → `SyncTrigger.triggerSync` automation is **dead on arrival** — the forwarder classifies `CREReceiver` as an invalid receiver and never calls it, so accumulated WETH on each L2 is never bridged to L1 and staked. This defeats the core purpose of the system. No attacker required; it fails in normal operation.

**Root cause**

`CREReceiver` re-declares a local **3-function** `IReceiver` (`onReport` + `getForwarder` + `supportsInterface`), so its `type(IReceiver).interfaceId` is `0x21a4cdb3`. `supportsInterface` returns true *only* for that id:

```solidity
// src/cre/CREReceiver.sol:97
function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
    return interfaceId == type(IReceiver).interfaceId;   // 0x21a4cdb3 only
}
```

The Chainlink CRE/Keystone forwarder checks a **different** id and additionally requires the ERC-165 base id — `CREReceiver` returns `false` for **both**, so the gate fails. (Full trace in [Appendix A](#appendix-a--f-1-verification-trace).)

**Why the local `IReceiver` has three functions — and why it must not.** The Keystone protocol's receiver interface is **`onReport(bytes,bytes)` and nothing else** (`type(IReceiver).interfaceId == 0x805f2132`); that single function is the entire forwarder↔receiver contract. Lido instead hand-wrote a local `IReceiver` that bundles everything the contract exposes:

| Member of Lido's `IReceiver` | Required by the Keystone protocol? | Where it's actually used |
| --- | --- | --- |
| `onReport(bytes,bytes)` | **Yes** — the forwarder calls it | the sync entry point |
| `getForwarder()` | **No** — the protocol never calls it | Lido's own deploy asserts (`L2UpgradeActions.s.sol:173-175`) + state-mate; mirrors `SyncTrigger.getForwarder()` |
| `supportsInterface(bytes4)` | **As a function yes (ERC-165) — but via `IERC165`, not as a member of the receiver interface** | the forwarder's ERC-165 gate |

`type(IReceiver).interfaceId` is the **XOR of every selector declared in the interface**, so folding in `getForwarder` (`0xa0042526`) and `supportsInterface` (`0x01ffc9a7`) silently moved the id from `0x805f2132` to `0x21a4cdb3`. **Either extra member alone** changes the id and breaks the gate; here both were added. The correct shape mirrors the canonical `KeystoneFeedsConsumer` / `ReceiverTemplate` — a single-function `IReceiver` plus a separately-inherited `IERC165`, with `getForwarder` kept as a plain getter outside any forwarder-facing interface:

```solidity
interface IReceiver { function onReport(bytes calldata, bytes calldata) external; }  // id 0x805f2132

contract CREReceiver is IReceiver, IERC165, Ownable {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IReceiver).interfaceId   // 0x805f2132
            || id == type(IERC165).interfaceId;     // 0x01ffc9a7
    }
    function getForwarder() external view returns (address) { return _forwarder; } // app getter, NOT in IReceiver
}
```

**Why every safety net misses it.** This is the dangerous part: three layers don't merely fail to catch the bug — they *encode the wrong id and actively confirm it*.

1. **Tests bypass the gate entirely.** `test/CREReceiverTest.t.sol` and `test/CREIntegrationTest.t.sol` `vm.prank(forwarder)` and call `onReport` **directly**, never going through the forwarder's `route()` ERC-165 gate.
2. **The one `supportsInterface` unit test asserts the *wrong* id.** `test_supportsInterface_IReceiver` (`CREReceiverTest.t.sol:318-319`) asserts `supportsInterface(type(IReceiver).interfaceId)` — i.e. `supportsInterface(0x21a4cdb3) == true` — and `test_supportsInterface_unknownReturnsFalse` only probes `0xdeadbeef`. Nothing asserts the two ids the forwarder actually queries (`0x805f2132`, `0x01ffc9a7`); `0x01ffc9a7` in fact returns `false`.
3. **The state-mate deploy oracle bakes the wrong id into all six chains.** Every `script/*/state-mate/*.yaml` (arbitrum, base, linea, optimism + sepolia; both resolved and `*-l2-upgrade.template.yaml`) pins:
   ```yaml
   supportsInterface:
     - args: ["0x21a4cdb3"] # IReceiver
       result: true
   ```
   The deployed contract *does* return `true` for `0x21a4cdb3`, so state-mate **passes** — it validates the receiver against itself rather than against the forwarder's requirement. This is the same **contaminated-oracle false-pass** class as the earlier Base/Linea gov-executor bug: the *expected* value was derived from the buggy interface, so the safety net green-lights the defect.

(Foundry post-conditions `_assertSyncInfrastructure` / `verifyStage1` separately check `getForwarder` / `expectedAuthor` / the allow-list but never exercise the ERC-165 delivery path, so they are silent here too.)

**Fix**

```diff
     function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
-        return interfaceId == type(IReceiver).interfaceId;
+        // The forwarder gates delivery on ERC165Checker.supportsInterface(receiver, 0x805f2132),
+        // which FIRST probes the ERC165 base id 0x01ffc9a7. The local 3-function IReceiver id
+        // (0x21a4cdb3) matches neither, so reports are silently never delivered.
+        return interfaceId == 0x805f2132   // keystone IReceiver (onReport-only) interface id
+            || interfaceId == 0x01ffc9a7;  // ERC165 base id (type(IERC165).interfaceId)
     }
```

Alternatively, redeclare the local `IReceiver` as the single-function `onReport(bytes,bytes)` interface (so `type(IReceiver).interfaceId == 0x805f2132`) and return `... || type(IERC165).interfaceId`.

**Also add a regression guard** to `_assertSyncInfrastructure` / `verifyStage1`:

```solidity
require(IERC165(creReceiver).supportsInterface(0x805f2132), "receiver not forwarder-compatible");
require(IERC165(creReceiver).supportsInterface(0x01ffc9a7), "receiver missing ERC165 base");
```

**Also de-contaminate the checks** so they assert the forwarder's real requirement, not the buggy id:
- every `script/*/state-mate/*.yaml`: replace the single `supportsInterface args: ["0x21a4cdb3"]` entry with two entries asserting `0x805f2132 → true` and `0x01ffc9a7 → true`;
- `test_supportsInterface_IReceiver`: assert `supportsInterface(0x805f2132)` **and** `supportsInterface(0x01ffc9a7)`, and add a case that the old `0x21a4cdb3` is no longer required.

**Validated against official sources (2026-06-01) — four independent ways:**
- **Official Chainlink CRE docs** ("Building Consumer Contracts"): *"The `KeystoneForwarder` uses this to check if your contract supports the `IReceiver` interface before sending a report,"* with the documented `ReceiverTemplate.supportsInterface` returning `type(IReceiver).interfaceId || type(IERC165).interfaceId`.
- **Exact upstream source the repo vendors** — `smartcontractkit/ccip@eb419a097bd11846ff2d82d25c447eee1f911b38` (the `lib/ccip` submodule under `chainlink-local`): `IReceiver` is `onReport`-only; `KeystoneForwarder.sol:157-159` gates and `:163` calls `onReport` only on pass; correct pattern in `KeystoneFeedsConsumer.sol:102-103`.
- **OpenZeppelin `ERC165Checker` v4.8.3**: `supportsInterface(acct,id)` requires `supportsERC165(acct)` first, which probes `type(IERC165).interfaceId` (`0x01ffc9a7`).
- **`cast sig`** selector arithmetic (Appendix A): `0x805f2132 ^ 0xa0042526 ^ 0x01ffc9a7 = 0x21a4cdb3`.

**Only remaining residual:** confirm each L2's **production-deployed** forwarder (Arbitrum/Base/Linea/Optimism) is this same `KeystoneForwarder` with the ERC-165 gate — addresses are in Chainlink's [Forwarder Directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-ts). The gate is the documented norm, so this is confirmation, not doubt.

---

### F-2 — `onReport` allow-list checks only `(target, selector)`; call arguments are fully report-author-controlled

> ✅ **Fixed in the working tree (2026-06-01, uncommitted).** `onReport` now enforces `data.length == 4` (new error `NonNullaryCall`) immediately after the allow-list check, so only **argument-less** calls dispatch — the report author controls nothing beyond *which* allow-listed selector fires. The sole production entry, `SyncTrigger.triggerSync()`, is nullary. The contract NatSpec now frames layer 3 as "(target, selector) + nullary". Unit tests reworked to a nullary mock call (`MockTarget.ping()`) plus a new `test_onReport_revertsOnNonNullaryCall`; **35/35** `CREReceiverTest` pass, `forge build` clean. The fork integration tests already drive the nullary `triggerSync()`, so they are unaffected. Analysis retained below.

- **Confidence:** 75 (description only — below threshold) · **Convergence:** access-control + economic-security + execution-trace agents
- **Location:** `src/cre/CREReceiver.sol:78-86`

**Description.** `onReport` decodes `(address target, bytes data)` from the DON-supplied report, checks only `_allowedCalls[target][bytes4(data)]`, then executes `target.call(data)` with the **remaining calldata unconstrained**. The contract is documented as a generic CRE→on-chain dispatcher whose owner can `setAllowedCall(target, selector, true)`. The single seeded entry — `(SyncTrigger, triggerSync())` — is argument-less and therefore inert, so this is **not exploitable today**; but the moment any *parameterized* selector is ever allow-listed (a token transfer, a config setter, an amount/recipient-bearing call), the off-chain report author gains full control of those arguments through this contract.

**Recommendation.** If the dispatcher only ever needs `triggerSync`, narrow it (hard-code the target/selector, or validate `data.length == 4` for nullary calls). If it must stay generic, document that every allow-list entry must be a nullary or argument-validated function, and consider an argument-shape allow-list rather than just `(target, selector)`.

---

### F-3 — `onReport` pins the author to an owner *key*, not a specific *workflow*

> ✅ **Resolved as documented — deliberate won't-bind (2026-06-01, uncommitted).** The recommended `workflowName`/`workflowId` bind was evaluated and intentionally **not** implemented. Rationale: (1) `workflowName` is an owner-chosen, owner-scoped label — not globally unique, and an attacker who controls the pinned owner key can simply register a workflow under the expected name, so a name-bind gives **no protection against the principal threat** (owner-key compromise); (2) `workflowId` is a content hash that only exists *after* the workflow is registered (post receiver-deploy), so it cannot be pinned at construction anyway; (3) with **F-2** locking execution to the single argument-less `triggerSync()`, a stray workflow signed by the same owner could at most trigger the intended, rate-limited sync — the blast radius is already contained by `(forwarder, owner)` + nullary + the single allow-list entry. Binding the name would add operational rigidity (a workflow rename ⇒ `CREReceiver` redeploy) for negligible gain. The trust boundary — and *why* name/id are not enforced — is now documented in the `CREReceiver` contract NatSpec and inline at the author check. Analysis retained below.

- **Confidence:** 75 (description only) · **Convergence:** economic-security + periphery + first-principles agents
- **Location:** `src/cre/CREReceiver.sol:73-76`, `_extractWorkflowOwner` at `:136`

**Description.** `onReport` authenticates only `workflowOwner == _expectedAuthor` and ignores the `workflowId`/`workflowName` also present in the metadata. The canonical `KeystoneFeedsConsumer` gates on **both** owner and workflow name. As written, *any* CRE workflow owned by the pinned deployer key — present, future, or rogue, under any name — produces reports that pass the author check; only the `(target, selector)` allow-list then constrains execution. The trust boundary is "any workflow signed by `_expectedAuthor`" rather than "the one Lido sync workflow," which widens unexpectedly the moment another workflow is created under that key or the key is reused/compromised.

**Recommendation.** Additionally bind to the expected `workflowName` (bytes10 at `metadata[32:42]`) and/or `workflowId`, mirroring `KeystoneFeedsConsumer`. Interacts with F-2: tighter author binding limits the blast radius if a parameterized selector is ever allow-listed.

---

### F-4 — L2 migration grants `DEFAULT_ADMIN_ROLE` + proxy/SyncTrigger ownership to an unvalidated env-supplied `L2_GOVERNANCE_EXECUTOR`

> ✅ **Fixed in the working tree (2026-06-01, uncommitted).** `L2UpgradeScriptBase` now reads `L2_GOVERNANCE_EXECUTOR` exclusively through a new `_envGovernanceExecutor()` helper, which reverts (`L2UpgradeWrongGovernanceExecutor(actual, expected)`) unless the env value equals the per-network `_expectedGovernanceExecutor()`. That hook is overridden in the **Optimism/Arbitrum/Base/Linea** scripts to return their `LIDO_L2_GOVERNANCE_EXECUTOR` constant (previously referenced only by tests). Both stages route through this single choke point — Stage 1 (`runDeploy`, which transfers SyncTrigger ownership to the executor) and Stage 2 (`runMigrate`/`run` admin + ProxyAdmin handover) — so a wrong-but-nonzero executor is rejected *before* any irreversible write. **Sepolia** deliberately opts out (inherits the base `address(0)`), since its executor is operator-supplied with no canonical value. `forge build` clean. Analysis retained below.

- **Confidence:** 75 (description only) · **Convergence:** vector-scan + access-control agents
- **Location:** `script/shared/L2UpgradeScriptBase.s.sol` (env read), `script/shared/L2UpgradeActions.s.sol` `executeMigrationSteps` / `_assertMigrationSteps`

**Description.** The future super-admin is read from the `L2_GOVERNANCE_EXECUTOR` env var and fed into `migrateSenderAdmin` (grant `DEFAULT_ADMIN_ROLE`), `transferProxyAdminOwnership`, and `transferSyncTriggerOwnership`. It is **never cross-checked** against the known-correct per-chain `LIDO_L2_GOVERNANCE_EXECUTOR` constant (which exists in each `*MigrationConstants.sol` but is used only by tests). `_assertMigrationSteps` only confirms the role/ownership landed on *whatever* address was passed — it cannot detect a wrong-but-nonzero executor. Because the Initial Owner's admin is revoked in the **same** transaction, a wrong value hands full, irreversible control of the L2 lane (admin role + `upgradeAndCall` authority via ProxyAdmin) to an unintended contract with no on-chain guardrail.

> This is not hypothetical: the Base/Linea governance-executor address was previously wrong in this repo (it had been set to the Initial Liquidity Owner). A consistency check would have caught it.

**Fix.** Assert the env value against the per-chain constant inside the migration, e.g.:

```solidity
require(cfg.governanceExecutor == LIDO_L2_GOVERNANCE_EXECUTOR, "wrong gov executor");
```

(or at minimum log a diff and require explicit confirmation). See also leads L-1/L-2/L-3 on the surrounding migration ordering.

---

## Leads

High-signal trails with concrete code smells where the full exploit path was not completed in one pass. Not scored — manual review recommended.

### CREReceiver / SyncTrigger (deployed contracts)

- **L-1 · `type(uint48).max` "deactivated" delay reverts instead of returning false** — `SyncTrigger._getAmountToSync` *(2 agents)*. `_lastExecution + _delay` overflows `uint48` when `_delay == type(uint48).max`, so `shouldSync()`/`getAmountToSync()`/`triggerSync()` panic-revert in the deactivated state; the off-chain CRE `eth_call` probe sees a revert rather than a clean "no sync". Inherited verbatim from audited upstream `SyncAutomation`; masked once a real delay is configured. Relevant if max-delay is ever used as a "pause".
- **L-2 · Two decoders disagree on `feeOtoD` length domain** — `SyncTrigger.setFeeOtoD` / `triggerSync`. `FeeCodec.decodeFeeMemory` accepts any buffer ≥17 bytes (and computes `msg.value`), but `CustomSender._ccipBuildAndSend` re-decodes the same bytes with `decodeCCIP`, which reverts unless length == 21. A 17–20-byte (or >21) owner-set config passes `SyncTrigger` then self-DoSes inside `sync`. Owner-misconfiguration only.
- **L-3 · `onReport` correctness coupled to one unpinned forwarder version** — `CREReceiver.onReport` / `_extractWorkflowOwner`. The `metadata[42:62]` slice and `onReport(bytes,bytes)` ABI are correct only for the newer CRE/Keystone v1.0.0 forwarder; the repo also vendors an older brownie `KeystoneForwarder` with a different `onReport(bytes32,address,bytes)` ABI. The forwarder is set from `L2_CRE_FORWARDER` env with no on-chain version assertion.
- **L-4 · No explicit `metadata.length` guard before slicing** — `CREReceiver._extractWorkflowOwner` *(2 agents)*. Relies on Solidity's implicit calldata-slice bounds-revert before `metadata[42:62]`. Safe today given the fixed 64-byte Keystone layout + trusted forwarder + nonzero `_expectedAuthor`, but brittle if the metadata format changes. Consider `require(metadata.length >= 62)`.
- **L-5 · `triggerSync` funds the CCIP fee from SyncTrigger's own balance with no refill path** — `SyncTrigger.triggerSync`. `CREReceiver` calls `target.call(data)` with zero value; once SyncTrigger's pre-funded native balance drops below `nativeAmount` (~0.125 ETH/sync), every sync reverts until an operator manually tops up SyncTrigger (not the ETH-holding CREReceiver). Liveness dependency — plausibly intended, but unenforced and undocumented in the traced code.

### L2 migration / orchestration (Foundry scripts, trusted-operator)

- **L-6 · Stage-2 grants `SYNC_ROLE` without re-asserting the trigger's wiring** — `L2UpgradeActions.executeMigrationSteps` / `_assertMigrationSteps`. Post-conditions check the role grant + ownership but never `ISyncTrigger(newSyncTrigger).getForwarder()` / `SENDER()`. An env `L2_SYNC_TRIGGER` typo or a mis-wired (wrong-forwarder) trigger gets `SYNC_ROLE` and bricks sync with no recovery short of governance. Add `SENDER()`/`getForwarder()` assertions before granting.
- **L-7 · `SYNC_ROLE` "sole holder" invariant is unverifiable on-chain** — `L2UpgradeActions.executeMigrationSteps`. Revokes only ≤2 hardcoded automation addresses; `CustomSender` inherits non-enumerable `AccessControlUpgradeable`, so the documented `getRoleMemberCount(SYNC_ROLE)==1` cannot be checked. Any pre-existing extra `SYNC_ROLE` holder retains `CustomSender.sync()` (pulls WETH and bridges) after migration. Enumerate/verify off-chain before migrating.
- **L-8 · No on-chain Stage-1-completeness precondition before irreversible handover** — `L2UpgradeScriptBase.runMigrate`. `runVerifyStage1` is a separate, optional, anyone-callable view; `runMigrate` performs the admin revoke + proxy-ownership transfer without requiring it, so a half-configured Stage 1 gets locked in with admin already moved to slow governance.
- **L-9 · Cross-chain mirror invariant `expectedAuthor (L2) == WorkflowRegistry.owner (L1)` is never reconciled** — `CREReceiver.expectedAuthor` / `verifyStage1`. The L2 and L1 checks each read the *same* operator env independently (tautological), and `setExpectedAuthor` (LOL multisig) can later drift one side. A wrong env value passes both checks; a later edit silently bricks that lane's sync. Verify the actual on-chain L1 registry owner against each L2 pin.
- **L-10 · `setOraclePool` repoints `CustomSender` to a freshly-deployed, unfunded pool** — `L2UpgradeActions.executeMigrationSteps`. Mainnet lanes have no liquidity-migration step (only Sepolia sweeps), and `verifyStage1` asserts the new empty pool is `!paused`, so user `fastStake` reverts with `OraclePoolInsufficientTokenOut` until an out-of-band LOL funding tx lands. Confirm funding is sequenced before users hit the new pool.

### Sepolia / testnet scripts

- **L-11 · Sepolia L1 admin-migration omits the chain-id guard present on every other script** — `SepoliaL1Upgrade.run`. Broadcasts the receiver admin handover + ProxyAdmin transfer with no `assertL1ChainId`, unlike mainnet `L1UpgradeScript.run`. A misconfigured `$RPC_URL` could fire irreversible handover on the wrong network.
- **L-12 · Sepolia migration body calls owner-only fns on bootstrap contracts owned by a different key** — `SepoliaL2Upgrade._runMigrateBody`. Broadcast by `INITIAL_OWNER_PRIVATE_KEY`, but the bootstrap `SyncAutomation`/pool are owned by `deployer`; correct only because `.env.sepolia.example` instructs operators to reuse the same key. Fragile actor assumption.

---

## What was verified clean (notable negatives)

- **CCIP fee / native / LINK accounting** in `SyncTrigger.triggerSync` → `CustomSender.sync` → `_ccipBuildAndSend` is byte-for-byte the audited upstream `SyncAutomation`; over-funded native is refunded via `TokenHelper.refundExcessNative(msg.sender)`. No over/under-send, no stranded value, no native/LINK confusion. *(math-precision, economic-security, execution-trace)*
- **`_extractWorkflowOwner` offset `metadata[42:62]`** is **correct** for the CRE/Keystone v1.0.0 layout (`workflowId(32) | workflowName(10) | workflowOwner(20)`); confirmed against the vendored `KeystoneForwarder` 64-byte metadata slice and `KeystoneFeedsConsumer`. (See L-3/L-4 for the version-coupling caveat.)
- **Reentrancy** from `onReport`'s `target.call` and from `triggerSync`'s `sync → refundExcessNative → SyncTrigger.receive()` is blocked by `onlyForwarder` and the empty `receive()`. *(execution-trace; matches `test_onReport_reentrancyBlocked`)*
- **Storage-writer authorization:** every external writer in `SyncTrigger`/`CREReceiver` is gated by `onlyOwner` or `onlyForwarder`; no inconsistent-guard gap; OZ v5 `Ownable` rejects zero-address transfers. *(access-control)*
- **Donation/inflation** against the OraclePool balance is self-harm and protocol-positive (donated WETH → protocol-owned wstETH), rate-limited by `_delay`. *(economic-security — rejected as a finding)*

---

## Appendix A — F-1 verification trace

Computed selectors / interface ids (via `cast sig`):

| Function | Selector |
| --- | --- |
| `onReport(bytes,bytes)` | `0x805f2132` |
| `getForwarder()` | `0xa0042526` |
| `supportsInterface(bytes4)` (ERC-165 base) | `0x01ffc9a7` |

- **Lido's local 3-function `IReceiver`** (`src/cre/interfaces/IReceiver.sol`): `type(IReceiver).interfaceId = 0x805f2132 ^ 0xa0042526 ^ 0x01ffc9a7 = 0x21a4cdb3`.
- **Keystone's 1-function `IReceiver`** (`lib/chainlink-local/lib/ccip/contracts/src/v0.8/keystone/interfaces/IReceiver.sol`, `onReport` only): `type(IReceiver).interfaceId = 0x805f2132`.

Forwarder gate (`lib/chainlink-local/lib/ccip/contracts/src/v0.8/keystone/KeystoneForwarder.sol`):

```solidity
// :157  — `type(IReceiver).interfaceId` here == 0x805f2132 (its own 1-fn interface)
if (!ERC165Checker.supportsInterface(receiver, type(IReceiver).interfaceId)) {
    s_transmissions[transmissionId].invalidReceiver = true;   // :158
    // ... returns; onReport NOT called
}
// :163  — only reached if the gate above passes
bytes memory payload = abi.encodeCall(IReceiver.onReport, (metadata, validatedReport));
```

OZ `ERC165Checker` (v4.8.3, `lib/.../utils/introspection/ERC165Checker.sol`): `supportsInterface(account, id)` first calls `supportsERC165(account)` (`:22`), which requires `account.supportsInterface(0x01ffc9a7) == true` (`:26`).

**Conclusion.** `CREReceiver.supportsInterface` returns `true` only for `0x21a4cdb3`, so:
1. `supportsInterface(0x01ffc9a7)` → `false` ⇒ `supportsERC165(CREReceiver)` → `false` ⇒ the whole check returns `false` regardless of the queried id; **and**
2. even without (1), the queried id `0x805f2132` ≠ `0x21a4cdb3`.

Either way `route()` sets `invalidReceiver = true` and never calls `onReport`. ∎

**Official cross-checks (2026-06-01).** Provenance pinned: the vendored forwarder is `smartcontractkit/ccip@eb419a097bd11846ff2d82d25c447eee1f911b38`. In that same tree the canonical receiver `KeystoneFeedsConsumer.sol:102-103` returns `type(IReceiver).interfaceId || type(IERC165).interfaceId` (the correct pattern), and Chainlink's CRE "Building Consumer Contracts" docs state the forwarder performs this ERC-165 check before delivery and ship an identical `ReceiverTemplate.supportsInterface`. By contrast the repo's own state-mate oracle pins the buggy `0x21a4cdb3` (`script/*/state-mate/*.yaml:189-191`) and the `supportsInterface` unit test asserts the same wrong id — so every in-repo check is self-consistently validating the defect rather than the forwarder's actual requirement.

---

## Methodology & reproduction

Generated by the Pashov Audit Group `solidity-auditor` skill (installed at `~/.claude/skills/`). Eight specialized agents analyzed the same source bundle in parallel; results were deduplicated by `Contract | function | bug-class` and run through four sequential gates (Refutation → Reachability → Trigger → Impact). Findings F-2…F-4 were promoted on multi-agent convergence (confidence 75, below the fix threshold). Because the gate methodology is tuned for attacker value-extraction, operator-misconfiguration issues in the trusted Foundry migration scripts correctly demote to leads — but that is where the bulk of the migration-safety risk lives, so L-6…L-10 warrant a manual pass.

Re-run: `run the solidity auditor with all the different agents possible on <files>`.

---

# 🩻 Pre-Audit X-Ray (Audit Readiness)

Generated by the Pashov `x-ray` skill (installed at `~/.claude/skills/`). Full briefing in **[`x-ray/`](x-ray/)**: [`x-ray.md`](x-ray/x-ray.md) (overview · threat model · verdict), [`entry-points.md`](x-ray/entry-points.md), [`invariants.md`](x-ray/invariants.md), [`architecture.svg`](x-ray/architecture.svg).

**Scope note.** Unlike the solidity-auditor above (which covered `src/` + the 18 `script/` migration files), the x-ray analyzes only the `foundry.toml` `src` dir — `SyncTrigger.sol` + `CREReceiver.sol` (**226 nSLOC**), the two deployed contracts. It is a readiness briefing, not a vulnerability scan.

## Readiness Verdict: 🟠 FRAGILE

Minimal, well-documented, cleanly access-controlled contracts (**0 permissionless entry points** — everything is `onlyOwner`/`onlyForwarder`), but the test suite — though substantial (**91 functions** across 15 files, incl. fork + integration) — has **no stateful fuzzing, no invariant tests, and no formal verification** for the cross-chain fee math or the 3-layer report authentication. Tier = lowest of {Tests=FRAGILE, Docs=HARDENED, Access-Control=ADEQUATE}.

Structural facts: 226 nSLOC / 2 non-upgradeable `Ownable` contracts · 0 permissionless entry points · 91 test fns / 0 fuzz / 0 invariant / 0 formal · single developer (100% of source, +482/-69) · 0 merge commits of 15.

## Invariant gaps (On-chain = No)

Each is simultaneously an invariant and a potential bug. Full derivations in [`x-ray/invariants.md`](x-ray/invariants.md).

| Inv | Property NOT enforced on-chain | Maps to |
|-----|--------------------------------|---------|
| **I-2** | Deactivated delay (`type(uint48).max`) should mean "no sync", but `_lastExecution + _delay` overflows `uint48` → revert | L-1 |
| **I-4** | `_forwarder != address(0)` — enforced in `CREReceiver`, **NOT** in `SyncTrigger` (`setForwarder` accepts zero) | **L-13** (new) |
| **X-1** | `SyncTrigger._forwarder == CREReceiver` **and** allow-list contains `triggerSync` — the wiring is owner-set and unchecked | L-6 |
| **E-1** | "≤ `maxAmount` synced per `delay` window" rate-limit — inherits I-2 + config dependence | L-1 |

## New lead from the x-ray

- **L-13 · `SyncTrigger.setForwarder` accepts `address(0)`** — `SyncTrigger.sol:148,186` — Code smells: unlike `CREReceiver.setForwarder` (guards `!= address(0)`), `_setForwarder` has no zero check; a single owner call to `setForwarder(0)` permanently bricks `triggerSync` (its `onlyForwarder` compares `msg.sender != address(0)`, always true). Owner-only self-brick, not externally exploitable — align with `CREReceiver` for safety.

## Test-methodology gaps

- **No stateful fuzz / invariant tests** for the `triggerSync` native/LINK fee split or the `onReport` 3-layer auth — exactly where fuzzing/invariants pay off.
- **No formal verification** configured.
- **`supportsInterface` is never exercised through a real forwarder** — tests `vm.prank` the forwarder and call `onReport` directly, bypassing the ERC165 delivery gate. Worse, the one `supportsInterface` unit test *and* the state-mate oracle for all six chains both assert the **buggy** id `0x21a4cdb3` (never `0x805f2132`/`0x01ffc9a7`), so the safety nets confirm **F-1** instead of catching it. This blind spot is what let F-1 pass CI.
- Coverage metrics unavailable (fork suite needs per-chain RPC); test *existence* confirmed by file scan.

## Process / git observations

- **Single-developer source** (100%, +482/-69) and **0 merge commits of 15** — no in-repo peer-review signal; bus-factor risk.
- **`CREReceiver` is #1 in both churn and attack-surface priority** — concentrate review on `onReport`, `_extractWorkflowOwner`, `supportsInterface`.
- **Prior assembly out-of-bounds fix** (`db70f15`) sits exactly on the `metadata[42:62]` extraction path — re-confirm the offset against the deployed forwarder (ties to L-3).
- **Hardening commit `41434b5`** (fix-score 21) tightened access control + accounting with net code removal in `CREReceiver` — highest-scored security-relevant commit.
- Forked deps (`chainlink-csr`, `chainlink-local`, OpenZeppelin) are clean git submodules — upstream fixes propagate via bump, not manual merge.

Re-run: `run an x-ray on the codebase`.
