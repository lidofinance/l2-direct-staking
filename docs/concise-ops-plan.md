# Concise migration ops plan

## Stage 0 — Pre-flight (anyone, read-only)

- Once across all networks: `just verify-constants-sync`
- Per network (×4): `just -E .env.<net> preflight-check`
- Per network (×4): `just -E .env.<net> preflight-check-l1`

## Stage 1 — Deploy (Lido Deployer, per network ×4, parallelizable)

Required env: `L2_LIDO_DEPLOYER_PRIVATE_KEY`, `L2_GOVERNANCE_EXECUTOR`, `L2_CRE_FORWARDER`.

1. **Lido Deployer** — `just -E .env.<net> deploy-stage1` — prints `L2_ORACLE_POOL` / `L2_SYNC_TRIGGER` / `L2_CRE_RECEIVER` as `export` lines; paste them into `.env.<net>`.
2. anyone — `just -E .env.<net> verify-stage1`
3. **Lido Deployer** — `just -E .env.<net> update-cre-config`
4. **Lido Deployer** — `just -E .env.<net> deploy-cre-workflow` — capture `CRE_WORKFLOW_ID` from the `cre` CLI output and paste into `.env.<net>`.
5. anyone — `just -E .env.<net> verify-cre-workflow`

## Stage 2 — Migrate (Initial Owner)

Required env: `INITIAL_OWNER_PRIVATE_KEY`, `L2_GOVERNANCE_EXECUTOR`, plus `LIDO_DAO_AGENT` (or `LIDO_NEW_OWNER`) for the L1 step.

Per network ×4, parallelizable:

1. **Initial Owner** — `just -E .env.<net> migrate-stage2`
2. anyone — `just -E .env.<net> test-<net>-upgrade-state-verify` — ≥45 state-mate post-conditions.

Once across all networks (L1 receiver is shared):

- **Initial Owner** — `just -E .env.<any-net> migrate-l1`

## Stage 3 — Post-migration (off-chain, no recipe)

- **LOL multisig** — transfer wstETH to the new `OraclePool` to seed `fastStake` liquidity.
- **Initial Liquidity Owner** — `OraclePool.sweep(token, recipient, amount)` on the old pool — optional; settles pre-migration liquidity and any wstETH from a sync round-trip that was in flight at the migration boundary.

## Notes

- Within each stage, per-network steps fan out across the 4 L2s (Optimism, Arbitrum, Base, Linea); the same actor can run them concurrently.
- `migrate-l1` runs **once total**; `LidoCustomReceiver` is shared across all four lanes.
- `deploy-stage1` → subsequent commands hand-off via the three address env vars (`L2_ORACLE_POOL` / `L2_SYNC_TRIGGER` / `L2_CRE_RECEIVER`); the recipe prints them export-ready.
- Migrating with an in-flight sync is safe — wstETH lands in the old pool by design and the Initial Liquidity Owner sweeps it. See [`../README.md`](../README.md) §Migration ordering.

Full reference: [`OPS-PLAN.md`](./OPS-PLAN.md) · [`../README.md`](../README.md).
