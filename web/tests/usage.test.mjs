import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatBytes, addToDay, crossedLimit, localDay, transferText } from '../js/usage.js';

test('bytes read the way people expect', () => {
  assert.equal(formatBytes(512_000), '512 KB');
  assert.equal(formatBytes(340_400_000), '340 MB');
  assert.equal(formatBytes(1_230_000_000), '1.2 GB');
});

test('daily total adds up within a day and restarts on a new one', () => {
  assert.deepEqual(addToDay(null, 5, '2026-10-06'), { day: '2026-10-06', bytes: 5 });
  assert.deepEqual(addToDay({ day: '2026-10-06', bytes: 5 }, 7, '2026-10-06'), { day: '2026-10-06', bytes: 12 });
  assert.deepEqual(addToDay({ day: '2026-10-05', bytes: 999 }, 7, '2026-10-06'), { day: '2026-10-06', bytes: 7 });
});

test('the warning fires once, when the limit is crossed', () => {
  assert.equal(crossedLimit(249e6, 251e6, 250), true);
  assert.equal(crossedLimit(251e6, 260e6, 250), false);
  assert.equal(crossedLimit(0, 9e9, 0), false);
});

test('local day key', () => {
  assert.equal(localDay(new Date(2026, 0, 5)), '2026-01-05');
});

test('upload speed and time left read plainly', () => {
  assert.equal(transferText(0, 100, 2000), '', 'nothing sent yet');
  assert.equal(transferText(500, 1000, 100), '', 'too early to tell');
  assert.equal(transferText(2_000_000, 26_000_000, 1000), '2.0 MB/s · about 12 s left');
  assert.equal(transferText(300_000, 600_000_000, 1000), '300 KB/s · about 34 min left');
  assert.equal(transferText(999_000, 1_000_000, 1000), '999 KB/s · almost done');
});
