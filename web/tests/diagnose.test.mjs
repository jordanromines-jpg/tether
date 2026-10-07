import { test } from 'node:test';
import assert from 'node:assert/strict';

import { healthKind, diagnose, seenText, pollDelay } from '../js/diagnose.js';

test('health: what each kind of answer means', () => {
  assert.equal(healthKind({ threw: true }), 'unreachable');
  assert.equal(healthKind({ status: 502, json: null }), 'notRunning', 'Tailscale reached the Mac, Tether did not answer');
  assert.equal(healthKind({ status: 200, json: { error: 'html' } }), 'notRunning');
  assert.equal(healthKind({ status: 200, json: { ok: true, paused: true } }), 'paused');
  assert.equal(healthKind({ status: 200, json: { ok: true, perms: { screen: true, input: false } } }), 'permissions');
  assert.equal(healthKind({ status: 200, json: { ok: true, perms: { screen: true, input: true } } }), 'ok');
});

const now = new Date('2026-10-07T20:30:00');

test('reasons: each failure gets its own plain explanation', () => {
  const r = (args) => diagnose({ mac: 'Studio', device: 'iPhone', now, ...args }).reason;
  assert.equal(r({ online: false, health: 'unreachable' }).title, 'This iPhone is offline', 'device names keep their own capitals');
  const offline = r({ online: true, health: 'unreachable', peer: { by: 'MacBook Pro', online: false, lastSeen: '2026-10-07T18:55:00' } });
  assert.equal(offline.kind, 'macOffline');
  assert.match(offline.detail, /last saw it at .*55/);
  assert.match(offline.detail, /says MacBook Pro/);
  assert.equal(r({ online: true, health: 'unreachable' }).kind, 'unreachable', 'no other Mac to ask');
  assert.equal(r({ online: true, health: 'notRunning' }).title, "Studio is on, but Tether isn't running");
  assert.equal(r({ online: true, health: 'paused' }).kind, 'paused');
  assert.equal(r({ online: true, health: 'permissions' }).kind, 'permissions');
  assert.equal(diagnose({ online: true, health: 'notRunning', now }).reason.title, "Your Mac is on, but Tether isn't running", 'an unknown name still reads as a sentence');
});

test('checklist: everything before the first failure passes, with a fix for what fails', () => {
  const { checks } = diagnose({ online: true, health: 'notRunning', mac: 'Studio', device: 'iPhone', now });
  assert.deepEqual(checks.map((c) => c.ok), [true, true, false, false, false]);
  assert.deepEqual(checks.map((c) => c.state), ['ok', 'ok', 'fail', 'unknown', 'unknown'], 'only the first failure is a failure');
  assert.match(checks[2].fix, /Open Tether on Studio/);
  const all = diagnose({ online: true, health: 'ok', mac: 'Studio', now }).checks;
  assert.ok(all.every((c) => c.ok));
  for (const c of all) assert.ok(!c.fix.includes('—') && !c.label.includes('—'), 'no em dashes');
});

test('last seen reads naturally', () => {
  assert.match(seenText('2026-10-07T18:55:00', now), /^\d{1,2}:55/);
  assert.match(seenText('2026-10-05T09:00:00', now), /^[A-Z][a-z]{2} /, 'this week: weekday');
  assert.equal(seenText('nonsense', now), '');
});

test('polling backs off from 2 s to 10 s', () => {
  assert.deepEqual([0, 1, 2, 3, 4, 9].map(pollDelay), [2000, 4000, 6000, 8000, 10000, 10000]);
});
