'use strict';
// Gundil Update Server: admin page. Talks to /api/ (server_web.go).

const IDLE_MS = 30 * 60 * 1000;
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];

let lastActivity = Date.now();
let signedIn = false;
let tab = 'devices';
let versions = [];
let devices = [];
let pollTimer = null;

function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (v === true) e.setAttribute(k, '');
    else if (v !== false && v != null) e.setAttribute(k, v);
  }
  for (const k of kids.flat()) {
    if (k == null || k === false) continue;
    e.append(k instanceof Node ? k : document.createTextNode(String(k)));
  }
  return e;
}

// copyText: the clipboard API exists only on HTTPS and localhost; this page
// is usually opened over plain http://<LAN address>, so fall back to the
// older copy command through a hidden text field.
async function copyText(text) {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch (_) { /* try the old way */ }
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.setAttribute('readonly', '');
  ta.style.position = 'fixed';
  ta.style.top = '-1000px';
  document.body.appendChild(ta);
  ta.select();
  let ok = false;
  try { ok = document.execCommand('copy'); } catch (_) { ok = false; }
  ta.remove();
  return ok;
}

function selectText(node) {
  const r = document.createRange();
  r.selectNodeContents(node);
  const sel = window.getSelection();
  sel.removeAllRanges();
  sel.addRange(r);
}

function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (t.hidden = true), 3500);
}

class ApiError extends Error {
  constructor(status, body) {
    super((body && body.error) || `Error ${status}`);
    this.status = status;
    this.body = body;
  }
}

async function api(method, path, body, opts = {}) {
  const headers = { 'X-Gundil': '1' };
  if (opts.background) headers['X-Background'] = '1';
  let payload;
  if (body instanceof FormData) payload = body;
  else if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const r = await fetch('/api/' + path, { method, headers, body: payload, credentials: 'same-origin' });
  // The server counts every request but background ones as activity.
  if (!opts.background && r.status !== 401) lastActivity = lastPing = Date.now();
  const isJson = (r.headers.get('Content-Type') || '').includes('json');
  const data = isJson ? await r.json() : await r.blob();
  if (!r.ok) {
    if (r.status === 401 && path !== 'login') {
      showLogin(signedIn ? signedOutNote() : null);
    } else if (r.status === 403 && data && data.mustChange) {
      showPassword(true);
    }
    throw new ApiError(r.status, isJson ? data : null);
  }
  return data;
}

// --------------------------------------------------------------- views

function show(view) {
  for (const s of $$('main > section')) s.hidden = s.id !== 'v-' + view;
  $('#top').hidden = !signedIn || view === 'login' || view === 'password-forced';
  if (view === 'password-forced') $('#v-password').hidden = false;
}

// signedOutNote: why the session ended. Long idle is the usual reason;
// otherwise the service restarted (sessions are kept in memory) or the
// password was changed in another browser.
function signedOutNote() {
  if (Date.now() - lastActivity >= IDLE_MS - 60000) return 'You were signed out after 30 minutes without activity.';
  return 'You were signed out: the service restarted, or the password was changed elsewhere. Sign in again.';
}

function showLogin(note) {
  signedIn = false;
  stopPolling();
  $('#login-note').textContent = note || 'Sign in as the admin.';
  $('#login-error').textContent = '';
  $('#f-login').password.value = '';
  show('login');
  $('#f-login').password.focus();
}

function showPassword(forced) {
  stopPolling();
  $('#pw-note').textContent = forced
    ? 'This is a new admin account: replace the one-time password before you continue.'
    : 'Other signed-in browsers are signed out after the change.';
  $('#pw-cancel').hidden = forced;
  $('#pw-error').textContent = '';
  $('#f-password').reset();
  show(forced ? 'password-forced' : 'password');
}

function openTab(name) {
  tab = name;
  for (const b of $$('#tabs button')) b.classList.toggle('on', b.dataset.tab === name);
  show(name);
  stopPolling();
  load();
}

