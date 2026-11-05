const { test } = require('node:test');
const assert = require('node:assert/strict');
const { CameraService } = require('../entry/src/main/ets/core/domain/CameraService.ets');
const { PHOTO_CONTEXT_PAYLOAD } = require('../entry/src/main/ets/core/protocol/CameraCodec.ets');
const { CancellationToken } = require('../entry/src/main/ets/core/domain/OperationResult.ets');

function cameraInHover(modeRaw = 6) {
  const calls = [];
  const telemetry = {
    flightAgeMs: 0, flight: { airborne: true, motorsOn: true, modeRaw },
    taskAgeMs: 0, task: { phaseRaw: 0, modeRaw: 0, observedAtMs: 0 },
    cameraAgeMs: 0, camera: { observedAtMs: 0, recordingCandidate: false, timeSynchronized: true },
    subject: { tracking: modeRaw === 26, trackingAt: Date.now() }
  };
  const session = {
    isReliableLinkFresh: () => true, snapshot: () => ({ telemetry }),
    requestNative: async (receiver, set, id) => {
      calls.push([receiver, set, id]);
      if (id === 0xff) Object.assign(telemetry.camera, { modeRaw: 0, observedAtMs: Date.now() });
      return id === 0xf9 ? Uint8Array.from([0, ...PHOTO_CONTEXT_PAYLOAD]) : Uint8Array.of(0);
    }
  };
  return { camera: new CameraService(session, {}), telemetry, calls, session };
}

test('photo context supports ordinary scanned hover but waits for applied mode before shutter', async () => {
  const { camera, telemetry, calls } = cameraInHover();
  const result = camera.shoot();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(calls, [[0x17, 3, 0xf9]]);
  telemetry.task = { phaseRaw: 5, modeRaw: 9, observedAtMs: Date.now() };
  telemetry.camera.observedAtMs = Date.now();
  assert.equal((await result).ok, true);
  assert.deepEqual(calls, [[0x17, 3, 0xf9], [1, 2, 0xff], [1, 2, 1]]);
});

test('photo parameter echo does not require the idle task to change to native mode 9', async () => {
  const { camera, telemetry, calls } = cameraInHover();
  const pending = camera.shoot();
  await new Promise(resolve => setImmediate(resolve));
  telemetry.task = { phaseRaw: 0, modeRaw: 0, observedAtMs: Date.now(), payloadHex: '0000000100' };
  telemetry.camera.observedAtMs = Date.now();
  assert.equal((await pending).ok, true);
  assert.deepEqual(calls, [[0x17, 3, 0xf9], [1, 2, 0xff], [1, 2, 1]]);
});

test('cancelling during photo context settling prevents mode and shutter requests', async () => {
  const { camera, calls } = cameraInHover();
  const token = new CancellationToken(1);
  const pending = camera.shoot(token);
  await new Promise(resolve => setImmediate(resolve));
  token.cancel();
  assert.equal((await pending).ok, false);
  assert.deepEqual(calls, [[0x17, 3, 0xf9]]);
});

test('a rejected shutter is reported as failure rather than a successful photo', async () => {
  const { camera, telemetry, session } = cameraInHover();
  const original = session.requestNative;
  session.requestNative = async (...args) => {
    if (args[0] === 1 && args[2] === 1) return Uint8Array.of(0xe3);
    return original(...args);
  };
  const pending = camera.shoot();
  await new Promise(resolve => setImmediate(resolve));
  telemetry.task = { phaseRaw: 5, modeRaw: 9, observedAtMs: Date.now() };
  telemetry.camera.observedAtMs = Date.now();
  const result = await pending;
  assert.equal(result.ok, false);
  assert.equal(result.error.code, 'CAMERA_CAPTURE_REJECTED');
});

test('tracked manual hover can switch to photo context, active native tasks cannot', () => {
  const { camera, telemetry } = cameraInHover(26);
  assert.doesNotThrow(() => camera.ensurePhotoContextSafe());
  telemetry.task = { phaseRaw: 5, modeRaw: 13 };
  assert.throws(() => camera.ensurePhotoContextSafe());
});

test('a rejected or missing record-stop reply is not reported as success', async () => {
  for (const reply of [undefined, Uint8Array.of(0xe3)]) {
    const { camera, session } = cameraInHover();
    camera.recordingRequested = true;
    session.requestNative = async () => reply;
    assert.equal((await camera.stopRecording()).ok, false);
    assert.equal(camera.snapshot().recordingRequested, true);
  }
});

test('observed recording completion releases the local camera lock after stable fresh idle', () => {
  const {camera,telemetry}=cameraInHover();
  camera.recordingRequested=true;camera.recordingAttemptAtMs=1000;
  const observe=(at,recording)=>{
    Object.assign(telemetry.camera,{observedAtMs:at,recordingCandidate:recording});
    camera.observeTelemetry(telemetry);
  };
  observe(1100,true);observe(1200,false);
  assert.equal(camera.snapshot().recordingRequested,true);
  observe(1750,false);assert.equal(camera.snapshot().recordingRequested,false);
});

test('unobserved, stale or earlier recording telemetry cannot clear an uncertain start', () => {
  const {camera,telemetry}=cameraInHover();
  camera.recordingRequested=true;camera.recordingAttemptAtMs=1000;
  Object.assign(telemetry.camera,{observedAtMs:900,recordingCandidate:true});camera.observeTelemetry(telemetry);
  Object.assign(telemetry.camera,{observedAtMs:1500,recordingCandidate:false});camera.observeTelemetry(telemetry);
  telemetry.camera.observedAtMs=2500;camera.observeTelemetry(telemetry);
  assert.equal(camera.snapshot().recordingRequested,true);
  telemetry.cameraAgeMs=2000;telemetry.camera.recordingCandidate=true;camera.observeTelemetry(telemetry);
  telemetry.cameraAgeMs=0;telemetry.camera.recordingCandidate=false;
  telemetry.camera.observedAtMs=3500;camera.observeTelemetry(telemetry);
  assert.equal(camera.snapshot().recordingRequested,true);
});

test('verified grounded cycle clears an old idle recording lock but preserves active or stale recordings', () => {
  for (const mode of ['idle','recording','stale','airborne']) {
    const {camera,telemetry}=cameraInHover();
    camera.recordingRequested=true;camera.recordingAttemptAtMs=1000;
    Object.assign(telemetry.flight,{airborne:mode==='airborne',motorsOn:mode==='airborne',observedAtMs:3000});
    Object.assign(telemetry.camera,{observedAtMs:3000,recordingCandidate:mode==='recording'});
    telemetry.cameraAgeMs=mode==='stale'?2000:0;
    camera.resetAfterGroundedCycle();
    assert.equal(camera.snapshot().recordingRequested,mode!=='idle');
  }
});

test('a stale telemetry gap restarts the stable-idle observation window', () => {
  const {camera,telemetry}=cameraInHover();camera.recordingRequested=true;camera.recordingAttemptAtMs=1000;
  Object.assign(telemetry.camera,{observedAtMs:1100,recordingCandidate:true});camera.observeTelemetry(telemetry);
  Object.assign(telemetry.camera,{observedAtMs:1200,recordingCandidate:false});camera.observeTelemetry(telemetry);
  telemetry.cameraAgeMs=2000;camera.observeTelemetry(telemetry);
  telemetry.cameraAgeMs=0;telemetry.camera.observedAtMs=2500;camera.observeTelemetry(telemetry);
  assert.equal(camera.snapshot().recordingRequested,true);
  telemetry.camera.observedAtMs=3100;camera.observeTelemetry(telemetry);
  assert.equal(camera.snapshot().recordingRequested,false);
});
