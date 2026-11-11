const { test } = require('node:test');
const assert = require('node:assert/strict');
const { VIDEO_MODE, PHOTO_MODE, PHOTO_CONTEXT_PAYLOAD } = require('../entry/src/main/ets/core/protocol/CameraCodec.ets');
const { CancellationToken } = require('../entry/src/main/ets/core/domain/OperationResult.ets');

let activeLogs;
const previousKits = global.__neoKits;
global.__neoKits = {
  ...previousKits,
  '@kit.PerformanceAnalysisKit': {
    hilog: Object.fromEntries(['info', 'warn', 'error'].map(level => [level,
      (...args) => activeLogs?.push({ level, args })]))
  }
};
const cameraModule = require.resolve('../entry/src/main/ets/core/domain/CameraService.ets');
delete require.cache[cameraModule];
const { CameraService } = require(cameraModule);
global.__neoKits = previousKits;

async function withClock(run) {
  const realNow = Date.now, realTimeout = global.setTimeout;
  const clock = { now: Date.UTC(2026, 10, 10, 10, 0), sleeps: 0, onSleep() {} };
  Date.now = () => clock.now;
  global.setTimeout = (callback, delay, ...args) => {
    clock.now += delay;
    clock.sleeps++;
    clock.onSleep();
    queueMicrotask(() => callback(...args));
    return 0;
  };
  try { return await run(clock); }
  finally { Date.now = realNow; global.setTimeout = realTimeout; activeLogs = undefined; }
}

function rig(clock, modeRaw = 1) {
  const calls = [], logs = [];
  activeLogs = logs;
  const telemetry = {
    cameraAgeMs: 0,
    camera: { modeRaw, observedAtMs: clock.now - 100, timeSynchronized: true,
      recordingCandidate: false, recordStateRaw: 0 },
    flightAgeMs: 0, flight: { airborne: true, motorsOn: true, modeRaw: 6 },
    taskAgeMs: 0, task: { observedAtMs: clock.now - 100, phaseRaw: 0, modeRaw: 0 }
  };
  const state = { linked: true };
  const session = {
    isReliableLinkFresh: () => state.linked,
    snapshot: () => ({ telemetry }),
    requestNative: async (...args) => {
      calls.push({ receiver: args[0], set: args[1], id: args[2], payload: [...args[3]] });
      return state.onRequest?.(...args);
    }
  };
  const camera = new CameraService(session, {});
  return { camera, telemetry, calls, logs, state };
}

function assertReleased(r) {
  assert.equal(r.camera.snapshot().operationActive, false, 'camera operation lock must be released');
}

function assertNoCapture(r) {
  assert.equal(r.calls.some(c => c.receiver === 1 && c.set === 2 && [1, 2].includes(c.id)), false,
    'preparing video mode must not send shutter or record start/stop');
  assert.equal(r.camera.snapshot().recordingRequested, false);
}

for (const age of [0, 1000]) {
  test(`video preparation reuses synchronized idle mode 1 at age ${age} without sending a mode command`, () => withClock(async clock => {
    const r = rig(clock);
    r.telemetry.cameraAgeMs = age;
    r.state.onRequest = async () => Uint8Array.of(0xe3);
    const result = await r.camera.prepareVideoMode();
    assertReleased(r);
    assert.equal(result.ok, true);
    assert.deepEqual(r.calls, []);
    assertNoCapture(r);
  }));
}

test('unsynchronized mode 1 is synchronized, then its newly observed mode is reused', () => withClock(async clock => {
  const r = rig(clock);
  r.telemetry.camera.timeSynchronized = false;
  r.state.onRequest = async (receiver, set, id) => {
    if (id === 0x54) {
      Object.assign(r.telemetry.camera, { timeSynchronized: true, observedAtMs: clock.now });
      return Uint8Array.of(0);
    }
    return Uint8Array.of(0xe3);
  };
  const result = await r.camera.prepareVideoMode();
  assertReleased(r);
  assert.equal(result.ok, true);
  assert.deepEqual(r.calls.map(c => c.id), [0x54]);
  assertNoCapture(r);
}));

