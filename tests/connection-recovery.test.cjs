const { test } = require('node:test');
const assert = require('node:assert/strict');
const { AppController } = require('../entry/src/main/ets/core/domain/AppController.ets');
const { CancellationToken } = require('../entry/src/main/ets/core/domain/OperationResult.ets');

function fixture() {
  const c = Object.create(AppController.prototype), events = [];
  let phase = 'ready', healthy = true, sessionId = 7;
  const telemetry = { flightAgeMs: 0, flight: { airborne: false, motorsOn: false },
    cameraAgeMs: 0, camera: { recordingCandidate: false } };
  const stats = { running: true, waitingForKey: false, recoveryPaused: false, lastRenderedAgeMs: 0 };
  c.busyValue = false; c.connectionRecoveryReason = ''; c.connectionAttempt = undefined; c.connectionEpoch = 0;
  c.log = s => events.push(s); c.emit = () => {};
  c.session = { snapshot: () => ({ phase, telemetry, transport: {} }), sessionId: () => sessionId,
    isStartupReady: () => healthy,
    disconnect: async () => { events.push('disconnect'); phase = 'disconnected'; sessionId++; return { ok: true }; } };
  c.video = { snapshot: () => ({ state: 'live', stats }), setSession: id => events.push(`video:${id}`) };
  c.flight = { snapshot: () => ({ movementActive: false }) };
  c.camera = { snapshot: () => ({ operationActive: false, recordingRequested: false }) };
  c.nativeTasks = { activeOrUnknown: () => false, snapshot: () => ({ busy: false, prepared: false }) };
  c.cancelOperations = () => events.push('cancel');
  c.connectSelectedAircraft = async () => { events.push('connect'); phase = 'registering'; };
  c.initialize = async () => { events.push('initialize'); phase = 'ready'; healthy = true; c.connectionRecoveryReason = ''; };
  return { c, events, telemetry, stats, setHealthy: v => healthy = v, setPhase: v => phase = v };
}

test('connection recovery leaves a healthy ready session intact', async () => {
  const { c, events } = fixture(); await c.ensureReadyConnection(); assert.deepEqual(events, []);
});
test('connection recovery replaces a ready session with stalled preview once without replaying flight', async () => {
  const { c, events, stats } = fixture(); stats.waitingForKey = true;
  await c.ensureReadyConnection();
  assert.deepEqual(events.filter(x => ['disconnect', 'connect', 'initialize'].includes(x)), ['disconnect', 'connect', 'initialize']);
  assert.ok(events.indexOf('video:') < events.indexOf('connect'));
});
test('connection recovery replaces a session after failed parameter preparation even if telemetry is fresh', async () => {
  const { c, events } = fixture();
  c.nativeConfig = {}; c.nativeTasks.prepare = async () => ({ ok: false, error: { code: 'NATIVE_PREPARE_FAILED', message: '参数回读失败' } });
  const result = await c.prepareNativeTask('dolly', new CancellationToken(1));
  assert.equal(result.ok, false); assert.match(c.connectionRecoveryReason, /参数回读失败/);
  await c.ensureReadyConnection(); assert.ok(events.includes('disconnect'));
  assert.equal(c.connectionRecoveryReason, '');
});
test('connection recovery never reconnects airborne, unknown, recording or active native sessions', async () => {
  for (const mode of ['airborne', 'unknown', 'recording', 'native', 'camera', 'movement', 'stale']) {
    const { c, events, telemetry, setHealthy } = fixture(); setHealthy(false);
    if (mode === 'airborne') telemetry.flight.airborne = true;
    if (mode === 'unknown') telemetry.flight = undefined;
    if (mode === 'recording') telemetry.camera.recordingCandidate = true;
    if (mode === 'native') c.nativeTasks.activeOrUnknown = () => true;
    if (mode === 'camera') c.camera.snapshot = () => ({ operationActive: true });
    if (mode === 'movement') c.flight.snapshot = () => ({ movementActive: true });
    if (mode === 'stale') telemetry.flightAgeMs = 1001;
    await c.ensureReadyConnection();
    assert.equal(events.includes('disconnect'), false, mode);
    assert.equal(events.includes('connect'), false, mode);
    assert.ok(events.some(x => /落地|停桨|恢复/.test(x)), mode);
  }
});
test('connection recovery serializes repeated clicks and caps a failed initialization at one replacement', async () => {
  const { c, events, setHealthy, setPhase } = fixture(); setHealthy(false);
  let release; c.connectSelectedAircraft = async () => {
    events.push('connect'); await new Promise(resolve => release = resolve); setPhase('registering');
  };
  c.initialize = async () => { events.push('initialize'); setPhase('registering'); };
  const first = c.ensureReadyConnection(), second = c.ensureReadyConnection();
  await new Promise(resolve => setImmediate(resolve)); release(); await Promise.all([first, second]);
  assert.equal(events.filter(x => x === 'connect').length, 1);
  assert.equal(events.filter(x => x === 'initialize').length, 1);
});
test('connection initialization accepts a verified control session before the first decoded preview', async () => {
  const { c, stats } = fixture(); stats.waitingForKey = true; stats.lastRenderedAgeMs = -1;
  c.run = async (_name, operation) => operation();
  c.session.initialize = async (_timeout, ready) => ready && !ready() ?
    { ok: false, error: { message: '实时画面未就绪' } } : { ok: true };
  await AppController.prototype.initialize.call(c);
  assert.equal(c.connectionRecoveryReason, '');
  assert.equal(c.connectionControlReady(), true);
  assert.equal(c.connectionHealthy(), false, 'visual actions still require a decoded preview');
  assert.equal(c.readyConnectionSession, 7);
});
test('connection preview readiness remains strict for visual work', () => {
  const { c, stats } = fixture(); assert.equal(c.previewReady(), true);
  for (const change of [{ waitingForKey: true }, { running: false }, { recoveryPaused: true }, { lastRenderedAgeMs: -1 }, { lastRenderedAgeMs: 1001 }]) {
    const original = { ...stats }; Object.assign(stats, change); assert.equal(c.previewReady(), false); Object.assign(stats, original);
  }
});
test('connection recovery cancelled while disconnecting cannot reconnect afterward', async () => {
  const { c, events, setHealthy } = fixture(); setHealthy(false);
  let release; c.session.disconnect = async () => { await new Promise(resolve => release = resolve); };
  const pending = c.ensureReadyConnection(); c.connectionEpoch++;
  release(); await pending; assert.equal(events.includes('connect'), false);
});
test('connection recovery applies the same ground gate to failed existing sessions', async () => {
  for (const mode of ['airborne', 'unknown', 'recording', 'grounded']) {
    const { c, events, telemetry, setPhase } = fixture(); setPhase('failed');
    if (mode === 'airborne') telemetry.flight.airborne = true;
    if (mode === 'unknown') telemetry.flight = undefined;
    if (mode === 'recording') telemetry.camera.recordingCandidate = true;
    await c.ensureReadyConnection();
    assert.equal(events.includes('connect'), mode === 'grounded', mode);
  }
});

