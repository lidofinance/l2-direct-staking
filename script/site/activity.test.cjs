const assert = require('node:assert/strict');
const { test } = require('node:test');

// The site modules expect a browser. Pacing and retry back-off wait on timers; fire them at once.
const records = new Map();
globalThis.localStorage = { getItem: key => records.get(key) ?? null, setItem: (key, value) => records.set(key, value) };
globalThis.document = { querySelectorAll() { return []; } };
globalThis.setTimeout = resolve => { queueMicrotask(resolve); return 0; };

const PROGRESS_KEY = 'direct-staking-watch.activity-progress.v1';
const SLOW_STAKE_TOPIC = '0xb9a1909fb1e8f533ab60d262ba908dc82a1d8dfaef2e6c4e4b2da76de8a1ca4d';
const TRANSFER_TOPIC = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const hex = n => '0x' + n.toString(16);
const word = value => '0x' + BigInt(value).toString(16).padStart(64, '0');
const txHash = n => '0x' + n.toString(16).padStart(64, '0');
const event = (block, n) => ({ block, tx: txHash(n), ts: block, cp: '0x' + '1'.repeat(40),
  kind: 'stake', label: 'Slow stake', amount: '1 WETH' });
const OLD = 0xa0, REMOVED = 0xa1;

// A JSON-RPC endpoint: `answer(method, params, url)` returns a result or throws a per-call error.
const jsonRpc = answer => async (url, init) => {
  const body = JSON.parse(init.body);
  const reply = async ({ id, method, params }) => {
    try { return { jsonrpc: '2.0', id, result: await answer(method, params, String(url)) }; }
    catch (e) { return { jsonrpc: '2.0', id, error: { message: e.message } }; }
  };
  const out = Array.isArray(body) ? await Promise.all(body.map(reply)) : await reply(body);
  return { ok: true, status: 200, json: async () => out };
};

let site, loads = 0;
async function modules() {
  site ??= {
    ...await import('../../site/static/config.js'),
    ...await import('../../site/static/rpc.js'),
    ...await import('../../site/static/activity-snapshot.js'),
  };
  return site;
}
// A fresh activity module per test, starting from `saved` progress (or the bundled snapshot).
async function load(saved) {
  records.clear();
  if (saved) records.set(PROGRESS_KEY, JSON.stringify(saved));
  return import(`../../site/static/activity.js?test=${++loads}`);
}
// Saved progress ahead of the bundled snapshot, holding one event behind the reorg window and one inside it.
async function progress() {
  const { LANES, ACTIVITY_SNAPSHOT } = await modules();
  return Object.fromEntries(LANES.map(L => {
    const block = ACTIVITY_SNAPSHOT[L.name].block + 10000;
    return [L.name, { chainId: L.chainId, block, events: [event(block - 3000, OLD), event(block - 100, REMOVED)] }];
  }));
}
const slowStakeLog = (L, block, n) => ({ address: L.sender, blockNumber: hex(block), transactionHash: txHash(n),
  logIndex: '0x0', topics: [SLOW_STAKE_TOPIC, word(0x123), word(0), word(L.weth)], data: word(1) + word(10n ** 15n).slice(2) });

test('all lanes resume at the checkpoint overlap and replace reorged events', async () => {
  const { LANES } = await modules();
  const saved = await progress();
  const { activityData, activityProgress } = await load(saved);
  for (const L of LANES) {
    const from = saved[L.name].block - 1799, head = saved[L.name].block + 100;
    const ranges = [];
    globalThis.fetch = jsonRpc((method, [p]) => {
      if (method === 'eth_blockNumber') return hex(head);
      if (method === 'eth_getBlockByNumber') return { timestamp: p };
      ranges.push([Number(p.fromBlock), Number(p.toBlock)]);
      return p.topics[0] === SLOW_STAKE_TOPIC ? [slowStakeLog(L, head - 99, 1), slowStakeLog(L, head - 99, 2)] : [];
    });
    const events = await activityData(L);
    assert.deepEqual(events.map(e => e.tx), [txHash(1), txHash(2), txHash(OLD)]);
    assert.equal(Math.min(...ranges.map(r => r[0])), from);
    assert.equal(Math.max(...ranges.map(r => r[1])), head);
    assert.equal(activityProgress[L.name].block, head);
  }
  assert.equal(JSON.parse(records.get(PROGRESS_KEY)).Linea.block, saved.Linea.block + 100);
});

