# RUNBOOK — L2 Direct Staking Migration

Operator checklist for migrating Direct Staking (ownership, admin roles, sync infra) to Lido
governance across **Optimism, Arbitrum, Base, Linea** + a shared **Ethereum L1** receiver.
Rationale, fee math, full monitoring, and architecture live in [`README.md`](README.md) and [`DOC.md`](DOC.md).

> **Recipe ≠ run ≠ state.** This file is the **recipe** (a method description). Broadcasting a step
> is the **run** (the on-chain transactions). The owner/role layout in [`DOC.md` §3](DOC.md) is the
> **resulting state**. A green check is the **evidence** that a run matched the recipe — **documented ≠ done.**
> Each step names the **system that signs it**; the recipe does not act, the keyholder does.

**How to read each step.** Load-bearing lines are tagged:

- **Def** — a definition/invariant (decided by reading, not running).
- **Gate `Gn`** — an *admissibility predicate*: proceed past it **only when its Evidence holds**. Steps cite gates by ID.
- **Duty** — an obligation on a **named role** (who *SHALL* act). Never "the system/script" — a keyholder.
- **Evidence** — the **carrier + observation** that decides a gate (an exit code, a printed count, a revert, an on-chain read-back). A claim with no carrier is an opinion.

**Def — verify vs validate** (two different evidence kinds, do not conflate):
*verify* = read back values just written / immutables, decided **in-description** (`verify-stage1` → 18 reads; the in-tx read-backs → 7). *validate* = observe the deployed contracts **live over RPC** from outside (`state-mate` → ≥45 checks; fork tests). Both are required; they fail differently.

---

## Setup (once)

- **Toolchain:** `forge`/`cast`/`anvil` (Foundry), `node`+`corepack`(yarn), `bun`, `jq`, **`yq`**.
  > ⚠️ `yq` is required by `verify-constants-sync` and `balances-*` — install it (`brew install yq`) or those recipes fail.
- **Deps:** `(cd lib/state-mate && corepack yarn install --immutable)` (state-mate) · `just setup-cre` (CRE bun deps). `forge build` pulls Solidity submodules.
- **Per-network env** — one `.env.<network>` per L2 (`L2_NETWORK` is the discriminator):

  ```env
  L1_RPC_URL=https://...                 # Ethereum mainnet (same in all 4 files)
  L2_RPC_URL=https://...                 # this L2's RPC
  L2_NETWORK=linea                       # optimism|arbitrum|base|linea
  L2_LIDO_DEPLOYER_PRIVATE_KEY=0x...     # Stage 1 signer
  INITIAL_OWNER_PRIVATE_KEY=0x...        # Stage 2 signer (cold key)
  L2_GOVERNANCE_EXECUTOR=0x...           # per network (table below)
  L2_CRE_FORWARDER=0x...                 # per network, Chainlink-published
  LIDO_DAO_AGENT=0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c
  # appended after deploy-stage1:  L2_ORACLE_POOL / L2_SYNC_TRIGGER / L2_CRE_RECEIVER
  # appended after deploy-cre-workflow:  CRE_WORKFLOW_ID
  ```

| Network  | L2 Governance Executor | LOL multisig (pool/CREReceiver owner) |
|----------|------------------------|----------------------------------------|
| Optimism | `0xEfa0dB536d2c8089685630fafe88CF7805966FC3` | `0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61` |
| Arbitrum | `0x1dcA41859Cd23b526CBe74dA8F48aC96e14B1A29` | `0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61` |
| Base     | `0x0E37599436974a25dDeEdF795C848d30Af46eaCF` | `0x5A9d695c518e95CD6Ea101f2f25fC2AE18486A61` |
| Linea    | `0x74Be82F00CC867614803ffd7f36A2a4aF0405670` | `0xA8EF4Db842d95DE72433a8B5b8fF40cB9C74c1B6` |

Shared L1: Receiver `0x6F357d53d6bE3238180316BA5F8f11467e164588` · ProxyAdmin
`0x88a45d2760b63c1500E3D2E3552b28e5Cdaa37BD` · DAO Agent `0x3e40D7…9C8c` · Initial Owner `0xb5c336…91a8`.

