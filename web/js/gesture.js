// Touch gesture maths that doesn't need a screen. Tested by web/tests/gesture.test.mjs.

// Momentum after a two-finger scroll: like a Mac trackpad, the content keeps going and slows down.
export const FRICTION = 0.95;          // speed kept per 16 ms frame
export const MIN_SPEED = 0.05;         // px per ms; slower than this, momentum stops
export const SAMPLE_MS = 100;          // the fling speed is measured over the last 100 ms

/** Speed of a fling, in px per ms, from recent scroll samples [{ t, dx, dy }] (oldest first). */
export function flingVelocity(samples, now) {
  const recent = samples.filter((s) => now - s.t <= SAMPLE_MS);
  if (recent.length < 2) return { vx: 0, vy: 0 };
  const span = Math.max(16, now - recent[0].t);
  const sum = recent.reduce((a, s) => ({ dx: a.dx + s.dx, dy: a.dy + s.dy }), { dx: 0, dy: 0 });
  return { vx: sum.dx / span, vy: sum.dy / span };
}

/** One momentum step of dtMs: how far to scroll now, and the speed left afterwards (null: stop). */
export function momentumStep({ vx, vy }, dtMs) {
  if (Math.hypot(vx, vy) < MIN_SPEED) return null;
  const keep = FRICTION ** (dtMs / 16);
  return { dx: vx * dtMs, dy: vy * dtMs, v: { vx: vx * keep, vy: vy * keep } };
}

/** Total distance a fling travels before it stops (for tests and tuning). */
export function flingDistance(v, dtMs = 16) {
  let total = 0;
  let step = momentumStep(v, dtMs);
  for (let i = 0; step && i < 2000; i++) {
    total += Math.hypot(step.dx, step.dy);
    step = momentumStep(step.v, dtMs);
  }
  return total;
}

// The menu-bar magnifier: shown while the pointer is near the top of the Mac's screen.
export const MENU_BAR_BAND = 0.025;    // top 2.5% of the screen (the menu bar on most displays)
export const inMenuBar = (ny, zoom = 1) => ny >= 0 && ny <= MENU_BAR_BAND && zoom <= 1.05;
