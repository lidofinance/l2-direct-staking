import { ACTIVITY_SNAPSHOT } from './activity-snapshot.js';
import { LANES, NAMES, RPC_DEFAULTS } from './config.js';
import { RPC_CONFIRMATIONS, rpcBatchChunks, rpcBlockNumber, rpcHistoryLogs } from './rpc.js';
import { ago, alink, eqa, esc, fmtAmt, holder, netLogo, refreshingViews, setTabStatus, short, viewRefresh, ZERO } from './ui.js';

// ── Pool activity ────────────────────────────────────────────────────────────
const SLOW_STAKE_TOPIC = '0xb9a1909fb1e8f533ab60d262ba908dc82a1d8dfaef2e6c4e4b2da76de8a1ca4d';
const TRANSFER_TOPIC = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';

async function poolActivityData(L, fromBlock, toBlock) {
  // Both transfer directions share one range so classification sees every leg of a transaction.
  const poolTopic = '0x' + '0'.repeat(24) + L.pool.slice(2).toLowerCase();
  const [outbound, inbound] = await Promise.all([
    rpcHistoryLogs(L, [L.weth, L.wsteth], [TRANSFER_TOPIC, poolTopic], fromBlock, toBlock),
    rpcHistoryLogs(L, [L.weth, L.wsteth], [TRANSFER_TOPIC, null, poolTopic], fromBlock, toBlock),
  ]);
  const byTx = new Map();
  const seen = new Set();
  for (const log of [...outbound, ...inbound]) {
    const key = `${log.transactionHash}:${log.logIndex}`;
    if (seen.has(key) || (log.topics?.[0] ?? '').toLowerCase() !== TRANSFER_TOPIC ||
        !/^0x[0-9a-f]{64}$/i.test(log.data ?? '') || !/^0x[0-9a-f]{64}$/i.test(log.transactionHash ?? '')) continue;
    seen.add(key);
    const from = topicAddress(log.topics[1]), to = topicAddress(log.topics[2]);
    const token = eqa(log.address, L.weth) ? 'WETH' : eqa(log.address, L.wsteth) ? 'wstETH' : null;
    if (!from || !to || !token) continue;
    const g = byTx.get(log.transactionHash) ?? { tx: log.transactionHash,
      block: Number(BigInt(log.blockNumber)), in: [], out: [] };
    (eqa(to, L.pool) ? g.in : g.out).push({ token, amount: BigInt(log.data), from, to });
    byTx.set(log.transactionHash, g);
  }
  return [...byTx.values()].map(g => classifyTx(L, g));
}

const topicAddress = topic => /^0x[0-9a-f]{64}$/i.test(topic ?? '') ? '0x' + topic.slice(-40) : null;

function parseSlowStakeLog(L, log) {
  const topics = log.topics ?? [];
  const data = log.data ?? '';
  const tx = log.transactionHash ?? '';
  if ((topics[0] ?? '').toLowerCase() !== SLOW_STAKE_TOPIC ||
      !/^0x[0-9a-f]{128}$/i.test(data) || !/^0x[0-9a-f]{64}$/i.test(tx)) return null;
  const user = topicAddress(topics[1]);
  const token = topicAddress(topics[3]);
  if (!user || !eqa(token, L.weth)) return null;
  const amount = BigInt('0x' + data.slice(66, 130));
  return { tx, block: Number(BigInt(log.blockNumber)),
    kind: 'stake', label: 'Slow stake', amount: `${fmtAmt(amount)} WETH → L1`, cp: user };
}

async function slowStakeData(L, fromBlock, toBlock) {
  const logs = await rpcHistoryLogs(L, L.sender, [SLOW_STAKE_TOPIC], fromBlock, toBlock);
  return logs.map(log => parseSlowStakeLog(L, log)).filter(Boolean);
}

export async function activityData(L) {
  // PublicNode rejects log reads on some lanes; use the public chain RPCs for activity.
  // A user-supplied endpoint still takes precedence for every activity request.
  L = { ...L, logsRpc: L.rpc === RPC_DEFAULTS[L.name] ? L.activityRpc ?? L.receiptsRpc ?? L.rpc : L.rpc };
  const previous = activityProgress[L.name];
  const toBlock = await rpcBlockNumber(L);
  if (toBlock < previous.block) throw new Error('RPC head is behind the activity checkpoint');
  // Reread the reorg window before the checkpoint and replace what it held.
  const fromBlock = Math.max(0, previous.block - RPC_CONFIRMATIONS + 1);
  const [pool, slowStakes] = await Promise.all([
    poolActivityData(L, fromBlock, toBlock).catch(e => { throw new Error(`pool: ${e.message}`); }),
    slowStakeData(L, fromBlock, toBlock).catch(e => { throw new Error(`SlowStake: ${e.message}`); }),
  ]);
  const fresh = [...pool, ...slowStakes].sort((a, b) => b.block - a.block).slice(0, 50);
  const blockNumbers = [...new Set(fresh.map(e => e.block))];
  const blocks = await rpcBatchChunks(L.logsRpc, blockNumbers.map(n =>
    ({ method: 'eth_getBlockByNumber', params: ['0x' + n.toString(16), false] })));
  fresh.forEach(e => {
    const timestamp = blocks[blockNumbers.indexOf(e.block)]?.timestamp;
    if (!timestamp) throw new Error('block timestamp unavailable');
    e.ts = Number(BigInt(timestamp));
  });
  // Both sources and the cursor commit together, so a failed read retries the same range.
  const events = [...fresh, ...previous.events.filter(e => e.block < fromBlock)].slice(0, 50);
  activityProgress[L.name] = { chainId: L.chainId, block: toBlock, events };
  try { localStorage.setItem(ACTIVITY_PROGRESS_KEY, JSON.stringify(activityProgress)); } catch {}
  return events;
}

