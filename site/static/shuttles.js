import { L1, LANE_BY_CCIP_SELECTOR } from './config.js';
import { blockscoutAddressLogs, rpcBatch, rpcBlockNumber, rpcFetch, SEL } from './rpc.js';
import { ago, alink, chip, esc, fmtAmt, laneWho, setOverviewStatus, short, viewRefresh } from './ui.js';

// ── Shuttle failures ────────────────────────────────────────────────────────
// MessageFailed discovers the incident and carries the complete CCIP message. Contract state and
// lifecycle events provide the current verdict; an old failure event alone must never look active.
const MESSAGE_FAILED_TOPIC = '0xef8a84d7e9c9d42c79a42cba16e93688c646989f43846843e163672cc887e253';
const MESSAGE_RECOVERED_TOPIC = '0xef3bf8c64bc480286c4f3503b870ceb23e648d2d902e31fb7bb46680da6de8ad';
const TOKENS_RECOVERED_TOPIC = '0x6e2f4b2b871174c4882a9b21bf5a2f421274d3dba05cc997af4528bdc393c027';
const ZERO32 = '0x' + '0'.repeat(64);
const FAILURES_SINCE = Date.parse('2026-08-01T00:00:00Z') / 1000;

const logQuantity = value => {
  try {
    if (typeof value === 'number') return Number.isSafeInteger(value) ? value : null;
    if (/^(0x[0-9a-f]+|\d+)$/i.test(value ?? '')) {
      const n = Number(BigInt(value));
      return Number.isSafeInteger(n) ? n : null;
    }
  } catch {}
  return null;
};

function parseFailedMessageLog(log) {
  const body = (log.data ?? '').replace(/^0x/, '');
  const topics = log.topics ?? [];
  const eventId = (topics[1] ?? '').toLowerCase();
  const tx = (log.transactionHash ?? '').toLowerCase();
  if ((topics[0] ?? '').toLowerCase() !== MESSAGE_FAILED_TOPIC ||
      !/^0x[0-9a-f]{64}$/.test(eventId) || !/^0x[0-9a-f]{64}$/.test(tx) ||
      !/^[0-9a-f]+$/i.test(body) || body.length % 64) return null;

  const words = body.length / 64;
  const word = i => {
    if (!Number.isSafeInteger(i) || i < 0 || i >= words) throw new Error('short event data');
    return body.slice(i * 64, i * 64 + 64);
  };
  const uint = i => BigInt('0x' + word(i));
  const relative = (base, slot) => {
    const offset = Number(uint(slot));
    if (!Number.isSafeInteger(offset) || offset % 32) throw new Error('invalid event offset');
    return base + offset / 32;
  };
  const bytes = (base, slot) => {
    const at = relative(base, slot);
    const length = Number(uint(at));
    if (!Number.isSafeInteger(length)) throw new Error('invalid bytes length');
    const start = (at + 1) * 64;
    const value = body.slice(start, start + length * 2);
    if (value.length !== length * 2) throw new Error('short bytes value');
    return value;
  };

  try {
    const tuple = relative(0, 0);
    const messageId = ('0x' + word(tuple)).toLowerCase();
    if (messageId !== eventId) return null;
    const sourceSelector = uint(tuple + 1).toString();
    bytes(tuple, tuple + 2); // validate the sender offset even though the receiver already authenticated it
    const payload = bytes(tuple, tuple + 3);
    const tokenArray = relative(tuple, tuple + 4);
    const tokenCount = Number(uint(tokenArray));
    const maxTokenCount = Math.floor((words - tokenArray - 1) / 2);
    if (!Number.isSafeInteger(tokenCount) || tokenCount < 0 || tokenCount > maxTokenCount) return null;
    const tokens = Array.from({ length: tokenCount }, (_, i) => ({
      token: '0x' + word(tokenArray + 1 + i * 2).slice(-40),
      amount: uint(tokenArray + 2 + i * 2),
    }));
    const block = logQuantity(log.blockNumber), logIndex = logQuantity(log.logIndex);
    if (block == null || logIndex == null) return null;
    return {
      messageId, sourceSelector, tx, block, logIndex, timestamp: logQuantity(log.timeStamp),
      recipient: payload.length >= 104 ? '0x' + payload.slice(0, 40) : null,
      amount: payload.length >= 104 ? BigInt('0x' + payload.slice(40, 104)) : null,
      tokens,
    };
  } catch { return null; }
}

