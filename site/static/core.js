import { ADMIN_ROLE, CONTROL_OWNER, CRE_AUTHOR, DAO_AGENT, L1, LANES, LOL, SYNC_ROLE, TRIGGER_SYNC_SEL } from './config.js';
import { bal, call, decAddr, decBool, decU, pad, rpcBatch, SEL } from './rpc.js';
import { syncVolumeStatus, syncVolumeValue } from './sync-volume.js';
import { ago, alink, chip, esc, fmtEth, holder, ICO, laneWho, legendHtml, netName, setOverviewStatus, setTabStatus, short, viewRefresh, worst } from './ui.js';

// ── Overview and Access Control ──────────────────────────────────────────────
function ownerCheck(actual, target) {
  if (!actual) return ['crit', 'unreadable'];
  const a = actual.toLowerCase();
  if (target.toLowerCase() !== a) return ['crit', holder(actual)];
  return ['ok', holder(actual)];
}

// ── Data ─────────────────────────────────────────────────────────────────────
export async function laneData(L) {
  const q = [
    call(L.sender, SEL.getOraclePool),                                   // 0
    call(L.sender, SEL.hasRole + pad(ADMIN_ROLE) + pad(L.gov)),          // 1
    call(L.sender, SEL.hasRole + pad(SYNC_ROLE) + pad(L.syncTrigger)),   // 2
    call(L.sender, SEL.hasRole + pad(SYNC_ROLE) + pad(L.retiredSyncTrigger)), // 3
    call(L.sender, SEL.hasRole + pad(SYNC_ROLE) + pad(L.oldAutomation)), // 4
    call(L.proxyAdmin, SEL.owner),                                       // 5
    call(L.syncTrigger, SEL.owner),                                      // 6
    call(L.syncTrigger, SEL.getForwarder),                               // 7
    call(L.syncTrigger, SEL.getLastExecution),                           // 8
    call(L.syncTrigger, SEL.getDelay),                                   // 9
    call(L.syncTrigger, SEL.getAmounts),                                 // 10
    call(L.syncTrigger, SEL.getMaxFees),                                 // 11
    call(L.syncTrigger, SEL.shouldSyncAmount),                           // 12
    call(L.syncTrigger, SEL.canSync),                                    // 13
    call(L.creReceiver, SEL.owner),                                      // 14
    call(L.creReceiver, SEL.getForwarder),                               // 15
    call(L.creReceiver, SEL.getExpectedAuthor),                          // 16
    call(L.creReceiver, SEL.isCallAllowed + pad(L.syncTrigger) + TRIGGER_SYNC_SEL.replace('0x', '').padEnd(64, '0')), // 17
    call(L.pool, SEL.owner),                                             // 18
    call(L.weth, SEL.balanceOf + pad(L.pool)),                           // 19
    call(L.wsteth, SEL.balanceOf + pad(L.pool)),                         // 20
    bal(L.syncTrigger),                                                  // 21
  ];
  const r = await rpcBatch(L.rpc, q);
  return {
    wiredPool: decAddr(r[0]), govIsAdmin: decBool(r[1]),
    triggerHasRole: decBool(r[2]), retiredHasRole: decBool(r[3]), oldAutoHasRole: decBool(r[4]),
    proxyOwner: decAddr(r[5]), stOwner: decAddr(r[6]), stForwarder: decAddr(r[7]),
    lastExec: decU(r[8]), delay: decU(r[9]),
    minAmount: r[10] ? BigInt('0x' + r[10].slice(2, 66)) : null,
    maxAmount: r[10] ? BigInt('0x' + r[10].slice(66, 130)) : null,
    maxFees: decU(r[11]), shouldSync: decU(r[12]), canSync: decBool(r[13]),
    creOwner: decAddr(r[14]), creForwarderActual: decAddr(r[15]), creAuthor: decAddr(r[16]),
    callAllowed: decBool(r[17]), poolOwner: decAddr(r[18]),
    poolWeth: decU(r[19]), poolWsteth: decU(r[20]), float: decU(r[21]),
  };
}

