import { Stream } from './stream.js';
import { View } from './view.js';
import { Keyboard } from './keys.js';
import { Input } from './input.js';
import { pref, setPref } from './store.js';
import { RemoteCursor } from './cursor.js';
import { AudioPlayer } from './audio.js';
import { passkeyStatus, registerPasskey, unlockWithPasskey } from './passkey.js';
import { refreshTip, hideTip } from './tooltip.js';
import { initToolbar, setDock, currentDock, foldedCount, fit } from './toolbar.js';
import { tool, TOOLS, deviceClass, defaultLayout, normalizeLayout, visibleLayout, isAvailable, sections, move as moveTool, toggle as toggleTool, keyRowTop } from './tools.js';
import { startTour } from './tour.js';
import { LABELS as DOCK_LABELS } from './dock.js';
import { showTips, tipsOpen, dismissTips } from './tips.js';
import { preloadMotion, sheetIn, sheetOut, settleFrom } from './motion.js';
import { Loupe } from './loupe.js';
import { comboLabel, buildCombo, parsePinned, togglePinned, isPinned, MAX_PINNED } from './shortcuts.js';
import { formatBytes, addToDay, crossedLimit, localDay } from './usage.js';
import { idleMinutes, shouldIdlePause, shouldHiddenPause, HIDDEN_PAUSE_MS, DEFAULT_IDLE_MINUTES } from './idle.js';

const $ = (s) => document.querySelector(s);
const canvas = $('#screen');
const viewport = $('#viewport');
const isTouch = navigator.maxTouchPoints > 0;
document.body.classList.toggle('desktop', !isTouch);
// Phone, tablet or desktop: picks the default toolbar, and each keeps its own layout.
const DEVICE = deviceClass({ touch: isTouch, shortSide: Math.min(screen.width, screen.height) });
document.body.classList.toggle('compact', pref('toolbarLabels', true) === false);

const view = new View(canvas, viewport);
const stream = new Stream(canvas, view);
const kb = new Keyboard(stream);
const input = new Input({ stream, view, keyboard: kb, surface: viewport });
const cursor = new RemoteCursor(viewport, view, { touch: isTouch });
input.cursor = cursor;
const audio = new AudioPlayer(stream);
stream.onAudio = (bytes) => audio.onFrame(bytes);
input.touchMode = pref('touchMode', 'trackpad');
cursor.scale = pref('pointerScale', 1);
const loupe = new Loupe(canvas, view, cursor);
loupe.enabled = pref('loupe', true);
input.onFinger = (state, x, y) => {
  if (state === 'start') loupe.show(x, y);
  else if (state === 'move') loupe.move(x, y);
  else loupe.hide();
};

let hello = null;
let currentDisplay = pref('display', null);
let lastMacClip = '';
let autoInfo = null;
let fitMode = 'off';
const sendFit = (mode) => stream.send({ t: 'fit', mode, w: innerWidth, h: innerHeight });
let fitResizeTimer;
addEventListener('resize', () => {
  if (fitMode === 'off') return;
  clearTimeout(fitResizeTimer);
  fitResizeTimer = setTimeout(() => sendFit(fitMode), 600); // e.g. rotating the phone
});
const codecs = Stream.support() ? ['h264'] : await Stream.detectCodecs();

stream.helloExtra = () => ({ quality: pref('quality', 'auto'), display: currentDisplay ?? undefined, codecs });

function el(tag, props = {}, ...children) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'onclick') n.addEventListener('click', v);
    else if (k in n) n[k] = v;
    else n.setAttribute(k, v);
  }
  n.append(...children);
  return n;
}
const SVG = 'http://www.w3.org/2000/svg';
function icon(name, className = 'i') {
  const s = document.createElementNS(SVG, 'svg');
  s.setAttribute('class', className);
  s.setAttribute('aria-hidden', 'true');
  const u = document.createElementNS(SVG, 'use');
  u.setAttribute('href', `icons.svg#${name}`);
  s.append(u);
  return s;
}
const macName = () => hello?.name || 'your Mac';

// ---------- Status screen ----------
// One card for every "not showing the screen yet" state: icon, title, one line, one main action.
const STATE_ICON = { paused: 'pause-circle', locked: 'lock-simple', passkey: 'fingerprint', error: 'warning-circle', offline: 'plugs', idle: 'moon-stars' };
let helpTimer;
function status(kind, title, detail = '', actions = []) {
  dismissTips();   // a status card always wins over the first-run tips
  const s = $('#status');
  // Reconnect attempts repeat 'connecting'; keep counting toward the help from the first one.
  const stillConnecting = kind === 'connecting' && !s.hidden && s.dataset.kind === 'connecting';
  s.hidden = false;
  s.dataset.kind = kind;
  s.querySelector('.glyph use').setAttribute('href', `icons.svg#${STATE_ICON[kind] || 'desktop'}`);
  $('#status-text').textContent = title;
  $('#status-detail').textContent = detail;
  $('#status-actions').replaceChildren(...actions.map((a, i) => {
    const b = el('button', { className: i === 0 && !a.secondary ? 'primary' : 'secondary', textContent: a.label });
    b.addEventListener('click', async () => {
      b.disabled = true;
      try { await a.run(); } catch (err) {
        $('#status-detail').textContent = err.name === 'NotAllowedError' ? 'Cancelled. Tap to try again.' : err.message;
      } finally { b.disabled = false; }
    });
    return b;
  }));
  if (!stillConnecting) {
    clearTimeout(helpTimer);
    $('#status-help').hidden = true;
    if (kind === 'connecting') helpTimer = setTimeout(showConnectHelp, 8000);
  } else if (!$('#status-help').hidden) {
    showConnectHelp(); // re-adds the Try again button the action reset removed
  }
  input.enabled = false;
}
function hideStatus() {
  clearTimeout(helpTimer);
  $('#status').hidden = true;
  input.enabled = !sheetOpen() && !tipsOpen();
}
// Still connecting after 8 seconds: list the things the person can actually check.
function showConnectHelp() {
  const item = (strong, rest) => el('li', {}, el('strong', { textContent: strong }), ` ${rest}`);
  $('#status-help').replaceChildren(
    item('Is Tailscale on?', 'Open Tailscale on this device and check it says Connected.'),
    item('Is the Mac awake?', 'A Mac that is asleep or shut down can\'t answer. Wake it or turn on "Wake for network access".'),
    item('Is Tether running?', 'Look for the Tether icon in the Mac\'s menu bar. If it\'s paused, resume it there.'));
  $('#status-help').hidden = false;
  if (!$('#status-actions').children.length) {
    $('#status-actions').append(el('button', { className: 'secondary', textContent: 'Try again', onclick: () => stream.reconnect() }),
      el('button', { className: 'secondary', textContent: 'Your other Macs', onclick: openMacsSheet }));
  }
}

function deviceName() {
  const ua = navigator.userAgent;
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return 'iPad';
  if (/Android/.test(ua)) return 'Android device';
  if (/Windows/.test(ua)) return 'Windows PC';
  if (/Macintosh/.test(ua)) return 'Mac';
  return 'A device';
}
stream.deviceName = pref('deviceName', '') || deviceName();

// ---------- Passkey lock and pause ----------
let pausePoll;
let lockRequired = false;   // the Mac asks for Face ID / Touch ID (so an idle pause locks again)
const resume = () => { stream.paused = false; stream.reconnect(); };
async function passkeyGate() {
  const st = await passkeyStatus();
  lockRequired = !!st.required;
  if (st.ok) return true;
  stream.paused = true;
  if (st.paused) {
    // Remote access paused from the Mac's menu bar: wait quietly, reconnect when resumed.
    status('paused', 'Paused on the Mac', st.msg || 'Resume it from the Tether icon in the Mac\'s menu bar. This page reconnects on its own.');
    clearTimeout(pausePoll);
    pausePoll = setTimeout(async () => { if (await passkeyGate()) resume(); }, 5000);
    return false;
  }
  if (st.unreachable) {
    // Keep trying quietly; the page carries on as soon as Tether answers again.
    status('connecting', 'Reconnecting', `${macName()} isn't answering yet. Trying again.`);
    clearTimeout(pausePoll);
    pausePoll = setTimeout(async () => { if (await passkeyGate()) resume(); }, 3000);
    return false;
  }
  if (st.enrolled) {
    status('locked', 'Locked', 'Unlock with Face ID or Touch ID to see your Mac.',
      [{ label: 'Unlock', run: async () => { await unlockWithPasskey(); resume(); } }]);
  } else if (st.enrolling) {
    status('passkey', 'Set up a passkey', 'This Mac asks for Face ID or Touch ID. Create a passkey for this device to continue.',
      [{ label: 'Create passkey', run: async () => { await registerPasskey(stream.deviceName); resume(); } }]);
  } else {
    status('passkey', 'Passkey required', 'On the Mac, open the Tether menu and choose "Add a passkey from a device", then reload this page.',
      [{ label: 'Reload', run: async () => location.reload() }]);
  }
  return false;
}
stream.beforeReconnect = passkeyGate;

const unsupported = Stream.support();
if (unsupported) {
  status('error', 'This browser can\'t show the screen', unsupported);
} else {
  status('connecting', 'Connecting to your Mac');
  if (await passkeyGate()) stream.connect();
}

