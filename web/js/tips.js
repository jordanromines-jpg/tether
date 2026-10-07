// First-run tips: three short cards about gestures, shown once per device after the screen first
// appears; the toolbar tour (tour.js) follows. Reopen any time from More → Tips.
import { pref, setPref } from './store.js';
import { fadeIn } from './motion.js';

const TOUCH = [
  ['hand-tap', 'Tap to click', 'Slide one finger to move the pointer. Tap with two fingers to right-click. Touch and hold, then move, to drag.'],
  ['mouse-scroll', 'Scroll and zoom', 'Scroll with two fingers. Pinch to zoom in, and drag with three fingers to look around while zoomed.'],
  ['hand-swipe-left', 'Swipe between Spaces', 'Swipe left or right with three fingers to switch desktops. Swipe up for Mission Control.'],
];
const DESKTOP = [
  ['cursor-click', 'Use it like your own Mac', 'Your mouse, trackpad and keyboard control the Mac. Most shortcuts pass straight through.'],
  ['keyboard', 'Shortcuts your browser keeps', 'A few shortcuts (like ⌘W or ⌘Q) belong to your browser. Send them from Keys, or use Full screen in Chrome.'],
  ['upload-simple', 'Drop files to send them', 'Drag files onto this window to put them in the Mac\'s Downloads folder. Get files back from Files.'],
];

const root = document.getElementById('tips');
const icon = root.querySelector('.tip-icon use');
const title = document.getElementById('tip-title');
const text = document.getElementById('tip-text');
const dots = root.querySelector('.tip-dots');
const next = root.querySelector('[data-tip-action="next"]');
const skip = root.querySelector('[data-tip-action="skip"]');
let cards = TOUCH;
let index = 0;
let onClose = () => {};

function render() {
  const [glyph, t, body] = cards[index];
  icon.setAttribute('href', `icons.svg#${glyph}`);
  title.textContent = t;
  text.textContent = body;
  dots.replaceChildren(...cards.map((_, i) => Object.assign(document.createElement('span'), { className: i === index ? 'on' : '' })));
  next.textContent = index === cards.length - 1 ? 'Done' : 'Next';
  skip.hidden = index === cards.length - 1;
  fadeIn(root.querySelector('.tip-card'));
}

function close() {
  root.hidden = true;
  setPref('tipsSeen', true);
  onClose();
}

next.addEventListener('click', () => { if (index < cards.length - 1) { index++; render(); } else close(); });
skip.addEventListener('click', close);
root.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.stopPropagation(); close(); } });
for (const ev of ['pointerdown', 'touchstart']) root.addEventListener(ev, (e) => e.stopPropagation(), { passive: true });

// Shows the tips. Unless forced, only the first time on this device.
export function showTips({ touch, force = false, closed = () => {} }) {
  if (!force && pref('tipsSeen', false)) return false;
  cards = touch ? TOUCH : DESKTOP;
  index = 0;
  onClose = closed;
  root.hidden = false;
  render();
  next.focus({ preventScroll: true });
  return true;
}

export const tipsOpen = () => !root.hidden;

/** Hides the tips without marking them as seen (a status card took over); they show again next time. */
export function dismissTips() {
  if (root.hidden) return;
  root.hidden = true;
  onClose();
}
