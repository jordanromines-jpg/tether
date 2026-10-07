// node --test web/tests/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { nearestDock, normalizeDock, isVertical, DOCKS } from '../js/dock.js';

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
