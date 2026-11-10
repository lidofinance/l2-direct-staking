const assert = require('node:assert/strict');
const { test } = require('node:test');

globalThis.localStorage = { getItem() { return null; }, setItem() {} };
globalThis.document = { querySelectorAll() { return []; }, getElementById() { return null; } };
globalThis.setTimeout = resolve => { queueMicrotask(resolve); return 0; };

test('Arbitrum and Linea sync history uses their log RPCs', async () => {
  const { refreshSyncVolume } = await import('../../site/static/sync-volume.js');
  const urls = [];
  globalThis.fetch = async (url, init) => {
    urls.push(String(url));
    if (!init?.body) return { ok: true, status: 200,
      json: async () => ({ items: [], next_page_params: null }) };
    const body = JSON.parse(init.body);
    const reply = call => ({ jsonrpc: '2.0', id: call.id,
      result: call.method === 'eth_blockNumber' ? '0x40000000' : [] });
    return { ok: true, status: 200,
      json: async () => Array.isArray(body) ? body.map(reply) : reply(body) };
  };

  await refreshSyncVolume();

  assert.ok(urls.some(url => url.startsWith('https://arb1.arbitrum.io/rpc')));
  assert.ok(urls.some(url => url.startsWith('https://linea.gateway.tenderly.co')));
  assert.ok(!urls.some(url => url.includes('arbitrum.blockscout.com') || url.includes('api-explorer.linea.build')));
});

test('sync totals use custom RPCs for the safe block and history', async t => {
  const { LANES, RPC_DEFAULTS } = await import('../../site/static/config.js');
  const { RPC_CONFIRMATIONS } = await import('../../site/static/rpc.js');
  const { refreshSyncVolume } = await import('../../site/static/sync-volume.js');
  const lanes = LANES.filter(L => L.logsRpc);
  lanes.forEach(L => { L.rpc = `https://${L.name.toLowerCase()}.custom.example`; });
  t.after(() => lanes.forEach(L => { L.rpc = RPC_DEFAULTS[L.name]; }));
  const requests = [];
  globalThis.fetch = async (url, init) => {
    if (!init?.body) return { ok: true, status: 200,
      json: async () => ({ items: [], next_page_params: null }) };
    const body = JSON.parse(init.body);
    const reply = call => {
      requests.push({ url: String(url), method: call.method, params: call.params });
      const L = LANES.find(lane => [lane.rpc, lane.logsRpc].includes(String(url)));
      return { jsonrpc: '2.0', id: call.id,
        result: call.method === 'eth_blockNumber'
          ? '0x' + (L.syncCheckpoint.block + RPC_CONFIRMATIONS + 2300).toString(16) : [] };
    };
    return { ok: true, status: 200,
      json: async () => Array.isArray(body) ? body.map(reply) : reply(body) };
  };

  await refreshSyncVolume();

  for (const L of lanes) {
    const head = requests.filter(r => r.method === 'eth_blockNumber' && r.url === L.rpc);
    const logs = requests.filter(r => r.method === 'eth_getLogs' && r.url === L.rpc);
    assert.equal(head.length, 1);
    assert.ok(logs.length > 0);
    assert.equal(Number(logs[0].params[0].fromBlock), L.syncCheckpoint.block + 1);
    assert.equal(Number(logs.at(-1).params[0].toBlock), L.syncCheckpoint.block + 2300);
    assert.ok(logs.every(r => Number(r.params[0].toBlock) - Number(r.params[0].fromBlock) < L.logsBlockRange));
  }
  assert.ok(!requests.some(r => r.url === 'https://arb1.arbitrum.io/rpc' ||
    r.url === 'https://linea.gateway.tenderly.co'));
});
