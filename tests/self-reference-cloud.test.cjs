const { test } = require('node:test');
const assert = require('node:assert/strict');

const reference = 'data:image/jpeg;base64,/9j/2Q==';

async function withClient(provider, run) {
  const previous = global.__neoKits, requests = [];
  global.__neoKits = { ...previous,
    '@kit.ArkTS': { util: {
      TextDecoder: { create: () => ({ decodeToString: bytes => new TextDecoder().decode(bytes) }) },
      Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } }
    } },
    '@kit.NetworkKit': { connection: { NetCap: { NET_CAPABILITY_INTERNET: 12 },
      getDefaultNet: async () => ({ netId: 100 }), getNetCapabilities: async () => ({ networkCap: [12] }),
      getConnectionProperties: async () => ({ interfaceName: 'test0', linkAddresses: [] })
    } },
    '@kit.RemoteCommunicationKit': { rcp: {
      Request: class { constructor(url, method, headers, content, cookies, range, configuration) {
        Object.assign(this, { url, method, headers, content, configuration });
      } },
      createSession: () => ({ close() {}, cancel() {}, fetch: async request => {
        requests.push(request);
        const bytes = new TextEncoder().encode(JSON.stringify({ choices: [
          { finish_reason: 'stop', message: { content: '{"action":"none"}' } }
        ] }));
        request.destination(bytes.buffer); return { statusCode: 200 };
      } })
    } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } }
  };
  const modulePath = require.resolve('../entry/src/main/ets/core/platform/CloudVlmClient.ets');
  delete require.cache[modulePath];
  try {
    const { CloudVlmClient } = require(modulePath);
    const client = new CloudVlmClient({ read: async () => 'fake-test-key' }, provider);
    try { await run(client, requests); } finally { client.close(); }
  } finally { global.__neoKits = previous; delete require.cache[modulePath]; }
}

function observation(purpose = 'subject_selection', withFrame = true) {
  return { requestId: 'reference-test', sessionId: 10, flightGeneration: 2,
    requestedAtMs: Date.now(), context: { airborne: true }, purpose,
    ...(withFrame ? { frame: { jpeg: new Uint8Array([255, 216, 1, 255, 217]).buffer,
      candidates: [{ id: 11, left: 0.1, top: 0.1, width: 0.2, height: 0.5 }] } } : {}) };
}

test('phone cloud adds the synthetic reference only for fresh framed self subject selection', async () => {
  let reads = 0;
  await withClient({ read: async () => { reads++; return reference; } }, async (client, requests) => {
    await client.request(observation(), '给我拍照', () => true);
    assert.equal(reads, 1);
    const images = JSON.parse(requests[0].content).messages[1].content.filter(part => part.type === 'image_url');
    assert.equal(images.length, 2);
    assert.ok(images.some(part => part.image_url.url === reference));
    assert.ok(images.some(part => part.image_url.url === 'data:image/jpeg;base64,/9gB/9k='));
    for (const [sample, text] of [
      [observation(), '帮我给白衣男生拍照'], [observation('shoot_intent'), '拍我'],
      [observation('shoot_intent', false), '拍我'], [observation(), '拍红衣女生']
    ]) {
      await client.request(sample, text, () => true);
      assert.equal(reads, 1, text);
      const parts = JSON.parse(requests.at(-1).content).messages[1].content;
      assert.equal(parts.filter(part => part.type === 'image_url').length, sample.frame ? 1 : 0);
      assert.ok(!parts.some(part => part.image_url?.url === reference));
    }
    const count = requests.length;
    await assert.rejects(client.request(observation('subject_selection', false), '拍我', () => true), /画面|取帧/);
    assert.equal(reads, 1); assert.equal(requests.length, count);
    await client.testConnection(); assert.equal(reads, 1);
  });
});

test('phone cloud fails clearly without HTTP when a required reference is missing or cannot load', async () => {
  for (const provider of [undefined, { read: async () => undefined },
    { read: async () => { throw new Error('synthetic missing image'); } }]) {
    await withClient(provider, async (client, requests) => {
      await assert.rejects(client.request(observation(), '跟随我', () => true), /参考照片/);
      assert.equal(requests.length, 0);
      await client.request(observation(), '拍红衣女生', () => true);
      assert.equal(requests.length, 1);
    });
  }
});

test('phone cloud rejects cancellation and expiry after slow reference loading without HTTP', async () => {
  for (const mode of ['cancelled', 'expired']) {
    let release, current = true;
    const wait = new Promise(resolve => { release = resolve; });
    await withClient({ read: async () => { await wait; return reference; } }, async (client, requests) => {
      const sample = observation();
      const pending = client.request(sample, '围着我拍', () => current);
      await new Promise(resolve => setImmediate(resolve));
      if (mode === 'cancelled') current = false;
      const now = Date.now;
      try {
        if (mode === 'expired') Date.now = () => sample.requestedAtMs + 20001;
        release();
        await assert.rejects(pending, mode === 'cancelled' ? /取消|变化/ : /过期|超时/);
        assert.equal(requests.length, 0);
      } finally { Date.now = now; current = true; }
      await client.request(observation(), '拍照', () => true);
      assert.equal(requests.length, 1);
    });
  }
});