stream.addEventListener('connecting', () => { if (!stream.hasVideo) status('connecting', `Connecting to ${macName()}`); });
stream.addEventListener('open', () => {
  if (viewOnly) stream.send({ t: 'observe', on: true });
  if (!stream.hasVideo) status('connecting', `Connecting to ${macName()}`, 'Waiting for the first picture.');
});
stream.addEventListener('firstframe', () => {
  hideStatus();
  preloadMotion();
  setTimeout(() => runTips(false), 600);
});
stream.addEventListener('close', () => {
  stream.hasVideo = false;
  updateConnection();
  status('connecting', 'Reconnecting', `Lost the connection to ${macName()}. Trying again.`);
});
// The Mac was updated while this page was open: load the new page so both sides match. An unsent
// Compose draft is never thrown away; the person reloads when ready.
let pageVersion = null;
function checkVersion(version) {
  if (!version) return;
  pageVersion ??= version;
  if (version === pageVersion) return;
  if ($('#compose-area')?.value) toast('Tether was updated on the Mac', { label: 'Reload', run: () => location.reload() }, 0);
  else location.reload();
}

stream.addEventListener('hello', (e) => {
  hello = e.detail;
  checkVersion(hello.version);
  currentDisplay = hello.display;
  document.title = `${hello.name} · Tether`;
  curtainOn = !!hello.curtain;
  renderToolbar();   // help links and the Mac's name arrive with hello
  const missing = [];
  if (!hello.perms?.screen) missing.push('Screen Recording');
  if (!hello.perms?.input) missing.push('Accessibility');
  showMacState(hello.state);
  if (missing.length) toast(`On the Mac, allow Tether in Privacy & Security: ${missing.join(' and ')}.`, null, 9000);
});
stream.addEventListener('display', (e) => { currentDisplay = e.detail.id; });
stream.addEventListener('windows', (e) => windowsReply?.(e.detail.list || []));
stream.addEventListener('target', (e) => {
  const one = e.detail.window != null;
  $('[data-action="wholescreen"]').hidden = !one;
  if (one) toast(`Showing only ${e.detail.app}: ${e.detail.title}`);
  fit();
});
stream.addEventListener('curtain', (e) => {
  curtainOn = !!e.detail.on;
  syncToolState();
  toast(curtainOn ? 'Curtain on. The Mac\'s own screen is black.' : 'Curtain off');
});
stream.addEventListener('state', (e) => showMacState(e.detail));
stream.addEventListener('cursor', (e) => {
  cursor.setRemote(e.detail.x, e.detail.y);
  view.follow(e.detail.x, e.detail.y);
});
stream.addEventListener('cursorShape', (e) => cursor.setShape(e.detail));
stream.addEventListener('quality', (e) => { autoInfo = e.detail; });
stream.addEventListener('fit', (e) => { fitMode = e.detail.mode; });
stream.addEventListener('config', (e) => { if (e.detail.auto) autoInfo = { ...autoInfo, maxWidth: e.detail.w }; });
stream.addEventListener('error', (e) => {
  if (stream.hasVideo) toast(e.detail.msg, null, 6000);
  else status('error', 'Can\'t show the screen', e.detail.msg, [{ label: 'Try again', run: () => stream.reconnect() }]);
});
let lastMacHTML = null;
let lastMacImage = null;   // { id, w, h }
stream.addEventListener('clip', (e) => {
  if (e.detail.kind === 'image') {
    lastMacImage = { id: e.detail.id, w: e.detail.w, h: e.detail.h };
    toast(`Mac copied an image (${e.detail.w} × ${e.detail.h})`, { label: 'Copy', run: () => copyMacImage(lastMacImage.id) }, 8000);
    return;
  }
  lastMacClip = e.detail.s;
  lastMacHTML = e.detail.html || null;
  const preview = lastMacClip.replace(/\s+/g, ' ').slice(0, 60);
  toast(`Mac copied: "${preview}"`, { label: 'Copy', run: () => copyLocal(lastMacClip, lastMacHTML) }, 6000);
});

// Copies the Mac's image to this device. The fetch promise goes straight into the ClipboardItem,
// so Safari still counts the tap as the user gesture it needs.
function copyMacImage(id) {
  try {
    const blob = fetch(`clipboard/image?id=${id}`).then((r) => { if (!r.ok) throw new Error('gone'); return r.blob(); });
    navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })])
      .then(() => toast('Image copied to this device'))
      .catch(() => toast('Couldn\'t copy the image. Open Clipboard to save it instead.'));
  } catch { toast('This browser can\'t copy images. Open Clipboard to save it instead.'); }
}

// ---------- Saving power: idle and background pauses ----------
// After a stretch with no interaction, or when the page goes out of sight, stop streaming so the
// Mac can stop capturing and let its display sleep. Coming back resumes (with Face ID again if
// the Mac requires it).
let lastActive = Date.now();
let lastActivitySent = 0;
let pausedReason = null;   // 'idle' | 'hidden' | null
let hiddenSince = null;
let hiddenTimer;
let viewOnly = false;
let curtainOn = false;
const idleLimit = () => idleMinutes(location.search, pref('idleMinutes', DEFAULT_IDLE_MINUTES));

function noteActivity() {
  lastActive = Date.now();
  // Tell the Mac now and then, so its panel doesn't call a zooming, scrolling person "idle".
  if (stream.connected && lastActive - lastActivitySent > 30_000) { lastActivitySent = lastActive; stream.send({ t: 'activity' }); }
}
for (const ev of ['pointerdown', 'keydown', 'wheel', 'touchstart']) document.addEventListener(ev, noteActivity, { capture: true, passive: true });
document.addEventListener('pointermove', (e) => { if (e.pointerType === 'mouse') noteActivity(); }, { capture: true, passive: true });

setInterval(() => {
  if (pausedReason || !stream.hasVideo) return;
  if (shouldIdlePause({ now: Date.now(), lastActive, minutes: idleLimit(), audioOn: audio.on, viewOnly,
    visible: document.visibilityState === 'visible' })) pauseFor('idle');
}, 5000);

function pauseFor(reason) {
  if (pausedReason) return;
  kb.releaseAll();
  pausedReason = reason;
  stream.pause();
  closeSheet();
  if (lockRequired) fetch('auth/lock', { method: 'POST' }).catch(() => {});
  const resumeAction = [{ label: 'Resume', run: resumeNow }];
  if (reason === 'idle') {
    const m = Math.round(idleLimit());
    const span = m >= 1 ? `${m} minute${m === 1 ? '' : 's'}` : 'a little while';
    status('idle', 'Paused to save power', `Nothing happened for ${span}, so Tether stopped streaming and ${macName()} can rest. Tap anywhere to pick up where you left off.`, resumeAction);
  } else {
    status('idle', 'Paused in the background', 'Tether stops streaming while this page is out of sight, and reconnects when you come back.', resumeAction);
  }
}

async function resumeNow() {
  if (!pausedReason) return;
  pausedReason = null;
  lastActive = Date.now();
  status('connecting', `Connecting to ${macName()}`);
  if (await passkeyGate()) { stream.paused = false; stream.retry = 0; stream.connect(); }
}
$('#status').addEventListener('click', (e) => {
  if ($('#status').dataset.kind === 'idle' && !e.target.closest('button')) resumeNow();
});

document.addEventListener('visibilitychange', () => {
  clearTimeout(hiddenTimer);
  if (document.visibilityState === 'visible') {
    hiddenSince = null;
    if (pausedReason === 'hidden') { resumeNow(); return; }
    if (pausedReason) return;
    if (!stream.connected) stream.reconnect(); else stream.requestKeyframe();
    return;
  }
  kb.releaseAll();
  hiddenSince = Date.now();
  if (audio.on || pausedReason) return;
  // Phones and tablets freeze background pages (timers stop), so pause straight away there;
  // desktop browsers get a minute's grace for a quick look at another tab.
  if (isTouch) { pauseFor('hidden'); return; }
  hiddenTimer = setTimeout(() => {
    if (shouldHiddenPause({ now: Date.now(), hiddenSince, audioOn: audio.on })) pauseFor('hidden');
  }, HIDDEN_PAUSE_MS + 100);
});

// ---------- View only and curtain ----------
function setViewOnly(on) {
  viewOnly = on;
  if (on) kb.releaseAll();
  stream.observe = on;
  stream.send({ t: 'observe', on });
  document.body.classList.toggle('view-only', on);
  $('[data-chip="viewonly"]').hidden = !on;
  if (on && document.activeElement === sink) sink.blur();
  renderToolbar();   // typing tools step aside in view only
  toast(on ? 'View only. Your taps and typing won\'t reach the Mac.' : 'You can control the Mac again');
}
function setCurtain(on) {
  stream.send({ t: 'curtain', on });
}
function openLink(name) {
  const url = hello?.links?.[name];
  if (url) window.open(url, '_blank', 'noopener');
}

addEventListener('blur', () => kb.releaseAll());

// ---------- Connection quality (toolbar chip) ----------
function quality() {
  if (!stream.connected || !stream.hasVideo) return '';
  const rtt = stream.stats.rtt;
  return rtt < 70 ? 'good' : rtt < 160 ? 'fair' : 'poor';
}
const QUALITY_WORD = { good: 'Good connection', fair: 'Slower connection', poor: 'Poor connection' };
// One line about the connection, from live state (shared by the toolbar item and More).
function connectionLine() {
  const q = quality();
  const s = stream.stats;
  if (q) return `${QUALITY_WORD[q]}: ${Math.round(s.rtt)} ms, ${s.fps} fps. This session: ${formatBytes(stream.sessionBytes)}`;
  if (pausedReason) return 'Paused';
  if (stream.connected) return 'Connected, waiting for the picture';
  return 'Connecting';
}
function updateConnection() {
  const q = quality();
  const line = connectionLine();
  for (const b of document.querySelectorAll('[data-action="status"]')) {
    b.querySelector('.dot').dataset.q = q;
    const lbl = b.querySelector('.lbl');
    if (lbl) lbl.textContent = hello?.name || 'Mac';
    if (b.closest('#toolbar')) {
      b.dataset.tip = macName();
      b.dataset.hint = line;
      b.setAttribute('aria-label', `${macName()}. ${line}`);
      refreshTip(b);
    } else {
      const detail = b.querySelector('small');
      if (detail) detail.textContent = line;
    }
  }
}
setInterval(updateConnection, 2000);