async function l1Data() {
  const q = [
    call(L1.receiver, SEL.hasRole + pad(ADMIN_ROLE) + pad(DAO_AGENT)),  // 0
    call(L1.proxyAdmin, SEL.owner),                                     // 1
    bal(L1.receiver),                                                   // 2
    call(L1.wsteth, SEL.balanceOf + pad(L1.receiver)),                  // 3
    call(L1.steth, SEL.balanceOf + pad(L1.receiver)),                   // 4
  ];
  const r = await rpcBatch(L1.rpc, q);
  return { daoIsAdmin: decBool(r[0]), proxyOwner: decAddr(r[1]),
           eth: decU(r[2]), wsteth: decU(r[3]), steth: decU(r[4]) };
}

// ── Derivations ──────────────────────────────────────────────────────────────
// Checks grouped by the contract they read from (group.addr → explorer link).
function laneGroups(L, d) {
  const eq = (a, b) => a && a.toLowerCase() === b.toLowerCase();
  const cell = ([level, value], a) => ({ level, value, a: a ? a.toLowerCase() : null }); // a → holder address, linked in the matrix
  const syncRole = d.retiredHasRole || d.oldAutoHasRole ? ['crit', 'legacy holder'] // revoked at migration; a regrant = compromise
    : d.triggerHasRole ? ['ok', 'SyncTrigger'] : ['crit', 'missing'];
  return [
    { contract: 'CustomSender', addr: L.sender, checks: [
      { key: 'wired pool', sub: 'getOraclePool()', ...cell(eq(d.wiredPool, L.pool) ? ['ok', holder(L.pool, 'OraclePool')] : ['crit', holder(d.wiredPool)], d.wiredPool) },
      { key: 'admin', sub: 'DEFAULT_ADMIN_ROLE', ...cell(d.govIsAdmin ? ['ok', holder(L.gov, 'Gov Executor')] : ['crit', 'not Gov Executor'], d.govIsAdmin ? L.gov : null) },
      { key: 'sync role', sub: 'hasRole(SYNC_ROLE)', ...cell(syncRole[1] === 'SyncTrigger' ? [syncRole[0], holder(L.syncTrigger, 'SyncTrigger')] : syncRole, L.syncTrigger) },
    ] },
    { contract: 'ProxyAdmin', addr: L.proxyAdmin, checks: [
      { key: 'owner', sub: 'owner()', ...cell(eq(d.proxyOwner, L.gov) ? ['ok', holder(L.gov, 'Gov Executor')] : ['crit', holder(d.proxyOwner)], d.proxyOwner) },
    ] },
    { contract: 'SyncTrigger', addr: L.syncTrigger, checks: [
      { key: 'owner', sub: 'owner()', ...cell(ownerCheck(d.stOwner, CONTROL_OWNER), d.stOwner) },
      { key: 'forwarder', sub: 'getForwarder()', ...cell(eq(d.stForwarder, L.creReceiver) ? ['ok', holder(L.creReceiver, 'CREReceiver')] : ['crit', holder(d.stForwarder)], d.stForwarder) },
    ] },
    { contract: 'CREReceiver', addr: L.creReceiver, checks: [
      { key: 'owner', sub: 'owner()', ...cell(ownerCheck(d.creOwner, CONTROL_OWNER), d.creOwner) },
      { key: 'forwarder', sub: 'getForwarder()', ...cell(eq(d.creForwarderActual, L.creForwarder) ? ['ok', holder(L.creForwarder, 'CRE Forwarder')] : ['crit', holder(d.creForwarderActual)], d.creForwarderActual) },
      { key: 'expected author', sub: 'getExpectedAuthor()', ...cell(ownerCheck(d.creAuthor, CRE_AUTHOR), d.creAuthor) },
      { key: 'triggerSync allowed', sub: 'isCallAllowed()', ...cell(d.callAllowed ? ['ok', 'allowed'] : ['crit', 'blocked']) },
    ] },
    { contract: 'OraclePool', addr: L.pool, checks: [
      { key: 'owner', sub: 'owner()', ...cell(ownerCheck(d.poolOwner, LOL), d.poolOwner) },
    ] },
  ];
}
const laneChecks = (L, d) => laneGroups(L, d).flatMap(g => g.checks);

