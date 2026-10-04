import { Stream } from './stream.js';
import { View } from './view.js';
import { Keyboard } from './keys.js';
import { Input } from './input.js';
import { pref, setPref } from './store.js';
import { RemoteCursor } from './cursor.js';
import { AudioPlayer } from './audio.js';
import { passkeyStatus, registerPasskey, unlockWithPasskey } from './passkey.js';

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

// ---------- Status overlay ----------
function status(text, detail = '', isError = false) {
  $('#status').hidden = false;
  $('#status').classList.toggle('error', isError);
  $('#status-text').textContent = text;
  $('#status-detail').textContent = detail;
}
const hideStatus = () => { $('#status').hidden = true; };

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

// ---------- Passkey lock ----------
let pausePoll;
async function passkeyGate() {
  const st = await passkeyStatus();
  if (st.ok) return true;
  stream.paused = true;
  if (st.paused) {
    // Remote access paused from the Mac's menu bar: wait quietly, reconnect when resumed.
    status('Paused on the Mac', st.msg || 'Resume it from the Tether menu-bar icon.', false);
    $('#status').classList.add('locked');
    clearTimeout(pausePoll);
    pausePoll = setTimeout(async () => {
      if (await passkeyGate()) { $('#status').classList.remove('locked'); stream.paused = false; stream.reconnect(); }
    }, 5000);
    return false;
  }
  const card = $('#status .status-card');
  const showLock = (msg, detail, buttonLabel, action) => {
    status(msg, detail, false);
    $('#status').classList.add('locked');
    card.querySelector('.lock-btn')?.remove();
    if (buttonLabel) {
      const b = el('button', { className: 'primary lock-btn', textContent: buttonLabel, onclick: async () => {
        b.disabled = true;
        try {
          await action();
          $('#status').classList.remove('locked');
          b.remove();
          stream.paused = false;
          stream.reconnect();
        } catch (err) {
          b.disabled = false;
          $('#status-detail').textContent = err.name === 'NotAllowedError' ? 'Cancelled — tap to try again.' : err.message;
        }
      } });
      card.append(b);
    }
  };
  if (st.enrolled) {
    showLock('Locked', 'Unlock with Face ID or Touch ID to see your Mac.', 'Unlock', unlockWithPasskey);
  } else if (st.enrolling) {
    showLock('Set up a passkey', 'This Mac requires Face ID / Touch ID. Create a passkey for this device.', 'Create passkey', () => registerPasskey(stream.deviceName));
  } else {
    showLock('Passkey required', 'On the Mac, open the Tether menu and choose “Add a passkey from a device…”, then reload this page.', 'Reload', async () => location.reload());
  }
  return false;
}
stream.beforeReconnect = passkeyGate;

const unsupported = Stream.support();
if (unsupported) {
  status('Can’t start here', unsupported, true);
} else if (await passkeyGate()) {
  stream.connect();
}

stream.addEventListener('connecting', () => { if (!stream.hasVideo) status('Connecting to your Mac…'); });
stream.addEventListener('open', () => status('Starting screen…'));
stream.addEventListener('firstframe', hideStatus);
stream.addEventListener('close', () => {
  stream.hasVideo = false;
  status('Reconnecting…', 'Check that the Mac is awake and on your tailnet.');
});
stream.addEventListener('hello', (e) => {
  hello = e.detail;
  currentDisplay = hello.display;
  document.title = `${hello.name} — Tether`;
  const missing = [];
  if (!hello.perms?.screen) missing.push('Screen Recording');
  if (!hello.perms?.input) missing.push('Accessibility');
  showMacState(hello.state);
  if (missing.length) toast(`On the Mac, allow Tether in Privacy & Security → ${missing.join(' and ')}.`, null, 9000);
});
stream.addEventListener('display', (e) => { currentDisplay = e.detail.id; });
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
  else status('Can’t show the screen', e.detail.msg, true);
});
stream.addEventListener('clip', (e) => {
  lastMacClip = e.detail.s;
  const preview = lastMacClip.replace(/\s+/g, ' ').slice(0, 60);
  toast(`Mac copied: “${preview}”`, { label: 'Copy', run: () => copyLocal(lastMacClip) }, 6000);
});

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    if (!stream.connected) stream.reconnect(); else stream.requestKeyframe();
  } else {
    kb.releaseAll();
  }
});
addEventListener('blur', () => kb.releaseAll());

