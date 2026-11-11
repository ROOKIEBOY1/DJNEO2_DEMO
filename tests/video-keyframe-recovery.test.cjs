const { test } = require('node:test');
const assert = require('node:assert/strict');
const { VideoKeyframeRecovery } = require('../entry/src/main/ets/core/media/VideoKeyframeRecovery.ets');

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function rig(send) {
  let at = 0;
  const calls = [], changes = [];
  const policy = new VideoKeyframeRecovery(reason => { calls.push(reason); return send ? send(reason) : Promise.resolve(); },
    () => at, snapshot => changes.push(snapshot));
  const input = { contextId: 'session-A', connected: true, videoAgeMs: 0,
    preview: { state: 'waiting_key', label: '', stats: { running: true, waitingForKey: true,
      renderedFrames: 0, acceptedRandomAccessFrames: 0, decoderEpoch: 1, lastRenderedAgeMs: -1,
      recoveryPaused: false } } };
  return { policy, input, calls, changes, setAt(value) { at = value; },
    observe(value, changes = {}) {
      at = value; Object.assign(input.preview.stats, changes); policy.observe(input);
    } };
}
async function settled() { await Promise.resolve(); await Promise.resolve(); }

test('keyframe policy never requests during healthy preview', async () => {
  const r = rig();
  for (let at = 0; at <= 8000; at += 250) r.observe(at, { renderedFrames: at + 1,
    acceptedRandomAccessFrames: 1, waitingForKey: false, lastRenderedAgeMs: 0 });
  assert.deepEqual(r.calls, []);
  assert.equal(r.policy.snapshot().automaticAttempts, 0);
});

test('keyframe policy waits two seconds at startup and confirms actual key plus rendered output', async () => {
  const r = rig(); r.observe(0); r.observe(1999); assert.deepEqual(r.calls, []);
  r.observe(2000); assert.deepEqual(r.calls, ['automatic']);
  assert.equal(r.policy.snapshot().pending, true);
  await settled(); assert.equal(r.policy.snapshot().state, 'requested');
  r.observe(2050, { acceptedRandomAccessFrames: 1 });
  assert.notEqual(r.policy.snapshot().state, 'recovered', 'an IRAP alone is not a displayed image');
  r.observe(2100, { renderedFrames: 1, lastRenderedAgeMs: 0, waitingForKey: false });
  assert.equal(r.policy.snapshot().state, 'recovered');
});

test('keyframe policy uses a strict two-second last-output threshold', async () => {
  const r = rig(); r.observe(0, { renderedFrames: 100, acceptedRandomAccessFrames: 5,
    waitingForKey: false, lastRenderedAgeMs: 0 });
  r.observe(2000, { lastRenderedAgeMs: 2000 }); assert.deepEqual(r.calls, []);
  r.observe(2001, { lastRenderedAgeMs: 2001 }); assert.deepEqual(r.calls, ['automatic']);
  await settled();
});

test('keyframe policy refuses stale control/video and stopped or paused automatic decode', () => {
  for (const invalid of ['control', 'video-missing', 'video-stale', 'video-negative', 'video-nan', 'stopped', 'paused']) {
    const r = rig();
    if (invalid === 'control') r.input.connected = false;
    if (invalid === 'video-missing') r.input.videoAgeMs = undefined;
    if (invalid === 'video-stale') r.input.videoAgeMs = 1001;
    if (invalid === 'video-negative') r.input.videoAgeMs = -1;
    if (invalid === 'video-nan') r.input.videoAgeMs = NaN;
    if (invalid === 'stopped') r.input.preview.stats.running = false;
    if (invalid === 'paused') r.input.preview.stats.recoveryPaused = true;
    r.observe(0); r.observe(3000); assert.deepEqual(r.calls, [], invalid);
  }
});

test('keyframe policy stops after three automatic attempts; manual remains available after cooldown', async () => {
  const r = rig(); r.observe(0);
  for (const at of [2000, 7000, 12000, 17000]) { r.observe(at); await settled(); }
  assert.deepEqual(r.calls, ['automatic', 'automatic', 'automatic']);
  assert.equal(r.policy.snapshot().automaticAttempts, 3);
  assert.equal(r.policy.snapshot().state, 'exhausted');
  await r.policy.requestManual(r.input);
  assert.equal(r.calls.at(-1), 'manual');
  assert.equal(r.policy.snapshot().automaticAttempts, 3);
});

test('keyframe manual and automatic requests share the five-second cooldown', async () => {
  const r = rig(); r.observe(0); await r.policy.requestManual(r.input);
  r.observe(2000); assert.equal(r.calls.length, 1);
  r.setAt(4999); await assert.rejects(r.policy.requestManual(r.input), /5.*秒|间隔|冷却/);
  r.observe(5000); await settled(); assert.deepEqual(r.calls, ['manual', 'automatic']);
});

