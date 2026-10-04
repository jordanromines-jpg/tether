// node --test web/tests/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { nearestDock, foldOrder, normalizeDock, isVertical, DOCKS } from '../js/dock.js';

test('drops snap to the nearest dock on a phone in portrait', () => {
  const [w, h] = [390, 844];
  assert.equal(nearestDock(195, 830, w, h), 'bottom-center');
  assert.equal(nearestDock(10, 830, w, h), 'bottom-left');
  assert.equal(nearestDock(380, 20, w, h), 'top-right');
  assert.equal(nearestDock(195, 10, w, h), 'top-center');
  assert.equal(nearestDock(5, 420, w, h), 'left');
  assert.equal(nearestDock(385, 400, w, h), 'right');
});

test('drops snap the same way on a wide desktop window', () => {
  const [w, h] = [1600, 900];
  assert.equal(nearestDock(800, 880, w, h), 'bottom-center');
  assert.equal(nearestDock(20, 450, w, h), 'left');
  assert.equal(nearestDock(1590, 10, w, h), 'top-right');
});

test('drops outside the viewport are clamped', () => {
  assert.equal(nearestDock(-50, 2000, 400, 800), 'bottom-left');
  assert.equal(nearestDock(9999, -9999, 400, 800), 'top-right');
});

test('unknown docks fall back to bottom centre; sides are vertical', () => {
  assert.equal(normalizeDock('middle'), 'bottom-center');
  assert.equal(normalizeDock('left'), 'left');
  assert.ok(isVertical('left') && isVertical('right'));
  assert.ok(!DOCKS.filter((d) => d !== 'left' && d !== 'right').some(isVertical));
});

test('fold order: highest priority number first, priority 0 never folds', () => {
  const item = (id, prio) => ({ id, dataset: { prio: String(prio) } });
  const items = [item('grip', 0), item('keyboard', 1), item('mods', 2), item('files', 6), item('hide', 11), item('more', 0)];
  assert.deepEqual(foldOrder(items).map((i) => i.id), ['hide', 'files', 'mods', 'keyboard']);
});
