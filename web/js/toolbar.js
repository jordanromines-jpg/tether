// The toolbar's position (docks), dragging, and folding buttons into More when space runs out.
import { DOCKS, normalizeDock, nearestDock, isVertical, foldOrder } from './dock.js';
import { pref, setPref } from './store.js';
import { settleFrom } from './motion.js';
import { hideTip } from './tooltip.js';

const toolbar = document.getElementById('toolbar');
const pill = document.getElementById('toolbar-show');
const DRAG_START = 6;

export function currentDock() { return toolbar.dataset.dock; }

export function setDock(dock, { animateFrom } = {}) {
  dock = normalizeDock(dock);
  for (const el of [toolbar, pill]) el.dataset.dock = dock;
  document.body.dataset.dock = dock;
  setPref('dock', dock);
  fit();
  if (animateFrom) {
    for (const el of [toolbar, pill]) {
      if (el.hidden) continue;
      const r = el.getBoundingClientRect();
      settleFrom(el, animateFrom.x - (r.left + r.width / 2), animateFrom.y - (r.top + r.height / 2));
    }
  }
}

// ---------- Folding (priority+) ----------
const foldables = () => [...toolbar.querySelectorAll('[data-prio]')]
  .filter((el) => Number(el.dataset.prio) > 0 && !(el.classList.contains('desktop-only') && !document.body.classList.contains('desktop')));
let onFoldChange = () => {};

export function fit() {
  if (toolbar.hidden) return;
  const vertical = isVertical(toolbar.dataset.dock);
  const items = foldables();
  const groups = [...toolbar.querySelectorAll('.group')];
  for (const el of [...items, ...groups]) el.classList.remove('folded');
  const cs = getComputedStyle(document.documentElement);
  const inset = (v) => parseFloat(cs.getPropertyValue(v)) || 0;
  const edge = 12;
  const available = vertical
    ? innerHeight - 2 * edge - inset('--safe-t') - inset('--safe-b')
    : innerWidth - 2 * edge - inset('--safe-l') - inset('--safe-r');
  const length = () => (vertical ? toolbar.offsetHeight : toolbar.offsetWidth);
  const hiddenOnThisDevice = (c) => c.classList.contains('desktop-only') && !document.body.classList.contains('desktop');
  // Fold the highest priority numbers first, measuring the real toolbar after each step
  // (folding a whole group also removes its separator, which an estimate would miss).
  for (const el of foldOrder(items)) {
    if (length() <= available) break;
    el.classList.add('folded');
    for (const g of groups) g.classList.toggle('folded', [...g.children].every((c) => c.classList.contains('folded') || hiddenOnThisDevice(c)));
  }
  onFoldChange();
}

// Buttons currently folded into More, in toolbar order.
export function foldedItems() {
  return foldables().filter((el) => el.classList.contains('folded'));
}

// ---------- Dragging ----------
// Drag starts from the grip (or anywhere on the collapsed pill). A press without movement is a
// normal click; after a real drag the click is swallowed and the bar springs into the nearest dock.
function draggable(el, handle) {
  let drag = null;
  const move = (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    const dx = e.clientX - drag.x;
    const dy = e.clientY - drag.y;
    if (!drag.moving) {
      if (Math.hypot(dx, dy) < DRAG_START) return;
      drag.moving = true;
      el.classList.add('dragging');
      hideTip();
    }
    el.style.transform = `translate(${dx}px, ${dy}px)`;
  };
  const end = (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    const moved = drag.moving;
    drag = null;
    removeEventListener('pointermove', move);
    removeEventListener('pointerup', end);
    removeEventListener('pointercancel', end);
    el.classList.remove('dragging');
    if (!moved) return;
    const r = el.getBoundingClientRect();
    const center = { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    el.style.transform = '';
    setDock(nearestDock(e.clientX, e.clientY, innerWidth, innerHeight), { animateFrom: center });
    const swallow = (c) => { c.stopImmediatePropagation(); c.preventDefault(); };
    handle.addEventListener('click', swallow, { capture: true, once: true });
    setTimeout(() => handle.removeEventListener('click', swallow, { capture: true }), 300);
  };
  // Move and release are tracked on the window, so a fast drag that leaves the handle still lands.
  handle.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    drag = { id: e.pointerId, x: e.clientX, y: e.clientY, moving: false };
    try { handle.setPointerCapture(e.pointerId); } catch { /* not all synthetic pointers can be captured */ }
    addEventListener('pointermove', move);
    addEventListener('pointerup', end);
    addEventListener('pointercancel', end);
  });
}

export function initToolbar({ onFold }) {
  onFoldChange = onFold;
  draggable(toolbar, toolbar.querySelector('.grip'));
  draggable(pill, pill);
  setDock(pref('dock', undefined));
  let raf = 0;
  addEventListener('resize', () => { cancelAnimationFrame(raf); raf = requestAnimationFrame(fit); });
}

export { DOCKS };