test('keyframe policy does not refill the automatic budget on one late frame', async () => {
  const r = rig(); r.observe(0);
  for (const at of [2000, 7000, 12000]) { r.observe(at); await settled(); }
  r.observe(12050, { acceptedRandomAccessFrames: 1, renderedFrames: 1,
    waitingForKey: false, lastRenderedAgeMs: 0 });
  assert.equal(r.policy.snapshot().state, 'recovered');
  assert.equal(r.policy.snapshot().automaticAttempts, 3);
  r.observe(17000, { lastRenderedAgeMs: 4950 }); await settled();
  assert.equal(r.calls.length, 3); assert.equal(r.policy.snapshot().state, 'exhausted');
});

test('keyframe policy refills only after five seconds of continuously new rendered frames', async () => {
  const r = rig(); r.observe(0); r.observe(2000); await settled();
  r.observe(2050, { acceptedRandomAccessFrames: 1, renderedFrames: 1,
    waitingForKey: false, lastRenderedAgeMs: 0 });
  for (let index = 1; index <= 19; index++) r.observe(2050 + index * 250,
    { renderedFrames: index + 1, lastRenderedAgeMs: 0 });
  assert.equal(r.policy.snapshot().automaticAttempts, 1);
  r.observe(7050, { renderedFrames: 21, lastRenderedAgeMs: 0 });
  assert.equal(r.policy.snapshot().automaticAttempts, 0);
});

test('keyframe policy rejects frozen counters and a long output gap as sustained health', async () => {
  const r = rig(); r.observe(0); r.observe(2000); await settled();
  r.observe(2050, { acceptedRandomAccessFrames: 1, renderedFrames: 1,
    waitingForKey: false, lastRenderedAgeMs: 0 });
  for (const at of [3050, 4050, 5050, 6050, 7050]) r.observe(at, { lastRenderedAgeMs: 0 });
  assert.equal(r.policy.snapshot().automaticAttempts, 1, 'a repeated cached counter is not continued rendering');
  r.observe(7100, { renderedFrames: 2 });
  r.observe(8201, { renderedFrames: 3 });
  for (let index = 1; index <= 10; index++) r.observe(8201 + index * 250, { renderedFrames: 3 + index });
  assert.equal(r.policy.snapshot().automaticAttempts, 1, 'the 1101ms render gap starts a new health window');
});

test('keyframe send rejection consumes attempt/cooldown and is handled without retry flooding', async () => {
  const r = rig(() => Promise.reject(new Error('wire failure'))); r.observe(0); r.observe(2000);
  await settled(); assert.equal(r.policy.snapshot().state, 'failed');
  assert.match(r.policy.snapshot().message, /wire failure/);
  assert.equal(r.policy.snapshot().automaticAttempts, 1);
  r.observe(2250); assert.equal(r.calls.length, 1);
  r.observe(7000); await settled(); assert.equal(r.calls.length, 2);
});

test('new media can recover before the send promise finishes without cancelling or downgrading it', async () => {
  const send = deferred(), r = rig(() => send.promise); r.observe(0); r.observe(2000);
  r.observe(2050, { acceptedRandomAccessFrames: 1, renderedFrames: 1,
    waitingForKey: false, lastRenderedAgeMs: 0 });
  assert.equal(r.policy.snapshot().state, 'recovered'); assert.equal(r.policy.snapshot().pending, true);
  send.resolve(); await settled();
  assert.equal(r.policy.snapshot().state, 'recovered'); assert.equal(r.policy.snapshot().pending, false);
});

test('a late send failure or watchdog cannot turn observed key-and-frame recovery into failure', async () => {
  for (const failure of ['reject', 'watchdog']) {
    const send = deferred(), r = rig(() => send.promise); r.observe(0);
    const outcome = r.policy.requestManual(r.input).catch(error => error.message);
    r.observe(50, { acceptedRandomAccessFrames: 1, renderedFrames: 1,
      waitingForKey: false, lastRenderedAgeMs: 0 });
    assert.equal(r.policy.snapshot().state, 'recovered');
    if (failure === 'reject') send.reject(new Error('wire completion failed'));
    else r.observe(1500, { renderedFrames: 2, lastRenderedAgeMs: 0 });
    assert.match(await outcome, /未确认|超时/);
    assert.equal(r.policy.snapshot().state, 'recovered');
    assert.equal(r.policy.snapshot().pending, false);
    send.resolve(); await settled();
    assert.equal(r.policy.snapshot().state, 'recovered');
  }
});

