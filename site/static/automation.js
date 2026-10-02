import { AUTO_SAFE, COMMON_DEPLOYED, CRE_CONFIG_JSON, CRE_CONFIG_SHA256, CRE_DEPLOYED_SOURCE_SHA256, CRE_WORKFLOW_NAME, DON_FAMILY, LANES, RPC_DEFAULTS, SYNC_TOPIC, TRIGGER_SYNC_SEL } from './config.js';
import { laneData } from './core.js';
import { creConfigSha, findConsolidated, paramsAgreement, parseAttributes, registryData, regsUsable, WF } from './registry.js';
import { decBool, decU, rpcBatch, rpcBatchChunks, rpcFetch } from './rpc.js';
import { SHA256_OK } from './sha256.js';
import { syncAmount } from './sync-volume.js';
import { ago, chip, esc, fmtEth, holder, laneWho, legendHtml, netLogo, setTabStatus, short, viewRefresh, who, worst } from './ui.js';

// ── CRE control plane events (CREReceiver lifecycle) ─────────────────────────
// Matched on topics[0], NOT on Blockscout's `decoded` field: the Linea explorer returns
// `decoded: null` for these events. Every argument this tab shows is indexed, so topics suffice.
const EXEC_TOPIC = '0xbe82131bb3404498c769b0511da41a4ad409fa7152562c2b6669241cbe3bb884';
const EVT = {
  [EXEC_TOPIC]:                                                           { label: 'Report executed', kind: 'exec' },
  '0x3321cda85c145617e47418aa14255e9dcbec53a753778e57591703b89a3cad31':   { label: 'Expected author', kind: 'gate' },
  '0xfbea789d6a139c51ef0f88cde81c3881e90e894fde6c8665726e118af8b13c35':   { label: 'Forwarder', kind: 'gate' },
  '0xb35b8e3487df8622d32523c450283db1844a7a279925f30df21d27bc116189d7':   { label: 'Allowed call', kind: 'gate' },
  '0x94b2de810873337ed265c5f8cf98c9cffefa06b8607f9a2f1fbaebdfbcfbef1c':   { label: 'ETH withdrawn', kind: 'flow' },
  '0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0':   { label: 'Owner', kind: 'gate' },
};

// `CallExecuted` names the call but carries none of its payload: the WETH a sync moved is emitted one
// hop away, by CustomSender's own `Sync(address,uint64,bytes32,uint256)` in the SAME transaction. Read
// it from that log rather than re-deriving it from a pool balance — what moved is a fact OF the
// transaction, while a balance read afterwards is a different claim about a different moment.
// SYNC_TOPIC and syncAmount() below are the ones the Overview tile already reads: one decoder for the
// one event, so a per-sync row and the cumulative total can never disagree about what a Sync says.

// Blockscout v2 returns the emitting address as an object here and as a bare string elsewhere.
const logAddr = i => (typeof i?.address === 'string' ? i.address : i?.address?.hash ?? i?.address_hash ?? '');

// Anchored on the CustomSender that emitted it: another contract's Sync in the same transaction is a
// different lane's fact. Returns null when the logs were read and hold no such event.
const syncWeiOf = (logs, L) => {
  const log = (logs ?? []).find(i => (i.topics?.[0] ?? '').toLowerCase() === SYNC_TOPIC
    && logAddr(i).toLowerCase() === L.sender.toLowerCase());
  const amount = log ? syncAmount(log) : null;
  return amount == null ? null : amount.toString();
};

// Three outcomes, three DIFFERENT claims, none allowed to read as another:
//   e.wei = "<decimal>"  → the Sync log was read; this is the amount it names
//   e.wei = null         → the tx's logs were read and hold no Sync from this lane's CustomSender —
//                          an anomaly (the call executed but moved nothing), never shown as `0`
//   e.amtUnread = true   → the source did not answer; unknown, and it says so rather than blank
async function attachSyncAmounts(L, rows) {
  // Amounts are immutable once mined, so a previously read one is re-shown rather than re-fetched;
  // only a successful read (a string) is reused — a null is retried in case the source was lagging.
  const known = new Map((automation.logs[L.name] ?? [])
    .filter(e => typeof e.wei === 'string').map(e => [e.tx, e.wei]));
  // Selector, not target: an exec against the RETIRED trigger moved WETH just the same, and the amount
  // is anchored on the CustomSender that emitted it, not on which trigger was called.
  const syncs = rows.filter(e => e.topic === EXEC_TOPIC && '0x' + (e.topics[2] ?? '').slice(2, 10) === TRIGGER_SYNC_SEL);
  syncs.forEach(e => { if (known.has(e.tx)) e.wei = known.get(e.tx); });
  const todo = syncs.filter(e => e.wei === undefined && e.tx);
  if (!todo.length) return;
  // Receipts contain the complete transaction logs without separate explorer requests.
  let receipts = [];
  try {
    const receiptRpc = L.rpc === RPC_DEFAULTS[L.name] ? (L.receiptsRpc ?? L.rpc) : L.rpc;
    receipts = await rpcBatchChunks(receiptRpc,
      todo.map(e => ({ method: 'eth_getTransactionReceipt', params: [e.tx] })));
  } catch { todo.forEach(e => { e.amtUnread = true; }); return; }
  todo.forEach((e, i) => {
    const r = receipts[i];
    if (!r || !Array.isArray(r.logs)) { e.amtUnread = true; return; }
    e.wei = syncWeiOf(r.logs, L);
  });
}

