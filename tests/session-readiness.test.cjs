const { test } = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');
const { buildOuterHeader } = require('../entry/src/main/ets/core/protocol/OuterCodec.ets');
const { allDumlMessages } = require('../entry/src/main/ets/core/protocol/CommandCodec.ets');
const { encodeDumlFrame, decodeDumlFrame } = require('../entry/src/main/ets/core/protocol/DumlCodec.ets');
const { writeU16LE } = require('../entry/src/main/ets/core/protocol/Bytes.ets');
const { builtInRegistrationProfile } = require('../entry/src/main/ets/core/transport/RegistrationExchange.ets');

function fixture({ missing, stale, replyDelay = 0 } = {}) {
  const sessionPath = require.resolve('../entry/src/main/ets/core/domain/DroneSession.ets');
  const routingPath = require.resolve('../entry/src/main/ets/core/transport/RoutingSequenceStore.ets');
  const saved = [require.cache[sessionPath], require.cache[routingPath]];
  const originalLoad = Module._load;
  const files = new Map([['/readiness/routing-sequence.json', JSON.stringify({
    version: 1, next_counter: 1000, routing_identity: '8e338dbb'
  })]]);
  Module._load = function (name, parent, main) {
    if (name === '@kit.CoreFileKit') return { fileIo: {
      OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
      accessSync: path => path === '/readiness' || files.has(path),
      readTextSync: path => files.get(path), openSync: path => ({ fd: path }),
      writeSync: (path, text) => files.set(path, text), fsyncSync() {}, closeSync() {},
      renameSync(from, to) { files.set(to, files.get(from)); files.delete(from); }
    } };
    return originalLoad.call(this, name, parent, main);
  };
  delete require.cache[sessionPath]; delete require.cache[routingPath];
  let session;
  try { session = new (require(sessionPath).DroneSession)(); }
  finally {
    Module._load = originalLoad;
    for (const [index, path] of [sessionPath, routingPath].entries()) {
      if (saved[index]) require.cache[path] = saved[index]; else delete require.cache[path];
    }
  }
  let receive;
  let deviceQueries = 0;
  let videoSequence = 0;
  const timers = [];
  const errors = [];
  const sent = [];
  function downlink(messages = [], timestamp = Date.now()) {
    const size = 34 + messages.reduce((total, message) => total + message.length, 0);
    const packet = new Uint8Array(size);
    packet.set(buildOuterHeader(session.sessionId(), 1, size));
    writeU16LE(packet, 24, session.transport?.snapshot().sent ?
      (session.videoSeed + session.transport.snapshot().sent * 8) & 0xffff : session.videoSeed);
    let offset = 34;
    for (const message of messages) { packet.set(message, offset); offset += message.length; }
    receive(packet, timestamp);
  }
  function telemetry(kind, timestamp = Date.now()) {
    if (kind === 'flight') {
      const payload = new Uint8Array(36); payload[30] = 6;
      downlink([encodeDumlFrame(3, 2, 1, 0, 3, 0x43, payload)], timestamp);
    } else if (kind === 'task') {
      downlink([encodeDumlFrame(0x92, 2, 2, 0, 0x23, 0x14,
        new Uint8Array([0, 0, 0, 1, 2]))], timestamp);
    } else if (kind === 'camera') {
      downlink([encodeDumlFrame(1, 2, 3, 0, 2, 0x80, new Uint8Array(60))], timestamp);
    } else if (kind === 'video') {
      const packet = new Uint8Array(25);
      videoSequence = videoSequence ? (videoSequence + 8) & 0xffff : (session.videoSeed + 8) & 0xffff;
      packet.set(buildOuterHeader(session.sessionId(), 2, 25, videoSequence));
      packet.set([1, 1, 0, 0, 0, 0, 0, 1, 2], 16);
      receive(packet, timestamp);
    }
  }
  session.channel = {
    async open(selection, onPacket, onError) { receive = onPacket; errors.push(onError); },
    async send(packet) {
      sent.push(new Uint8Array(packet));
      if (packet[6] === 0) {
        const reply = new Uint8Array(15);
        reply.set(buildOuterHeader(session.sessionId(), 0, 15).slice(0, 8));
        reply.set([1, 15, 0, 5, 5, 64, 31], 8); receive(reply, Date.now());
      }
      for (const bytes of allDumlMessages(packet)) {
        const frame = decodeDumlFrame(bytes);
        if (frame.flags !== 0x40) continue;
        if (frame.commandSet === 3 && frame.commandId === 0x34) {
          deviceQueries++;
          const respond = () => downlink([encodeDumlFrame(3, 2, frame.sequence, 0x80, 3, 0x34,
            new Uint8Array([0]))]);
          if (replyDelay) timers.push(setTimeout(respond, replyDelay)); else respond();
        } else if (frame.commandSet === 0 && frame.commandId === 1 && frame.receiver === 0x1f) {
          downlink([encodeDumlFrame(0x1f, 2, frame.sequence, 0x80, 0, 1, new Uint8Array([0]))]);
        }
      }
    },
    async close() {}, receivedCount: () => 1, sentCount: () => sent.length,
    lastPeer: () => '192.168.2.1:9003'
  };
  return {
    session, telemetry, downlink, errors, deviceQueries: () => deviceQueries,
    async connect() {
      const result = await session.connect({ id: 'readiness', directory: '/readiness',
        registration: builtInRegistrationProfile() },
      { localAddress: '192.168.2.2', interfaceName: 'wlan0', handle: {} });
      if (result.ok) {
        clearInterval(session.tickTimer); session.tickTimer = undefined;
        session.shortPhaseUntil = 0;
        for (const kind of ['flight', 'task', 'camera', 'video']) {
          if (kind !== missing) telemetry(kind, kind === stale ? Date.now() - 2000 : Date.now());
        }
      }
      return result;
    },
    async close() { for (const timer of timers) clearTimeout(timer); await session.disconnect(); }
  };
}

