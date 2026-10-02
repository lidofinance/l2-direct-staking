import { NETS, RPC_DEFAULTS } from './config.js';
import { netName } from './ui.js';

// ── RPC endpoint overrides ───────────────────────────────────────────────────
// Per-browser overrides for the endpoints in config.js, so an operator can point the dashboard at a
// private or paid provider (or a fork) without editing the code. localStorage rather than a cookie:
// no server would ever want these URLs in a request header — they frequently carry an API key.
const RPC_STORE = 'dsw.rpc.v1';
function loadRpcOverrides() {
  try {
    const o = JSON.parse(localStorage.getItem(RPC_STORE) || '{}');
    // Keep only keys that still name a network and still hold a string: a stale entry from a renamed
    // lane must not resurrect itself, and a malformed value must not become a fetch target.
    return Object.fromEntries(Object.entries(o)
      .filter(([k, v]) => RPC_DEFAULTS[k] && typeof v === 'string' && v.trim()));
  } catch { return {}; } // unparseable or storage blocked → defaults, never a hard failure
}
export function applyRpcOverrides(o = loadRpcOverrides()) {
  NETS.forEach(n => {
    n.rpc = o[n.name] || RPC_DEFAULTS[n.name];
  });
  const n = Object.keys(o).length;
  const badge = document.querySelector('#rpcbtn .badge');
  if (badge) badge.remove();
  if (n) document.getElementById('rpcbtn')
    .insertAdjacentHTML('beforeend', `<span class="badge">${n} custom</span>`);
  return o;
}

// Probe a candidate endpoint. Returns the chain id it reports, or throws — an unreachable or
// non-JSON-RPC URL must never be treated as "probably fine".
async function probeChainId(url) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), 8000);
  try {
    const res = await fetch(url, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] }),
      signal: ctl.signal,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const j = await res.json();
    if (j.error) throw new Error(j.error.message || 'JSON-RPC error');
    if (!j.result) throw new Error('no eth_chainId result');
    return Number(BigInt(j.result));
  } catch (e) {
    throw new Error(e.name === 'AbortError' ? 'timed out after 8s'
      : /Failed to fetch|NetworkError|Load failed/i.test(e.message) ? 'unreachable (or CORS-blocked)'
      : e.message);
  } finally { clearTimeout(t); }
}

function renderRpcRows() {
  const o = loadRpcOverrides();
  document.getElementById('rpcrows').innerHTML = NETS.map(n => `
    <div class="row" data-net="${n.name}">
      <div class="lab">${netName(n)}<span>chain ${n.chainId}</span></div>
      <div class="ctl">
        <input type="url" spellcheck="false" placeholder="${RPC_DEFAULTS[n.name]}"
               value="${o[n.name] ? o[n.name].replace(/"/g, '&quot;') : ''}">
        <button type="button" class="clear">Default</button>
      </div>
      <div class="msg dim">${o[n.name] ? 'custom endpoint' : 'using the built-in public endpoint'}</div>
    </div>`).join('');
}

export function openRpcDialog() { renderRpcRows(); document.getElementById('rpcdlg').showModal(); }

// Verify every changed endpoint before persisting any of them. A URL that answers on the wrong chain is
// rejected outright: the addresses on this dashboard are deterministic deploys that exist on several
// lanes, so a mis-bound endpoint would render a real-looking, entirely wrong lane.
export async function saveRpcDialog() {
  const save = document.getElementById('rpcsave');
  const rows = [...document.querySelectorAll('#rpcrows .row')];
  save.disabled = true; save.textContent = 'Verifying…';
  const next = {};
  let bad = 0;
  await Promise.all(rows.map(async row => {
    const net = NETS.find(n => n.name === row.dataset.net);
    const input = row.querySelector('input');
    const msg = row.querySelector('.msg');
    const url = input.value.trim();
    input.classList.remove('bad');
    if (!url) { msg.className = 'msg dim'; msg.textContent = 'using the built-in public endpoint'; return; }
    if (!/^https?:\/\//i.test(url)) {
      bad++; input.classList.add('bad'); msg.className = 'msg bad';
      msg.textContent = 'must start with http:// or https://'; return;
    }
    msg.className = 'msg dim'; msg.textContent = 'checking…';
    try {
      const id = await probeChainId(url);
      if (id !== net.chainId) {
        bad++; input.classList.add('bad'); msg.className = 'msg bad';
        msg.textContent = `answers for chain ${id}, expected ${net.chainId} — not saved`;
        return;
      }
      next[net.name] = url;
      msg.className = 'msg good'; msg.textContent = `✓ chain ${id}`;
    } catch (e) {
      bad++; input.classList.add('bad'); msg.className = 'msg bad'; msg.textContent = e.message;
    }
  }));
  save.disabled = false; save.textContent = 'Verify & save';
  if (bad) return false; // leave the dialog open with the failures marked
  try { localStorage.setItem(RPC_STORE, JSON.stringify(next)); }
  catch { /* private mode: the in-memory override below still applies for this session */ }
  applyRpcOverrides(next);
  document.getElementById('rpcdlg').close();
  return true;
}