async function load() {
  try {
    if (tab === 'devices') await loadDevices();
    else if (tab === 'policy') await loadPolicy();
    else if (tab === 'versions') await loadVersions();
    else if (tab === 'server') await loadServer();
  } catch (e) {
    if (!(e instanceof ApiError) || e.status >= 500) toast(e.message);
  }
}

function stopPolling() {
  clearInterval(pollTimer);
  pollTimer = null;
}

function poll(fn, ms) {
  stopPolling();
  pollTimer = setInterval(() => fn().catch(() => {}), ms);
}

// ------------------------------------------------------------ helpers

function ago(iso) {
  const s = (Date.now() - new Date(iso).getTime()) / 1000;
  if (s < 90) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400 * 2) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} days ago`;
}

function size(n) {
  if (n >= 1 << 20) return (n / (1 << 20)).toFixed(1) + ' MB';
  return Math.max(1, Math.round(n / 1024)) + ' KB';
}

function cmp(a, b) {
  const pa = a.split('.').map(Number), pb = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) - (pb[i] || 0);
  return 0;
}

function versionsFor(pkg) {
  return versions.filter((v) => v.files.some((f) => f.package === pkg)).map((v) => v.version);
}

function versionsForFamily(family, families) {
  const pkgs = families[family] || [];
  return versions.filter((v) => v.files.some((f) => pkgs.includes(f.package))).map((v) => v.version);
}

// ------------------------------------------------------------- devices

async function loadDevices() {
  const [d, v] = await Promise.all([api('GET', 'devices'), api('GET', 'versions')]);
  devices = d;
  versions = v.versions;
  renderDevices();
}

function renderDevices() {
  const q = $('#dev-filter').value.trim().toLowerCase();
  const list = devices.filter((d) => !q || [d.name, d.package, d.version, d.os, d.address].join(' ').toLowerCase().includes(q));
  $('#dev-count').textContent = `${list.length} of ${devices.length}`;
  const tb = $('#dev-table tbody');
  tb.replaceChildren();
  if (!list.length) {
    tb.append(el('tr', {}, el('td', { colspan: 7, class: 'muted' }, devices.length ? 'No match.' : 'No device has checked in yet.')));
    return;
  }
  for (const d of list) {
    // What the server told it at its last check-in…
    const told = (offer, answer) => {
      if (offer && offer !== d.version) {
        const down = cmp(offer, d.version) < 0;
        return el('span', { class: 'tag ' + (down ? 'down' : 'up') }, `${down ? 'downgrade' : 'update'} to ${offer}`);
      }
      if (offer || answer === 'up to date') return el('span', { class: 'tag' }, 'up to date');
      return answer ? el('span', { class: 'tag' }, answer) : null;
    };
    let state = told(d.offered, d.answer);
    // …and, when it changed since (new version, policy or pin), what it
    // will be told at the next one.
    const nextSame = (d.nextOffer || '') === (d.offered || '') && (d.nextOffer || d.nextAnswer === (d.answer || 'up to date'));
    if (!nextSame && d.lastSeen) {
      const next = told(d.nextOffer, d.nextAnswer);
      if (next) state = el('span', {}, state, state ? ' ' : null, el('span', { class: 'muted small' }, 'next check-in: '), next);
    }
    const pin = el('select', { 'aria-label': 'Pin version for ' + d.name },
      el('option', { value: '' }, 'Follow policy'),
      versionsFor(d.package).map((v) => el('option', { value: v, selected: v === d.pin }, v)));
    pin.addEventListener('change', async () => {
      try {
        await api('POST', 'devices/' + encodeURIComponent(d.id), { pin: pin.value });
        d.pin = pin.value;
        toast(pin.value ? `${d.name} pinned to ${pin.value}` : `${d.name} follows the policy`);
      } catch (e) { toast(e.message); }
    });
    const del = el('button', { class: 'link danger', title: 'Forget this device (it appears again at its next check-in)' }, 'Forget');
    del.addEventListener('click', async () => {
      if (!confirm(`Forget ${d.name}? It appears again when it checks in.`)) return;
      await api('DELETE', 'devices/' + encodeURIComponent(d.id));
      devices = devices.filter((x) => x.id !== d.id);
      renderDevices();
    });
    tb.append(el('tr', {},
      el('td', {}, el('div', {}, d.name || '(no name)'), el('div', { class: 'muted small' }, d.os)),
      el('td', {}, d.package),
      el('td', {}, d.version),
      el('td', {}, state, d.fetched ? el('div', { class: 'muted small' }, 'got ' + d.fetched) : null),
      el('td', { title: new Date(d.lastSeen).toLocaleString() }, ago(d.lastSeen), el('div', { class: 'muted small' }, d.address)),
      el('td', {}, pin),
      el('td', {}, del)));
  }
}

// -------------------------------------------------------------- policy

const PACKAGES_BY_FAMILY = {
  android: ['android-arm64-v8a', 'android-armeabi-v7a', 'android-x86_64', 'android-universal'],
  windows: ['windows-x64-setup', 'windows-x64-portable'],
  macos: ['macos'],
  ios: ['ios'],
  linux: ['appimage-x86_64', 'appimage-aarch64', 'linux-x64', 'linux-arm64'],
  node: ['node-arm', 'node-arm64'],
  gateway: ['gateway-linux-x86_64', 'gateway-linux-arm64', 'gateway-linux-armv7', 'gateway-linux-armv6',
    'gateway-linux-mips', 'gateway-linux-mipsle', 'gateway-windows-x86_64', 'gateway-windows-arm64'],
};

async function loadPolicy() {
  const [p, v, d] = await Promise.all([api('GET', 'policy'), api('GET', 'versions'), api('GET', 'devices')]);
  versions = v.versions;
  devices = d;
  const tb = $('#pol-table tbody');
  tb.replaceChildren();
  for (const f of p.families) {
    const cur = p.policy[f.ID] || { target: '', mode: 'off' };
    const target = el('select', { name: 'target-' + f.ID, 'aria-label': 'Version for ' + f.Name },
      el('option', { value: '' }, 'No version'),
      el('option', { value: 'latest', selected: cur.target === 'latest' }, 'Newest available'),
      versionsForFamily(f.ID, PACKAGES_BY_FAMILY).map((v) => el('option', { value: v, selected: v === cur.target }, v)));
    const mode = el('select', { name: 'mode-' + f.ID, 'aria-label': 'Action for ' + f.Name },
      [['off', 'Off'], ['ask', 'Ask'], ['auto', 'Install automatically']].map(([v, t]) => el('option', { value: v, selected: v === cur.mode }, t)));
    const counts = {};
    for (const x of devices.filter((x) => x.family === f.ID)) counts[x.version] = (counts[x.version] || 0) + 1;
    const running = Object.entries(counts).sort((a, b) => cmp(b[0], a[0])).map(([v, n]) => `${v} × ${n}`).join(', ');
    tb.append(el('tr', {}, el('td', {}, f.Name), el('td', {}, target), el('td', {}, mode),
      el('td', { class: 'muted small' }, running || 'none')));
  }
}

async function savePolicy(ev) {
  ev.preventDefault();
  const body = {};
  for (const s of $$('#pol-table select[name^=target-]')) {
    const id = s.name.slice(7);
    body[id] = { target: s.value, mode: $(`#pol-table select[name="mode-${id}"]`).value };
  }
  $('#pol-error').textContent = '';
  try {
    await api('POST', 'policy', body);
    $('#pol-saved').textContent = 'Saved. Devices pick it up at their next check-in.';
    setTimeout(() => ($('#pol-saved').textContent = ''), 4000);
  } catch (e) {
    $('#pol-error').textContent = e.message;
  }
}