test('session readiness: verification plus video alone cannot initialize without each telemetry stream', async () => {
  for (const missing of ['flight', 'task', 'camera', 'video']) {
    const f = fixture({ missing });
    try {
      assert.equal((await f.connect()).ok, true);
      const result = await f.session.initialize(120);
      assert.equal(result.ok, false, `missing ${missing} must prevent ready`);
      assert.equal(f.session.snapshot().phase, 'registering');
      assert.match(result.error.message, new RegExp({
        flight: '飞行状态', task: '任务状态', camera: '相机状态', video: '图传数据'
      }[missing]));
    } finally { await f.close(); }
  }
});

test('session readiness: stale telemetry and video cannot authorize a ready session', async () => {
  for (const stale of ['flight', 'task', 'camera', 'video']) {
    const f = fixture({ stale });
    try {
      await f.connect();
      assert.equal((await f.session.initialize(120)).ok, false, `${stale} must be fresh`);
    } finally { await f.close(); }
  }
});

test('session readiness: a decoded preview is required when the caller supplies its readiness check', async () => {
  const f = fixture();
  try {
    await f.connect();
    const result = await f.session.initialize(120, () => false);
    assert.equal(result.ok, false);
    assert.match(result.error.message, /实时画面/);
  } finally { await f.close(); }
});

test('session readiness: initialization waits for delayed telemetry and preview before becoming ready', async () => {
  const f = fixture({ missing: 'camera' });
  let previewReady = false;
  try {
    await f.connect();
    const timer = setTimeout(() => { f.telemetry('camera'); previewReady = true; }, 70);
    try {
      const result = await f.session.initialize(400, () => previewReady);
      assert.equal(result.ok, true);
      assert.equal(previewReady, true, 'missing startup evidence must be awaited');
      assert.equal(f.session.isStartupReady(), true);
    } finally { clearTimeout(timer); }
  } finally { await f.close(); }
});

test('session readiness: reinitialization queries the device again and revokes ready on failure', async () => {
  const f = fixture();
  try {
    await f.connect();
    assert.equal((await f.session.initialize(250)).ok, true);
    const queries = f.deviceQueries();
    const result = await f.session.initialize(120, () => false);
    assert.equal(result.ok, false);
    assert.equal(f.session.snapshot().phase, 'registering');
    assert.ok(f.deviceQueries() > queries, 'old device verification cannot authorize reinitialization');
  } finally { await f.close(); }
});