---

## Gates (proceed past `Gn` only when its Evidence holds)

| ID | Admissibility predicate | Evidence that decides it (carrier + observation) | Blocks until it holds |
|----|-------------------------|--------------------------------------------------|------------------------|
| **G1** | Pre-live checks pass for this lane | `test-acceptance` / `forge test` exit 0 · `verify-constants-sync` prints `OK` · `preflight-check{,-l1}` print `OK` | any production tx (Stage 1) |
| **G2** | Stage 1 *verified* on this network + CRE workflow live | `verify-stage1` → `Script ran successfully` (18 reads) · `verify-cre-workflow` → status `ACTIVE`, owner = Lido Deployer | `migrate-stage2` on this network |
| **G3** | **All 4** L2s migrated *and* validated | 4× `migrate-stage2` broadcast with no revert · 4× state-mate exit 0 | `migrate-l1` (the L1 seal) |
| **G4** | This network *validated* (this is the **Def of "done/green"**) | `test-<net>-upgrade-state-verify` exit 0, tail `✔ Total: ≥45 checks passed` | LOL liquidity seed **and** legacy-upkeep cancel for this network |

---

## 1 · Pre-live checks (off production) → clears **G1**

Run top-to-bottom; **Evidence** of each is its exit/print. Operator (any) SHALL re-run for the lane being migrated.

```sh
# a. Build + tests   (Evidence: each exits 0)
forge build
forge test --match-contract 'CREReceiverTest|SyncTriggerTest'   # contract unit tests (verify; no RPC)
just test-cre-workflow          # CRE TypeScript workflow (bun)
just test-acceptance            # FORKS REHEARSAL (validate): deploy+migrate ×4 + L1 + state-mate + forge tests

# b. Constants drift — Solidity is the single source of truth   (Evidence: prints "OK", exit 0)
just verify-constants-sync      # needs yq

# c. Preflight against the PRODUCTION RPCs (read-only, per network)   (Evidence: prints "OK")
just -E .env.<network> preflight-check       # chain-id, sender bytecode, legacy-sync age, old-pool balances, Sync events (~12h)
just -E .env.<network> preflight-check-l1     # L1 mainnet + receiver adapter/sender wiring for this lane
```

**d. Dress rehearsal** — the *actual* operator recipes on an anvil fork of one L2 + L1 (validates recipe wiring end-to-end; Linea shown, substitute per net):

```sh
anvil --silent --auto-impersonate -p 8650 -f "$L1_RPC_URL"       >/tmp/dr-l1.log 2>&1 &
anvil --silent --auto-impersonate -p 8651 -f "$L2_LINEA_RPC_URL" >/tmp/dr-l2.log 2>&1 &
until cast chain-id --rpc-url http://127.0.0.1:8650 >/dev/null 2>&1 && cast chain-id --rpc-url http://127.0.0.1:8651 >/dev/null 2>&1; do sleep 1; done
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; IO=0xb5c336a5c60D3482b29d83C742C65AE8351b91a8; DAO=0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c
for u in http://127.0.0.1:8650 http://127.0.0.1:8651; do for a in $DEPLOYER $IO $DAO; do cast rpc --rpc-url $u anvil_setBalance $a 0x3635C9ADC5DEA00000 >/dev/null; done; done

export L2_NETWORK=linea L2_GOVERNANCE_EXECUTOR=0x74Be82F00CC867614803ffd7f36A2a4aF0405670 L2_CRE_FORWARDER=0x000000000000000000000000000000000000dEaD
L2_RPC_URL=http://127.0.0.1:8651 just deploy-stage1            # → paste the 3 printed exports into the shell
L2_RPC_URL=http://127.0.0.1:8651 just verify-stage1           # Evidence: "Script ran successfully" = 18 reads pass
ALLOW_UNSAFE_COMBINED_RUN=1 forge script script/linea/LineaL2Upgrade.s.sol:LineaL2UpgradeScript \
  --sig 'runMigrateUnlocked()' --rpc-url http://127.0.0.1:8651 --broadcast --non-interactive --unlocked --sender $IO
# validate: render template into /tmp with the deployed addresses, run state-mate --only l2 (see README §dress rehearsal)
pkill -f 'anvil .*-p 865[01]'                                  # cleanup
```

