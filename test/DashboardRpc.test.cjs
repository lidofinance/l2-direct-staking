const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const source = readFileSync(path.join(__dirname, '../site/static/app.js'), 'utf8');
// Load the dashboard's functions and state without starting its browser event handlers or polling.
const startup = source.indexOf('const tabButtons = ');
assert.ok(startup > 0);
const base = { name: 'Base', chainId: 8453, logsRpc: 'https://mainnet.base.org' };
const address = '0x09BdB4E8BA68d245DCb1c6fbEb1e4f13b57cc69A';
const firstBlock = 48000000;

function dashboard(reply) {
  const storage = new Map();
  const elements = new Map();
  const context = vm.createContext({
    TextEncoder, TextDecoder, URL,
    setInterval() {},
    setTabStatus() {},
    localStorage: {
      getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value),
    },
    document: { getElementById(id) {
      if (!elements.has(id)) elements.set(id, { innerHTML: '' });
      return elements.get(id);
    } },
  });
  vm.runInContext(source.slice(0, startup) + '\nlet activeTab = "main";', context);
  const batches = [];
  context.rpcFetch = async (url, init) => {
    const body = JSON.parse(init.body);
    batches.push(body);
    return { ok: true, json: async () => reply(body) };
  };
  return { context, storage, elements, batches };
}

const emptyLogs = calls => calls.map(c => ({ id: c.id, result: [] }));
const history = (d, last) => d.context.rpcHistoryLogs(base, address, [], firstBlock, last);

test('history queries cover every requested block within the Base range limit', async () => {
  const d = dashboard(calls => calls.map(c => {
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
  const d = dashboard(emptyLogs);
  const lastBlock = firstBlock + 6004;
  await history(d, lastBlock);
  const firstRequests = d.batches.flat();
  const stable = firstRequests.filter(c => Number(BigInt(c.params[0].toBlock)) <= lastBlock - 1800);
  assert.ok(stable.length > 0);
  assert.equal(d.storage.size, stable.length);
  d.batches.length = 0;
  // Exercise the persistent cache, not just the in-memory copy.
  vm.runInContext('logRangeCache.clear()', d.context);
  await history(d, lastBlock);
  const repeated = d.batches.flat();
  assert.equal(repeated.length, firstRequests.length - stable.length);
  assert.ok(repeated.every(c => Number(BigInt(c.params[0].toBlock)) > lastBlock - 1800));
});

test('a rejected log query preserves the provider code and reason without caching a false empty result', async () => {
  const d = dashboard(calls => calls.map((c, i) => i === 1
    ? { id: c.id, error: { code: -32614, message: 'eth_getLogs is limited to a 2,000 range' } }
    : { id: c.id, result: [] }));
  await assert.rejects(history(d, firstBlock + 8004),
    /eth_getLogs \(-32614\): eth_getLogs is limited to a 2,000 range/);
  assert.equal(d.storage.size, 0);
});

test('contract-call reverts still return null beside successful state reads', async () => {
  const d = dashboard(calls => [
    { id: calls[1].id, result: '0x01' },
    { id: calls[0].id, error: { code: 3, message: 'execution reverted' } },
  ]);
  const results = await d.context.rpcBatch(base.logsRpc, [
    { method: 'eth_call', params: [] }, { method: 'eth_call', params: [] },
  ]);
  assert.deepEqual(Array.from(results), [null, '0x01']);
});

test('missing log responses remain failures, while valid empty logs succeed', async () => {
  const missing = dashboard(() => []);
  await assert.rejects(history(missing, firstBlock + 10), /invalid logs response/);
  const empty = dashboard(emptyLogs);
  assert.equal((await history(empty, firstBlock + 10)).length, 0);
});

test('a failed Base history refresh retains the last successful events and reports the cause', async () => {
  const d = dashboard(calls => calls.map(c => ({
    id: c.id, error: { code: -32602, message: 'Archive access denied' },
  })));
  vm.runInContext('automation.logs.Base = [{ tx: "cached-event" }]', d.context);
  d.context.automationLogs = async L => L.name === 'Base' ? history(d, firstBlock + 10) : [];
  await d.context.refreshAutomationLogs();
  assert.equal(vm.runInContext('automation.logs.Base[0].tx', d.context), 'cached-event');
  assert.match(vm.runInContext('automation.logErrors[0]', d.context), /Base.*-32602.*Archive access denied/);
});

test('provider messages render as text in activity and automation error banners', () => {
  const d = dashboard(emptyLogs);
  const error = '<img src=x onerror=alert(1)> & rejected';
  d.context.renderActivity([{ L: base, error }]);
  const activity = d.elements.get('activity').innerHTML;
  assert.ok(activity.includes('&lt;img src=x onerror=alert(1)&gt; &amp; rejected'));
  assert.ok(!activity.includes(error));
  d.context.providerError = error;
  vm.runInContext(`
    automation.lanes = LANES.map(L => ({ L, error: 'unread' }));
    automation.logErrors = [providerError];
    renderAutomation();
  `, d.context);
  const automation = d.elements.get('automation-cards').innerHTML;
  assert.equal(automation.split('&lt;img src=x onerror=alert(1)&gt; &amp; rejected').length - 1, 2);
  assert.ok(!automation.includes(error));
});
