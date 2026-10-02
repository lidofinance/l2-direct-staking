import { LANES, SYNC_TOPIC } from './config.js';
import { blockscoutAddressLogs, rpcSafeBlock } from './rpc.js';
import { fmtEth } from './ui.js';

// ── Synced to L1 (CustomSender Sync volume) ──────────────────────────────────
const SYNC_PROGRESS_KEY = 'direct-staking-watch.sync-progress';
function readSyncProgress(L) {
  const seed = L.syncCheckpoint;
  try {
    const all = JSON.parse(localStorage.getItem(SYNC_PROGRESS_KEY));
    const saved = all?.[L.name];
    if (Number.isSafeInteger(saved?.block) && saved.block >= seed.block &&
        Number.isSafeInteger(saved?.count) && saved.count >= seed.count &&
        /^\d+$/.test(saved?.wei ?? '') && BigInt(saved.wei) >= BigInt(seed.wei)) return saved;
  } catch {}
  return seed;
}

function saveSyncProgress(L, progress) {
  try {
    const all = JSON.parse(localStorage.getItem(SYNC_PROGRESS_KEY)) || {};
    all[L.name] = progress;
    localStorage.setItem(SYNC_PROGRESS_KEY, JSON.stringify(all));
  } catch {}
}

export const syncAmount = log => (log.topics?.[0] ?? '').toLowerCase() === SYNC_TOPIC &&
  /^0x[0-9a-f]{128}$/i.test(log.data ?? '') ? BigInt('0x' + log.data.slice(66, 130)) : null;

// Cumulative CustomSender.Sync totals were verified through these per-lane checkpoint blocks on
// 2026-08-20. Only the immutable tail after each block is read on load; localStorage advances the
// cursor after every successful refresh.
async function syncLogsRange(L, fromBlock, toBlock) {
  return (await blockscoutAddressLogs(L.bs, L.sender, SYNC_TOPIC, { fromBlock }))
    .filter(log => log.blockNumber <= toBlock);
}

async function syncVolumeData(L) {
  const progress = readSyncProgress(L);
  const toBlock = await rpcSafeBlock(L);
  if (toBlock <= progress.block) return { wei: BigInt(progress.wei), count: progress.count };
  const logs = await syncLogsRange(L, progress.block + 1, toBlock);
  const unique = [...new Map(logs.map(log => [`${log.transactionHash}:${log.logIndex}`, log])).values()];
  const amounts = unique.map(syncAmount).filter(amount => amount != null);
  const next = { block: toBlock,
    wei: (BigInt(progress.wei) + amounts.reduce((sum, amount) => sum + amount, 0n)).toString(),
    count: progress.count + amounts.length };
  saveSyncProgress(L, next);
  return { wei: BigInt(next.wei), count: next.count };
}

function cachedSyncVolume() {
  const progress = LANES.map(readSyncProgress);
  return { readable: progress.length, cached: true,
    wei: progress.reduce((sum, item) => sum + BigInt(item.wei), 0n),
    count: progress.reduce((sum, item) => sum + item.count, 0) };
}

let syncVolume = cachedSyncVolume();
let syncVolumeRefreshing = true;

export function syncVolumeStatus() {
  if (!syncVolume) return { level: 'tinted', loading: true, value: '', sub: 'reading CustomSender history' };
  if (!syncVolume.readable) return { level: 'critical', value: 'unread', sub: 'no lane history readable' };
  const partial = syncVolume.readable < LANES.length;
  return { level: partial ? 'warning' : 'tinted',
    refreshing: syncVolumeRefreshing,
    value: `${partial || syncVolume.cached ? '≥ ' : ''}${fmtEth(syncVolume.wei, 2)} <span class="unit">WETH</span>`,
    sub: `${syncVolume.count} sync${syncVolume.count === 1 ? '' : 's'}` };
}

export const syncVolumeValue = status => status.loading
  ? '<span class="spin" aria-hidden="true"></span><span>Loading</span>'
  : status.value;

function updateSyncVolumeTile() {
  const tile = document.getElementById('sync-volume');
  if (!tile) return;
  const status = syncVolumeStatus();
  tile.classList.toggle('tinted', status.level === 'tinted');
  tile.classList.toggle('warning', status.level === 'warning');
  tile.classList.toggle('critical', status.level === 'critical');
  const value = tile.querySelector('.v');
  value.classList.toggle('loading', !!status.loading);
  value.setAttribute('aria-busy', String(!!status.loading || status.refreshing));
  value.innerHTML = syncVolumeValue(status);
  tile.querySelector('.sync-volume-text').textContent = status.sub;
  tile.querySelector('.sync-volume-sub .spin').hidden = !status.refreshing;
}

export async function refreshSyncVolume() {
  syncVolumeRefreshing = true;
  updateSyncVolumeTile();
  const results = await Promise.all(LANES.map(L => syncVolumeData(L)
    .then(summary => ({ L, summary }))
    .catch(() => { const saved = readSyncProgress(L); return { L, cached: true,
      summary: { wei: BigInt(saved.wei), count: saved.count } }; })));
  const readable = results.filter(r => r.summary);
  syncVolume = { readable: readable.length, cached: results.some(r => r.cached),
    wei: readable.reduce((sum, r) => sum + r.summary.wei, 0n),
    count: readable.reduce((sum, r) => sum + r.summary.count, 0) };
  syncVolumeRefreshing = false;
  updateSyncVolumeTile();
}
