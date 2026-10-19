const assert = require('node:assert/strict');
const { test } = require('node:test');

const records = new Map();
globalThis.localStorage = { getItem: key => records.get(key) ?? null, setItem: (key, value) => records.set(key, value) };
globalThis.document = { querySelectorAll() { return []; } };
globalThis.setTimeout = resolve => { queueMicrotask(resolve); return 0; };

const FAILED = '0xef8a84d7e9c9d42c79a42cba16e93688c646989f43846843e163672cc887e253';
const RETRIED = '0xef3bf8c64bc480286c4f3503b870ceb23e648d2d902e31fb7bb46680da6de8ad';
const RECOVERED = '0x6e2f4b2b871174c4882a9b21bf5a2f421274d3dba05cc997af4528bdc393c027';
const hex = n => '0x' + n.toString(16);
const word = n => BigInt(n).toString(16).padStart(64, '0');
const hash = n => '0x' + word(n);
const timestamp = Date.parse('2026-10-19T00:00:00Z') / 1000;
// ABI encoding of MessageFailed(bytes32, Any2EVMMessage), with empty sender/data/tokens.
const failed = (block, id = 1) => ({ blockNumber: hex(block), logIndex: '0x0',
  transactionHash: hash(id + 100), topics: [FAILED, hash(id)],
  data: '0x' + [32, id, 3734403246176062136n, 160, 192, 224, 0, 0, 0].map(word).join('') });
const lifecycle = (topic, block, id = 1, index = 0) => ({ blockNumber: hex(block), logIndex: hex(index),
  transactionHash: hash(id + 200), topics: [topic, hash(id)], data: '0x' });

function mockSources({ head = 10000, logs = [], state = hash(1), answer } = {}) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    assert.ok(init?.body, 'receiver history must not use the explorer');
    const body = JSON.parse(init.body);
    const reply = c => {
      calls.push(c);
      try {
        let result;
        const [p] = c.params;
        if (answer) result = answer(c.method, c.params);
        if (result === undefined) {
          if (c.method === 'eth_blockNumber') result = hex(head);
          else if (c.method === 'eth_getBlockByNumber') result = { timestamp: hex(timestamp) };
          else if (c.method === 'eth_call') result = state;
          else if (c.method === 'eth_getLogs') result = logs.filter(l => Number(l.blockNumber) >= Number(p.fromBlock) && Number(l.blockNumber) <= Number(p.toBlock));
          else throw new Error('unexpected method ' + c.method);
        }
        return { jsonrpc: '2.0', id: c.id, result };
      } catch (e) { return { jsonrpc: '2.0', id: c.id, error: { message: e.message } }; }
    };
    return response(Array.isArray(body) ? body.map(reply) : reply(body));
  };
  return calls;
}
const response = data => ({ ok: true, status: 200, json: async () => data });

const PROGRESS_KEY = 'direct-staking-watch.receiver-progress.v1';
async function checkpoint(logs = []) {
  const { RECEIVER_SNAPSHOT: seed } = await import('../../site/static/receiver-snapshot.js');
  const saved = { ...seed, block: seed.block + 10000, logs: logs.map(l => ({ ...l,
    blockNumber: Number(l.blockNumber), logIndex: Number(l.logIndex), timeStamp: timestamp })) };
  records.clear();
  records.set(PROGRESS_KEY, JSON.stringify(saved));
  return saved;
}

// Exercise the real data path with a provider whose backend is one block behind its head oracle.
test('receiver logs and state use the same block behind the observed RPC head', async () => {
  const { failedMessageData } = await import('../../site/static/shuttles.js');
  const saved = await checkpoint(), head = saved.block + 100;
  const calls = mockSources({ head, logs: [failed(head - 5)], answer(method, params) {
    if (method === 'eth_getLogs' && Number(params[0].toBlock) > head - 1 ||
        method === 'eth_call' && Number(params[1]) > head - 1) throw new Error('header not found');
  } });
  const messages = await failedMessageData();
  assert.equal(messages[0].state, 'active');
  const end = Math.max(...calls.filter(c => c.method === 'eth_getLogs').map(c => Number(c.params[0].toBlock)));
  assert.ok(end < head);
  assert.equal(Number(calls.find(c => c.method === 'eth_call').params[1]), end);
});

