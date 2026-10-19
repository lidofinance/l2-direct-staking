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

function mockSources({ head = 10000, indexed = head - 10, logs = [], state = hash(1), answer } = {}) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    if (!init?.body) {
      const u = new URL(url);
      if (u.pathname === '/api/v2/blocks') return response({ items: [{ height: indexed }] });
      return response({ items: logs.filter(l => l.topics[0] === u.searchParams.get('topic') && Number(l.blockNumber) <= indexed)
        .map(l => ({ topics: l.topics, data: l.data, block_number: Number(l.blockNumber), index: Number(l.logIndex),
          transaction_hash: l.transactionHash, block_timestamp: new Date(timestamp * 1000).toISOString() })), next_page_params: null });
    }
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

// Exercise the real data path with a provider whose backend is one block behind its head oracle.
test('receiver logs and state use the same block behind the observed RPC head', async () => {
  const { failedMessageData } = await import('../../site/static/shuttles.js');
  const calls = mockSources({ head: 10000, logs: [failed(9995)], answer(method, params) {
    if (method === 'eth_getLogs' && Number(params[0].toBlock) > 9999 ||
        method === 'eth_call' && Number(params[1]) > 9999) throw new Error('header not found');
  } });
  const messages = await failedMessageData();
  assert.equal(messages[0].state, 'active');
  const end = Math.max(...calls.filter(c => c.method === 'eth_getLogs').map(c => Number(c.params[0].toBlock)));
  assert.ok(end < 10000);
  assert.equal(Number(calls.find(c => c.method === 'eth_call').params[1]), end);
});
