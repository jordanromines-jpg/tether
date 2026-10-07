import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatBytes, addToDay, crossedLimit, localDay } from '../js/usage.js';

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
