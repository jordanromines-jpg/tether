// Every tool Tether offers, in one place: the toolbar, More and Edit toolbar all draw from this list.
// Pure data and functions (no DOM), tested by web/tests/tools.test.mjs.

export const SECTIONS = [
  ['type', 'Type'], ['control', 'Control'], ['transfer', 'Transfer'], ['view', 'View'], ['toolbar', 'Toolbar'], ['help', 'Help'],
];

// short: the label under the icon (fits 64 px at 11 px). hint: one line of what it does.
// toggle: shows On or Off. needs: only offered when the context allows it.
export const TOOLS = [
  { id: 'keyboard', label: 'Keyboard', short: 'Keyboard', icon: 'keyboard', section: 'type', toggle: true, needs: 'control',
    hint: 'Type on the Mac. ⌘ ⌥ ⌃ ⇧, Esc and the arrows sit above the on-screen keyboard.' },
  { id: 'compose', label: 'Compose', short: 'Compose', icon: 'pencil-simple-line', section: 'type', needs: 'control',
    hint: 'Write with autocorrect or dictation, then send it.' },
  { id: 'keys', label: 'Keys and shortcuts', short: 'Keys', icon: 'command', section: 'type', needs: 'control',
    hint: 'Modifier keys, Esc, arrows, function keys and Mac shortcuts.' },
  { id: 'actions', label: 'Quick actions', short: 'Actions', icon: 'lightning', section: 'control', needs: 'control',
    hint: 'Volume, media, screenshot, open a link or an app.' },
  { id: 'windows', label: 'Windows', short: 'Windows', icon: 'app-window', section: 'control',
    hint: 'Bring a window to the front, or show just that one window.' },
  { id: 'macs', label: 'Your Macs', short: 'Macs', icon: 'swap', section: 'control',
    hint: 'See your other Macs and switch to one.' },
  { id: 'capture', label: 'Capture pointer', short: 'Capture', icon: 'cursor', section: 'control', needs: 'pointerCapture',
    hint: 'Your mouse or trackpad moves the Mac\'s pointer. Esc releases it.' },
  { id: 'clipboard', label: 'Clipboard', short: 'Clipboard', icon: 'clipboard-text', section: 'transfer',
    hint: 'Copy and paste between this device and the Mac.' },
  { id: 'files', label: 'Files', short: 'Files', icon: 'folder-simple', section: 'transfer',
    hint: 'Download from the Mac, or upload to it.' },
  { id: 'sound', label: 'Sound', short: 'Sound', icon: 'speaker-slash', section: 'view', toggle: true,
    hint: 'Play the Mac\'s sound here.' },
  { id: 'settings', label: 'Display and quality', short: 'Display', icon: 'sliders-horizontal', section: 'view',
    hint: 'Screen, sharpness, touch mode, toolbar labels.' },
  { id: 'fullscreen', label: 'Full screen', short: 'Full screen', icon: 'arrows-out', section: 'view', needs: 'desktop',
    hint: 'Use the whole screen. In Chrome, ⌘W and ⌘Q then go to the Mac.' },
  { id: 'viewonly', label: 'View only', short: 'View only', icon: 'eye', section: 'view', toggle: true,
    hint: 'Watch without controlling. Your taps and typing won\'t reach the Mac.' },
  { id: 'curtain', label: 'Curtain', short: 'Curtain', icon: 'eye-slash', section: 'view', toggle: true, needs: 'control',
    hint: 'Blacks out the Mac\'s own screen while you work.' },
  { id: 'status', label: 'Connection', short: 'Mac', icon: 'desktop', section: 'view', status: true,
    hint: 'How the connection is doing, and data used.' },
  { id: 'move', label: 'Move toolbar', short: 'Move', icon: 'arrows-out-cardinal', section: 'toolbar',
    hint: 'Put the toolbar on any edge. You can also drag it by its grip.' },
  { id: 'edit', label: 'Edit toolbar', short: 'Edit', icon: 'wrench', section: 'toolbar',
    hint: 'Choose which tools are in the toolbar, and their order.' },
  { id: 'hide', label: 'Hide toolbar', short: 'Hide', icon: 'caret-down', section: 'toolbar',
    hint: 'Shrinks it to a small button.' },
  { id: 'tips', label: 'Tips', short: 'Tips', icon: 'lightbulb', section: 'help',
    hint: 'The short tour of how to use Tether.' },
  { id: 'help', label: 'Help and docs', short: 'Help', icon: 'question', section: 'help', needs: 'links',
    hint: 'Opens the guide on GitHub.' },
  { id: 'issues', label: 'Report a problem', short: 'Report', icon: 'bug', section: 'help', needs: 'links',
    hint: 'Opens a new issue on GitHub.' },
];

