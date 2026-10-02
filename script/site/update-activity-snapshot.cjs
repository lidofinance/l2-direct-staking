// Node 22+: node --env-file=.env script/site/update-activity-snapshot.cjs
// Run from the repository root. RPC URLs are used only here, never written to the snapshot.
const fs = require('node:fs');
const path = 'site/static/activity-snapshot.js';
// The site modules expect a browser; activity reads touch only these two.
globalThis.localStorage = { getItem() { return null; }, setItem() {} };
globalThis.document = { querySelectorAll() { return []; } };
(async () => {
  const { LANES } = await import('../../site/static/config.js');
  const { rpcRequest } = await import('../../site/static/rpc.js');
  const { activityData, activityProgress } = await import('../../site/static/activity.js');
  for (const lane of LANES) {
    const rpc = process.env[`RPC_${lane.name.toUpperCase()}_REMOTE`];
    if (!rpc) throw new Error(`Missing RPC_${lane.name.toUpperCase()}_REMOTE`);
    if (Number(BigInt(await rpcRequest(rpc, 'eth_chainId', []))) !== lane.chainId)
      throw new Error(`${lane.name}: wrong chain`);
    await activityData({ ...lane, rpc, logsRpc: rpc });
    const snapshot = activityProgress[lane.name];
    // Save after each lane; lanes not reached yet keep their previous snapshot.
    fs.writeFileSync(path, 'export const ACTIVITY_SNAPSHOT = ' + JSON.stringify(activityProgress, null, 2) + ';\n');
    console.log(`${lane.name}: block ${snapshot.block}, ${snapshot.events.length} events`);
  }
})().catch(error => { console.error(error.message.replace(/https?:\/\/\S+/g, '[RPC]')); process.exitCode = 1; });
