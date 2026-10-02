import { L1, LANES } from './config.js';

// ── Minimal ABI plumbing ─────────────────────────────────────────────────────
export const SEL = {
  owner: '0x8da5cb5b', getForwarder: '0xa0042526', getExpectedAuthor: '0x3397cf67',
  getOraclePool: '0x37d86246', getLastExecution: '0x7acd7f48', getDelay: '0xcebc9a82',
  getAmounts: '0x3d370b4e', getMaxFees: '0x77c46f80', shouldSyncAmount: '0x755b53a3',
  canSync: '0x269d5486', hasRole: '0x91d14854', balanceOf: '0x70a08231', isCallAllowed: '0x797c8d69',
  isOwnerLinked: '0x0987294c', getWorkflowListByOwner: '0x8c42ffc5', failedMessageHash: '0x34219403',
};
export const pad = a => a.toLowerCase().replace('0x', '').padStart(64, '0');
export const padU = n => BigInt(n).toString(16).padStart(64, '0');

// Minimal reader for the one dynamic return shape this page needs — getWorkflowListByOwner's
// (bytes32,address,uint64,uint8,string,string,string,string,bytes,string)[]. Deliberately not a
// general ABI library: it decodes this layout and returns null on anything it does not recognise,
// which lands on the same "unreadable → crit" path as the one-line decoders above.
export const LAYOUT_WORKFLOW = ['b32', 'addr', 'u', 'u', 'str', 'str', 'str', 'str', 'hex', 'str'];
const utf8 = h => new TextDecoder().decode(Uint8Array.from(h.match(/../g) ?? [], p => parseInt(p, 16)));
export function decodeTupleArray(hex, layout) {
  const b = (hex || '').replace(/^0x/, '');
  if (b.length < 64 || b.length % 64) return null;
  const words = b.length / 64;
  const w = i => b.slice(i * 64, i * 64 + 64);
  const u = i => BigInt('0x' + w(i));
  const jump = (base, slot) => {                 // relative offset at `slot`, resolved against `base`
    const off = Number(u(slot));
    if (off % 32) throw new Error('unaligned');
    const at = base + off / 32;
    if (at < 0 || at >= words) throw new Error('out of range');
    return at;
  };
  try {
    const arr = jump(0, 0);                      // head word 0 → the array
    const n = Number(u(arr));
    const elems = arr + 1;                       // element offsets are relative to just past the length
    if (n < 0 || elems + n > words) return null;
    return Array.from({ length: n }, (_, e) => {
      const t = jump(elems, elems + e);          // start of this tuple
      return layout.map((kind, s) => {
        const slot = t + s;
        if (slot >= words) throw new Error('short');
        if (kind === 'b32') return '0x' + w(slot);
        if (kind === 'addr') return '0x' + w(slot).slice(24);
        if (kind === 'u') return u(slot);
        const d = jump(t, slot);                 // dynamic member: offset relative to the tuple start
        const len = Number(u(d));
        const raw = b.slice((d + 1) * 64, (d + 1) * 64 + len * 2);
        if (raw.length < len * 2) throw new Error('short');
        return kind === 'hex' ? '0x' + raw : utf8(raw);
      });
    });
  } catch { return null; }
}
export const call = (to, data) => ({ method: 'eth_call', params: [{ to, data }, 'latest'] });
export const bal = a => ({ method: 'eth_getBalance', params: [a, 'latest'] });
export const decAddr = h => /^0x[0-9a-f]{64}$/i.test(h ?? '') ? '0x' + h.slice(-40) : null;
export const decBool = h => h ? BigInt(h) !== 0n : null;
export const decU = h => h ? BigInt(h) : null;

const rpcQueues = new Map();
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
export async function rpcFetch(url, init) {
  url = String(url);
  const origin = new URL(url).origin;
  // Explorers and the chains' own public RPCs rate-limit per IP; custom endpoints run unpaced.
  const paced = [L1, ...LANES].some(L => [L.bs, L.receiptsRpc, L.activityRpc]
    .some(u => u && new URL(u).origin === origin)) || origin === 'https://base.gateway.tenderly.co';
  const request = async () => {
    let res;
    for (let attempt = 0; attempt < 3; attempt++) {
      res = await fetch(url, init);
      if (res.status !== 429) {
        if (paced) await wait(1000);
        return res;
      }
      await wait(500 * 2 ** attempt);
    }
    return res;
  };
  if (!paced) return request();
  const queued = (rpcQueues.get(origin) ?? Promise.resolve()).then(request, request);
  rpcQueues.set(origin, queued.then(() => undefined, () => undefined));
  return queued;
}

// Chunked so a batch-limited endpoint still works: free tiers commonly cap a batch (mainnet.optimism.io
// at 10) and answer an oversized one with a single error OBJECT instead of the per-call array, which
// used to surface as a bare "out.map is not a function". A lane reads ~20 calls, so this is 2 requests
// against the default endpoints and the ceiling stays below every cap seen in the wild.
const RPC_BATCH_MAX = 10;

