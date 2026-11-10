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
| `receiver-history.js` | RPC receiver history and checkpoint persistence |
| `registry.js` | WorkflowRegistry reads and record attributes |
| `automation.js` | Automation tab |
| `calldata.js` | CRE Calldata tab |
| `rpc-settings.js` | RPC override dialog |
| `sha256.js` | Synchronous sha256 |
| `main.js` | Refresh loop, tabs, event wiring |

## Activity snapshots

`static/activity-snapshot.js` contains a checked block and up to 50 recent events
for each of Optimism, Arbitrum, Base and Linea. Retaining each lane's history
allows older rows to enter the table when a reorg removes newer events.
The Activity tab immediately displays the latest 50 events across all lanes,
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

## Receiver failure history

`static/receiver-snapshot.js` contains all receiver failure, retry and recovery
events since 1 August 2026, derived from a complete RPC scan. The L1 failures
panel resumes from that checkpoint with a 1,800-block overlap; it does not use
an explorer's indexed height as evidence of complete history. Every failure is
retained, including resolved incidents. A newer valid browser checkpoint takes
precedence. The browser replaces overlapping events and saves progress only
after event decoding and all failed-message state reads succeed.

Logs and contract state are read at the same block, two blocks behind the RPC
head to allow for small differences between provider backends. Failures and
recoveries in those last two blocks appear on a later refresh. This margin and
the reorg overlap are not finality guarantees.

Update the bundled history before publishing (Node 22.7 or later):

```sh
node script/site/update-receiver-snapshot.cjs
node --test script/site/*.test.cjs
```

The updater reads `RPC_ETHEREUM_REMOTE` from the environment, checks mainnet's
chain ID, and stops 1,800 blocks behind the head. It writes only public event
data, after the whole scan and decoding succeed. Use `--rebuild` to derive the
first block at or after 1 August and scan the complete window again; that mode
requires an RPC with historical logs for the whole window. Normal updates need
history from the saved checkpoint's overlap. Refresh the snapshot regularly so
first-time visitors stay within their RPC's available log history. If that
history is unavailable, the panel reports the failed range rather than claiming
there were no failures. An RPC can still return incomplete data without an
error; this design trusts its log responses and does not prove chain completeness.
