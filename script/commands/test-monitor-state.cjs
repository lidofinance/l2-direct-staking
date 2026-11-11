#!/usr/bin/env node
// Exercise script/commands/monitor-state.sh (the unchanged state-mate CLI over config/state) against a
// local RPC fixture derived independently from the same config files: every asserted call/storage read
// must be served exactly as configured, and injected drift / RPC / storage faults must fail the run.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { createRequire } = require('node:module');
const root = path.resolve(__dirname, '../..');
const sm = process.env.STATE_MATE_DIR ? path.resolve(process.env.STATE_MATE_DIR) : path.join(root, 'lib/state-mate');
const requireSM = createRequire(path.join(sm, 'package.json'));
requireSM('ts-node').register({ project: path.join(sm, 'tsconfig.json'), transpileOnly: true, compilerOptions: { rootDir: sm } });
requireSM('tsconfig-paths').register({ baseUrl: sm, paths: {} });
const { Interface, zeroPadValue } = requireSM('ethers');
const { composeWithSiblings } = require(path.join(sm, 'src/sibling-delegation'));
const { INPUTS_SPEC } = require(path.join(sm, 'src/inputs'));
const { DEPLOYED_SPEC } = require(path.join(sm, 'src/deployed-addresses'));
const sourceDir = path.join(root, 'config/state');
const runner = path.join(root, 'script/commands/monitor-state.sh');

function sibling(file, spec) { return { text: fs.readFileSync(path.join(sourceDir, file), 'utf8'), spec }; }
function abiFor(name) { return new Interface(JSON.parse(fs.readFileSync(path.join(sourceDir, 'abi', `${name}.json`), 'utf8'))); }

// Collect the (address, calldata) -> result and (address, slot) -> value pairs one config section asserts.
function collect(section, calls, storage) {
  for (const contract of Object.values(section.contracts)) {
    const iface = abiFor(contract.name);
    const addChecks = (address, checks) => {
      for (const [method, check] of Object.entries(checks || {})) {
        if (check === null || !iface.hasFunction(method)) continue;
        for (const entry of Array.isArray(check) ? check : [check]) {
          const call = entry && typeof entry === 'object' && !Array.isArray(entry) ? entry : { result: entry };
          if (call.result === null || call.mustRevert) continue;
          const fragment = iface.getFunction(call.signature || method);
          const data = iface.encodeFunctionData(fragment, call.args || []);
          const outputs = fragment.outputs.length === 1 ? [call.result] : call.result;
          calls.set(`${address.toLowerCase()}:${data}`, { method, result: iface.encodeFunctionResult(fragment, outputs) });
        }
      }
    };
    addChecks(contract.address, contract.checks);
    if (contract.implementation) addChecks(contract.implementation, contract.implementationChecks);
    // state-mate checks every named holder against every listed role (membership plus cross-role exclusion).
    const acl = Object.entries(contract.ozNonEnumerableAcl || {});
    const namedHolders = [...new Set(acl.flatMap(([, holders]) => holders))];
    for (const [role, holders] of acl) {
      for (const holder of namedHolders) {
        const data = iface.encodeFunctionData('hasRole', [role, holder]);
        const result = iface.encodeFunctionResult('hasRole', [holders.includes(holder)]);
        calls.set(`${contract.address.toLowerCase()}:${data}`, { method: 'hasRole', result });
      }
    }
    for (const check of contract.storage || []) {
      storage.set(`${contract.address.toLowerCase()}:${check.slot.toLowerCase()}`, zeroPadValue(check.expected, 32));
    }
  }
}

function baseline(network) {
  const calls = new Map(), storage = new Map();
  if (network === 'ethereum') {
    const { document } = composeWithSiblings(fs.readFileSync(path.join(sourceDir, 'ethereum.yaml'), 'utf8'), [sibling('ethereum.inputs.yaml', INPUTS_SPEC)]);
    collect(document.l1, calls, storage);
    return { chainId: `0x${BigInt(document.l1.chainId).toString(16)}`, calls, storage };
  }
  const inputs = [sibling('common.inputs.yaml', INPUTS_SPEC), sibling(`${network}.inputs.yaml`, INPUTS_SPEC)];
  const { document } = composeWithSiblings(fs.readFileSync(path.join(sourceDir, 'l2.yaml'), 'utf8'),
    [...inputs, sibling('common.deployed.yaml', DEPLOYED_SPEC), sibling(`${network}.deployed.yaml`, DEPLOYED_SPEC)]);
  collect(document.l2, calls, storage); // the runner selects --only l2 when no L1 RPC is configured
  if (network === 'linea') {
    const gelato = composeWithSiblings(fs.readFileSync(path.join(sourceDir, 'l2-linea-gelato.yaml'), 'utf8'), []).document; // standalone
    collect(gelato.l2, calls, storage);
  }
  return { chainId: `0x${BigInt(document.l2.chainId).toString(16)}`, calls, storage };
}

