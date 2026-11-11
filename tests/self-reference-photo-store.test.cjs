const { test } = require('node:test');
const assert = require('node:assert/strict');

// Synthetic JPEG markers only. ImageKit/resource boundaries are simulated; no portrait is read.
const jpeg = new Uint8Array([255, 216, 255, 217]);

async function withStore(options, run) {
  const previous = global.__neoKits;
  const state = { reads: 0, sources: 0, decodes: [], transforms: [], packs: [], releases: [] };
  let size;
  const pixels = {
    getImageInfo: async () => ({ size: options.decodedSize || size }),
    flip: async (horizontal, vertical) => {
      state.transforms.push(['flip', horizontal, vertical]);
      if (options.fail === 'flip') throw new Error('synthetic transform failure');
    },
    rotate: async angle => {
      state.transforms.push(['rotate', angle]);
      if (angle === 90 || angle === 270) size = { width: size.height, height: size.width };
      if (options.fail === 'rotate') throw new Error('synthetic transform failure');
    },
    release: async () => { state.releases.push('pixels'); if (options.releaseFails) throw new Error('release'); }
  };
  global.__neoKits = { ...previous,
    '@kit.ArkTS': { util: { Base64Helper: class {
      encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
    } } },
    '@kit.ImageKit': { image: {
      PropertyKey: { ORIENTATION: 'Orientation' },
      createImageSource: buffer => {
        state.sources++;
        assert.deepEqual(new Uint8Array(buffer), options.raw || jpeg);
        return {
          getImageInfo: async () => {
            if (options.fail === 'info') throw new Error('synthetic decode failure');
            return { size: options.sourceSize || { width: 3120, height: 4160 } };
          },
          getImageProperty: async (key, properties) => {
            assert.equal(key, 'Orientation');
            assert.equal(properties.defaultValue, 'Top-left');
            return options.orientation || 'Top-left';
          },
          createPixelMap: async config => {
            state.decodes.push(config); size = { ...config.desiredSize };
            if (options.fail === 'decode') throw new Error('synthetic decode failure');
            return pixels;
          },
          release: async () => { state.releases.push('source'); }
        };
      },
      createImagePacker: () => ({
        packToData: async (input, config) => {
          assert.equal(input, pixels); state.packs.push(config);
          if (options.fail === 'pack') throw new Error('synthetic encoding failure');
          return (options.output || jpeg).buffer;
        },
        release: async () => { state.releases.push('packer'); if (options.releaseFails) throw new Error('release'); }
      })
    } }
  };
  const modulePath = require.resolve('../entry/src/main/ets/core/platform/SelfReferencePhotoStore.ets');
  delete require.cache[modulePath];
  try {
    const { SelfReferencePhotoStore } = require(modulePath);
    const context = { resourceManager: { getRawFileContent: async path => {
      state.reads++; assert.equal(path, 'demo-self-reference.jpg');
      if (options.fail === 'raw') throw new Error('synthetic missing resource');
      if (options.wait) await options.wait;
      return options.raw || jpeg;
    } } };
    await run(new SelfReferencePhotoStore(context), state, options);
  } finally { global.__neoKits = previous; delete require.cache[modulePath]; }
}

test('reference photo loads lazily, bounds JPEG dimensions and caches a shared successful normalization', async () => {
  let release; const wait = new Promise(resolve => { release = resolve; });
  await withStore({ wait }, async (store, state) => {
    assert.equal(state.reads, 0);
    const first = store.read(), second = store.read();
    assert.equal(first, second);
    release();
    assert.equal(await first, 'data:image/jpeg;base64,/9j/2Q==');
    assert.equal(await second, 'data:image/jpeg;base64,/9j/2Q==');
    assert.equal(await store.read(), 'data:image/jpeg;base64,/9j/2Q==');
    assert.equal(state.reads, 1); assert.equal(state.sources, 1);
    assert.deepEqual(state.decodes[0].desiredSize, { width: 768, height: 1024 });
    assert.equal(state.decodes[0].editable, true);
    assert.deepEqual(state.packs, [{ format: 'image/jpeg', quality: 82, needsPackProperties: false }]);
    assert.deepEqual(state.releases, ['packer', 'pixels', 'source']);
  });
});