test('a switched surface with cumulative frames but no rendered timestamp waits two seconds before requesting', async () => {
  const r = rig();
  r.observe(0, { renderedFrames: 100, acceptedRandomAccessFrames: 5,
    lastRenderedAgeMs: 0, waitingForKey: false });
  r.observe(100, { lastRenderedAgeMs: -1 }); r.observe(2099);
  assert.deepEqual(r.calls, []);
  r.observe(2100); assert.deepEqual(r.calls, ['automatic']); await settled();
});

test('hung sends are bounded and their late completion cannot settle a newer request', async () => {
  const first = deferred(), second = deferred(); let call = 0;
  const r = rig(() => (++call === 1 ? first.promise : second.promise)); r.observe(0);
  const firstResult = r.policy.requestManual(r.input).then(() => 'ok', error => error.message);
  r.observe(1500); assert.match(await firstResult, /超时/);
  assert.equal(r.policy.snapshot().pending, false);
  // The hung attempt is abandoned at 1500ms. Its completion-based conservative
  // retry window ends at 6500ms, rather than 5000ms after the original intent.
  r.setAt(5000); await assert.rejects(r.policy.requestManual(r.input), /5.*秒|间隔|冷却/);
  r.setAt(6500); const next = r.policy.requestManual(r.input);
  first.resolve(); await settled(); assert.equal(r.policy.snapshot().pending, true);
  second.resolve(); await next; assert.equal(r.policy.snapshot().state, 'requested');
});

test('a replacement context rejects the old request without carrying its result or quota', async () => {
  const first = deferred(), second = deferred(); let call = 0;
  const r = rig(() => (++call === 1 ? first.promise : second.promise)); r.observe(0);
  const firstResult = r.policy.requestManual(r.input).catch(error => error.message);
  r.input.contextId = 'session-B'; r.observe(100); assert.match(await firstResult, /会话|连接|取消/);
  r.observe(2100); assert.equal(r.calls.length, 2);
  first.reject(new Error('old session send failed')); await settled();
  assert.equal(r.policy.snapshot().pending, true);
  assert.equal(r.policy.snapshot().automaticAttempts, 1);
  assert.doesNotMatch(r.policy.snapshot().message, /old session/);
  second.resolve(); await settled();
});

test('temporary unreliable control cancels pending status but preserves cooldown and automatic quota', async () => {
  const send = deferred(), r = rig(() => send.promise); r.observe(0); r.observe(2000);
  r.input.connected = false; r.observe(2050);
  assert.equal(r.policy.snapshot().pending, false);
  assert.equal(r.policy.snapshot().automaticAttempts, 1);
  r.input.connected = true; r.observe(2200);
  await assert.rejects(r.policy.requestManual(r.input), /5.*秒|间隔|冷却/);
  send.reject(new Error('old unavailable outcome')); await settled();
  assert.equal(r.calls.length, 1); assert.equal(r.policy.snapshot().automaticAttempts, 1);
});

test('a new frame without a new accepted key, or a key without a new frame, is not request recovery', async () => {
  const r = rig(); r.observe(0, { acceptedRandomAccessFrames: 5, renderedFrames: 100,
    waitingForKey: false, lastRenderedAgeMs: 0 });
  await r.policy.requestManual(r.input);
  r.observe(100, { renderedFrames: 101 }); assert.notEqual(r.policy.snapshot().state, 'recovered');
  r.observe(200, { acceptedRandomAccessFrames: 6, renderedFrames: 100 });
  assert.notEqual(r.policy.snapshot().state, 'recovered');
  r.observe(300, { renderedFrames: 102 }); assert.equal(r.policy.snapshot().state, 'recovered');
});

test('manual preflight then synchronous preview restart captures a zero baseline instead of guessing an epoch reset', async () => {
  const r = rig(); r.observe(0, { acceptedRandomAccessFrames: 1, renderedFrames: 1,
    decoderEpoch: 4, recoveryPaused: true });
  r.policy.assertManualRequestAllowed(r.input); assert.equal(r.calls.length, 0);
  Object.assign(r.input.preview.stats, { acceptedRandomAccessFrames: 0, renderedFrames: 0,
    decoderEpoch: 0, recoveryPaused: false });
  await r.policy.requestManual(r.input);
  r.observe(100, { acceptedRandomAccessFrames: 1, renderedFrames: 3,
    decoderEpoch: 5, waitingForKey: false, lastRenderedAgeMs: 0 });
  assert.equal(r.policy.snapshot().state, 'recovered');
});