async function rpcBatchChunk(url, calls, idBase, attempt = 0) {
  const body = calls.map((c, i) => ({ jsonrpc: '2.0', id: idBase + i, ...c }));
  const res = await rpcFetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const out = await res.json();
  const limited = (Array.isArray(out) ? out : [out]).some(r => /rate limit|too many requests|requests per second/i.test(r?.error?.message ?? ''));
  if (limited && attempt < 2) {
    await wait(1000 * 2 ** attempt);
    return rpcBatchChunk(url, calls, idBase, attempt + 1);
  }
  // A batch request answered with a single object is a whole-batch rejection (rate limit, batch-size
  // cap, auth). Report what it said — never let it fall through as a shape error.
  if (!Array.isArray(out)) throw new Error(out?.error?.message || 'endpoint rejected the batch request');
  const byId = new Map(out.map(r => [r.id, r]));
  return calls.map((call, i) => {
    const response = byId.get(idBase + i);
    if (call.method === 'eth_getLogs' && response?.error)
      throw new Error(`eth_getLogs (${response.error.code ?? 'RPC error'}): ${response.error.message || 'request failed'}`);
    return response?.result ?? null; // per-call revert → null
  });
}

export async function rpcBatch(url, calls) {
  const chunks = [];
  for (let i = 0; i < calls.length; i += RPC_BATCH_MAX) chunks.push(i);
  const parts = await Promise.all(chunks.map(i =>
    rpcBatchChunk(url, calls.slice(i, i + RPC_BATCH_MAX), i)));
  return parts.flat();
}

export async function rpcBatchChunks(url, calls, size = 5) {
  const results = [];
  for (let i = 0; i < calls.length; i += size) results.push(...await rpcBatch(url, calls.slice(i, i + size)));
  return results;
}

export async function rpcRequest(url, method, params) {
  const res = await rpcFetch(url, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const out = await res.json();
  if (out.error || out.result == null) throw new Error(out.error?.message || 'invalid RPC response');
  return out.result;
}

// Persist older blocks; reread the reorg window through the live tip for event views.
export const RPC_CONFIRMATIONS = 1800;
export const rpcBlockNumber = async L => Number(BigInt(await rpcRequest(L.logsRpc ?? L.rpc, 'eth_blockNumber', [])));
// Cumulative totals advance only behind the reorg window.
export async function rpcSafeBlock(L) {
  return Math.max(0, await rpcBlockNumber(L) - RPC_CONFIRMATIONS);
}

const logRangeCache = new Map();

export async function rpcHistoryLogs(L, address, topics, fromBlock, toBlock) {
  const url = L.logsRpc;
  const result = [];
  const ranges = [];
  for (let first = fromBlock; first <= toBlock; first += 2000)
    ranges.push([first, Math.min(first + 1999, toBlock)]);
  for (let i = 0; i < ranges.length; i += 4) {
    const pages = ranges.slice(i, i + 4).map(([first, last]) => {
      const key = 'dsw.logs.v1:' + JSON.stringify([L.chainId, url, address, topics, first, last]);
      // Cache only ranges behind the reorg window; read the live tail every time.
      const stable = last <= toBlock - RPC_CONFIRMATIONS;
      let logs;
      if (stable) {
        logs = logRangeCache.get(key);
        if (!logs) try {
          const saved = JSON.parse(localStorage.getItem(key));
          if (Array.isArray(saved)) { logs = saved; logRangeCache.set(key, saved); }
        } catch {}
      }
      return { first, last, key, stable, logs };
    });
    const missing = pages.filter(page => !page.logs);
    const fetched = await rpcBatch(url, missing.map(page => ({ method: 'eth_getLogs', params: [{
      fromBlock: '0x' + page.first.toString(16), toBlock: '0x' + page.last.toString(16), address, topics,
    }] })));
    missing.forEach((page, j) => {
      if (!Array.isArray(fetched[j])) throw new Error('invalid logs response');
      page.logs = fetched[j];
      if (page.stable) {
        logRangeCache.set(page.key, page.logs);
        try { localStorage.setItem(page.key, JSON.stringify(page.logs)); } catch {}
      }
    });
    result.push(...pages.flatMap(page => page.logs));
  }
  return result;
}

export async function blockscoutAddressLogs(base, address, topic, { since = null, fromBlock = 0 } = {}) {
  const rows = [];
  const normalizedTopic = topic.toLowerCase();
  let nextPage = {};
  for (let pageNumber = 0; nextPage && pageNumber < 100; pageNumber++) {
    const url = new URL(`${base}/api/v2/addresses/${address}/logs`);
    url.searchParams.set('topic', topic);
    Object.entries(nextPage).forEach(([key, value]) => url.searchParams.set(key, value));
    const res = await rpcFetch(url.toString());
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const page = await res.json();
    if (!Array.isArray(page.items)) throw new Error('invalid logs response');
    const logs = page.items
      .filter(item => (item.topics?.[0] ?? '').toLowerCase() === normalizedTopic)
      .map(item => ({
      topics: item.topics, data: item.data,
      blockNumber: item.block_number, logIndex: item.index,
      transactionHash: item.transaction_hash,
      timeStamp: item.block_timestamp ? Math.floor(Date.parse(item.block_timestamp) / 1000) : null,
    }));
    for (const log of logs) {
      if (log.blockNumber < fromBlock) return rows;
      if (since != null) {
        if (!Number.isFinite(log.timeStamp)) throw new Error('receiver event timestamp unavailable');
        if (log.timeStamp < since) return rows;
      }
      rows.push(log);
    }
    nextPage = page.next_page_params;
  }
  if (nextPage) throw new Error('log history exceeds 5,000 rows');
  return rows;
}
