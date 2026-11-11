const { test } = require('node:test');
const assert = require('node:assert/strict');

function fixture(sources = ['/clips/first.mp4', '/clips/second.mp4'], revision = 'capture-1') {
  const { MovieComposer } = require('../entry/src/main/ets/core/media/MovieComposer.ets');
  const calls = { starts: [], cancellations: [] };
  const jobs = new Map();
  const port = {
    start(inputs, outputPath, musicPath) {
      const id = calls.starts.length + 1;
      calls.starts.push({ sources: inputs.slice(), outputPath, musicPath });
      jobs.set(id, { id, stage: 'probing', progress: 0, durationMs: 0, error: '', outputPath });
      return id;
    },
    snapshot(id) { return jobs.get(id); },
    cancel(id) { calls.cancellations.push(id); }
  };
  const composer = new MovieComposer(port);
  composer.setSources(sources, revision);
  return { composer, calls, jobs, port };
}

function update(f, id, values) { Object.assign(f.jobs.get(id), values); f.composer.poll(); }

test('source groups deduplicate in source order and snapshots cannot mutate the selected group', () => {
  const inputs = ['/clips/b.mp4', '/clips/a.mp4', '/clips/b.mp4'];
  const f = fixture(inputs);
  inputs.push('/clips/injected.mp4');
  const snapshot = f.composer.snapshot();
  snapshot.sources.push('/clips/snapshot-injected.mp4');
  snapshot.stage = 'completed';
  f.composer.start('/movies/result.mp4', '/music/titan.mp3');
  assert.deepEqual(f.calls.starts[0].sources, ['/clips/b.mp4', '/clips/a.mp4']);
  assert.deepEqual(f.composer.snapshot().sources, ['/clips/b.mp4', '/clips/a.mp4']);
  assert.equal(f.composer.snapshot().stage, 'probing');
  assert.match(snapshot.sourceKey, /^user-bgm-v5\|/);
});

test('source identity changes with order or capture revision but not duplicate entries', () => {
  const f = fixture(['/a', '/b', '/a']);
  const first = f.composer.snapshot().sourceKey;
  f.composer.setSources(['/a', '/b'], 'capture-1');
  assert.equal(f.composer.snapshot().sourceKey, first);
  f.composer.setSources(['/b', '/a'], 'capture-1');
  assert.notEqual(f.composer.snapshot().sourceKey, first);
  f.composer.setSources(['/a', '/b'], 'capture-2');
  assert.notEqual(f.composer.snapshot().sourceKey, first);
});

test('repeated starts share one export and completed groups retain their verified cached output', () => {
  const f = fixture();
  f.composer.start('/movies/result.mp4', '/music/titan.mp3');
  f.composer.start('/movies/duplicate.mp4', '/music/titan.mp3');
  assert.equal(f.calls.starts.length, 1);
  assert.equal(f.composer.snapshot().busy, true);
  assert.equal(f.composer.snapshot().outputPath, '');
  update(f, 1, { stage: 'rendering', progress: 0.45, durationMs: 7200 });
  assert.equal(f.composer.snapshot().stage, 'rendering');
  assert.equal(f.composer.snapshot().progress, 0.45);
  update(f, 1, { stage: 'finalizing', progress: 0.97 });
  assert.equal(f.composer.snapshot().outputPath, '');
  update(f, 1, { stage: 'completed', progress: 1 });
  assert.equal(f.composer.snapshot().stage, 'completed');
  assert.equal(f.composer.snapshot().outputPath, '/movies/result.mp4');
  assert.equal(f.composer.snapshot().durationMs, 7200);
  assert.equal(f.composer.snapshot().busy, false);
  f.composer.start('/movies/again.mp4', '/music/titan.mp3');
  assert.equal(f.calls.starts.length, 1);
  assert.equal(f.composer.snapshot().outputPath, '/movies/result.mp4');
});

