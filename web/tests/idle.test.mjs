import { test } from 'node:test';
import assert from 'node:assert/strict';
import { idleMinutes, shouldIdlePause, shouldHiddenPause, DEFAULT_IDLE_MINUTES } from '../js/idle.js';

const MIN = 60_000;

test('idle limit: URL override wins, then the saved choice, then the default', () => {
  assert.equal(idleMinutes('?idle=0.25', 15), 0.25);
  assert.equal(idleMinutes('', 30), 30);
  assert.equal(idleMinutes('', undefined), DEFAULT_IDLE_MINUTES);
  assert.equal(idleMinutes('?idle=0', 15), 0);
  assert.equal(idleMinutes('?idle=banana', 5), DEFAULT_IDLE_MINUTES);
  assert.equal(idleMinutes('?idle=-3', 5), DEFAULT_IDLE_MINUTES);
});

test('pauses after the idle limit with no interaction', () => {
  assert.equal(shouldIdlePause({ now: 15 * MIN, lastActive: 0, minutes: 15 }), true);
  assert.equal(shouldIdlePause({ now: 15 * MIN - 1, lastActive: 0, minutes: 15 }), false);
});

test('never pauses for idle when set to Never, while sound plays, in view only, or when hidden', () => {
  const base = { now: 60 * MIN, lastActive: 0, minutes: 5 };
  assert.equal(shouldIdlePause({ ...base, minutes: 0 }), false);
  assert.equal(shouldIdlePause({ ...base, audioOn: true }), false);
  assert.equal(shouldIdlePause({ ...base, viewOnly: true }), false);
  assert.equal(shouldIdlePause({ ...base, visible: false }), false);
});

test('background pause after a minute hidden, unless sound is playing', () => {
  assert.equal(shouldHiddenPause({ now: 60_000, hiddenSince: 0 }), true);
  assert.equal(shouldHiddenPause({ now: 59_999, hiddenSince: 0 }), false);
  assert.equal(shouldHiddenPause({ now: 120_000, hiddenSince: 0, audioOn: true }), false);
  assert.equal(shouldHiddenPause({ now: 120_000, hiddenSince: null }), false);
});
