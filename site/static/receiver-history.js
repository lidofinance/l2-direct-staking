import { RECEIVER_SNAPSHOT } from './receiver-snapshot.js';
import { RPC_CONFIRMATIONS, rpcBlockTimestamps, rpcHistoryLogs, rpcRequest } from './rpc.js';

export const MESSAGE_FAILED_TOPIC = '0xef8a84d7e9c9d42c79a42cba16e93688c646989f43846843e163672cc887e253';
export const MESSAGE_RECOVERED_TOPIC = '0xef3bf8c64bc480286c4f3503b870ceb23e648d2d902e31fb7bb46680da6de8ad';
export const TOKENS_RECOVERED_TOPIC = '0x6e2f4b2b871174c4882a9b21bf5a2f421274d3dba05cc997af4528bdc393c027';
export const RECEIVER_TOPICS = [MESSAGE_FAILED_TOPIC, MESSAGE_RECOVERED_TOPIC, TOKENS_RECOVERED_TOPIC];
export const FAILURES_SINCE = Date.parse('2026-08-01T00:00:00Z') / 1000;
const PROGRESS_KEY = 'direct-staking-watch.receiver-progress.v1';

function validCheckpoint(snapshot, L) {
  return snapshot?.chainId === L.chainId && snapshot.receiver?.toLowerCase() === L.receiver.toLowerCase() &&
    snapshot.since === FAILURES_SINCE && Number.isSafeInteger(snapshot.fromBlock) && snapshot.fromBlock >= 0 &&
    Number.isSafeInteger(snapshot.block) && snapshot.block >= snapshot.fromBlock && Array.isArray(snapshot.logs) &&
    snapshot.logs.every(log => log && Number.isSafeInteger(log.blockNumber) && log.blockNumber >= snapshot.fromBlock &&
      log.blockNumber <= snapshot.block && Number.isSafeInteger(log.logIndex) && log.logIndex >= 0 &&
      Number.isSafeInteger(log.timeStamp) && log.timeStamp >= FAILURES_SINCE &&
      /^0x[0-9a-f]{64}$/i.test(log.transactionHash ?? '') && /^0x(?:[0-9a-f]{2})*$/i.test(log.data ?? '') &&
      RECEIVER_TOPICS.includes(log.topics?.[0]?.toLowerCase()) && /^0x[0-9a-f]{64}$/i.test(log.topics?.[1] ?? ''));
}

export function receiverCheckpoint(L, validate = () => {}) {
  const valid = snapshot => {
    if (!validCheckpoint(snapshot, L)) return false;
    try { validate(snapshot.logs); return true; } catch { return false; }
  };
  const seed = valid(RECEIVER_SNAPSHOT) ? RECEIVER_SNAPSHOT : null;
  try {
    const saved = JSON.parse(localStorage.getItem(PROGRESS_KEY));
    if (valid(saved) && saved.block >= (seed?.block ?? 0) &&
        (!seed || saved.fromBlock === seed.fromBlock)) return saved;
  } catch {}
  return seed;
}

export function saveReceiverCheckpoint(snapshot) {
  try { localStorage.setItem(PROGRESS_KEY, JSON.stringify(snapshot)); } catch {}
}

// Locate the first block in the requested time window. Used only for a full rebuild.
async function firstReceiverBlock(L, toBlock) {
  let low = 0, high = toBlock;
  const at = async block => {
    const value = await rpcRequest(L.rpc, 'eth_getBlockByNumber', ['0x' + block.toString(16), false]);
    const ts = Number(BigInt(value.timestamp));
    if (!Number.isSafeInteger(ts) || ts < 0) throw new Error('block timestamp unavailable');
    return ts;
  };
  if (await at(high) < FAILURES_SINCE) throw new Error('RPC head predates the receiver history window');
  while (low < high) {
    const mid = Math.floor((low + high) / 2);
    if (await at(mid) < FAILURES_SINCE) low = mid + 1;
    else high = mid;
  }
  return low;
}

// Return a candidate only. The caller persists it after decoding and all state reads succeed.
export async function readReceiverHistory(L, previous, toBlock) {
  if (previous && !validCheckpoint(previous, L)) throw new Error('invalid receiver checkpoint');
  if (previous && toBlock < previous.block) throw new Error('RPC head is behind the receiver checkpoint');
  const first = previous?.fromBlock ?? await firstReceiverBlock(L, toBlock);
  const from = previous ? Math.max(first, previous.block - RPC_CONFIRMATIONS + 1) : first;
  let logs;
  try {
    logs = await rpcHistoryLogs({ ...L, logsRpc: L.rpc }, L.receiver, [RECEIVER_TOPICS], from, toBlock);
  } catch (error) {
    throw new Error(`Receiver history blocks ${from}–${toBlock} unavailable; refresh the bundled snapshot or use an RPC with historical logs. ${error.message}`);
  }
  const timestamps = await rpcBlockTimestamps(L.rpc, logs.map(log => log.blockNumber));
  const fresh = logs.map(log => ({
    blockNumber: Number(BigInt(log.blockNumber)), logIndex: Number(BigInt(log.logIndex)),
    transactionHash: log.transactionHash, topics: log.topics, data: log.data,
    timeStamp: timestamps.get(Number(BigInt(log.blockNumber))),
  }));
  if (fresh.some(log => log.blockNumber < from || log.blockNumber > toBlock))
    throw new Error('receiver log outside requested range');
  const all = [...(previous?.logs ?? []).filter(log => log.blockNumber < from), ...fresh];
  const unique = new Map(all.map(log => [`${log.transactionHash.toLowerCase()}:${log.logIndex}`, log]));
  const candidate = { chainId: L.chainId, receiver: L.receiver, since: FAILURES_SINCE, fromBlock: first,
    block: toBlock, logs: [...unique.values()].sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex) };
  if (!validCheckpoint(candidate, L)) throw new Error('invalid receiver logs');
  return candidate;
}