test('mode is read again after clock synchronization instead of reusing the old mode 1', () => withClock(async clock => {
  const r = rig(clock);
  r.telemetry.camera.timeSynchronized = false;
  r.state.onRequest = async (receiver, set, id) => {
    if (id === 0x54) Object.assign(r.telemetry.camera,
      { timeSynchronized: true, modeRaw: 0, observedAtMs: clock.now });
    if (id === 0xff) Object.assign(r.telemetry.camera, { modeRaw: 1, observedAtMs: clock.now });
    return Uint8Array.of(0);
  };
  const result = await r.camera.prepareVideoMode();
  assertReleased(r);
  assert.equal(result.ok, true);
  assert.deepEqual(r.calls.map(c => c.id), [0x54, 0xff]);
  assert.deepEqual(r.calls[1].payload, [...VIDEO_MODE]);
  assertNoCapture(r);
}));

test('mode 0 sends VIDEO_MODE once and waits for a new camera observation rather than trusting its ACK', () => withClock(async clock => {
  const r = rig(clock, 0);
  r.state.onRequest = async () => Uint8Array.of(0);
  clock.onSleep = () => {
    if (clock.sleeps === 2) Object.assign(r.telemetry.camera, { modeRaw: 1, observedAtMs: clock.now });
  };
  const result = await r.camera.prepareVideoMode();
  assertReleased(r);
  assert.equal(result.ok, true);
  assert.equal(clock.sleeps, 2);
  assert.deepEqual(r.calls.map(c => [c.receiver, c.set, c.id, c.payload]), [[1, 2, 0xff, [...VIDEO_MODE]]]);
  assertNoCapture(r);
}));

function assertFailureDiagnostics(r, result, reply) {
  assert.equal(result.ok, false);
  assert.match(result.error.message, reply);
  const diagnostic = r.logs.filter(l => l.args[1] === 'NeoCamera').map(l => l.args.slice(2).join(' ')).join('\n');
  assert.match(diagnostic, /before|前/i, 'camera diagnostics must retain the pre-request state');
  assert.match(diagnostic, /after|后/i, 'camera diagnostics must retain the post-request state');
  for (const value of [0, 2]) assert.match(diagnostic, new RegExp(`mode(?:Raw)?[=:\\s]+${value}(?:\\D|$)`, 'i'));
  for (const value of [7, 17]) assert.match(diagnostic, new RegExp(`ageMs[=:\\s]+${value}(?:\\D|$)`, 'i'));
  for (const field of ['synced', 'recording']) {
    for (const value of ['true', 'false']) assert.match(diagnostic, new RegExp(`${field}[=:\\s]+${value}`, 'i'));
  }
}

for (const [name, reply, expected] of [
  ['nonzero reply', Uint8Array.of(0xe3), /0xe3/i],
  ['missing reply', undefined, /timeout/i]
]) {
  test(`video mode ${name} fails with the actual reply and logs both camera states without retrying`, () => withClock(async clock => {
    const r = rig(clock, 0);
    r.telemetry.cameraAgeMs = 7;
    r.state.onRequest = async () => {
      r.telemetry.cameraAgeMs = 17;
      Object.assign(r.telemetry.camera, { modeRaw: 2, timeSynchronized: false, recordingCandidate: true });
      return reply;
    };
    const result = await r.camera.prepareVideoMode();
    assertReleased(r);
    assert.deepEqual(r.calls.map(c => c.id), [0xff]);
    assertFailureDiagnostics(r, result, expected);
    assertNoCapture(r);
  }));
}

for (const [name, invalidate] of [
  ['stale camera', r => { r.telemetry.cameraAgeMs = 1001; }],
  ['missing camera', r => { delete r.telemetry.camera; }],
  ['missing camera age', r => { delete r.telemetry.cameraAgeMs; }],
  ['active recording', r => { r.telemetry.camera.recordingCandidate = true; }],
  ['unconfirmed local recording', r => { r.camera.recordingRequested = true; }],
  ['lost reliable link', r => { r.state.linked = false; }]
]) {
  test(`video preparation does not reuse mode 1 with ${name}`, () => withClock(async clock => {
    const r = rig(clock);
    invalidate(r);
    const result = await r.camera.prepareVideoMode();
    assertReleased(r);
    assert.equal(result.ok, false);
    assert.deepEqual(r.calls, []);
  }));
}

test('a cancelled preparation cannot reuse otherwise ready video mode', () => withClock(async clock => {
  const r = rig(clock), token = new CancellationToken(1);
  token.cancel();
  const result = await r.camera.prepareVideoMode(token);
  assertReleased(r);
  assert.equal(result.ok, false);
  assert.deepEqual(r.calls, []);
}));