test('RPC covers the entire checkpoint overlap including failures below an explorer frontier', async () => {
  const { failedMessageData } = await import('../../site/static/shuttles.js');
  const saved = await checkpoint(), head = saved.block + 5000;
  // This event would be missed by an explorer with an interior gap and an indexed head at head.
  const missed = failed(saved.block + 1);
  const calls = mockSources({ head, logs: [missed] });
  const messages = await failedMessageData();
  assert.equal(messages[0].messageId, hash(1));
  const ranges = calls.filter(c => c.method === 'eth_getLogs').map(c => c.params[0]);
  assert.equal(Number(ranges[0].fromBlock), saved.block - 1799);
  assert.equal(Number(ranges.at(-1).toBlock), head - 2);
  ranges.forEach((r, i) => {
    assert.ok(Number(r.toBlock) - Number(r.fromBlock) < 2000);
    if (i) assert.equal(Number(r.fromBlock), Number(ranges[i - 1].toBlock) + 1);
    assert.deepEqual(r.topics, [[FAILED, RETRIED, RECOVERED]]);
  });
});

test('reorg refresh replaces the overlap while retaining older failures', async () => {
  const { failedMessageData } = await import('../../site/static/shuttles.js');
  let saved = await checkpoint();
  saved = await checkpoint([failed(saved.block - 3000, 1), failed(saved.block - 10, 2),
    lifecycle(RETRIED, saved.block - 5, 1)]);
  mockSources({ head: saved.block + 100, logs: [failed(saved.block - 9, 3)] });
  const messages = await failedMessageData();
  assert.deepEqual(messages.map(m => m.messageId), [hash(1), hash(3)]);
  assert.ok(messages.every(m => m.lifecycle === null));
  const persisted = JSON.parse(records.get(PROGRESS_KEY));
  assert.equal(persisted.block, saved.block + 98);
  assert.equal(persisted.logs.length, 2);
});

test('failed state reads preserve the checkpoint and retry the same history', async () => {
  const { failedMessageData } = await import('../../site/static/shuttles.js');
  const saved = await checkpoint(), head = saved.block + 100;
  const before = records.get(PROGRESS_KEY);
  mockSources({ head, logs: [failed(head - 5)], state: null });
  await assert.rejects(failedMessageData(), /state unreadable/);
  assert.equal(records.get(PROGRESS_KEY), before);
  const calls = mockSources({ head, logs: [failed(head - 5)] });
  assert.equal((await failedMessageData()).length, 1);
  assert.equal(Number(calls.find(c => c.method === 'eth_getLogs').params[0].fromBlock), saved.block - 1799);
});

test('provider failures never advance history or render a false no-failures result', async () => {
  const { failedMessageData, refreshShuttles } = await import('../../site/static/shuttles.js');
  const cases = [
    { method: 'eth_getLogs', result: null, error: /invalid logs response/ },
    { method: 'eth_getLogs', thrown: 'history pruned', error: /refresh the bundled snapshot.*history pruned/ },
    { method: 'eth_getBlockByNumber', result: null, error: /timestamp unavailable/ },
  ];
  for (const c of cases) {
    const saved = await checkpoint(), before = records.get(PROGRESS_KEY);
    mockSources({ head: saved.block + 100, logs: [failed(saved.block + 5)], answer(method) {
      if (method !== c.method) return undefined;
      if (c.thrown) throw new Error(c.thrown);
      return c.result;
    } });
    await assert.rejects(failedMessageData(), c.error);
    assert.equal(records.get(PROGRESS_KEY), before);
    const panel = { innerHTML: '' };
    globalThis.document.getElementById = id => id === 'shuttle' ? panel : null;
    await refreshShuttles();
    assert.match(panel.innerHTML, /err-banner/);
    assert.doesNotMatch(panel.innerHTML, /No failures/);
    assert.equal(records.get(PROGRESS_KEY), before);
  }
});