test('a new source group cancels the old export and keeps the cleanup lock until terminal acknowledgement', () => {
  const f = fixture();
  f.composer.start('/movies/old.mp4', '/music/titan.mp3');
  f.composer.setSources(['/clips/new.mp4'], 'capture-2');
  assert.deepEqual(f.calls.cancellations, [1]);
  assert.equal(f.composer.snapshot().stage, 'idle');
  assert.equal(f.composer.snapshot().busy, true);
  f.composer.start('/movies/new.mp4', '/music/titan.mp3');
  assert.equal(f.calls.starts.length, 1);
  update(f, 1, { stage: 'rendering', progress: 0.8, durationMs: 9000 });
  assert.equal(f.composer.snapshot().stage, 'idle');
  assert.equal(f.composer.snapshot().progress, 0);
  update(f, 1, { stage: 'completed', progress: 1, durationMs: 9000 });
  assert.equal(f.composer.snapshot().stage, 'idle');
  assert.equal(f.composer.snapshot().outputPath, '');
  assert.equal(f.composer.snapshot().busy, false);
  f.composer.start('/movies/new.mp4', '/music/titan.mp3');
  assert.deepEqual(f.calls.starts[1].sources, ['/clips/new.mp4']);
});

test('switching away and back never republishes a late completion from the earlier group instance', () => {
  const f = fixture(['/clips/a.mp4'], 'same-revision');
  f.composer.start('/movies/old.mp4', '/music/titan.mp3');
  f.composer.setSources(['/clips/b.mp4'], 'other-revision');
  f.composer.setSources(['/clips/a.mp4'], 'same-revision');
  update(f, 1, { stage: 'completed', progress: 1, durationMs: 2000 });
  assert.equal(f.composer.snapshot().stage, 'idle');
  assert.equal(f.composer.snapshot().outputPath, '');
});

test('cancel discards a late success and prevents retry until that job stops', () => {
  const f = fixture();
  f.composer.start('/movies/cancelled.mp4', '/music/titan.mp3');
  f.composer.cancel();
  f.composer.cancel();
  assert.deepEqual(f.calls.cancellations, [1]);
  assert.equal(f.composer.snapshot().stage, 'cancelled');
  assert.equal(f.composer.snapshot().busy, true);
  f.composer.start('/movies/retry.mp4', '/music/titan.mp3');
  assert.equal(f.calls.starts.length, 1);
  update(f, 1, { stage: 'completed', progress: 1, durationMs: 2200 });
  assert.equal(f.composer.snapshot().stage, 'cancelled');
  assert.equal(f.composer.snapshot().outputPath, '');
  assert.equal(f.composer.snapshot().busy, false);
  f.composer.start('/movies/retry.mp4', '/music/titan.mp3');
  assert.equal(f.calls.starts.length, 2);
});

test('native failure reports its reason and permits a fresh export only after native terminal state', () => {
  const f = fixture();
  f.composer.start('/movies/failed.mp4', '/music/titan.mp3');
  update(f, 1, { stage: 'failed', error: '不支持本次视频编码', progress: 0.2 });
  assert.equal(f.composer.snapshot().stage, 'failed');
  assert.match(f.composer.snapshot().error, /不支持本次视频编码/);
  assert.equal(f.composer.snapshot().busy, false);
  f.composer.start('/movies/retry.mp4', '/music/titan.mp3');
  assert.equal(f.calls.starts.length, 2);
  assert.equal(f.composer.snapshot().error, '');
});

test('native cancellation acknowledges cleanup without ever publishing an unfinished output', () => {
  const f = fixture();
  f.composer.start('/movies/stopped.mp4', '/music/titan.mp3');
  update(f, 1, { stage: 'cancelled', progress: 0.4 });
  assert.equal(f.composer.snapshot().stage, 'cancelled');
  assert.equal(f.composer.snapshot().busy, false);
  assert.equal(f.composer.snapshot().outputPath, '');
});

