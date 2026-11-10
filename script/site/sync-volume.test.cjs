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
