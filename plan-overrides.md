# Use state-mate `--overrides` for the canary TestStage profile

## Context

Today the state-mate config carries the canary (Stage-1) and production profiles in one
file via a fragile mechanism:

- `config/state/l2.yaml` ships the **canary** profile — its 7 handoff-scoped checks reference
  `*l2LidoDeployer` / `*syncDelayTestStage` / `*syncMinAmountTestStage`.
- A permanent **parking block** in `l2.yaml` `misc:` (lines 44–57) aliases *both* profiles'
  swappable anchors, only to satisfy state-mate's "every `.inputs` anchor must be referenced"
  invariant.
- After `handoff`, the operator **hand-edits 7 lines** in `l2.yaml` to swap canary → production
  anchors before the final state-mate run.

state-mate's `feat/separate-deployed` branch HEAD (`5038c5a`, newer than our pinned `deaf6b7`)
adds a clean **`--overrides <path>`** feature: an inputs-shaped overlay file that *redefines the
values of labels already in the `.inputs` file*. Rules enforced by the engine:
1. **No new labels** — every overlay anchor must already exist in the base `.inputs`.
2. **Value must differ** — a no-op override (same value as base) is rejected.
3. **Same section** — `config:` stays `config:`, `externals:` stays `externals:`.
4. Explicit-only — never auto-discovered (applying it is always deliberate). Requires `--inputs`.

**Goal:** replace the parking-block + manual-swap mechanism with a single explicit shared
`config/state/l2.inputs.test-stage.yaml` overlay driven by `--overrides`.

## Key design consequence (the approach is forced, not chosen)

Rule #2 (value must differ) means the base `.inputs` must hold **one** profile and the overlay the
**other**. Since production is the permanent, canonical end state and the base already defines the
production anchors (`syncMinAmount`, `syncDelay`, `l2LiquidityOwner`, `l2CreForwarder`), the only
valid layout is:

- **Base `.inputs` = production** (committed default). `l2.yaml` references production anchors.
- **Overlay `.inputs.test-stage.yaml` = canary** (deployer-owned, tiny amounts), applied with
  `--overrides` only for the pre-handoff canary run.

This **inverts today's default** (production becomes the committed state) and is strictly better:
the permanent production verification needs **no overlay and no hand-editing**, and the canary is an
explicit, deliberate overlay — matching the feature's intent.

Flipping the 7 checks to production anchors also makes those anchors referenced *live* in `l2.yaml`,
so **the parking block becomes fully removable** (verified: every remaining base-inputs anchor is
referenced live after the flip; the two `*TestStage` anchors are the only ones removed).

The 4 canary anchors and their values (lane-invariant — same deployer + amounts on every lane):

| `l2.yaml` check | production anchor (base) | canary value (overlay) |
|---|---|---|
| `syncTrigger.getDelay` | `syncDelay` 43200 | `60` |
| `syncTrigger.getAmounts[0]` | `syncMinAmount` 5e18 | `0.0002e18` |
| pool/trigger/receiver `owner`, `getExpectedAuthor` | `l2LiquidityOwner` (real LOL) | deployer `0xf39F…` |
| `creReceiver.getForwarder` | `l2CreForwarder` (real fwd) | deployer `0xf39F…` |

## Changes

### A. Bump the state-mate submodule  ← required first (older pin has no `--overrides`)
- `lib/state-mate`: check out `5038c5a` (HEAD of the tracked `feat/separate-deployed`), then
  `yarn install --immutable` (the commit bumps only the version string + source; lockfile unchanged).
- Records a working-tree change to the submodule pointer. **Committing is left to you** (per repo
  convention — commit only when asked).

### B. `config/state/l2.yaml` (shared wiring)
- Flip the 7 handoff-scoped checks to production anchors and drop the inline
  "canary … swap after handoff" notes:
  - L161 `oraclePool.owner: *l2LiquidityOwner`
  - L184 `syncTrigger.owner: *l2LiquidityOwner`
  - L185 `syncTrigger.getDelay: *syncDelay`
  - L187 `getAmounts result: [*syncMinAmount, *syncMaxAmount]`
  - L202 `creReceiver.owner: *l2LiquidityOwner`
  - L203 `creReceiver.getForwarder: *l2CreForwarder`
  - L204 `creReceiver.getExpectedAuthor: *l2LiquidityOwner`
- **Delete the parking block** (L44–57); `misc:` keeps only the two EIP-1967 slot anchors (L42–43).
- Rewrite the header (L28–36 "CANARY vs PRODUCTION PROFILE" + the example invocation at L6–8):
  production is the default; the canary run adds `--overrides config/state/l2.inputs.test-stage.yaml`.

### C. `config/state/l2-<net>.inputs.yaml` (×4: optimism, arbitrum, base, linea)
- Remove the `&syncMinAmountTestStage` / `&syncDelayTestStage` anchors + their "Canary deploy-test
  overrides" comment (OP L13–15; ~L11–13 on the others). Production `syncMinAmount`/`syncDelay` stay.
