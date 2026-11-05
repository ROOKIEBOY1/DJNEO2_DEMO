const { test } = require('node:test');
const assert = require('node:assert/strict');
const { TelemetryStore } = require('../entry/src/main/ets/core/domain/TelemetryStore.ets');
const { encodeDumlFrame } = require('../entry/src/main/ets/core/protocol/DumlCodec.ets');

const report = (id, payload, sender = 0x92) => encodeDumlFrame(sender, 2, 1, 0, 0x0a, id, payload);

test('validated detection supplies clipped boxes and expires separately from a zero result', () => {
  const telemetry = new TelemetryStore();
  const payload = new Uint8Array(24);
  payload[0] = 2;
  payload[11] = 1;
  const view = new DataView(payload.buffer);
  [17, 0, 0, 5000, 4000, 2000].forEach((value, index) => view.setUint16(12 + index * 2, value, true));
  telemetry.observe(report(0xbc, payload), 100);
  const subject = telemetry.snapshot(1100).subject;
  assert.equal(subject.candidateCount, 1);
  assert.equal(subject.overlay[0].id, 17);
  assert.equal(subject.overlay[0].left, 0);
  assert.equal(subject.overlay[0].width, 0.2);
  assert.equal(telemetry.snapshot(1101).subject.candidateCount, undefined);
  telemetry.observe(report(0xbc, Uint8Array.of(2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), 1200);
  assert.equal(telemetry.snapshot(1200).subject.candidateCount, 0);
});

test('newer zero detection suppresses a tracking box and session cleanup clears reports', () => {
  const telemetry = new TelemetryStore();
  const payload = new Uint8Array(20);
  payload.set([1, 17, 0]);
  const view = new DataView(payload.buffer);
  [0.5, 0.5, 0.25, 0.25].forEach((value, index) => view.setFloat32(3 + index * 4, value, true));
  telemetry.observe(report(0x95, payload, 1), 100);
  assert.deepEqual(telemetry.snapshot(100).subject.overlay, []);
  telemetry.observe(report(0x95, payload), 100);
  assert.equal(telemetry.snapshot(101).subject.tracking, true);
  telemetry.observe(report(0xbc, Uint8Array.of(2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), 200);
  assert.deepEqual(telemetry.snapshot(200).subject.overlay, []);
  telemetry.clearSubject();
  assert.equal(telemetry.snapshot(201).subject.candidateCount, undefined);
});
