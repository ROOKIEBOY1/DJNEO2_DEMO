const { test } = require('node:test');
const assert = require('node:assert/strict');

function withProfileFiles(run) {
  const files = new Map();
  const directories = new Set();
  const handles = new Map();
  let nextFd = 1;
  const previousKits = global.__neoKits;
  const modulePath = require.resolve('../entry/src/main/ets/core/profile/AircraftProfileStore.ets');
  const previousModule = require.cache[modulePath];
  global.__neoKits = { ...previousKits, '@kit.CoreFileKit': { fileIo: {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    accessSync: path => files.has(path) || directories.has(path),
    mkdirSync: path => directories.add(path),
    readTextSync: path => files.get(path),
    openSync(path) { const fd = nextFd++; handles.set(fd, path); files.set(path, ''); return { fd }; },
    writeSync: (fd, text) => files.set(handles.get(fd), text),
    fsyncSync() {},
    closeSync: file => handles.delete(file.fd),
    renameSync(from, to) { files.set(to, files.get(from)); files.delete(from); }
  } } };
  delete require.cache[modulePath];
  try {
    const { AircraftProfileStore } = require(modulePath);
    run({ AircraftProfileStore, files });
  } finally {
    global.__neoKits = previousKits;
    delete require.cache[modulePath];
    if (previousModule) require.cache[modulePath] = previousModule;
  }
}

test('a fresh installation can reopen its unconfigured aircraft and save credentials', () => {
  withProfileFiles(({ AircraftProfileStore }) => {
    const first = new AircraftProfileStore('/profile-startup/files');
    const id = first.selectedId();
    assert.equal(first.selected().configured, false);

    const reopened = new AircraftProfileStore('/profile-startup/files');
    assert.equal(reopened.selectedId(), id);
    assert.equal(reopened.list().length, 1);
    assert.equal(reopened.selected().configured, false);
    reopened.updateCredentials(id, '测试飞机', 'DJI-NEO2-TEST', 'test-password');

    const configured = new AircraftProfileStore('/profile-startup/files');
    assert.equal(configured.selectedId(), id);
    assert.equal(configured.selected().configured, true);
    assert.equal(configured.selected().ssid, 'DJI-NEO2-TEST');
  });
});

test('reopening an existing aircraft preserves its credentials and routing counter', () => {
  withProfileFiles(({ AircraftProfileStore, files }) => {
    const first = new AircraftProfileStore('/profile-startup/files');
    const id = first.selectedId();
    first.updateCredentials(id, '测试飞机', 'DJI-NEO2-TEST', 'test-password');
    const record = JSON.parse(files.get('/profile-startup/files/aircraft-profiles.json')).profiles[0];
    const routingPath = `/profile-startup/files/aircraft/${id}/routing-sequence.json`;
    const routing = JSON.stringify({ version: 1, next_counter: 8192, routing_identity: record.routingIdentity });
    files.set(routingPath, routing);

    const reopened = new AircraftProfileStore('/profile-startup/files');
    assert.equal(reopened.selected().routingReady, true);
    assert.equal(reopened.runtime(id).password, 'test-password');
    assert.equal(reopened.runtime(id).ssid, 'DJI-NEO2-TEST');
    assert.equal(files.get(routingPath), routing);
  });
});

test('an empty SSID with a stored password is not accepted as an unconfigured placeholder', () => {
  withProfileFiles(({ AircraftProfileStore, files }) => {
    new AircraftProfileStore('/profile-startup/files');
    const path = '/profile-startup/files/aircraft-profiles.json';
    const document = JSON.parse(files.get(path));
    document.profiles[0].password = 'test-password';
    files.set(path, JSON.stringify(document));
    assert.throws(() => new AircraftProfileStore('/profile-startup/files'), /Invalid aircraft profile/);
  });
});
