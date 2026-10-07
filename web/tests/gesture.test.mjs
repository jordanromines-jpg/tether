import { test } from 'node:test';
import assert from 'node:assert/strict';

import { flingVelocity, momentumStep, flingDistance, inMenuBar, MIN_SPEED } from '../js/gesture.js';

test('fling speed comes from the last 100 ms only', () => {
  const samples = [{ t: 0, dx: 0, dy: 500 }, { t: 900, dx: 0, dy: 20 }, { t: 950, dx: 0, dy: 20 }, { t: 1000, dx: 0, dy: 20 }];
  const v = flingVelocity(samples, 1000);
  assert.ok(Math.abs(v.vy - 0.6) < 0.01, `vy ${v.vy}`);
  assert.equal(v.vx, 0);
  assert.deepEqual(flingVelocity([{ t: 0, dx: 0, dy: 50 }], 500), { vx: 0, vy: 0 }, 'a finger that stopped has no fling');
});

test('momentum slows down and stops', () => {
  let step = momentumStep({ vx: 0, vy: 1 }, 16);
  assert.equal(step.dy, 16);
  let frames = 0;
  while (step) { step = momentumStep(step.v, 16); frames++; }
  assert.ok(frames > 20 && frames < 200, `stops after ${frames} frames`);
  assert.equal(momentumStep({ vx: 0, vy: MIN_SPEED / 2 }, 16), null, 'too slow to keep going');
});

test('a faster fling goes further, and frame rate barely matters', () => {
  assert.ok(flingDistance({ vx: 0, vy: 2 }) > flingDistance({ vx: 0, vy: 1 }) * 1.5);
  const at60 = flingDistance({ vx: 0, vy: 1 }, 16);
  const at120 = flingDistance({ vx: 0, vy: 1 }, 8);
  assert.ok(Math.abs(at60 - at120) / at60 < 0.08, `${at60} vs ${at120}`);
});

test('the menu-bar magnifier shows near the top, only when not zoomed in', () => {
  assert.ok(inMenuBar(0.01));
  assert.ok(!inMenuBar(0.05));
  assert.ok(!inMenuBar(0.01, 2), 'zoomed in, the menu bar is already big');
  assert.ok(!inMenuBar(-0.1));
});
