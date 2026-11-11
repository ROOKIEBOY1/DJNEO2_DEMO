const { test } = require('node:test');
const assert = require('node:assert/strict');
const { RegistrationExchange, builtInRegistrationProfile } =
  require('../entry/src/main/ets/core/transport/RegistrationExchange.ets');
const { allDumlMessages } = require('../entry/src/main/ets/core/protocol/CommandCodec.ets');
const { encodeDumlFrame, decodeDumlFrame, validDumlFrames } =
  require('../entry/src/main/ets/core/protocol/DumlCodec.ets');

// Original phone log, 2026-11-10 16:19:54.143: 12AD repeatedly sends this request.
const observedPacket = Buffer.from(
  '8380664c00000128f85af85a00000000f85af85a00000000685b685b000000006100' +
  '5561042427ee3006005101553e044be9ee00004051080000243135383146413651433236384e3031434c394754' +
  '04020037303038454533442d353939372d343039372d000504047dca', 'hex');
const observedRequest = allDumlMessages(observedPacket).find(frame => frame[9] === 0x51 && frame[10] === 8);
const observedPayload = decodeDumlFrame(observedRequest).payload;
const currentIdentity = Buffer.from('0000243135383146413651433236384e3031434c394754', 'hex');
const expectedAck = Buffer.from('0000243135383146413651433236384e3031434c39475400', 'hex');

function innerFrames(packets) {
  return packets.flatMap(packet => {
    const outer = decodeDumlFrame(packet);
    return outer.commandSet === 0x51 && outer.commandId === 1 ?
      validDumlFrames(outer.payload).map(decodeDumlFrame) : [outer];
  });
}

function poll(registration, now) {
  let sequence = 300;
  return innerFrames(registration.poll(now, () => ++sequence, () => ++sequence));
}

function request(commandId, payload, sequence = 123) {
  return encodeDumlFrame(0xe9, 0xee, sequence, 0x40, 0x51, commandId, payload);
}

test('the captured 12AD registration request receives its current identity and request sequence', () => {
  const registration = new RegistrationExchange(1000, builtInRegistrationProfile());
  registration.observe(observedRequest);
  const replies = poll(registration, 999);
  assert.equal(replies.length, 1, 'the observed registration request must receive an acknowledgement');
  assert.equal(replies[0].commandId, 8);
  assert.equal(replies[0].flags, 0xc0);
  assert.equal(replies[0].sequence, 0);
  assert.deepEqual(Buffer.from(replies[0].payload), expectedAck);
  assert.equal(registration.snapshot().unknownRequests, 0);
});

test('scheduled identity registration uses the aircraft learned from the current request', () => {
  const registration = new RegistrationExchange(0, builtInRegistrationProfile());
  registration.observe(observedRequest);
  const identity = poll(registration, 300).find(frame => frame.commandId === 6 && frame.flags === 0x40);
  assert.ok(identity);
  assert.deepEqual(Buffer.from(identity.payload.slice(23, 46)), currentIdentity);
});

test('a startup aircraft heartbeat supplies identity before the scheduled registration', () => {
  const registration = new RegistrationExchange(0, builtInRegistrationProfile());
  const heartbeat = new Uint8Array(55);
  heartbeat[0] = 5;
  heartbeat.set(currentIdentity, 1);
  heartbeat.set([1, 1, 1], 24);
  registration.observe(encodeDumlFrame(0xe9, 0xee, 1, 0, 0x51, 0x13, heartbeat));
  const identity = poll(registration, 300).find(frame => frame.commandId === 6 && frame.flags === 0x40);
  assert.ok(identity);
  assert.deepEqual(Buffer.from(identity.payload.slice(23, 46)), currentIdentity);
});

test('identity registration waits for a current identity instead of replaying the old aircraft', () => {
  const registration = new RegistrationExchange(0, builtInRegistrationProfile());
  assert.equal(poll(registration, 300).some(frame => frame.commandId === 6), false);
  registration.observe(observedRequest);
  const frames = poll(registration, 350);
  const identity = frames.find(frame => frame.commandId === 6 && frame.flags === 0x40);
  assert.ok(identity);
  assert.deepEqual(Buffer.from(identity.payload.slice(23, 46)), currentIdentity);
  assert.equal(poll(registration, 400).some(frame => frame.commandId === 6), false);
});

test('the 51-byte identity request also echoes a new aircraft identity', () => {
  const registration = new RegistrationExchange(1000, builtInRegistrationProfile());
  registration.observe(request(6, Buffer.concat([currentIdentity, Buffer.alloc(28)]), 321));
  const replies = poll(registration, 999);
  assert.equal(replies.length, 1);
  assert.equal(replies[0].commandId, 6);
  assert.equal(replies[0].sequence, 321);
  assert.deepEqual(Buffer.from(replies[0].payload), expectedAck);
});

test('malformed identity requests and a request for another local client remain unanswered', () => {
  const invalid = [Buffer.from(observedPayload.slice(0, -1)), Buffer.from(observedPayload),
    Buffer.from(observedPayload), Buffer.from(observedPayload)];
  invalid[1][2] = 0;
  invalid[2][3] = 0xff;
  invalid[3][26] = 0x58;
  for (const payload of invalid) {
    const registration = new RegistrationExchange(1000, builtInRegistrationProfile());
    registration.observe(request(8, payload));
    assert.deepEqual(poll(registration, 999), []);
    assert.equal(registration.snapshot().unknownRequests, 1);
  }
});

test('one registration exchange never adopts a second aircraft identity', () => {
  const registration = new RegistrationExchange(1000, builtInRegistrationProfile());
  registration.observe(observedRequest);
  poll(registration, 999);
  const other = Buffer.from(currentIdentity);
  other[22] = 0x41;
  registration.observe(request(6, Buffer.concat([other, Buffer.alloc(28)])));
  assert.deepEqual(poll(registration, 999), []);
  assert.equal(registration.snapshot().unknownRequests, 1);
});

test('learning a new aircraft does not change shared templates or the original aircraft registration', () => {
  const profile = builtInRegistrationProfile();
  const original = profile.templates.get('identity').payloadHex;
  const first = new RegistrationExchange(0, profile);
  first.observe(observedRequest);
  poll(first, 300);
  assert.equal(profile.templates.get('identity').payloadHex, original);

  const oldIdentity = Buffer.from('000024313538314641365143323542533031434a474737', 'hex');
  const second = new RegistrationExchange(0, profile);
  second.observe(request(6, Buffer.concat([oldIdentity, Buffer.alloc(28)])));
  const frames = poll(second, 300);
  assert.deepEqual(Buffer.from(frames.find(frame => frame.commandId === 6 && frame.flags === 0xc0).payload),
    Buffer.from('000024313538314641365143323542533031434a47473700', 'hex'));
  assert.deepEqual(Buffer.from(frames.find(frame => frame.commandId === 6 && frame.flags === 0x40).payload.slice(23, 46)), oldIdentity);
});
