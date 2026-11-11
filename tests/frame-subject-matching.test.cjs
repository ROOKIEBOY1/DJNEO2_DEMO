const { test } = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');
const { closestFrameSubjects, matchFrameSubjects } = require('../entry/src/main/ets/core/media/VlmFrame.ets');

const box = (id, left = .1) => ({ id, left, top: .2, width: .2, height: .5 });
const scan = (at, ids = [11, 13]) => ({ detectionAt: at, candidates: ids.map(id => box(id)),
  overlay: ids.map(id => box(id)), tracking: false });
const tracked = (at, id = 11, detectionAt = at - 650) => ({
  detectionAt, candidates: [box(11), box(13)], selectedIdCandidate: id,
  trackingAt: at, tracking: true, overlay: [box(id, .6)]
});

function captureFixture(subjectAt, { pendingFrames = 0, mutatePacking, frameAge = 30,
  cancelled = [], requestTicket = 17, requestError, mutateReleasing, releases = [], mutateCancel } = {}) {
  const path = require.resolve('../entry/src/main/ets/core/domain/AppController.ets');
  const cached = require.cache[path], originalLoad = Module._load;
  let polls = 0, epoch = 1, sessionId = 7, generation = 2, control = 3;
  const changes = () => ({ changeEpoch: () => epoch++, changeSession: () => sessionId++,
    changeFlight: () => generation++, changeControl: () => { control++; c.agentGeneration = control; } });
  const native = { requestFrame: () => { if (requestError) throw requestError; return requestTicket; },
    cancelFrame: ticket => { cancelled.push(ticket); if (mutateCancel) mutateCancel(changes()); }, takeFrame: () => {
    if (polls++ < pendingFrames) return undefined;
    return { rgba: new ArrayBuffer(2 * 2 * 4), width: 2, height: 2, capturedAtMs: Date.now() - frameAge };
  } };
  Module._load = function (name, parent, main) {
    if (name === 'libneovideo.so') return { default: native, ...native };
    if (name === '@kit.ImageKit') return { image: {
      PixelMapFormat: { RGBA_8888: 3 },
      createPixelMap: async () => ({ release: async () => {
        releases.push('pixels'); if (mutateReleasing) mutateReleasing('pixels', changes());
      } }),
      createImagePacker: () => ({ packToData: async () => {
        if (mutatePacking) mutatePacking(changes());
        return new ArrayBuffer(4);
      }, release: async () => {
        releases.push('packer'); if (mutateReleasing) mutateReleasing('packer', changes());
      } })
    } };
    return originalLoad.call(this, name, parent, main);
  };
  delete require.cache[path];
  let AppController;
  try { AppController = require(path).AppController; }
  finally {
    Module._load = originalLoad;
    if (cached) require.cache[path] = cached; else delete require.cache[path];
  }
  const c = Object.create(AppController.prototype);
  Object.assign(c, { vlmFramePending: false, agentGeneration: control,
    video: { snapshot: () => ({ state: 'live', stats: { decoderEpoch: epoch, waitingForKey: false } }) },
    session: { sessionId: () => sessionId, isReliableLinkFresh: () => true,
      snapshot: () => ({ telemetry: { subject: subjectAt() } }) },
    flight: { snapshot: () => ({ generation }) }, log() {} });
  return c;
}

test('frame subject matching: post-confirmation RGBA uses fresh matching tracking metadata instead of stale scan time', async () => {
  let report;
  const c = captureFixture(() => report);
  report = tracked(Date.now() - 20);
  const result = await c.captureVlmFrame(11);
  assert.equal(result.currentSubjectId, 11);
  assert.equal(result.candidatesObservedAtMs, report.trackingAt);
  assert.deepEqual(result.candidates, [box(11, .6)], 'locked validation marks the fresh tracking box, never the old scan boxes');
});

test('frame subject matching: scan selection never borrows tracking boxes or widens the 200ms report window', () => {
  assert.equal(closestFrameSubjects(1000, tracked(1000), undefined), undefined);
  assert.equal(matchFrameSubjects(1000, [tracked(1000)]), undefined);
  assert.equal(matchFrameSubjects(1000, [scan(799)]), undefined);
  const result = matchFrameSubjects(1000, [scan(800)]);
  assert.equal(result.source, 'candidates');
  assert.deepEqual(result.candidates.map(item => item.id), [11, 13]);
  assert.equal(result.observedAtMs, 800);
});

test('frame subject matching: locked matching is strict about time, ID, tracking presence and conflicting selection', () => {
  for (const report of [tracked(799), tracked(1201), tracked(1000, 13),
    { ...tracked(1000), tracking: false }, { ...tracked(1000), trackingAt: undefined },
    { ...tracked(1000), overlay: [box(11), box(13)] }, { ...tracked(1000), selectedIdCandidate: 13 }]) {
    assert.equal(matchFrameSubjects(1000, [report], 11), undefined);
  }
  const result = matchFrameSubjects(1000, [tracked(800)], 11);
  assert.equal(result.source, 'tracking');
  assert.equal(result.observedAtMs, 800);
  assert.equal(result.currentSubjectId, 11);
});

