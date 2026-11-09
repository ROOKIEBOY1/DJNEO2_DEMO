const { test } = require('node:test');
const assert = require('node:assert/strict');
const { selectedSubjectOverlay } = require('../entry/src/main/ets/core/domain/SubjectObservation.ets');

test('preview hides scan candidates and exposes only the confirmed selected tracking box', () => {
  const a = { id: 7, left: 0.1, top: 0.2, width: 0.2, height: 0.5 };
  const b = { ...a, id: 9, left: 0.6 };
  const scan = { candidates: [a, b], overlay: [a, b], tracking: false };
  assert.deepEqual(selectedSubjectOverlay(scan, 7), []);
  assert.equal(scan.candidates.length, 2); // Both candidates remain available to the VLM.
  const track = { ...scan, tracking: true, overlay: [a], selectedIdCandidate: 7 };
  assert.deepEqual(selectedSubjectOverlay(track, undefined), []);
  assert.deepEqual(selectedSubjectOverlay(track, 7), [a]);
  assert.deepEqual(selectedSubjectOverlay(track, 9), []); // Do not show A while switching to B.
  assert.deepEqual(selectedSubjectOverlay({ ...track, overlay: [b], selectedIdCandidate: 9 }, 9), [b]);
  assert.deepEqual(selectedSubjectOverlay({ ...track, tracking: false }, 7), []);
  assert.deepEqual(selectedSubjectOverlay(undefined, 7), []);
});
