const assert = require('node:assert/strict');
const { test } = require('node:test');

globalThis.localStorage = { getItem() { return null; }, setItem() {} };
globalThis.document = { querySelectorAll() { return []; } };

const event = ts => ({ ts, block: ts ?? 1 });

test('recent events keep the latest three rows from every loaded lane', async () => {
  const { LANES } = await import('../../site/static/config.js');
  const { recentAutomationEvents } = await import('../../site/static/automation.js');
  const logs = {
    Optimism: Array.from({ length: 10 }, (_, i) => event(100 - i)),
    Arbitrum: Array.from({ length: 10 }, (_, i) => event(90 - i)),
    Base: [event(10), event(9), event(8)],
    Linea: [event(5), event(null)],
  };

  const rows = recentAutomationEvents(logs);
  assert.deepEqual(Object.fromEntries(LANES.map(L =>
    [L.name, rows.filter(row => row.L === L).length])), {
    Optimism: 3, Arbitrum: 3, Base: 3, Linea: 2,
  });
  assert.deepEqual(rows.map(row => row.ts), [100, 99, 98, 90, 89, 88, 10, 9, 8, 5, null]);
});

test('recent events tolerate missing and short lane histories', async () => {
  const { recentAutomationEvents } = await import('../../site/static/automation.js');
  const rows = recentAutomationEvents({ Base: [event(2)] });

  assert.equal(rows.length, 1);
  assert.equal(rows[0].L.name, 'Base');
  assert.equal(rows[0].ts, 2);
});