test('frame subject matching: a retained intermediate report can pair the frame even when both endpoints are too far away', () => {
  const reports = [scan(600), scan(1005, [17]), scan(1250)];
  assert.equal(closestFrameSubjects(1000, reports[0], reports[2]), undefined);
  const result = matchFrameSubjects(1000, reports);
  assert.equal(result.observedAtMs, 1005);
  assert.deepEqual(result.candidates.map(item => item.id), [17]);
});

test('frame subject matching: a changed session, control, flight or decoder during RGBA packing cannot return a frame', async () => {
  for (const change of ['changeEpoch', 'changeSession', 'changeFlight', 'changeControl']) {
    const c = captureFixture(() => scan(Date.now()), { mutatePacking: state => state[change]() });
    await assert.rejects(c.captureVlmFrame(), /会话|控制|画面|解码|变化/, change);
    assert.equal(c.vlmFramePending, false);
  }
});

test('frame subject matching: a different tracked subject during capture cannot be hidden by a later matching report', async () => {
  let reads = 0;
  const c = captureFixture(() => tracked(Date.now(), ++reads === 2 ? 13 : 11, Date.now()), { pendingFrames: 1 });
  await assert.rejects(c.captureVlmFrame(11), /主体|跟踪/);
});

test('frame subject matching: an old or future RGBA cannot become a fresh observation just because its metadata matches', async () => {
  for (const frameAge of [601, -100]) {
    const c = captureFixture(() => scan(Date.now() - frameAge), { frameAge });
    await assert.rejects(c.captureVlmFrame(), /过期|时间|画面/);
  }
});

test('frame subject matching: capture retains matching reports observed between its initial snapshot and RGBA arrival', async () => {
  const realNow = Date.now, realTimeout = global.setTimeout;
  const start = 100000; let now = start;
  Date.now = () => now;
  global.setTimeout = callback => { now += 16; queueMicrotask(callback); return 0; };
  try {
    const c = captureFixture(() => scan(now < start + 16 ? start - 300 :
      now < start + 208 ? start + 30 : start + 250, [17]), { pendingFrames: 16, frameAge: 226 });
    const frame = await c.captureVlmFrame();
    assert.equal(frame.capturedAtMs, start + 30);
    assert.equal(frame.candidatesObservedAtMs, start + 30);
    assert.deepEqual(frame.candidates.map(item => item.id), [17]);
  } finally { Date.now = realNow; global.setTimeout = realTimeout; }
});

test('frame subject matching: a locked observation preserves its actual readback failure instead of treating it as a target switch', async () => {
  const c = captureFixture(() => tracked(Date.now()));
  c.captureVlmFrame = async () => { throw new Error('已取得画面，但没有时间匹配的已确认主体跟踪回报'); };
  await assert.rejects(c.captureAgentObservation(false, 11), /未能复核.*跟踪回报.*未启动运镜/);
});

test('frame subject matching: a locked observation without live preview cannot silently become a frame-less action', async () => {
  const c = captureFixture(() => tracked(Date.now()));
  c.video.snapshot = () => ({ state: 'waiting_key' });
  c.nativeTasks = { snapshot: () => ({ kind: 'none', prepared: false, activeOrUnknown: false }) };
  c.camera = { snapshot: () => ({ recordingRequested: false }) };
  c.nativeConfig = { radiusMeters: 2, framing: '半身', zoom: 3, retreat: true };
  c.agentRequestSequence = 0;
  await assert.rejects(c.captureAgentObservation(false, 11), /画面.*未.*就绪|未能复核.*主体/);
});

test('frame subject matching: a conflicting selected ID during capture cannot be hidden by matching tracking history', async () => {
  for (const changesBack of [false, true]) {
    let reads = 0;
    const c = captureFixture(() => ({ ...tracked(Date.now()),
      selectedIdCandidate: ++reads < 3 || (changesBack && reads > 3) ? 11 : 13 }));
    await assert.rejects(c.captureVlmFrame(11), /主体|跟踪/);
  }
});

