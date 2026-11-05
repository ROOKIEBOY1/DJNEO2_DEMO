const { test } = require('node:test');
const assert = require('node:assert/strict');
const { closestFrameSubjects, canApplyVlmSelection, markVlmCandidates } = require('../entry/src/main/ets/core/media/VlmFrame.ets');

test('frame pairing chooses the closest candidate report and rejects stale reports', () => {
  const before = { detectionAt: 850, candidates: [{ id: 4 }] };
  const after = { detectionAt: 1030, candidates: [{ id: 7 }] };
  assert.equal(closestFrameSubjects(1000, before, after), after);
  assert.equal(closestFrameSubjects(880, before, after), before);
  assert.equal(closestFrameSubjects(1231, before, after), undefined);
  assert.equal(closestFrameSubjects(1000, undefined, { candidates: [] }), undefined);
});

test('candidate marks stay inside the pixel buffer and keep the image dimensions', () => {
  const pixels = new Uint8Array(64 * 36 * 4).fill(80);
  markVlmCandidates(pixels.buffer, 64, 36, [{ id: 29, left: 0.5, top: 0.75, width: 0.5, height: 0.25 }]);
  const border = (27 * 64 + 32) * 4;
  assert.deepEqual([...pixels.slice(border, border + 4)], [0, 255, 100, 255]);
  assert.equal(pixels.length, 64 * 36 * 4);
  assert.deepEqual([...pixels.slice(0, 4)], [80, 80, 80, 80]);
  assert.throws(() => markVlmCandidates(new ArrayBuffer(4), 64, 36, []), /尺寸无效/);
});

test('a VLM response must match the original session, flight cycle and candidate', () => {
  const frame = { sessionId: 12, capturedAtMs: 1000, candidates: [{ id: 7 }] };
  assert.equal(canApplyVlmSelection(frame, 7, 12, 3, 3, 2000), true);
  assert.equal(canApplyVlmSelection(frame, 8, 12, 3, 3, 2000), false);
  assert.equal(canApplyVlmSelection(frame, 7, 13, 3, 3, 2000), false);
  assert.equal(canApplyVlmSelection(frame, 7, 12, 3, 4, 2000), false);
  assert.equal(canApplyVlmSelection(frame, 7, 12, 3, 3, 22000), false);
});
