import { EOAS, NAMES, SAFES } from './config.js';

// ── Shared UI helpers ────────────────────────────────────────────────────────
// Holder-kind marks: person = EOA, two people = Safe multisig, document = contract.
export const ICO = {
  eoa: '<svg class="hico" viewBox="0 0 16 16" width="11" height="11" fill="currentColor" aria-label="EOA"><circle cx="8" cy="4.5" r="3"/><path d="M8 8.5c-3.3 0-6 2-6 4.5V14h12v-1c0-2.5-2.7-4.5-6-4.5z"/></svg>',
  safe: '<svg class="hico" viewBox="0 0 20 16" width="13" height="11" fill="currentColor" aria-label="Safe multisig"><circle cx="7" cy="4.5" r="3"/><path d="M7 8.5c-3.3 0-6 2-6 4.5V14h12v-1c0-2.5-2.7-4.5-6-4.5z"/><circle cx="15" cy="5" r="2.4"/><path d="M15 8.8c-.7 0-1.4.1-2 .3 1.2 1 2 2.3 2 3.9v1h4v-1c0-1.9-1.7-3.5-4-4.2z"/></svg>',
  contract: '<svg class="hico" viewBox="0 0 16 16" width="11" height="11" fill="currentColor" aria-label="contract"><path fill-rule="evenodd" d="M3.5 1H10l3 3v11H3.5V1zm5.5 1.2V5h2.8L9 2.2z"/></svg>',
};
const holderKind = a => EOAS.has(a) ? 'eoa' : SAFES.has(a) ? 'safe' : 'contract';
export const holder = (a, name) => `${ICO[holderKind((a || '').toLowerCase())]} ${name ?? who(a)}`;

export const netLogo = n => `<img src="${n.logo}" alt="" aria-hidden="true">`;
export const netName = n => `<span class="net-name">${netLogo(n)}<b>${n.name}</b></span>`;
// ── Formatting ───────────────────────────────────────────────────────────────
export const fmtEth = (wei, dp = 4) => wei == null ? '—' : (Number(wei) / 1e18).toLocaleString('en-US', { maximumFractionDigits: dp });
export const short = a => a ? a.slice(0, 6) + '…' + a.slice(-4) : '—';
export const who = a => a ? (NAMES[a.toLowerCase()] || short(a)) : '—';
export function ago(ts) {
  if (ts == null) return '—';
  let s = Math.max(0, Math.floor(Date.now() / 1000) - Number(ts));
  const d = Math.floor(s / 86400); s %= 86400;
  const h = Math.floor(s / 3600); const m = Math.floor(s % 3600 / 60);
  return (d ? d + 'd ' : '') + (h ? h + 'h ' : '') + (d ? '' : m + 'm ') + 'ago';
}
export const worst = levels => levels.includes('crit') ? 'crit' : levels.includes('warn') ? 'warn' : 'ok';
export const chip = (level, main, sub) =>
  `<span class="chip ${level}"><div class="m">${level === 'ok' ? '✓ ' : level === 'warn' ? '⚠ ' : level === 'crit' ? '✕ ' : ''}${main}</div>${sub ? `<div class="s">${sub}</div>` : ''}</span>`;
export const alink = (net, a, text) => `<a href="${net.explorer}/address/${a}" target="_blank" title="${a}">${text ?? short(a)}&thinsp;↗</a>`;
export const refreshingViews = new Set();
const REFRESH_ICON = `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M13.4 5.4A5.8 5.8 0 1 0 13 11"/><path d="M13.4 2.7v2.7h-2.7"/></svg>`;
export const viewRefresh = (view, label) => {
  const loading = refreshingViews.has(view);
  return `<button class="view-refresh${loading ? ' loading' : ''}" data-refresh-view="${view}"
    title="Refresh ${label}" aria-label="Refresh ${label}"${loading ? ' disabled' : ''}>${REFRESH_ICON}</button>`;
};
// Two digests, nothing else — the payload carries no summary hash over itself. Such a value would be
// derivable from the fields beside it, so it could only agree or contradict, and a reader might check
// IT instead of the two digests that carry the meaning.
//
// The compiled binary is deliberately absent too. Two builds of identical sources differ by three bytes
// (javy bakes entropy into its QuickJS snapshot; SOURCE_DATE_EPOCH does not fix it and no CLI flag pins
// it), so a published wasm digest could never be reproduced by a reader — it would render as a check
// while being an assertion, which is the one thing this payload must not do.
// Text arriving from chain or from an explorer is attacker-controlled — the registry's workflowName is
// written by the workflow owner, and this repo's own threat model treats that key as compromised.
export const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// Token transfers and CustomSender SlowStake events across all four lanes.
export const eqa = (a, b) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
export const ZERO = '0x' + '0'.repeat(40);
export const fmtAmt = wei => {
  const value = fmtEth(wei, wei > 0n && wei < 10n ** 15n ? 8 : 4);
  return wei > 0n && value === '0' ? '<0.00000001' : value;
};
export const legendHtml = () => `<span class="legend">
  <span><span class="dot ok"></span> ok</span>
  <span><span class="dot warn"></span> warn</span>
  <span><span class="dot crit"></span> critical</span></span>`;

export const laneWho = L => `<span class="who">
  <span class="avatar">${netLogo(L)}</span>
  <span><span class="name">${L.name}</span><br>
  <span class="sub">${alink(L, L.syncTrigger, 'trigger')} · ${alink(L, L.pool, 'pool')}</span></span></span>`;

export const tabButtons = [...document.querySelectorAll('.tab')];
export function setTabStatus(tab, status) {
  const button = tabButtons.find(b => b.dataset.tab === tab);
  if (!button) return;
  button.dataset.status = status ?? '';
  button.title = status === 'crit' ? 'Critical issue' : status === 'warn' ? 'Warning' : status === 'new' ? 'New activity' : '';
}

// Overview also holds the L1 failures card, so its dot shows the worse of the two.
const overviewStatus = { core: 'ok', shuttle: 'ok' };
export function setOverviewStatus(part, level) {
  overviewStatus[part] = level;
  const combined = worst(Object.values(overviewStatus));
  setTabStatus('main', combined === 'ok' ? null : combined);
}
