'use strict';
// Gundil Gateway: settings page. Talks to /api/ (gateway_web.go).

const IDLE_MS = 30 * 60 * 1000;
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];

let lastActivity = Date.now();
let signedIn = false;
let tab = 'status';
let pollTimer = null;
let settings = null;

function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v;
    else if (v === true) e.setAttribute(k, '');
    else if (v !== false && v != null) e.setAttribute(k, v);
  }
  for (const k of kids.flat()) {
    if (k == null || k === false) continue;
    e.append(k instanceof Node ? k : document.createTextNode(String(k)));
  }
  return e;
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
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const r = await fetch('/api/' + path, { method, headers, body: payload, credentials: 'same-origin' });
  // The server counts every request but background ones as activity.
  if (!opts.background && r.status !== 401) lastActivity = lastPing = Date.now();
  const isJson = (r.headers.get('Content-Type') || '').includes('json');
  const data = isJson ? await r.json() : await r.text();
  if (!r.ok) {
    if (r.status === 401 && path !== 'login') {
      showLogin(signedIn ? 'You were signed out after 30 minutes without activity.' : null);
    } else if (r.status === 403 && data && data.mustChange) {
      showPassword(true);
    }
    throw new ApiError(r.status, isJson ? data : { error: String(data).trim() });
  }
  return data;
}

// --------------------------------------------------------------- views