> Does **not** cover: real CRE workflow deploy/DON, real CCIP send→L1 (covered by `test-acceptance` fork tests), LOL seed, Aragon vote.

---

## 2 · Live migration run

**Def — network order.** Migrate by ascending capital in the old pool (the comparator is **ETH-equivalent of old-pool WETH+wstETH**): **Linea → Arbitrum → Base → Optimism.** The middle three are within ~0.1 ETH (**incomparable** for risk purposes — any order among them is admissible). Re-read the comparator right before each:
`cast call <oldPool> "balanceOf(address)(uint256)" <weth|wsteth> --rpc-url $L2_RPC_URL`.

**Def — in-flight cutover (replaces "safe"/"correct-by-design").** `sync()` encodes the **recipient pool address into the CCIP message at call time**, immutable for the rest of the round-trip. ⇒ a round-trip started *before* Stage 2 that lands *after* it delivers wstETH to the **old** pool. **Recovery duty:** the **Initial Liquidity Owner** (old-pool owner) `sweep()`s it. The **new** pool is unaffected (seeded separately, §3). So no new-pool value is at risk and no message strands — that is the full content of "safe here."

### Stage 1 — Duty: **Lido Deployer** SHALL, per network

```sh
just -E .env.<network> deploy-stage1        # deploys pool+trigger+receiver; PRINTS export L2_ORACLE_POOL/SYNC_TRIGGER/CRE_RECEIVER
#   → Duty: append those 3 lines to .env.<network>
just -E .env.<network> verify-stage1        # verify (in-description): 18 read-backs incl. guardrails that Stage 2 has NOT run
just -E .env.<network> update-cre-config    # writes deployed addrs into cre config json
just -E .env.<network> deploy-cre-workflow  # cre workflow deploy; Duty: append printed CRE_WORKFLOW_ID= to .env
just -E .env.<network> verify-cre-workflow  # WorkflowRegistry: owner = Lido Deployer, status ACTIVE
```
**Evidence for G2:** `verify-stage1` → `Script ran successfully`; `verify-cre-workflow` → `ACTIVE`. CRE workflow is deployed **before** Stage 2 so the new sync path is live the moment legacy `SYNC_ROLE` is revoked (minimises the no-sync window).

### Stage 2 — Duty: **Initial Owner** SHALL, per network (then L1 once)

```sh
just -E .env.<network> migrate-stage2       # setOraclePool(new); SYNC_ROLE→new trigger (revoke legacy); DEFAULT_ADMIN→GovExec; L2 ProxyAdmin→GovExec
```
Requires **G2** for this network. **Evidence (in-tx, verify):** the script reads back **7** values after writing them; on any mismatch the broadcast **reverts** — there is no partial migration. A clean broadcast *is* the evidence the 7 post-conditions hold.

```sh
just -E .env.<any-network> migrate-l1       # ONCE: L1 Receiver admin + L1 ProxyAdmin → Lido DAO Agent
```
Requires **G3**. ⚠️ **The L1 seal is the action that ends external control of the shared receiver — run it LAST and keep the "all L2s migrated → L1 sealed" window short.** Until it lands, the external Initial Owner retains upgrade power over the receiver that serves every chain (see `DOC.md` §6.4).

**Def — transaction count:** 10 deploy + 6 migrate per L2 (7 for Linea) + 3 on L1 = **68 total**.

---

## 3 · Post-migration checks

### Validate (any operator) → clears **G4** per network

`validate` = observe the live contracts over RPC. **Evidence:** each exits 0; state-mate tails `✔ Total: ≥45 checks passed`.

```sh
just -E .env.optimism test-optimism-upgrade-state-verify
just -E .env.arbitrum test-arbitrum-upgrade-state-verify
just -E .env.base     test-base-upgrade-state-verify
just -E .env.linea    test-linea-upgrade-state-verify
just -E .env.<any>    verify-l1-state-mate                 # shared L1 (once)
just -E .env.<network> verify-cre-workflow                 # per network: ACTIVE + owner
```