test('a failed source leaves events and cursor untouched and retry reads the same range', async () => {
  const { LANES } = await modules();
  const saved = await progress();
  const { activityData, activityProgress } = await load(saved);
  const L = LANES[0], block = saved[L.name].block;
  let slowStake = () => { throw new Error('upstream unavailable'); };
  globalThis.fetch = jsonRpc((method, [p]) => {
    if (method === 'eth_blockNumber') return hex(block + 100);
    return p.topics[0] === SLOW_STAKE_TOPIC ? slowStake(p) : [];
  });
  await assert.rejects(activityData(L), /SlowStake: eth_getLogs \(RPC error\): upstream unavailable/);
  assert.equal(activityProgress[L.name].block, block);
  assert.equal(records.get(PROGRESS_KEY), JSON.stringify(saved));
  slowStake = p => { if (Number(p.fromBlock) !== block - 1799) throw new Error('skipped range'); return []; };
  await activityData(L);
  assert.equal(activityProgress[L.name].block, block + 100);
});

test('older and invalid saved checkpoints fall back to the embedded snapshot', async () => {
  const { LANES, ACTIVITY_SNAPSHOT: seed } = await modules();
  const { activityProgress } = await load({
    Optimism: { chainId: 10, block: seed.Optimism.block - 1000, events: [] },
    Base: { chainId: 8453, block: seed.Base.block + 1000 },
    Arbitrum: { chainId: 10, block: seed.Arbitrum.block + 1000, events: [] },
    Linea: { chainId: 59144, block: seed.Linea.block + 1000, events: [] } });
  assert.deepEqual(LANES.map(L => activityProgress[L.name].block),
    [seed.Optimism.block, seed.Arbitrum.block, seed.Base.block, seed.Linea.block + 1000]);
});

test('a saved checkpoint with a malformed event falls back to the embedded snapshot', async () => {
  const { ACTIVITY_SNAPSHOT: seed } = await modules();
  const saved = await progress();
  saved.Optimism.events.push({ block: 1, ts: 1, tx: txHash(1) });
  const { activityProgress } = await load(saved);
  assert.equal(activityProgress.Optimism.block, seed.Optimism.block);
  assert.equal(activityProgress.Arbitrum.block, saved.Arbitrum.block);
});

test('a lagging RPC cannot rewind the checkpoint', async () => {
  const { LANES } = await modules();
  const saved = await progress();
  const { activityData, activityProgress } = await load(saved);
  const block = saved.Optimism.block;
  globalThis.fetch = jsonRpc(() => hex(block - 1));
  await assert.rejects(activityData(LANES[0]), /behind/);
  assert.equal(activityProgress.Optimism.block, block);
});

test('RPC log requests cover the full range in chunks of at most 2000 blocks', async () => {
  const { LANES, rpcHistoryLogs } = await modules();
  const requests = [];
  globalThis.fetch = jsonRpc((method, [p]) => { requests.push(p); return []; });
  await rpcHistoryLogs({ ...LANES[0], logsRpc: 'https://logs.example' }, '0x123', [], 8201, 13000);
  assert.deepEqual(requests.map(p => [Number(p.fromBlock), Number(p.toBlock)]),
    [[8201, 10200], [10201, 12200], [12201, 13000]]);
});

test('missing timestamps fail without advancing progress', async () => {
  const { LANES } = await modules();
  const saved = await progress();
  const { activityData, activityProgress } = await load(saved);
  const L = LANES[0], block = saved[L.name].block;
  const poolTopic = word(L.pool);
  globalThis.fetch = jsonRpc((method, [p]) => {
    if (method === 'eth_blockNumber') return hex(block + 100);
    if (method === 'eth_getBlockByNumber') return null;
    return p.topics[2] === poolTopic ? [{ address: L.weth, blockNumber: hex(block + 1), transactionHash: txHash(3),
      logIndex: '0x0', topics: [TRANSFER_TOPIC, word(0x1), poolTopic], data: word(1) }] : [];
  });
  await assert.rejects(activityData(L), /timestamp unavailable/);
  assert.equal(activityProgress[L.name].block, block);
});

