// Tooltips for any element with data-tip (title) and optional data-hint (one line of how-to).
// Mouse: hover for 300ms, then neighbours show instantly. Touch: touch and hold for 450ms; letting
// go afterwards does not press the button. Keyboard: shown while the control has visible focus.
const HOVER_DELAY = 300;
const HOLD_DELAY = 450;
const WARM_MS = 400;

const tip = document.getElementById('tooltip');
const [titleEl, hintEl] = [tip.querySelector('strong'), tip.querySelector('span')];
let current = null;
let timer = 0;
let lastHidden = 0;
let hold = null;
let swallowClick = false;

function place(target) {
  const r = target.getBoundingClientRect();
  const t = tip.getBoundingClientRect();
  const dock = target.closest('#toolbar, #toolbar-show')?.dataset.dock || '';
  const gap = 10;
  let x;
  let y;
  if (dock === 'left') { x = r.right + gap; y = r.top + r.height / 2 - t.height / 2; }
  else if (dock === 'right') { x = r.left - gap - t.width; y = r.top + r.height / 2 - t.height / 2; }
  else if (dock.startsWith('top')) { x = r.left + r.width / 2 - t.width / 2; y = r.bottom + gap; }
  else { x = r.left + r.width / 2 - t.width / 2; y = r.top - gap - t.height; }
  x = Math.max(8, Math.min(innerWidth - t.width - 8, x));
  y = Math.max(8, Math.min(innerHeight - t.height - 8, y));
  tip.style.transform = `translate(${Math.round(x)}px, ${Math.round(y)}px)`;
}

export function showTip(target) {
  clearTimeout(timer);
  current = target;
  titleEl.textContent = target.dataset.tip;
  hintEl.textContent = target.dataset.hint || '';
  tip.hidden = false;
  place(target);
  requestAnimationFrame(() => tip.classList.add('show'));
}

export function hideTip() {
  clearTimeout(timer);
  if (!current) return;
  current = null;
  lastHidden = performance.now();
  tip.classList.remove('show');
  tip.hidden = true;
}

// Keep the text fresh if a tooltip for this element is open (e.g. live connection stats).
export function refreshTip(target) {
  if (current === target) { hintEl.textContent = target.dataset.hint || ''; place(target); }
}

const tipTarget = (e) => e.target.closest?.('[data-tip]');

document.addEventListener('pointerover', (e) => {
  if (e.pointerType !== 'mouse') return;
  const t = tipTarget(e);
  if (!t || t === current) return;
  clearTimeout(timer);
  const warm = current || performance.now() - lastHidden < WARM_MS;
  if (warm) showTip(t); else timer = setTimeout(() => showTip(t), HOVER_DELAY);
}, true);
document.addEventListener('pointerout', (e) => {
  if (e.pointerType !== 'mouse') return;
  const t = tipTarget(e);
  if (t && !t.contains(e.relatedTarget)) hideTip();
}, true);

// Capture phase: the toolbar stops pointerdown from bubbling so taps never reach the remote screen.
document.addEventListener('pointerdown', (e) => {
  const t = tipTarget(e);
  if (e.pointerType === 'mouse') { hideTip(); return; }
  if (!t) { hideTip(); return; }
  hold = { t, x: e.clientX, y: e.clientY, shown: false };
  timer = setTimeout(() => { if (hold) { hold.shown = true; showTip(t); } }, HOLD_DELAY);
}, true);
document.addEventListener('pointermove', (e) => {
  if (hold && !hold.shown && Math.hypot(e.clientX - hold.x, e.clientY - hold.y) > 10) { clearTimeout(timer); hold = null; }
}, true);
for (const type of ['pointerup', 'pointercancel']) {
  document.addEventListener(type, () => {
    if (!hold) return;
    clearTimeout(timer);
    if (hold.shown) {
      // Some browsers send no click after a long press, so only guard the next few hundred ms.
      swallowClick = true;
      setTimeout(() => { swallowClick = false; }, 400);
      setTimeout(hideTip, 900);
    }
    hold = null;
  }, true);
}
document.addEventListener('click', (e) => {
  if (!swallowClick) return;
  swallowClick = false;
  e.preventDefault();
  e.stopImmediatePropagation();
}, true);

document.addEventListener('focusin', (e) => {
  const t = tipTarget(e);
  if (t && t.matches(':focus-visible')) showTip(t);
});
document.addEventListener('focusout', hideTip);
addEventListener('resize', hideTip);
addEventListener('scroll', hideTip, true);
