const { test } = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');
const { buildOuterHeader } = require('../entry/src/main/ets/core/protocol/OuterCodec.ets');
const { allDumlMessages } = require('../entry/src/main/ets/core/protocol/CommandCodec.ets');
const { decodeDumlFrame, encodeDumlFrame } = require('../entry/src/main/ets/core/protocol/DumlCodec.ets');
const { builtInRegistrationProfile } = require('../entry/src/main/ets/core/transport/RegistrationExchange.ets');

// Load the real session and routing store with an in-memory replacement for the
// platform file API. The UDP boundary below is the only other replacement.
function sessionClass() {
  const sessionPath = require.resolve('../entry/src/main/ets/core/domain/DroneSession.ets');
  const routingPath = require.resolve('../entry/src/main/ets/core/transport/RoutingSequenceStore.ets');
  const saved = [require.cache[sessionPath], require.cache[routingPath]];
  const originalLoad = Module._load;
  const files = new Map([['/aircraft/routing-sequence.json', JSON.stringify({
    version: 1, next_counter: 159105, routing_identity: '8e338dbb'
  })]]);
  Module._load = function (name, parent, main) {
    if (name === '@kit.CoreFileKit') return { fileIo: {
      OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
      accessSync: path => path === '/aircraft' || files.has(path),
      readTextSync: path => files.get(path),
      openSync: path => ({ fd: path }),
      writeSync: (path, text) => files.set(path, text),
      fsyncSync() {}, closeSync() {},
      renameSync: (from, to) => { files.set(to, files.get(from)); files.delete(from); }
    } };
    return originalLoad.call(this, name, parent, main);
  };
  delete require.cache[sessionPath]; delete require.cache[routingPath];
  try { return require(sessionPath).DroneSession; }
  finally {
    Module._load = originalLoad;
    for (const [index, path] of [sessionPath, routingPath].entries()) {
      if (saved[index]) require.cache[path] = saved[index];
      else delete require.cache[path];
    }
  }
}

function fixture({ beforeMatch = false, duplicateMatch = false } = {}) {
  const DroneSession = sessionClass();
  const session = new DroneSession();
  const sent = [], frames = [];
  let receive, sessionId, lastBurstSequence, deliveredContinuation = false;
  const u16 = (packet, offset) => packet[offset] | packet[offset + 1] << 8;
  const deliver = packet => receive(packet, Date.now());
  function handshake(id) {
    const reply = new Uint8Array(15);
    reply.set(buildOuterHeader(id, 0, 15).slice(0, 8));
    reply.set([1, 15, 0, 5, 5, 64, 31], 8);
    return reply;
  }
  function video(sequence, frame) {
    const packet = new Uint8Array(25);
    packet.set(buildOuterHeader(sessionId, 2, 25, sequence));
    packet.set([frame, 1, 0, 0, 0, 0, 0, 1, 2], 16);
    return packet;
  }
  session.channel = {
    async open(selection, listener) { receive = listener; },
    async send(packet) {
      sent.push(new Uint8Array(packet));
      if (packet[6] === 0) {
        sessionId = u16(packet, 2);
        const seed = u16(packet, 8);
        if (beforeMatch) {
          deliver(video((seed + 512) & 0xffff, 99));
          deliver(handshake(sessionId === 0xffff ? 1 : sessionId + 1));
        }
        deliver(handshake(sessionId));
        deliver(video((seed + 8) & 0xffff, 1));
        lastBurstSequence = (seed + 16) & 0xffff;
        deliver(video(lastBurstSequence, 2));
        // An early registration heartbeat must survive the same handshake burst.
        const state = new Uint8Array(55); state.set([4, 4, 4], 24);
        const message = encodeDumlFrame(0xe9, 0xee, 7, 0, 0x51, 0x13, state);
        const downlink = new Uint8Array(34 + message.length);
        downlink.set(buildOuterHeader(sessionId, 1, downlink.length));
        downlink.set(message, 34); deliver(downlink);
        if (duplicateMatch) deliver(handshake(sessionId));
      } else if (packet[6] === 4 && !deliveredContinuation &&
        u16(packet, 8) === lastBurstSequence && u16(packet, 10) === lastBurstSequence) {
        deliveredContinuation = true;
        deliver(video((lastBurstSequence + 8) & 0xffff, 3));
      }
    },
    async close() {}, receivedCount: () => frames.length,
    sentCount: () => sent.length, lastPeer: () => '192.168.2.1:9003'
  };
  session.setVideoFrameListener(frame => frames.push(frame));
  return { session, sent, frames,
    connect: () => session.connect({ id: 'aircraft', directory: '/aircraft',
      registration: builtInRegistrationProfile() },
    { localAddress: '192.168.2.2', interfaceName: 'wlan0', handle: {} }) };
}

test('the first ACK covers video received immediately after the handshake and releases continued video', async () => {
  const f = fixture();
  try {
    assert.equal((await f.connect()).ok, true);
    assert.equal(f.frames.length, 2);
    await f.session.tick();
    assert.equal(f.frames.length, 3, 'the aircraft must receive an ACK for the complete initial video burst');
    assert.equal(f.session.snapshot().registration.remoteState, '040404');
    const sticks = f.sent.flatMap(allDumlMessages).map(decodeDumlFrame)
      .filter(frame => frame.commandSet === 1 && frame.commandId === 10);
    assert.equal(sticks.length, 1);
    assert.equal(Buffer.from(sticks[0].payload).toString('hex'), '010d00000420000108400002000006550104',
      'the existing two-second short initial stick phase must remain active');
  } finally { await f.session.disconnect(); }
});

test('packets preceding a matching handshake cannot enter the video or transport session', async () => {
  const f = fixture({ beforeMatch: true });
  try {
    assert.equal((await f.connect()).ok, true);
    assert.equal(f.frames.length, 2, 'pre-handshake video is unverified and must be discarded');
    await f.session.tick();
    assert.equal(f.frames.length, 3);
  } finally { await f.session.disconnect(); }
});

test('a duplicate matching handshake does not reset the video acknowledgement or registration', async () => {
  const f = fixture({ duplicateMatch: true });
  try {
    assert.equal((await f.connect()).ok, true);
    assert.equal(f.session.snapshot().registration.remoteState, '040404');
    await f.session.tick();
    assert.equal(f.frames.length, 3);
    assert.equal(f.sent.filter(packet => packet[6] === 4).length, 1);
  } finally { await f.session.disconnect(); }
});