function classifyTx(L, g) {
  const find = (legs, token) => legs.find(l => l.token === token);
  const wIn = find(g.in, 'WETH'), wsOut = find(g.out, 'wstETH');
  const wOut = find(g.out, 'WETH'), wsIn = find(g.in, 'wstETH');
  const base = { tx: g.tx, block: g.block };
  if (wIn && wsOut) return { ...base, kind: 'stake', label: 'Fast stake',
    amount: `${fmtAmt(wIn.amount)} WETH → ${fmtAmt(wsOut.amount)} wstETH`, cp: wsOut.to };
  if (wOut) return eqa(wOut.to, L.sender)
    ? { ...base, kind: 'sync', label: 'Sync → L1', amount: `−${fmtAmt(wOut.amount)} WETH`, cp: wOut.to }
    : { ...base, kind: 'flow', label: 'WETH out', amount: `−${fmtAmt(wOut.amount)} WETH`, cp: wOut.to };
  if (wsIn) return { ...base, kind: 'flow', label: eqa(wsIn.from, ZERO) ? 'Top-up · bridge' : 'Top-up',
    amount: `+${fmtAmt(wsIn.amount)} wstETH`, cp: wsIn.from };
  if (wsOut) return { ...base, kind: 'flow', label: 'wstETH out', amount: `−${fmtAmt(wsOut.amount)} wstETH`, cp: wsOut.to };
  return { ...base, kind: 'flow', label: 'WETH in', amount: `+${fmtAmt(wIn.amount)} WETH`, cp: wIn.from };
}

const ACTIVITY_SEEN_KEY = 'direct-staking-watch.activity-seen';
const ACTIVITY_PROGRESS_KEY = 'direct-staking-watch.activity-progress.v1';
export const activityProgress = readActivityProgress();
let latestActivity = null;
let activitySeen = readActivitySeen();
let activityFailed = false;
// Rows newer than this marker render highlighted; it advances when the tab is (re)opened,
// so the highlight survives auto-refreshes while the user is looking at the table.
let activityViewBoundary = readActivitySeen();
let lastActivityResults = null;
// The table opens on the latest rows; "Show all" reveals the rest of what was already fetched.
const ACTIVITY_PREVIEW_ROWS = 20;
let activityShowAll = false;
let activityTabActive = false;
let activityRenderedAt = null;
// The cursor and its events form one record; a saved one wins only if it is ahead of the bundled snapshot.
function readActivityProgress() {
  let saved;
  try { saved = JSON.parse(localStorage.getItem(ACTIVITY_PROGRESS_KEY)); } catch {}
  return Object.fromEntries(LANES.map(L => {
    const seed = ACTIVITY_SNAPSHOT[L.name], item = saved?.[L.name];
    const valid = item?.chainId === L.chainId && Number.isSafeInteger(item.block) &&
      item.block >= seed.block && Array.isArray(item.events);
    return [L.name, valid ? item : seed];
  }));
}

function readActivitySeen() {
  try {
    const marker = JSON.parse(localStorage.getItem(ACTIVITY_SEEN_KEY));
    return marker && Number.isFinite(marker.ts) && Array.isArray(marker.txs) ? marker : null;
  } catch { return null; }
}

function saveActivitySeen() {
  try { localStorage.setItem(ACTIVITY_SEEN_KEY, JSON.stringify(activitySeen)); } catch {}
}

function hasUnseenActivity() {
  if (!latestActivity || !activitySeen) return false;
  return latestActivity.ts > activitySeen.ts ||
    latestActivity.ts === activitySeen.ts && latestActivity.txs.some(tx => !activitySeen.txs.includes(tx));
}

function updateActivityTabStatus() {
  setTabStatus('activity', activityFailed ? 'crit' : hasUnseenActivity() ? 'new' : null);
}

function markActivitySeen() {
  if (latestActivity) {
    activitySeen = latestActivity;
    saveActivitySeen();
  }
  updateActivityTabStatus();
}