test('mixed-case RPC quantities and topics decode with same-block lifecycle ordering', async () => {
  const { failedMessageData } = await import('../../site/static/shuttles.js');
  const saved = await checkpoint(), block = saved.block + 5;
  const logs = [1, 2, 3, 4].map(id => ({ ...failed(block, id), logIndex: '0xA' }));
  logs.push(lifecycle(RETRIED, block, 1, 11), lifecycle(RECOVERED, block, 2, 12),
    lifecycle(RETRIED, block, 3, 9), lifecycle(RECOVERED, block, 4, 13));
  logs.forEach(log => {
    log.blockNumber = '0x' + Number(log.blockNumber).toString(16).toUpperCase();
    log.topics = log.topics.map(t => '0x' + t.slice(2).toUpperCase());
    log.transactionHash = '0x' + log.transactionHash.slice(2).toUpperCase();
  });
  mockSources({ head: saved.block + 100, logs, state: hash(0), answer(method, [p]) {
    if (method === 'eth_call' && p.data.endsWith(word(4))) return hash(1);
  } });
  const messages = await failedMessageData();
  assert.deepEqual(messages.map(m => m.state), ['retried', 'recovered', 'unknown', 'active']);
  assert.equal(messages[0].lifecycle.logIndex, 11);
  assert.equal(messages[2].lifecycle, null);
});

test('malformed event payloads fail without saving partial history', async () => {
  const { failedMessageData } = await import('../../site/static/shuttles.js');
  const saved = await checkpoint(), before = records.get(PROGRESS_KEY);
  mockSources({ head: saved.block + 100, logs: [{ ...failed(saved.block + 5), data: '0x' }] });
  await assert.rejects(failedMessageData(), /unrecognized receiver event/);
  assert.equal(records.get(PROGRESS_KEY), before);
});

test('older, wrong-network, malformed and incompatible browser checkpoints fall back to the seed', async () => {
  const { L1 } = await import('../../site/static/config.js');
  const { RECEIVER_SNAPSHOT: seed } = await import('../../site/static/receiver-snapshot.js');
  const { receiverCheckpoint } = await import('../../site/static/receiver-history.js');
  const { decodeReceiverHistory } = await import('../../site/static/shuttles.js');
  const newer = { ...seed, block: seed.block + 1000 };
  for (const saved of [
    { ...seed, block: seed.block - 1 }, { ...newer, chainId: 10 },
    { ...newer, receiver: '0x' + '1'.repeat(40) }, { ...newer, logs: null },
    { ...newer, fromBlock: seed.fromBlock + 1 }, { ...newer, since: seed.since + 1 },
    { ...newer, logs: [{ ...failed(seed.block), blockNumber: seed.block, logIndex: 0, timeStamp: timestamp, data: '0x' }] },
  ]) {
    records.set(PROGRESS_KEY, JSON.stringify(saved));
    assert.deepEqual(receiverCheckpoint(L1, decodeReceiverHistory), seed);
  }
});

test('a lagging RPC cannot rewind receiver history', async () => {
  const { failedMessageData } = await import('../../site/static/shuttles.js');
  const saved = await checkpoint(), before = records.get(PROGRESS_KEY);
  const calls = mockSources({ head: saved.block + 1 });
  await assert.rejects(failedMessageData(), /behind the receiver checkpoint/);
  assert.equal(calls.filter(c => c.method === 'eth_getLogs').length, 0);
  assert.equal(records.get(PROGRESS_KEY), before);
});

test('receiver history and state honor the configured Ethereum RPC override', async t => {
  const { L1 } = await import('../../site/static/config.js');
  const { failedMessageData } = await import('../../site/static/shuttles.js');
  const oldRPC = L1.rpc;
  t.after(() => { L1.rpc = oldRPC; });
  L1.rpc = 'https://custom-ethereum.example';
  const saved = await checkpoint();
  mockSources({ head: saved.block + 100, logs: [failed(saved.block + 5)] });
  const fetch = globalThis.fetch, urls = [];
  globalThis.fetch = (url, init) => { urls.push(String(url)); return fetch(url, init); };
  assert.equal((await failedMessageData()).length, 1);
  assert.ok(urls.length >= 4);
  assert.ok(urls.every(url => url === L1.rpc));
});