// ---------- Mac state banner (asleep / locked) ----------
function showMacState(state) {
  const banner = $('#banner');
  if (!state || (!state.asleep && !state.locked)) { banner.hidden = true; return; }
  const text = state.asleep
    ? 'Your Mac’s display is asleep.'
    : 'Your Mac is locked. Tap ⌨︎, type your password, then press Return.';
  banner.replaceChildren(el('span', { className: 'text', textContent: text }));
  if (state.asleep) banner.append(el('button', { textContent: 'Wake', onclick: () => stream.send({ t: 'wake' }) }));
  banner.hidden = false;
}

// ---------- Hardware keyboard ----------
const sink = $('#kbd-sink');
const sheetOpen = () => !$('#sheet').hidden;

document.addEventListener('keydown', (e) => {
  if (sheetOpen()) return;
  const fromSink = e.target === sink;
  // Printable chars typed into the soft-keyboard sink go through the text path,
  // which handles iOS keyboards (shift state, autocomplete) correctly.
  if (fromSink && e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) return;
  if (kb.handleKeyDown(e)) e.preventDefault();
}, true);
document.addEventListener('keyup', (e) => {
  if (sheetOpen()) return;
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
const toolbar = $('#toolbar');
function setToolbarHidden(h) {
  toolbar.hidden = h;
  $('#toolbar-show').hidden = !h;
  setPref('toolbarHidden', h);
}
setToolbarHidden(pref('toolbarHidden', false));
$('#toolbar-show').addEventListener('click', () => setToolbarHidden(false));

function setPressed(sel, on) {
  const el = document.querySelector(sel);
  if (el) el.setAttribute('aria-pressed', String(on));
}

kb.onStickyChange = (sticky) => {
  for (const btn of toolbar.querySelectorAll('[data-mod]')) {
    const state = sticky.get(btn.dataset.mod);
    btn.setAttribute('aria-pressed', String(!!state));
    btn.classList.toggle('locked', state === 'locked');
  }
};

toolbar.addEventListener('click', (e) => {
  const btn = e.target.closest('button');
  if (!btn) return;
  if (btn.dataset.mod) { kb.toggleSticky(btn.dataset.mod); return; }
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
    sound: async () => {
      if (audio.on) { audio.stop(); setPressed('[data-action="sound"]', false); return; }
      try {
        await audio.start();
        setPressed('[data-action="sound"]', true);
        toast(audio.format === 'aac' ? 'Sound on' : 'Sound on (compatibility mode)');
      } catch (err) { toast(`Couldn’t start sound: ${err.message}`); }
    },
    settings: openSettingsSheet,
    fullscreen: () => document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen?.(),
    hide: () => setToolbarHidden(true),
  };
  actions[btn.dataset.action]?.();
});
// Keep toolbar taps from reaching the remote screen.
for (const ev of ['pointerdown', 'touchstart']) toolbar.addEventListener(ev, (e) => e.stopPropagation(), { passive: true });

// ---------- Sheets ----------
function openSheet(title, build) {
  $('#sheet-title').textContent = title;
  const body = $('#sheet-body');
  body.replaceChildren();
  build(body);
  $('#sheet').hidden = false;
  input.enabled = false;
}
function closeSheet() {
  $('#sheet').hidden = true;
  input.enabled = true;
  canvas.focus({ preventScroll: true });
}
$('#sheet').addEventListener('click', (e) => {
  if (e.target.id === 'sheet' || e.target.closest('[data-close]')) closeSheet();
});
addEventListener('keydown', (e) => { if (e.key === 'Escape' && sheetOpen()) { e.stopPropagation(); closeSheet(); } }, true);

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
  openSheet('Keys', (body) => {
    body.append(el('h3', { textContent: 'Keys' }),
      el('div', { className: 'grid' }, ...KEYS.map(([label, code]) =>
        el('button', { className: 'key-btn', textContent: label, onclick: () => kb.tap(code) }))));
    body.append(el('h3', { textContent: 'Shortcuts' }),
      el('div', { className: 'grid' }, ...SHORTCUTS.map(([label, combo]) =>
        el('button', { className: 'key-btn', textContent: label, onclick: () => { kb.combo(combo); closeSheet(); } }))));
  });
}

async function copyLocal(text) {
  try {
    await navigator.clipboard.writeText(text);
    toast('Copied to this device');
  } catch {
    toast('Couldn’t copy — open Clipboard to select it manually');
  }
}