// Why canSync() is false — same gates the contract checks, named from data we already read.
function canSyncCause(d) {
  if (d.triggerHasRole === false) return 'SYNC_ROLE lost';
  if (d.float != null && d.maxFees != null && d.float < d.maxFees) return 'float below maxFees';
  if (d.triggerHasRole == null || d.float == null || d.maxFees == null) return 'gate unreadable';
  return 'pool paused'; // the only remaining canSync gate
}

function syncState(d) {
  if (d.shouldSync == null || d.canSync == null) return ['crit', 'UNREADABLE', 'probe failed'];
  if (d.shouldSync > 0n && !d.canSync) return ['crit', 'BLOCKED', fmtEth(d.shouldSync, 2) + ' WETH due — ' + canSyncCause(d)];
  if (d.shouldSync > 0n) return ['warn', 'DUE', fmtEth(d.shouldSync, 2) + ' WETH, awaiting DON'];
  if (!d.canSync) return ['warn', 'IMPAIRED', canSyncCause(d)];
  if (d.delay != null && d.lastExec != null && BigInt(Math.floor(Date.now() / 1000)) < d.lastExec + d.delay)
    return ['ok', 'COOLDOWN', 'delay window active'];
  return ['ok', 'IDLE', 'pool below min amount'];
}

function floatState(d) {
  if (d.float == null || d.maxFees == null || d.maxFees === 0n) return { level: 'crit', x: null };
  const x = Number(d.float) / Number(d.maxFees);
  return { level: x >= 1.5 ? 'ok' : x >= 1 ? 'warn' : 'crit', x };
}

function l1AccessChecks(d) {
  const [pl, pv] = ownerCheck(d.proxyOwner, DAO_AGENT);
  return [
    { key: 'Receiver admin', level: d.daoIsAdmin ? 'ok' : 'crit',
      value: d.daoIsAdmin ? holder(DAO_AGENT) : 'not DAO Agent', sub: 'DEFAULT_ADMIN_ROLE' },
    { key: 'ProxyAdmin owner', level: pl, value: pv, sub: 'owner()' },
  ];
}

function l1BalanceChecks(d) {
  const balRow = (label, v, unit = label.replace('Receiver ', '')) => ({
    key: label,
    ...(v == null ? { level: 'crit', value: 'unreadable', sub: '' }
      : v > 10n ** 18n ? { level: 'crit', value: `${fmtEth(v)} ${unit}`, sub: 'parked > 1' }
      : v > 10n ** 12n ? { level: 'warn', value: `${fmtEth(v, 6)} ${unit}`, sub: 'transient?' }
      : { level: 'ok', value: '~0', sub: 'as expected' }),
  });
  return [
    balRow('Receiver ETH', d.eth), balRow('Receiver wstETH', d.wsteth), balRow('Receiver stETH', d.steth),
  ];
}

