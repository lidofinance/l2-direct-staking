# RUNBOOK — Pool Switch (activate) + Live Canary Sync

> **Status (2026-07-24): §1 activate, §2 live sync, and `handoff` are DONE on all 4 lanes**
> (evidence + carriers: RUNBOOK.md §Evidence status). Current work is §3 (post-handoff checks,
> CRE workflow registration, float funding) — **blocked on Arbitrum + Base**: their handoff
> (2026-07-23) transferred pool/trigger/receiver + `expectedAuthor` to the superseded LOL Safe
> `0x5A9d…8A61`, not the required `0xFc83…66E6` (re-pinned 2026-07-24, commit `b6ec13d`); only
> the old Safe can transfer them onward. §4 `finalize` has not run on any lane.
>
> Scope: the next two production steps per network, given the Stage-1 canary contracts are
> already **deployed** and the trigger float **funded** (see [RUNBOOK.md §Canary validation](../RUNBOOK.md)).
> Two actors, one broadcast each — **do not co-locate the keys**:
>
> | Step | Actor | Key env var |
> |---|---|---|
> | 1. Pool switch | **Initial Owner** (CustomSender admin — *not* the Liquidity Owner) | `INITIAL_OWNER_PRIVATE_KEY` |
> | 2. Live sync test | **Lido Deployer** (`0xBeedf0c72D63eE8f8784eDB4A9326Fb43b69D50c`) | `L2_LIDO_DEPLOYER_PRIVATE_KEY` |
>
> Network order (ascending old-pool capital): **Linea → {Arbitrum, Base, Optimism}** — the last
> three are ~equal, any order; re-read the comparator before each lane (RUNBOOK.md §Def —
> network order, authoritative). Complete both steps (and the keep-or-`rollback` decision)
> on one lane before the next.

`L2_ORACLE_POOL`, `L2_SYNC_TRIGGER`, `L2_CRE_RECEIVER`, `L2_TEST_DEPLOYER` are expected in
`.env.<network>` (authoritative copies: `config/state/l2-<network>.deployed.yaml`).

Signing keys are exported in the shell only, never stored in `.env.<network>`, each on its
own actor's machine: `INITIAL_OWNER_PRIVATE_KEY` (`activate`, `rollback`) and
`L2_LIDO_DEPLOYER_PRIVATE_KEY` (`seed-test-weth`, `simulate-sync`). `preflight-check` and
`verify-test` need no keys (read-only).

Optional overrides (defaults are fine): `L2_TEST_WETH_SEED` for `seed-test-weth` (default
`1e17` = 0.1 WETH; must exceed the 0.0002 test minAmount); `L2_SYNC_MIN_AMOUNT_TEST` /
`L2_SYNC_DELAY_TEST` for `verify-test` (auto-read via `yq` from
`config/state/l2.inputs.test-stage.yaml` — set only if `yq` is not installed).

## 0. Preconditions (read-only, no keys)

**0.a Env/config validation.** `.env.<network>` carries `L2_NETWORK`, `L2_RPC_URL` and the
four canary addresses, matching the deployed.yaml (same three contract addresses on all
4 lanes — see the pinned table in RUNBOOK.md):

```sh
grep -E 'L2_(ORACLE_POOL|SYNC_TRIGGER|CRE_RECEIVER|TEST_DEPLOYER)=' .env.<network>
yq '.deployed.l2[] | select(anchor == "l2OraclePool" or anchor == "l2SyncTrigger" or anchor == "l2CreReceiver")' \
  config/state/l2-<network>.deployed.yaml
```

**0.b Legacy-lane health.**

```sh
just -E .env.<network> preflight-check   # chain-id, sender bytecode, legacy-sync age, old-pool balances
```

Evidence: final line `OK L2 preflight passed … — N PASS, M WARN` (hard failure exits early
with `PREFLIGHT FAIL`; WARNs still pass — review them). A very recent legacy sync means an
in-flight round-trip will land wstETH in the **old** pool — expected; the old-pool owner
`sweep()`s it (RUNBOOK.md §Def — in-flight cutover).

**0.c Deployed-canary state (pre-activate reads)** — `verify-test` asserts the *post*-activate
state, so read these directly (`source .env.<network>` first; `$CS` = the lane's
`CustomSender`, pinned in `script/<network>/<Net>MigrationConstants.sol`):