// ---------- Data meter ----------
let countedBytes = 0;
let usageWarned = false;
function usage() {
  return { session: stream.sessionBytes, today: (pref('usage', null)?.day === localDay() ? pref('usage', null).bytes : 0) };
}
setInterval(() => {
  const now = stream.sessionBytes;
  const delta = now - countedBytes;
  if (delta <= 0) return;
  setPref('usage', addToDay(pref('usage', null), delta, localDay()));
  if (!usageWarned && crossedLimit(countedBytes, now, pref('usageWarn', 0))) {
    usageWarned = true;
    toast(`You've used ${formatBytes(now)} this session.`, pref('quality', 'auto') === 'saver' ? null
      : { label: 'Battery saver', run: () => { setPref('quality', 'saver'); stream.send({ t: 'quality', preset: 'saver' }); } }, 10000);
  }
  countedBytes = now;
}, 5000);

// ---------- Mac state banner (asleep / locked) ----------
function showMacState(state) {
  const banner = $('#banner');
  if (!state || (!state.asleep && !state.locked)) { banner.hidden = true; return; }
  const text = state.asleep
    ? 'The Mac\'s display is asleep.'
    : 'The Mac is locked. Open the keyboard, type your password, then press Return.';
  banner.replaceChildren(icon(state.asleep ? 'moon' : 'lock-simple'), el('span', { className: 'text', textContent: text }));
  if (state.asleep) banner.append(el('button', { textContent: 'Wake', onclick: () => stream.send({ t: 'wake' }) }));
  else banner.append(el('button', { textContent: 'Keyboard', onclick: () => actions.keyboard() }));
  banner.hidden = false;
}

// ---------- Hardware keyboard ----------
const sink = $('#kbd-sink');
const sheetOpen = () => !$('#sheet').hidden;

document.addEventListener('keydown', (e) => {
  if (sheetOpen() || tipsOpen()) return;
  const fromSink = e.target === sink;
  // Printable chars typed into the soft-keyboard sink go through the text path,
  // which handles iOS keyboards (shift state, autocomplete) correctly.
  if (fromSink && e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) return;
  if (kb.handleKeyDown(e)) e.preventDefault();
}, true);
document.addEventListener('keyup', (e) => {
  if (sheetOpen() || tipsOpen()) return;
  if (kb.handleKeyUp(e)) e.preventDefault();
}, true);

// ---------- Soft keyboard (iPhone / iPad) ----------
const SENTINEL = ' ';
sink.value = SENTINEL;
sink.addEventListener('beforeinput', (e) => {
  switch (e.inputType) {
    case 'insertText':
    case 'insertReplacementText':
      kb.text(e.data ?? e.dataTransfer?.getData('text/plain') ?? '');
      break;
    case 'insertLineBreak':
    case 'insertParagraph':
      kb.tap('Enter');
      break;
    case 'deleteContentBackward':
    case 'deleteWordBackward':
      kb.tap('Backspace');
      break;
    case 'deleteContentForward':
      kb.tap('Delete');
      break;
    default:
      return;
  }
  e.preventDefault();
});
// Fallback if a browser ignores preventDefault on beforeinput.
sink.addEventListener('input', () => {
  const v = sink.value;
  if (v.length < SENTINEL.length) kb.tap('Backspace');
  else if (v.startsWith(SENTINEL)) kb.text(v.slice(SENTINEL.length));
  sink.value = SENTINEL;
});

// ---------- Toolbar ----------
// Drawn from web/js/tools.js: the person's tools in their order (Edit toolbar), each an icon with a
// short label (unless Compact is on), then More. Pinned shortcuts follow the tools.
let sticky = new Map();
const toolbar = $('#toolbar');
const pill = $('#toolbar-show');
const toolsBox = toolbar.querySelector('.tools');
const layoutKey = `toolbar:${DEVICE}`;
const layout = () => normalizeLayout(pref(layoutKey, null), DEVICE);
const toolCtx = () => ({ control: !viewOnly, desktop: !isTouch, pointerCapture: pointerCaptureAvailable(), links: !!hello?.links });

function setToolbarHidden(h) {
  hideTip();
  toolbar.hidden = h;
  pill.hidden = !h;
  setPref('toolbarHidden', h);
  if (!h) fit();
}

function toolButton(t) {
  const b = el('button', { className: `tool${t.status ? ' status' : ''}`, 'aria-label': t.label },
    icon(t.icon), el('span', { className: 'lbl', textContent: t.short }));
  b.dataset.action = t.id;
  b.dataset.tip = t.label;
  b.dataset.hint = t.hint;
  if (t.toggle) b.setAttribute('aria-pressed', 'false');
  if (t.status) b.append(el('span', { className: 'dot', 'aria-hidden': 'true' }));
  return b;
}

function pinButton(p) {
  const b = el('button', { className: 'tool pin', 'aria-label': p.label },
    el('span', { className: 'combo', textContent: comboLabel(p.combo) }), el('span', { className: 'lbl', textContent: p.label }));
  b.dataset.tip = p.label;
  b.dataset.hint = `Sends ${comboLabel(p.combo)} to the Mac`;
  b.addEventListener('click', (e) => { e.stopPropagation(); kb.combo(p.combo); });
  return b;
}

function renderToolbar() {
  const ctx = toolCtx();
  const ids = visibleLayout(layout(), ctx);
  const pins = ctx.control ? parsePinned(pref('pinned', [])) : [];
  const before = ids.filter((id) => id !== 'status');
  toolsBox.replaceChildren(...before.map((id) => toolButton(tool(id))), ...pins.map(pinButton),
    ...(ids.includes('status') ? [toolButton(tool('status'))] : []));
  syncToolState();
  updateConnection();
  fit();
}
const renderPinned = renderToolbar;

// On/off state and live icons, for every copy of a tool on screen (toolbar and More).
const toolOn = {
  keyboard: () => document.activeElement === sink,
  sound: () => audio.on,
  viewonly: () => viewOnly,
  curtain: () => curtainOn,
};
function syncToolState() {
  for (const [id, on] of Object.entries(toolOn)) {
    for (const b of document.querySelectorAll(`[data-action="${id}"]:not(.chip)`)) {
      b.setAttribute('aria-pressed', String(on()));
      const st = b.querySelector('.state');
      if (st) { st.textContent = on() ? 'On' : 'Off'; st.classList.toggle('on', on()); }
    }
  }
  for (const u of document.querySelectorAll('[data-action="sound"] use')) u.setAttribute('href', `icons.svg#${audio.on ? 'speaker-high' : 'speaker-slash'}`);
  for (const u of document.querySelectorAll('[data-action="fullscreen"] use')) u.setAttribute('href', `icons.svg#${document.fullscreenElement ? 'arrows-in' : 'arrows-out'}`);
}

initToolbar({ onFold: () => {} });
renderToolbar();
setToolbarHidden(pref('toolbarHidden', false));
pill.addEventListener('click', () => setToolbarHidden(false));

function setLabels(on) {
  setPref('toolbarLabels', on);
  document.body.classList.toggle('compact', !on);
  fit();
}

function syncSticky() {
  for (const btn of document.querySelectorAll('[data-mod]')) {
    const state = sticky.get(btn.dataset.mod);
    btn.setAttribute('aria-pressed', String(!!state));
    btn.classList.toggle('locked', state === 'locked');
  }
}
kb.onStickyChange = (s) => { sticky = s; syncSticky(); };

// ---------- Key row (above the on-screen keyboard) ----------
// While someone types on a phone or iPad, ⌘ ⌥ ⌃ ⇧, Esc, Tab and the arrows sit right on top of the
// keyboard, and the toolbar steps aside. The buttons act on press and never take focus, so the
// keyboard stays up.
const keyrow = $('#keyrow');
function placeKeyRow() {
  if (keyrow.hidden) return;
  const vv = window.visualViewport;
  const top = keyRowTop({ vvHeight: vv?.height ?? innerHeight, vvOffsetTop: vv?.offsetTop ?? 0, rowHeight: keyrow.offsetHeight });
  keyrow.style.transform = `translateY(${top}px)`;
}
function setTyping(on) {
  if (!isTouch) return;
  keyrow.hidden = !on;
  document.body.classList.toggle('typing', on);
  if (on) { syncSticky(); placeKeyRow(); }
  hideTip();
}
function stopTyping() {
  sink.blur();
  setTyping(false);
  syncToolState();
}
window.visualViewport?.addEventListener('resize', placeKeyRow);
window.visualViewport?.addEventListener('scroll', placeKeyRow);
let repeatTimer = 0;
keyrow.addEventListener('pointerdown', (e) => {
  const b = e.target.closest('button');
  e.preventDefault();   // keep focus (and the keyboard) on the sink
  e.stopPropagation();
  if (!b) return;
  if (b.dataset.mod) { kb.toggleSticky(b.dataset.mod); return; }
  if (b.dataset.keyAction === 'done') { stopTyping(); return; }
  if (!b.dataset.key) return;
  kb.tap(b.dataset.key);
  // Hold an arrow to repeat it.
  if (b.hasAttribute('data-repeat')) {
    clearInterval(repeatTimer);
    const start = Date.now();
    repeatTimer = setInterval(() => { if (Date.now() - start > 350) kb.tap(b.dataset.key); }, 60);
  }
});
for (const ev of ['pointerup', 'pointercancel', 'pointerleave']) keyrow.addEventListener(ev, () => clearInterval(repeatTimer));
keyrow.addEventListener('touchstart', (e) => e.stopPropagation(), { passive: true });
sink.addEventListener('focus', () => { setTyping(true); syncToolState(); });
sink.addEventListener('blur', () => { setTyping(false); clearInterval(repeatTimer); syncToolState(); });

