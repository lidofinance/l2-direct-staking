# Dashboard

`index.html` loads `static/main.js` as an ES module; the other files in `static/`
are its imports. Browsers block module scripts opened from `file://`, so serve the
folder to view it locally:

```sh
python3 -m http.server -d site 8000
```

Then open http://localhost:8000. GitHub Pages publishes `site/` as is.

| Module | Contents |
|---|---|
| `config.js` | Addresses, lanes, RPC defaults, CRE workflow pins |
| `rpc.js` | ABI helpers, JSON-RPC batching and pacing, log history, Blockscout logs |
| `ui.js` | Formatting, chips, holder labels, tab status |
| `core.js` | Overview and Access Control |
| `sync-volume.js` | Synced to L1 tile |
| `activity.js` | Pool activity |
| `shuttles.js` | L1 failures |
| `registry.js` | WorkflowRegistry reads and record attributes |
| `automation.js` | Automation tab |
| `calldata.js` | CRE Calldata tab |
| `rpc-settings.js` | RPC override dialog |
| `sha256.js` | Synchronous sha256 |
| `main.js` | Refresh loop, tabs, event wiring |

## Activity snapshots

`static/activity-snapshot.js` contains a checked block and up to 50 recent events
for Optimism, Arbitrum, Base and Linea. The Activity tab displays these immediately,
then reads RPC logs from the checkpoint with a 1,800-block overlap. It replaces
that overlap and stores the new block and events together in `localStorage` only
after both pool transfers and SlowStake events load successfully. A newer browser
snapshot takes precedence over the bundled one. The overlap covers short reorgs;
it is not a chain finality guarantee.

Before publishing the site, update the snapshot from the repository root with
Node 22.7 or later:

```sh
node --env-file=.env script/site/update-activity-snapshot.cjs
node --test script/site/activity.test.cjs
```

The updater uses `RPC_OPTIMISM_REMOTE`, `RPC_ARBITRUM_REMOTE`, `RPC_BASE_REMOTE`
and `RPC_LINEA_REMOTE`. These endpoints must support logs since the saved blocks.
It writes no RPC URLs or credentials and saves the file after each network
succeeds, so a failure keeps the networks already updated. It stops at the first
failed network. Review and publish the changed snapshot with the site through
the existing Pages workflow. Browsers cannot update the bundled file themselves;
refresh it regularly to keep first-visit RPC scans short.
