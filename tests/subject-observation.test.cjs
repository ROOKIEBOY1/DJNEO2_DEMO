const { test } = require('node:test');
const assert = require('node:assert/strict');
const { TelemetryStore } = require('../entry/src/main/ets/core/domain/TelemetryStore.ets');
const { encodeDumlFrame } = require('../entry/src/main/ets/core/protocol/DumlCodec.ets');

const report = (id, payload, sender = 0x92) => encodeDumlFrame(sender, 2, 1, 0, 0x0a, id, payload);

// Synthetic tables exercise the captured 12-byte record structure, not a hardware candidate limit.
function detection(ids, selectedId = ids[ids.length - 1] ?? 0) {
  const payload = new Uint8Array(12 + ids.length * 12);
  payload[0] = 2;
  payload[11] = ids.length;
  const view = new DataView(payload.buffer);
  view.setUint16(6, selectedId, true);
  ids.forEach((id, index) => {
    const offset = 12 + index * 12;
    [id, 0x0102, 5000, 5000, 5000, 5000].forEach((value, field) => {
      view.setUint16(offset + field * 2, value, true);
    });
  });
  return payload;
}

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

for (const ids of [[0, 11, 255], [11, 13, 17, 23, 29]]) {
  test(`a structurally valid ${ids.length}-person table preserves every candidate and its freshness`, () => {
    const telemetry = new TelemetryStore();
    telemetry.observe(report(0xbc, detection(ids)), 100);
    const subject = telemetry.snapshot(1100).subject;
    assert.equal(subject.candidateCount, ids.length);
    assert.deepEqual(subject.candidates.map(candidate => candidate.id), ids);
    assert.equal(subject.selectedIdCandidate, ids[ids.length - 1]);
    assert.deepEqual(subject.candidates[ids.length - 1], {
      id: ids[ids.length - 1], left: 0.25, top: 0.25, width: 0.5, height: 0.5
    });
    assert.equal(subject.detectionAt, 100);
    assert.equal(telemetry.snapshot(99).subject.candidateCount, undefined);
    assert.equal(telemetry.snapshot(1101).subject.candidateCount, undefined);
    assert.equal(telemetry.snapshot(1101).subject.selectedIdCandidate, undefined);
  });
}

test('the largest complete detection table fitting one DUML frame is accepted without truncation', () => {
  const telemetry = new TelemetryStore();
  const ids = Array.from({ length: 83 }, (_, index) => index);
  const raw = report(0xbc, detection(ids));
  assert.equal(raw.length, 1021);
  telemetry.observe(raw, 100);
  const subject = telemetry.snapshot(100).subject;
  assert.equal(subject.candidateCount, 83);
  assert.equal(subject.candidates[0].id, 0);
  assert.equal(subject.candidates[82].id, 82);
  assert.equal(subject.selectedIdCandidate, 82);
  assert.throws(() => report(0xbc, detection(Array.from({ length: 84 }, (_, index) => index))), /DUML length/);
});

test('malformed detection headers and count lengths clear the previous complete report', () => {
  const valid = detection([11, 13, 17]);
  const wrongVersion = valid.slice();
  wrongVersion[0] = 1;
  const smallerCount = valid.slice();
  smallerCount[11] = 2;
  const largerCount = valid.slice();
  largerCount[11] = 4;
  const oversizedCount = valid.slice();
  oversizedCount[11] = 255;
  const zeroCountWithRecords = valid.slice();
  zeroCountWithRecords[11] = 0;
  const trailingByte = new Uint8Array(valid.length + 1);
  trailingByte.set(valid);
  const malformed = [valid.slice(0, 11), wrongVersion, smallerCount, largerCount,
    oversizedCount, zeroCountWithRecords, valid.slice(0, -1), trailingByte];
  for (const payload of malformed) {
    const telemetry = new TelemetryStore();
    telemetry.observe(report(0xbc, detection([11, 13])), 100);
    assert.equal(telemetry.snapshot(100).subject.candidateCount, 2);
    telemetry.observe(report(0xbc, payload), 200);
    const subject = telemetry.snapshot(200).subject;
    assert.equal(subject.candidateCount, undefined);
    assert.equal(subject.detectionAt, undefined);
    assert.equal(subject.selectedIdCandidate, undefined);
    assert.deepEqual(subject.candidates, []);
    assert.deepEqual(subject.overlay, []);
  }
});

test('an invalid coordinate in any record rejects the whole multi-person report', () => {
  for (const record of [0, 4]) {
    for (const [field, value] of [[4, 10001], [6, 10001], [8, 0], [8, 10001], [10, 0], [10, 10001]]) {
      const telemetry = new TelemetryStore();
      telemetry.observe(report(0xbc, detection([11, 13])), 100);
      assert.equal(telemetry.snapshot(100).subject.candidateCount, 2);
      const payload = detection([11, 13, 17, 23, 29]);
      new DataView(payload.buffer).setUint16(12 + record * 12 + field, value, true);
      telemetry.observe(report(0xbc, payload), 200);
      const subject = telemetry.snapshot(200).subject;
      assert.equal(subject.candidateCount, undefined, `record ${record}, field ${field}, value ${value}`);
      assert.equal(subject.selectedIdCandidate, undefined);
      assert.deepEqual(subject.candidates, []);
      assert.deepEqual(subject.overlay, []);
    }
  }
});

test('an unsupported candidate ID in the first or later record clears the whole report', () => {
  for (const record of [0, 4]) {
    for (const id of [256, 65535]) {
      const telemetry = new TelemetryStore();
      telemetry.observe(report(0xbc, detection([11, 13, 17, 23, 29])), 100);
      assert.equal(telemetry.snapshot(100).subject.candidateCount, 5);
      const payload = detection([11, 13, 17, 23, 29], 13);
      new DataView(payload.buffer).setUint16(12 + record * 12, id, true);
      telemetry.observe(report(0xbc, payload), 200);
      const subject = telemetry.snapshot(200).subject;
      assert.equal(subject.candidateCount, undefined, `record ${record}, id ${id}`);
      assert.equal(subject.detectionAt, undefined);
      assert.equal(subject.selectedIdCandidate, undefined);
      assert.deepEqual(subject.candidates, []);
      assert.deepEqual(subject.overlay, []);
    }
  }
});

test('duplicate IDs in a three- or five-person table reject every candidate', () => {
  for (const ids of [[11, 11, 17], [11, 13, 17, 23, 11]]) {
    const telemetry = new TelemetryStore();
    telemetry.observe(report(0xbc, detection([11, 13, 17, 23, 29])), 100);
    assert.equal(telemetry.snapshot(100).subject.candidateCount, 5);
    telemetry.observe(report(0xbc, detection(ids)), 200);
    const subject = telemetry.snapshot(200).subject;
    assert.equal(subject.candidateCount, undefined);
    assert.equal(subject.detectionAt, undefined);
    assert.equal(subject.selectedIdCandidate, undefined);
    assert.deepEqual(subject.candidates, []);
    assert.deepEqual(subject.overlay, []);
  }
});

test('the header selected-ID sentinel does not invalidate supported unique candidate IDs', () => {
  const telemetry = new TelemetryStore();
  telemetry.observe(report(0xbc, detection([0, 11, 255], 65535)), 100);
  const subject = telemetry.snapshot(100).subject;
  assert.equal(subject.candidateCount, 3);
  assert.deepEqual(subject.candidates.map(candidate => candidate.id), [0, 11, 255]);
  assert.equal(subject.selectedIdCandidate, 65535);
});
