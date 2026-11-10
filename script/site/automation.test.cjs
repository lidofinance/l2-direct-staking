const assert = require('node:assert/strict');
const { test } = require('node:test');

globalThis.localStorage = { getItem() { return null; }, setItem() {} };
globalThis.document = { querySelectorAll() { return []; } };
globalThis.setTimeout = resolve => { queueMicrotask(resolve); return 0; };

const event = ts => ({ ts, block: ts ?? 1 });

test('recent events keep the latest ten rows across all lanes', async () => {
  const { LANES } = await import('../../site/static/config.js');
  const { recentAutomationEvents } = await import('../../site/static/automation.js');
  const logs = {
    Optimism: [94, 100, 96, 92, 98, 90].map(event),
    Arbitrum: [91, 99, 93, 97, 95, 89].map(event),
    Base: [event(10), event(9), event(8)],
    Linea: [event(5), event(null)],
  };

  const rows = recentAutomationEvents(logs);
  assert.deepEqual(Object.fromEntries(LANES.map(L =>
    [L.name, rows.filter(row => row.L === L).length])), {
    Optimism: 5, Arbitrum: 5, Base: 0, Linea: 0,
  });
  assert.deepEqual(rows.map(row => row.ts), [100, 99, 98, 97, 96, 95, 94, 93, 92, 91]);
});

test('recent events tolerate missing and short lane histories', async () => {
  const { recentAutomationEvents } = await import('../../site/static/automation.js');
  const rows = recentAutomationEvents({ Base: [event(null), event(2)], Linea: [event(3)] });

  assert.deepEqual(rows.map(row => row.ts), [3, 2, null]);
  assert.deepEqual(rows.map(row => row.L.name), ['Linea', 'Base', 'Base']);
});

test('Arbitrum and Linea automation history uses their log RPCs', async () => {
  const { LANES } = await import('../../site/static/config.js');
  const { automationLogs } = await import('../../site/static/automation.js');
  const urls = [];
  const ownerTopic = '0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0';
  const log = {
    topics: [ownerTopic, '0x' + '0'.repeat(64), '0x' + '1'.repeat(64)], data: '0x',
    blockNumber: '0x1', blockTimestamp: '0x2', transactionHash: '0x' + '2'.repeat(64),
  };
  globalThis.fetch = async (url, init) => {
    urls.push(String(url));
    if (!init?.body) return { ok: true, status: 200, json: async () => ({ items: [] }) };
    const body = JSON.parse(init.body);
    const reply = call => ({ jsonrpc: '2.0', id: call.id,
      result: call.method === 'eth_blockNumber'
        ? (String(url).includes('arbitrum') ? '0x1f000000' : '0x1f00000') : [log] });
    return { ok: true, status: 200,
      json: async () => Array.isArray(body) ? body.map(reply) : reply(body) };
  };

  const lanes = LANES.filter(L => L.name === 'Arbitrum' || L.name === 'Linea');
  const rows = await Promise.all(lanes.map(automationLogs));

  assert.deepEqual(rows.map(laneRows => laneRows.length), [1, 1]);
  assert.ok(urls.some(url => url.startsWith('https://arb1.arbitrum.io/rpc')));
  assert.ok(urls.some(url => url.startsWith('https://linea.gateway.tenderly.co')));
  assert.ok(!urls.some(url => url.includes('arbitrum.blockscout.com') || url.includes('api-explorer.linea.build')));
});

