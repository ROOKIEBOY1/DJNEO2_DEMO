const { test } = require('node:test');
const assert = require('node:assert/strict');
const { subjectFramePresentation, showSubjectFrame, selectedSubjectFrames } =
  require('../entry/src/main/ets/core/domain/SubjectFramePresentation.ets');

function assertBox(actual, expected) {
  assert.ok(actual, 'a visible subject should have a presentation box');
  assert.equal(actual.id, expected.id);
  for (const field of ['left', 'top', 'width', 'height']) {
    assert.ok(Math.abs(actual[field] - expected[field]) < 1e-12,
      `${field}: expected ${expected[field]}, received ${actual[field]}`);
  }
}

test('subject frame shrinks around the original center without changing tracking coordinates', () => {
  const input = Object.freeze({ id: 7, left: 0.3, top: 0.25, width: 0.2, height: 0.4 });
  const output = subjectFramePresentation(input);
  assertBox(output, { id: 7, left: 0.31, top: 0.27, width: 0.18, height: 0.36 });
  assert.notEqual(output, input);
  assert.deepEqual(input, { id: 7, left: 0.3, top: 0.25, width: 0.2, height: 0.4 });
});

test('a full-screen or oversized frame leaves visible space around all four sides', () => {
  for (const input of [
    { id: 9, left: 0, top: 0, width: 1, height: 1 },
    { id: 9, left: -0.2, top: -0.4, width: 1.4, height: 1.8 }
  ]) {
    assertBox(subjectFramePresentation(input), { id: 9, left: 0.1, top: 0.1, width: 0.8, height: 0.8 });
  }
});

test('partly visible edge subjects stay visible with at least eight percent inset', () => {
  assertBox(subjectFramePresentation({ id: 13, left: -0.08, top: 0.82, width: 0.2, height: 0.3 }),
    { id: 13, left: 0.08, top: 0.65, width: 0.18, height: 0.27 });
  assertBox(subjectFramePresentation({ id: 14, left: 0.9, top: -0.1, width: 0.4, height: 0.2 }),
    { id: 14, left: 0.56, top: 0.08, width: 0.36, height: 0.18 });
});

test('invalid numbers and empty dimensions cannot produce a visible frame', () => {
  const valid = { id: 7, left: 0.3, top: 0.25, width: 0.2, height: 0.4 };
  for (const field of ['id', 'left', 'top', 'width', 'height']) {
    for (const value of [NaN, Infinity, -Infinity]) {
      assert.equal(subjectFramePresentation({ ...valid, [field]: value }), undefined, `${field}=${value}`);
    }
  }
  for (const field of ['width', 'height']) {
    for (const value of [0, -0.2]) {
      assert.equal(subjectFramePresentation({ ...valid, [field]: value }), undefined, `${field}=${value}`);
    }
  }
});

test('fully off-screen subjects do not reappear as clamped phantom frames', () => {
  for (const input of [
    { id: 1, left: 1, top: 0.3, width: 0.2, height: 0.2 },
    { id: 1, left: 0.3, top: 1, width: 0.2, height: 0.2 },
    { id: 1, left: -0.2, top: 0.3, width: 0.2, height: 0.2 },
    { id: 1, left: 0.3, top: -0.2, width: 0.2, height: 0.2 }
  ]) {
    assert.equal(subjectFramePresentation(input), undefined);
  }
});

test('the workflow confirmation stage owns frame visibility across consecutive requests', () => {
  assert.equal(showSubjectFrame('confirm'), true);
  for (const stage of ['', 'idle', 'taking_off', 'scanning', 'selecting', 'plan', 'starting', 'shooting', 'returning',
    'completed', 'failed', 'cancelled']) {
    assert.equal(showSubjectFrame(stage), false, stage);
  }
  assert.equal(showSubjectFrame('confirm'), true, 'a new confirmation is visible after a completed request');
});

test('the frame uses only the workflow-selected real target and disappears as confirmation advances', () => {
  const target = { id: 7, left: 0.3, top: 0.25, width: 0.2, height: 0.4 };
  const other = { ...target, id: 9, left: 0.6 };
  const task = { stage: 'confirm', subjectId: 7, active: true };
  const frames = selectedSubjectFrames(task, [other, target]);
  assert.equal(frames.length, 1);
  assertBox(frames[0], { id: 7, left: 0.31, top: 0.27, width: 0.18, height: 0.36 });
  for (const stage of ['selecting', 'plan', 'starting', 'shooting', 'completed', 'failed', 'cancelled']) {
    assert.deepEqual(selectedSubjectFrames({ ...task, stage }, [target]), [], stage);
  }
  assert.deepEqual(selectedSubjectFrames(task, [other]), [], 'never draw another candidate as the selected subject');
  assert.deepEqual(selectedSubjectFrames({ ...task, subjectId: undefined }, [target]), []);
  assert.deepEqual(selectedSubjectFrames(task, [{ ...target, width: 0 }]), []);
});