function parseFailedLifecycleLog(log) {
  const topic = (log.topics?.[0] ?? '').toLowerCase();
  const messageId = (log.topics?.[1] ?? '').toLowerCase();
  const tx = (log.transactionHash ?? '').toLowerCase();
  const block = logQuantity(log.blockNumber), logIndex = logQuantity(log.logIndex);
  const kind = topic === MESSAGE_RECOVERED_TOPIC ? 'retried'
    : topic === TOKENS_RECOVERED_TOPIC ? 'recovered' : null;
  if (!kind || !/^0x[0-9a-f]{64}$/.test(messageId) || !/^0x[0-9a-f]{64}$/.test(tx) ||
      block == null || logIndex == null) return null;
  return { kind, messageId, tx, block, logIndex, timestamp: logQuantity(log.timeStamp) };
}

async function l1ReceiverLogs(topic, toBlock) {
  return (await blockscoutAddressLogs(L1.bs, L1.receiver, topic, { since: FAILURES_SINCE }))
    .filter(log => log.blockNumber <= toBlock);
}

async function blockscoutIndexedBlock() {
  const res = await rpcFetch(`${L1.bs}/api/v2/blocks?type=block`);
  if (!res.ok) throw new Error(`index status HTTP ${res.status}`);
  const indexedBlock = logQuantity((await res.json()).items?.[0]?.height);
  if (indexedBlock == null) throw new Error('indexed block unreadable');
  return indexedBlock;
}

async function failedMessageData() {
  const [rpcHead, indexedHead] = await Promise.all([rpcBlockNumber(L1), blockscoutIndexedBlock()]);
  const maxIndexLag = 64;
  if (rpcHead - indexedHead > maxIndexLag)
    throw new Error(`L1 indexer is ${rpcHead - indexedHead} blocks behind RPC (maximum ${maxIndexLag})`);
  const atBlock = Math.min(rpcHead, indexedHead);
  const failedLogs = await l1ReceiverLogs(MESSAGE_FAILED_TOPIC, atBlock);
  const retriedLogs = await l1ReceiverLogs(MESSAGE_RECOVERED_TOPIC, atBlock);
  const recoveredLogs = await l1ReceiverLogs(TOKENS_RECOVERED_TOPIC, atBlock);
  const decoded = failedLogs.map(parseFailedMessageLog);
  const lifecycle = [...retriedLogs, ...recoveredLogs].map(parseFailedLifecycleLog);
  if (decoded.some(message => !message) || lifecycle.some(event => !event))
    throw new Error('unrecognized receiver event');
  if (decoded.some(message => message.timestamp == null))
    throw new Error('receiver event timestamp unavailable');
  const messages = [...new Map(decoded.filter(message => message.timestamp >= FAILURES_SINCE)
    .map(message => [message.messageId, message])).values()];
  const hashes = await rpcBatch(L1.rpc, messages.map(message => ({ method: 'eth_call', params: [{
    to: L1.receiver, data: SEL.failedMessageHash + message.messageId.slice(2),
  }, '0x' + atBlock.toString(16)] })));
  if (hashes.some(hash => !/^0x[0-9a-f]{64}$/i.test(hash ?? '')))
    throw new Error('failed-message state unreadable');
  return messages.map((message, i) => {
    const later = lifecycle.filter(event => event.messageId === message.messageId &&
      (event.block > message.block || event.block === message.block && event.logIndex > message.logIndex))
      .sort((a, b) => b.block - a.block || b.logIndex - a.logIndex)[0] ?? null;
    const failedHash = hashes[i].toLowerCase();
    return { ...message, failedHash, lifecycle: later,
      state: failedHash !== ZERO32 ? 'active' : later?.kind ?? 'unknown' };
  });
}

