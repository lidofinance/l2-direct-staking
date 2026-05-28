# Migration runbook

Bash-first reference: every step is one command, organized by **who runs it**. Per-network secrets and addresses live in a `.env.<network>` file (one per L2: `.env.optimism`, `.env.arbitrum`, `.env.base`, `.env.linea`); `just -E .env.<net>` loads that file into the recipe environment (the justfile already has `set dotenv-load`, so `-E` just selects which file).

Pattern used throughout:

```bash
# `-E .env.<net>` loads everything — RPC URLs, keys, and the Stage-1 output addresses
# (L2_ORACLE_POOL, L2_SYNC_TRIGGER, L2_CRE_RECEIVER, CRE_WORKFLOW_ID) — into the recipe
# environment. Recipes read them directly; no need to pass them as positional args.
just -E .env.<net> <recipe> <network>
```

L1 (`migrate-l1`) is **once total** — use any one of the four `.env.<net>` files; only the L1 vars are read.

Companion docs:
- [`OPS-PLAN.md`](./OPS-PLAN.md) — full reasoning + checkpoints
- [`concise-ops-plan.md`](./concise-ops-plan.md) — stage-centric TL;DR
- [`deploy-params.md`](./deploy-params.md) — full env var inventory and "why each value"
- [`LEVERS.md`](./LEVERS.md) — post-deploy state-mutating calls

---

## 0. Per-network `.env.<network>` template

Create one file per L2. Fill values from [`deploy-params.md`](./deploy-params.md) §"Optimism / Arbitrum / Base / Linea" and the env sections.

```bash
# .env.optimism (example; adapt per network)

# Network discriminator (every recipe reads this to pick per-network logic)
L2_NETWORK=optimism   # one of: optimism | arbitrum | base | linea

# RPC URLs
L1_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
L2_RPC_URL=https://opt-mainnet.g.alchemy.com/v2/YOUR_KEY

# Stage 1 — Lido Deployer (signs runDeploy + cre workflow deploy)
L2_LIDO_DEPLOYER_PRIVATE_KEY=0x...
L2_GOVERNANCE_EXECUTOR=0xEfa0dB536d2c8089685630fafe88CF7805966FC3  # per-network; Optimism = OptimismBridgeExecutor
L2_CRE_FORWARDER=0x...                                              # per-network CRE Forwarder address
# L2_LIQUIDITY_OWNER=0x...                                          # optional; defaults to network LOL multisig
# L2_INITIAL_OWNER=0xb5c336a5c60D3482b29d83C742C65AE8351b91a8       # optional; defaults to L1.INITIAL_OWNER

# Stage 1 outputs (filled in after deploy-stage1 — recipe prints them as `export` lines)
L2_ORACLE_POOL=0x...
L2_SYNC_TRIGGER=0x...
L2_CRE_RECEIVER=0x...
L2_LIDO_DEPLOYER_ADDRESS=0x...   # = vm.addr(L2_LIDO_DEPLOYER_PRIVATE_KEY); pinned as CREReceiver.expectedAuthor

# CRE workflow id (filled in after deploy-cre-workflow)
CRE_WORKFLOW_ID=...

# Stage 2 — Initial Owner
INITIAL_OWNER_PRIVATE_KEY=0x...

# L1 migration — Initial Owner (reuses INITIAL_OWNER_PRIVATE_KEY)
LIDO_DAO_AGENT=0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c

# Optional verifier
# ETHERSCAN_API_KEY=...
```

**Never commit filled-in `.env.<net>` files.** Add `.env.optimism` etc. to `.gitignore` if not already.

---

## 1. Pre-flight (actor: anyone, ×4 networks)

```bash
# Once across all networks (no env file dependency — pure on-chain reads).
just verify-constants-sync

# Per network — bootstrap automation upkeep age, old-pool inventory, in-flight CCIP Sync events.
# Reads L2_NETWORK + L2_RPC_URL from .env.<net>.
just -E .env.<net> preflight-check

# Per network — L1 lane wiring (adapter + sender mapping).
# Reads L2_NETWORK + L1_RPC_URL from .env.<net>.
just -E .env.<net> preflight-check-l1
```

If any step fails, **stop and resolve before broadcasting**.

---

## 2. Lido Deployer (actor: holds `L2_LIDO_DEPLOYER_PRIVATE_KEY`)

Per network (×4, parallelizable):

```bash
# 1. Stage 1: deploy OraclePool + SyncTrigger + CREReceiver, transfer ownership.
#    Reads L2_NETWORK + L2_RPC_URL from .env.<net>.
#    The recipe prints `export L2_ORACLE_POOL=…/L2_SYNC_TRIGGER=…/L2_CRE_RECEIVER=…` —
#    paste those into .env.<net>.
just -E .env.<net> deploy-stage1

# 2. Update CRE workflow source with the new SyncTrigger + CREReceiver.
#    Reads L2_NETWORK + L2_SYNC_TRIGGER + L2_CRE_RECEIVER from .env.<net>.
just -E .env.<net> update-cre-config

# 3. Compile WASM and register on Ethereum-mainnet WorkflowRegistry.
#    Capture the workflow id from `cre` CLI output and add CRE_WORKFLOW_ID=… to .env.<net>.
just -E .env.<net> deploy-cre-workflow
```

---

## 3. anyone — validation gate between Stage 1 and Stage 2 (×4)

```bash
# 18 post-conditions on new contracts; asserts Stage 2 has NOT yet run.
# Reads L2_NETWORK + L2_RPC_URL + L2_ORACLE_POOL + L2_SYNC_TRIGGER + L2_CRE_RECEIVER from .env.<net>.
just -E .env.<net> verify-stage1

# Confirms WorkflowRegistry has the workflow registered, ACTIVE, with correct owner.
# Reads L1_RPC_URL + CRE_WORKFLOW_ID from .env.<net>.
just -E .env.<net> verify-cre-workflow
```