function sendClip(text, paste) {
  if (!text) return;
  stream.send({ t: 'setclip', s: text });
  if (paste) setTimeout(() => kb.combo(['MetaLeft', 'KeyV']), 150);
  toast(paste ? 'Pasted on the Mac' : 'Sent to the Mac’s clipboard');
}

function openClipboardSheet() {
  openSheet('Clipboard', (body) => {
    const area = el('textarea', { placeholder: 'Type or paste text to send to the Mac…' });
    body.append(
      el('h3', { textContent: 'From the Mac' }),
      lastMacClip
        ? el('div', {}, el('textarea', { readOnly: true, value: lastMacClip }),
            el('div', { className: 'row' }, el('button', { className: 'primary', textContent: 'Copy to this device', onclick: () => copyLocal(lastMacClip) })))
        : el('p', { className: 'muted', textContent: 'Copy something on the Mac and it shows up here.' }),
      el('h3', { textContent: 'To the Mac' }),
      area,
      el('div', { className: 'row' },
        el('button', { className: 'choice', textContent: 'Paste from this device', onclick: async () => {
          try { area.value = await navigator.clipboard.readText(); } catch { toast('Clipboard access was blocked — paste into the box instead'); }
        } }),
        el('button', { className: 'choice', textContent: 'Send', onclick: () => { sendClip(area.value, false); closeSheet(); } }),
        el('button', { className: 'primary', textContent: 'Send & paste', onclick: () => { sendClip(area.value, true); closeSheet(); } })),
    );
  });
}

function segmented(options, current, onPick) {
  const wrap = el('div', { className: 'segmented', role: 'radiogroup' });
  for (const [value, label, hint] of options) {
    const b = el('button', { className: 'choice', role: 'radio' }, label, hint ? el('small', { textContent: hint }) : '');
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

function openSettingsSheet() {
  openSheet('Display & quality', (body) => {
    const displays = hello?.displays ?? [];
    if (displays.length > 1) {
      body.append(el('h3', { textContent: 'Display' }), el('div', { className: 'list' }, ...displays.map((d) => {
        const b = el('button', { className: 'choice', role: 'radio' }, d.name, el('small', { textContent: `${d.w} × ${d.h}` }));
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
        [['off', 'Off', 'Mac’s own size'], ['mirror', 'Fit screen', 'reshape desktop'], ['extend', 'Extra display', 'blank space']],
        fitMode,
        (m) => { fitMode = m; sendFit(m); }),
        el('p', { className: 'muted', textContent: '“Fit screen” resizes the Mac’s desktop to this device’s shape while you’re connected; it switches back when you disconnect. Uses an undocumented macOS feature.' }));
    }
    body.append(el('h3', { textContent: 'Quality' }), segmented(
      [['auto', 'Auto', 'adapts'], ['fast', 'Fast', 'cellular'], ['balanced', 'Balanced', '1080p'], ['sharp', 'Sharp', 'full res']],
      pref('quality', 'auto'),
      (q) => { setPref('quality', q); stream.send({ t: 'quality', preset: q }); }));
    if (isTouch) {
      body.append(el('h3', { textContent: 'Touch' }), segmented(
        [['trackpad', 'Trackpad', 'drag to move'], ['direct', 'Direct', 'tap where you point']],
        input.touchMode,
        (m) => { input.touchMode = m; setPref('touchMode', m); }));
      body.append(el('p', { className: 'muted', textContent:
        'Tap to click · two-finger tap to right-click · touch and hold to drag · two fingers to scroll · pinch to zoom · three fingers to pan.' }));
    }
    const macs = el('div', { className: 'list' }, el('p', { className: 'muted', textContent: 'Looking for your other Macs…' }));
    body.append(el('h3', { textContent: 'Your Macs' }), macs);
    loadMacs(macs);
    const s = stream.stats;
    body.append(el('h3', { textContent: 'Connection' }),
      el('p', { className: 'muted', textContent:
        `${view.videoW} × ${view.videoH} · ${s.codec} · ${s.fps} fps · ${(s.kbps / 1000).toFixed(1)} Mbps · ${Math.round(s.rtt)} ms` +
        (pref('quality', 'auto') === 'auto' ? ' · Auto' : '') }),
      el('div', { className: 'row' }, el('button', { className: 'choice', textContent: 'Reconnect', onclick: () => { stream.reconnect(); closeSheet(); } })));
  });
}

// ---------- Other Macs running Tether ----------
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
    container.append(el('p', { className: 'muted', textContent: 'Only this Mac has Tether. Set it up on another Mac and it appears here.' }));
    return;
  }
  for (const p of found) {
    const b = el('button', { className: 'choice', role: 'radio' }, p.label || p.name, el('small', { textContent: p.self ? 'this one' : new URL(p.url).host }));
    b.setAttribute('aria-checked', String(!!p.self));
    if (!p.self) b.addEventListener('click', () => { location.href = `${p.url}/`; });
    container.append(b);
  }
}

// ---------- Compose (autocorrect, predictive text, dictation) ----------
function openComposeSheet() {
  openSheet('Compose', (body) => {
    const area = el('textarea', { id: 'compose-area', placeholder: 'Type or dictate here, then send it to the Mac…' });
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
      el('button', { className: 'choice', textContent: 'Type it', onclick: () => send(false) }),
      el('button', { className: 'primary', textContent: 'Type + Return', onclick: () => send(true) })),
      el('p', { className: 'muted', textContent: 'Uses your device’s keyboard features — autocorrect, predictions and the microphone key for dictation.' }));
    setTimeout(() => area.focus(), 50);
  });
}