// ------------------------------------------------------------ versions

async function loadVersions() {
  const v = await api('GET', 'versions');
  versions = v.versions;
  renderJob(v.job);
  renderVersions();
  const st = await api('GET', 'status', undefined, { background: true });
  $('#gh-repo').textContent = `Releases of github.com/${st.repo}.`;
  if (v.job && v.job.running) poll(async () => {
    const x = await api('GET', 'versions', undefined, { background: true });
    renderJob(x.job);
    if (!x.job.running) { versions = x.versions; renderVersions(); stopPolling(); }
  }, 2000);
}

function renderJob(job) {
  const box = $('#job');
  if (!job || (!job.running && !job.error)) { box.hidden = true; return; }
  box.hidden = false;
  box.textContent = job.running
    ? `Downloading copies of ${job.version}: file ${job.done + 1} of ${job.total} (${job.file}, ${size(job.bytes)})…`
    : `Copies of ${job.version}: ${job.error}`;
}

function renderVersions() {
  const box = $('#ver-list');
  box.replaceChildren(el('h3', {}, 'On this server'));
  if (!versions.length) {
    box.append(el('p', { class: 'muted' }, 'No version yet. Add one from GitHub or upload files.'));
    return;
  }
  for (const v of versions) {
    const local = v.files.filter((f) => f.local).length;
    const del = el('button', { class: 'danger' }, 'Remove');
    del.addEventListener('click', async (e) => {
      e.preventDefault();
      if (!confirm(`Remove version ${v.version} and its copies from this server?`)) return;
      try { await api('DELETE', 'versions/' + v.version); await loadVersions(); } catch (er) { toast(er.message); }
    });
    box.append(el('details', { class: 'card ver' },
      el('summary', {}, el('b', {}, v.version),
        el('span', { class: v.sig ? 'tag up' : 'tag down', title: v.sig ? 'The release\'s SHA256SUMS.txt is signed: devices can check every file.' : 'No signature: devices that check signatures won\'t install this version. Add it again from GitHub, or upload its SHA256SUMS.txt and SHA256SUMS.txt.sig.' }, v.sig ? 'signed' : 'not signed'),
        el('span', { class: 'muted small' }, `${v.files.length} files, ${local} kept here · ${v.source} · added ${ago(v.added)}`), del),
      el('ul', {}, v.files.map((f) => el('li', {}, f.asset, ' ', el('span', { class: 'muted' }, `${size(f.size)} · ${f.local ? 'kept here' : 'from GitHub'}`))))));
  }
}