const BY_ID = new Map(TOOLS.map((t) => [t.id, t]));
export const tool = (id) => BY_ID.get(id);

// Phone: a short screen side under 600 px. The class doesn't change when the device rotates.
export function deviceClass({ touch, shortSide }) {
  if (!touch) return 'desktop';
  return shortSide >= 600 ? 'tablet' : 'phone';
}

// What's in the toolbar before anyone edits it. More is always added at the end.
const DEFAULTS = {
  phone: ['keyboard', 'actions', 'windows', 'clipboard'],
  tablet: ['keyboard', 'actions', 'windows', 'clipboard', 'files', 'sound', 'settings', 'status'],
  desktop: ['actions', 'windows', 'clipboard', 'files', 'sound', 'settings', 'fullscreen', 'status'],
};
export const defaultLayout = (cls) => [...(DEFAULTS[cls] || DEFAULTS.desktop)];

// Is a tool offered right now? ctx: { control, desktop, pointerCapture, links } (control is false in view only).
export function isAvailable(t, ctx) {
  if (!t) return false;
  if (t.needs === 'control') return ctx.control !== false;
  if (t.needs) return !!ctx[t.needs];
  return true;
}
export const availableTools = (ctx) => TOOLS.filter((t) => isAvailable(t, ctx));

// A saved layout, cleaned: known ids only, no repeats, More never listed (it's always last).
export function normalizeLayout(saved, cls) {
  if (!Array.isArray(saved)) return defaultLayout(cls);
  const seen = new Set();
  return saved.filter((id) => typeof id === 'string' && BY_ID.has(id) && !seen.has(id) && seen.add(id));
}

// The ids actually shown, in order: the layout minus what isn't available here and now.
export const visibleLayout = (layout, ctx) => layout.filter((id) => isAvailable(tool(id), ctx));

// When space runs out, tools fold into More from the end: pinned shortcuts first, then the layout backwards.
export const foldOrder = (layoutIds, pinIds = []) => [...pinIds].reverse().concat([...layoutIds].reverse());

// Edit toolbar helpers.
export function move(layout, id, delta) {
  const i = layout.indexOf(id);
  const j = i + delta;
  if (i < 0 || j < 0 || j >= layout.length) return layout;
  const next = [...layout];
  [next[i], next[j]] = [next[j], next[i]];
  return next;
}
export function toggle(layout, id) {
  return layout.includes(id) ? layout.filter((x) => x !== id) : [...layout, id];
}

// Tools grouped for More, in section order: [[sectionId, title, [tools…]], …].
export function sections(ctx) {
  const tools = availableTools(ctx).filter((t) => !t.status);
  return SECTIONS.map(([id, title]) => [id, title, tools.filter((t) => t.section === id)]).filter(([, , list]) => list.length);
}

// Where the key row sits: on top of the on-screen keyboard, i.e. at the bottom of the visual viewport.
export function keyRowTop({ vvHeight, vvOffsetTop, rowHeight }) {
  return Math.round(vvOffsetTop + vvHeight - rowHeight);
}
