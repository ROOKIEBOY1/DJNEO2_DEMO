const { test } = require('node:test');
const assert = require('node:assert/strict');
const calls = [];
let failWrite = false;
global.__neoKits = {
  ...global.__neoKits,
  '@kit.MediaLibraryKit': { photoAccessHelper: {
    getPhotoAccessHelper: () => ({
      applyChanges: async change => {
        calls.push(change);
        if (failWrite) throw new Error('gallery write failed');
      },
      release: async () => { calls.push('released'); }
    }),
    MediaAssetChangeRequest: {
      createImageAssetRequest: (context, uri) => ({ kind: 'photo', uri }),
      createVideoAssetRequest: (context, uri) => ({ kind: 'video', uri })
    }
  } }
};
delete require.cache[require.resolve('../entry/src/main/ets/core/platform/GallerySaver.ets')];
const { GallerySaver } = require('../entry/src/main/ets/core/platform/GallerySaver.ets');

test('gallery save imports photo and video originals through the corresponding media API', async () => {
  const saver = new GallerySaver();
  await saver.save({}, 'file://photo.jpg', 'photo');
  await saver.save({}, 'file://video.mp4', 'video');
  assert.deepEqual(calls, [
    { kind: 'photo', uri: 'file://photo.jpg' }, 'released',
    { kind: 'video', uri: 'file://video.mp4' }, 'released'
  ]);
});

test('gallery failures propagate while releasing the media helper', async () => {
  failWrite = true;
  await assert.rejects(new GallerySaver().save({}, 'file://photo.jpg', 'photo'), /gallery write failed/);
  assert.equal(calls.at(-1), 'released');
});