test('clock synchronization cannot reuse the mode after recording starts or the link is lost', () => withClock(async clock => {
  for (const changed of ['recording', 'link']) {
    const r = rig(clock);
    r.telemetry.camera.timeSynchronized = false;
    r.state.onRequest = async () => {
      Object.assign(r.telemetry.camera, { timeSynchronized: true, observedAtMs: clock.now });
      if (changed === 'recording') r.telemetry.camera.recordingCandidate = true;
      else r.state.linked = false;
      return Uint8Array.of(0);
    };
    const result = await r.camera.prepareVideoMode();
    assertReleased(r);
    assert.equal(result.ok, false, changed);
    assert.deepEqual(r.calls.map(c => c.id), [0x54], changed);
  }
}));

test('cancellation or a new recording while waiting for the mode prevents successful preparation', () => withClock(async clock => {
  for (const changed of ['cancel', 'recording']) {
    const r = rig(clock, 0), token = new CancellationToken(1);
    r.state.onRequest = async () => Uint8Array.of(0);
    clock.onSleep = () => {
      Object.assign(r.telemetry.camera, { modeRaw: 1, observedAtMs: clock.now });
      if (changed === 'cancel') token.cancel();
      else r.telemetry.camera.recordingCandidate = true;
    };
    const result = await r.camera.prepareVideoMode(token);
    assertReleased(r);
    assert.equal(result.ok, false, changed);
    assert.deepEqual(r.calls.map(c => c.id), [0xff]);
    assertNoCapture(r);
  }
}));

test('a mode ACK without new matching telemetry times out and releases the camera lock', () => withClock(async clock => {
  const r = rig(clock, 0);
  r.state.onRequest = async () => Uint8Array.of(0);
  const result = await r.camera.prepareVideoMode();
  assertReleased(r);
  assert.equal(result.ok, false);
  assert.deepEqual(r.calls.map(c => c.id), [0xff]);
  assert.ok(clock.sleeps > 0);
  assertNoCapture(r);
}));

test('an in-flight mode preparation retains its lock against a second camera operation', () => withClock(async clock => {
  const r = rig(clock, 0);
  let resolveRequest;
  r.state.onRequest = () => new Promise(resolve => { resolveRequest = resolve; });
  const pending = r.camera.prepareVideoMode();
  assert.equal(r.camera.snapshot().operationActive, true);
  const second = await r.camera.prepareVideoMode();
  assert.equal(second.ok, false);
  assert.equal(second.error.code, 'CAMERA_BUSY');
  assert.equal(r.camera.snapshot().operationActive, true);
  Object.assign(r.telemetry.camera, { modeRaw: 1, observedAtMs: clock.now });
  resolveRequest(Uint8Array.of(0));
  assert.equal((await pending).ok, true);
  assertReleased(r);
  assert.deepEqual(r.calls.map(c => c.id), [0xff]);
}));

test('ordinary recording still sends its mode command and an explicit record-start command', () => withClock(async clock => {
  const r = rig(clock);
  r.state.onRequest = async () => {
    r.telemetry.camera.observedAtMs = clock.now;
    return Uint8Array.of(0);
  };
  const result = await r.camera.startRecording();
  assertReleased(r);
  assert.equal(result.ok, true);
  assert.deepEqual(r.calls.map(c => [c.id, c.payload]), [[0xff, [...VIDEO_MODE]], [2, [1]]]);
  assert.equal(r.camera.snapshot().recordingRequested, true);
}));

test('ordinary photography still selects photo context, switches photo mode, then sends its shutter', () => withClock(async clock => {
  const r = rig(clock);
  r.state.onRequest = async (receiver, set, id) => {
    r.telemetry.camera.observedAtMs = clock.now;
    if (id === 0xf9) {
      r.telemetry.task.observedAtMs = clock.now;
      return Uint8Array.from([0, ...PHOTO_CONTEXT_PAYLOAD]);
    }
    if (id === 0xff) r.telemetry.camera.modeRaw = 0;
    return Uint8Array.of(0);
  };
  const result = await r.camera.shoot();
  assertReleased(r);
  assert.equal(result.ok, true);
  assert.deepEqual(r.calls.map(c => [c.id, c.payload]),
    [[0xf9, [...PHOTO_CONTEXT_PAYLOAD]], [0xff, [...PHOTO_MODE]], [1, [1]]]);
}));