test('session readiness: video traffic cannot keep an expired control downlink fresh', async () => {
  const f = fixture();
  try {
    await f.connect();
    assert.equal((await f.session.initialize(250)).ok, true);
    const old = Date.now() - 2000;
    f.downlink([], old);
    for (const kind of ['flight', 'task', 'camera']) f.telemetry(kind, old);
    // Keep the telemetry timestamps current without observing another control packet.
    // This isolates control freshness from the independently observed sensor streams.
    const store = f.session.telemetry;
    for (const kind of ['flight', 'task', 'camera']) store[kind].observedAtMs = Date.now();
    f.telemetry('video');
    assert.equal(f.session.isStartupReady(), false);
    assert.ok(f.session.snapshot().controlDownlinkAgeMs >= 2000);
  } finally { await f.close(); }
});

test('session readiness: a failed or replaced session cannot be marked ready by an earlier device reply', async () => {
  for (const change of ['failed', 'closing', 'disconnected', 'generation', 'session']) {
    const f = fixture({ replyDelay: 50 });
    try {
      await f.connect();
      const pending = f.session.initialize(250);
      const timer = setTimeout(() => {
        if (change === 'generation') f.session.generation++;
        else if (change === 'session') f.session.session++;
        else f.session.phaseValue = change;
      }, 10);
      try {
        assert.equal((await pending).ok, false, `stale reply after ${change} must not initialize`);
        assert.notEqual(f.session.snapshot().phase, 'ready');
      } finally { clearTimeout(timer); }
    } finally { await f.close(); }
  }
});

test('session readiness: reconnecting a failed session releases the old routing reservation owner', async () => {
  const f = fixture();
  try {
    assert.equal((await f.connect()).ok, true);
    f.errors[0]('simulated UDP failure');
    assert.equal((await f.connect()).ok, true, 'failed sessions must release routing before replacing it');
    f.errors[0]('obsolete socket callback');
    assert.equal(f.session.snapshot().phase, 'registering', 'old socket errors cannot fail the new session');
  } finally { await f.close(); }
});

test('session readiness: an old tick rejection cannot fail a newly connected session', async () => {
  const f = fixture();
  let rejectSend;
  try {
    // Run the actual scheduled tick, including its asynchronous failure handler.
    let scheduledTick;
    const originalSetInterval = global.setInterval;
    global.setInterval = callback => { scheduledTick = callback; return originalSetInterval(() => {}, 10000); };
    try {
      await f.connect();
    } finally { global.setInterval = originalSetInterval; }
    const send = f.session.channel.send;
    f.session.channel.send = async packet => {
      f.session.channel.send = send;
      await new Promise((resolve, reject) => { rejectSend = reject; });
    };
    scheduledTick();
    assert.equal(typeof rejectSend, 'function');
    f.errors.at(-1)('replace the current failed socket');
    assert.equal((await f.connect()).ok, true);
    rejectSend(new Error('late old socket rejection'));
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.session.snapshot().phase, 'registering');
  } finally {
    if (rejectSend) rejectSend(new Error('fixture cleanup'));
    await f.close();
  }
});

test('session readiness: concurrent reconnects cannot both replace a failed session', async () => {
  const f = fixture();
  let finishClose;
  try {
    await f.connect(); f.errors[0]('simulated UDP failure');
    f.session.channel.close = () => new Promise(resolve => { finishClose = resolve; });
    const reconnect = f.connect();
    assert.equal(typeof finishClose, 'function', 'reconnect must close its failed predecessor');
    const duplicate = f.session.connect({ id: 'readiness', directory: '/readiness',
      registration: builtInRegistrationProfile() },
    { localAddress: '192.168.2.2', interfaceName: 'wlan0', handle: {} });
    // Release either cleanup to avoid leaving resources pending if the guard regresses.
    finishClose();
    const result = await Promise.race([duplicate,
      new Promise(resolve => setTimeout(() => resolve({ ok: true }), 50))]);
    assert.equal(result.ok, false, 'a reconnect in progress owns the session before its first await');
    assert.equal(result.error.code, 'SESSION_ACTIVE');
    assert.equal((await reconnect).ok, true);
  } finally {
    if (finishClose) finishClose();
    f.session.channel.close = async () => {};
    await f.close();
  }
});