```sh
for c in $L2_ORACLE_POOL $L2_SYNC_TRIGGER $L2_CRE_RECEIVER; do
  cast call $c 'owner()(address)' --rpc-url $L2_RPC_URL; done      # all == $L2_TEST_DEPLOYER
cast call $L2_CRE_RECEIVER 'getForwarder()(address)' --rpc-url $L2_RPC_URL       # == $L2_TEST_DEPLOYER
cast call $L2_CRE_RECEIVER 'getExpectedAuthor()(address)' --rpc-url $L2_RPC_URL  # == $L2_TEST_DEPLOYER
cast call $L2_SYNC_TRIGGER 'getDelay()(uint48)' --rpc-url $L2_RPC_URL            # == 60 (test delay)
cast call $L2_SYNC_TRIGGER 'getAmounts()(uint128,uint128)' --rpc-url $L2_RPC_URL # min == 0.0002e18 (test)
cast call $L2_ORACLE_POOL 'paused()(bool)' --rpc-url $L2_RPC_URL                 # == false
cast balance $L2_SYNC_TRIGGER --rpc-url $L2_RPC_URL   # >= 0.5 ETH float; if short: just fund-trigger
                                                      # (Deployer key; re-sends the FULL float, not a
                                                      # top-up — excess is owner-sweep()-recoverable)
cast call $CS 'getOraclePool()(address)' --rpc-url $L2_RPC_URL   # still the OLD pool (pre-activate)
cast call $CS 'hasRole(bytes32,address)(bool)' \
  0xbb1ef2b79fa8154a13ffa50bd30e5f91ed93ff9b924bd04be671240cbc9d4b71 $L2_SYNC_TRIGGER \
  --rpc-url $L2_RPC_URL                                          # SYNC_ROLE not granted yet == false
cast call $CS 'hasRole(bytes32,address)(bool)' \
  0x0000000000000000000000000000000000000000000000000000000000000000 <INITIAL_OWNER_ADDR> \
  --rpc-url $L2_RPC_URL                                          # Initial Owner holds DEFAULT_ADMIN_ROLE == true
```

The §0.5 fork rehearsal hard-asserts all of 0.c in one shot (`_bindCanaryL2` +
`verifyCanaryStage1`); the manual reads are the no-`forge` fallback / itemized evidence trail.

## 0.5 Fork rehearsal of both steps (keyless, non-destructive, recommended per lane)

```sh
L1_RPC_URL=... just -E .env.<network> test-<network>-canary-acceptance
```

Runs `test_canarySyncOnDeployedAddresses` on an in-process fork, **bound to the real
on-chain canary addresses** from the deployed.yaml (bind-only — a missing address is a hard
failure, no fresh-deploy fallback). It: (1) asserts the deployer-owned canary shape;
(2) **pranks the Initial Owner's `activate`** (same `activateForTesting` body as
`runActivate()`) if still pre-activate, then hard-asserts `verifyCanaryStage1` — the same
checks as `verify-test`; (3) seeds WETH above the minAmount, warps past the delay, and drives
`CREReceiver.onReport` as the deployer with a **byte-identical report** to `simulate-sync`,
asserting the pool WETH is pulled.

Keyless (actor calls are pranks), no gas, no real-state mutation. Deltas vs the real
broadcasts: WETH seed / float via `deal` / `vm.deal`; the CCIP round-trip is not followed to
L1 (covered by `just test-acceptance`). Requires `L1_RPC_URL`; L2 RPC from `.env.<network>`
(or the positional arg). Siblings on the same binding: `test_canaryRollbackRestoresOldPool`
(§Rollback) and `test_canaryDeployerSimulatedSyncAndHandoff` (through handoff + finalize).

## 1. Pool switch — Initial Owner (Stage 0→1, reversible)

```sh
INITIAL_OWNER_PRIVATE_KEY=... just -E .env.<network> activate
```

One script run, two admin calls:
`CustomSender.setOraclePool(L2_ORACLE_POOL)` + `CustomSender.grantRole(SYNC_ROLE, L2_SYNC_TRIGGER)`.
Admin and the legacy automation's `SYNC_ROLE` are left intact, so `rollback` stays clean.

Verify (read-only, any machine):

```sh
just -E .env.<network> verify-test       # Evidence: "Script ran successfully"
```

Asserts: contracts deployer-owned, `CustomSender.getOraclePool()` == new pool, new trigger
holds `SYNC_ROLE`, governance executor not yet admin (seal not run), trigger float fully funded.

> From this moment L2 `fastStake` routes through the **new** pool, which has no wstETH seed
> yet — keep the window to the LOL seed short (docs/runbook-liquidity-provider.md);
> `sync`-accrual of WETH works regardless.

