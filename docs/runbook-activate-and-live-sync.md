# RUNBOOK — Pool Switch (activate) + Live Canary Sync

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
`1e17` = 0.1 WETH; must exceed the 0.05 test minAmount); `L2_SYNC_MIN_AMOUNT_TEST` /
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
cast call $L2_SYNC_TRIGGER 'getAmounts()(uint128,uint128)' --rpc-url $L2_RPC_URL # min == 0.05e18 (test)
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
holds `SYNC_ROLE`, Initial Owner still admin, trigger float fully funded.

> From this moment L2 `fastStake` routes through the **new** pool, which has no wstETH seed
> yet — keep the window to the LOL seed short (docs/runbook-liquidity-provider.md);
> `sync`-accrual of WETH works regardless.

## 2. Live sync test with little liquidity — Deployer (Stage 1)

```sh
just -E .env.<network> seed-test-weth    # deposit ETH→WETH + transfer into the pool
                                         # default 0.1 WETH (L2_TEST_WETH_SEED), test minAmount = 0.05
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

## Rollback (only from here, before handoff)

If the test is unsatisfactory:

```sh
INITIAL_OWNER_PRIVATE_KEY=... just -E .env.<network> rollback
```

Repoints `CustomSender` at the pinned predecessor pool + revokes the new trigger's
`SYNC_ROLE`; the legacy system is fully restored. Control-plane only: in-flight CCIP messages
complete as sent (recipient pool is encoded at `sync()` time) and are `sweep`-recoverable
from the test pool.

## Next after both pass

`just -E .env.<network> handoff` (Deployer: sweep residue, production config, transfer to LOL) —
see RUNBOOK.md §G2.