test('session readiness: a cancelled socket open cannot initialize or close a later connection', async () => {
  const f = fixture();
  let finishOpen;
  try {
    const open = f.session.channel.open;
    f.session.channel.open = async (...args) => {
      f.session.channel.open = open;
      await new Promise(resolve => { finishOpen = resolve; });
      await open(...args);
    };
    const oldConnection = f.connect();
    assert.equal(typeof finishOpen, 'function');
    await f.session.disconnect();
    assert.equal((await f.connect()).ok, true);
    finishOpen();
    assert.equal((await oldConnection).ok, false, 'a completed old socket open must not revive its cancelled connection');
    assert.equal(f.session.snapshot().phase, 'registering', 'a cancelled connect must preserve its replacement');
  } finally { if (finishOpen) finishOpen(); await f.close(); }
});

test('session readiness: a matched handshake send resolving or rejecting after cancellation preserves its replacement', async () => {
  for (const reject of [false, true]) {
    const f = fixture();
    let finishSend;
    let held = false;
    try {
      const send = f.session.channel.send;
      f.session.channel.send = async packet => {
        await send(packet);
        if (packet[6] === 0 && !held) {
          held = true;
          await new Promise((resolve, fail) => { finishSend = () => reject ? fail(new Error('old send failed')) : resolve(); });
        }
      };
      const oldConnection = f.connect();
      await new Promise(resolve => setImmediate(resolve));
      assert.equal(f.session.handshakeMatched, true);
      await f.session.disconnect();
      assert.equal((await f.connect()).ok, true);
      const replacement = f.session.sessionId();
      finishSend();
      assert.equal((await oldConnection).ok, false);
      assert.equal(f.session.sessionId(), replacement);
      assert.equal(f.session.snapshot().phase, 'registering');
      assert.equal(f.session.snapshot().routing.persistent, true, 'an old error cannot close the new routing owner');
    } finally { if (finishSend) finishSend(); await f.close(); }
  }
});

test('session readiness: replies and the initialization deadline complete before a stuck UDP send callback', async () => {
  for (const receivedReply of [false, true]) {
    const f = fixture();
    let rejectSend;
    let watchdog;
    try {
      await f.connect();
      const reusedSequence = (f.session.innerSequence + 1) & 0xffff;
      const send = f.session.channel.send;
      f.session.channel.send = async packet => {
        f.session.channel.send = send;
        if (receivedReply) await send(packet);
        await new Promise((resolve, reject) => { rejectSend = reject; });
      };
      const initializing = f.session.initialize(150);
      const result = await Promise.race([initializing, new Promise(resolve => {
        watchdog = setTimeout(() => resolve({ ok: 'hung' }), 500);
      })]);
      assert.equal(result.ok, receivedReply, 'response or bounded timeout must finish even if send never settles');
      if (!receivedReply) assert.equal(result.error.code, 'INITIALIZATION_TIMEOUT');
      clearTimeout(watchdog);

      await f.session.disconnect();
      assert.equal((await f.connect()).ok, true);
      // Reuse the sequence in a new session: a late rejection from the old send
      // must not delete or resolve this new command's pending response.
      f.session.innerSequence = reusedSequence;
      f.session.channel.send = async () => {};
      const replacementReply = f.session.requestNative(3, 3, 0x34, new Uint8Array(0), 400);
      rejectSend(new Error('late failure from replaced socket'));
      await new Promise(resolve => setImmediate(resolve));
      assert.equal(f.session.pending.has(reusedSequence), true);
      f.downlink([encodeDumlFrame(3, 2, reusedSequence, 0x80, 3, 0x34, new Uint8Array([0]))]);
      assert.deepEqual(await replacementReply, new Uint8Array([0]));
      assert.equal(f.session.snapshot().phase, 'registering');
    } finally {
      clearTimeout(watchdog);
      if (rejectSend) rejectSend(new Error('fixture cleanup'));
      await f.close();
    }
  }
});

test('session readiness: a delayed earlier disconnect cannot clear a replacement after a second disconnect', async () => {
  const f = fixture();
  let finishClose;
  let closes = 0;
  try {
    await f.connect();
    f.session.channel.close = async () => {
      if (++closes === 1) await new Promise(resolve => { finishClose = resolve; });
    };
    const firstDisconnect = f.session.disconnect();
    await f.session.disconnect();
    assert.equal((await f.connect()).ok, true);
    const replacement = f.session.sessionId();
    finishClose();
    await firstDisconnect;
    assert.equal(f.session.sessionId(), replacement);
    assert.equal(f.session.snapshot().phase, 'registering');
    assert.equal(f.session.snapshot().routing.persistent, true);
  } finally { if (finishClose) finishClose(); await f.close(); }
});