function renderShuttles(messages, error) {
  if (error) {
    setOverviewStatus('shuttle', 'crit');
    document.getElementById('shuttle').innerHTML = `<div class="card">
      <div class="card-head"><h3>L1 receiver failures</h3>${viewRefresh('shuttle', 'Shuttle failures')}</div>
      <div class="err-banner">✕ ${esc(error)}</div></div>`;
    return;
  }
  const active = messages.filter(message => message.state === 'active');
  const unknown = messages.filter(message => message.state === 'unknown');
  const retried = messages.filter(message => message.state === 'retried');
  const recovered = messages.filter(message => message.state === 'recovered');
  const ordered = [...messages].sort((a, b) => (b.timestamp ?? 0) - (a.timestamp ?? 0) ||
    b.block - a.block || b.logIndex - a.logIndex);
  setOverviewStatus('shuttle', unknown.length || active.length ? 'crit' : 'ok');
  const rows = ordered.map(message => {
    const lane = LANE_BY_CCIP_SELECTOR.get(message.sourceSelector);
    const source = lane ? laneWho(lane) : `<span class="mono">${message.sourceSelector}</span>`;
    const recipient = message.recipient
      ? lane ? alink(lane, message.recipient) : `<span class="mono">${short(message.recipient)}</span>` : '—';
    const requested = message.amount == null ? '<div class="m">Malformed</div><div class="s">payload &lt; 52 bytes</div>'
      : `<div class="m">${fmtAmt(message.amount)} requested</div><div class="s">${message.tokens.length} token ${message.tokens.length === 1 ? 'entry' : 'entries'}</div>`;
    const state = message.state === 'active' ? chip('crit', 'Stored on L1', 'retry / recover')
      : message.state === 'retried' ? chip('ok', 'Retry sent', 'L1 cleared')
      : message.state === 'recovered' ? chip('warn', 'Tokens recovered', 'off Shuttle')
      : chip('crit', 'Unknown', 'hash = 0; no event');
    return `<tr>
      <td><span class="num"><div class="m">${ago(message.timestamp)}</div><div class="s">${message.timestamp ? new Date(message.timestamp * 1000).toLocaleString() : 'time unavailable'}</div></span></td>
      <td>${source}</td>
      <td><span class="num">${requested}</span></td>
      <td>${recipient}</td>
      <td>${state}</td>
      <td><span class="who">
        <a class="mono" href="https://ccip.chain.link/msg/${message.messageId}" target="_blank" title="${message.messageId}">CCIP ↗</a>
        <a class="mono" href="${L1.explorer}/tx/${message.tx}" target="_blank" title="${message.tx}">Failure ↗</a>
        ${message.lifecycle ? `<a class="mono" href="${L1.explorer}/tx/${message.lifecycle.tx}" target="_blank" title="${message.lifecycle.tx}">${message.lifecycle.kind === 'retried' ? 'Retry' : 'Recovery'} ↗</a>` : ''}
      </span></td>
    </tr>`;
  }).join('');
  const summary = messages.length
    ? `${active.length} active · ${retried.length} retry sent · ${recovered.length} tokens recovered`
    : 'No failures since 1 Aug 2026.';
  document.getElementById('shuttle').innerHTML = `<div class="card">
    <div class="card-head">
      <h3>L1 receiver failures</h3>
      <span class="desc">${summary}${messages.length ? ' · since 1 Aug 2026' : ''}</span>
      ${viewRefresh('shuttle', 'Shuttle failures')}
    </div>
    ${unknown.length ? `<div class="err-banner">✕ ${unknown.length} message ${unknown.length === 1 ? 'has' : 'have'} no lifecycle event</div>` : ''}
    ${rows ? `<div class="scroll-x"><table>
      <tr><th>Failed</th><th>Source</th><th>Payload</th><th>Recipient</th><th>Current state</th><th>Evidence</th></tr>
      ${rows}</table></div>` : ''}
  </div>`;
}

export async function refreshShuttles() {
  try { renderShuttles(await failedMessageData(), null); }
  catch (e) { renderShuttles([], e.message); }
}