// Explorer and cached rows end up in links and labels, so only well-formed hex passes.
const HASH = /^0x[0-9a-f]{64}$/i;
const wellFormed = e => HASH.test(e.tx ?? '') && e.topics.every(t => t == null || HASH.test(t)) &&
  /^0x[0-9a-f]*$/i.test(e.data ?? '');

async function automationLogs(L) {
  // The whole CREReceiver history is ~8 events per lane, so one query is the full record.
  const res = await rpcFetch(`${L.bs}/api/v2/addresses/${L.creReceiver}/logs`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const page = await res.json();
  const rows = (page.items ?? [])
    .filter(i => EVT[(i.topics?.[0] ?? '').toLowerCase()])
    .map(i => ({
      topic: i.topics[0].toLowerCase(), topics: i.topics.map(t => t && t.toLowerCase()),
      data: i.data, block: i.block_number, tx: i.transaction_hash,
      ts: i.block_timestamp ? Math.floor(Date.parse(i.block_timestamp) / 1000) : null,
    }))
    .filter(wellFormed);
  // Linea's explorer also omits block_timestamp here; backfill from the lane's own RPC by block.
  const missing = [...new Set(rows.filter(r => r.ts == null && r.block != null).map(r => r.block))];
  if (missing.length) {
    const calls = missing.map(n =>
      ({ method: 'eth_getBlockByNumber', params: ['0x' + n.toString(16), false] }));
    const blocks = await rpcBatch(L.rpc, calls);
    const stamps = new Map(missing.map((n, i) => [n, blocks[i]?.timestamp ? Number(BigInt(blocks[i].timestamp)) : null]));
    rows.forEach(r => { if (r.ts == null) r.ts = stamps.get(r.block) ?? null; });
  }
  await attachSyncAmounts(L, rows);
  return rows.sort((a, b) => (b.ts ?? 0) - (a.ts ?? 0));
}

// ── Automation ───────────────────────────────────────────────────────────────
// Three planes, three verdicts, deliberately never merged into one light: the registry read ACTIVE
// throughout the 2026-08-13 → 08-16 window in which the author gate rejected every report. A lane is
// only as good as its weakest plane, and registration never carries that verdict on its own.
const AUTOMATION_CACHE_KEY = 'direct-staking-watch.automation-cache';
// How long a lane may sit DUE before "waiting for the next tick" becomes "stalled". This is DERIVED
// from the schedules the workflow actually runs, not fixed: the consolidation moved every lane from a
// 5-minute cron to one hourly cron, and a 30-minute window against an hourly tick would raise a
// critical on essentially every healthy sync — a lane goes due at `lastExecution + delay`, which has no
// relation to its minute-of-hour slot, so a normal wait is up to a full period.
//
// Floor and slack are deliberate: never tighter than the old 30 minutes, and always a quarter-hour
// beyond one full tick period, so RPC lag or a skipped tick is late rather than "undelivered".
const DUE_GRACE_FLOOR_S = 1800;
const DUE_GRACE_SLACK_S = 900;
function dueGraceSeconds(lanes) {
  const periods = (Array.isArray(lanes) ? lanes : []).map(l => cdCron(l?.schedule).periodSec);
  // An unreadable schedule must widen the window, never narrow it: a day is the longest period this
  // page can gloss, and reporting "stalled" off a cron nobody parsed would be a verdict with no basis.
  if (!periods.length || periods.some(p => p == null)) return Math.max(DUE_GRACE_FLOOR_S, 86400 + DUE_GRACE_SLACK_S);
  return Math.max(DUE_GRACE_FLOOR_S, Math.max(...periods) + DUE_GRACE_SLACK_S);
}
// A cached `wei` is fed to BigInt() by the renderer and localStorage is persistent, attacker-adjacent
// input: anything but a plain decimal string — or the `null` that means "read, no Sync log" — would
// throw mid-render and strand the tab. Downgrade an implausible one to "unread", a claim the next
// refresh re-reads, rather than trusting it or dropping the row that carries it. A row that never
// carried an amount (any event but a sync) is left exactly as it is.
const sanitizeWei = e => !('wei' in e) || e.wei === null || (typeof e.wei === 'string' && /^\d+$/.test(e.wei))
  ? e : { ...e, wei: undefined, amtUnread: true };
export const automation = { regs: null, regError: null, lanes: null, logs: readAutomationCache(), logErrors: [] };
// The registered record's attestation, published by renderAutomation for the artifact checker.
export let regAttest = null;

// The cache is persistent attacker-adjacent input: validate its SHAPE, not just that it parsed. A row
// whose topic is not in EVT would throw inside renderAutomation and strand the tab on its loader
// across every reload until localStorage is cleared by hand.
function readAutomationCache() {
  try {
    const cache = JSON.parse(localStorage.getItem(AUTOMATION_CACHE_KEY));
    if (!cache || typeof cache !== 'object') return {};
    return Object.fromEntries(Object.entries(cache)
      .filter(([name, rows]) => LANES.some(L => L.name === name) && Array.isArray(rows))
      .map(([name, rows]) => [name, rows.filter(e => e && EVT[e.topic] && Array.isArray(e.topics) && wellFormed(e)).map(sanitizeWei)]));
  } catch { return {}; }
}
function saveAutomationCache() {
  try { localStorage.setItem(AUTOMATION_CACHE_KEY, JSON.stringify(automation.logs)); } catch {}
}

// Which registration governs THIS lane: the one consolidated record, which stands for all four. The
// superseded per-lane records are deliberately NOT consulted — a lane is reported against the layout
// that is meant to drive it, and a retired record standing in for it would read as a working lane.
const laneWorkflow = regs => findConsolidated(regs);

const acctFor = (regs, addr) => (regs ?? []).find(a => addr && a.owner.toLowerCase() === addr.toLowerCase()) ?? null;
const execEvents = name => (automation.logs[name] ?? []).filter(e => e.topic === EXEC_TOPIC);

// The six conjuncts of the author gate. Each is one atomic claim; the composite is their conjunction,
// governed by the weakest link — never an average, never the best of them.
function gateChecks(L, d, regs) {
  const eq = (a, b) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
  const read = regsUsable(regs);
  const author = d.creAuthor;
  const wf = laneWorkflow(regs);
  const linked = acctFor(regs, author)?.linked;
  const cell = (key, sub, chain, verdict, a) => ({ key, sub, chain, ...verdict, a: a ? a.toLowerCase() : null });
  return [
    cell('owner link-registered', 'isOwnerLinked(author)', 'L1',
      linked == null ? { level: 'warn', value: 'unread' }
        : linked ? { level: 'ok', value: 'linked' } : { level: 'crit', value: 'NOT linked' }, author),
    cell('registry owner = author', 'workflow.owner ↔ getExpectedAuthor()', 'L1↔L2',
      !read ? { level: 'warn', value: 'unread' }
        : !wf ? { level: 'crit', value: 'no workflow' }
        : eq(wf.t[WF.owner], author) ? { level: 'ok', value: holder(author) }
        : { level: 'crit', value: holder(wf.t[WF.owner]) }, wf ? wf.t[WF.owner] : null),
    cell('forwarder accepted', 'CREReceiver.getForwarder()', 'L2',
      eq(d.creForwarderActual, L.creForwarder) ? { level: 'ok', value: holder(L.creForwarder, 'CRE Forwarder') }
        : { level: 'crit', value: holder(d.creForwarderActual) }, d.creForwarderActual),
    cell('triggerSync allow-listed', 'isCallAllowed()', 'L2',
      d.callAllowed ? { level: 'ok', value: 'allowed' } : { level: 'crit', value: 'blocked' }, null),
    cell('trigger accepts receiver', 'SyncTrigger.getForwarder()', 'L2',
      eq(d.stForwarder, L.creReceiver) ? { level: 'ok', value: holder(L.creReceiver, 'CREReceiver') }
        : { level: 'crit', value: holder(d.stForwarder) }, d.stForwarder),
    cell('SYNC_ROLE held', 'CustomSender.hasRole()', 'L2',
      d.triggerHasRole ? { level: 'ok', value: 'held' } : { level: 'crit', value: 'revoked' }, L.syncTrigger),
  ];
}

// Registration is a RECORD. It warrants "the DON should run this" and nothing about acceptance or delivery.
function registrationChecks(L, regs) {
  if (!regsUsable(regs)) return { level: 'warn', rows: null, unread: true };
  const wf = laneWorkflow(regs);
  if (!wf) return { level: 'crit', rows: null, unread: false };
  const t = wf.t;
  const status = t[WF.status] === 0n ? { level: 'ok', value: 'ACTIVE' }
    : { level: 'crit', value: t[WF.status] === 1n ? 'PAUSED' : `status ${t[WF.status]}` };
  const don = t[WF.donFamily] === DON_FAMILY ? { level: 'ok', value: t[WF.donFamily] }
    : { level: 'crit', value: esc(t[WF.donFamily]) || '—' };
  // The tag is what `cre workflow deploy` registered; a tag that stops matching the name means the
  // registration no longer describes the lane it is named for.
  const tag = t[WF.tag] === t[WF.name] ? { level: 'ok', value: 'tag = name' }
    : { level: 'crit', value: 'tag ≠ name', sub: esc(t[WF.tag]) || '(empty)' };
  return { level: worst([status.level, don.level, tag.level]), rows: { t, status, don, tag } };
}

// Absence of a delivery is NOT failure: the workflow signs only when a sync is due. Only the
// conjunction "due AND executable AND nothing landed" is a real stall.
//
// The idle state is named IDLE, never "delivering". A lane whose last report is weeks old is not
// delivering anything — it has nothing to deliver, which is a different claim, and collapsing the two
// would smuggle liveness back in through a label after the card structure took it out.
function deliveryState(L, d, graceS) {
  const execs = execEvents(L.name);
  const last = execs.length ? execs[0].ts : null;
  const now = Math.floor(Date.now() / 1000);
  // Missing history is checked FIRST: with no logs there is no delivery evidence either way, and a
  // "nothing landed" verdict read off an unfetched history is absence-of-evidence dressed as evidence.
  if (!Array.isArray(automation.logs[L.name]))
    return { level: 'warn', label: 'UNKNOWN', n: null, last: null, note: 'delivery history not loaded' };
  if (d.shouldSync == null || d.canSync == null)
    return { level: 'warn', label: 'UNKNOWN', n: execs.length, last, note: 'sync predicates unreadable' };
  if (d.shouldSync > 0n && !d.canSync)
    return { level: 'warn', label: 'DUE, BLOCKED', n: execs.length, last,
      note: 'blocked on-chain, not by the DON — see Overview' };
  // The grace window runs from the moment the lane BECAME due (lastExecution + delay), never from the
  // last delivery: shouldSyncAmount() only goes non-zero once the 12h delay has elapsed, so measuring
  // staleness against the last report would make every normal sync window fire this critical.
  const dueSince = d.lastExec != null && d.delay != null ? Number(d.lastExec + d.delay) : null;
  const overdue = dueSince != null && now - dueSince > graceS;
  if (d.shouldSync > 0n && d.canSync && overdue)
    return { level: 'crit', label: 'DUE, UNDELIVERED', n: execs.length, last,
      note: `${fmtEth(d.shouldSync, 2)} WETH due for ${ago(dueSince).replace(' ago', '')} — past the ${
        Math.round(graceS / 60)} min this cadence allows, no report` };
  if (d.shouldSync > 0n)
    return { level: 'ok', label: 'DUE', n: execs.length, last, note: 'awaiting the next DON tick' };
  if (!execs.length)
    return { level: 'warn', label: 'NEVER DELIVERED', n: 0, last, note: 'no accepted report' };
  return { level: 'ok', label: 'IDLE', n: execs.length, last, note: 'nothing due' };
}

// One event's human reading, from indexed topics only — Linea's explorer decodes nothing for us.
// Every field is READ from the log, never assumed: this is the card that has to stay truthful when
// someone with the owner key allow-lists a call that is not triggerSync().
const SELECTORS = { [TRIGGER_SYNC_SEL]: 'triggerSync()' };
const selName = t => {
  if (!t) return '<span class="chip crit">unreadable selector</span>';
  const sel = '0x' + t.slice(2, 10);
  return SELECTORS[sel] ?? `<span class="chip crit">unknown call ${sel}</span>`;
};
function eventDetail(e) {
  const addr = t => t ? '0x' + t.slice(-40) : null;
  // holder() resolves the name from the ADDRESS via NAMES; an unrecognised target stays a short hex
  // string rather than borrowing a label it did not earn.
  if (e.topic === EXEC_TOPIC) {
    const call = `${selName(e.topics[2])} on ${holder(addr(e.topics[1]))}`;
    // A sync's size is part of what the row reports, so an unread or absent amount is SAID, not blank.
    if (typeof e.wei === 'string') return `${call} · <strong>${fmtEth(BigInt(e.wei))} WETH</strong>`;
    if (e.wei === null) return `${call} · <span class="chip warn"><div class="m">⚠ no Sync event</div></span>`;
    if (e.amtUnread) return `${call} · <span style="color:var(--muted)">amount unread</span>`;
    return call;
  }
  if (e.topic === '0xb35b8e3487df8622d32523c450283db1844a7a279925f30df21d27bc116189d7')
    return `${selName(e.topics[2])} on ${holder(addr(e.topics[1]))} → ${decBool(e.data) ? 'allowed' : 'blocked'}`;
  if (e.topic === '0x94b2de810873337ed265c5f8cf98c9cffefa06b8607f9a2f1fbaebdfbcfbef1c')
    return `${e.data && e.data !== '0x' ? fmtEth(decU(e.data)) : '—'} ETH → ${holder(addr(e.topics[1]))}`;
  return `${holder(addr(e.topics[1]))} → ${holder(addr(e.topics[2]))}`;
}

function renderAutomation() {
  const lanes = automation.lanes;
  if (!lanes) return; // the log fetch alone cannot draw the planes; first paint comes from refresh()
  const regs = automation.regs;

  // Resolved before anything renders, because the delivery verdict depends on it: the chain's published
  // params if the record carries them, this repo's copy otherwise. Both the grace window below and the
  // Deployed Parameters card read this one answer, so they cannot disagree about which cadence is live.
  const cons = findConsolidated(regs);
  const attrsHex = cons ? cons.t[WF.attributes] : null;
  const attrs = parseAttributes(attrsHex);
  regAttest = attrs.kind === 'attest' ? attrs.a : null;   // what the artifact checker verifies against
  const repoParams = (() => { try { return JSON.parse(CRE_CONFIG_JSON); } catch { return null; } })();
  // Only the verbatim-config payload puts parameters on the chain; under an attestation the table is
  // this repo's copy, vouched for by a digest. Three states, not two, and the label says which.
  const paramsSrc = (attrs.kind === 'config' ? attrs.config : null) ?? repoParams;
  const paramsOrigin = attrs.kind === 'config' ? 'chain'
    : (attrs.kind === 'attest' && attrs.a.config === creConfigSha) ? 'attested' : 'repo';
  const paramsFromChain = paramsOrigin === 'chain';
  const graceS = dueGraceSeconds(paramsSrc?.lanes);

  const perLane = lanes.map(l => l.error ? null : ({
    L: l.L, d: l.d,
    reg: registrationChecks(l.L, regs),
    gate: gateChecks(l.L, l.d, regs),
    del: deliveryState(l.L, l.d, graceS),
  }));
  const armed = perLane.filter(p => p && p.gate.every(c => c.level === 'ok'));
  const active = perLane.filter(p => p && p.reg.rows && p.reg.rows.status.level === 'ok');
  const lastDelivery = perLane.reduce((m, p) => Math.max(m, p?.del.last ?? 0), 0) || null;
  const regsRead = regsUsable(regs);
  // "unread" is not a count and "never" is not "not fetched" — each tile states which it is.
  const deliveryRead = LANES.every(L => Array.isArray(automation.logs[L.name])) && !automation.logErrors.length;
  // Name the conjunct that actually blocks, rather than assuming the reason.
  const gateBlocked = [...new Set(perLane.filter(Boolean)
    .map(p => p.gate.find(c => c.level === 'crit')?.key).filter(Boolean))];

  // ── Card A2 — the parameters the registered workflow runs on ──
  // Source order is deliberate: whatever the RECORD publishes wins over this repo's copy, because the
  // question is what is deployed, not what is declared here. The repo copy is the fallback, and it is
  // labelled as such — a lane table with no chain backing must never read like a chain reading.

  // Row 1 — is there a record at all. "Not registered yet" is the EXPECTED state until the Safe executes
  // the upsert, so it is stated as a fact and kept out of the tab's status: an unstarted step is not a fault.
  const recRow = !regsUsable(regs)
    ? { level: 'warn', html: chip('warn', 'registry unread', 'L1 read failed — record state unknown'), count: true }
    : !cons
      ? { level: 'ok', html: chip('', 'not registered yet', `no workflow named ${esc(CRE_WORKFLOW_NAME)} under ${who(AUTO_SAFE)}`), count: false }
      : { level: cons.t[WF.status] === 0n ? 'ok' : 'warn',
          html: chip(cons.t[WF.status] === 0n ? 'ok' : 'warn',
            cons.t[WF.status] === 0n ? 'ACTIVE' : cons.t[WF.status] === 1n ? 'PAUSED' : `status ${cons.t[WF.status]}`,
            `${holder(cons.t[WF.owner])} · registered ${ago(Number(cons.t[WF.createdAt]))}`), count: true };

  // Row 2 — are the params observable on-chain at all, and do they match this page's copy? attributes is
  // arbitrary owner-written bytes the registry never reads, which is exactly what makes it usable for
  // publishing the config verbatim — and exactly why a match is an ATTESTATION, not an oracle.
  const pubRow = !cons ? { level: 'ok', html: chip('', 'n/a', 'nothing registered to publish from'), count: false }
    : attrs.kind === 'empty'
      ? { level: 'warn', html: chip('warn', 'attributes empty', 'nothing about the deployed artifacts was published — the table below is this repo\'s copy, unconfirmed'), count: true }
    : attrs.kind === 'attest'
      // The attestation publishes DIGESTS, so the lane table below stays the repo's copy — but a copy
      // whose sha256 the record commits to is a different thing from an unchecked one, and the verdict
      // says which of the two you are looking at.
      ? (attrs.a.config === creConfigSha
          ? { level: 'ok', html: chip('ok', 'matches repo', 'config.deploy.json'), count: true }
          : { level: 'crit', html: chip('crit', 'does not match repo', `<span class="mono">${esc(String(attrs.a.config ?? '—').slice(0, 16))}…</span> ≠ <span class="mono">${creConfigSha.slice(0, 16)}…</span>`), count: true })
    : attrs.kind === 'config'
      ? (a => ({ level: a.level, html: chip(a.level, a.label, a.note + (a.level === 'ok' ? '' : ' — the table below shows the CHAIN\'s')), count: true }))(
          paramsAgreement(attrsHex, attrs.config, CRE_CONFIG_JSON, repoParams))
    : { level: 'crit', html: chip('crit', 'unrecognised payload', `${attrs.bytes} bytes that are neither an attestation nor a config`), count: true };

  // Row 3 — the page's own integrity. Recomputed here so a wrong constant cannot masquerade as agreement.
  const digRow = !SHA256_OK
    ? { level: 'crit', html: chip('crit', 'digest engine failed self-test', 'no digest on this page can be trusted'), count: true }
    : creConfigSha === CRE_CONFIG_SHA256
      ? { level: 'ok', html: chip('ok', 'matches pin', `<span class="mono">${CRE_CONFIG_SHA256.slice(0, 16)}…</span>`), count: true }
      : { level: 'crit', html: chip('crit', 'sha256 ≠ pin', `computed <span class="mono">${esc(creConfigSha.slice(0, 16))}…</span> — regenerate with just cre-workflow-hash`), count: true };

  // Row 3b — the source and binary the record attests to. Only the attestation can answer this: the
  // config alone never said WHICH code was uploaded, and the artifact store answers 403 to everyone.
  const srcRow = !cons || attrs.kind !== 'attest'
    ? { level: 'ok', html: chip('', 'not attested', 'no source digest is published for this record'), count: false }
    : (() => {
        const srcOk = attrs.a.source === CRE_DEPLOYED_SOURCE_SHA256;
        return { level: srcOk ? 'ok' : 'crit', count: true, html: chip(srcOk ? 'ok' : 'crit',
          srcOk ? 'matches deployment' : 'does not match deployment',
          srcOk ? 'main.ts · c944edc'
            : `<span class="mono">${esc(String(attrs.a.source ?? '—').slice(0, 16))}…</span> ≠ <span class="mono">${CRE_DEPLOYED_SOURCE_SHA256.slice(0, 16)}…</span>`) };
      })();

  // Row 4 — the addresses the params point at. A config that is internally valid but aims at the wrong
  // receiver would still register, still run, and never deliver: worth its own row, not a footnote.
  const addrOk = (a, b) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
  const tgtRow = !paramsSrc ? { level: 'crit', html: chip('crit', 'params unparseable', 'neither chain nor repo yielded a config'), count: true }
    : addrOk(paramsSrc.receiverAddress, COMMON_DEPLOYED.creReceiver) && addrOk(paramsSrc.targetAddress, COMMON_DEPLOYED.syncTrigger)
      ? { level: 'ok', html: chip('ok', 'addresses match', `${short(COMMON_DEPLOYED.creReceiver)} → ${short(COMMON_DEPLOYED.syncTrigger)}`), count: true }
      : { level: 'crit', html: chip('crit', 'addresses off-pin',
          `receiver <span class="mono">${esc(short(paramsSrc.receiverAddress))}</span> · target <span class="mono">${esc(short(paramsSrc.targetAddress))}</span>`), count: true };

  // Same renderer the calldata explainer uses, so a lane table cannot say one thing before signing and
  // another after: one implementation, one set of issues.
  const laneTab = laneTableHtml(paramsSrc?.lanes);
  const paramsLevel = worst([recRow, pubRow, digRow, srcRow, tgtRow].filter(r => r.count).map(r => r.level)
    .concat(cons ? laneTab.issues.map(i => i.level) : []));

  const paramsCard = `<div class="card">
    <div class="card-head">
      <h3>Deployed Parameters</h3>
      <span class="desc">Digests show what was declared, not what the DON runs.</span>
    </div>
    <div class="params-checks">
      <div class="params-check"><div class="params-check-label">Registration</div>${recRow.html}</div>
      <div class="params-check"><div class="params-check-label">Config</div>${pubRow.html}</div>
      <div class="params-check"><div class="params-check-label">Source</div>${srcRow.html}</div>
      <div class="params-check"><div class="params-check-label">Config hash</div>${digRow.html}</div>
      <div class="params-check"><div class="params-check-label">Contracts</div>${tgtRow.html}</div>
    </div>
    <div class="card-head"><span class="desc">Lane triggers · <strong>${
      paramsOrigin === 'chain' ? 'on-chain config'
      : paramsOrigin === 'attested' ? 'attested repo config'
      : 'unverified repo config'}</strong> ·
      gas <span class="mono">${esc(paramsSrc?.writeGasLimit ?? '—')}</span></span></div>
    ${laneTab.html}
    ${laneTab.issues.map(i => `<div class="err-banner">${i.level === 'crit' ? '✕' : '⚠'} ${i.text}${
      i.level === 'crit' && laneTab.missing.length ? ` — ${paramsFromChain ? 'the registered config drives fewer lanes than this dashboard tracks' : 'the repo config is short a lane'}` : ''}</div>`).join('')}
  </div>`;

  const level = worst([
    paramsLevel,
    ...(automation.regError ? ['crit'] : []),
    ...lanes.filter(l => l.error).map(() => 'crit'),
    // An event-source outage means the delivery plane is unverified; a green tab must not be read off a
    // cache that could not be refreshed.
    ...(automation.logErrors.length ? ['warn'] : []),
    ...perLane.filter(Boolean).flatMap(p => [p.reg.level, p.del.level, ...p.gate.map(c => c.level)]),
  ]);
  setTabStatus('automation', level === 'ok' ? null : level);

  const hero = `<div class="card hero">
    <div>
      <h2 class="serif">CRE automation</h2>
      <p>Registry, author gate, and delivery by lane.</p>
      ${viewRefresh('automation', 'Automation')}
    </div>
    <div class="stat">
      <!-- LANES, not workflows: under the consolidated layout there is ONE registration behind all four
           of these, so a tile headed "Workflows ACTIVE" would read as a count of records and be wrong. -->
      <div class="k">Lanes registered</div>
      <div class="v serif">${regsRead ? `${active.length}<span style="color:var(--muted)">/${LANES.length}</span>`
        : '<span style="color:var(--muted)">?</span>'}</div>
      <div class="s">${!regsRead ? 'registry unread — count unknown'
        : `DON ${DON_FAMILY} · ${cons ? 'one record, four lanes' : 'no record governs a lane'}`}</div>
    </div>
    <div class="stat ${gateBlocked.length ? 'critical' : 'tinted'}">
      <div class="k">Author gate armed</div>
      <div class="v serif">${armed.length}<span style="color:var(--muted)">/${LANES.length}</span></div>
      <div class="s">${armed.length === LANES.length ? 'reports accepted'
        : gateBlocked.length ? 'blocked at: ' + esc(gateBlocked.join(', '))
        : 'gate state unverified — see the lane table'}</div>
    </div>
    <div class="stat tinted">
      <div class="k">Last delivery</div>
      <div class="v serif">${deliveryRead
        ? (lastDelivery ? ago(lastDelivery) : 'never')
        : '<span style="color:var(--muted)">unread</span>'}</div>
      <div class="s">${deliveryRead ? 'reports run only when sync is due'
        : 'event source unreachable — delivery history not verified'}</div>
    </div>
  </div>`;

  const laneRows = perLane.map((p, i) => {
    if (!p) return `<tr><td>${laneWho(lanes[i].L)}</td><td colspan="4">${chip('crit', 'RPC error', esc(lanes[i].error))}</td></tr>`;
    const regBad = p.reg.rows
      ? [p.reg.rows.status, p.reg.rows.don, p.reg.rows.tag].find(c => c.level !== 'ok')
      : null;
    const registration = !p.reg.rows
      ? (p.reg.unread ? chip('warn', 'UNKNOWN', 'registry unread') : chip('crit', 'MISSING', 'workflow not registered'))
      : regBad ? chip(regBad.level, 'MISCONFIGURED', regBad.value)
      : chip('ok', 'ACTIVE', `<span class="mono">${esc(CRE_WORKFLOW_NAME)}</span> · one record, four lanes`);
    const gateBad = p.gate.find(c => c.level !== 'ok');
    const gate = gateBad
      ? chip(gateBad.level, gateBad.level === 'crit' ? 'BLOCKED' : 'UNKNOWN', gateBad.key)
      : chip('ok', 'ARMED');
    return `<tr>
      <td>${laneWho(p.L)}</td>
      <td>${registration}</td>
      <td>${gate}</td>
      <td>${chip(p.del.level, p.del.label, p.del.note)}</td>
      <td><span class="num"><div class="m">${p.del.last ? ago(p.del.last) : '—'}</div>
          <div class="s">${p.del.last ? new Date(p.del.last * 1000).toLocaleString() : 'no accepted report'}</div></span></td>
    </tr>`;
  }).join('');

  const laneCard = `<div class="card">
    <div class="card-head">
      <h3>Automation by lane</h3>
      ${legendHtml()}
    </div>
    ${automation.regError ? `<div class="err-banner">✕ registry unreadable: ${esc(automation.regError)}</div>` : ''}
    ${automation.logErrors.length ? `<div class="err-banner">⚠ event source unreachable: ${automation.logErrors.map(esc).join(', ')} · showing cached history<button class="retry" data-action="automation-retry">⟳ retry</button></div>` : ''}
    <div class="scroll-x"><table class="syncm">
      <tr><th>Lane</th><th>Workflow</th><th>Author gate</th><th>Delivery</th><th>Last accepted report</th></tr>
      ${laneRows}
    </table></div>
  </div>`;

  // Recent control-plane history.
  const events = LANES.flatMap(L => (automation.logs[L.name] ?? []).map(e => ({ L, ...e })))
    .sort((a, b) => (b.ts ?? 0) - (a.ts ?? 0));
  const visibleEvents = events.slice(0, 12);
  const evRows = visibleEvents.map(e => `<tr>
    <td><span class="num"><div class="m">${ago(e.ts)}</div>
        <div class="s">${e.ts ? new Date(e.ts * 1000).toLocaleString() : 'block ' + e.block}</div></span></td>
    <td><span class="who"><span class="avatar">${netLogo(e.L)}</span><span class="name">${e.L.name}</span></span></td>
    <td><span class="tag ${EVT[e.topic].kind === 'exec' ? 'sync' : ''}">${EVT[e.topic].label}</span></td>
    <td>${eventDetail(e)}</td>
    <td><a href="${e.L.explorer}/tx/${e.tx}" target="_blank" title="${e.tx}" class="mono">${short(e.tx)}&thinsp;↗</a></td>
  </tr>`).join('');
  const missingLanes = LANES.filter(L => !Array.isArray(automation.logs[L.name])).map(L => L.name);
  const evCard = `<div class="card">
    <div class="card-head">
      <h3>Recent events</h3>
      <span class="desc">Latest ${visibleEvents.length} events.</span>
    </div>
    ${automation.logErrors.length || missingLanes.length ? `<div class="err-banner">⚠ incomplete: ${
      [...automation.logErrors.map(esc), ...missingLanes.map(n => n + ' (not loaded)')].join(', ')} — rows below are cached or partial</div>` : ''}
    ${evRows ? `<div class="scroll-x"><table>
      <tr><th>Age</th><th>Lane</th><th>Event</th><th>Detail</th><th>Tx</th></tr>${evRows}</table></div>`
      : '<div class="err-banner">no CREReceiver events found</div>'}
  </div>`;

  document.getElementById('automation-cards').innerHTML = hero + laneCard + paramsCard + evCard;
}

// ── Lane triggers: the crons and networks a config actually registers ────────
// One workflow, four cron triggers, and the only place they exist is the config — which the registry
// stores as a 403-gated URL. Wherever a copy of that config IS available (published in `attributes`, or
// this page's own pinned copy), it is worth reading properly rather than echoing: a six-field CRE cron
// misread as five-field crontab, a duplicated selector, or two lanes landing in the same minute are all
// silent at registration and only surface as behaviour weeks later.
const laneOfSelector = sel => LANES.find(L => String(sel ?? '') === `ethereum-mainnet-${L.name.toLowerCase()}-1`) ?? null;

// CRE cron carries a SECONDS field first — six fields, not crontab's five. Reading "0 15 * * * *" with
// crontab habits gives a different schedule entirely, which is why the field count is a verdict and not
// a formatting detail.
function cdCron(schedule) {
  const f = String(schedule ?? '').trim().split(/\s+/).filter(Boolean);
  if (f.length === 5) return { level: 'crit', reads: 'five fields — crontab, not CRE', periodSec: null,
    note: 'CRE takes six fields, seconds first; a five-field expression means something else here', next: [] };
  if (f.length !== 6) return { level: 'crit', reads: `${f.length} field${f.length === 1 ? '' : 's'}`, periodSec: null,
    note: 'expected six: sec min hour day month weekday', next: [] };
  const [sec, min, hour, dom, mon, dow] = f;
  const pad = n => String(n).padStart(2, '0');
  const step = spec => (/^\*\/[1-9]\d*$/.test(spec) ? Number(spec.slice(2)) : null);
  const fixed = spec => (/^\d+$/.test(spec) ? Number(spec) : null);
  const known = spec => spec === '*' || fixed(spec) !== null || step(spec) !== null;
  const hits = (spec, v) => spec === '*' || fixed(spec) === v || (step(spec) !== null && v % step(spec) === 0);

  // Only the shapes this system uses are glossed, and the seconds field must be a fixed value — the
  // scan below walks minutes, so a wildcard second would be described by a search that never looked at
  // seconds. Anything else is reported as un-glossed rather than guessed at.
  const s0 = fixed(sec);
  if (s0 === null || ![min, hour].every(known) || dom !== '*' || mon !== '*' || dow !== '*')
    return { level: 'warn', reads: 'pattern not glossed here', periodSec: null,
      note: 'read the six fields directly — this page only spells out the shapes this system uses', next: [] };
  if (s0 > 59 || fixed(min) > 59 || fixed(hour) > 23)
    return { level: 'crit', reads: 'value out of range', periodSec: null,
      note: 'seconds and minutes run 0–59, hours 0–23', next: [] };

  const mStep = step(min), hStep = step(hour), mFix = fixed(min), hFix = fixed(hour);
  const reads =
    hour === '*' && min === '*' ? `every minute at :${pad(s0)}`
    : hour === '*' && mStep ? `every ${mStep} minutes at :${pad(s0)}`
    : hour === '*' && mFix !== null ? `every hour at :${pad(mFix)}:${pad(s0)}`
    : hStep && mFix !== null ? `every ${hStep} hours at :${pad(mFix)}:${pad(s0)}`
    : hFix !== null && mFix !== null ? `once a day at ${pad(hFix)}:${pad(mFix)}:${pad(s0)}`
    : `sec ${sec} · min ${min} · hour ${hour}`;

  // Next fires by scanning forward minute by minute (bounded to 48h), which handles every shape above
  // without a per-shape formula. The PERIOD is then read off the gaps rather than assumed — for a step
  // expression that does not divide the hour, gaps are uneven, so the widest one is the honest answer.
  const now = new Date();
  const next = [];
  let t = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours(), now.getUTCMinutes(), s0));
  for (let i = 0; i < 2880 && next.length < 4; i++) {
    if (t > now && hits(hour, t.getUTCHours()) && hits(min, t.getUTCMinutes())) next.push(new Date(t));
    t = new Date(t.getTime() + 60e3);
  }
  const gaps = next.slice(1).map((d, i) => (d - next[i]) / 1000);
  return { level: 'ok', reads, note: null, next: next.slice(0, 2),
    periodSec: gaps.length ? Math.max(...gaps) : null };
}