async function loadGithub() {
  const btn = $('#gh-load');
  btn.disabled = true;
  btn.textContent = 'Loading…';
  try {
    const rels = await api('GET', 'github');
    const list = $('#gh-list');
    list.replaceChildren();
    if (!rels.length) list.append(el('p', { class: 'muted' }, 'No release with app files.'));
    for (const r of rels) {
      const have = versions.some((v) => cmp(v.version, r.tag.replace(/^v/, '')) === 0);
      const add = el('button', { class: have ? '' : 'primary' }, have ? 'Add again' : 'Add');
      add.addEventListener('click', async () => {
        const keep = $$('#gh-keep-boxes input:checked').map((x) => x.value);
        add.disabled = true;
        try {
          await api('POST', 'versions/import', { tag: r.tag, keep });
          toast(`${r.tag} added`);
          await loadVersions();
        } catch (e) { toast(e.message); }
        add.disabled = false;
      });
      list.append(el('div', { class: 'gh-item' },
        el('div', {}, el('b', {}, r.tag), r.prerelease ? ' (pre-release)' : '', el('div', { class: 'muted small' }, `${r.files} files · ${ago(r.published)}`)), add));
    }
    $('#gh-keep').hidden = false;
  } catch (e) {
    toast(e.message);
  }
  btn.disabled = false;
  btn.textContent = 'Show releases';
}

function keepBoxes() {
  const names = { android: 'Android', windows: 'Windows', macos: 'Mac', ios: 'iPhone', linux: 'Linux desktop', node: 'Headless node', gateway: 'Gateway' };
  $('#gh-keep-boxes').replaceChildren(...Object.entries(names).map(([id, n]) =>
    el('label', {}, el('input', { type: 'checkbox', value: id }), n)));
}