function render(l1, lanes) {
  const laneOverviewLevels = lanes.map(l => l.error
    ? 'crit'
    : worst([syncState(l.d)[0], floatState(l.d).level]));

  const overviewLevel = worst([
    l1.error ? 'crit' : worst([...l1BalanceChecks(l1.d), ...l1AccessChecks(l1.d)].map(c => c.level)),
    ...laneOverviewLevels,
  ]);
  const accessLevel = worst(lanes.map(l => l.error ? 'crit' : worst(laneChecks(l.L, l.d).map(c => c.level))));
  setOverviewStatus('core', overviewLevel);
  setTabStatus('access', accessLevel === 'ok' ? null : accessLevel);

  const rpcOk = [l1, ...lanes].filter(x => !x.error).length;
  document.getElementById('rpcstat').innerHTML =
    `<span class="dot ${rpcOk === 5 ? 'ok' : 'crit'}"></span> RPC ${rpcOk}/5`;

  // hero numbers
  const live = lanes.filter(l => !l.error);
  const crits = laneOverviewLevels.filter(level => level === 'crit').length;
  const warns = laneOverviewLevels.filter(level => level === 'warn').length;
  const healthy = LANES.length - crits;
  const totalWeth = live.reduce((s, l) => s + (l.d.poolWeth ?? 0n), 0n);
  const synced = syncVolumeStatus();

  const hero = `<div class="card hero">
    <div>
      <h2 class="serif">Sync &amp; custody</h2>
      <p>WETH accumulates on L2 and syncs to L1 for staking.</p>
      ${viewRefresh('main', 'Overview')}
    </div>
    <div class="stat">
      <div class="k">Lanes healthy</div>
      <div class="v serif">${healthy}<span style="color:var(--muted)">/${LANES.length}</span></div>
      <div class="s">${crits ? crits + ' critical' : 'no critical lanes'}${warns ? ' · ' + warns + ' warn' : ''}</div>
    </div>
    <div class="stat tinted">
      <div class="k">Pool WETH</div>
      <div class="v serif">${fmtEth(totalWeth, 2)} <span class="unit">WETH</span></div>
      <div class="s">across 4 lanes</div>
    </div>
    <div class="stat ${synced.level}" id="sync-volume">
      <div class="k" title="Cumulative amount emitted by CustomSender.Sync across all lanes">Synced to L1</div>
      <div class="v serif${synced.loading ? ' loading' : ''}" role="status" aria-live="polite" aria-busy="${!!synced.loading || synced.refreshing}">${syncVolumeValue(synced)}</div>
      <div class="s sync-volume-sub"><span class="sync-volume-text">${synced.sub}</span><span class="spin" aria-hidden="true"${synced.refreshing ? '' : ' hidden'}></span></div>
    </div>
  </div>`;

  // sync matrix
  const num = (m, s) => `<span class="num"><div class="m">${m}</div><div class="s">${s}</div></span>`;
  const syncRows = lanes.map(l => {
    if (l.error) return `<tr><td>${laneWho(l.L)}</td><td colspan="4"><span class="chip crit"><div class="m">✕ RPC error</div><div class="s">${esc(l.error)}</div></span></td></tr>`;
    const d = l.d, [slv, sm, ss] = syncState(d), f = floatState(d);
    return `<tr>
      <td>${laneWho(l.L)}</td>
      <td>${chip(slv, sm, slv === 'ok' ? 'last sync ' + ago(d.lastExec) : ss)}</td>
      <td>${num(fmtEth(d.poolWeth, 2) + ' WETH', d.minAmount != null ? `min ${fmtEth(d.minAmount, 0)} · max ${fmtEth(d.maxAmount, 0)}` : '—')}</td>
      <td>${num(fmtEth(d.poolWsteth, 2) + ' wstETH', 'fastStake liquidity')}</td>
      <td>${chip(f.level, f.x != null ? f.x.toFixed(2) + '× maxFees' : '—', fmtEth(d.float) + ' ETH on trigger')}</td>
    </tr>`;
  }).join('');

  const syncCard = `<div class="card">
    <div class="card-head">
      <h3>Sync Matrix</h3>
      ${legendHtml()}
    </div>
    <div class="scroll-x"><table class="syncm">
      <tr><th>Lane</th><th>Sync state</th><th>Pool WETH</th><th>Pool wstETH</th><th title="ok ≥ 1.5× · warn ≥ 1× · critical &lt; 1×">Fee float</th></tr>
      ${syncRows}
    </table></div>
  </div>`;

  // ownership matrix: rows = checks grouped by contract, columns = lanes.
  // These are tripwires, not daily reads — deviations surface on top, the green wall folds away.
  const perLane = lanes.map(l => l.error ? null : laneGroups(l.L, l.d));
  const okLane = lanes.find(l => !l.error);
  const template = laneGroups(okLane?.L ?? LANES[0], okLane?.d ?? {});
  const laneAddrs = lanes.map(l => laneGroups(l.L, {}).map(g => g.addr));

  const checkRow = (gi, ci, row) => `<tr>
    <td class="rowlabel">${row.key}<span class="sub mono">${row.sub}</span></td>
    ${perLane.map((cs, li) => {
      if (!cs) return '<td>—</td>';
      const c = cs[gi].checks[ci];
      const inner = chip(c.level, c.value, c.a ? `<span class="mono">${short(c.a)}&thinsp;↗</span>` : null);
      return `<td>${c.a ? `<a class="chiplink" href="${lanes[li].L.explorer}/address/${c.a}" target="_blank" title="${c.a}">${inner}</a>` : inner}</td>`;
    }).join('')}
  </tr>`;
  const buildTable = filter => `<table class="ownm">
    <tr><th>Check</th>${lanes.map(l => `<th>${netName(l.L)}</th>`).join('')}</tr>
    ${template.map((g, gi) => {
      const rows = g.checks.map((row, ci) => ({ row, ci })).filter(({ ci }) => filter(gi, ci));
      if (!rows.length) return '';
      return `<tr class="group"><td class="gname">${g.contract}</td>` +
        lanes.map((l, li) => `<td><a href="${l.L.explorer}/address/${laneAddrs[li][gi]}" target="_blank" title="${laneAddrs[li][gi]}">${short(laneAddrs[li][gi])}&thinsp;↗</a></td>`).join('') +
        '</tr>' + rows.map(({ row, ci }) => checkRow(gi, ci, row)).join('');
    }).join('')}
  </table>`;

  const deviates = (gi, ci) => perLane.some(cs => cs && cs[gi].checks[ci].level !== 'ok');
  const nDev = template.flatMap((g, gi) => g.checks.filter((_, ci) => deviates(gi, ci))).length;
  const nChecks = template.reduce((s, g) => s + g.checks.length, 0);
  const unreachable = lanes.filter(l => l.error).map(l => l.L.name);
  const reachNote = unreachable.length ? ` · ${unreachable.join(', ')} unreachable` : '';

  const ownCard = `<div class="card">
    <div class="card-head">
      <h3>Ownership &amp; Wiring</h3><span class="desc">On-chain values vs expected. ${ICO.contract} contract · ${ICO.safe} Safe</span>
      ${viewRefresh('access', 'Access Control')}
    </div>
    ${nDev ? `<div class="err-banner">✕ ${nDev} of ${nChecks} checks deviate from target${reachNote}</div>` : ''}
    <div class="scroll-x">${buildTable(() => true)}</div>
  </div>`;

  // One L1 card on Overview: the shared receiver's balances and its roles.
  const l1Metrics = (checks, grid, label) => `<div class="l1-metric-grid ${grid}">${checks.map(c => `<div class="l1-metric ${c.level}">
        <div class="l1-metric-label">${label(c.key)}</div>
        ${chip(c.level, c.value, c.sub)}
      </div>`).join('')}</div>`;
  const l1Body = l1.error
    ? `<div class="err-banner">RPC error: ${esc(l1.error)}</div>`
    : l1Metrics(l1BalanceChecks(l1.d), 'l1-balance-grid', key => key.replace('Receiver ', '')) +
      l1Metrics(l1AccessChecks(l1.d), 'l1-access-grid', key => key);
  const l1Card = `<div class="card l1-card">
    <div class="card-head">
      <div class="l1-card-copy">
        <h3>${netName(L1)}</h3>
        <span class="desc">Shared receiver balances and access control</span>
      </div>
      <span class="l1-card-links">${alink(L1, L1.receiver, 'LidoCustomReceiver')} ${alink(L1, L1.proxyAdmin, 'ProxyAdmin')}</span>
    </div>${l1Body}</div>`;

  document.getElementById('overview-cards').innerHTML = hero + syncCard + l1Card;
  document.getElementById('access').innerHTML = ownCard;
}

async function readCoreState() {
  const [l1, ...lanes] = await Promise.all([
    l1Data().then(d => ({ d })).catch(e => ({ error: e.message })),
    ...LANES.map(L => laneData(L).then(d => ({ L, d })).catch(e => ({ L, error: e.message }))),
  ]);
  return { l1, lanes };
}
export async function refreshOverviewAccess() {
  const { l1, lanes } = await readCoreState();
  render(l1, lanes);
  return lanes;
}