export function renderActivity(results) {
  const failed = results.filter(r => r.error).map(r => `${r.L.name} (${r.error})`);
  const pending = results.filter(r => r.pending).map(r => r.L.name);
  const stale = results.some(r => r.error && r.events);
  const rows = results.filter(r => r.events)
    .flatMap(r => r.events.map(e => ({ L: r.L, ...e })))
    .sort((a, b) => b.ts - a.ts).slice(0, 60);
  activityFailed = failed.length > 0;
  latestActivity = rows.length ? {
    ts: rows[0].ts,
    txs: rows.filter(r => r.ts === rows[0].ts).map(r => r.tx).sort(),
  } : null;
  if (!activitySeen && latestActivity) {
    activitySeen = latestActivity;
    saveActivitySeen();
  }
  if (activityTabActive) markActivitySeen();
  else updateActivityTabStatus();
  lastActivityResults = results;
  const isFresh = e => !!activityViewBoundary && (e.ts > activityViewBoundary.ts ||
    e.ts === activityViewBoundary.ts && !activityViewBoundary.txs.includes(e.tx));
  const shown = activityShowAll ? rows : rows.slice(0, ACTIVITY_PREVIEW_ROWS);
  const tr = shown.map(e => `<tr${isFresh(e) ? ' class="fresh"' : ''}>
    <td><span class="num"><div class="m">${ago(e.ts)}</div><div class="s">${new Date(e.ts * 1000).toLocaleString()}</div></span></td>
    <td><span class="who"><span class="avatar">${netLogo(e.L)}</span><span class="name">${e.L.name}</span></span></td>
    <td><span class="tag ${e.kind}">${e.label}</span></td>
    <td><span class="num"><div class="m">${e.amount}</div></span></td>
    <td><span class="who">${alink(e.L, e.cp, NAMES[e.cp.toLowerCase()] && !eqa(e.cp, ZERO) ? holder(e.cp) : undefined)}</span></td>
    <td><a href="${e.L.explorer}/tx/${e.tx}" target="_blank" title="${e.tx}" class="mono">${short(e.tx)}&thinsp;↗</a></td>
  </tr>`).join('');
  document.getElementById('activity').innerHTML = `<div class="card">
    <div class="card-head">
      <h3>Pool Activity</h3>
      <span class="desc">Latest pool transactions across all lanes.</span>
      <span class="upd" id="activity-upd" role="status" aria-live="polite"></span>
      ${viewRefresh('activity', 'Pool activity')}
    </div>
    ${failed.length ? `<div class="err-banner">✕ Activity source unavailable: ${failed.map(esc).join(', ')}${stale ? ' · showing cached activity' : ''}<button class="retry" data-action="activity-retry">⟳ retry</button></div>` : ''}
    ${pending.length ? `<div class="loader"><span class="spin"></span> Loading ${pending.join(', ')} history…</div>` : ''}
    ${rows.length ? `<div class="scroll-x"><table>
      <tr><th>Age</th><th>Lane</th><th>Action</th><th>Amount</th><th>Counterparty</th><th>Tx</th></tr>
      ${tr}</table></div>${rows.length > shown.length ? `<div class="show-all">
        <button type="button" class="refresh alt" data-action="activity-show-all">Show all ${rows.length}</button>
      </div>` : ''}` : failed.length || pending.length ? '' : '<div class="err-banner">no transfers found</div>'}
  </div>`;
  updateActivityUpd();
}

// Called by selectTab; the highlight boundary advances only when the tab is (re)opened.
export function setActivityTabActive(active) {
  activityTabActive = active;
  if (!active) return;
  activityViewBoundary = activitySeen;   // highlight what arrived since the last visit
  markActivitySeen();
  if (lastActivityResults) renderActivity(lastActivityResults);
}

export function showAllActivity() {
  activityShowAll = true;
  renderActivity(lastActivityResults);
}

export function updateActivityUpd() {
  const el = document.getElementById('activity-upd');
  if (!el) return;
  const busy = refreshingViews.has('activity') || lastActivityResults?.some(r => r.pending);
  el.innerHTML = busy ? '<span class="spin" aria-hidden="true"></span>updating…'
    : activityRenderedAt ? `updated ${ago(Math.floor(activityRenderedAt / 1000))}` : '';
}
// One read at a time: auto-refresh, the refresh button and retry share it.
let activityRefresh = null;
export function refreshActivity() {
  return activityRefresh ??= readActivity().finally(() => { activityRefresh = null; });
}
async function readActivity() {
  const results = LANES.map(L => ({ L, pending: true, events: activityProgress[L.name].events }));
  renderActivity(results);
  await Promise.all(LANES.map(async (L, i) => {
    try {
      results[i] = { L, events: await activityData(L) };
    } catch (e) {
      results[i] = { L, error: e.message, events: activityProgress[L.name].events };
    }
    renderActivity(results);
  }));
  if (results.every(r => !r.error)) activityRenderedAt = Date.now();
  renderActivity(results);
}