async function upload(ev) {
  ev.preventDefault();
  const fd = new FormData();
  for (const f of ev.target.files.files) fd.append('files', f, f.name);
  $('#up-status').textContent = 'Uploading…';
  try {
    const r = await api('POST', 'versions/upload', fd);
    $('#up-status').textContent = 'Added: ' + (r.files.length ? r.files.join(', ') : 'no release files') +
      (r.signed && r.signed.length ? ` · signature for ${r.signed.join(', ')}` : '') + (r.warning ? ` · ${r.warning}` : '');
    ev.target.reset();
    await loadVersions();
  } catch (e) {
    $('#up-status').textContent = e.message;
  }
}

// -------------------------------------------------------------- server

async function loadServer() {
  const st = await api('GET', 'status');
  $('#code').textContent = st.code;
  renderNet(st);
  try {
    const svg = await api('GET', 'qr.svg', undefined, { background: true });
    $('#qr').src = URL.createObjectURL(svg);
  } catch (_) { /* optional */ }
  $('#su-repo').textContent = st.repo || 'GitHub';
  const su = await loadSelf();
  // Look at GitHub when the tab opens, at most once an hour.
  if (!su.busy && !su.problem && (!su.lastCheck || Date.now() - Date.parse(su.lastCheck) > 3600e3)) {
    checkSelf(true);
  }
  await loadLog();
}

// --------------------------------------------------- move (server key)

async function exportKey(ev) {
  ev.preventDefault();
  const f = ev.target;
  $('#key-export-error').textContent = '';
  try {
    const r = await api('POST', 'server-key/export', { password: f.password.value });
    f.password.value = '';
    $('#key-text').textContent = r.key;
    $('#key-out').hidden = false;
  } catch (e) {
    $('#key-export-error').textContent = e.message;
  }
}

function hideKey() {
  $('#key-text').textContent = '';
  $('#key-out').hidden = true;
}

function downloadKey() {
  const text = $('#key-text').textContent;
  const a = el('a', { href: URL.createObjectURL(new Blob([text + '\n'], { type: 'text/plain' })), download: 'gundil-server-key.txt' });
  document.body.appendChild(a);
  a.click();
  a.remove();
}

let keyCheckTimer = null;
function checkKey() {
  clearTimeout(keyCheckTimer);
  const key = $('#f-key-import').key.value.trim();
  const out = $('#key-check');
  if (!key) { out.textContent = ''; return; }
  keyCheckTimer = setTimeout(async () => {
    try {
      const r = await api('POST', 'server-key/import', { key, check: true });
      out.textContent = r.same ? 'This server already has that key.' : `Server code with this key: ${r.code}`;
    } catch (e) {
      out.textContent = e.message;
    }
  }, 300);
}

async function importKey(ev) {
  ev.preventDefault();
  const f = ev.target;
  $('#key-error').textContent = '';
  let check;
  try {
    check = await api('POST', 'server-key/import', { key: f.key.value, check: true });
  } catch (e) {
    $('#key-error').textContent = e.message;
    return;
  }
  if (check.same) { $('#key-error').textContent = 'This server already has that key.'; return; }
  if (!confirm(`Replace this server's key? Its server code becomes\n${check.code}\nApps that know the current code lose this server. The old key is kept in the data folder (keys.json.old-…). The server restarts.`)) return;
  try {
    const r = await api('POST', 'server-key/import', { key: f.key.value, password: f.password.value });
    f.reset();
    $('#key-check').textContent = '';
    if (r.restart) {
      toast('Imported. Restarting with the new key…');
      setTimeout(() => showLogin(`The server restarted with the imported key (${r.code}). Sign in again.`), 4000);
    }
  } catch (e) {
    $('#key-error').textContent = e.message;
  }
}

// ------------------------------------------------------- server update

let suLatest = null;

