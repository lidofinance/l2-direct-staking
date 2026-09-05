const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { spawnSync, execFileSync } = require('node:child_process');

const repo = path.resolve(__dirname, '../..');
const digest = text => createHash('sha256').update(text).digest('hex');
const config = '{"lanes":[]}\n';
const source = '// deployment source\n';
const signature = 'upsertWorkflow(string,string,bytes32,uint8,string,string,string,bytes,bool)';
const env = { PATH: process.env.PATH, LC_ALL: 'C' };

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'staking-commands-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const dir of ['script/commands', 'script/shared', 'cre-workflows/sync-automation', 'site/static', 'bin'])
    fs.mkdirSync(path.join(root, dir), { recursive: true });
  for (const file of ['commands/cre-workflow-hash.sh', 'commands/cre-attach-params.sh',
    'commands/env-doctor.sh', 'shared/cre-artifacts.sh', 'shared/cre-env.sh'])
    fs.copyFileSync(path.join(repo, 'script', file), path.join(root, 'script', file));
  fs.writeFileSync(path.join(root, 'cre-workflows/sync-automation/config.deploy.json'), config);
  fs.writeFileSync(path.join(root, 'cre-workflows/sync-automation/main.ts'), source);
  fs.writeFileSync(path.join(root, 'site/static/app.js'),
    `const CRE_CONFIG_SHA256 = '${digest(config)}';\nconst CRE_SOURCE_SHA256 = '${digest(source)}';\n` +
    `const CRE_CONFIG_JSON = ${JSON.stringify(config)};\n`);
  return root;
}

function run(root, command, options = {}) {
  return spawnSync('bash', [path.join(root, 'script/commands', command + '.sh')], {
    cwd: os.tmpdir(), encoding: 'utf8', timeout: 10000, env, ...options,
  });
}

function calldata(attrs = '0x') {
  return execFileSync('cast', ['calldata', signature, 'test-workflow', 'test-tag',
    '0x' + 'ab'.repeat(32), '1', 'zone-a', 'https://example.com/binary',
    'https://example.com/config', attrs, 'true'], { encoding: 'utf8', env }).trim();
}

function decode(data) {
  return JSON.parse(execFileSync('cast', ['decode-calldata', '--json', signature, data],
    { encoding: 'utf8', env }));
}

test('dashboard validation detects source and config drift', t => {
  const root = fixture(t);
  assert.equal(run(root, 'cre-workflow-hash').status, 0);
  fs.appendFileSync(path.join(root, 'cre-workflows/sync-automation/main.ts'), '// changed\n');
  let result = run(root, 'cre-workflow-hash');
  assert.equal(result.status, 1);
  assert.match(result.stderr, /CRE_SOURCE_SHA256 is stale/);
  fs.appendFileSync(path.join(root, 'cre-workflows/sync-automation/config.deploy.json'), '\n');
  result = run(root, 'cre-workflow-hash');
  assert.equal(result.status, 1);
  assert.match(result.stderr, /CRE_CONFIG_SHA256 is stale/);
  assert.match(result.stderr, /not config.deploy.json byte-for-byte/);
});

test('attach uses source files without a dashboard and preserves every other calldata field', t => {
  const root = fixture(t);
  fs.unlinkSync(path.join(root, 'site/static/app.js'));
  const input = calldata();
  for (const options of [{ input: input + '\n' }, { env: { ...env, CRE_CALLDATA: input } }]) {
    const result = run(root, 'cre-attach-params', options);
    assert.equal(result.status, 0, result.stderr);
    const before = decode(input), after = decode(result.stdout.trim());
    const attrs = JSON.parse(Buffer.from(after[7].slice(2), 'hex').toString());
    assert.deepEqual(attrs, { v: 'cre-attest/3', config: digest(config), source: digest(source) });
    after[7] = before[7];
    assert.deepEqual(after, before);
  }
});

test('attach refuses existing attributes and malformed calldata', t => {
  const root = fixture(t);
  let result = run(root, 'cre-attach-params', { input: calldata('0x1234') + '\n' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Refusing to overwrite/);
  result = run(root, 'cre-attach-params', { input: '0x1234\n' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Expected raw upsertWorkflow calldata/);
});

test('env-doctor reports key variable names without exposing either value', t => {
  const root = fixture(t);
  // No real dotenv files or RPC bindings; just returns no address anchors.
  fs.writeFileSync(path.join(root, 'bin/just'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  const canonical = 'test-canonical-secret', legacy = 'test-legacy-secret';
  for (const vars of [{ L2_AUTOMATION_OWNER_PRIVATE_KEY: canonical, L2_AUTOMATION_OWNER_PK: legacy },
    { L2_AUTOMATION_OWNER_PK: legacy }, {}]) {
    const result = run(root, 'env-doctor', { env: { ...env, PATH: root + '/bin:' + env.PATH, ...vars } });
    assert.equal(result.status, 1); // RPC is deliberately absent.
    const output = result.stdout + result.stderr;
    assert(!output.includes(canonical));
    assert(!output.includes(legacy));
    if (vars.L2_AUTOMATION_OWNER_PRIVATE_KEY)
      assert.match(output, /key = set \(via L2_AUTOMATION_OWNER_PRIVATE_KEY\)/);
    else if (vars.L2_AUTOMATION_OWNER_PK)
      assert.match(output, /key = set \(via L2_AUTOMATION_OWNER_PK\)/);
    else assert.match(output, /Automation Owner key unset/);
  }
});
