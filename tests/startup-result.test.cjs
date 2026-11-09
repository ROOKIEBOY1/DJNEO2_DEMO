const { test } = require('node:test');
const assert = require('node:assert/strict');
const profileModule = require('../entry/src/main/ets/core/profile/AircraftProfileStore.ets');
const { NativeMovieFiles } = require('../entry/src/main/ets/core/platform/NativeMovieExport.ets');
const { MovieComposer } = require('../entry/src/main/ets/core/media/MovieComposer.ets');
const { AppController } = require('../entry/src/main/ets/core/domain/AppController.ets');
const { videoResultReady, taskProgressPresentation } =
  require('../entry/src/main/ets/core/domain/AssistantFlightPresentation.ets');

const filesDirectory = '/startup-test/files';

function cacheRecord(name) {
  const sources = [`file://${filesDirectory}/${name}-1.mp4`, `file://${filesDirectory}/${name}-2.mp4`];
  const revision = `${name}-revision`;
  const composer = new MovieComposer({});
  composer.setSources(sources, revision);
  return Object.freeze({ version: 1, sources: Object.freeze(sources), revision,
    sourceKey: composer.snapshot().sourceKey, outputPath: `${filesDirectory}/neo_movie_${name}.mp4`,
    durationMs: 12000, size: 32000 });
}

function withStoredMovies(latest, otherRecords, run) {
  const originalProfileStore = profileModule.AircraftProfileStore;
  const originalMethods = {};
  const records = new Map([latest, ...otherRecords].map(record => [record.sourceKey, record]));
  const lookups = [];
  // Replace file-backed boundaries only: the controller, workflows and composer are real instances.
  profileModule.AircraftProfileStore = class {
    list() { return []; }
    selectedId() { return ''; }
    selected() { return undefined; }
  };
  const methods = {
    loadLatest(directory) {
      assert.equal(directory, filesDirectory);
      return latest;
    },
    loadCompleted(directory, sourceKey) {
      assert.equal(directory, filesDirectory);
      lookups.push(sourceKey);
      return records.get(sourceKey);
    },
    revision(sources) {
      return [...records.values()].find(record => JSON.stringify(record.sources) === JSON.stringify(sources))?.revision ?? '';
    }
  };
  for (const [name, method] of Object.entries(methods)) {
    originalMethods[name] = NativeMovieFiles.prototype[name];
    NativeMovieFiles.prototype[name] = method;
  }
  try {
    return run({ lookups });
  } finally {
    profileModule.AircraftProfileStore = originalProfileStore;
    Object.assign(NativeMovieFiles.prototype, originalMethods);
  }
}

test('cold startup leaves historical movies out of the current media and flight results', () => {
  const historical = cacheRecord('historical');
  withStoredMovies(historical, [], () => {
    const controller = new AppController(filesDirectory, {});
    const state = controller.snapshot();

    assert.equal(videoResultReady(state), false, 'a stored movie is not evidence of a capture in this app session');
    assert.equal(state.agentMediaUri, '');
    assert.equal(state.agentMediaKind, '');
    assert.deepEqual(state.agentMediaUris, []);
    assert.equal(state.agentMediaCount, 0);
    assert.equal(state.agentVideoResultReady, false);
    assert.equal(state.agentFeedback, '');
    assert.equal(state.movie.stage, 'idle');
    assert.deepEqual(state.movie.sources, []);
    assert.equal(state.movie.outputPath, '');
    assert.equal(state.movieCanCompose, false);
    assert.equal(state.groundDolly.stage, 'idle');
    assert.equal(state.closeup.stage, 'idle');
    assert.equal(state.nativeTask.executionObserved, false);
    assert.equal(taskProgressPresentation(state).visible, false);

    // Session visibility must change without invalidating the independently stored cache.
    const files = new NativeMovieFiles();
    assert.equal(files.loadLatest(filesDirectory), historical);
    assert.equal(files.loadCompleted(filesDirectory, historical.sourceKey), historical);
  });
});

test('current capture sources still reuse their matching movie cache after startup', () => {
  const historical = cacheRecord('historical');
  const current = cacheRecord('current');
  withStoredMovies(historical, [current], ({ lookups }) => {
    const controller = new AppController(filesDirectory, {});
    // Supply current-session media as the capture-return path does, then use the real snapshot synchronization.
    Object.assign(controller, { agentMediaUris: current.sources.slice(), agentMediaUri: current.sources[0],
      agentMediaKind: 'video', agentMediaIndex: 0, agentVideoResultReady: true });
    const state = controller.snapshot();

    assert.equal(videoResultReady(state), true);
    assert.deepEqual(state.agentMediaUris, current.sources);
    assert.equal(state.movie.stage, 'completed');
    assert.deepEqual(state.movie.sources, current.sources);
    assert.equal(state.movie.sourceKey, current.sourceKey);
    assert.equal(state.movie.outputPath, current.outputPath);
    assert.equal(state.movie.durationMs, current.durationMs);
    assert.ok(lookups.includes(current.sourceKey), 'explicit current sources still perform the keyed cache lookup');
    assert.equal(new NativeMovieFiles().loadLatest(filesDirectory), historical);
  });
});