async function loadSelf(background) {
  const u = await api('GET', 'self-update', undefined, { background });
  const checked = u.lastCheck && !u.lastCheck.startsWith('0001') ? new Date(u.lastCheck).toLocaleString() : 'not yet';
  const busy = u.busy === 'installing' ? 'installing…' : u.busy === 'checking' ? 'checking GitHub…' : null;
  const list = [['This server', u.version], ['Newest release', u.latest || '—'], ['Last check', checked],
    ['Result', busy || u.result || '']];
  $('#su-info').replaceChildren(...list.flatMap(([k, v]) => [el('dt', {}, k), el('dd', {}, v)]));
  suLatest = u.available ? u.latest : null;
  const inst = $('#su-install');
  inst.hidden = !suLatest;
  inst.disabled = !!u.busy;
  inst.textContent = suLatest ? `Update to ${suLatest}` : 'Update';
  $('#su-check').disabled = !!u.busy || !!u.problem;
  $('#su-notes-box').hidden = !(u.available && u.notes);
  $('#su-notes').textContent = u.notes || '';
  const n = $('#su-notice');
  n.hidden = !u.problem;
  n.textContent = u.problem || '';
  return u;
}

async function checkSelf(quiet) {
  const b = $('#su-check');
  b.disabled = true;
  b.textContent = 'Checking…';
  try {
    await api('POST', 'self-update/check', undefined, { background: quiet === true });
  } catch (e) {
    if (quiet !== true) toast(e.message);
  }
  b.textContent = 'Check now';
  await loadSelf(true).catch(() => {});
}

async function installSelf() {
  if (!suLatest || !confirm(`Update this server to ${suLatest} now? It restarts afterwards; devices keep working.`)) return;
  const target = suLatest;
  try {
    await api('POST', 'self-update/install');
  } catch (e) {
    toast(e.message);
    return;
  }
  const n = $('#su-notice');
  n.hidden = false;
  n.textContent = `Downloading and checking ${target}… The server restarts when it's done; this page then asks you to sign in again.`;
  $('#su-install').disabled = $('#su-check').disabled = true;
  // Wait for the restart: the page goes away, then comes back signed out.
  let wentAway = false;
  const t = setInterval(async () => {
    try {
      const r = await fetch('/api/session', { headers: { 'X-Gundil': '1', 'X-Background': '1' } });
      const s = await r.json();
      if (!s.signedIn) {
        clearInterval(t);
        showLogin(wentAway ? `The server restarted on version ${target}. Sign in again.` : 'Signed out.');
      } else if (!wentAway) {
        const u = await loadSelf(true).catch(() => null);
        if (u && !u.busy && !(u.result || '').startsWith('Installed')) {
          clearInterval(t); // Done without installing: say why.
          n.hidden = false;
          n.textContent = u.result || 'Not installed.';
        }
      }
    } catch (_) {
      wentAway = true;
      n.textContent = 'Restarting…';
    }
  }, 3000);
}

function renderNet(st) {
  const nat = { cone: 'cone: devices can reach it', symmetric: 'strict (symmetric): devices may not reach it', unknown: 'unknown (no STUN answer)' }[st.nat] || st.nat || 'checking…';
  const rows = [['Version', st.version], ['Relays', `${st.relays} of ${st.relaysTotal} connected`], ['NAT', nat],
    ['Public address', st.public || 'unknown'], ['Devices', st.devices != null ? `${st.devices} (${st.recent} in the last 24 h)` : null],
    ['Data folder', st.dataDir]].filter((r) => r[1] != null);
  $('#net').replaceChildren(...rows.flatMap(([k, v]) => [el('dt', {}, k), el('dd', {}, v)]));
}

async function loadLog() {
  const l = await api('GET', 'log');
  const pre = $('#log');
  pre.textContent = l.lines.join('\n') || '(empty)';
  pre.scrollTop = pre.scrollHeight;
}

// ------------------------------------------------------------- session

async function start() {
  const s = await api('GET', 'session');
  if (!s.signedIn) return showLogin();
  signedIn = true;
  lastActivity = Date.now() - (IDLE_MS - s.idleLeft * 1000);
  if (s.mustChange) return showPassword(true);
  openTab(tab);
}

