const { test } = require('node:test');
const assert = require('node:assert/strict');

const reference = 'data:image/jpeg;base64,/9j/2Q==';
const wrongTask = { action: 'dolly_zoom', zoom: 3, framing: '半身', recipe: 'dolly_circle' };
const selected = { action: 'select_subject', subjectId: 17 };

function observation(now, purpose = 'subject_selection') {
  return { purpose, requestId: 'selection-retry', sessionId: 10, flightGeneration: 2,
    controlGeneration: 0, requestedAtMs: now, context: { phase: 'selecting', airborne: true,
      flightStateFresh: true, tracking: false, taskKind: 'dolly_zoom', taskPrepared: false,
      taskActive: false, cameraIdle: true, recording: false, radiusMeters: 2,
      framing: '半身', zoom: 3, retreat: true, movementSeconds: 0.5 },
    frame: { jpeg: new Uint8Array([255, 216, 1, 255, 217]).buffer,
      candidates: [{ id: 17, left: 0.1, top: 0.1, width: 0.2, height: 0.5 }], currentSubjectId: 17 } };
}

async function withClient(steps, run, options = {}) {
  const previousKits = global.__neoKits, previousNow = Date.now;
  const previousSetInterval = global.setInterval, previousClearInterval = global.clearInterval;
  const requests = [], logs = [], intervals = new Map(), cancellations = [];
  let now = 1000000, timerId = 0, encodings = 0, referenceReads = 0, pendingReject;
  const state = { requests, logs, intervals, cancellations,
    now: () => now, advance: ms => { now += ms; },
    counts: () => ({ encodings, referenceReads }),
    tick: () => { for (const callback of [...intervals.values()]) callback(); } };
  Date.now = () => now;
  global.setInterval = callback => { intervals.set(++timerId, callback); return timerId; };
  global.clearInterval = id => { intervals.delete(id); };
  global.__neoKits = { ...previousKits,
    '@kit.ArkTS': { util: {
      TextDecoder: { create: () => ({ decodeToString: bytes => {
        options.onDecode?.(state); return new TextDecoder().decode(bytes);
      } }) },
      Base64Helper: class { encodeToStringSync(bytes) { encodings++; return Buffer.from(bytes).toString('base64'); } }
    } },
    '@kit.NetworkKit': { connection: { NetCap: { NET_CAPABILITY_INTERNET: 12 },
      getDefaultNet: async () => ({ netId: 100 }), getNetCapabilities: async () => ({ networkCap: [12] }),
      getConnectionProperties: async () => ({ interfaceName: 'test0', linkAddresses: [] })
    } },
    '@kit.RemoteCommunicationKit': { rcp: {
      Request: class { constructor(url, method, headers, content, cookies, range, configuration) {
        Object.assign(this, { url, method, headers, content, configuration });
      } },
      createSession: () => ({ close() {}, cancel(request) {
        cancellations.push(request); pendingReject?.({ code: 1007900992 });
      }, fetch: async request => {
        requests.push(request);
        assert.equal(intervals.size, 1, 'each attempt owns exactly one watchdog');
        const step = steps[requests.length - 1];
        assert.ok(step, 'unexpected extra HTTP request');
        step.before?.(state);
        if (step.pending) return new Promise((resolve, reject) => { pendingReject = reject; });
        if (step.network) throw { code: 1007900992 };
        const text = JSON.stringify({ choices: [{ finish_reason: 'stop',
          message: { content: step.raw ?? JSON.stringify(step.command ?? selected) } }] });
        const bytes = new TextEncoder().encode(text);
        const split = Math.floor(bytes.length / 2);
        if (step.oversize) request.destination(new ArrayBuffer(65537));
        else {
          request.destination(bytes.slice(0, split).buffer);
          request.destination(bytes.slice(split).buffer);
        }
        step.after?.(state);
        return { statusCode: step.status ?? 200 };
      } })
    } },
    '@kit.PerformanceAnalysisKit': { hilog: {
      info(...args) { logs.push(['info', ...args]); },
      warn(...args) { logs.push(['warn', ...args]); options.onRejectLog?.(state); },
      error(...args) { logs.push(['error', ...args]); }
    } }
  };
  const modulePath = require.resolve('../entry/src/main/ets/core/platform/CloudVlmClient.ets');
  delete require.cache[modulePath];
  try {
    const { CloudVlmClient } = require(modulePath);
    const client = new CloudVlmClient({ read: async () => 'fake-selection-secret' },
      { read: async () => { referenceReads++; return reference; } });
    try { await run(client, state); } finally { client.close(); }
    assert.equal(intervals.size, 0, 'watchdogs must be released after every outcome');
  } finally {
    global.__neoKits = previousKits; Date.now = previousNow;
    global.setInterval = previousSetInterval; global.clearInterval = previousClearInterval;
    delete require.cache[modulePath];
  }
}

test('subject selection retries one wrong task with the same frame and original deadline', async () => {
  await withClient([{ command: wrongTask, after: state => state.advance(7000) }, { command: selected }], async (client, state) => {
    const result = await client.request(observation(state.now()), '起飞给白衣男生拍三倍半身特写视频', () => true);
    assert.deepEqual(result.command, selected);
    assert.equal(state.requests.length, 2);
    const [first, second] = state.requests.map(request => JSON.parse(request.content));
    assert.deepEqual(first.messages[1], second.messages[1], 'retry must preserve candidates, image and target');
    assert.notEqual(first.messages[0].content, second.messages[0].content, 'retry adds the selector-only reminder');
    assert.equal(state.requests[0].configuration.transfer.timeout.transferMs, 20000);
    assert.equal(state.requests[1].configuration.transfer.timeout.transferMs, 13000);
    assert.equal(state.counts().encodings, 1);
  });
});