// Renders the lane table shared by the Deployed Parameters card and the calldata explainer, and returns
// the issues it found so the caller can fold them into its own verdict instead of re-deriving them.
export function laneTableHtml(lanes) {
  const list = Array.isArray(lanes) ? lanes : [];
  const issues = [];
  const seen = new Set(), minutes = new Map();
  const rows = list.map((ln, i) => {
    const sel = String(ln?.chainSelectorName ?? '');
    const L = laneOfSelector(sel);
    const c = cdCron(ln?.schedule);
    if (!L) issues.push({ level: 'crit', text: `lane ${i + 1} names ${esc(sel) || 'no chain'} — not one of the four this system runs` });
    if (seen.has(sel)) issues.push({ level: 'crit', text: `${esc(sel)} appears twice — two triggers would write the same report to the same chain` });
    seen.add(sel);
    if (c.level !== 'ok') issues.push({ level: c.level, text: `${esc(sel) || `lane ${i + 1}`}: ${c.reads}` });
    const mm = (c.reads?.match(/^every hour at :(\d\d)/) ?? [])[1];
    if (mm != null) { minutes.set(mm, (minutes.get(mm) ?? 0) + 1); }
    return `<tr>
      <td>${L ? laneWho(L) : chip('crit', 'unknown network', esc(sel) || '(empty)')}</td>
      <td><span class="num"><div class="m mono">${esc(sel) || '—'}</div>
          <div class="s">${L ? `chain ${L.chainId}` : 'no lane on this dashboard'}</div></span></td>
      <td><span class="num"><div class="m mono">${esc(String(ln?.schedule ?? '—'))}</div>
          <div class="s">${c.level === 'ok' ? esc(c.reads) : `<span class="chip ${c.level}"><div class="m">${esc(c.reads)}</div></span>`}</div></span></td>
      <td class="s">${c.next.length
        ? `${c.next.map(d => d.toISOString().replace('T', ' ').slice(0, 19) + 'Z').join('<br>')}`
        : esc(c.note ?? '—')}</td>
    </tr>`;
  }).join('');
  [...minutes].filter(([, n]) => n > 1).forEach(([mm]) =>
    issues.push({ level: 'warn', text: `two lanes both fire at :${mm} — the stagger that keeps executions apart is gone` }));
  const missing = LANES.filter(L => !list.some(ln => laneOfSelector(ln?.chainSelectorName) === L));
  if (missing.length)
    issues.push({ level: 'crit', text: `no trigger for ${missing.map(L => L.name).join(', ')}` });
  return { issues, missing, html: `<div class="scroll-x"><table class="syncm">
    <tr><th>Network</th><th>Chain selector</th><th>Cron (seconds-first)</th><th>Next fires (UTC)</th></tr>
    ${rows || '<tr><td colspan="4">no lanes in this config</td></tr>'}
  </table></div>` };
}

