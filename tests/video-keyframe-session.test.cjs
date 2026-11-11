const { test } = require('node:test');
const assert = require('node:assert/strict');
const { DroneSession } = require('../entry/src/main/ets/core/domain/DroneSession.ets');
const { ReliableTransport } = require('../entry/src/main/ets/core/transport/ReliableTransport.ets');
const { allDumlMessages } = require('../entry/src/main/ets/core/protocol/CommandCodec.ets');
const { decodeDumlFrame } = require('../entry/src/main/ets/core/protocol/DumlCodec.ets');
const { buildOuterHeader } = require('../entry/src/main/ets/core/protocol/OuterCodec.ets');
const { buildVideoKeyframeRequest } = require('../entry/src/main/ets/core/protocol/VideoKeyframeCodec.ets');

const flush = async () => { for (let n = 0; n < 8; n++) await Promise.resolve(); };
function clock() {
  const tasks = new Map(); let sequence = 0;
  const result = { time: 10000, nowMs: () => result.time,
    schedule(callback, delayMs) { const id = ++sequence; tasks.set(id, { at: result.time + delayMs, callback }); return id; },
    cancel(id) { tasks.delete(id); },
    async advance(ms) {
      const until = result.time + ms;
      while (true) {
        const next = [...tasks].sort((a, b) => a[1].at - b[1].at).find(entry => entry[1].at <= until);
        if (!next) break;
        result.time = next[1].at; tasks.delete(next[0]); next[1].callback(); await flush();
      }
      result.time = until; await flush();
    }, tasks };
  return result;
}
function rig(send) {
  const timer = clock(), session = new DroneSession(timer), sent = [];
  const channel = { async send(packet) { sent.push(new Uint8Array(packet)); if (send) return send(packet); },
    async close() {}, receivedCount: () => 1, sentCount: () => sent.length, lastPeer: () => '192.168.2.1:9003' };
  Object.assign(session, { channel, phaseValue: 'ready', session: 7, generation: 3, deviceVerified: true,
    lastControlReceivedAt: Date.now(), lastError: '',
    transport: new ReliableTransport(7, 0x1000),
    routing: { next() { throw new Error('Direct request must not consume application routing counters'); },
      snapshot: () => ({}), close() {} } });
  session.requestNative = async () => { throw new Error('Keyframe requests must not use the task tunnel or ACK waiter'); };
  const frames = () => sent.flatMap(allDumlMessages).map(decodeDumlFrame);
  return { timer, session, sent, channel, frames };
}

test('keyframe codec matches independent direct DUML golden vectors and wraps a monotonic uint32', () => {
  assert.equal(Buffer.from(buildVideoKeyframeRequest(0x1234, 0x89abcdef, true)).toString('hex'),
    '5517043802e934120018470008efcdab8901000000a84f');
  assert.equal(Buffer.from(buildVideoKeyframeRequest(0xffff, 0, false)).toString('hex'),
    '5517043802e9ffff0018470008000000000000000035cc');
  const wrapped = decodeDumlFrame(buildVideoKeyframeRequest(7, 0x100000009, true));
  assert.deepEqual([...wrapped.payload], [0, 8, 9, 0, 0, 0, 1, 0, 0, 0]);
  for (const bad of [-1, NaN, Infinity, 1.25, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => buildVideoKeyframeRequest(7, bad, true));
  }
  assert.throws(() => buildVideoKeyframeRequest(7, 1, 1));
});

test('keyframe session sends true then false after 120ms without any DUML ACK or flight/camera write', async () => {
  const f = rig();
  await f.session.requestVideoKeyframe('manual');
  assert.equal(f.frames().length, 1);
  assert.equal(f.session.pending.size, 0);
  await f.timer.advance(119); assert.equal(f.frames().length, 1);
  await f.timer.advance(1);
  assert.deepEqual(f.frames().map(frame => [frame.sender, frame.receiver, frame.flags, frame.commandSet, frame.commandId,
    new DataView(frame.payload.buffer).getUint32(6, true)]), [[2, 0xe9, 0, 0x18, 0x47, 1], [2, 0xe9, 0, 0x18, 0x47, 0]]);
  assert.deepEqual(f.frames().map(frame => new DataView(frame.payload.buffer).getUint32(2, true)), [10000, 10120]);
  assert.equal(f.session.snapshot().generation, 3);
});

test('keyframe session requires fresh verified ready control before true', async () => {
  for (const change of [s => { s.phaseValue = 'registering'; }, s => { s.deviceVerified = false; },
    s => { s.lastControlReceivedAt = Date.now() - 1001; }, s => { s.lastControlReceivedAt = Date.now() + 1000; },
    s => { s.lastError = 'link error'; }, s => { s.transport = undefined; }]) {
    const f = rig(); change(f.session);
    await assert.rejects(f.session.requestVideoKeyframe());
    assert.equal(f.sent.length, 0);
  }
});

