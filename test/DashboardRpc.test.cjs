const assert = require('node:assert/strict');
const { test } = require('node:test');

let loads = 0;
const base = { name: 'Base', chainId: 8453, logsRpc: 'https://mainnet.base.org' };
const address = '0x09BdB4E8BA68d245DCb1c6fbEb1e4f13b57cc69A';
const firstBlock = 48000000;

async function dashboard(reply) {
  const storage = new Map();
  const elements = new Map();
  globalThis.localStorage = {
    getItem: key => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, value),
  };
  globalThis.document = {
    querySelectorAll() { return []; },
    getElementById(id) {
      if (!elements.has(id)) elements.set(id, { innerHTML: '' });
      return elements.get(id);
    },
  };
  // Exercise the actual modules with fresh RPC caches and no browser polling.
  globalThis.setTimeout = resolve => { queueMicrotask(resolve); return 0; };
  const context = await import(`../site/static/rpc.js?test=${++loads}`);
  const batches = [];
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    batches.push(body);
    return { ok: true, status: 200, json: async () => reply(body) };
  };
  return { context, storage, elements, batches };
}

const emptyLogs = calls => calls.map(c => ({ id: c.id, result: [] }));
const history = (d, last) => d.context.rpcHistoryLogs(base, address, [], firstBlock, last);

test('history queries cover every requested block within the Base range limit', async () => {
  const d = await dashboard(calls => calls.map(c => {
    const { fromBlock, toBlock } = c.params[0];
    assert.ok(Number(BigInt(toBlock) - BigInt(fromBlock)) < 2000);
    return { id: c.id, result: [{ blockNumber: fromBlock }, { blockNumber: toBlock }] };
  }).reverse()); // JSON-RPC batch responses need not be in request order.
  const lastBlock = firstBlock + 8004;
  const logs = await history(d, lastBlock);
  const ranges = d.batches.flat().map(c => c.params[0]);
  let next = firstBlock;
  for (const range of ranges) {
    assert.equal(Number(BigInt(range.fromBlock)), next);
    next = Number(BigInt(range.toBlock)) + 1;
  }
  assert.equal(next, lastBlock + 1);
  assert.equal(Number(BigInt(logs[0].blockNumber)), firstBlock);
  assert.equal(Number(BigInt(logs.at(-1).blockNumber)), lastBlock);
  assert.equal(logs.length, ranges.length * 2);
});

test('stable empty ranges are cached; the reorg window is fetched again', async () => {
  const d = await dashboard(emptyLogs);
  const lastBlock = firstBlock + 6004;
  await history(d, lastBlock);
  const firstRequests = d.batches.flat();
  const stable = firstRequests.filter(c => Number(BigInt(c.params[0].toBlock)) <= lastBlock - 1800);
  assert.ok(stable.length > 0);
  assert.equal(d.storage.size, stable.length);
  d.batches.length = 0;
  // Exercise the persistent cache, not just the in-memory copy.
  d.context = await import(`../site/static/rpc.js?test=${++loads}`);
  await history(d, lastBlock);
  const repeated = d.batches.flat();
  assert.equal(repeated.length, firstRequests.length - stable.length);
  assert.ok(repeated.every(c => Number(BigInt(c.params[0].toBlock)) > lastBlock - 1800));
});

test('a rejected log query preserves the provider code and reason without caching a false empty result', async () => {
  const d = await dashboard(calls => calls.map((c, i) => i === 1
    ? { id: c.id, error: { code: -32614, message: 'eth_getLogs is limited to a 2,000 range' } }
    : { id: c.id, result: [] }));
  await assert.rejects(history(d, firstBlock + 8004),
    /eth_getLogs \(-32614\): eth_getLogs is limited to a 2,000 range/);
  assert.equal(d.storage.size, 0);
});

test('contract-call reverts still return null beside successful state reads', async () => {
  const d = await dashboard(calls => [
    { id: calls[1].id, result: '0x01' },
    { id: calls[0].id, error: { code: 3, message: 'execution reverted' } },
  ]);
  const results = await d.context.rpcBatch(base.logsRpc, [
    { method: 'eth_call', params: [] }, { method: 'eth_call', params: [] },
  ]);
  assert.deepEqual(Array.from(results), [null, '0x01']);
});

test('missing log responses remain failures, while valid empty logs succeed', async () => {
  const missing = await dashboard(() => []);
  await assert.rejects(history(missing, firstBlock + 10), /invalid logs response/);
  const empty = await dashboard(emptyLogs);
  assert.equal((await history(empty, firstBlock + 10)).length, 0);
});

test('a failed Base history refresh retains the last successful events and reports the cause', async () => {
  const d = await dashboard(calls => calls.map(c => ({
    id: c.id, error: { code: -32602, message: 'Archive access denied' },
  })));
  const { automation, refreshAutomationLogs } = await import('../site/static/automation.js');
  automation.logs.Base = [{ tx: 'cached-event' }];
  // Automation now reads explorer logs; a source failure must still preserve cached events.
  globalThis.fetch = async url => {
    if (String(url).includes('base.blockscout.com')) throw new Error('Archive access denied');
    return { ok: true, status: 200, json: async () => ({ items: [] }) };
  };
  await refreshAutomationLogs();
  assert.equal(automation.logs.Base[0].tx, 'cached-event');
  assert.match(automation.logErrors[0], /Base.*Archive access denied/);
});

test('provider messages render as text in activity and automation error banners', async () => {
  const d = await dashboard(emptyLogs);
  const error = '<img src=x onerror=alert(1)> & rejected';
  const { renderActivity } = await import('../site/static/activity.js');
  renderActivity([{ L: base, error, events: [] }]);
  const activity = d.elements.get('activity').innerHTML;
  assert.ok(activity.includes('&lt;img src=x onerror=alert(1)&gt; &amp; rejected'));
  assert.ok(!activity.includes(error));
  const { LANES } = await import('../site/static/config.js');
  const { automation: state, refreshAutomationLogs } = await import('../site/static/automation.js');
  state.logs = {};
  state.lanes = LANES.map(L => ({ L, error: 'unread' }));
  globalThis.fetch = async url => {
    if (String(url).includes('base.blockscout.com')) throw new Error(error);
    return { ok: true, status: 200, json: async () => ({ items: [] }) };
  };
  await refreshAutomationLogs();
  const automation = d.elements.get('automation-cards').innerHTML;
  assert.equal(automation.split('&lt;img src=x onerror=alert(1)&gt; &amp; rejected').length - 1, 2);
  assert.ok(!automation.includes(error));
});