test('RPC log errors retain the provider message while contract reverts remain nullable', async () => {
  const { rpcBatch } = await modules();
  globalThis.fetch = jsonRpc(() => { throw new Error('eth_getLogs is limited to a 2,000 range'); });
  await assert.rejects(rpcBatch('https://example.com', [{ method: 'eth_getLogs', params: [] }]), /2,000/);
  assert.deepEqual(await rpcBatch('https://example.com', [{ method: 'eth_call', params: [] }]), [null]);
});

test('the bundled snapshot has valid, ordered events for every lane', async () => {
  const { ACTIVITY_SNAPSHOT: snapshots } = await modules();
  for (const [name, chainId] of [['Optimism', 10], ['Arbitrum', 42161], ['Base', 8453], ['Linea', 59144]]) {
    const item = snapshots[name];
    assert.equal(item.chainId, chainId);
    assert.ok(Number.isSafeInteger(item.block) && item.block > 0);
    assert.ok(item.events.length > 0 && item.events.length <= 50);
    let previous = item.block;
    for (const e of item.events) {
      assert.ok(Number.isSafeInteger(e.block) && e.block > 0 && e.block <= previous);
      assert.ok(Number.isSafeInteger(e.ts) && e.ts > 0);
      assert.match(e.tx, /^0x[0-9a-f]{64}$/i);
      assert.match(e.cp, /^0x[0-9a-f]{40}$/i);
      previous = e.block;
    }
  }
});

test('activity uses the chain RPC by default and respects custom endpoints', async () => {
  const { LANES } = await modules();
  const saved = await progress();
  const { activityData } = await load(saved);
  const urls = [];
  globalThis.fetch = jsonRpc((method, params, url) => {
    if (method !== 'eth_blockNumber') return [];
    urls.push(url);
    return hex(saved.Optimism.block + 100);
  });
  await activityData(LANES[0]);
  await activityData({ ...LANES[0], rpc: 'https://custom.example' });
  assert.deepEqual(urls, ['https://mainnet.optimism.io', 'https://custom.example']);
});

test('JSON-RPC rate limits retry before reporting failure', async () => {
  const { rpcBatch } = await modules();
  for (const message of ['over rate limit', 'Your IP has exceeded its requests per second capacity.']) {
    let attempts = 0;
    globalThis.fetch = jsonRpc(() => { if (++attempts < 3) throw new Error(message); return []; });
    const result = await rpcBatch('https://example.com', [{ method: 'eth_getLogs', params: [] }]);
    assert.equal(attempts, 3);
    assert.deepEqual(result, [[]]);
  }
});

test('pool transfers with a malformed transaction hash are dropped', async () => {
  const { LANES } = await modules();
  const saved = await progress();
  const { activityData } = await load(saved);
  const L = LANES[0], block = saved[L.name].block;
  const poolTopic = word(L.pool);
  globalThis.fetch = jsonRpc((method, [p]) => {
    if (method === 'eth_blockNumber') return hex(block + 100);
    if (method === 'eth_getBlockByNumber') return { timestamp: p };
    return p.topics[2] === poolTopic ? [{ address: L.weth, blockNumber: hex(block + 1), transactionHash: '"><img src=x>',
      logIndex: '0x0', topics: [TRANSFER_TOPIC, word(0x1), poolTopic], data: word(1) }] : [];
  });
  assert.deepEqual((await activityData(L)).map(e => e.tx), [txHash(OLD)]);
});

test('Activity opens on the latest 20 rows and Show all reveals the rest', async () => {
  const { LANES } = await modules();
  const { renderActivity, showAllActivity } = await load();
  const panel = { innerHTML: '' };
  globalThis.document.getElementById = id => id === 'activity' ? panel : null;
  const rows = () => (panel.innerHTML.match(/<tr[ >]/g) ?? []).length - 1; // minus the header row
  renderActivity([{ L: LANES[0], events: Array.from({ length: 30 }, (_, i) => event(1000 + i, i + 1)) }]);
  assert.equal(rows(), 20);
  assert.match(panel.innerHTML, /Show all 30/);
  showAllActivity();
  assert.equal(rows(), 30);
  assert.doesNotMatch(panel.innerHTML, /Show all/);
});
