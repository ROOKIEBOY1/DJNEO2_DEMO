const { test } = require('node:test');
const assert = require('node:assert/strict');

let mode = 'fragmented';
let closed = 0;
global.__neoKits = {
  '@kit.ArkTS': { util: {
    TextEncoder: { create: () => ({ encodeInto: text => new TextEncoder().encode(text) }) },
    TextDecoder: { create: () => ({ decodeToString: bytes => new TextDecoder().decode(bytes) }) }
  } },
  '@kit.NetworkKit': { socket: { constructTCPSocketInstance: () => {
    const listeners = {};
    return {
      on: (event, listener) => { listeners[event] = listener; },
      connect: async () => {},
      close: async () => { closed++; },
      send: async ({ data }) => {
        const packet = Buffer.from(data);
        const metadata = JSON.parse(packet.toString('utf8', 8, 8 + packet.readUInt32LE(0)));
        assert.equal(metadata.protocolVersion, 2);
        assert.equal(packet.readUInt32LE(4), 0);
        const payload = Buffer.from(JSON.stringify({
          version: 2, requestId: metadata.requestId, command: { action: 'photo' }
        }));
        const header = Buffer.alloc(4);
        header.writeUInt32LE(mode === 'oversize' ? 9000 : payload.length);
        const reply = Buffer.concat([header, payload]);
        for (const bytes of [reply.subarray(0, 1), reply.subarray(1, 3), reply.subarray(3)]) {
          listeners.message({ message: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) });
        }
      }
    };
  } } }
};
const { requestAgentAction } = require('../entry/src/main/ets/core/platform/VlmUsbExport.ets');

test('agent USB replies handle fragmented headers and bodies and reject oversized messages', async () => {
  const observation = { requestId: 'transport-1', sessionId: 1, context: {}, requestedAtMs: Date.now() };
  const response = await requestAgentAction(observation, '拍照');
  assert.equal(response.command.action, 'photo');
  mode = 'oversize';
  await assert.rejects(requestAgentAction(observation, '拍照'), /传输失败/);
  assert.equal(closed, 2);
});
