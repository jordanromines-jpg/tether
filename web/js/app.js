import { Stream } from './stream.js';
import { View } from './view.js';
import { Keyboard } from './keys.js';
import { Input } from './input.js';
import { pref, setPref } from './store.js';
import { RemoteCursor } from './cursor.js';
import { AudioPlayer } from './audio.js';
import { passkeyStatus, registerPasskey, unlockWithPasskey } from './passkey.js';
import { refreshTip, hideTip } from './tooltip.js';
import { initToolbar, setDock, currentDock, foldedItems, fit } from './toolbar.js';
import { LABELS as DOCK_LABELS } from './dock.js';
import { showTips, tipsOpen, dismissTips } from './tips.js';
import { preloadMotion, sheetIn, sheetOut, settleFrom } from './motion.js';
import { idleMinutes, shouldIdlePause, shouldHiddenPause, HIDDEN_PAUSE_MS, DEFAULT_IDLE_MINUTES } from './idle.js';

const $ = (s) => document.querySelector(s);
const canvas = $('#screen');
const viewport = $('#viewport');
const isTouch = navigator.maxTouchPoints > 0;
document.body.classList.toggle('desktop', !isTouch);

const view = new View(canvas, viewport);
const stream = new Stream(canvas, view);
const kb = new Keyboard(stream);
const input = new Input({ stream, view, keyboard: kb, surface: viewport });
const cursor = new RemoteCursor(viewport, view, { touch: isTouch });
input.cursor = cursor;
const audio = new AudioPlayer(stream);
stream.onAudio = (bytes) => audio.onFrame(bytes);
input.touchMode = pref('touchMode', 'trackpad');

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
    $('#status-actions').append(el('button', { className: 'secondary', textContent: 'Try again', onclick: () => stream.reconnect() }));
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
stream.deviceName = deviceName();

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
  setTimeout(() => showTips({ touch: isTouch, closed: () => { input.enabled = !sheetOpen(); } }) && (input.enabled = false), 600);
});
stream.addEventListener('close', () => {
  stream.hasVideo = false;
  updateConnection();
  status('connecting', 'Reconnecting', `Lost the connection to ${macName()}. Trying again.`);
});
stream.addEventListener('hello', (e) => {
  hello = e.detail;
  currentDisplay = hello.display;
  document.title = `${hello.name} · Tether`;
  $('.conn-name').textContent = hello.name;
  curtainOn = !!hello.curtain;
  updateConnection();
  const missing = [];
  if (!hello.perms?.screen) missing.push('Screen Recording');
  if (!hello.perms?.input) missing.push('Accessibility');
  showMacState(hello.state);
  if (missing.length) toast(`On the Mac, allow Tether in Privacy & Security: ${missing.join(' and ')}.`, null, 9000);
});
stream.addEventListener('display', (e) => { currentDisplay = e.detail.id; });
stream.addEventListener('curtain', (e) => {
  curtainOn = !!e.detail.on;
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
stream.addEventListener('clip', (e) => {
  lastMacClip = e.detail.s;
  const preview = lastMacClip.replace(/\s+/g, ' ').slice(0, 60);
  toast(`Mac copied: "${preview}"`, { label: 'Copy', run: () => copyLocal(lastMacClip) }, 6000);
});

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
  $('[data-action="viewonly"]').hidden = !on;
  if (on && document.activeElement === sink) sink.blur();
  fit();
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
const QUALITY_WORD = { good: 'Good connection', fair: 'Slower connection', poor: 'Poor connection', '': 'Not connected' };
function updateConnection() {
  const chip = $('[data-action="macs"]');
  const q = quality();
  chip.querySelector('.dot').dataset.q = q;
  const s = stream.stats;
  chip.dataset.tip = hello?.name || 'Connection';
  chip.dataset.hint = q ? `${QUALITY_WORD[q]}: ${Math.round(s.rtt)} ms, ${s.fps} fps` : QUALITY_WORD[''];
  chip.setAttribute('aria-label', `${macName()}. ${chip.dataset.hint}`);
  refreshTip(chip);
}
setInterval(updateConnection, 2000);

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
sink.addEventListener('blur', () => setPressed('[data-action="keyboard"]', false));

// ---------- Toolbar ----------
let sticky = new Map();
const toolbar = $('#toolbar');
const pill = $('#toolbar-show');
function setToolbarHidden(h) {
  hideTip();
  toolbar.hidden = h;
  pill.hidden = !h;
  setPref('toolbarHidden', h);
  if (!h) fit();
}
initToolbar({ onFold: () => syncSticky() });
setToolbarHidden(pref('toolbarHidden', false));
pill.addEventListener('click', () => setToolbarHidden(false));

function setPressed(sel, on) {
  for (const b of document.querySelectorAll(sel)) b.setAttribute('aria-pressed', String(on));
}

function syncSticky() {
  for (const btn of document.querySelectorAll('[data-mod]')) {
    const state = sticky.get(btn.dataset.mod);
    btn.setAttribute('aria-pressed', String(!!state));
    btn.classList.toggle('locked', state === 'locked');
  }
}
kb.onStickyChange = (s) => { sticky = s; syncSticky(); };

const actions = {
  keyboard: () => {
    if (document.activeElement === sink) { sink.blur(); return; }
    sink.value = SENTINEL;
    sink.focus();
    setPressed('[data-action="keyboard"]', true);
  },
  keys: openKeysSheet,
  clipboard: openClipboardSheet,
  files: () => openFilesSheet('downloads', ''),
  compose: openComposeSheet,
  macs: openConnectionSheet,
  sound: async () => {
    const btn = $('[data-action="sound"]');
    const setIcon = (on) => btn.querySelector('use').setAttribute('href', `icons.svg#${on ? 'speaker-high' : 'speaker-slash'}`);
    if (audio.on) { audio.stop(); setPressed('[data-action="sound"]', false); setIcon(false); return; }
    try {
      await audio.start();
      setPressed('[data-action="sound"]', true);
      setIcon(true);
      toast(audio.format === 'aac' ? 'Sound on' : 'Sound on (compatibility mode)');
    } catch (err) { toast(`Couldn't start sound: ${err.message}`); }
  },
  settings: openSettingsSheet,
  fullscreen: () => (document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen?.()),
  hide: () => setToolbarHidden(true),
  more: openMoreSheet,
  viewonly: () => setViewOnly(false),
  move: openDockSheet,
  tips: () => { closeSheet(); input.enabled = false; showTips({ touch: isTouch, force: true, closed: () => { input.enabled = !sheetOpen(); } }); },
};
document.addEventListener('fullscreenchange', () => {
  $('[data-action="fullscreen"] use').setAttribute('href', `icons.svg#${document.fullscreenElement ? 'arrows-in' : 'arrows-out'}`);
});

toolbar.addEventListener('click', (e) => {
  const btn = e.target.closest('button');
  if (!btn) return;
  if (btn.dataset.mod) { kb.toggleSticky(btn.dataset.mod); return; }
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

// ---------- More menu ----------
function openMoreSheet() {
  openSheet('More', (body) => {
    const menu = el('div', { className: 'menu', role: 'menu' });
    const folded = foldedItems();
    for (const item of folded) {
      if (item.classList.contains('mods')) {
        menu.append(el('div', { className: 'mods-row', role: 'group', 'aria-label': 'Modifier keys' },
          ...[...item.querySelectorAll('[data-mod]')].map((m) => {
            const b = el('button', { className: 'choice', textContent: m.textContent, 'aria-label': m.getAttribute('aria-label'),
              onclick: () => kb.toggleSticky(m.dataset.mod) });
            b.dataset.mod = m.dataset.mod;
            b.setAttribute('aria-pressed', m.getAttribute('aria-pressed'));
            return b;
          })));
        continue;
      }
      const glyph = item.querySelector('use')?.getAttribute('href')?.split('#')[1] || 'desktop';
      const label = item.dataset.action === 'macs' ? (hello?.name || 'Connection') : item.dataset.tip;
      const extra = item.dataset.action === 'macs' ? el('small', { className: 'stats', textContent: item.dataset.hint }) : '';
      menu.append(el('button', { className: 'menu-item', role: 'menuitem', onclick: () => { closeSheetThen(actions[item.dataset.action]); } },
        icon(glyph), el('span', { textContent: label }), extra));
    }
    if (folded.length) menu.append(el('hr'));
    menu.append(
      el('button', { className: 'menu-item', role: 'menuitem', onclick: () => openDockSheet() },
        icon('arrows-out-cardinal'), el('span', { textContent: 'Move toolbar' }), el('small', { textContent: DOCK_LABELS[currentDock()] })),
      toggleRow('eye', 'View only', viewOnly, () => { setViewOnly(!viewOnly); closeSheet(); }),
      ...(viewOnly ? [] : [toggleRow('eye-slash', 'Curtain', curtainOn, () => { setCurtain(!curtainOn); closeSheet(); },
        'Blacks out the Mac\'s own screen')]),
      el('hr'),
      el('button', { className: 'menu-item', role: 'menuitem', onclick: actions.tips }, icon('lightbulb'), el('span', { textContent: 'Tips' })));
    if (hello?.links) {
      menu.append(
        el('button', { className: 'menu-item', role: 'menuitem', onclick: () => openLink('help') }, icon('question'), el('span', { textContent: 'Help and docs' })),
        el('button', { className: 'menu-item', role: 'menuitem', onclick: () => openLink('issues') }, icon('bug'), el('span', { textContent: 'Report a problem' })));
    }
    if (!folded.some((f) => f.dataset.action === 'hide')) {
      menu.append(el('button', { className: 'menu-item', role: 'menuitem', onclick: () => { closeSheetThen(actions.hide); } },
        icon('caret-down'), el('span', { textContent: 'Hide toolbar' })));
    }
    body.append(menu);
  });
  syncSticky();
}
// A menu row that switches something on or off.
function toggleRow(glyph, label, on, run, hint = '') {
  const b = el('button', { className: 'menu-item', role: 'menuitemcheckbox', onclick: run },
    icon(glyph), el('span', {}, label, hint ? el('small', { className: 'hint', textContent: hint }) : ''), el('small', { className: `state${on ? ' on' : ''}`, textContent: on ? 'On' : 'Off' }));
  b.setAttribute('aria-checked', String(on));
  return b;
}

// Run a toolbar action from the More menu: actions that open their own sheet replace this one.
function closeSheetThen(fn) {
  const opensSheet = [actions.keys, actions.clipboard, actions.files, actions.compose, actions.macs, actions.settings].includes(fn);
  if (opensSheet) { fn(); return; }
  closeSheet().then(() => fn?.());
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
    body.append(el('h3', { textContent: 'Keys' }),
      el('div', { className: 'grid' }, ...KEYS.map(([label, code]) =>
        el('button', { className: 'key-btn', textContent: label, onclick: () => kb.tap(code) }))));
    body.append(el('h3', { textContent: 'Shortcuts' }),
      el('div', { className: 'grid' }, ...SHORTCUTS.map(([label, combo]) =>
        el('button', { className: 'key-btn', textContent: label, onclick: () => { kb.combo(combo); closeSheet(); } }))));
  });
}

// ---------- Clipboard ----------
async function copyLocal(text) {
  try {
    await navigator.clipboard.writeText(text);
    toast('Copied to this device');
  } catch {
    toast('Couldn\'t copy. Open Clipboard to select it by hand.');
  }
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
      el('h3', { textContent: 'To the Mac' }),
      area,
      el('div', { className: 'row' },
        el('button', { className: 'secondary', textContent: 'Paste here', onclick: async () => {
          try { area.value = await navigator.clipboard.readText(); } catch { toast('Clipboard access was blocked. Paste into the box instead.'); }
        } }),
        el('button', { className: 'secondary', textContent: 'Send', onclick: () => { sendClip(area.value, false); closeSheet(); } }),
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
      body.append(el('h3', { textContent: 'Screen' }), el('div', { className: 'list', role: 'radiogroup', 'aria-label': 'Screen' }, ...displays.map((d) => {
        const b = el('button', { className: 'choice', role: 'radio' }, d.name, el('small', { className: 'stats', textContent: `${d.w} × ${d.h}` }));
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
      [['auto', 'Auto', 'adapts'], ['fast', 'Fast', 'cellular'], ['balanced', 'Balanced', '1080p'], ['sharp', 'Sharp', 'full res']],
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
    }
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

async function loadMacs(container) {
  let peers = [];
  try { peers = (await (await fetch('peers')).json()).peers || []; } catch { /* offline */ }
  const probe = async (p) => {
    if (p.self) return { ...p, up: true };
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 3000);
    try {
      const r = await fetch(`${p.url}/healthz`, { mode: 'cors', signal: ctl.signal, credentials: 'omit' });
      const h = await r.json();
      return { ...p, up: !!h.ok, label: h.name };
    } catch { return { ...p, up: false }; } finally { clearTimeout(t); }
  };
  const found = (await Promise.all(peers.map(probe))).filter((p) => p.up);
  container.replaceChildren();
  if (found.length <= 1) {
    container.append(el('div', { className: 'empty' }, icon('desktop'),
      el('span', { textContent: 'Only this Mac has Tether. Set it up on another Mac and it shows up here.' })));
    return;
  }
  for (const p of found) {
    const b = el('button', { className: 'choice', role: 'radio' }, p.label || p.name, el('small', { textContent: p.self ? 'This one' : new URL(p.url).host }));
    b.setAttribute('aria-checked', String(!!p.self));
    if (!p.self) b.addEventListener('click', () => { location.href = `${p.url}/`; });
    container.append(b);
  }
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
const ROOTS = [['downloads', 'Downloads'], ['desktop', 'Desktop']];
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
      el('div', { className: 'row' }, el('button', { className: 'primary', onclick: () => $('#file-input').click() },
        'Upload to the Mac\'s Downloads')));
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
function uploadFiles(files) {
  for (const file of files) {
    const xhr = new XMLHttpRequest();
    const bar = el('progress', { max: 1, value: 0 });
    const t = toast(`Sending ${file.name}`, null, 0);
    t.append(bar);
    xhr.upload.onprogress = (e) => { if (e.lengthComputable) bar.value = e.loaded / e.total; };
    xhr.onload = () => {
      if (xhr.status === 200) {
        const saved = JSON.parse(xhr.responseText).saved;
        toast(`Saved to Downloads: ${saved}`, null, 4000);
      } else {
        toast(`Upload failed (${xhr.status})`, null, 5000);
      }
    };
    xhr.onerror = () => toast('Upload failed. The connection dropped.', null, 5000);
    xhr.open('POST', `upload?name=${encodeURIComponent(file.name)}`);
    xhr.send(file);
  }
}
$('#file-input').addEventListener('change', (e) => { uploadFiles(e.target.files); e.target.value = ''; });

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
