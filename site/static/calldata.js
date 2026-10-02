import { automation, laneTableHtml, regAttest } from './automation.js';
import { CRE_CONFIG_JSON, CRE_CONFIG_SHA256, CRE_SOURCE_SHA256, CRE_WORKFLOW_NAME, DON_FAMILY, L1 } from './config.js';
import { bytesOfHex, creConfigSha, paramsAgreement, parseAttributes, regsUsable, WF } from './registry.js';
import { sha256Hex } from './sha256.js';
import { chip, esc, holder, short, worst, ZERO } from './ui.js';

// ── Calldata explainer — what the multisig is actually about to sign ─────────
// A Safe signer is shown a destination and a hex blob. The blob alone decides what happens, and
// nothing in the path spells out what its fields MEAN here: the CRE CLI prints it without commentary,
// the Safe UI renders bytes, and an explorer at best names the function. So it is decoded in-page and
// every field is given a VERDICT against the same pins the rest of this tab checks — a decoded value
// that nobody compares to anything is how a wrong workflowId or an empty attributes field gets signed.
//
// Local only: no network write, no signature, nothing leaves the page. The one optional read is an
// eth_call against the registry to ask whether a workflowId is already taken.
const REG_FN = {
  '0xb377bfc5': { name: 'upsertWorkflow',
    types: ['string', 'string', 'bytes32', 'uint8', 'string', 'string', 'string', 'bytes', 'bool'],
    args: ['workflowName', 'tag', 'workflowId', 'status', 'donFamily', 'binaryUrl', 'configUrl', 'attributes', 'keepAlive'] },
  '0xdc101969': { name: 'linkOwner', types: ['uint256', 'bytes32', 'bytes'], args: ['validityTimestamp', 'proof', 'signature'] },
  '0x39d68c6a': { name: 'unlinkOwner', types: ['address', 'uint256', 'bytes'], args: ['owner', 'validityTimestamp', 'signature'] },
  '0xe690f332': { name: 'pauseWorkflow', types: ['bytes32'], args: ['workflowId'] },
  '0x530979d6': { name: 'activateWorkflow', types: ['bytes32', 'string'], args: ['workflowId', 'donFamily'] },
  '0x695e1340': { name: 'deleteWorkflow', types: ['bytes32'], args: ['workflowId'] },
  '0xd8b80738': { name: 'batchPauseWorkflows', types: ['bytes32[]'], args: ['workflowIds'] },
  '0xafbb2401': { name: 'updateWorkflowDONFamily', types: ['bytes32', 'string'], args: ['workflowId', 'newDonFamily'] },
};
const SAFE_EXEC_SEL = '0x6a761202';
const SAFE_EXEC = { name: 'execTransaction',
  types: ['address', 'uint256', 'bytes', 'uint8', 'uint256', 'uint256', 'uint256', 'address', 'address', 'bytes'],
  args: ['to', 'value', 'data', 'operation', 'safeTxGas', 'baseGas', 'gasPrice', 'gasToken', 'refundReceiver', 'signatures'] };

// Flat-argument ABI decoder for the shapes above. Deliberately narrow, like decodeTupleArray: it
// returns null on anything it does not recognise rather than guessing, because a half-decoded blob
// rendered as a table is worse than a refusal — it invites a signature on fields nobody verified.
function decodeAbiArgs(hex, types) {
  const b = (hex || '').replace(/^0x/, '');
  if (!b.length || b.length % 64) return null;
  const words = b.length / 64;
  const w = i => b.slice(i * 64, i * 64 + 64);
  const u = i => BigInt('0x' + w(i));
  try {
    return types.map((t, i) => {
      if (i >= words) throw new Error('short');
      if (t === 'bytes32') return '0x' + w(i);
      if (t === 'address') return '0x' + w(i).slice(24);
      if (t === 'bool') return u(i) !== 0n;
      if (t === 'uint8' || t === 'uint256') return u(i);
      const off = Number(u(i));
      if (off % 32) throw new Error('unaligned');
      const at = off / 32;
      if (at < 0 || at >= words) throw new Error('out of range');
      const len = Number(u(at));
      if (t === 'bytes32[]') {
        if (at + 1 + len > words) throw new Error('short array');
        return Array.from({ length: len }, (_, k) => '0x' + w(at + 1 + k));
      }
      const raw = b.slice((at + 1) * 64, (at + 1) * 64 + len * 2);
      if (raw.length < len * 2) throw new Error('short dynamic');
      if (t === 'bytes') return '0x' + raw;
      // Strict UTF-8: registry strings are owner-written, and a lenient decode would render mojibake
      // as if it were a workflow name.
      return new TextDecoder('utf-8', { fatal: true }).decode(bytesOfHex(raw));
    });
  } catch { return null; }
}