## 2. Live sync test with little liquidity — Deployer (Stage 1)

```sh
just -E .env.<network> seed-test-weth    # deposit ETH→WETH + transfer into the pool
                                         # default 0.0005 WETH (L2_TEST_WETH_SEED), test minAmount = 0.0002
# wait ≥ 60 s (L2_SYNC_DELAY_TEST — the canary delay since the last trigger execution)
just -E .env.<network> simulate-sync     # deployer = forwarder + author: onReport → triggerSync → sync
```

Evidence, immediate (tx receipt / explorer): `CREReceiver.CallExecuted` + `CustomSender.Sync`
events; pool WETH balance dropped to 0 (`cast call $WETH 'balanceOf(address)(uint256)'
$L2_ORACLE_POOL`); CCIP fee fronted from the trigger float (no value on the call).

Evidence, delayed (~the CCIP round-trip, track on https://ccip.chain.link by the tx hash):
L2→L1 message delivered, WETH staked on L1; wstETH lands back in the **new** pool
(`balanceOf` on the lane's wstETH token).

The deployer later `sweep()`s this test residue during `handoff` — no action now.

## 2.5 Pre-handoff state-mate validation (read-only, no keys)

The independent live-RPC oracle for the **pre-handoff** state — the §3.b sibling with the
shared test-stage overlay (`config/state/l2.inputs.test-stage.yaml`) describing the
deployer-owned canary shape (owner / forwarder / author = deployer, test min-amount 0.0002e18,
test delay 60 s). `verify-test` (§1) reads back the same state from the same repo's script —
state-mate re-derives it from an independently reviewed config (RUNBOOK.md §Def —
verify vs validate); record this run as part of the G2 evidence before `handoff`:

```sh
just -E .env.<network> test-<network>-upgrade-state-verify-canary
```

Evidence: `Total: 82 checks`. Run **after** `activate` (§1): the pre-activate group
(`getOraclePool` still old pool, new trigger's `SYNC_ROLE` false, `shouldSyncAmount` via the
old pool) has cleared, so the ONLY expected failures are the finalize-gated group —
`CustomSender` `DEFAULT_ADMIN_ROLE` still Initial Owner not governance executor (two checks +
the ACL mirror), legacy automation still holding `SYNC_ROLE`, `proxyAdmin.owner` still Initial
Owner. Anything else red is a real defect — stop before `handoff`. (Full expected-failure
annotations: RUNBOOK.md §Canary validation, step 1.) The committed overlay deployer anchors
are the real canary deployer (`L2_TEST_DEPLOYER`) — no local edit needed for mainnet lanes.

## Rollback (only from here, before handoff)

> **No longer available (2026-07-24):** `handoff` has run on all 4 lanes, so the 1→0 rollback
> window is closed everywhere — the contracts are no longer deployer-owned. Kept for the record.

If the test is unsatisfactory:

```sh
INITIAL_OWNER_PRIVATE_KEY=... just -E .env.<network> rollback
```

Repoints `CustomSender` at the pinned predecessor pool + revokes the new trigger's
`SYNC_ROLE`; the legacy system is fully restored. Control-plane only: in-flight CCIP messages
complete as sent (recipient pool is encoded at `sync()` time) and are `sweep`-recoverable
from the test pool.

## Next after both pass

> **Done on all 4 lanes (2026-07-23/24)** — but on Arbitrum + Base it transferred to the
> superseded LOL Safe (see the Status note at the top); resolve that before §3 can pass there.

`just -E .env.<network> handoff` (Deployer: sweep residue, production config, transfer to LOL) —
see RUNBOOK.md §G2. Then confirm the result with §3 below **before** the CRE workflow
registration and `finalize`.

> ⚠ **Manual sync capability ends at `handoff`.** During Stage 1 the deployer is wired as the
> `CREReceiver`'s forwarder **and** expected author (deployer-as-CRE), so it can drive
> `triggerSync()` by hand (§2). `handoff` re-pins the receiver to the real CRE forwarder +
> LOL-Safe author, and `SyncTrigger.triggerSync()` is `onlyForwarder` (= the receiver) — from
> that point **only the registered CRE workflow can sync**; no EOA (deployer, LOL, Initial
> Owner) can trigger one manually. Do all manual sync testing before `handoff`.

## 3. Post-handoff state checks (read-only, no keys)

`handoff` ends with an in-broadcast assertion of its own result, but that check runs inside
the same transaction batch that made the changes. The reads below re-observe the state from
outside, on any machine, and are the recorded G2-handoff evidence (RUNBOOK.md §Gates).

**3.a Aggregate check.**

```sh
just -E .env.<network> verify-stage2     # Evidence: "Script ran successfully"
```

Asserts in one shot: pool / trigger / receiver all **LOL-owned**; `CREReceiver` wired to the
**real CRE forwarder** with the **LOL Safe** as expected author (the deployer stand-ins are
gone); production delay/amounts restored; the pinned fee blobs / gas-limit ceiling unchanged;
pool still active (`getOraclePool()` == new pool); trigger still holds `SYNC_ROLE`;
**Initial Owner still admin** and the governance executor **not** yet admin — i.e. the
irreversible seal has NOT run. The float is NOT asserted: `handoff` sweeps the trigger's
entire ETH float back to the deployer, so the trigger arrives here **empty** — fund the
production float as a separate permissionless step (`just fund-trigger` or a bare ETH
transfer); until then `canSync()` is false and no production sync can fire.

**3.b state-mate validation (independent live-RPC evidence trail).** The itemized state is
covered by the state-mate production profile (`config/state/l2.yaml` ships production
defaults — the post-handoff expectation):

```sh
just -E .env.$L2_NETWORK test-$L2_NETWORK-upgrade-state-verify
```

Evidence: `✔ Total: ≥45 checks passed`. Point of attention: pre-`finalize`, the seal-related
checks (`CustomSender` `DEFAULT_ADMIN_ROLE` → governance executor, old automation revoked,
ProxyAdmin owner) are EXPECTED failures — everything else must be green. Full invariant list
and the two-assurance-layers caveat: RUNBOOK.md §G4.

**3.c Test residue swept** — not covered by `verify-stage2`, check explicitly
(`source .env.$L2_NETWORK` first; `$WETH`/`$WSTETH` = the lane's `L2_WETH`/`L2_WSTETH` pinned
in `script/$L2_NETWORK/<Net>MigrationConstants.sol`):

```sh
cast call $WETH   'balanceOf(address)(uint256)' $L2_ORACLE_POOL --rpc-url $L2_RPC_URL  # == 0
cast call $WSTETH 'balanceOf(address)(uint256)' $L2_ORACLE_POOL --rpc-url $L2_RPC_URL  # == 0 (see note)
cast balance $L2_SYNC_TRIGGER --rpc-url $L2_RPC_URL                                    # == 0 (float swept to the deployer)
```

> If the §2 CCIP round-trip lands **after** `handoff`, the test wstETH arrives in the
> now-LOL-owned pool — a nonzero wstETH balance here is that in-flight residue, not a missed
> sweep. It is LOL-`sweep()`-recoverable, or simply left in place as (a sliver of) pool seed.

**3.d CRE workflow: deploy + verify** — Actor: **LOL** (Safe), per lane, after `handoff`
and before `finalize` (RUNBOOK.md §G2-handoff — the production sync path must be live before
the seal; until the pool is seeded no real sync can fire):

```sh
just -E .env.$L2_NETWORK update-cre-config      # fill deploy config with live trigger/receiver addrs
just -E .env.$L2_NETWORK deploy-cre-workflow    # emits UNSIGNED WorkflowRegistry calldata
# → execute that calldata FROM THE LOL SAFE (the tx sender becomes the workflow owner —
#   must equal CREReceiver.expectedAuthor; the recipe aborts up front if they'd mismatch).
# → record the printed id: CRE_WORKFLOW_ID=... in .env.$L2_NETWORK
just -E .env.$L2_NETWORK verify-cre-workflow    # Evidence: ACTIVE, owner == LOL Safe
```

Points of attention: the workflow owner is the **Safe**, never the CLI EOA (`--unsigned`
flow; a throwaway `CRE_ETH_PRIVATE_KEY` only inits the RPC client); fund the CRE credit
under the LOL Safe's CRE account (dashboard-only — docs/monitoring.md §4).

A green result confirms the *registry* side only. Whether the DON embeds the Safe as the
report author (`expectedAuthor` gate) is first proven by the first production
`CREReceiver.CallExecuted` on this lane — gate G2-author; if reports revert `InvalidAuthor`,
see RUNBOOK.md §G2-author for the re-pin procedure.

The fork rehearsal `test_canaryDeployerSimulatedSyncAndHandoff` (§0.5 siblings) drives the
same handoff on a fork and hard-asserts this end state — run it pre-broadcast as the keyless
dress rehearsal of everything above.

## 4. Complete the admin migration (finalize each L2, then L1)

`handoff` moved only the deployer-held ownership (pool / trigger / receiver) and restored
production params. Still with the **Initial Owner**: `CustomSender` `DEFAULT_ADMIN_ROLE` +
L2 ProxyAdmin (per lane), and the L1 Receiver admin + L1 ProxyAdmin. This section passes
those; afterwards only the real liquidity seed remains (docs/runbook-liquidity-provider.md).

```sh
export L2_NETWORK=<network>   # optimism | arbitrum | base | linea
```

**4.a Per-L2 governance seal** — Actor: **Initial Owner**, **IRREVERSIBLE**, per lane, only
after §3 is green (the interlock refuses unless infra is LOL-owned + production-configured):

```sh
INITIAL_OWNER_PRIVATE_KEY=... just -E .env.$L2_NETWORK finalize
```

Does: revoke old automation(s) `SYNC_ROLE`; move `DEFAULT_ADMIN_ROLE` Initial Owner →
governance executor; transfer L2 ProxyAdmin to the executor; float top-up first.

**4.b Per-L2 post-seal reads** (no keys; §3.b's admin checks flip). Addresses
(`<GOV_EXECUTOR_ADDR>`, `<OLD_AUTOMATION_ADDR>` — Chainlink and/or Gelato, check all the lane
pins — `<L2_PROXY_ADMIN_ADDR>`) from `script/$L2_NETWORK/<Net>MigrationConstants.sol`:

```sh
source .env.$L2_NETWORK
cast call $CS 'hasRole(bytes32,address)(bool)' \
  0x0000000000000000000000000000000000000000000000000000000000000000 <GOV_EXECUTOR_ADDR> \
  --rpc-url $L2_RPC_URL                                   # == true  (executor is admin)
cast call $CS 'hasRole(bytes32,address)(bool)' \
  0x0000000000000000000000000000000000000000000000000000000000000000 <INITIAL_OWNER_ADDR> \
  --rpc-url $L2_RPC_URL                                   # == false (Initial Owner sealed out)
cast call $CS 'hasRole(bytes32,address)(bool)' \
  0xbb1ef2b79fa8154a13ffa50bd30e5f91ed93ff9b924bd04be671240cbc9d4b71 <OLD_AUTOMATION_ADDR> \
  --rpc-url $L2_RPC_URL                                   # == false (old automation SYNC_ROLE revoked)
cast call <L2_PROXY_ADMIN_ADDR> 'owner()(address)' --rpc-url $L2_RPC_URL  # == governance executor
```

> `CustomSender` is not AccessControlEnumerable — these reads prove only the two touched
> addresses; audit out-of-band admin grants off-chain (`_assertMigrationSteps` note).

Then re-run the §3.b state-mate production profile — post-seal it must be **fully green**
(the seal-gated expected failures of §3.b have flipped; this is the RUNBOOK.md §G3 evidence,
required on all 4 lanes before `migrate-l1`):

```sh
just -E .env.$L2_NETWORK test-$L2_NETWORK-upgrade-state-verify   # Evidence: exit 0, ✔ Total: … passed, NO failures
```

**4.c L1 admin migration** — Actor: **Initial Owner**, **IRREVERSIBLE**, run **ONCE** after
all 4 lanes are sealed. L1 Receiver admin + L1 ProxyAdmin → Lido DAO Agent (pinned
`L1MigrationConstants.LIDO_DAO_AGENT`, never env):

```sh
INITIAL_OWNER_PRIVATE_KEY=... just -E .env.$L2_NETWORK migrate-l1   # any lane's env; L1_RPC_URL identical
```

**4.d L1 post-migration reads** (addresses from `script/l1/L1MigrationConstants.sol`):

```sh
cast call <L1_RECEIVER_ADDR> 'hasRole(bytes32,address)(bool)' \
  0x0000000000000000000000000000000000000000000000000000000000000000 <LIDO_DAO_AGENT_ADDR> \
  --rpc-url $L1_RPC_URL                                   # == true  (DAO Agent is admin)
cast call <L1_RECEIVER_ADDR> 'hasRole(bytes32,address)(bool)' \
  0x0000000000000000000000000000000000000000000000000000000000000000 <INITIAL_OWNER_ADDR> \
  --rpc-url $L1_RPC_URL                                   # == false (Initial Owner out)
cast call <L1_PROXY_ADMIN_ADDR> 'owner()(address)' --rpc-url $L1_RPC_URL  # == Lido DAO Agent
```

4.a–4.d green on all lanes ⇒ admin migration complete (deployer + Initial Owner hold
nothing); remaining: seed the real liquidity.