**Both must pass before Stage 2.**

---

## 4. Initial Owner (actor: holds `INITIAL_OWNER_PRIVATE_KEY`)

### Per-network L2 migration (×4, parallelizable)

```bash
# Swaps OraclePool, grants SYNC_ROLE to new SyncTrigger, revokes from old automations,
# migrates Sender admin + ProxyAdmin owner. Asserts every write landed.
# Reads L2_NETWORK + L2_RPC_URL + L2_ORACLE_POOL + L2_SYNC_TRIGGER from .env.<net>.
just -E .env.<net> migrate-stage2
```

### L1 admin migration (once across all 4 networks)

```bash
# Use any one .env.<net> — only L1 vars are read
# (L1_RPC_URL, INITIAL_OWNER_PRIVATE_KEY, LIDO_DAO_AGENT).
just -E .env.optimism migrate-l1
```

---

## 5. anyone — final state-mate verification (×4)

≥45 state-mate post-conditions per network. Pinned values include the encoded `getFeeOtoD` / `getFeeDtoO` blobs, so any drift between deployed config and `script/<net>/state-mate/<net>.yaml` fails here.

```bash
# Reads L2_RPC_URL from .env.<net>.
just -E .env.<net> test-<net>-upgrade-state-verify
```

---

## 6. LOL multisig (off-chain, no `just` recipe)

Per network, after state-mate verification passes:

```text
From the LOL multisig (network's LIQUIDITY_OWNER address from .env.<net>):
  Transfer wstETH → L2_ORACLE_POOL  (seed fastStake liquidity).
```

Until this lands, fastStake on the new pool reverts on insufficient inventory.

---

## 7. Initial Liquidity Owner (off-chain, optional, no `just` recipe)

Settles pre-migration WETH/wstETH inventory and any sync round-trip in flight at the migration boundary:

```text
On the OLD OraclePool (per network), via the Initial Liquidity Owner multisig:
  oraclePool.sweep(L2_WETH,    recipient, balanceOf(oldPool, L2_WETH))
  oraclePool.sweep(L2_WSTETH,  recipient, balanceOf(oldPool, L2_WSTETH))
```

Skippable — the old pool is no longer wired to anything live. Actor identity in [`OPS-PLAN.md`](./OPS-PLAN.md) §"Initial Liquidity Owner".

---

## 8. Post-migration health (anyone, ongoing)

Wire the alerts in [`alerts-spec.md`](./alerts-spec.md). The first sync round-trip after migration validates the full L2→L1→L2 path end-to-end. Watch:

- `SyncTrigger.getLastExecution()` advances within 12 h after pool reaches `minSyncAmount`
- L1 `LidoCustomReceiver.MessageSucceeded(messageId)` emits ~20 min after each L2 `CustomSender.Sync(_, _, messageId, _)`
- L2 `OraclePool` wstETH balance refills via the per-L2 native bridge SLA after each sync

Cheap on-chain check (no env file needed):

```bash
just balances-l1 "$L1_RPC_URL"
just balances-<net> "$L2_RPC_URL"
```

---

## Quick sanity matrix

| Step | Actor | Env file consumed | Idempotent |
|---|---|---|---|
| `verify-constants-sync` | anyone | none | ✓ |
| `preflight-check[-l1]` | anyone | `.env.<net>` (RPC URLs) | ✓ |
| `deploy-stage1` | Lido Deployer | `.env.<net>` (deployer key + GovExec + CRE Forwarder) | no — each run = new addresses |
| `update-cre-config` | Lido Deployer | `.env.<net>` (Stage-1 outputs) | ✓ |
| `deploy-cre-workflow` | Lido Deployer | `.env.<net>` + `cre` CLI creds | re-deploy = upsert |
| `verify-stage1` | anyone | `.env.<net>` (Stage-1 outputs + GovExec + CRE Forwarder + deployer address) | ✓ |
| `verify-cre-workflow` | anyone | `.env.<net>` (CRE_WORKFLOW_ID) | ✓ |
| `migrate-stage2` | Initial Owner | `.env.<net>` (initial-owner key + GovExec) | no — Stage-2 guards in `verifyStage1` block re-runs |
| `migrate-l1` | Initial Owner | any `.env.<net>` (L1 vars only) | no — re-runs revert when role already moved |
| `test-<net>-upgrade-state-verify` | anyone | `.env.<net>` (RPC URL) | ✓ |

---

## Sepolia rehearsal

Same `-E` pattern, but the recipes are Sepolia-specific (no positional args; everything from env):

```bash
set -a; source .env.sepolia; set +a

# Bootstrap CSR (mainnet has this pre-deployed; testnet needs it):
just -E .env.sepolia sepolia-deploy-csr

# Mirrors mainnet stages:
just -E .env.sepolia sepolia-deploy-stage1
just -E .env.sepolia sepolia-verify-stage1
just -E .env.sepolia sepolia-migrate-stage2
just -E .env.sepolia sepolia-upgrade-l1

# State-mate verification:
just -E .env.sepolia test-sepolia-upgrade-state-verify
```

Env scaffolded by [`.env.sepolia.example`](../.env.sepolia.example). Differences from mainnet: see [`deploy-params.md`](./deploy-params.md) §"Sepolia (testnet)" — lower amounts/delays, 0.1 ETH `maxFee` instead of 0.125, 400k `gasLimit` instead of 1M, EOAs in place of multisigs, MockAggregator instead of live Chainlink feed.
