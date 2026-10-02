import { activityProgress, refreshActivity, renderActivity, setActivityTabActive, showAllActivity, updateActivityUpd } from './activity.js';
import { refreshAutomationLogs, refreshAutomationState } from './automation.js';
import { cdFiles, cdTakeFile, decodeCalldataInput, refreshCalldata, renderArtifactChecks } from './calldata.js';
import { LANES } from './config.js';
import { refreshOverviewAccess } from './core.js';
import { applyRpcOverrides, openRpcDialog, saveRpcDialog } from './rpc-settings.js';
import { sha256Hex } from './sha256.js';
import { refreshShuttles } from './shuttles.js';
import { refreshSyncVolume } from './sync-volume.js';
import { refreshingViews, tabButtons } from './ui.js';

// ── Page loop ────────────────────────────────────────────────────────────────
function updateViewRefresh(view) {
  const button = document.querySelector(`[data-refresh-view="${view}"]`);
  if (!button) return;
  const loading = refreshingViews.has(view);
  button.classList.toggle('loading', loading);
  button.disabled = loading;
  if (view === 'activity') updateActivityUpd();
}

let refreshAllPromise = null;
async function refreshAll() {
  if (refreshAllPromise) return refreshAllPromise;
  refreshAllPromise = (async () => {
    const core = refreshOverviewAccess();
    await Promise.all([
      core.then(lanes => refreshAutomationState(lanes)).then(refreshCalldata),
      refreshActivity(),
      refreshShuttles(),
      refreshSyncVolume(),
      refreshAutomationLogs(),
    ]);
  })();
  updateActivityUpd();
  try {
    await refreshAllPromise;
  } finally {
    refreshAllPromise = null;
    updateActivityUpd();
  }
}

async function refreshView(view) {
  const affected = view === 'main' || view === 'access' ? ['main', 'access'] : [view];
  if (affected.some(name => refreshingViews.has(name))) return;
  affected.forEach(name => { refreshingViews.add(name); updateViewRefresh(name); });
  try {
    // Activity has its own in-flight read, so its button never waits on the slower views.
    if (view === 'activity') await refreshActivity();
    else if (refreshAllPromise) await refreshAllPromise;
    else if (view === 'shuttle') await refreshShuttles();
    else if (view === 'automation') await Promise.all([refreshAutomationState().then(refreshCalldata), refreshAutomationLogs()]);
    else if (view === 'main') await Promise.all([refreshOverviewAccess(), refreshSyncVolume()]);
    else await refreshOverviewAccess();
  } finally {
    affected.forEach(name => { refreshingViews.delete(name); updateViewRefresh(name); });
  }
}

let activeTab = 'main';

function selectTab(tab) {
  const selected = tabButtons.find(b => b.dataset.tab === tab) ?? tabButtons[0];
  activeTab = selected.dataset.tab;
  tabButtons.forEach(b => {
    b.classList.toggle('active', b === selected);
    b.setAttribute('aria-pressed', String(b === selected));
    b.setAttribute('aria-controls', b.dataset.tab);
  });
  tabButtons.forEach(b => document.getElementById(b.dataset.tab).hidden = b !== selected);
  setActivityTabActive(activeTab === 'activity');
  if (location.hash !== '#' + activeTab) history.replaceState(null, '', '#' + activeTab);
}

tabButtons.forEach(b => b.onclick = () => selectTab(b.dataset.tab));
window.addEventListener('hashchange', () => selectTab(location.hash.slice(1)));
document.addEventListener('click', event => {
  const button = event.target.closest('[data-refresh-view]');
  if (button) refreshView(button.dataset.refreshView);
  // Buttons inside re-rendered markup; module functions are out of reach of inline handlers.
  const action = event.target.closest('[data-action]');
  if (action?.dataset.action === 'activity-retry') { action.disabled = true; refreshActivity(); }
  if (action?.dataset.action === 'activity-show-all') showAllActivity();
  if (action?.dataset.action === 'automation-retry') { action.disabled = true; refreshAutomationLogs(); }
});
selectTab(location.hash.slice(1));

// Decode as you type: the check is pure local parsing, and a signer who has to press a button to learn
// what a blob does will read the blob instead.
document.getElementById('cd-go').onclick = decodeCalldataInput;
document.getElementById('cd-in').addEventListener('input', decodeCalldataInput);
document.getElementById('cd-clear').onclick = () => {
  document.getElementById('cd-in').value = '';
  decodeCalldataInput();
};
[['source', 'cd-f-src'], ['config', 'cd-f-cfg']].forEach(([key, id]) =>
  document.getElementById(id).addEventListener('change', e => cdTakeFile(key, e.target.files?.[0])));
// Pasting the source is the same check by another route — for a reviewer reading a diff in a browser
// rather than holding the file. Byte-exact or it will not match, which is the point.
document.getElementById('cd-src-paste').addEventListener('input', e => {
  const text = e.target.value;
  cdFiles.source = text ? { name: 'pasted text', size: new TextEncoder().encode(text).length, sha: sha256Hex(text) } : null;
  renderArtifactChecks();
});
renderArtifactChecks();

document.getElementById('rpcbtn').onclick = openRpcDialog;
document.getElementById('rpcsave').onclick = async () => { if (await saveRpcDialog()) refreshAll(); };
document.getElementById('rpccancel').onclick = () => document.getElementById('rpcdlg').close();
document.getElementById('rpcreset').onclick = () => {
  document.querySelectorAll('#rpcrows .row').forEach(row => {
    row.querySelector('input').value = '';
    row.querySelector('input').classList.remove('bad');
    row.querySelector('.msg').className = 'msg dim';
    row.querySelector('.msg').textContent = 'using the built-in public endpoint';
  });
};
// Per-row "Default" clears the field; saving with it empty is what actually drops the override.
document.getElementById('rpcrows').addEventListener('click', e => {
  if (!e.target.classList.contains('clear')) return;
  const row = e.target.closest('.row');
  row.querySelector('input').value = '';
  row.querySelector('input').classList.remove('bad');
  row.querySelector('.msg').className = 'msg dim';
  row.querySelector('.msg').textContent = 'using the built-in public endpoint';
});
applyRpcOverrides(); // before the first read, so a stored override is used from the very first paint
renderActivity(LANES.map(L => ({ L, events: activityProgress[L.name].events })));
refreshAll();
setInterval(refreshAll, 60_000);
setInterval(updateActivityUpd, 10_000);