test('reference photo does not enlarge small images and applies every EXIF orientation before JPEG packing', async () => {
  const cases = [
    ['Top-left', []], ['Top-right', [['flip', true, false]]],
    ['Bottom-right', [['rotate', 180]]], ['Bottom-left', [['flip', false, true]]],
    ['Left-top', [['flip', true, false], ['rotate', 270]]],
    ['Right-top', [['rotate', 90]]],
    ['Right-bottom', [['flip', true, false], ['rotate', 90]]],
    ['Left-bottom', [['rotate', 270]]]
  ];
  for (const [orientation, expected] of cases) {
    await withStore({ orientation, sourceSize: { width: 320, height: 240 } }, async (store, state) => {
      assert.equal(await store.read(), 'data:image/jpeg;base64,/9j/2Q==');
      assert.deepEqual(state.decodes[0].desiredSize, { width: 320, height: 240 });
      assert.deepEqual(state.transforms, expected, orientation);
    });
  }
});

test('reference photo rejects empty, oversized or malformed source bytes before ImageKit decode', async () => {
  for (const raw of [new Uint8Array(), new Uint8Array(8 * 1024 * 1024 + 1), new Uint8Array([1, 2, 3, 4])]) {
    await withStore({ raw }, async (store, state) => {
      await assert.rejects(store.read(), /参考照片/); assert.equal(state.sources, 0);
    });
  }
  const exactLimit = new Uint8Array(8 * 1024 * 1024);
  exactLimit.set([255, 216]); exactLimit.set([255, 217], exactLimit.length - 2);
  await withStore({ raw: exactLimit }, async (store, state) => {
    assert.equal(await store.read(), 'data:image/jpeg;base64,/9j/2Q=='); assert.equal(state.sources, 1);
  });
});

test('reference photo rejects invalid dimensions, orientation and unbounded encoded output, releasing resources', async () => {
  const oversized = new Uint8Array(750001); oversized.set([255, 216]); oversized.set([255, 217], oversized.length - 2);
  const cases = [
    [{ sourceSize: { width: 0, height: 240 } }, ['source']],
    [{ sourceSize: { width: Infinity, height: 240 } }, ['source']],
    [{ orientation: 'Unknown Value 9' }, ['source']],
    [{ decodedSize: { width: 1025, height: 768 } }, ['pixels', 'source']],
    [{ output: oversized }, ['packer', 'pixels', 'source']],
    [{ output: new Uint8Array() }, ['packer', 'pixels', 'source']],
    [{ output: new Uint8Array([1, 2, 3, 4]) }, ['packer', 'pixels', 'source']]
  ];
  for (const [options, released] of cases) {
    await withStore(options, async (store, state) => {
      await assert.rejects(store.read(), /参考照片/); assert.deepEqual(state.releases, released);
    });
  }
  const exactLimit = new Uint8Array(750000);
  exactLimit.set([255, 216]); exactLimit.set([255, 217], exactLimit.length - 2);
  await withStore({ output: exactLimit }, async store => {
    assert.equal(Buffer.from((await store.read()).split(',')[1], 'base64').length, 750000);
  });
});

test('reference photo releases every created image resource on failure and retries failed loads', async () => {
  for (const [fail, released] of [
    ['raw', []], ['info', ['source']], ['decode', ['source']],
    ['flip', ['pixels', 'source']], ['rotate', ['pixels', 'source']],
    ['pack', ['packer', 'pixels', 'source']]
  ]) {
    await withStore({ fail, orientation: fail === 'flip' ? 'Top-right' : 'Right-top' }, async (store, state, options) => {
      await assert.rejects(store.read()); assert.deepEqual(state.releases, released);
      options.fail = undefined;
      assert.equal(await store.read(), 'data:image/jpeg;base64,/9j/2Q=='); assert.equal(state.reads, 2);
    });
  }
  await withStore({ releaseFails: true }, async (store, state) => {
    assert.equal(await store.read(), 'data:image/jpeg;base64,/9j/2Q==');
    assert.deepEqual(state.releases, ['packer', 'pixels', 'source']);
  });
});
