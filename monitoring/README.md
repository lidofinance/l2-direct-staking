# Direct Staking — state monitor

Single-file web dashboard over the Lido CCIP Direct-Staking deployment: the shared L1 receiver plus the four L2 lanes (Optimism, Arbitrum, Base, Linea).

Open `index.html` in a browser. No build, no dependencies — plain `eth_call` batches against public RPCs (publicnode), auto-refresh every 60 s. If `file://` fetches are blocked, serve it:

```sh
python3 -m http.server 8080
```

## What it shows

Per lane:

- **Tiles** — pool WETH (vs min/max sync amounts), pool wstETH (fastStake liquidity), time since last sync, `canSync()` / `shouldSyncAmount()`.
- **Sync line** — idle / cooldown / due / **BLOCKED** (due but `canSync()` false: fee float, `SYNC_ROLE`, or pool pause).
- **Checks** — sender→pool wiring, sender admin, `SYNC_ROLE` population (new trigger granted, retired/legacy revoked), ProxyAdmin / SyncTrigger / CREReceiver / OraclePool owners, CREReceiver forwarder + expected author + `triggerSync` allow-list, fee float vs `getMaxFees()` (warn < 2×, crit < 1×).

L1: receiver admin, ProxyAdmin owner, and receiver ETH / stETH / wstETH balances (expected ~0).

Owner checks accept the migration target and flag the pre-migration holder as WARN, anything else as CRIT. Addresses and role hashes are pinned from the `l2-direct-staking` repo configs (`config/state/*.inputs.yaml`, `*.deployed.yaml`); edit the constants at the top of `index.html` when they change.