End-state invariants state-mate asserts (the **Def of "validated/green"** for a network). state-mate checks the **complete** role-member set, not mere presence:

| Contract (×4 = per network) | Getter | Expected |
|---|---|---|
| L1 Receiver | `hasRole(DEFAULT_ADMIN_ROLE, daoAgent)` / count | `true` / `1` |
| L1 ProxyAdmin | `owner()` | Lido DAO Agent |
| L2 CustomSender ×4 | `hasRole(DEFAULT_ADMIN_ROLE, govExec)` / count | `true` / `1` |
| L2 CustomSender ×4 | `hasRole(SYNC_ROLE, newSyncTrigger)` / count | `true` / `1` |
| L2 CustomSender ×4 | `getOraclePool()` | new OraclePool |
| L2 ProxyAdmin ×4 / SyncTrigger ×4 | `owner()` | L2 Gov Executor |
| SyncTrigger ×4 | `getForwarder()` | CREReceiver |
| CREReceiver ×4 | `owner()` / `getForwarder()` / `getExpectedAuthor()` | LOL / CRE Forwarder / Lido Deployer |
| CREReceiver ×4 | `isCallAllowed(SyncTrigger, 0x340b2b0b)` | `true` |
| OraclePool (new) ×4 | `owner()` | LOL multisig |

### Finalize (each requires **G4** for that network)

- **Duty — LOL multisig** SHALL transfer initial wstETH to each **new** pool (1 ERC-20 transfer/net). Until seeded, `fastStake` reverts for lack of output liquidity. **Do not seed a network before its G4.**
- **Duty — Lido Deployer / ops** SHALL cancel the old Chainlink Automation upkeeps (and Linea's Gelato bot) **only after G4** confirms the new SyncTrigger is the sole `SYNC_ROLE` holder.

### Watch (first weeks) — full table in [`README.md` §Monitoring](README.md)

- **CRITICAL:** the G4 invariant table above (any drift = key compromise / unintended governance); L1 Receiver balance ~0 (`MessageFailed` → page); CCIP manual-exec queue empty; Arbitrum retryable auto-redeems (≤7-day window or funds lost).
- **HIGH:** `SyncTrigger.getLastExecution()` advancing < 24 h while pool WETH ≥ min; `Sync`(L2) ↔ `MessageSucceeded`(L1) 1:1; CRE workflow `ACTIVE` + funded.
- **MEDIUM:** actual CCIP fee / `maxFee` < 80%; `ccipReceive` gas / `gasLimit` < 80%.

---

## FPF conformance notes

Improved per the First Principles Framework — each statement routed to its kind, evidence referred not asserted:

- **A.6.B (Boundary Norm Square, L/A/D/E).** Gates = Admissibility predicates with stable IDs `G1–G4`, cited by ID not paraphrase (CC-A.6.B.4); duties name an accountable role (CC-A.6.B.3); every gate carries Evidence = carrier + observation (CC-A.6.B.5); gates are predicates, not laws (CC-A.6.B.6).
- **A.6.Q (quality-term precision).** "safe" / "correct-by-design" / "green" / "done" no longer carry boundary force as bare adjectives; each is a **Def** backed by mechanism + evidence (CC-A.6.Q-14/15), removing the "magic scalar" anti-pattern.
- **A.6.A (action-invitation precision).** "proceed" / "safe to proceed" were action-cues smuggling gates; they now route to explicit `Gn` predicates (CC-A.6.A-18, no invitation-as-obligation).
- **A.10 (evidence graph referring).** Every gate/claim names its carrier; **verify** (in-description read-backs) vs **validate** (live-RPC state-mate/fork) are the `verifiedBy` / `validatedBy` anchors — kept distinct.
- **A.7 (strict distinction).** "Recipe ≠ run ≠ state" banner (MethodDescription ≠ Work ≠ Object, CC-A7.4); each step names the **signing system** rather than letting the recipe "act" (CC-A7.1/A7.3); "documented ≠ done."
- **A.19 / G.5 (no hidden scalarization).** Network order states its comparator (ETH-equiv in old pool) and marks the middle three **incomparable**, instead of implying a strict total order.