test('frame subject matching: a stable same-target handoff retries a temporary locked readback failure with a new frame', async () => {
  const c = captureFixture(() => tracked(Date.now()));
  const snapshot = c.session.snapshot;
  c.session.snapshot = () => ({ phase: 'ready', telemetry: { ...snapshot().telemetry,
    flightAgeMs: 0, flight: { modeRaw: 26, airborne: true, motorsOn: true } } });
  c.video.snapshot = () => ({ state: 'live', stats: { decoderEpoch: 1, waitingForKey: false,
    running: true, recoveryPaused: false, lastAssembledAgeMs: 0 } });
  c.waitForAutomaticSubjectScan = async () => {};
  c.nativeTasks = { snapshot: () => ({ kind: 'dolly', prepared: false, activeOrUnknown: false }) };
  c.camera = { snapshot: () => ({ recordingRequested: false }) };
  c.nativeConfig = { radiusMeters: 2, framing: '半身', zoom: 3, retreat: true };
  c.agentRequestSequence = 0; c.finishAgentObservation = () => {};
  const capture = c.captureVlmFrame; let attempts = 0;
  c.captureVlmFrame = async id => {
    if (++attempts === 1) throw new Error('实时图传取帧超时或会话已断开');
    return capture.call(c, id);
  };
  const fresh = await c.waitForCloseupTarget(() => true, 11);
  assert.equal(fresh.frame.currentSubjectId, 11);
  assert.equal(attempts, 2);
});

test('frame subject matching: optional handoff sampling still rejects explicit target and control changes', async () => {
  const target = captureFixture(() => ({ ...tracked(Date.now()), selectedIdCandidate: 13 }));
  await assert.rejects(target.captureAgentObservation(false, 11, true), /主体.*变化/);
  const control = captureFixture(() => tracked(Date.now()));
  control.captureVlmFrame = async () => { control.agentGeneration++; throw new Error('temporary readback gap'); };
  await assert.rejects(control.captureAgentObservation(false, 11, true), /控制状态.*变化/);
});

test('frame subject matching: every acquired native ticket is cancelled after success, timeout, decoder change or unmatched metadata', async () => {
  for (const mode of ['success', 'timeout', 'decoder', 'metadata']) {
    const cancelled = [];
    const c = captureFixture(() => scan(Date.now() - (mode === 'metadata' ? 650 : 0)), {
      cancelled, pendingFrames: mode === 'timeout' ? Infinity : 0,
      mutatePacking: mode === 'decoder' ? state => state.changeEpoch() : undefined
    });
    if (mode === 'success') await c.captureVlmFrame(); else await assert.rejects(c.captureVlmFrame());
    assert.deepEqual(cancelled, [17], mode);
    assert.equal(c.vlmFramePending, false);
  }
});

test('frame subject matching: a rejected native ticket is never cancelled as a different request', async () => {
  for (const requestError of [undefined, new Error('native request failed')]) {
    const cancelled = [];
    const c = captureFixture(() => scan(Date.now()), { cancelled, requestTicket: 0, requestError });
    await assert.rejects(c.captureVlmFrame());
    assert.deepEqual(cancelled, []);
    assert.equal(c.vlmFramePending, false);
  }
});

test('frame subject matching: state changes during image release or ticket cleanup cannot return a locked frame', async () => {
  for (const stage of ['packer', 'pixels', 'ticket']) {
    for (const change of ['selectedId', 'decoderEpoch']) {
      let selectedId = 11; const cancelled = [], releases = [];
      const mutate = state => { if (change === 'selectedId') selectedId = 13; else state.changeEpoch(); };
      const c = captureFixture(() => ({ ...tracked(Date.now()), selectedIdCandidate: selectedId }), {
        cancelled, releases,
        mutateReleasing: (resource, state) => { if (resource === stage) mutate(state); },
        mutateCancel: stage === 'ticket' ? mutate : undefined
      });
      await assert.rejects(c.captureVlmFrame(11), /主体.*变化|解码会话.*变化/, `${stage}/${change}`);
      assert.deepEqual(releases, ['packer', 'pixels']);
      assert.deepEqual(cancelled, [17]);
      assert.equal(c.vlmFramePending, false);
    }
  }
});

test('frame subject matching: image release errors propagate after remaining resources and native ticket are cleaned', async () => {
  const cancelled = [], releases = [];
  const c = captureFixture(() => tracked(Date.now()), { cancelled, releases,
    mutateReleasing: resource => { if (resource === 'packer') throw new Error('packer release failed'); } });
  await assert.rejects(c.captureVlmFrame(11), /packer release failed/);
  assert.deepEqual(releases, ['packer', 'pixels']);
  assert.deepEqual(cancelled, [17]);
  assert.equal(c.vlmFramePending, false);
});

test('frame subject matching: slow image cleanup cannot return a frame after its freshness limit expires', async () => {
  const realNow = Date.now; let now = 100000; Date.now = () => now;
  try {
    const cancelled = [];
    const c = captureFixture(() => tracked(Date.now()), { cancelled,
      mutateReleasing: resource => { if (resource === 'pixels') now += 601; } });
    await assert.rejects(c.captureVlmFrame(11), /画面已过期/);
    assert.deepEqual(cancelled, [17]);
  } finally { Date.now = realNow; }
});
