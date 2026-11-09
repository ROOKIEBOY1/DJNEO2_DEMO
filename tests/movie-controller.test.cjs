const { test } = require('node:test');
const assert = require('node:assert/strict');
const { movieSourceReady } = require('../entry/src/main/ets/core/media/MovieEligibility.ets');
const { AppController } = require('../entry/src/main/ets/core/domain/AppController.ets');

function ready(overrides = {}) {
  return { agentMediaKind: 'video', agentMediaUri: 'a', agentMediaUris: ['a', 'b'], agentVideoResultReady: true,
    videoCapturePending: false, agentConfirmation: '', groundDolly: { active: false, stage: 'completed' },
    closeup: { active: false, stage: 'completed' }, ...overrides };
}

test('movie eligibility requires completed capture and full return, not merely partial playable clips', () => {
  assert.equal(movieSourceReady(ready()), true);
  assert.equal(movieSourceReady(ready({ closeup: { active: false, stage: 'idle' } })), true);
  for (const closeup of [{ active: true, stage: 'returning' }, { active: false, stage: 'failed' },
    { active: false, stage: 'cancelled' }]) assert.equal(movieSourceReady(ready({ closeup })), false);
  assert.equal(movieSourceReady(ready({ videoCapturePending: true })), false);
  assert.equal(movieSourceReady(ready({ agentVideoResultReady: false })), false);
  assert.equal(movieSourceReady(ready({ agentMediaKind: 'photo' })), false);
  assert.equal(movieSourceReady(ready({ agentMediaUris: [] })), false);
  assert.equal(movieSourceReady(ready({ groundDolly: { active: true, stage: 'shooting' } })), false);
});

function fixture() {
  const c = Object.create(AppController.prototype);
  const calls = [];
  let movie = { stage: 'idle', busy: false, sourceKey: 'key', sources: ['a', 'b'], outputPath: '', durationMs: 0 };
  Object.assign(c, { moviePreparing: false, moviePreparationEpoch: 0, movieSaving: false,
    syncMovieSources() {}, emit() {}, log() {}, ensureMoviePolling() {}, snapshot: () => ready(),
    movieComposer: { snapshot: () => ({ ...movie }), start: (...args) => { calls.push(['start', ...args]); movie.stage = 'probing'; movie.busy = true; },
      cancel: () => { calls.push(['cancel']); } },
    movieFiles: { prepareMusic: async () => '/files/titan.mp3', newOutputPath: () => '/files/movie.mp4',
      playableUri: path => 'file://' + path }, outputDirectory: '/files',
    galleryVideoReceiver: { save: async sources => calls.push(['save', sources]) },
    agentMediaUris: ['a', 'b'] });
  return { c, calls, setMovie: value => { movie = { ...movie, ...value }; } };
}

test('one-tap composition starts one independent job and reuses an existing completed movie', async () => {
  const f = fixture();
  await f.c.composeMovie({}); await f.c.composeMovie({});
  assert.deepEqual(f.calls, [['start', '/files/movie.mp4', '/files/titan.mp3']]);
  f.setMovie({ stage: 'completed', busy: false, outputPath: '/files/movie.mp4', durationMs: 10000 });
  await f.c.composeMovie({});
  assert.equal(f.calls.length, 1);
  assert.deepEqual(f.c.agentMediaUris, ['a', 'b']);
});

test('changing source or cancelling while the music is being prepared cannot start a late export', async () => {
  const f = fixture(); let finish;
  f.c.movieFiles.prepareMusic = () => new Promise(resolve => { finish = resolve; });
  const p = f.c.composeMovie({});
  assert.equal(f.c.moviePreparing, true);
  await f.c.composeMovie({});
  f.c.cancelMovie(); finish('/files/titan.mp3'); await p;
  assert.deepEqual(f.calls, [['cancel']]);
  assert.equal(f.c.moviePreparing, false);
  const g = fixture(); let resolve;
  g.c.movieFiles.prepareMusic = () => new Promise(done => { resolve = done; });
  const later = g.c.composeMovie({}); g.setMovie({ sourceKey: 'new' });
  resolve('/files/titan.mp3'); await assert.rejects(later, /素材.*变化|已变更/);
  assert.equal(g.calls.length, 0);
});

test('partial task cannot export and movie save targets only verified finished movie', async () => {
  const f = fixture();
  f.c.snapshot = () => ready({ closeup: { active: false, stage: 'failed' } });
  await assert.rejects(f.c.composeMovie({}), /完整|完成/);
  await assert.rejects(f.c.saveMovieToGallery({}), /完成|成片/);
  f.setMovie({ stage: 'completed', outputPath: '/files/movie.mp4', durationMs: 10000 });
  await f.c.saveMovieToGallery({});
  assert.deepEqual(f.calls, [['save', ['file:///files/movie.mp4']]]);
  assert.deepEqual(f.c.agentMediaUris, ['a', 'b']);
  assert.equal(f.c.movieSaving, false);
});