test('Base merges its explorer history with a recent RPC tail', async () => {
  const { LANES } = await import('../../site/static/config.js');
  const { automationLogs } = await import('../../site/static/automation.js');
  const L = LANES.find(lane => lane.name === 'Base');
  const urls = [];
  const ownerTopic = '0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0';
  const execTopic = '0xbe82131bb3404498c769b0511da41a4ad409fa7152562c2b6669241cbe3bb884';
  const oldTx = '0x' + '3'.repeat(64), recentTx = '0x' + '4'.repeat(64);
  const oldLog = { topics: [ownerTopic, '0x' + '0'.repeat(64), '0x' + '1'.repeat(64)], data: '0x',
    block_number: 1, block_timestamp: '2026-11-01T00:00:00Z', transaction_hash: oldTx };
  const recentLog = { topics: [execTopic, '0x' + '0'.repeat(64),
    '0x340b2b0b' + '0'.repeat(56)], data: '0x' + '0'.repeat(128), blockNumber: '0xf0000',
    blockTimestamp: '0x6af25782', transactionHash: recentTx };
  globalThis.fetch = async (url, init) => {
    urls.push(String(url));
    if (!init?.body) return { ok: true, status: 200, json: async () => ({ items: [oldLog] }) };
    const body = JSON.parse(init.body);
    const reply = call => ({ jsonrpc: '2.0', id: call.id,
      result: call.method === 'eth_blockNumber' ? '0xf4240'
        : call.method === 'eth_getTransactionReceipt' ? { logs: [] } : [recentLog] });
    return { ok: true, status: 200,
      json: async () => Array.isArray(body) ? body.map(reply) : reply(body) };
  };

  const rows = await automationLogs(L);

  assert.deepEqual(rows.map(row => row.tx), [recentTx, oldTx]);
  assert.ok(urls.some(url => url.startsWith('https://base-rpc.publicnode.com')));
  assert.ok(urls.some(url => url.startsWith('https://base.blockscout.com')));
});

test('Base retains cached events outside the RPC tail and replaces events inside it', async t => {
  const { LANES } = await import('../../site/static/config.js');
  const { automation, automationLogs } = await import('../../site/static/automation.js');
  const L = LANES.find(lane => lane.name === 'Base');
  const topic = '0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0';
  const retained = { topic, topics: [topic], data: '0x', block: 1600000, ts: 1,
    tx: '0x' + '5'.repeat(64) };
  const removed = { ...retained, block: 1900000, ts: 2, tx: '0x' + '6'.repeat(64) };
  automation.logs.Base = [removed, retained];
  t.after(() => { delete automation.logs.Base; });
  globalThis.fetch = async (url, init) => {
    if (!init?.body) return { ok: true, status: 200, json: async () => ({ items: [{
      topics: removed.topics, data: removed.data, block_number: removed.block,
      block_timestamp: '2026-11-01T00:00:00Z', transaction_hash: removed.tx,
    }] }) };
    const body = JSON.parse(init.body);
    const reply = call => ({ jsonrpc: '2.0', id: call.id,
      result: call.method === 'eth_blockNumber' ? '0x1e8480' : [] });
    return { ok: true, status: 200,
      json: async () => Array.isArray(body) ? body.map(reply) : reply(body) };
  };

  const rows = await automationLogs(L);

  assert.deepEqual(rows.map(row => row.tx), [retained.tx]);
});

test('automation preserves distinct same-topic logs in one transaction', async () => {
  const { LANES } = await import('../../site/static/config.js');
  const { automationLogs } = await import('../../site/static/automation.js');
  const L = LANES.find(lane => lane.name === 'Arbitrum');
  const topic = '0xb35b8e3487df8622d32523c450283db1844a7a279925f30df21d27bc116189d7';
  const logs = [1, 2].map(index => ({ topics: [topic, '0x' + String(index).repeat(64)],
    data: '0x' + '0'.repeat(63) + '1', blockNumber: '0x1', blockTimestamp: '0x2',
    transactionHash: '0x' + '7'.repeat(64), logIndex: '0x' + index }));
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    const reply = call => ({ jsonrpc: '2.0', id: call.id,
      result: call.method === 'eth_blockNumber' ? '0x1d267dbd' : logs });
    return { ok: true, status: 200,
      json: async () => Array.isArray(body) ? body.map(reply) : reply(body) };
  };

  const rows = await automationLogs(L);

  assert.equal(rows.length, 2);
});