test('a complete empty RPC history renders no failures', async () => {
  const { refreshShuttles } = await import('../../site/static/shuttles.js');
  const saved = await checkpoint();
  mockSources({ head: saved.block + 100 });
  const panel = { innerHTML: '' };
  globalThis.document.getElementById = id => id === 'shuttle' ? panel : null;
  await refreshShuttles();
  assert.match(panel.innerHTML, /No failures since 1 Aug 2026/);
  assert.doesNotMatch(panel.innerHTML, /err-banner/);
});

test('the real updater rebuilds the full window and preserves the old file on failure', async t => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { spawnSync } = require('node:child_process');
  const { pathToFileURL } = require('node:url');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'receiver-snapshot-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const output = path.join(dir, 'site/static/receiver-snapshot.js');
  fs.mkdirSync(path.dirname(output), { recursive: true });
  const scriptURL = pathToFileURL(require.resolve('./update-receiver-snapshot.cjs')).href;
  const { FAILURES_SINCE } = await import('../../site/static/receiver-history.js');
  for (const mode of ['success', 'wrong-chain', 'missing-page']) {
    fs.writeFileSync(output, 'old snapshot');
    const child = spawnSync(process.execPath, ['--input-type=module', '--eval', `
      import fs from 'node:fs';
      import assert from 'node:assert/strict';
      const { logs, since, mode } = JSON.parse(fs.readFileSync(0, 'utf8'));
      globalThis.setTimeout = resolve => { queueMicrotask(resolve); return 0; };
      globalThis.fetch = async (url, init) => {
        assert.equal(url, 'https://archive.example');
        const body = JSON.parse(init.body);
        const reply = ({ id, method, params: [p] }) => {
          let result;
          if (method === 'eth_chainId') result = mode === 'wrong-chain' ? '0xa' : '0x1';
          else if (method === 'eth_blockNumber') result = '0x1f40'; // 8000; checkpoint = 6200
          else if (method === 'eth_getBlockByNumber') result = { timestamp: '0x' + (since + Number(p) - 10).toString(16) };
          else if (method === 'eth_getLogs') {
            assert.equal(p.topics[0].length, 3);
            assert.ok(Number(p.toBlock) - Number(p.fromBlock) < 2000);
            result = mode === 'missing-page' ? null : logs.filter(l =>
              Number(l.blockNumber) >= Number(p.fromBlock) && Number(l.blockNumber) <= Number(p.toBlock));
          } else throw new Error('unexpected method ' + method);
          return { jsonrpc: '2.0', id, result };
        };
        return { ok: true, status: 200, json: async () => Array.isArray(body) ? body.map(reply) : reply(body) };
      };
      process.argv.push('--rebuild');
      await import(${JSON.stringify(scriptURL)});
    `], { cwd: dir, encoding: 'utf8', timeout: 15000,
      env: { ...process.env, RPC_ETHEREUM_REMOTE: 'https://archive.example' },
      input: JSON.stringify({ mode, since: FAILURES_SINCE, logs: [failed(10), lifecycle(RETRIED, 12)] }) });
    if (mode !== 'success') {
      assert.equal(child.status, 1, child.stderr);
      assert.match(child.stderr, mode === 'wrong-chain' ? /wrong chain/ : /invalid logs response/);
      assert.equal(fs.readFileSync(output, 'utf8'), 'old snapshot');
      continue;
    }
    assert.equal(child.status, 0, child.error?.message ?? child.stderr);
    const snapshot = JSON.parse(fs.readFileSync(output, 'utf8').replace(/^export const RECEIVER_SNAPSHOT = /, '').replace(/;\s*$/, ''));
    assert.equal(snapshot.fromBlock, 10);
    assert.equal(snapshot.block, 6200);
    assert.equal(snapshot.logs.length, 2);
    assert.equal(snapshot.logs[0].timeStamp, FAILURES_SINCE);
    assert.ok(!fs.readFileSync(output, 'utf8').includes('archive.example'));
  }
});