for (const [name, invalid] of [
  ['wrong job id', { id: 999 }],
  ['unknown stage', { stage: 'done' }],
  ['non-finite progress', { progress: NaN }],
  ['different output path', { outputPath: '/movies/unrelated.mp4' }],
  ['blank output path', { outputPath: '' }],
  ['zero completed duration', { durationMs: 0 }],
  ['non-finite completed duration', { durationMs: Infinity }]
]) {
  test(`invalid native ${name} cannot become a completed movie`, () => {
    const f = fixture();
    f.composer.start('/movies/result.mp4', '/music/titan.mp3');
    update(f, 1, { stage: 'completed', progress: 1, durationMs: 3000, ...invalid });
    assert.equal(f.composer.snapshot().stage, 'failed');
    assert.equal(f.composer.snapshot().outputPath, '');
    assert.match(f.composer.snapshot().error, /[\u4e00-\u9fff]/);
  });
}

test('an unrelated terminal job cannot release the native cleanup lock', () => {
  const f = fixture();
  f.composer.start('/movies/result.mp4', '/music/titan.mp3');
  update(f, 1, { id: 999, stage: 'completed', progress: 1, durationMs: 3000 });
  assert.equal(f.composer.snapshot().busy, true);
  f.composer.start('/movies/retry.mp4', '/music/titan.mp3');
  assert.equal(f.calls.starts.length, 1);
  update(f, 1, { id: 1, stage: 'cancelled' });
  assert.equal(f.composer.snapshot().busy, false);
  f.composer.start('/movies/retry.mp4', '/music/titan.mp3');
  assert.equal(f.calls.starts.length, 2);
});

test('a malformed active snapshot requests cancellation and waits for the real job to stop', () => {
  const f = fixture();
  f.composer.start('/movies/result.mp4', '/music/titan.mp3');
  update(f, 1, { stage: 'rendering', progress: NaN });
  assert.equal(f.composer.snapshot().busy, true);
  assert.deepEqual(f.calls.cancellations, [1]);
  f.composer.start('/movies/retry.mp4', '/music/titan.mp3');
  assert.equal(f.calls.starts.length, 1);
  update(f, 1, { stage: 'completed', progress: 1, durationMs: 3000 });
  assert.equal(f.composer.snapshot().stage, 'failed');
  assert.equal(f.composer.snapshot().busy, false);
  assert.equal(f.composer.snapshot().outputPath, '');
});

test('polling and cancellation exceptions become explicit failures without releasing a running job', () => {
  const f = fixture();
  f.composer.start('/movies/result.mp4', '/music/titan.mp3');
  f.port.snapshot = () => { throw new Error('snapshot unavailable'); };
  f.port.cancel = () => { throw new Error('cancel unavailable'); };
  assert.doesNotThrow(() => f.composer.poll());
  assert.equal(f.composer.snapshot().stage, 'failed');
  assert.equal(f.composer.snapshot().busy, true);
  assert.match(f.composer.snapshot().error, /[\u4e00-\u9fff]/);
  assert.equal(f.composer.snapshot().outputPath, '');
  f.port.snapshot = id => f.jobs.get(id);
  update(f, 1, { stage: 'completed', progress: 1, durationMs: 3000 });
  assert.equal(f.composer.snapshot().stage, 'failed');
  assert.equal(f.composer.snapshot().busy, false);
});

test('start exceptions and invalid job ids fail explicitly and allow retry', () => {
  for (const result of [() => { throw new Error('no codec'); }, () => 0, () => NaN, () => -1, () => 0.5]) {
    const f = fixture();
    const start = f.port.start;
    f.port.start = result;
    assert.doesNotThrow(() => f.composer.start('/movies/result.mp4', '/music/titan.mp3'));
    assert.equal(f.composer.snapshot().stage, 'failed');
    assert.equal(f.composer.snapshot().busy, false);
    assert.match(f.composer.snapshot().error, /[\u4e00-\u9fff]/);
    f.port.start = start;
    f.composer.start('/movies/retry.mp4', '/music/titan.mp3');
    assert.equal(f.composer.snapshot().stage, 'probing');
  }
});