// `html: true` marks a value this page composed itself (an icon + label from holder()); everything
// else is escaped on the way out, because most values here are bytes a signer was handed by someone.
const cdRow = (field, value, verdict, note, html, destructive) =>
  ({ field, value, level: verdict, note, html: !!html, destructive: !!destructive });
// A workflowId is only meaningful against the records this tab already read.
const cdKnownWorkflow = id => {
  const regs = automation.regs;
  if (!regsUsable(regs)) return null;
  return regs.flatMap(acct => acct.workflows.map(t => ({ acct, t })))
    .find(({ t }) => (t[WF.id] || '').toLowerCase() === (id || '').toLowerCase()) ?? null;
};

function cdArtifactUrlStatus(value, idBare, expectedLeaf) {
  let u;
  try { u = new URL(String(value ?? '')); } catch { return { onHost: false, keyed: false }; }
  const parts = u.pathname.split('/');
  const onHost = u.origin === 'https://storage.cre.chain.link';
  const keyed = onHost && parts.length === 4 && parts[1] === 'artifacts'
    && parts[2].toLowerCase() === idBare && parts[3] === expectedLeaf;
  return { onHost, keyed };
}

function cdExplainUpsert(a) {
  const [name, tag, id, status, don, binUrl, cfgUrl, attrs, keepAlive] = a;
  const idBare = (id || '').replace(/^0x/, '').toLowerCase();
  const rows = [];

  // One name is expected here and everything else is a stop, the retired per-lane names included: this
  // system runs ONE registration now, so re-registering a lane-specific one is a mistake, not a variant.
  rows.push(cdRow('workflowName', name, name === CRE_WORKFLOW_NAME ? 'ok' : 'crit',
    name === CRE_WORKFLOW_NAME ? 'the consolidated four-lane workflow'
      : 'not the name this repo registers'));

  rows.push(cdRow('tag', tag, tag === name ? 'ok' : 'crit',
    tag === name ? 'matches the name, as the CLI registers it'
      : 'the record key is keccak(owner, name, tag) — a different tag creates a SEPARATE record'));

  const known = cdKnownWorkflow(id);
  rows.push(cdRow('workflowId', short(id), known ? 'crit' : 'ok',
    known ? `already registered as ${esc(known.t[WF.name])} — upsertWorkflow reverts WorkflowIDAlreadyExists on a re-used id`
      : 'hash of binary + config + owner + name. The binary is not reproducible, so this identifies the artifact rather than proving it'));

  // ACTIVE is a legitimate choice, not a defect, so it is described rather than flagged: registering
  // ahead of the author cutover costs rejected reports, and whether that is worth avoiding is the
  // operator's call, made once — not a warning re-raised on every paste.
  rows.push(cdRow('status', status === 0n ? '0 · ACTIVE' : status === 1n ? '1 · PAUSED' : String(status),
    status === 0n || status === 1n ? 'ok' : 'crit',
    status === 0n ? 'runs immediately. Until each lane\'s expectedAuthor points here, every tick is rejected (credits spent, no log)'
      : status === 1n ? 'registered but not running — reversible with activateWorkflow'
      : 'not a status this registry defines'));

  rows.push(cdRow('donFamily', don, don === DON_FAMILY ? 'ok' : 'crit',
    don === DON_FAMILY ? 'the family this owner holds quota on'
      : `expected ${DON_FAMILY} — and the registry refuses to change a family on update, so this is not fixable in place`));

  [['binaryUrl', binUrl, 'binary.wasm'], ['configUrl', cfgUrl, 'config']].forEach(([k, url, leaf]) => {
    const { onHost, keyed } = cdArtifactUrlStatus(url, idBare, leaf);
    rows.push(cdRow(k, url ? String(url).slice(0, 46) + (String(url).length > 46 ? '…' : '') : '(empty)',
      keyed ? 'ok' : 'crit',
      keyed ? `exact /artifacts/<workflowId>/${leaf} path on the CRE host — one build`
        : onHost ? `expected /artifacts/<workflowId>/${leaf} — URL path and artifact disagree`
        : 'not on storage.cre.chain.link — the DON would not load this'));
  });

  // The field this whole card exists for: attributes is the only place the deployed parameters can be
  // observed at all, because the artifact URLs above are 403 to everyone but the DON.
  const attrHex = String(attrs ?? '0x');
  const parsedAttrs = parseAttributes(attrHex);
  cdAttest = parsedAttrs.kind === 'attest' ? parsedAttrs.a : null;
  const repoParsed = (() => { try { return JSON.parse(CRE_CONFIG_JSON); } catch { return null; } })();
  let params = null, attrLevel, attrNote;
  if (parsedAttrs.kind === 'empty') {
    attrLevel = 'warn';
    attrNote = 'EMPTY — nothing about the deployed config or source would be observable. Re-emit with `just cre-attach-params` first';
  } else if (parsedAttrs.kind === 'attest') {
    // Two digests, each checked against a file this page can hash. The row reports the weaker of the two
    // checks; the artifact table below gives the per-file verdicts.
    const a = parsedAttrs.a;
    const cfgOk = a.config === creConfigSha;
    const srcOk = a.source === CRE_SOURCE_SHA256;
    attrLevel = !cfgOk || !srcOk ? 'crit' : 'ok';
    attrNote = !cfgOk ? 'attested config digest is NOT this repo\'s — different parameters would be deployed'
      : !srcOk ? 'attested source digest is NOT this repo\'s main.ts — that is different code'
      : 'both digests match this repo — re-hash either file below to confirm';
  } else if (parsedAttrs.kind === 'config') {
    params = parsedAttrs.config;
    const agree = paramsAgreement(attrHex, params, CRE_CONFIG_JSON, repoParsed);
    attrLevel = agree.level;
    attrNote = agree.level === 'ok' ? `${agree.note} (the older verbatim-config payload)`
      : `${agree.note} — the lanes below are what this payload would actually publish`;
  } else if (parsedAttrs.kind === 'attest-unknown') {
    attrLevel = 'crit';
    attrNote = `attestation version ${esc(String(parsedAttrs.a.v))} — this page checks cre-attest/3 and cannot verify this payload`;
  } else {
    attrLevel = 'crit';
    attrNote = 'neither a cre-attest payload nor a workflow config — do not sign metadata nobody can read';
  }
  rows.push(cdRow('attributes', `${parsedAttrs.bytes} bytes`, attrLevel, attrNote));
  if (parsedAttrs.kind === 'attest') {
    const a = parsedAttrs.a;
    rows.push(cdRow('· attested config', short('0x' + String(a.config ?? '')), a.config === creConfigSha ? 'ok' : 'crit',
      a.config === creConfigSha ? 'sha256(config.deploy.json) — also an input to the workflowId above' : 'does not match this repo'));
    rows.push(cdRow('· attested source', short('0x' + String(a.source ?? '')), a.source === CRE_SOURCE_SHA256 ? 'ok' : 'crit',
      a.source === CRE_SOURCE_SHA256 ? 'sha256(main.ts) — one file, so this covers the whole workflow' : 'does not match this repo\'s main.ts'));
    // Neutral by design: this row states the limit of the check, it is not a finding about THIS payload.
    // Given a verdict level it would raise the headline on every clean paste and train the reader to
    // scroll past the banner.
    rows.push(cdRow('· what a match proves', 'declaration only', '',
      'The owner writes these digests, and the uploaded artifacts are 403 to everyone but the DON. A match shows the config and source here are the ones DECLARED at registration — not that the DON executes them.'));
  }

  rows.push(cdRow('keepAlive', String(keepAlive), keepAlive === false ? 'ok' : 'warn',
    keepAlive === false ? 'an earlier record under this owner+name is paused as this one registers — replace-in-place'
      : 'earlier records stay ACTIVE — two workflows would run the same job'));

  // The crons and the networks are the substance of this registration, and they are in the calldata ONLY
  // when attributes carries the config. When it does not, say where they went rather than rendering an
  // empty table: "no triggers shown" and "no triggers registered" are opposite claims.
  // The bytes themselves, decoded. A reader checking a signature should see the exact text that would
  // land on-chain — 172 characters of UTF-8 JSON — not only this page's verdict about it. Escaped, and
  // shown for anything that decoded as text, including a payload this page does not recognise.
  const attrsBlock = parsedAttrs.text
    ? `<div class="cdsum">attributes, decoded (UTF-8 JSON, ${parsedAttrs.bytes} bytes):
         <div class="cdjson mono">${esc(parsedAttrs.text)}</div></div>`
    : parsedAttrs.kind === 'binary'
      ? `<div class="cdsum">attributes: ${parsedAttrs.bytes} bytes that are not valid UTF-8 — nothing to display as text.</div>`
      : '';

  let extra;
  if (!params && parsedAttrs.kind === 'attest' && parsedAttrs.a.config === creConfigSha) {
    // The payload carries a digest, not the bytes — but it is the digest of the copy this page holds,
    // so the triggers can be shown, sourced honestly: "the config this attests to", not "the chain's".
    params = repoParsed;
  }
  if (params) {
    const laneTab = laneTableHtml(params.lanes);
    if (laneTab.issues.length) {
      rows.push(cdRow('lane triggers', `${(params.lanes ?? []).length} trigger${(params.lanes ?? []).length === 1 ? '' : 's'}`,
        worst(laneTab.issues.map(i => i.level)), laneTab.issues.map(i => i.text).join(' · ')));
    } else {
      rows.push(cdRow('lane triggers', `${(params.lanes ?? []).length} triggers`, 'ok',
        'one cron per network, four lanes, staggered'));
    }
    extra = attrsBlock + `<div class="cdsum">Triggers this payload registers — ${parsedAttrs.kind === 'attest'
      ? 'from this repo\'s config.deploy.json, whose digest the payload attests' : 'decoded from the payload itself'} · receiver
      <span class="mono">${esc(short(params.receiverAddress))}</span> · target
      <span class="mono">${esc(short(params.targetAddress))}</span> · write gas limit
      <span class="mono">${esc(String(params.writeGasLimit ?? '—'))}</span></div>${laneTab.html}`;
  } else {
    extra = attrsBlock + `<div class="cdsum">⚠ <strong>The crons and networks are not in this calldata.</strong> They live in the 403-gated
      config artifact, so what this would schedule cannot be read from the bytes you are signing. Re-emit with
      <span class="mono">just cre-attach-params</span> and paste it here again.</div>`;
  }

  return { title: `upsertWorkflow — register or replace <strong>${esc(String(name))}</strong>`, rows, extra };
}