async function login(ev) {
  ev.preventDefault();
  const f = ev.target;
  $('#login-error').textContent = '';
  try {
    const r = await api('POST', 'login', { user: 'admin', password: f.password.value });
    signedIn = true;
    lastActivity = lastPing = Date.now();
    if (r.mustChange) showPassword(true);
    else openTab('devices');
  } catch (e) {
    $('#login-error').textContent = e.message;
  }
}

async function changePassword(ev) {
  ev.preventDefault();
  const f = ev.target;
  $('#pw-error').textContent = '';
  if (f.new.value !== f.again.value) {
    $('#pw-error').textContent = 'The two new passwords are different.';
    return;
  }
  try {
    await api('POST', 'password', { current: f.current.value, new: f.new.value });
    toast('Password changed');
    openTab(tab);
  } catch (e) {
    $('#pw-error').textContent = e.message;
  }
}

async function logout() {
  try { await api('POST', 'logout'); } catch (_) { /* gone anyway */ }
  showLogin('Signed out.');
}

// Activity: the server only counts requests without X-Background, so tell
// it about clicks, typing and scrolling at most once a minute. The countdown
// runs from the last time the server heard of it, so the two agree.
let lastPing = 0;
function activity() {
  if (!signedIn) return;
  if (Date.now() - lastPing > 60000) {
    lastPing = Date.now();
    api('GET', 'session').then(() => { lastActivity = lastPing; }).catch(() => {});
  }
}

function tick() {
  if (!signedIn) { $('#idle').textContent = ''; return; }
  const left = IDLE_MS - (Date.now() - lastActivity);
  if (left <= 0) {
    showLogin('You were signed out after 30 minutes without activity.');
    api('POST', 'logout').catch(() => {});
    return;
  }
  const m = Math.ceil(left / 60000);
  $('#idle').textContent = m <= 2 ? `Signing out in ${Math.ceil(left / 1000)} s` : `Signed in · ${m} min left`;
}

document.addEventListener('DOMContentLoaded', () => {
  $('#f-login').addEventListener('submit', login);
  $('#f-password').addEventListener('submit', changePassword);
  $('#pw-cancel').addEventListener('click', () => openTab(tab));
  $('#logout').addEventListener('click', logout);
  for (const b of $$('#tabs button')) b.addEventListener('click', () => openTab(b.dataset.tab));
  $('#dev-filter').addEventListener('input', renderDevices);
  $('#f-policy').addEventListener('submit', savePolicy);
  $('#gh-load').addEventListener('click', loadGithub);
  $('#f-upload').addEventListener('submit', upload);
  $('#copy-code').addEventListener('click', async () => {
    if (await copyText($('#code').textContent)) toast('Copied');
    else {
      selectText($('#code'));
      toast('Press Ctrl+C (or Cmd+C) to copy the selected code.');
    }
  });
  $('#check').addEventListener('click', async () => {
    $('#check').disabled = true;
    try { renderNet({ ...(await api('GET', 'status')), ...(await api('POST', 'check')) }); } catch (e) { toast(e.message); }
    $('#check').disabled = false;
  });
  $('#change-pw').addEventListener('click', () => showPassword(false));
  $('#log-refresh').addEventListener('click', loadLog);
  $('#su-check').addEventListener('click', checkSelf);
  $('#f-key-export').addEventListener('submit', exportKey);
  $('#key-hide').addEventListener('click', hideKey);
  $('#key-download').addEventListener('click', downloadKey);
  $('#key-copy').addEventListener('click', async () => {
    if (await copyText($('#key-text').textContent)) toast('Copied');
    else { selectText($('#key-text')); toast('Press Ctrl+C (or Cmd+C) to copy the selected key.'); }
  });
  $('#f-key-import').key.addEventListener('input', checkKey);
  $('#f-key-import').addEventListener('submit', importKey);
  $('#su-install').addEventListener('click', installSelf);
  for (const e of ['click', 'keydown', 'scroll', 'mousemove', 'touchstart']) {
    document.addEventListener(e, activity, { passive: true, capture: true });
  }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) activity(); });
  keepBoxes();
  setInterval(tick, 1000);
  start().catch((e) => showLogin(e.message));
});