const actions = {
  keyboard: () => {
    if (document.activeElement === sink) { stopTyping(); return; }
    sink.value = SENTINEL;
    sink.focus();
    // Some browsers skip the focus event when the window itself isn't focused.
    if (document.activeElement === sink) { setTyping(true); syncToolState(); }
  },
  compose: openComposeSheet,
  keys: openKeysSheet,
  actions: openQuickSheet,
  windows: openWindowsSheet,
  macs: openMacsSheet,
  capture: () => canvas.requestPointerLock?.(),
  clipboard: openClipboardSheet,
  files: () => openFilesSheet('downloads', ''),
  sound: async () => {
    if (audio.on) { audio.stop(); syncToolState(); return; }
    try {
      await audio.start();
      toast(audio.format === 'aac' ? 'Sound on' : 'Sound on (compatibility mode)');
    } catch (err) { toast(`Couldn't start sound: ${err.message}`); }
    syncToolState();
  },
  settings: openSettingsSheet,
  fullscreen: () => (document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen?.()),
  viewonly: () => setViewOnly(!viewOnly),
  curtain: () => setCurtain(!curtainOn),
  status: openConnectionSheet,
  move: openDockSheet,
  edit: openEditToolbarSheet,
  hide: () => setToolbarHidden(true),
  tips: () => { closeSheet(); runTips(true); },
  help: () => openLink('help'),
  issues: () => openLink('issues'),
  more: openMoreSheet,
  wholescreen: () => stream.send({ t: 'captureWindow' }),
};
// First run (or More → Tips): the gesture cards, then the tour of the real toolbar.
function runTips(force) {
  input.enabled = false;
  const done = () => { input.enabled = !sheetOpen(); };
  const tour = () => {
    if (toolbar.hidden) setToolbarHidden(false);
    if (!startTour({ force, done })) done();
  };
  if (!showTips({ touch: isTouch, force, closed: tour })) tour();
}

// Tools that open a sheet of their own (from More, they replace it instead of closing it first).
const OPENS_SHEET = new Set(['compose', 'keys', 'actions', 'windows', 'macs', 'clipboard', 'files', 'settings', 'status', 'move', 'edit']);

document.addEventListener('fullscreenchange', () => {
  syncToolState();
  // In full screen, Chrome and Edge can hand ⌘W, ⌘Q and friends to the Mac instead of closing the tab.
  if (document.fullscreenElement) navigator.keyboard?.lock?.().catch(() => {});
  else navigator.keyboard?.unlock?.();
});

toolbar.addEventListener('click', (e) => {
  const btn = e.target.closest('button');
  if (!btn || btn.classList.contains('pin')) return;
  opener = btn;
  actions[btn.dataset.action]?.();
});
// Keep toolbar taps from reaching the remote screen.
for (const target of [toolbar, pill]) {
  for (const ev of ['pointerdown', 'touchstart']) target.addEventListener(ev, (e) => e.stopPropagation(), { passive: true });
}

// ---------- Sheets ----------
// Bottom sheet on phones, centred panel elsewhere. Focus stays inside while open and returns to
// the button that opened it.
const sheet = $('#sheet');
const card = $('.sheet-card');
const phoneLayout = matchMedia('(max-width: 600px)');
let opener = null;
let closing = false;

function openSheet(title, build) {
  hideTip();
  $('#sheet-title').textContent = title;
  const body = $('#sheet-body');
  body.replaceChildren();
  build(body);
  const wasOpen = sheetOpen();
  sheet.hidden = false;
  input.enabled = false;
  card.scrollTop = 0;
  if (!wasOpen) sheetIn(sheet, card, phoneLayout.matches);
  if (!isTouch) (body.querySelector('textarea, [aria-checked="true"], button') || card.querySelector('.close')).focus({ preventScroll: true });
}
async function closeSheet() {
  if (!sheetOpen() || closing) return;
  closing = true;
  await sheetOut(sheet, card, phoneLayout.matches);
  sheet.hidden = true;
  closing = false;
  input.enabled = $('#status').hidden && !tipsOpen();
  if (opener && !opener.closest('.folded') && opener.isConnected && !opener.closest('[hidden]')) opener.focus({ preventScroll: true });
  else canvas.focus({ preventScroll: true });
  opener = null;
}
sheet.addEventListener('click', (e) => {
  if (e.target === sheet || e.target.closest('[data-close]')) closeSheet();
});
addEventListener('keydown', (e) => {
  if (!sheetOpen()) return;
  if (e.key === 'Escape') { e.stopPropagation(); closeSheet(); return; }
  if (e.key === 'Tab') {
    const f = [...card.querySelectorAll('button, textarea, input, [tabindex="0"]')].filter((n) => !n.disabled && n.offsetParent);
    if (!f.length) return;
    const first = f[0];
    const last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { last.focus(); e.preventDefault(); }
    else if (!e.shiftKey && document.activeElement === last) { first.focus(); e.preventDefault(); }
    else if (!card.contains(document.activeElement)) { first.focus(); e.preventDefault(); }
  }
}, true);
for (const ev of ['pointerdown', 'touchstart']) sheet.addEventListener(ev, (e) => e.stopPropagation(), { passive: true });

// Drag the handle or header down to dismiss (phone layout).
{
  let drag = null;
  const header = card.querySelector('header');
  for (const h of [card.querySelector('.handle'), header]) {
    h.addEventListener('pointerdown', (e) => {
      if (!phoneLayout.matches || e.target.closest('button')) return;
      drag = { id: e.pointerId, y: e.clientY, dy: 0 };
      h.setPointerCapture(e.pointerId);
    });
    h.addEventListener('pointermove', (e) => {
      if (!drag || e.pointerId !== drag.id) return;
      drag.dy = Math.max(0, e.clientY - drag.y);
      card.style.transform = `translateY(${drag.dy}px)`;
    });
    const end = (e) => {
      if (!drag || e.pointerId !== drag.id) return;
      const { dy } = drag;
      drag = null;
      if (dy > 90) { card.style.transform = ''; sheet.hidden = true; closing = false; input.enabled = $('#status').hidden; opener = null; }
      else settleFrom(card, 0, dy);
    };
    h.addEventListener('pointerup', end);
    h.addEventListener('pointercancel', end);
  }
}

// ---------- More ----------
// Every tool, whether or not it's in the toolbar: the connection on top, then labeled tiles by
// section. Toggles show On or Off.
function moreTile(t) {
  const b = el('button', { className: 'tile', 'aria-label': t.label }, icon(t.icon), el('span', { textContent: t.label }));
  b.dataset.action = t.id;
  b.dataset.tip = t.label;
  b.dataset.hint = t.hint;
  if (t.toggle) {
    b.setAttribute('aria-pressed', 'false');
    b.append(el('small', { className: 'state' }));
  }
  b.addEventListener('click', () => runFromMore(t.id));
  return b;
}
function runFromMore(id) {
  if (OPENS_SHEET.has(id)) { actions[id](); return; }
  closeSheet().then(() => actions[id]?.());
}
function openMoreSheet() {
  openSheet('More', (body) => {
    const ctx = toolCtx();
    const status = el('button', { className: 'more-status', 'aria-label': `${macName()}, connection details` },
      el('span', { className: 'glyph' }, icon('desktop'), el('span', { className: 'dot', 'aria-hidden': 'true' })),
      el('span', { className: 'text' }, el('span', { className: 'lbl', textContent: macName() }), el('small', { textContent: connectionLine() })),
      icon('caret-down', 'i chevron'));
    status.dataset.action = 'status';
    status.addEventListener('click', () => runFromMore('status'));
    body.append(status);
    for (const [id, title, list] of sections(ctx)) {
      const tiles = list.map(moreTile);
      if (id === 'type') {
        for (const p of parsePinned(pref('pinned', []))) {
          if (!ctx.control) break;
          tiles.push(el('button', { className: 'tile', onclick: () => { closeSheet(); kb.combo(p.combo); } },
            el('span', { className: 'combo', textContent: comboLabel(p.combo) }), el('span', { textContent: p.label })));
        }
      }
      body.append(el('h3', { textContent: title }), el('div', { className: 'tiles more-tiles' }, ...tiles));
    }
    syncToolState();
    updateConnection();
  });
}