for (const [name, sources, output, music] of [
  ['missing sources', [], '/movies/result.mp4', '/music/titan.mp3'],
  ['blank output', ['/clips/a.mp4'], '  ', '/music/titan.mp3'],
  ['blank music', ['/clips/a.mp4'], '/movies/result.mp4', ''],
  ['original path', ['/clips/a.mp4'], '/clips/a.mp4', '/music/titan.mp3'],
  ['normalized original path', ['/clips/a.mp4'], '/clips/folder/../a.mp4', '/music/titan.mp3'],
  ['original file URI', ['file:///clips/a.mp4'], '/clips/a.mp4', '/music/titan.mp3'],
  ['music path', ['/clips/a.mp4'], '/music/titan.mp3', '/music/titan.mp3']
]) {
  test(`unsafe export with ${name} is rejected before calling the media engine`, () => {
    const f = fixture(sources);
    f.composer.start(output, music);
    assert.equal(f.calls.starts.length, 0);
    assert.equal(f.composer.snapshot().stage, 'failed');
    assert.equal(f.composer.snapshot().busy, false);
    assert.match(f.composer.snapshot().error, /[\u4e00-\u9fff]/);
  });
}

test('progress exposed to the caller remains bounded', () => {
  const f = fixture();
  f.composer.start('/movies/result.mp4', '/music/titan.mp3');
  update(f, 1, { progress: -0.3 });
  assert.equal(f.composer.snapshot().progress, 0);
  update(f, 1, { progress: 5 });
  assert.equal(f.composer.snapshot().progress, 1);
});

test('verified manifest restoration accepts only the currently selected group and valid completed metadata', () => {
  const f = fixture(['/clips/a.mp4', '/clips/b.mp4']);
  assert.equal(f.composer.restoreCompleted(['/clips/a.mp4', '/clips/b.mp4'], 'different', '/movies/cached.mp4', 5000), false);
  assert.equal(f.composer.restoreCompleted(['/clips/b.mp4', '/clips/a.mp4'], 'capture-1', '/movies/cached.mp4', 5000), false);
  assert.equal(f.composer.restoreCompleted(['/clips/a.mp4', '/clips/b.mp4'], 'capture-1', '', 5000), false);
  assert.equal(f.composer.restoreCompleted(['/clips/a.mp4', '/clips/b.mp4'], 'capture-1', '/clips/a.mp4', 5000), false);
  assert.equal(f.composer.restoreCompleted(['/clips/a.mp4', '/clips/b.mp4'], 'capture-1', '/movies/cached.mp4', 0), false);
  assert.equal(f.composer.restoreCompleted(['/clips/a.mp4', '/clips/b.mp4'], 'capture-1', '/movies/cached.mp4', NaN), false);
  assert.equal(f.composer.snapshot().stage, 'idle');
  assert.equal(f.composer.restoreCompleted(['/clips/a.mp4', '/clips/b.mp4', '/clips/a.mp4'], 'capture-1', '/movies/cached.mp4', 5000), true);
  assert.equal(f.composer.snapshot().stage, 'completed');
  assert.equal(f.composer.snapshot().progress, 1);
  assert.equal(f.composer.snapshot().durationMs, 5000);
  assert.equal(f.composer.snapshot().outputPath, '/movies/cached.mp4');
  f.composer.start('/movies/duplicate.mp4', '/music/titan.mp3');
  assert.equal(f.calls.starts.length, 0);
});

test('manifest restoration cannot replace active exports or release cleanup locks', () => {
  const f = fixture(['/clips/a.mp4']);
  f.composer.start('/movies/active.mp4', '/music/titan.mp3');
  assert.equal(f.composer.restoreCompleted(['/clips/a.mp4'], 'capture-1', '/movies/cached.mp4', 5000), false);
  f.composer.setSources(['/clips/b.mp4'], 'capture-2');
  assert.equal(f.composer.restoreCompleted(['/clips/b.mp4'], 'capture-2', '/movies/cached.mp4', 5000), false);
  assert.equal(f.composer.snapshot().stage, 'idle');
  assert.equal(f.composer.snapshot().busy, true);
});