function cdExplain(sel, fn, args) {
  if (sel === '0xb377bfc5') return cdExplainUpsert(args);
  const rows = [];
  const named = id => { const k = cdKnownWorkflow(id); return k ? esc(k.t[WF.name]) : 'not among the records this tab read'; };
  if (fn.name === 'pauseWorkflow' || fn.name === 'deleteWorkflow') {
    rows.push(cdRow('workflowId', short(args[0]), cdKnownWorkflow(args[0]) ? 'ok' : 'warn', named(args[0])));
    rows.push(cdRow('effect', fn.name, fn.name === 'deleteWorkflow' ? 'crit' : 'ok',
      fn.name === 'deleteWorkflow' ? 'IRREVERSIBLE — re-registering needs a fresh artifact, since a re-used workflowId is rejected'
        : 'stops execution, frees the ACTIVE slot; reversible with activateWorkflow',
      false, fn.name === 'deleteWorkflow'));
  } else if (fn.name === 'activateWorkflow') {
    rows.push(cdRow('workflowId', short(args[0]), cdKnownWorkflow(args[0]) ? 'ok' : 'warn', named(args[0])));
    rows.push(cdRow('donFamily', args[1], args[1] === DON_FAMILY ? 'ok' : 'crit',
      args[1] === DON_FAMILY ? 're-checks the ACTIVE quota on this family' : `expected ${DON_FAMILY}`));
  } else if (fn.name === 'batchPauseWorkflows') {
    (args[0] || []).forEach((id, i) => rows.push(cdRow(`workflowIds[${i}]`, short(id), cdKnownWorkflow(id) ? 'ok' : 'warn', named(id))));
  } else if (fn.name === 'updateWorkflowDONFamily') {
    rows.push(cdRow('workflowId', short(args[0]), cdKnownWorkflow(args[0]) ? 'ok' : 'warn', named(args[0])));
    rows.push(cdRow('newDonFamily', args[1], args[1] === DON_FAMILY ? 'ok' : 'crit', 'moves it to another DON family — quota is per family'));
  } else if (fn.name === 'linkOwner') {
    rows.push(cdRow('validityTimestamp', new Date(Number(args[0]) * 1000).toLocaleString(),
      Number(args[0]) * 1000 > Date.now() ? 'ok' : 'crit',
      Number(args[0]) * 1000 > Date.now() ? 'the attestation is still valid' : 'EXPIRED — the registry would reject this'));
    rows.push(cdRow('proof', short(args[1]), 'ok', 'single-use — the registry never clears it, so a re-link needs a fresh backend-issued proof'));
    rows.push(cdRow('signature', `${(String(args[2]).length - 2) / 2} bytes`, 'ok',
      'Chainlink\'s attestation over the claimed owner — NOT the owner\'s own signature'));
    rows.push(cdRow('who gets linked', 'msg.sender', 'warn',
      'links WHOEVER SENDS IT — the wrong sender links the wrong address and spends the proof'));
  } else if (fn.name === 'unlinkOwner') {
    rows.push(cdRow('owner', `${holder(args[0])} <span class="mono">${short(args[0])}</span>`, 'crit',
      'DESTRUCTIVE — deletes every workflow this owner holds and burns the proof permanently', true, true));
  }
  return { title: `${fn.name} — ${REG_FN_PROSE[fn.name] ?? 'WorkflowRegistry call'}`, rows, extra: '' };
}
const REG_FN_PROSE = {
  pauseWorkflow: 'stop a registered workflow', activateWorkflow: 'resume a paused workflow',
  deleteWorkflow: 'erase a registration', batchPauseWorkflows: 'stop several workflows at once',
  updateWorkflowDONFamily: 'move a workflow to another DON family',
  linkOwner: 'admit an address as a workflow owner', unlinkOwner: 'remove an owner — and its workflows',
};

