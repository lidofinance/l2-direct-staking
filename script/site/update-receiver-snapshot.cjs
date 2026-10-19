// Node 22.7+: RPC_ETHEREUM_REMOTE=... node script/site/update-receiver-snapshot.cjs [--rebuild]
// Run from the repository root. --rebuild verifies the entire window, independently of the saved seed.
const fs = require('node:fs');
const path = 'site/static/receiver-snapshot.js';
globalThis.localStorage = { getItem() { return null; }, setItem() {} };
globalThis.document = { querySelectorAll() { return []; } };
(async () => {
  if (process.argv.slice(2).some(arg => arg !== '--rebuild')) throw new Error('Usage: update-receiver-snapshot.cjs [--rebuild]');
  const rpc = process.env.RPC_ETHEREUM_REMOTE;
  if (!rpc) throw new Error('Missing RPC_ETHEREUM_REMOTE');
  const { L1 } = await import('../../site/static/config.js');
  const { rpcRequest, rpcSafeBlock } = await import('../../site/static/rpc.js');
  const { receiverCheckpoint, readReceiverHistory } = await import('../../site/static/receiver-history.js');
  const { decodeReceiverHistory } = await import('../../site/static/shuttles.js');
  const L = { ...L1, rpc };
  if (Number(BigInt(await rpcRequest(rpc, 'eth_chainId', []))) !== L.chainId) throw new Error('Ethereum: wrong chain');
  const block = await rpcSafeBlock(L);
  const previous = process.argv.includes('--rebuild') ? null : receiverCheckpoint(L, decodeReceiverHistory);
  const snapshot = await readReceiverHistory(L, previous, block);
  decodeReceiverHistory(snapshot.logs);
  // Keep the old artifact intact unless the entire range and event decoding succeeded.
  fs.writeFileSync(path + '.tmp', 'export const RECEIVER_SNAPSHOT = ' + JSON.stringify(snapshot, null, 2) + ';\n');
  fs.renameSync(path + '.tmp', path);
  console.log(`Ethereum receiver: blocks ${snapshot.fromBlock}–${snapshot.block}, ${snapshot.logs.length} events`);
})().catch(error => { console.error(error.message.replace(/https?:\/\/\S+/g, '[RPC]')); process.exitCode = 1; });