export async function refreshAutomationState(lanes) {
  const currentLanes = lanes ?? await Promise.all(LANES.map(L => laneData(L)
    .then(d => ({ L, d })).catch(e => ({ L, error: e.message }))));
  // The owner set is discovered, not hardcoded: whichever address each lane currently expects as its
  // report author is the one whose registry account matters. Survives the pending Safe migration.
  // AUTO_SAFE is included EXPLICITLY, not discovered: it owns the consolidated registration even when
  // a lane's expectedAuthor points elsewhere, so a purely discovered owner set would be blind to the
  // workflow exactly when the author gate is broken — the window that most needs watching.
  const owners = [...new Set([AUTO_SAFE,
    ...currentLanes.filter(l => !l.error && l.d.creAuthor).map(l => l.d.creAuthor.toLowerCase())])];
  let regs = null, regError = null;
  try { regs = await registryData(owners); } catch (e) { regError = e.message; }
  // Published together: a render that pairs this cycle's lanes with the previous cycle's registry would
  // show a just-changed expectedAuthor as an unlinked author and flash a false gate failure.
  automation.lanes = currentLanes;
  automation.regs = regs;
  automation.regError = regError;
  renderAutomation();
}
export async function refreshAutomationLogs() {
  const results = await Promise.all(LANES.map(L => automationLogs(L)
    .then(events => { automation.logs[L.name] = events; renderAutomation(); return { L }; })
    .catch(e => ({ L, error: e.message }))));
  saveAutomationCache();
  automation.logErrors = results.filter(r => r.error).map(r => `${r.L.name} (${r.error})`);
  renderAutomation();
}