// ---------- Edit toolbar ----------
// Pick which tools sit in the toolbar, and their order. Saved per kind of device.
function openEditToolbarSheet() {
  openSheet('Edit toolbar', (body) => {
    const note = el('p', { className: 'muted' });
    const list = el('div', { className: 'menu edit-list' });
    const draw = () => {
      const current = layout();
      const ctx = toolCtx();
      const others = TOOLS.filter((t) => !current.includes(t.id) && isAvailable(t, ctx) && !['edit'].includes(t.id));
      const row = (t, inBar, i) => {
        const sw = el('button', { className: 'menu-item', role: 'switch', 'aria-label': `${t.label} in the toolbar` },
          icon(t.icon), el('span', { textContent: t.label }),
          el('small', { className: `state${inBar ? ' on' : ''}`, textContent: inBar ? 'On' : 'Off' }));
        sw.dataset.tip = t.label;
        sw.dataset.hint = t.hint;
        sw.setAttribute('aria-checked', String(inBar));
        sw.addEventListener('click', () => save(toggleTool(current, t.id)));
        if (!inBar) return sw;
        const up = el('button', { className: 'reorder', 'aria-label': `Move ${t.label} earlier`, disabled: i === 0 }, icon('arrow-up'));
        const down = el('button', { className: 'reorder', 'aria-label': `Move ${t.label} later`, disabled: i === current.length - 1 }, icon('arrow-down'));
        up.addEventListener('click', () => save(moveTool(current, t.id, -1), `[aria-label="Move ${t.label} earlier"]`));
        down.addEventListener('click', () => save(moveTool(current, t.id, 1), `[aria-label="Move ${t.label} later"]`));
        return el('div', { className: 'edit-row' }, sw, up, down);
      };
      list.replaceChildren(
        el('h3', { textContent: 'In the toolbar' }),
        ...(current.length ? current.map((id, i) => row(tool(id), true, i)) : [el('p', { className: 'muted', textContent: 'Nothing yet: only More. Add tools below.' })]),
        el('h3', { textContent: 'Not in the toolbar' }),
        ...others.map((t) => row(t, false)));
      const folded = foldedCount();
      note.textContent = !folded ? 'Everything in the toolbar fits on this screen.'
        : `${folded === 1 ? '1 tool doesn\'t' : `${folded} tools don't`} fit on this screen, so the last ${folded === 1 ? 'one is' : 'ones are'} hidden. Everything is still in More.`;
    };
    const save = (next, focusSel) => {
      setPref(layoutKey, next);
      renderToolbar();
      draw();
      if (focusSel) list.querySelector(focusSel)?.focus();
    };
    const labels = toggleRow('sliders-horizontal', 'Labels under icons', pref('toolbarLabels', true), (e) => {
      const on = !pref('toolbarLabels', true);
      setLabels(on);
      const b = e.currentTarget;
      b.setAttribute('aria-checked', String(on));
      const st = b.querySelector('.state'); st.textContent = on ? 'On' : 'Off'; st.classList.toggle('on', on);
      draw();
    }, 'Turn off for a smaller, icons-only toolbar');
    body.append(note, el('div', { className: 'menu' }, labels), list,
      el('div', { className: 'row' }, el('button', { className: 'secondary', textContent: 'Reset to default', onclick: () => save(defaultLayout(DEVICE)) })),
      el('p', { className: 'muted', textContent: 'More always lists every tool. Pinned shortcuts (from Keys) sit after these.' }));
    draw();
  });
}

// A menu row that switches something on or off.
function toggleRow(glyph, label, on, run, hint = '') {
  const b = el('button', { className: 'menu-item', role: 'menuitemcheckbox', onclick: run },
    icon(glyph), el('span', {}, label, hint ? el('small', { className: 'hint', textContent: hint }) : ''), el('small', { className: `state${on ? ' on' : ''}`, textContent: on ? 'On' : 'Off' }));
  b.setAttribute('aria-checked', String(on));
  return b;
}

// Single-pointer alternative to dragging the toolbar.
function openDockSheet() {
  openSheet('Move toolbar', (body) => {
    const order = ['top-left', 'top-center', 'top-right', 'left', null, 'right', 'bottom-left', 'bottom-center', 'bottom-right'];
    body.append(el('p', { className: 'muted', textContent: 'Pick a spot, or drag the toolbar by its grip.' }),
      el('div', { className: 'dock-grid', role: 'radiogroup', 'aria-label': 'Toolbar position' }, ...order.map((dock) => {
        if (!dock) return el('div', { className: 'empty', 'aria-hidden': 'true' }, icon('desktop'));
        const b = el('button', { className: 'choice', role: 'radio', textContent: DOCK_LABELS[dock] });
        b.setAttribute('aria-checked', String(dock === currentDock()));
        b.addEventListener('click', () => { setDock(dock); closeSheet(); });
        return b;
      })));
  });
}

// ---------- Quick actions ----------
const QUICK = [
  ['speaker-low', 'Volume down', 'volumeDown'], ['speaker-high', 'Volume up', 'volumeUp'], ['speaker-x', 'Mute', 'mute'],
  ['skip-back', 'Previous', 'previous'], ['play-pause', 'Play or pause', 'playPause'], ['skip-forward', 'Next', 'next'],
  ['squares-four', 'Mission Control', 'missionControl'], ['moon', 'Sleep display', 'sleepDisplay'], ['lock-key', 'Lock screen', 'lockScreen'],
];
function tile(glyph, label, run) {
  return el('button', { className: 'tile', onclick: run }, icon(glyph), el('span', { textContent: label }));
}
function openQuickSheet() {
  openSheet('Quick actions', (body) => {
    let lockArmed = 0;
    body.append(el('div', { className: 'tiles' }, ...QUICK.map(([glyph, label, name]) => tile(glyph, label, (e) => {
      if (name === 'lockScreen' && Date.now() - lockArmed > 3000) {
        // Unlocking needs the Mac's password, so ask for a second tap.
        lockArmed = Date.now();
        e.currentTarget.querySelector('span').textContent = 'Tap again to lock';
        return;
      }
      stream.send({ t: 'action', name });
      if (name === 'sleepDisplay' || name === 'lockScreen' || name === 'missionControl') closeSheet();
    }))));
    body.append(el('h3', { textContent: 'More' }), el('div', { className: 'tiles' },
      tile('camera', 'Screenshot', () => { closeSheet(); takeScreenshot(); }),
      tile('link', 'Open a link', openLinkSheet),
      tile('magnifying-glass', 'Open an app', openAppsSheet),
      tile('command', 'Keys and shortcuts', openKeysSheet),
      tile('warning-circle', 'Force Quit', () => { stream.send({ t: 'action', name: 'forceQuit' }); closeSheet(); })));
  });
}

// Saves what's on screen to this device: the share sheet (Photos) on phones, a download elsewhere.
// The image is made synchronously so Safari still counts the tap as the share's user gesture.
function takeScreenshot() {
  if (!stream.hasVideo) { toast('Nothing on screen yet'); return; }
  const url = canvas.toDataURL('image/png');
  const bytes = Uint8Array.from(atob(url.split(',')[1]), (c) => c.charCodeAt(0));
  const stamp = new Date().toISOString().slice(0, 19).replace('T', ' at ').replace(/:/g, '.');
  const name = `${(hello?.name || 'Mac').replace(/[^\w ]+/g, '')} ${stamp}.png`;
  const file = new File([bytes], name, { type: 'image/png' });
  if (navigator.canShare?.({ files: [file] })) {
    navigator.share({ files: [file] }).then(() => toast('Screenshot shared')).catch((err) => {
      if (err.name !== 'AbortError') toast(`Couldn't share the screenshot: ${err.message}`);
    });
    return;
  }
  const a = el('a', { href: URL.createObjectURL(file), download: name });
  document.body.append(a); a.click(); a.remove();
  toast('Screenshot saved');
}

