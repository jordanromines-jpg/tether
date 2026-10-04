// The few animations Tether uses (see docs/DESIGN.md → Motion). Anime.js is loaded in the
// background after start-up; until it's ready, and whenever the person prefers reduced motion,
// changes are simply instant. Nothing ever waits on an animation.
const reduce = matchMedia('(prefers-reduced-motion: reduce)');
let lib = null;
let loading = null;

export function preloadMotion() {
  loading ??= import('../vendor/anime.esm.min.js').then((m) => { lib = m; }).catch(() => {});
  return loading;
}

const ready = () => (reduce.matches ? null : lib);

// Spring an element from an offset back to where CSS puts it (used after the toolbar snaps to a dock).
export function settleFrom(el, dx, dy) {
  const a = ready();
  el.style.transform = '';
  if (!a || (Math.abs(dx) < 1 && Math.abs(dy) < 1)) return;
  a.animate(el, {
    x: [dx, 0], y: [dy, 0],
    ease: a.spring({ bounce: 0.18, duration: 380 }),
    onComplete: () => { el.style.transform = ''; },
  });
}

// Sheet enter: a short rise and fade. From the bottom edge on phones.
export function sheetIn(scrim, card, fromBottom) {
  const a = ready();
  if (!a) return;
  a.animate(scrim, { opacity: [0, 1], duration: 160, ease: 'outQuad' });
  a.animate(card, {
    y: [fromBottom ? 48 : 16, 0], opacity: [0, 1],
    ease: a.spring({ bounce: 0, duration: 260 }),
    onComplete: () => { card.style.transform = ''; card.style.opacity = ''; },
  });
}

// Sheet exit: faster than the enter. Resolves when it's safe to hide.
export function sheetOut(scrim, card, fromBottom) {
  const a = ready();
  if (!a) return Promise.resolve();
  return new Promise((resolve) => {
    a.animate(scrim, { opacity: 0, duration: 160, ease: 'outQuad' });
    a.animate(card, {
      y: fromBottom ? '+=56' : 8, opacity: 0, duration: 160, ease: 'outQuad',
      onComplete: () => { card.style.transform = ''; card.style.opacity = ''; scrim.style.opacity = ''; resolve(); },
    });
  });
}

// Cross-fade for content swaps (first-run tips).
export function fadeIn(el) {
  const a = ready();
  if (a) a.animate(el, { opacity: [0, 1], duration: 180, ease: 'outQuad' });
}