- Trim the `l2LidoDeployer` comment's "2nd use (canary) … set this LOCALLY" paragraph (OP L51–54) —
  the canary deployer now lives in the overlay file. Keep the dev-fork / vacuous-`hasRole` note; add
  a one-line pointer to the overlay file.

### D. NEW `config/state/l2.inputs.test-stage.yaml`  ← single shared overlay (all 4 lanes)
One inputs-shaped overlay (shared like `l2.yaml` itself), redefining the 4 canary anchors. The
canary values are lane-invariant (same deployer + amounts), and the engine's "value must differ"
gate passes against every lane's production base, so one file serves all four:
```yaml
---
# Canary Stage-1 overlay (state-mate --overrides), shared by all 4 lanes like l2.yaml. Redefines the 4
# anchors the canary deploy sets to deployer/test values, so `--overrides this-file` verifies the live
# pre-handoff state. handoff() restores the production values in l2-<net>.inputs.yaml; drop --overrides
# for the final run. Every label here MUST exist in each l2-<net>.inputs.yaml and differ (state-mate
# enforces both per lane; verify-externals-coverage mirrors it pre-commit).
config:
  - &syncMinAmount 200000000000000 # 0.0002e18  canary getAmounts()[0]  (prod 5e18)
  - &syncDelay 60                    # 1 min    canary getDelay()        (prod 12h)
externals:
  # Pre-handoff the deployer owns pool/SyncTrigger/CREReceiver and is the CRE forwarder + author.
  # ⚠ DEV-FORK deployer (Anvil #0); for a MAINNET canary run set both to the real deployer LOCALLY (uncommitted).
  - &l2LiquidityOwner "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  - &l2CreForwarder  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
```

### E. `justfile`  (all paths point at the single shared `config/state/l2.inputs.test-stage.yaml`)
Mandatory (these recipes currently read the now-removed `*TestStage` anchors):
- `deploy-test` (L1033–1039), `verify-test` (L1097–1104): source `syncMinAmount`/`syncDelay` from the
  shared overlay instead of `*TestStage` from base `.inputs`; update the comments (L1022–1023, L1084) + echo.
- `simulate-sync` (L1167–1169): read `syncDelay` from the shared overlay; update the reminder text.

Canary state-mate path:
- `_state-verify` (L2716, L2740–2743): add an `overrides=''` param; when set, append
  `--overrides "$ROOT_DIR/config/state/l2.inputs.test-stage.yaml"` to the sibling args.
  Existing 2-arg production wrappers keep working unchanged (no overlay = production).
- Add `test-<net>-upgrade-state-verify-canary` (×4) → `_state-verify <net> "" canary`.
- Lint hardening — extend `verify-externals-coverage`: for each `l2-<net>.inputs.yaml`, assert every
  anchor in `l2.inputs.test-stage.yaml` (a) exists in that base, (b) sits in the same section, and
  (c) holds a value that differs — a pre-commit, no-RPC mirror of state-mate's runtime overlay rules.

### F. Docs / script comments
- `docs/mainnet-simulated-cre-test.md` (L74–89): rewrite the "state-mate canary profile" section and
  table to "production default + `--overrides` canary overlay"; replace the "set `l2LidoDeployer`
  locally" bullet with the `--overrides` invocation.
- `RUNBOOK.md`: replace the "⚠ Swap `l2.yaml` to its production profile first" block (L310–315) with
  "production is the default; for the canary use `--overrides` / `…-state-verify-canary`"; fix the
  `deploy-test` env note (L41).
- `script/shared/L2UpgradeScriptBase.s.sol` (L216–218 NatSpec): point at the overlay file's
  `syncMinAmount`/`syncDelay` instead of the `*TestStage` anchors. Comment-only; the Solidity
  `_canaryTestCfg` keeps reading `L2_SYNC_MIN_AMOUNT_TEST`/`L2_SYNC_DELAY_TEST` env (set by recipes).
  (This is a script, not `src/` — repo references are allowed here.)

## Verification
1. `cd lib/state-mate && yarn install --immutable && yarn test` — new `overrides.test.ts` passes.
2. `yq '.. | select(anchor=="syncMinAmount")' config/state/l2.inputs.test-stage.yaml`
   → `200000000000000`; repeat for `syncDelay` → `60`. Confirms the recipe sourcing.
3. `just verify-constants-sync` and `just verify-externals-coverage` stay green (no RPC).
4. `forge build` + `just test` (138 unit tests) green (only a comment changes in `.s.sol`).
5. Layering gates (config-validation phase, before RPC): run state-mate **with** `--overrides`
   against a dev fork / any RPC and confirm no `unused anchor` / `no-op override` / `new label` /
   `section` error; and **without** `--overrides` confirm no orphaned-anchor error (parking-block
   removal is safe). Full on-chain pass needs a fork/CI RPC.

## Notes / risks
- **One shared overlay** (`config/state/l2.inputs.test-stage.yaml`) serves all 4 lanes — valid because
  the canary values are lane-invariant and differ from every lane's production base.
- A **mainnet** canary state-mate run needs the real deployer in the overlay's two address values, set
  locally and uncommitted — now a single edit (one file) instead of per-lane.
- No `src/` contract changes; no ABI changes. Lints and unit tests don't need an RPC.