// Safe wrapper: the same bytes are often pasted as a whole execTransaction. Unwrap it, check the parts
// a signer cannot see (destination, value, and above all `operation`), then explain the inner call.
function cdExplainSafeExec(args) {
  const [to, value, data, operation, safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, signatures] = args;
  const noGasToken = String(gasToken).toLowerCase() === ZERO.toLowerCase();
  const noRefundReceiver = String(refundReceiver).toLowerCase() === ZERO.toLowerCase();
  const signatureBytes = Math.max(0, (String(signatures).length - 2) / 2);
  const rows = [
    cdRow('to', `${holder(to)} <span class="mono">${short(to)}</span>`,
      (to || '').toLowerCase() === L1.workflowRegistry.toLowerCase() ? 'ok' : 'crit',
      (to || '').toLowerCase() === L1.workflowRegistry.toLowerCase() ? 'the L1 WorkflowRegistry this dashboard tracks'
        : `NOT the WorkflowRegistry (${short(L1.workflowRegistry)}) — this calldata does not mean here what it says`, true),
    cdRow('value', `${value} wei`, value === 0n ? 'ok' : 'crit', value === 0n ? 'no ETH moves' : 'this call also sends ETH'),
    cdRow('operation', operation === 0n ? '0 · CALL' : operation === 1n ? '1 · DELEGATECALL' : `${operation} · INVALID`, operation === 0n ? 'ok' : 'crit',
      operation === 0n ? 'an ordinary call' : 'only CALL is expected for a registry transaction'),
    cdRow('safeTxGas', String(safeTxGas), '', 'execution gas cap — the Safe estimates this; this page has no pinned value'),
    cdRow('baseGas', String(baseGas), baseGas === 0n ? 'ok' : 'crit',
      baseGas === 0n ? 'no base-gas reimbursement' : 'nonzero reimbursement input — not expected for this transaction'),
    cdRow('gasPrice', String(gasPrice), gasPrice === 0n ? 'ok' : 'crit',
      gasPrice === 0n ? 'refund disabled' : 'the Safe may reimburse the executor — not expected here'),
    cdRow('gasToken', `${holder(gasToken)} ${short(gasToken)}`, noGasToken ? 'ok' : 'crit',
      noGasToken ? 'native token sentinel; inert while gasPrice is zero' : 'token reimbursement setting — not expected here', true),
    cdRow('refundReceiver', `${holder(refundReceiver)} ${short(refundReceiver)}`, noRefundReceiver ? 'ok' : 'crit',
      noRefundReceiver ? 'default refund receiver; inert while gasPrice is zero' : 'attacker-chosen refund receiver — not expected here', true),
    cdRow('signatures', `${signatureBytes} bytes`, '',
      'ABI-valid bytes only — the Safe verifies signer ownership and threshold on-chain'),
  ];
  return { rows, inner: data };
}