test('movie save serializes authorization and releases its lock on cancel or failure', async () => {
  const f = fixture(); let reject;
  f.setMovie({ stage: 'completed', outputPath: '/files/movie.mp4', durationMs: 10000 });
  f.c.galleryVideoReceiver.save = () => new Promise((_, fail) => { reject = fail; });
  const saving = f.c.saveMovieToGallery({});
  await assert.rejects(f.c.saveMovieToGallery({}), /正在/);
  reject(Error('已取消保存')); await assert.rejects(saving, /取消/);
  assert.equal(f.c.movieSaving, false);
  assert.deepEqual(f.c.agentMediaUris, ['a', 'b']);
});

test('source A to B to A invalidates an outstanding music preparation even though final key is equal', async () => {
  const f = fixture(); delete f.c.syncMovieSources;
  let selected = { stage: 'idle', busy: false, sources: [], sourceKey: '' };
  f.c.movieComposer.snapshot = () => ({ ...selected });
  f.c.movieComposer.setSources = sources => { selected = { stage: 'idle', busy: false, sources, sourceKey: JSON.stringify(sources) }; };
  f.c.movieFiles.revision = () => 'rev'; f.c.movieFiles.loadCompleted = () => undefined;
  f.c.movieSourceIdentity = ''; f.c.movieCacheAttemptKey = '';
  f.c.agentVideoResultReady = true; f.c.agentMediaKind = 'video';
  let finish; f.c.movieFiles.prepareMusic = () => new Promise(resolve => { finish = resolve; });
  const pending = f.c.composeMovie({});
  f.c.agentMediaUris = ['B']; f.c.syncMovieSources();
  f.c.agentMediaUris = ['a', 'b']; f.c.syncMovieSources();
  finish('/files/titan.mp3'); await pending;
  assert.equal(f.calls.some(call => call[0] === 'start'), false);
});

test('cached new group is restored after old native cancellation finishes, without another source change', () => {
  const f = fixture(); delete f.c.syncMovieSources;
  let busy = true; let restores = 0;
  f.c.agentMediaUris = ['B']; f.c.agentVideoResultReady = true; f.c.agentMediaKind = 'video';
  f.c.movieSourceIdentity = ''; f.c.movieCacheAttemptKey = '';
  f.c.movieComposer.setSources = () => {};
  f.c.movieComposer.snapshot = () => ({ stage: 'idle', busy, sources: ['B'], sourceKey: 'B-key' });
  f.c.movieComposer.restoreCompleted = () => { restores++; return true; };
  f.c.movieFiles.revision = () => 'B-rev';
  f.c.movieFiles.loadCompleted = () => ({ sourceKey: 'B-key', outputPath: '/files/old-B.mp4', durationMs: 9000 });
  f.c.syncMovieSources(); assert.equal(restores, 0);
  busy = false; f.c.syncMovieSources(); assert.equal(restores, 1);
  f.c.syncMovieSources(); assert.equal(restores, 1);
});

test('reconnecting resets remote ownership but retains a complete local result even when connection fails', async () => {
  const f = fixture();
  f.setMovie({ stage: 'completed', outputPath: '/files/movie.mp4', durationMs: 10000 });
  Object.assign(f.c, { agentMediaKind: 'video', agentMediaUri: 'a', agentVideoResultReady: true,
    profiles: { selected: () => ({ configured: true, registrationReady: true, routingReady: true }), runtime: () => ({}), selectedId: () => 'drone' },
    flight: { resetForAircraftSession() {} }, nativeTasks: { resetForAircraftSession() {} }, camera: { resetForAircraftSession() {} },
    captureMedia: { reset() {} }, retireCloseup() {},
    wifi: { join: async () => ({}), leave: async () => {} },
    session: { connect: async () => ({ ok: false }) }, run: async (_name, operation) => { await operation(); } });
  await f.c.connectSelectedAircraft();
  assert.deepEqual(f.c.agentMediaUris, ['a', 'b']); assert.equal(f.c.agentVideoResultReady, true);
  f.c.snapshot = () => ready({ closeup: { stage: 'failed', active: false } });
  await f.c.connectSelectedAircraft();
  assert.deepEqual(f.c.agentMediaUris, []); assert.equal(f.c.agentVideoResultReady, false);
});
