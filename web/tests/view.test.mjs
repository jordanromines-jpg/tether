// Pointer placement: a finger at a spot maps to the Mac position the overlay is then drawn at.
import { test } from 'node:test';
import assert from 'node:assert/strict';

globalThis.addEventListener ??= () => {};
globalThis.visualViewport ??= undefined;
const { View } = await import('../js/view.js');

function makeView(vw, vh, videoW, videoH, top = 0) {
  const canvas = { style: {}, width: 0, height: 0 };
  const viewport = { clientWidth: vw, clientHeight: vh, getBoundingClientRect: () => ({ left: 0, top, width: vw, height: vh }) };
  const v = new View(canvas, viewport);
  v.setVideoSize(videoW, videoH);
  return v;
}

const SIZES = {
  'iPhone portrait': [390, 844], 'iPhone landscape': [844, 390],
  'iPad portrait': [820, 1180], 'iPad landscape': [1180, 820],
};
const POINTS = [[0, 0], [0.5, 0.5], [1, 1], [0.25, 0.75], [0.9, 0.1]];

for (const [name, [w, h]] of Object.entries(SIZES)) {
  test(`${name}: finger → Mac → overlay lands where the finger was`, () => {
    const v = makeView(w, h, 3840, 2160);
    for (const [nx, ny] of POINTS) {
      const c = v.toClient(nx, ny);
      const back = v.toNormalized(c.x, c.y);
      assert.ok(Math.abs(back.x - nx) < 1e-9 && Math.abs(back.y - ny) < 1e-9, `${nx},${ny}`);
    }
    // The stream is letterboxed and centred: the Mac's corners sit on the video's corners.
    const tl = v.toClient(0, 0), br = v.toClient(1, 1);
    assert.ok(Math.abs((br.x - tl.x) / (br.y - tl.y) - 16 / 9) < 1e-6, 'aspect kept');
    assert.ok(Math.abs(tl.x - (w - (br.x - tl.x)) / 2) < 0.5 && Math.abs(tl.y - (h - (br.y - tl.y)) / 2) < 0.5, 'centred');
  });

  test(`${name}: still exact when zoomed in and panned`, () => {
    const v = makeView(w, h, 3840, 2160);
    v.zoomAt(3, w * 0.3, h * 0.6);
    v.panBy(-40, 25);
    for (const [fx, fy] of [[w * 0.5, h * 0.5], [w * 0.1, h * 0.9], [w - 1, 1]]) {
      const n = v.toNormalized(fx, fy);
      if (n.x <= 0 || n.x >= 1 || n.y <= 0 || n.y >= 1) continue;   // outside the picture is clamped
      const c = v.toClient(n.x, n.y);
      assert.ok(Math.abs(c.x - fx) < 1e-6 && Math.abs(c.y - fy) < 1e-6, `${fx},${fy}`);
    }
  });
}

test('a viewport that starts lower on the page (e.g. under a browser bar) is accounted for', () => {
  const v = makeView(390, 800, 3840, 2160, 44);
  const n = v.toNormalized(195, 44 + 400);
  assert.ok(Math.abs(n.x - 0.5) < 1e-9 && Math.abs(n.y - 0.5) < 1e-9);
});

test('rotating re-fits the picture even when the resize event came too early (iOS)', () => {
  const observers = [];
  globalThis.ResizeObserver = class { constructor(cb) { this.cb = cb; observers.push(this); } observe() {} };
  try {
    const canvas = { style: {}, width: 0, height: 0 };
    const viewport = { clientWidth: 390, clientHeight: 844, getBoundingClientRect: () => ({ left: 0, top: 0, width: viewport.clientWidth, height: viewport.clientHeight }) };
    const v = new View(canvas, viewport);
    v.setVideoSize(5120, 2880);
    // Rotated: the width is new, but the height the 'resize' event saw was still the portrait one.
    viewport.clientWidth = 844; viewport.clientHeight = 750;
    v.layout(true);
    // Then layout settles to the real landscape height, which only the observer reports.
    viewport.clientHeight = 390;
    observers.at(-1).cb();
    assert.ok(v.displayedHeight <= 390 + 0.5, `picture fits the height (${v.displayedHeight})`);
    assert.ok(v.ty >= 0 && v.ty + v.displayedHeight <= 390 + 0.5, `and isn't pushed down (ty ${v.ty})`);
    const mid = v.toNormalized(v.toClient(0.5, 0.5).x, v.toClient(0.5, 0.5).y);
    assert.ok(Math.abs(mid.x - 0.5) < 1e-6 && Math.abs(mid.y - 0.5) < 1e-6, 'taps still land where drawn');
  } finally { delete globalThis.ResizeObserver; }
});