// ---------- Files (browse & download, upload) ----------
const ROOTS = [['downloads', 'Downloads'], ['desktop', 'Desktop']];
const fmtSize = (n) => n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(0)} KB` : n < 1073741824 ? `${(n / 1048576).toFixed(1)} MB` : `${(n / 1073741824).toFixed(2)} GB`;

async function openFilesSheet(root, path) {
  openSheet('Files', (body) => {
    body.append(
      el('div', { className: 'tabs', role: 'tablist' }, ...ROOTS.map(([id, label]) => {
        const b = el('button', { className: 'choice', role: 'tab', textContent: label, onclick: () => openFilesSheet(id, '') });
        b.setAttribute('aria-checked', String(id === root));
        return b;
      })),
      el('div', { className: 'row' }, el('button', { className: 'primary', textContent: 'Upload to the Mac’s Downloads…',
        onclick: () => $('#file-input').click() })));
    const parts = path ? path.split('/') : [];
    const crumbs = el('p', { className: 'crumbs' }, el('button', { textContent: ROOTS.find(([id]) => id === root)[1], onclick: () => openFilesSheet(root, '') }));
    parts.forEach((p, i) => crumbs.append(' / ', el('button', { textContent: p, onclick: () => openFilesSheet(root, parts.slice(0, i + 1).join('/')) })));
    const list = el('div', { className: 'list' }, el('p', { className: 'muted', textContent: 'Loading…' }));
    body.append(el('h3', { textContent: 'On the Mac' }), crumbs, list);
    fetch(`files?root=${root}&path=${encodeURIComponent(path)}`).then((r) => r.json()).then((data) => {
      list.replaceChildren();
      if (data.error) { list.append(el('p', { className: 'muted', textContent: data.error })); return; }
      if (!data.items.length) { list.append(el('p', { className: 'muted', textContent: 'Empty folder.' })); return; }
      for (const it of data.items.slice(0, 300)) {
        const sub = path ? `${path}/${it.name}` : it.name;
        const meta = it.dir ? 'folder' : `${fmtSize(it.size)} · ${new Date(it.mtime * 1000).toLocaleDateString()}`;
        const row = el('button', { className: 'choice file-row' },
          el('span', { textContent: it.dir ? '📁' : '📄' }), el('span', { className: 'name', textContent: it.name }), el('span', { className: 'meta', textContent: meta }));
        row.addEventListener('click', () => {
          if (it.dir) { openFilesSheet(root, sub); return; }
          const a = el('a', { href: `download?root=${root}&path=${encodeURIComponent(sub)}`, download: it.name });
          document.body.append(a); a.click(); a.remove();
          toast(`Downloading ${it.name}…`);
        });
        list.append(row);
      }
    }).catch(() => list.replaceChildren(el('p', { className: 'muted', textContent: 'Couldn’t load the folder.' })));
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
    const t = toast(`Sending ${file.name}…`, null, 0);
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
    xhr.onerror = () => toast('Upload failed — connection lost', null, 5000);
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