function show(view) {
  for (const s of $$('main > section')) s.hidden = s.id !== 'v-' + view;
  $('#top').hidden = !signedIn || view === 'login' || view === 'password-forced';
  if (view === 'password-forced') $('#v-password').hidden = false;
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
    if (tab === 'status') {
      await loadStatus();
      poll(() => loadStatus(true), 5000);
    } else if (tab === 'settings') await loadSettings();
    else if (tab === 'log') {
      await loadLog();
      poll(() => loadLog(true), 5000);
    }
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

function rows(dl, list) {
  dl.replaceChildren(...list.filter((r) => r[1] != null && r[1] !== '')
    .flatMap(([k, v]) => [el('dt', {}, k), el('dd', {}, v)]));
}

function duration(s) {
  if (s < 120) return `${s} s`;
  if (s < 7200) return `${Math.round(s / 60)} min`;
  if (s < 172800) return `${Math.round(s / 3600)} h`;
  return `${Math.round(s / 86400)} days`;
}

// -------------------------------------------------------------- status

const natText = {
  cone: 'cone: direct calls work',
  symmetric: 'strict (symmetric): direct calls may fail',
  unknown: 'unknown (no STUN answer)',
};

async function loadStatus(background) {
  const s = await api('GET', 'status', undefined, { background });
  const w = $('#waiting');
  w.hidden = s.running;
  if (!s.running) {
    const why = s.key ? s.problem : 'Set the intercom password or the home key in the settings.';
    w.replaceChildren(el('b', {}, 'Not running yet. '), why || '',
      ' ', el('a', { href: '#settings', id: 'go-settings' }, 'Open the settings'));
    $('#go-settings').addEventListener('click', (e) => { e.preventDefault(); openTab('settings'); });
  }
  rows($('#st-main'), [
    ['State', s.running ? 'running' : 'waiting for the settings'],
    ['Name', s.name],
    ['Version', s.version],
    ['Key', s.key || 'not set'],
    ['Cameras', s.share ? 'shared' : 'not shared'],
    ['Self-update', s.updates ? (s.updateServer ? `on (server ${s.updateServer})` : 'on, but no update server') : 'off'],
    ['Up', duration(s.uptime)],
  ]);
  if (s.running) {
    rows($('#st-net'), [
      ['Relays', `${s.relays} of ${s.relaysTotal} connected`],
      ['NAT', natText[s.nat] || 'checking…'],
      ['Public address', s.public || 'unknown'],
      ['Shares', s.share ? (s.subnets || []).join(', ') || 'no LAN found' : 'nothing'],
    ]);
  } else {
    rows($('#st-net'), [['Relays', 'not connected']]);
  }
  $('#check').disabled = !s.running;
  $('#cfg-path').textContent = s.configPath;
}

async function checkNetwork() {
  const b = $('#check');
  b.disabled = true;
  b.textContent = 'Checking…';
  try {
    const r = await api('POST', 'check');
    rows($('#st-net'), [
      ['Key', r.key === 'password' ? 'the intercom password' : `home key ${r.key}`],
      ['Relays', `${r.relays} of ${r.relaysTotal} connected`],
      ['NAT', r.natText || r.nat],
      ['Public address', r.public || 'unknown'],
      ['Shares', r.share ? (r.subnets || []).join(', ') || 'no LAN found' : 'nothing (sharing is off)'],
      ...(r.cameras || []).map((c) => ['Camera', c]),
    ]);
    stopPolling(); // Keep the result on screen.
  } catch (e) {
    toast(e.message);
  }
  b.textContent = 'Check network';
  b.disabled = false;
}

async function restart() {
  try {
    await api('POST', 'restart');
    toast('Restarting the gateway…');
    setTimeout(() => load(), 3000);
  } catch (e) {
    toast(e.message);
  }
}

// ------------------------------------------------------------ settings

function authMode(mode) {
  $('#auth-password').hidden = mode !== 'password';
  $('#auth-home').hidden = mode !== 'home_key';
}

async function loadSettings() {
  settings = await api('GET', 'settings');
  const f = $('#f-settings');
  for (const r of f.authMode) r.checked = r.value === (settings.authMode || 'home_key');
  authMode(settings.authMode || 'home_key');
  f.password.value = '';
  f.homeKey.value = '';
  f.password.placeholder = settings.authMode === 'password' ? 'unchanged' : '';
  f.homeKey.placeholder = settings.authMode === 'home_key' ? 'unchanged' : 'GUNDIL-PAIR-…';
  $('#pw-kept').textContent = settings.authMode === 'password' ? 'Empty keeps the current one.' : '';
  $('#hk-kept').textContent = settings.homeKeyFingerprint
    ? `Now: home key ${settings.homeKeyFingerprint} (compare with the app). Empty keeps it.` : '';
  f.name.value = settings.name;
  f.shareCameras.checked = settings.shareCameras;
  f.checkHosts.value = settings.checkHosts;
  f.relays.value = settings.relays;
  f.relays.placeholder = settings.defaultRelays;
  f.updates.checked = settings.updates;
  f.updateServer.value = settings.updateServer;
  $('#set-error').textContent = '';
  $('#set-saved').textContent = '';
}

async function saveSettings(ev) {
  ev.preventDefault();
  const f = ev.target;
  $('#set-error').textContent = '';
  $('#set-saved').textContent = '';
  const mode = f.authMode.value;
  try {
    await api('POST', 'settings', {
      authMode: mode,
      password: mode === 'password' ? f.password.value : '',
      homeKey: mode === 'home_key' ? f.homeKey.value : '',
      name: f.name.value,
      shareCameras: f.shareCameras.checked,
      checkHosts: f.checkHosts.value,
      relays: f.relays.value,
      updates: f.updates.checked,
      updateServer: f.updateServer.value,
    });
    $('#set-saved').textContent = 'Saved. The gateway is restarting with the new settings.';
    await loadSettings();
    $('#set-saved').textContent = 'Saved. The gateway is restarting with the new settings.';
  } catch (e) {
    $('#set-error').textContent = e.message;
  }
}

// ------------------------------------------------------------------ log

async function loadLog(background) {
  const l = await api('GET', 'log', undefined, { background });
  const pre = $('#log');
  const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
  pre.textContent = l.lines.join('\n') || '(empty)';
  if (atEnd || !background) pre.scrollTop = pre.scrollHeight;
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
    else openTab('status');
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
  $('#check').addEventListener('click', checkNetwork);
  $('#restart').addEventListener('click', restart);
  $('#change-pw').addEventListener('click', () => showPassword(false));
  $('#f-settings').addEventListener('submit', saveSettings);
  for (const r of $('#f-settings').authMode) r.addEventListener('change', () => authMode(r.value));
  $('#log-refresh').addEventListener('click', () => loadLog());
  for (const e of ['click', 'keydown', 'scroll', 'mousemove', 'touchstart']) {
    document.addEventListener(e, activity, { passive: true, capture: true });
  }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) activity(); });
  setInterval(tick, 1000);
  start().catch((e) => showLogin(e.message));
});