const rpcCases = new Map();
for (const network of ['ethereum', 'optimism', 'arbitrum', 'base', 'linea']) rpcCases.set(network, baseline(network));

function response(request, context) {
  const { id, method, params } = request;
  const success = result => ({ jsonrpc: '2.0', id, result });
  const error = message => ({ jsonrpc: '2.0', id, error: { code: -32000, message } });
  if (method === 'eth_chainId') return success(context.chainId);
  if (method === 'eth_blockNumber') return success('0x100');
  if (method === 'eth_call') {
    const key = `${params[0].to.toLowerCase()}:${params[0].data || params[0].input}`;
    const fixture = context.calls.get(key);
    if (!fixture) return error('Unexpected call: not covered by the independent fixture');
    context.read.add(key);
    if (context.fault === 'rpc' && fixture.method === 'getDelay') { context.injectedErrors++; return error('simulated RPC failure'); }
    if (context.fault === 'drift' && fixture.method === 'getDelay') return success(zeroPadValue('0xa8c1', 32)); // 43201 instead of 43200
    return success(fixture.result);
  }
  if (method === 'eth_getStorageAt') {
    const key = `${params[0].toLowerCase()}:${params[1].toLowerCase()}`;
    const value = context.storage.get(key);
    if (!value) return error('Unexpected storage read');
    context.read.add(key);
    if (context.fault === 'storage') return success(zeroPadValue('0x01', 32));
    return success(value);
  }
  return error(`Unexpected RPC method ${method}`);
}

async function run(server, network, fault) {
  const token = `${network}-${fault || 'healthy'}`;
  const context = { ...rpcCases.get(network), fault, read: new Set(), injectedErrors: 0 };
  server.contexts.set(token, context);
  const url = `http://127.0.0.1:${server.address().port}/${token}`;
  const upper = network.toUpperCase();
  // Only the variables the runner reads; no L1 RPC so lane runs take `--only l2` (the fixture matches).
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, STATE_MATE_DIR: sm, NO_COLOR: '1', FORCE_COLOR: '0' };
  if (network === 'ethereum') env.L1_RPC_URL = url; else env[`L2_${upper}_RPC_URL`] = url;
  const { code, output } = await new Promise((resolve, reject) => {
    const child = spawn('bash', [runner, network], { cwd: os.tmpdir(), env });
    let output = '';
    const timer = setTimeout(() => { child.kill(); reject(new Error(`${token}: timed out\n${output}`)); }, 120000);
    child.stdout.on('data', chunk => { output += chunk; });
    child.stderr.on('data', chunk => { output += chunk; });
    child.on('error', reject);
    child.on('close', code => { clearTimeout(timer); resolve({ code, output }); });
  });
  assert.equal(code === 0, !fault, `${token}: unexpected exit ${code}\n${output}`);
  const expected = new Set([...context.calls.keys(), ...context.storage.keys()]);
  const missed = [...expected].filter(key => !context.read.has(key));
  assert.deepEqual(missed, [], `${token}: configured assertions were never read:\n${missed.join('\n')}\n${output}`);
  const plain = output.replace(/\x1b\[[0-9;]*[A-Za-z]/g, ''); // the runner forces colour for terminals
  const totals = [...plain.matchAll(/Total: (\d+) checks/g)].map(m => Number(m[1]));
  assert.ok(totals.length > 0, `${token}: no state-mate total in output\n${output}`);
  if (fault === 'drift') assert.match(plain, /43201/, output);
  if (fault === 'rpc') {
    // Every configured getDelay read (SyncTrigger and the BridgeExecutor) is faulted exactly once.
    const faulted = [...context.calls.values()].filter(call => call.method === 'getDelay').length;
    assert.equal(context.injectedErrors, faulted, `${token}: expected ${faulted} injected RPC errors\n${output}`);
    assert.match(plain, /Method: getDelay/, output);
  }
  if (fault === 'storage') assert.match(plain, /storage/i, output);
  console.log(`${token}: ${expected.size} configured reads served, state-mate totals ${totals.join('+')}, exit ${code} as expected`);
}

(async () => {
  const server = http.createServer(async (req, res) => {
    const context = server.contexts.get(req.url.slice(1));
    if (!context) { res.writeHead(404).end(); return; }
    let body = '';
    for await (const chunk of req) body += chunk;
    const request = JSON.parse(body);
    const result = Array.isArray(request) ? request.map(item => response(item, context)) : response(request, context);
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(result));
  });
  server.contexts = new Map();
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    await run(server, 'ethereum', null);
    for (const lane of ['optimism', 'arbitrum', 'base', 'linea']) await run(server, lane, null);
    await run(server, 'optimism', 'drift');
    await run(server, 'optimism', 'rpc');
    await run(server, 'ethereum', 'storage');
  } finally {
    if (server.listening) await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