test('an epoch change with unchanged cumulative key counter never supplies fake key evidence', async () => {
  const r = rig(); r.observe(0, { acceptedRandomAccessFrames: 1, renderedFrames: 1,
    decoderEpoch: 4, waitingForKey: false, lastRenderedAgeMs: 0 });
  await r.policy.requestManual(r.input);
  r.observe(100, { decoderEpoch: 5, renderedFrames: 3 });
  assert.notEqual(r.policy.snapshot().state, 'recovered');
  r.observe(150, { acceptedRandomAccessFrames: 2, decoderEpoch: 3 });
  assert.notEqual(r.policy.snapshot().state, 'recovered', 'stale old-epoch snapshots are not current recovery');
});

test('manual failures update their own status before rejection, and callbacks stay quiet on telemetry ticks', async () => {
  const r = rig(); r.input.connected = false;
  await assert.rejects(r.policy.requestManual(r.input), /连接|链路/);
  assert.match(r.policy.snapshot().message, /连接|链路/);
  r.input.connected = true; r.observe(0); r.observe(2000); await settled();
  const notifications = r.changes.length;
  for (const at of [2250, 2500, 2750]) r.observe(at);
  assert.equal(r.changes.length, notifications);
  await assert.rejects(r.policy.requestManual(r.input), /5.*秒|间隔|冷却/);
  assert.match(r.policy.snapshot().message, /5.*秒|间隔|冷却/);
});

test('a synchronous lifecycle reset from the requesting callback prevents the old request from being sent', async () => {
  const r = rig(); let calls = 0, policy;
  policy = new VideoKeyframeRecovery(() => { calls++; return Promise.resolve(); }, () => 0,
    snapshot => { if (snapshot.state === 'requesting') policy.reset(); });
  await assert.rejects(policy.requestManual(r.input), /连接.*取消/);
  assert.equal(calls, 0);
  assert.equal(policy.snapshot().state, 'idle');
});

test('policy cooldown covers actual Session send time after a slow requesting UI callback', async () => {
  const { input } = rig(); let at = 0, advanced = false, lastWireAt;
  const wires = []; let rejectedBySession = 0;
  const policy = new VideoKeyframeRecovery(() => {
    if (lastWireAt !== undefined && at - lastWireAt < 5000) {
      rejectedBySession++; return Promise.reject(new Error('Session still cooling down'));
    }
    lastWireAt = at; wires.push(at); return Promise.resolve();
  }, () => at, snapshot => {
    if (snapshot.state === 'requesting' && !advanced) { advanced = true; at += 100; }
  });
  policy.observe(input); at = 2000; policy.observe(input); await settled();
  assert.deepEqual(wires, [2100]);
  assert.equal(policy.snapshot().lastRequestAtMs, 2000, 'request evidence time is not rewritten as completion time');
  at = 7000; policy.observe(input); await settled();
  assert.equal(policy.snapshot().automaticAttempts, 1, 'a too-early policy attempt must not consume quota');
  assert.equal(rejectedBySession, 0);
  at = 7100; policy.observe(input); await settled();
  assert.deepEqual(wires, [2100, 7100]); assert.equal(rejectedBySession, 0);
});

test('current send resolve, rejection and same-context cancellation start cooldown from their later completion', async () => {
  for (const end of ['resolve', 'reject', 'cancel']) {
    const first = deferred(); let call = 0;
    const r = rig(() => ++call === 1 ? first.promise : Promise.resolve()); r.observe(0);
    const outcome = r.policy.requestManual(r.input).catch(error => error.message);
    r.setAt(500);
    if (end === 'resolve') first.resolve();
    else if (end === 'reject') first.reject(new Error('send unconfirmed'));
    else { r.input.connected = false; r.observe(500); }
    await outcome;
    r.input.connected = true; r.setAt(5000);
    await assert.rejects(r.policy.requestManual(r.input), /5.*秒|间隔|冷却/, end);
    r.setAt(5500); await r.policy.requestManual(r.input);
    assert.equal(r.calls.length, 2, end);
    first.resolve(); await settled();
  }
});

test('late old-context completion cannot extend the replacement context cooldown', async () => {
  const old = deferred(); let call = 0;
  const r = rig(() => ++call === 1 ? old.promise : Promise.resolve()); r.observe(0);
  const outcome = r.policy.requestManual(r.input).catch(error => error.message);
  r.input.contextId = 'session-B'; r.observe(1000); await outcome;
  r.observe(3000); await settled();
  assert.deepEqual(r.calls, ['manual', 'automatic']);
  r.setAt(7000); old.resolve(); await settled();
  r.observe(8000); await settled();
  assert.deepEqual(r.calls, ['manual', 'automatic', 'automatic']);
  assert.equal(r.policy.snapshot().automaticAttempts, 2);
});
