import { AUTO_SAFE, CRE_CONFIG_JSON, CRE_WORKFLOW_NAME, L1 } from './config.js';
import { call, decBool, decodeTupleArray, LAYOUT_WORKFLOW, pad, padU, rpcBatch, SEL } from './rpc.js';
import { sha256Hex } from './sha256.js';

// ── CRE registration plane (L1 WorkflowRegistry) ─────────────────────────────
// One mainnet registry holds all four lanes' workflows. Read per OWNER and enumerated, so the tab
// keeps working when the pending Safe migration moves ownership — the owner set is discovered from
// each lane's live getExpectedAuthor() rather than hardcoded.
export async function registryData(owners) {
  const R = L1.workflowRegistry;
  const q = owners.flatMap(o => [
    call(R, SEL.getWorkflowListByOwner + pad(o) + padU(0) + padU(20)),
    call(R, SEL.isOwnerLinked + pad(o)),
  ]);
  const r = await rpcBatch(L1.rpc, q);
  return owners.map((o, i) => ({
    owner: o,
    workflows: decodeTupleArray(r[i * 2], LAYOUT_WORKFLOW),
    linked: decBool(r[i * 2 + 1]),
  }));
}

// Tuple fields, by index, so the render code never counts positions.
export const WF = { id: 0, owner: 1, createdAt: 2, status: 3, name: 4, tag: 7, attributes: 8, donFamily: 9 };

// rpcBatch turns a PER-CALL revert into null while the batch still resolves, so a non-null `regs` does
// not mean the enumeration succeeded. "The registry says no such workflow" and "we could not ask the
// registry" are different claims and only the first may be reported as an absence.
export const regsUsable = regs => regs != null && regs.every(a => a.workflows != null);

// The consolidated record, found by OWNER + NAME. Workflow names are owner-scoped, so a same-named
// record under another queried owner must not drive registration, author-gate, or cadence verdicts.
export const findConsolidated = regs => !regsUsable(regs) ? null : regs
  .flatMap(acct => acct.workflows.map(t => ({ t })))
  .find(({ t }) => String(t[WF.owner]).toLowerCase() === AUTO_SAFE.toLowerCase()
    && t[WF.name] === CRE_WORKFLOW_NAME) ?? null;

// sha256 of the page's own copy of the config, computed rather than asserted: a transcription slip in
// CRE_CONFIG_SHA256 must not be able to pass as agreement with the chain.
export const creConfigSha = sha256Hex(CRE_CONFIG_JSON);
const hexOf = b => [...b].map(x => x.toString(16).padStart(2, '0')).join('');
const hexOfText = t => '0x' + hexOf(new TextEncoder().encode(t));
// Three outcomes, not two. What the workflowId commits to is sha256 of the config's BYTES, so a
// re-indented or re-serialised copy of the same parameters is a different artifact even though every
// value matches — worth saying plainly rather than collapsing into "same" or "different".
export function paramsAgreement(attrsHex, parsed, repoText, repoParsed) {
  const bytes = String(attrsHex ?? '').toLowerCase() === hexOfText(repoText).toLowerCase();
  if (bytes) return { level: 'ok', label: 'chain = repo', note: 'the record publishes this repo\'s config.deploy.json, byte for byte' };
  const semantic = parsed != null && repoParsed != null && JSON.stringify(parsed) === JSON.stringify(repoParsed);
  if (semantic) return { level: 'warn', label: 'same params, other bytes',
    note: 'every value matches, but the published bytes are not this file\'s — different sha256, so the registered workflowId commits to a different config artifact' };
  return { level: 'crit', label: 'chain ≠ repo', note: 'the deployed parameters differ from config.deploy.json' };
}
export const bytesOfHex = h => Uint8Array.from((h || '').replace(/^0x/, '').match(/../g) ?? [], p => parseInt(p, 16));
// What the record's `attributes` turned out to be. Three payloads are recognised — the attestation this
// repo publishes, the older verbatim-config form, and "something else" — because a page that treats an
// unrecognised payload as absent would report a workflow carrying unknown metadata as carrying none.
export function parseAttributes(hex) {
  if (!hex || hex === '0x') return { kind: 'empty', bytes: 0 };
  const bytes = (hex.length - 2) / 2;
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytesOfHex(hex)); }
  catch { return { kind: 'binary', bytes }; }
  let json;
  try { json = JSON.parse(text); } catch { return { kind: 'text', bytes, text }; }
  if (json && json.v === 'cre-attest/3') return { kind: 'attest', bytes, text, a: json };
  // A payload announcing itself as an attestation this page cannot check is NOT treated as one: the
  // fields it carries would be rendered as verified when nothing verified them.
  if (json && typeof json.v === 'string' && json.v.startsWith('cre-attest/'))
    return { kind: 'attest-unknown', bytes, text, a: json };
  if (json && Array.isArray(json.lanes)) return { kind: 'config', bytes, text, config: json };
  return { kind: 'json', bytes, text, json };
}