let cdLast = '';
// The attestation currently in view: the pasted calldata's if there is one, otherwise the registered
// record's. Kept apart so a paste cannot silently overwrite what the chain says, and vice versa.
let cdAttest = null;
// Files the reader dropped in, by role, with the digest computed here.
export const cdFiles = { source: null, config: null };

const CD_ROLES = [
  { key: 'config', label: 'config.deploy.json', field: 'config', pin: () => CRE_CONFIG_SHA256,
    worth: 'the deployed parameters' },
  { key: 'source', label: 'main.ts', field: 'source', pin: () => CRE_SOURCE_SHA256,
    worth: 'the whole workflow, one file' },
];

export function renderArtifactChecks() {
  const out = document.getElementById('cd-files-out');
  const a = cdAttest ?? regAttest;
  const src = cdAttest ? 'the pasted calldata' : regAttest ? 'the registered record' : null;
  const rows = CD_ROLES.map(r => {
    const got = cdFiles[r.key];
    const want = a ? String(a[r.field] ?? '') : r.pin();
    const wantFrom = a ? `attested by ${src}` : r.pin() ? 'pinned in this page' : null;
    let verdict, note;
    if (!got) {
      verdict = ''; note = want ? `expected <span class="mono">${esc(want.slice(0, 16))}…</span> · ${wantFrom}` : 'nothing to compare against';
    } else if (!want) {
      verdict = 'warn'; note = 'no attestation and no pin to compare against';
    } else if (got.sha === want) {
      verdict = 'ok'; note = `matches · ${wantFrom}`;
    } else {
      verdict = 'crit'; note = `expected <span class="mono">${esc(want.slice(0, 16))}…</span> · ${wantFrom}`;
    }
    return `<tr>
      <td class="rowlabel">${r.label}<span class="sub">${r.worth}</span></td>
      <td><span class="mono">${got ? got.sha.slice(0, 16) + '…' : '—'}</span></td>
      <td>${verdict ? chip(verdict, verdict === 'ok' ? 'match' : verdict === 'warn' ? 'no reference' : 'MISMATCH') : chip('', 'not supplied')}</td>
      <td class="s">${note}</td>
    </tr>`;
  }).join('');
  const header = a
    ? `<div class="cdsum">Reference: <strong>${src}</strong> · <span class="mono">${esc(String(a.v ?? ''))}</span></div>`
    : `<div class="cdsum">Reference: this page's own pins — no attestation in view.</div>`;
  out.innerHTML = header + `<div class="scroll-x"><table class="syncm">
    <tr><th>Artifact</th><th>sha256 of your file</th><th></th><th>Verdict</th></tr>${rows}</table></div>`;
}