test('two bad selection responses stop after two attempts and log only safe rejection labels', async () => {
  const untrusted = 'SECRET_RESPONSE_TEXT_fake-selection-secret_data:image/jpeg;base64,/9gB/9k=';
  await withClient([{ command: { ...wrongTask, message: untrusted } }, { command: { action: untrusted, message: untrusted } }], async (client, state) => {
    await assert.rejects(client.request(observation(state.now()), '拍白衣男生', () => true), error => {
      assert.equal(error.constructor.name, 'SubjectSelectionProtocolError'); return true;
    });
    assert.equal(state.requests.length, 2);
    const rejections = state.logs.filter(log => log[0] === 'warn');
    assert.equal(rejections.length, 2);
    for (const [index, log] of rejections.entries()) {
      assert.match(log[3], /phase=.*action=.*attempt=.*reason=/);
      assert.ok(log.includes('subject_selection'));
      assert.ok(log.includes(index + 1));
    }
    assert.ok(rejections[0].includes('dolly_zoom'));
    assert.ok(rejections[1].includes('unknown'));
    const serialized = JSON.stringify(state.logs);
    for (const secret of [untrusted, 'SECRET_RESPONSE_TEXT', 'fake-selection-secret', 'data:image/jpeg;base64', '/9gB/9k=']) {
      assert.ok(!serialized.includes(secret), `must not log ${secret}`);
    }
  });
});

test('a valid none is returned after one selection request', async () => {
  await withClient([{ command: { action: 'none', message: '请明确要选哪位' } }], async (client, state) => {
    const result = await client.request(observation(state.now()), '拍白衣男生', () => true);
    assert.deepEqual(result.command, { action: 'none', message: '请明确要选哪位' });
    assert.equal(state.requests.length, 1);
  });
});

test('cancellation or expiry between selection attempts prevents the second HTTP request', async () => {
  for (const mode of ['cancelled', 'expired']) {
    let current = true;
    await withClient([{ command: wrongTask }], async (client, state) => {
      await assert.rejects(client.request(observation(state.now()), '拍白衣男生', () => current),
        mode === 'cancelled' ? /取消|变化/ : /过期|超时/);
      assert.equal(state.requests.length, 1);
    }, { onRejectLog: state => { if (mode === 'cancelled') current = false; else state.advance(20001); } });
  }
});

test('a selection transport failure, HTTP rejection or oversized response never retries', async () => {
  for (const step of [{ status: 401 }, { status: 403 }, { status: 429 }, { status: 302 }, { status: 500 },
    { network: true }, { oversize: true }]) {
    await withClient([{ command: wrongTask, ...step }], async (client, state) => {
      await assert.rejects(client.request(observation(state.now()), '拍白衣男生', () => true));
      assert.equal(state.requests.length, 1);
      assert.equal(state.logs.filter(log => log[0] === 'warn').length, 0);
    });
  }
});

test('selection retry reads a self reference once and preserves both images', async () => {
  await withClient([{ command: wrongTask }, { command: selected }], async (client, state) => {
    assert.deepEqual((await client.request(observation(state.now()), '给我拍特写视频', () => true)).command, selected);
    assert.deepEqual(state.counts(), { encodings: 1, referenceReads: 1 });
    assert.equal(state.requests.length, 2);
    for (const request of state.requests) {
      const images = JSON.parse(request.content).messages[1].content.filter(part => part.type === 'image_url');
      assert.deepEqual(images.map(part => part.image_url.url), [reference, 'data:image/jpeg;base64,/9gB/9k=']);
    }
    assert.deepEqual(JSON.parse(state.requests[0].content).messages[1], JSON.parse(state.requests[1].content).messages[1]);
  });
});

test('ordinary requests retain one attempt for valid actions and invalid JSON', async () => {
  for (const [step, succeeds] of [[{ command: { action: 'photo' } }, true], [{ raw: 'not JSON' }, false]]) {
    await withClient([step], async (client, state) => {
      const sample = observation(state.now(), 'shoot_intent');
      const pending = client.request(sample, '拍照', () => true);
      if (succeeds) assert.equal((await pending).command.action, 'photo');
      else await assert.rejects(pending);
      assert.equal(state.requests.length, 1);
    });
  }
});

test('a retry retains busy ownership and cancellation targets its own request and watchdog', async () => {
  let current = true;
  await withClient([{ command: wrongTask }, { pending: true }], async (client, state) => {
    const sample = observation(state.now());
    const pending = client.request(sample, '拍白衣男生', () => current);
    const outcome = pending.then(result => ({ result }), error => ({ error }));
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(state.requests.length, 2);
    await assert.rejects(client.request(sample, '拍照', () => true), /处理中/);
    current = false; client.cancelPending(); state.tick();
    const settled = await outcome;
    assert.match(settled.error?.message ?? '', /取消|变化/);
    assert.ok(state.cancellations.length >= 1);
    assert.ok(state.cancellations.every(request => request === state.requests[1]));
  });
});

test('cancellation or expiry during response decoding cannot return a selection', async () => {
  for (const mode of ['cancelled', 'expired']) {
    let current = true;
    await withClient([{ command: selected }], async (client, state) => {
      await assert.rejects(client.request(observation(state.now()), '拍白衣男生', () => current),
        mode === 'cancelled' ? /取消|变化/ : /过期|超时/);
      assert.equal(state.requests.length, 1);
    }, { onDecode: state => { if (mode === 'cancelled') current = false; else state.advance(20001); } });
  }
});
