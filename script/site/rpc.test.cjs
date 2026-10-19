const assert = require('node:assert/strict');
const { test } = require('node:test');

test('block timestamps join numeric and mixed-case hex blocks with bounded batches', async () => {
  const { rpcBlockTimestamps } = await import('../../site/static/rpc.js');
  const batches = [];
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    batches.push(body);
    return { ok: true, json: async () => body.map(c => ({ id: c.id,
      result: { timestamp: '0x' + (Number(c.params[0]) + 1000).toString(16) } })).reverse() };
  };
  const timestamps = await rpcBlockTimestamps('https://rpc.example', [10, '0xA', '0xa', 11, 12, 13, 14, 15]);
  assert.deepEqual([...timestamps], [[10, 1010], [11, 1011], [12, 1012], [13, 1013], [14, 1014], [15, 1015]]);
  assert.deepEqual(batches.map(b => b.length), [5, 1]);
});

test('missing or malformed block timestamps fail explicitly', async () => {
  const { rpcBlockTimestamps } = await import('../../site/static/rpc.js');
  for (const result of [null, {}, { timestamp: 'invalid' }, { timestamp: '0x0' }]) {
    globalThis.fetch = async (url, init) => ({ ok: true,
      json: async () => JSON.parse(init.body).map(c => ({ id: c.id, result })) });
    await assert.rejects(rpcBlockTimestamps('https://rpc.example', [10]), /block timestamp unavailable/);
  }
});