export async function cdTakeFile(key, file) {
  // The label next to the button is ours as well — the native control's "no file chosen" is drawn by the
  // browser in the browser's language, so nothing here reads it or relies on it.
  const nameEl = document.getElementById(key === 'source' ? 'cd-f-src-name' : 'cd-f-cfg-name');
  if (!file) {
    cdFiles[key] = null;
    if (nameEl) nameEl.textContent = 'no file selected';
    renderArtifactChecks();
    return;
  }
  const buf = new Uint8Array(await file.arrayBuffer());
  cdFiles[key] = { name: file.name, size: buf.length, sha: sha256Hex(buf) };
  if (nameEl) nameEl.textContent = `${file.name} · ${buf.length.toLocaleString()} bytes`;
  renderArtifactChecks();
}
function cdRenderRows(title, rows, extra) {
  const body = rows.map(r => `<tr>
    <td class="rowlabel">${esc(r.field)}</td>
    <td><span class="mono">${r.html ? r.value : esc(String(r.value))}</span></td>
    <td>${chip(r.level, r.level === 'ok' ? 'ok' : r.level === 'warn' ? 'check this' : r.level === 'crit' ? 'stop' : 'note')}</td>
    <td class="s">${r.note}</td>
  </tr>`).join('');
  return `<div class="cdsum">${title}</div>
    <div class="scroll-x"><table class="syncm">
      <tr><th>Field</th><th>Value</th><th></th><th>What it means here</th></tr>${body}</table></div>${extra ?? ''}`;
}