function openLinkSheet() {
  openSheet('Open a link on the Mac', (body) => {
    const field = el('input', { type: 'url', placeholder: 'https://', className: 'field', 'aria-label': 'Link to open on the Mac',
      autocapitalize: 'off', autocorrect: 'off', inputMode: 'url', enterKeyHint: 'go' });
    const go = () => {
      let v = field.value.trim();
      if (v && !/^https?:\/\//i.test(v)) v = `https://${v}`;
      try { const u = new URL(v); if (!/^https?:$/.test(u.protocol)) throw new Error(); } catch { toast('That doesn\'t look like a web link'); return; }
      stream.send({ t: 'openURL', url: v });
      toast('Opening on the Mac');
      closeSheet();
    };
    field.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
    body.append(field, el('div', { className: 'row' }, el('button', { className: 'primary', textContent: 'Open on the Mac', onclick: go })),
      el('p', { className: 'muted', textContent: 'It opens in the Mac\'s default browser.' }));
    setTimeout(() => field.focus(), 50);
  });
}

async function openAppsSheet() {
  openSheet('Open an app', (body) => {
    const field = el('input', { type: 'search', placeholder: 'Search apps', className: 'field', 'aria-label': 'Search apps',
      autocapitalize: 'off', autocorrect: 'off', enterKeyHint: 'go' });
    const list = el('div', { className: 'list' }, el('p', { className: 'muted', textContent: 'Loading the Mac\'s apps.' }));
    body.append(field, el('div', { style: 'height:8px' }), list);
    let apps = [];
    const render = () => {
      const q = field.value.trim().toLowerCase();
      const shown = apps.filter((a) => a.name.toLowerCase().includes(q)).slice(0, 60);
      list.replaceChildren(...(shown.length ? shown.map((a) => el('button', { className: 'choice', textContent: a.name, onclick: () => {
        stream.send({ t: 'openApp', path: a.path });
        toast(`Opening ${a.name}`);
        closeSheet();
      } })) : [el('div', { className: 'empty' }, icon('magnifying-glass'), el('span', { textContent: 'No app by that name.' }))]));
    };
    field.addEventListener('input', render);
    field.addEventListener('keydown', (e) => { if (e.key === 'Enter') list.querySelector('button')?.click(); });
    fetch('apps').then((r) => r.json()).then((d) => { apps = d.apps || []; render(); })
      .catch(() => list.replaceChildren(el('p', { className: 'muted', textContent: 'Couldn\'t load the Mac\'s apps.' })));
    if (!isTouch) setTimeout(() => field.focus(), 50);
  });
}

// ---------- Windows (switcher and single-window mode) ----------
let windowsReply = null;
function openWindowsSheet() {
  openSheet('Windows', (body) => {
    const list = el('div', { className: 'list' }, el('p', { className: 'muted', textContent: 'Finding the Mac\'s windows.' }));
    let fitOn = pref('windowFit', isTouch);
    const fitRow = toggleRow('arrows-out', 'Fit to this device', fitOn, (e) => {
      fitOn = !fitOn;
      setPref('windowFit', fitOn);
      const b = e.currentTarget;
      b.setAttribute('aria-checked', String(fitOn));
      const st = b.querySelector('.state'); st.textContent = fitOn ? 'On' : 'Off'; st.classList.toggle('on', fitOn);
    }, 'Resizes the window to your screen\'s shape while you use it');
    body.append(el('p', { className: 'muted', textContent: 'Tap a window to bring it to the front, or Show only to see just that window.' }),
      el('div', { className: 'menu' }, fitRow), list);
    windowsReply = (wins) => {
      windowsReply = null;
      list.replaceChildren();
      if (!wins.length) { list.append(el('div', { className: 'empty' }, icon('app-window'), el('span', { textContent: 'No windows are open on the Mac.' }))); return; }
      for (const w of wins) {
        const img = w.icon ? el('img', { className: 'app-icon', src: `data:image/png;base64,${w.icon}`, alt: '' }) : icon('app-window');
        list.append(el('div', { className: 'window-row' },
          el('button', { className: 'choice window-main', onclick: () => { stream.send({ t: 'focusWindow', id: w.id }); toast(`${w.app} is in front`); closeSheet(); } },
            img, el('span', { className: 'name' }, el('strong', { textContent: w.app }), el('small', { textContent: w.title }))),
          el('button', { className: 'secondary', textContent: 'Show only', onclick: () => {
            stream.send({ t: 'captureWindow', id: w.id, fit: fitOn, aspect: innerWidth / innerHeight });
            closeSheet();
          } })));
      }
    };
    stream.send({ t: 'windows' });
  });
}

// ---------- Your Macs ----------
function openMacsSheet() {
  openSheet('Your Macs', (body) => {
    const grid = el('div', { className: 'macs' }, el('p', { className: 'muted', textContent: 'Looking for your Macs.' }));
    body.append(grid);
    loadMacs(grid, true);
  });
}

// ---------- Pointer capture ----------
function pointerCaptureAvailable() { return 'requestPointerLock' in canvas && (!isTouch || matchMedia('(any-pointer: fine)').matches); }
document.addEventListener('pointerlockchange', () => {
  toast(document.pointerLockElement ? 'Pointer captured. Press Esc to release it.' : 'Pointer released');
});


// ---------- Keys and shortcuts ----------
const KEYS = [
  ['esc', 'Escape'], ['tab', 'Tab'], ['⌫', 'Backspace'], ['⌦', 'Delete'], ['return', 'Enter'], ['space', 'Space'],
  ['←', 'ArrowLeft'], ['↑', 'ArrowUp'], ['↓', 'ArrowDown'], ['→', 'ArrowRight'],
  ['home', 'Home'], ['end', 'End'], ['pg up', 'PageUp'], ['pg dn', 'PageDown'],
  ...Array.from({ length: 12 }, (_, i) => [`F${i + 1}`, `F${i + 1}`]),
];
const SHORTCUTS = [
  ['Spotlight', ['MetaLeft', 'Space']], ['Switch app', ['MetaLeft', 'Tab']], ['Mission Control', ['ControlLeft', 'ArrowUp']],
  ['Copy', ['MetaLeft', 'KeyC']], ['Paste', ['MetaLeft', 'KeyV']], ['Undo', ['MetaLeft', 'KeyZ']],
  ['Close window', ['MetaLeft', 'KeyW']], ['Quit app', ['MetaLeft', 'KeyQ']], ['New tab', ['MetaLeft', 'KeyT']],
  ['Screenshot', ['MetaLeft', 'ShiftLeft', 'Digit4']], ['Force Quit', ['MetaLeft', 'AltLeft', 'Escape']],
  ['Lock screen', ['ControlLeft', 'MetaLeft', 'KeyQ']],
];

function openKeysSheet() {
  openSheet('Keys and shortcuts', (body) => {
    // Sticky modifiers: tap one, then a key or a click on the screen (⌘-click). Double-tap keeps it on.
    body.append(el('h3', { textContent: 'Modifier keys' }),
      el('div', { className: 'mods-row', role: 'group', 'aria-label': 'Modifier keys' }, ...[['MetaLeft', '⌘', 'Command'], ['AltLeft', '⌥', 'Option'], ['ControlLeft', '⌃', 'Control'], ['ShiftLeft', '⇧', 'Shift']].map(([code, sym, name]) => {
        const b = el('button', { className: 'choice', textContent: sym, 'aria-label': name, onclick: () => kb.toggleSticky(code) });
        b.dataset.mod = code;
        return b;
      })),
      el('p', { className: 'muted', textContent: 'Tap one, then a key or a click on the screen. Double-tap to keep it on.' }));
    syncSticky();
    body.append(el('h3', { textContent: 'Keys' }),
      el('div', { className: 'grid' }, ...KEYS.map(([label, code]) =>
        el('button', { className: 'key-btn', textContent: label, onclick: () => kb.tap(code) }))));
    let editing = false;
    const shortcutsGrid = el('div', { className: 'grid' });
    const drawShortcuts = () => {
      const pinned = parsePinned(pref('pinned', []));
      shortcutsGrid.replaceChildren(...SHORTCUTS.map(([label, combo]) => {
        const on = isPinned(pinned, combo);
        const b = el('button', { className: `key-btn${editing && on ? ' pinned-on' : ''}`, textContent: editing ? `${on ? 'Unpin' : 'Pin'} ${label}` : label,
          onclick: () => {
            if (!editing) { kb.combo(combo); closeSheet(); return; }
            const next = togglePinned(pinned, { label, combo });
            if (next.length === pinned.length && !on) toast(`You can pin up to ${MAX_PINNED}`);
            setPref('pinned', next); renderPinned(); drawShortcuts();
          } });
        return b;
      }));
    };
    drawShortcuts();
    const editBtn = el('button', { className: 'link', textContent: 'Pin to toolbar', onclick: () => {
      editing = !editing; editBtn.textContent = editing ? 'Done' : 'Pin to toolbar'; builder.hidden = !editing; drawShortcuts();
    } });
    // Build your own: modifiers plus one key.
    const mods = new Set(['MetaLeft']);
    const modRow = el('div', { className: 'mods-row' }, ...[['ControlLeft', '⌃'], ['AltLeft', '⌥'], ['ShiftLeft', '⇧'], ['MetaLeft', '⌘']].map(([code, sym]) => {
      const b = el('button', { className: 'choice', textContent: sym, 'aria-label': code.replace('Left', '') });
      b.setAttribute('aria-pressed', String(mods.has(code)));
      b.addEventListener('click', () => { mods.has(code) ? mods.delete(code) : mods.add(code); b.setAttribute('aria-pressed', String(mods.has(code))); });
      return b;
    }));
    const keyField = el('input', { className: 'field', placeholder: 'Key, like K or 4', maxLength: 1, 'aria-label': 'Key', autocapitalize: 'characters' });
    const nameField = el('input', { className: 'field', placeholder: 'Name, like Clear history', 'aria-label': 'Shortcut name', maxLength: 30 });
    const builder = el('div', { className: 'builder', hidden: true },
      el('h3', { textContent: 'Your own shortcut' }), modRow, el('div', { className: 'row' }, keyField, nameField),
      el('div', { className: 'row' }, el('button', { className: 'primary', textContent: 'Pin it', onclick: () => {
        const ch = keyField.value.trim().toUpperCase();
        const key = /^[A-Z]$/.test(ch) ? `Key${ch}` : /^[0-9]$/.test(ch) ? `Digit${ch}` : '';
        const combo = buildCombo([...mods], key);
        if (!combo) { toast('Type one letter or number for the key'); return; }
        const pinned = parsePinned(pref('pinned', []));
        if (pinned.length >= MAX_PINNED) { toast(`You can pin up to ${MAX_PINNED}`); return; }
        setPref('pinned', togglePinned(pinned, { label: nameField.value.trim() || comboLabel(combo), combo }));
        renderPinned(); keyField.value = ''; nameField.value = '';
        toast(`Pinned ${comboLabel(combo)} to the toolbar`);
      } })));
    body.append(el('div', { className: 'section-head' }, el('h3', { textContent: 'Shortcuts' }), editBtn), shortcutsGrid, builder);
  });
}

// ---------- Clipboard ----------
async function copyLocal(text, html = null) {
  try {
    if (html && window.ClipboardItem) {
      await navigator.clipboard.write([new ClipboardItem({
        'text/plain': new Blob([text], { type: 'text/plain' }), 'text/html': new Blob([html], { type: 'text/html' }) })]);
    } else {
      await navigator.clipboard.writeText(text);
    }
    toast(html ? 'Copied with formatting' : 'Copied to this device');
  } catch {
    toast('Couldn\'t copy. Open Clipboard to select it by hand.');
  }
}

// Sends an image from this device's clipboard to the Mac's clipboard.
async function pasteImageToMac() {
  try {
    const items = await navigator.clipboard.read();
    const item = items.find((i) => i.types.some((t) => t.startsWith('image/')));
    if (!item) { toast('There\'s no image on this device\'s clipboard'); return; }
    const blob = await item.getType(item.types.find((t) => t.startsWith('image/')));
    const r = await fetch('clipboard/image', { method: 'POST', body: blob });
    const d = await r.json().catch(() => ({}));
    toast(r.ok ? 'Image is on the Mac\'s clipboard. Press ⌘V there to paste it.' : (d.error || 'Couldn\'t send the image'));
  } catch { toast('Clipboard access was blocked. Allow pasting when the browser asks.'); }
}

function sendClip(text, paste) {
  if (!text) return;
  stream.send({ t: 'setclip', s: text });
  if (paste) setTimeout(() => kb.combo(['MetaLeft', 'KeyV']), 150);
  toast(paste ? 'Pasted on the Mac' : 'Sent to the Mac\'s clipboard');
}

function openClipboardSheet() {
  openSheet('Clipboard', (body) => {
    const area = el('textarea', { placeholder: 'Type or paste text to send to the Mac', 'aria-label': 'Text to send to the Mac' });
    body.append(
      el('h3', { textContent: 'From the Mac' }),
      lastMacClip
        ? el('div', {}, el('textarea', { readOnly: true, value: lastMacClip, 'aria-label': 'Last text copied on the Mac' }),
            el('div', { className: 'row' }, el('button', { className: 'primary', textContent: 'Copy to this device', onclick: () => copyLocal(lastMacClip) })))
        : el('div', { className: 'empty' }, icon('clipboard-text'), el('span', { textContent: 'Copy something on the Mac and it shows up here.' })),
      ...(lastMacImage ? [el('h3', { textContent: 'Image from the Mac' }),
        el('img', { className: 'clip-image', src: `clipboard/image?id=${lastMacImage.id}`, alt: 'Image copied on the Mac' }),
        el('div', { className: 'row' },
          el('button', { className: 'secondary', textContent: 'Copy image', onclick: () => copyMacImage(lastMacImage.id) }),
          el('a', { className: 'secondary button-link', textContent: 'Save image', href: `clipboard/image?id=${lastMacImage.id}`, download: 'Mac clipboard.png' }))] : []),
      el('h3', { textContent: 'To the Mac' }),
      area,
      el('div', { className: 'row' },
        el('button', { className: 'secondary', textContent: 'Paste here', onclick: async () => {
          try { area.value = await navigator.clipboard.readText(); } catch { toast('Clipboard access was blocked. Paste into the box instead.'); }
        } }),
        el('button', { className: 'secondary', textContent: 'Send', onclick: () => { sendClip(area.value, false); closeSheet(); } }),
        el('button', { className: 'secondary', textContent: 'Paste image', onclick: pasteImageToMac }),
        el('button', { className: 'primary', textContent: 'Send and paste', onclick: () => { sendClip(area.value, true); closeSheet(); } })),
    );
  });
}

function segmented(options, current, onPick, label) {
  const wrap = el('div', { className: 'segmented', role: 'radiogroup', 'aria-label': label });
  for (const [value, text, hint] of options) {
    const b = el('button', { className: 'choice', role: 'radio' }, text, hint ? el('small', { textContent: hint }) : '');
    b.setAttribute('aria-checked', String(value === current));
    b.addEventListener('click', () => {
      wrap.querySelectorAll('.choice').forEach((c) => c.setAttribute('aria-checked', 'false'));
      b.setAttribute('aria-checked', 'true');
      onPick(value);
    });
    wrap.append(b);
  }
  return wrap;
}

// ---------- Display and quality ----------
function openSettingsSheet() {
  openSheet('Display and quality', (body) => {
    const displays = hello?.displays ?? [];
    if (displays.length > 1) {
      // A live overview: each display's picture refreshes about once a second while this is open.
      const thumbs = [];
      const refresh = () => {
        if (sheet.hidden || !thumbs[0]?.isConnected) return;
        for (const t of thumbs) t.src = `thumbnail?display=${t.dataset.id}&w=320&t=${Date.now()}`;
        setTimeout(refresh, 1200);
      };
      setTimeout(refresh, 50);
      body.append(el('h3', { textContent: 'Screen' }), el('div', { className: 'list displays', role: 'radiogroup', 'aria-label': 'Screen' }, ...displays.map((d) => {
        const thumb = el('img', { className: 'display-thumb', alt: d.name });
        thumb.dataset.id = d.id;
        thumbs.push(thumb);
        const b = el('button', { className: 'choice', role: 'radio' }, thumb, d.name, el('small', { className: 'stats', textContent: `${d.w} × ${d.h}` }));
        b.setAttribute('aria-checked', String(d.id === currentDisplay));
        b.addEventListener('click', () => {
          currentDisplay = d.id;
          setPref('display', d.id);
          stream.send({ t: 'display', id: d.id });
          closeSheet();
        });
        return b;
      })));
    }
    if (hello?.fitAvailable) {
      body.append(el('h3', { textContent: 'Fit to this device' }), segmented(
        [['off', 'Off', 'Mac\'s own size'], ['mirror', 'Fit screen', 'reshapes desktop'], ['extend', 'Extra display', 'blank space']],
        fitMode,
        (m) => { fitMode = m; sendFit(m); }, 'Fit to this device'),
        el('p', { className: 'muted', textContent: 'Fit screen resizes the Mac\'s desktop to this device\'s shape while you\'re connected, and switches back when you disconnect. It uses an undocumented macOS feature.' }));
    }
    body.append(el('h3', { textContent: 'Quality' }), segmented(
      [['auto', 'Auto', 'adapts'], ['saver', 'Saver', 'battery'], ['fast', 'Fast', 'cellular'], ['balanced', 'Balanced', '1080p'], ['sharp', 'Sharp', 'full res']],
      pref('quality', 'auto'),
      (q) => { setPref('quality', q); stream.send({ t: 'quality', preset: q }); }, 'Quality'));
    body.append(el('h3', { textContent: 'Pause when idle' }), segmented(
      [[5, '5 min'], [15, '15 min'], [30, '30 min'], [0, 'Never']],
      pref('idleMinutes', DEFAULT_IDLE_MINUTES),
      (m) => setPref('idleMinutes', m), 'Pause when idle'),
      el('p', { className: 'muted', textContent: 'Stops streaming when nobody has touched anything for a while, so the Mac can rest. Not while sound is playing or in view only.' }));
    if (isTouch) {
      body.append(el('h3', { textContent: 'Touch' }), segmented(
        [['trackpad', 'Trackpad', 'drag to move'], ['direct', 'Direct', 'tap where you point']],
        input.touchMode,
        (m) => { input.touchMode = m; setPref('touchMode', m); }, 'Touch'),
        el('p', { className: 'muted' }, 'Gestures are in ', el('button', { className: 'link', textContent: 'Tips', onclick: actions.tips }), '.'));
      body.append(el('h3', { textContent: 'Pointer size' }), segmented(
        [[1, 'Normal'], [1.5, 'Large'], [2, 'Larger']], pref('pointerScale', 1),
        (v) => { setPref('pointerScale', v); cursor.scale = v; cursor.render(); }, 'Pointer size'));
      body.append(el('div', { className: 'menu' }, toggleRow('magnifying-glass', 'Magnifier', loupe.enabled, (e) => {
        loupe.enabled = !loupe.enabled;
        setPref('loupe', loupe.enabled);
        const b = e.currentTarget;
        b.setAttribute('aria-checked', String(loupe.enabled));
        const st = b.querySelector('.state'); st.textContent = loupe.enabled ? 'On' : 'Off'; st.classList.toggle('on', loupe.enabled);
      }, 'A zoomed view above your finger when dragging')));
    }
    body.append(el('h3', { textContent: 'Toolbar' }), segmented(
      [[true, 'Labels', 'icon and name'], [false, 'Compact', 'icons only']], pref('toolbarLabels', true),
      (v) => setLabels(v), 'Toolbar'),
      el('div', { className: 'row' }, el('button', { className: 'secondary', textContent: 'Edit toolbar', onclick: openEditToolbarSheet })));
    body.append(el('h3', { textContent: 'Data' }), segmented(
      [[0, 'No warning'], [250, '250 MB'], [500, '500 MB'], [1000, '1 GB']], pref('usageWarn', 0),
      (v) => { setPref('usageWarn', v); usageWarned = false; }, 'Warn me after'),
      el('p', { className: 'muted', textContent: 'Shows a reminder once a session uses this much, handy on cellular.' }));
    const nameField = el('input', { className: 'field', value: pref('deviceName', '') , placeholder: deviceName(), 'aria-label': 'This device\'s name', maxLength: 40 });
    body.append(el('h3', { textContent: 'This device\'s name' }), nameField,
      el('div', { className: 'row' }, el('button', { className: 'secondary', textContent: 'Save name', onclick: () => {
        setPref('deviceName', nameField.value.trim());
        stream.deviceName = nameField.value.trim() || deviceName();
        toast('Saved. The Mac shows it from your next connection.');
      } })),
      el('p', { className: 'muted', textContent: 'Shown in the Mac\'s Tether panel, its activity list and your passkeys.' }));
  });
}

// ---------- Connection and other Macs ----------
function openConnectionSheet() {
  openSheet(hello?.name || 'Connection', (body) => {
    const s = stream.stats;
    const q = quality();
    body.append(
      el('p', { className: 'stats' }, el('span', { className: 'dot', 'data-q': q, style: 'display:inline-block;margin-right:8px' }),
        q ? `${QUALITY_WORD[q]}` : QUALITY_WORD['']),
      el('p', { className: 'muted stats', textContent: stream.hasVideo
        ? `${view.videoW} × ${view.videoH}, ${s.codec}, ${s.fps} fps, ${(s.kbps / 1000).toFixed(1)} Mbps, ${Math.round(s.rtt)} ms${pref('quality', 'auto') === 'auto' ? ', Auto quality' : ''}`
        : 'Waiting for video.' }),
      el('p', { className: 'muted stats', textContent: `Data: ${formatBytes(usage().session)} this session, ${formatBytes(usage().today)} today on this device.` }),
      el('div', { className: 'row' }, el('button', { className: 'secondary', textContent: 'Reconnect', onclick: () => { stream.reconnect(); closeSheet(); } })));
    body.append(el('div', { className: 'menu' },
      toggleRow('eye', 'View only', viewOnly, () => { setViewOnly(!viewOnly); closeSheet(); }, 'Watch without controlling'),
      ...(viewOnly ? [] : [toggleRow('eye-slash', 'Curtain', curtainOn, () => { setCurtain(!curtainOn); closeSheet(); },
        'Blacks out the Mac\'s own screen')])));
    const macs = el('div', { className: 'list' }, el('p', { className: 'muted', textContent: 'Looking for your other Macs.' }));
    body.append(el('h3', { textContent: 'Your Macs' }), macs);
    loadMacs(macs);
  });
}

// Your Macs: this one, other Macs running Tether (with a picture), and ones that are offline.
async function loadMacs(container, cards = false) {
  let peers = [];
  try { peers = (await (await fetch('peers')).json()).peers || []; } catch { /* offline */ }
  const probe = async (p) => {
    if (p.self) return { ...p, state: 'online' };
    if (p.online === false) return { ...p, state: 'offline' };
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 3000);
    try {
      const r = await fetch(`${p.url}/healthz`, { mode: 'cors', signal: ctl.signal, credentials: 'omit' });
      const h = await r.json();
      return { ...p, state: h.ok ? (h.paused ? 'paused' : 'online') : 'quiet', label: h.name };
    } catch { return { ...p, state: 'quiet' }; } finally { clearTimeout(t); }
  };
  const all = await Promise.all(peers.map(probe));
  container.replaceChildren();
  if (!cards) {
    const up = all.filter((p) => p.state === 'online');
    if (up.length <= 1) {
      container.append(el('div', { className: 'empty' }, icon('desktop'),
        el('span', { textContent: 'Only this Mac has Tether. Set it up on another Mac and it shows up here.' })));
    }
    if (all.length > 1) container.append(el('button', { className: 'secondary', textContent: 'Show your Macs', onclick: openMacsSheet }));
    return;
  }
  const STATUS = { online: 'Online', paused: 'Paused', quiet: 'Not answering', offline: 'Offline' };
  const order = { online: 0, paused: 1, quiet: 2, offline: 3 };
  all.sort((a, b) => (b.self - a.self) || (order[a.state] - order[b.state]));
  for (const p of all) {
    const seen = p.state === 'offline' && p.lastSeen ? `Offline since ${new Date(p.lastSeen).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' })}` : STATUS[p.state];
    const pic = el('div', { className: 'mac-pic' });
    if (p.state === 'online' || p.state === 'paused') {
      const img = el('img', { alt: '', src: `${p.self ? '' : p.url + '/'}thumbnail?w=480`, loading: 'lazy' });
      img.addEventListener('error', () => pic.replaceChildren(icon(p.self ? 'desktop' : 'lock-simple')));
      pic.append(img);
    } else {
      pic.append(icon('moon'));
    }
    const card = el('button', { className: `mac-card ${p.state}`, disabled: p.state === 'offline' }, pic,
      el('span', { className: 'mac-meta' }, el('strong', { textContent: p.label || p.name }),
        el('small', {}, el('span', { className: 'dot', 'data-q': p.state === 'online' ? 'good' : p.state === 'offline' ? '' : 'fair' }), ` ${p.self ? 'This one' : seen}`)));
    if (!p.self && p.state !== 'offline') card.addEventListener('click', () => { location.href = `${p.url}/`; });
    else if (p.self) card.addEventListener('click', () => closeSheet());
    container.append(card);
  }
  if (all.length <= 1) container.append(el('p', { className: 'muted', textContent: 'Set up Tether on your other Macs and they show up here.' }));
}