test('keyframe session enforces five-second cooldown including rollback and ambiguous failed sends', async () => {
  const f = rig(() => { throw new Error('send rejected'); });
  await assert.rejects(f.session.requestVideoKeyframe(), /send rejected/);
  await assert.rejects(f.session.requestVideoKeyframe(), /处理中|间隔|冷却/);
  await f.timer.advance(120);
  f.timer.time = 9000;
  await assert.rejects(f.session.requestVideoKeyframe(), /间隔|冷却/);
  f.timer.time = 15000;
  await assert.rejects(f.session.requestVideoKeyframe(), /send rejected/);
  assert.equal(f.sent.length, 3, 'true attempt, its false, then a later true');
  await f.timer.advance(120);
});

test('keyframe false still follows if a video frame arrives or control freshness expires first', async () => {
  const f = rig(); let received = 0;
  f.session.setVideoFrameListener(() => received++);
  await f.session.requestVideoKeyframe();
  await f.timer.advance(50);
  const packet = new Uint8Array(25); packet.set(buildOuterHeader(7, 2, 25, 0x1008));
  packet.set([1, 1, 0, 0, 0, 0, 0, 1, 2], 16);
  f.session.onPacket(packet, Date.now());
  assert.equal(received, 1);
  f.session.lastControlReceivedAt = Date.now() - 2000;
  await f.timer.advance(70);
  assert.deepEqual(f.frames().map(frame => frame.payload[6]), [1, 0]);
});

test('keyframe false is independent of a delayed true callback and the true wait is bounded', async () => {
  let resolveTrue;
  const f = rig(packet => decodeDumlFrame(allDumlMessages(packet)[0]).payload[6] === 1 ?
    new Promise(resolve => { resolveTrue = resolve; }) : undefined);
  const pending = f.session.requestVideoKeyframe();
  const settled = pending.then(() => 'ok', error => error);
  await f.timer.advance(120);
  assert.deepEqual(f.frames().map(frame => frame.payload[6]), [1, 0]);
  await f.timer.advance(380);
  assert.match((await settled).message, /超时/);
  resolveTrue(); await flush();
  assert.equal(f.session.snapshot().lastError, '');
  assert.equal(f.session.snapshot().phase, 'ready');
});

test('keyframe false failures are isolated from flight control and release the pulse', async () => {
  const f = rig(packet => { if (decodeDumlFrame(allDumlMessages(packet)[0]).payload[6] === 0) throw new Error('false send failed'); });
  await f.session.requestVideoKeyframe();
  await f.timer.advance(120);
  assert.equal(f.session.snapshot().phase, 'ready'); assert.equal(f.session.snapshot().lastError, '');
  f.timer.time = 15000; await f.session.requestVideoKeyframe(); await f.timer.advance(120);
  assert.equal(f.frames().length, 4);
});

test('keyframe false timeout is bounded and cannot strand the pulse or change the control session', async () => {
  const f = rig(packet => decodeDumlFrame(allDumlMessages(packet)[0]).payload[6] === 0 ? new Promise(() => {}) : undefined);
  await f.session.requestVideoKeyframe(); await f.timer.advance(120);
  assert.ok(f.session.keyframePulse);
  await f.timer.advance(500);
  assert.equal(f.session.keyframePulse, undefined);
  assert.equal(f.session.snapshot().phase, 'ready'); assert.equal(f.session.snapshot().lastError, '');
  f.timer.time = 15000; await f.session.requestVideoKeyframe();
  assert.equal(f.frames().length, 3);
  await f.timer.advance(620);
});

test('a pending video send never blocks the existing stick and transport acknowledgement tick', async () => {
  const f = rig(packet => {
    const frame = allDumlMessages(packet).map(decodeDumlFrame)[0];
    if (frame?.commandSet === 0x18 && frame.payload[6] === 1) return new Promise(() => {});
  });
  f.session.registration = { poll: () => [], snapshot: () => ({}) };
  const pulse = f.session.requestVideoKeyframe().catch(error => error);
  let tickFinished = false;
  const tick = f.session.tick().then(() => { tickFinished = true; });
  await flush();
  assert.equal(tickFinished, true);
  await tick;
  assert.ok(f.frames().some(frame => frame.commandSet === 1 && frame.commandId === 0x0a));
  assert.ok(f.sent.some(packet => packet[6] === 4));
  await f.timer.advance(500);
  assert.match((await pulse).message, /超时/);
});

test('keyframe cleanup settles pending waits and stale reset callbacks cannot use a new session socket', async () => {
  let rejectOld;
  const f = rig(() => new Promise((_resolve, reject) => { rejectOld = reject; }));
  const old = f.session.requestVideoKeyframe().then(() => undefined, error => error);
  const oldReset = [...f.timer.tasks.values()].find(task => task.at === 10120)?.callback;
  await f.session.disconnect();
  assert.match((await old).message, /会话|取消/);
  const newer = rig();
  Object.assign(f.session, { channel: newer.channel, phaseValue: 'ready', session: 8, generation: 5,
    deviceVerified: true, lastControlReceivedAt: Date.now(), lastError: '',
    transport: new ReliableTransport(8, 0x2000), routing: { snapshot: () => ({}), close() {} } });
  await f.session.requestVideoKeyframe();
  oldReset(); rejectOld(new Error('late old callback')); await flush();
  assert.equal(newer.sent.length, 1);
  await f.timer.advance(120);
  assert.equal(newer.sent.length, 2);
  assert.equal(f.session.snapshot().phase, 'ready'); assert.equal(f.session.snapshot().lastError, '');
});