// Verdicts like "this workflowId is already registered" need `regs`; a paste made while the first
// read was still in flight would otherwise keep its weaker answer until the next keystroke.
export function refreshCalldata() {
  if (cdLast) decodeCalldataInput(); else renderArtifactChecks();
}

export function decodeCalldataInput() {
  const out = document.getElementById('cd-out');
  cdAttest = null;
  renderArtifactChecks();
  const raw = (document.getElementById('cd-in').value || '').replace(/[\s"',]/g, '');
  cdLast = raw;
  if (!raw) { out.innerHTML = ''; return; }
  if (!/^0x[0-9a-fA-F]*$/.test(raw) || raw.length < 10) {
    out.innerHTML = `<div class="err-banner">✕ not calldata: expected 0x followed by at least a 4-byte selector</div>`;
    return;
  }
  let html = '', body = raw.slice(10), sel = raw.slice(0, 10).toLowerCase();
  const verdicts = [];
  let wrapRows = null;
  if (sel === SAFE_EXEC_SEL) {
    const args = decodeAbiArgs(body, SAFE_EXEC.types);
    if (!args) { out.innerHTML = `<div class="err-banner">✕ execTransaction selector, but the arguments do not decode</div>`; return; }
    const wrap = cdExplainSafeExec(args);
    wrapRows = wrap.rows;
    verdicts.push(...wrap.rows.map(r => r.level));
    html += cdRenderRows('Safe <strong>execTransaction</strong> — the outer envelope', wrap.rows, '');
    const inner = String(wrap.inner ?? '0x');
    if (inner.length < 10) { out.innerHTML = html + `<div class="err-banner">⚠ the inner call is empty</div>`; return; }
    sel = inner.slice(0, 10).toLowerCase(); body = inner.slice(10);
  }
  const fn = REG_FN[sel];
  if (!fn) {
    out.innerHTML = html + `<div class="err-banner">✕ unknown selector <span class="mono">${esc(sel)}</span> — not a WorkflowRegistry function this page knows.
      Do not sign it on the strength of a dashboard that could not read it.</div>`;
    return;
  }
  const args = decodeAbiArgs(body, fn.types);
  if (!args) {
    out.innerHTML = html + `<div class="err-banner">✕ selector says <span class="mono">${esc(fn.name)}</span>, but its arguments do not decode — malformed or truncated calldata</div>`;
    return;
  }
  const ex = cdExplain(sel, fn, args);
  verdicts.push(...ex.rows.map(r => r.level));
  // The headline is the WEAKEST field, stated first. A signer reading top-to-bottom must not have to
  // reach row nine to discover that row nine says stop.
  const critRows = [...(wrapRows ?? []), ...ex.rows].filter(r => r.level === 'crit');
  const crits = critRows.length, warns = verdicts.filter(v => v === 'warn').length;
  const byDesign = crits > 0 && critRows.every(r => r.destructive);
  html = (byDesign ? `<div class="err-banner">✕ irreversible by design — sign only if this is exactly the action you intend</div>`
    : crits ? `<div class="err-banner">✕ ${crits} field${crits > 1 ? 's' : ''} say${crits > 1 ? '' : 's'} STOP — do not sign this as it stands</div>`
    : warns ? `<div class="err-banner">⚠ ${warns} field${warns > 1 ? 's' : ''} to confirm deliberately — read the notes before signing</div>`
    : `<div class="cdsum">✓ No checked field conflicts with this page's pins. Where you send it from is still yours to check.</div>`) + html;
  html += cdRenderRows(ex.title, ex.rows, ex.extra);
  html += `<div class="cdsum">Send to <strong>${holder(L1.workflowRegistry)}</strong> <span class="mono">${short(L1.workflowRegistry)}</span> on Ethereum mainnet, from the linked owner. This page checked the calldata, not where you send it.</div>`;
  out.innerHTML = html;
  renderArtifactChecks();
}
