const { test } = require('node:test');
const assert = require('node:assert/strict');
const { RecordingClock } = require('../entry/src/main/ets/core/domain/RecordingClock.ets');

test('recording clock stays at zero until the aircraft confirms recording', () => {
  const clock = new RecordingClock();
  assert.deepEqual(clock.snapshot(0), { label: '00:00', recording: false });
  clock.update(1000, false, 'shoot-1');
  clock.update(5000, undefined, 'shoot-1');
  assert.deepEqual(clock.snapshot(15000), { label: '00:00', recording: false });
  clock.update(16000, true, 'shoot-1');
  assert.deepEqual(clock.snapshot(17500), { label: '00:01', recording: true });
});

test('two clips in one capture accumulate recording time while excluding the inter-clip gap', () => {
  const clock = new RecordingClock();
  clock.update(1000, true, 'shoot-1');
  clock.update(4000, false, 'shoot-1');
  assert.deepEqual(clock.snapshot(6000), { label: '00:03', recording: false });
  clock.update(7000, true, 'shoot-1');
  clock.update(10500, false, 'shoot-1');
  assert.deepEqual(clock.snapshot(20000), { label: '00:06', recording: false });
});

test('unknown telemetry freezes the clock and resuming excludes the unknown interval', () => {
  const clock = new RecordingClock();
  clock.update(1000, true, 'shoot-1');
  clock.update(2500, undefined, 'shoot-1');
  assert.deepEqual(clock.snapshot(6500), { label: '00:01', recording: false });
  clock.update(7000, true, 'shoot-1');
  clock.update(8500, false, 'shoot-1');
  assert.deepEqual(clock.snapshot(9000), { label: '00:03', recording: false });
});

test('a new capture clears the previous recording duration, including while awaiting confirmation', () => {
  const clock = new RecordingClock();
  clock.update(1000, true, 'shoot-1');
  clock.update(66000, false, 'shoot-1');
  assert.equal(clock.snapshot(67000).label, '01:05');
  clock.update(68000, false, 'shoot-2');
  assert.deepEqual(clock.snapshot(70000), { label: '00:00', recording: false });
  clock.update(71000, true, 'shoot-2');
  assert.deepEqual(clock.snapshot(73000), { label: '00:02', recording: true });
});

test('repeated identical observations and snapshots never count the same duration twice', () => {
  const clock = new RecordingClock();
  clock.update(1000, true, 'shoot-1');
  clock.update(1250, true, 'shoot-1');
  assert.equal(clock.snapshot(2000).label, '00:01');
  clock.update(2500, true, 'shoot-1');
  assert.equal(clock.snapshot(3000).label, '00:02');
  assert.equal(clock.snapshot(3000).label, '00:02');
  clock.update(4000, false, 'shoot-1');
  clock.update(6000, false, 'shoot-1');
  assert.deepEqual(clock.snapshot(9000), { label: '00:03', recording: false });
});