function initialRegistration() {
  const f = fixture(), { c, telemetry } = f;
  delete telemetry.flight; delete telemetry.camera;
  const snapshot = c.session.snapshot;
  c.session.snapshot = () => ({ ...snapshot(), deviceVerified: false });
  f.setPhase('registering'); f.setHealthy(false);
  c.flight.snapshot = () => ({ takeoffSent: false, takeoffAcknowledged: false, nativeTaskMayFly: false,
    movementActive: false, landRequested: false, landSent: false, landAcknowledged: false });
  c.nativeTasks.snapshot = () => ({ busy: false, prepared: false });
  c.initialize = async () => { f.events.push('initialize'); f.setPhase('registering'); };
  return f;
}
test('connection retries an uninitialized registration with no telemetry once using a new handshake', async () => {
  const { c, events } = initialRegistration();
  await c.ensureReadyConnection();
  assert.equal(events.filter(x => x === 'disconnect').length, 1);
  assert.equal(events.filter(x => x === 'connect').length, 1);
  assert.equal(events.filter(x => x === 'initialize').length, 2);
});
test('connection bootstrap retry cannot bypass established or uncertain flight and camera state', async () => {
  for (const mode of ['established', 'takeoff', 'ack', 'native', 'move', 'land', 'sentLand', 'camera', 'record', 'prepared', 'oldFlight', 'oldTask', 'oldCamera']) {
    const { c, events, telemetry } = initialRegistration();
    if (mode === 'established') c.readyConnectionSession = 7;
    const flight = c.flight.snapshot();
    if (mode === 'takeoff') flight.takeoffSent = true;
    if (mode === 'ack') flight.takeoffAcknowledged = true;
    if (mode === 'native') flight.nativeTaskMayFly = true;
    if (mode === 'move') flight.movementActive = true;
    if (mode === 'land') flight.landRequested = true;
    if (mode === 'sentLand') flight.landSent = true;
    c.flight.snapshot = () => flight;
    if (mode === 'camera') c.camera.snapshot = () => ({ operationActive: true, recordingRequested: false });
    if (mode === 'record') c.camera.snapshot = () => ({ operationActive: false, recordingRequested: true });
    if (mode === 'prepared') c.nativeTasks.snapshot = () => ({ busy: false, prepared: true });
    if (mode === 'oldFlight') telemetry.flight = { airborne: true, motorsOn: true };
    if (mode === 'oldTask') telemetry.task = { modeRaw: 13 };
    if (mode === 'oldCamera') telemetry.camera = { recordingCandidate: true };
    await c.ensureReadyConnection();
    assert.equal(events.includes('connect'), false, mode);
  }
});
test('connection does not disconnect valid ground telemetry while waiting for the first keyframe', async () => {
  const { c, events, stats, setPhase } = fixture(); setPhase('registering');
  stats.waitingForKey = true; stats.lastRenderedAgeMs = -1;
  c.initialize = AppController.prototype.initialize.bind(c);
  c.run = async (_name, operation) => operation();
  c.session.initialize = async () => { setPhase('ready'); return { ok: true }; };
  await c.ensureReadyConnection();
  assert.equal(c.connectionControlReady(), true);
  assert.equal(events.includes('disconnect'), false);
});
test('connection bootstrap retry requires every local authorization flag to be explicitly clear', async () => {
  for (const flag of ['takeoffSent', 'takeoffAcknowledged', 'nativeTaskMayFly', 'movementActive', 'landRequested', 'landSent', 'landAcknowledged']) {
    const { c, events } = initialRegistration(); const flight = c.flight.snapshot(); delete flight[flag];
    c.flight.snapshot = () => flight;
    await c.ensureReadyConnection(); assert.equal(events.includes('connect'), false, flag);
  }
});