// ---------- Compose (autocorrect, predictive text, dictation) ----------
function openComposeSheet() {
  openSheet('Compose', (body) => {
    const area = el('textarea', { id: 'compose-area', placeholder: 'Type or dictate here, then send it to the Mac', 'aria-label': 'Text to type on the Mac' });
    area.setAttribute('autocorrect', 'on');
    area.setAttribute('autocapitalize', 'sentences');
    area.spellcheck = true;
    const send = (enter) => {
      if (area.value) kb.text(area.value);
      if (enter) kb.tap('Enter');
      area.value = '';
      area.focus();
    };
    body.append(area, el('div', { className: 'row' },
      el('button', { className: 'secondary', textContent: 'Type it', onclick: () => send(false) }),
      el('button', { className: 'primary', textContent: 'Type and Return', onclick: () => send(true) })),
      el('p', { className: 'muted', textContent: 'Uses your device\'s keyboard: autocorrect, predictions and the microphone key for dictation.' }));
    setTimeout(() => area.focus(), 50);
  });
}

// ---------- Files (browse and download, upload) ----------
const ROOTS = [['downloads', 'Downloads'], ['desktop', 'Desktop'], ['documents', 'Documents']];
let uploadTarget = { root: 'downloads', path: '', label: 'Downloads' };
const fmtSize = (n) => (n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(0)} KB` : n < 1073741824 ? `${(n / 1048576).toFixed(1)} MB` : `${(n / 1073741824).toFixed(2)} GB`);

function openFilesSheet(root, path) {
  openSheet('Files', (body) => {
    body.append(
      el('div', { className: 'tabs', role: 'tablist' }, ...ROOTS.map(([id, label]) => {
        const b = el('button', { className: 'choice', role: 'tab', textContent: label, onclick: () => openFilesSheet(id, '') });
        b.setAttribute('aria-selected', String(id === root));
        b.setAttribute('aria-checked', String(id === root));
        return b;
      })),
      el('div', { className: 'row' }, el('button', { className: 'primary', onclick: () => {
        uploadTarget = { root, path, label: path ? path.split('/').pop() : ROOTS.find(([id]) => id === root)[1] };
        $('#file-input').click();
      } }, `Upload here (${path ? path.split('/').pop() : ROOTS.find(([id]) => id === root)[1]})`)));
    const parts = path ? path.split('/') : [];
    const crumbs = el('nav', { className: 'crumbs', 'aria-label': 'Folder' },
      el('button', { className: 'link', textContent: ROOTS.find(([id]) => id === root)[1], onclick: () => openFilesSheet(root, '') }));
    parts.forEach((p, i) => crumbs.append('/', el('button', { className: 'link', textContent: p, onclick: () => openFilesSheet(root, parts.slice(0, i + 1).join('/')) })));
    const list = el('div', { className: 'list' }, el('p', { className: 'muted', textContent: 'Loading.' }));
    body.append(el('h3', { textContent: 'On the Mac' }), crumbs, list);
    fetch(`files?root=${root}&path=${encodeURIComponent(path)}`).then((r) => r.json()).then((data) => {
      list.replaceChildren();
      if (data.error) { list.append(el('div', { className: 'empty' }, icon('warning-circle'), el('span', { textContent: data.error }))); return; }
      if (!data.items.length) { list.append(el('div', { className: 'empty' }, icon('folder-simple'), el('span', { textContent: 'This folder is empty.' }))); return; }
      for (const it of data.items.slice(0, 300)) {
        const sub = path ? `${path}/${it.name}` : it.name;
        const meta = it.dir ? 'Folder' : `${fmtSize(it.size)}, ${new Date(it.mtime * 1000).toLocaleDateString()}`;
        const row = el('button', { className: 'choice file-row' },
          icon(it.dir ? 'folder-simple' : 'file'), el('span', { className: 'name', textContent: it.name }), el('span', { className: 'meta', textContent: meta }));
        row.addEventListener('click', () => {
          if (it.dir) { openFilesSheet(root, sub); return; }
          const a = el('a', { href: `download?root=${root}&path=${encodeURIComponent(sub)}`, download: it.name });
          document.body.append(a); a.click(); a.remove();
          toast(`Downloading ${it.name}`);
        });
        list.append(row);
      }
    }).catch(() => list.replaceChildren(el('div', { className: 'empty' }, icon('warning-circle'), el('span', { textContent: 'Couldn\'t load the folder.' }))));
  });
}

// ---------- Toast ----------
let toastTimer;
function toast(text, action = null, ms = 2500) {
  const t = $('#toast');
  t.replaceChildren(el('span', { className: 'text', textContent: text }));
  if (action) t.append(el('button', { textContent: action.label, onclick: () => { action.run(); t.hidden = true; } }));
  t.hidden = false;
  clearTimeout(toastTimer);
  if (ms) toastTimer = setTimeout(() => { t.hidden = true; }, ms);
  return t;
}

// ---------- File upload ----------
// Dropped files go to Downloads; "Upload here" sends them to the folder being browsed.
function uploadFiles(files, target = { root: 'downloads', path: '', label: 'Downloads' }) {
  for (const file of files) {
    const xhr = new XMLHttpRequest();
    const bar = el('progress', { max: 1, value: 0 });
    const t = toast(`Sending ${file.name} to ${target.label}`, null, 0);
    t.append(bar);
    xhr.upload.onprogress = (e) => { if (e.lengthComputable) bar.value = e.loaded / e.total; };
    xhr.onload = () => {
      if (xhr.status === 200) {
        const saved = JSON.parse(xhr.responseText).saved;
        toast(`Saved to ${target.label}: ${saved}`, null, 4000);
      } else {
        let msg = `Upload failed (${xhr.status})`;
        try { msg = JSON.parse(xhr.responseText).error || msg; } catch { /* not JSON */ }
        toast(msg, null, 6000);
      }
    };
    xhr.onerror = () => toast('Upload failed. The connection dropped.', null, 5000);
    xhr.open('POST', `upload?name=${encodeURIComponent(file.name)}&root=${target.root}&path=${encodeURIComponent(target.path)}`);
    xhr.send(file);
  }
}
$('#file-input').addEventListener('change', (e) => { uploadFiles(e.target.files, uploadTarget); e.target.value = ''; });

let dragDepth = 0;
addEventListener('dragenter', (e) => { if (e.dataTransfer?.types.includes('Files')) { dragDepth++; $('#drop-hint').hidden = false; e.preventDefault(); } });
addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; $('#drop-hint').hidden = true; } });
addEventListener('dragover', (e) => e.preventDefault());
addEventListener('drop', (e) => {
  e.preventDefault();
  dragDepth = 0;
  $('#drop-hint').hidden = true;
  if (e.dataTransfer?.files.length) uploadFiles(e.dataTransfer.files);
});

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
