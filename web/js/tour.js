// First-run tour: rings one real toolbar button at a time and says what it's for. Runs after the
// gesture tips, once per device; More → Tips shows it again. Steps whose button isn't in the bar
// (removed in Edit toolbar, or folded away on a small screen) are skipped.
import { pref, setPref } from './store.js';
import { fadeIn } from './motion.js';

const STEPS = [
  ['keyboard', 'Keyboard', 'Type on the Mac. ⌘ ⌥ ⌃ ⇧, Esc, Tab and the arrows sit right above the on-screen keyboard.'],
  ['actions', 'Actions', 'Volume, media, a screenshot of the Mac, and opening a link or an app.'],
  ['windows', 'Windows', 'Bring any window to the front, or show just that one window, sized for this screen.'],
  ['more', 'More', 'Every tool lives here, even the ones not in the toolbar. Edit toolbar picks what\'s in it.'],
  ['move', 'Move it', 'Drag this grip to put the toolbar on any edge of the screen.'],
];

const root = document.getElementById('tour');
const ring = root.querySelector('.tour-ring');
const cardEl = root.querySelector('.tour-card');
const title = document.getElementById('tour-title');
const text = document.getElementById('tour-text');
const count = root.querySelector('.tour-count');
const next = root.querySelector('[data-tour-action="next"]');
const skip = root.querySelector('[data-tour-action="skip"]');
let steps = [];
let index = 0;
let onDone = () => {};

const target = (id) => {
  const b = document.querySelector(`#toolbar [data-action="${id}"]`);
  return b && b.offsetParent && !b.classList.contains('folded') ? b : null;
};

function place() {
  const b = target(steps[index][0]);
  if (!b) return;
  const r = b.getBoundingClientRect();
  const pad = 4;
  Object.assign(ring.style, { left: `${r.left - pad}px`, top: `${r.top - pad}px`, width: `${r.width + 2 * pad}px`, height: `${r.height + 2 * pad}px` });
  const c = cardEl.getBoundingClientRect();
  const dock = document.getElementById('toolbar').dataset.dock || '';
  const gap = 16;
  let x = r.left + r.width / 2 - c.width / 2;
  let y = r.top - gap - c.height;
  if (dock.startsWith('top')) y = r.bottom + gap;
  if (dock === 'left') { x = r.right + gap; y = r.top + r.height / 2 - c.height / 2; }
  if (dock === 'right') { x = r.left - gap - c.width; y = r.top + r.height / 2 - c.height / 2; }
  x = Math.max(12, Math.min(innerWidth - c.width - 12, x));
  y = Math.max(12, Math.min(innerHeight - c.height - 12, y));
  cardEl.style.transform = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
}

function render() {
  const [, t, body] = steps[index];
  title.textContent = t;
  text.textContent = body;
  count.textContent = `${index + 1} of ${steps.length}`;
  next.textContent = index === steps.length - 1 ? 'Done' : 'Next';
  skip.hidden = index === steps.length - 1;
  place();
  fadeIn(cardEl);
}

function close() {
  root.hidden = true;
  setPref('tourSeen', true);
  removeEventListener('resize', place);
  onDone();
}

next.addEventListener('click', () => { if (index < steps.length - 1) { index++; render(); } else close(); });
skip.addEventListener('click', close);
root.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.stopPropagation(); close(); } });
// Taps on the dimmed screen stay here, never reaching the Mac.
for (const ev of ['pointerdown', 'touchstart']) root.addEventListener(ev, (e) => e.stopPropagation(), { passive: true });

/** Starts the tour if it hasn't run on this device (or when forced). Returns false if nothing to show. */
export function startTour({ force = false, done = () => {} } = {}) {
  if (!force && pref('tourSeen', false)) return false;
  steps = STEPS.filter(([id]) => target(id));
  if (!steps.length) return false;
  index = 0;
  onDone = done;
  root.hidden = false;
  addEventListener('resize', place);
  render();
  next.focus({ preventScroll: true });
  return true;
}

export const tourOpen = () => !root.hidden;
