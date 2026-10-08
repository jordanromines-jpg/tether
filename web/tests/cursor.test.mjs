// The drawn pointer (trackpad mode) must end up where the Mac's pointer really is.
import { test } from 'node:test';
import assert from 'node:assert/strict';

globalThis.document ??= { createElement: () => ({ style: {}, hidden: true }) };
const { RemoteCursor, PREDICT_MS } = await import('../js/cursor.js');
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

function makeCursor() {
  const view = { videoW: 1000, displayedWidth: 400, displayedHeight: 250, toClient: (x, y) => ({ x: x * 400, y: y * 250 }) };
  const c = new RemoteCursor({ append() {}, style: {} }, view, { touch: true });
  c.setShape({ png: '', w: 16, h: 24, hx: 1, hy: 1, nw: 0.01, nh: 0.02 });
  return c;
}

test('a guess that drifted is corrected once the finger pauses', async () => {
  const c = makeCursor();
  c.setRemote(0.5, 0.5);
  c.predictDelta(0.1, 0);                 // the phone guesses 0.6
  c.setRemote(0.57, 0.5);                 // the Mac really went to 0.57, then reports nothing more
  assert.equal(c.pos.x, 0.6, 'while moving, the guess is drawn (no lag)');
  await wait(PREDICT_MS + 60);
  assert.equal(c.pos.x, 0.57, 'after the pause, the real position is drawn');
});

test('the correction waits while the finger keeps moving', async () => {
  const c = makeCursor();
  c.setRemote(0.2, 0.2);
  c.predictDelta(0.05, 0);
  c.setRemote(0.24, 0.2);
  await wait(PREDICT_MS / 2);
  c.predictDelta(0.05, 0);                 // still moving
  await wait(PREDICT_MS / 2 + 10);
  assert.ok(Math.abs(c.pos.x - 0.3) < 1e-9, `still the guess mid-move (${c.pos.x})`);
  c.setRemote(0.28, 0.2);
  await wait(PREDICT_MS + 60);
  assert.equal(c.pos.x, 0.28);
});

test('with no guess in play, the Mac position shows at once', () => {
  const c = makeCursor();
  c.setRemote(0.1, 0.9);
  assert.deepEqual(c.pos, { x: 0.1, y: 0.9 });
});
