const { test } = require('node:test');
const assert = require('node:assert/strict');
const { CaptureMedia } = require('../entry/src/main/ets/core/media/CaptureMedia.ets');
const { CancellationToken } = require('../entry/src/main/ets/core/domain/OperationResult.ets');

function setup() {
  let now = 1000, sessionId = 10, queries = 0;
  let entries = [{ path: 'old.JPG', kind: 'photo', size: 100 }];
  let recording = false;
  const downloads = [];
  const session = {
    sessionId: () => sessionId, isReliableLinkFresh: () => true,
    snapshot: () => ({ telemetry: {
      cameraAgeMs: 0, camera: { observedAtMs: now, recordingCandidate: recording },
      taskAgeMs: 0, task: { phaseRaw: 0, modeRaw: 0 }
    } })
  };
  const repo = {
    listMedia: async () => { queries++; return { ok: true, data: entries.slice() }; },
    downloadEntry: async entry => {
      downloads.push(entry.path); return { ok: true, data: { path: '/download/' + entry.path } };
    }
  };
  const capture = new CaptureMedia(session, repo, '/download', () => now, async ms => { now += ms; });
  return { capture, repo, downloads, session, setEntries: value => { entries = value; },
    setSession: value => { sessionId = value; }, setRecording: value => { recording = value; },
    advance: ms => { now += ms; }, queries: () => queries };
}

test('photo retrieval waits for a new stable original and ignores the old file', async () => {
  const f = setup();
  await f.capture.begin('photo', new CancellationToken(1));
  f.capture.markReady('photo');
  let reads = 0;
  f.repo.listMedia = async () => {
    reads++;
    return { ok: true, data: reads < 4 ? [{ path: 'old.JPG', kind: 'photo', size: 100 }] :
      [{ path: 'old.JPG', kind: 'photo', size: 100 }, { path: 'new.JPG', kind: 'photo', size: 200 }] };
  };
  const result = await f.capture.retrieveAll('photo', new CancellationToken(1), () => {});
  assert.equal(result[0].path, '/download/new.JPG');
  assert.ok(reads >= 5);
  assert.deepEqual(f.downloads, ['new.JPG']);
  assert.equal(f.capture.hasPending('photo'), false);
});

test('video becomes automatically ready only after an observed recording ends', async () => {
  const f = setup();
  await f.capture.begin('video', new CancellationToken(1));
  f.capture.observe(f.session.snapshot().telemetry, false);
  assert.equal(f.capture.readyKind(), undefined);
  f.setRecording(true); f.capture.observe(f.session.snapshot().telemetry, true);
  assert.equal(f.capture.readyKind(), undefined);
  f.advance(100); f.setRecording(false);
  f.capture.observe(f.session.snapshot().telemetry, true);
  assert.equal(f.capture.readyKind(), undefined);
  f.capture.observe(f.session.snapshot().telemetry, false);
  assert.equal(f.capture.readyKind(), 'video');
});

test('cancelled or cross-session retrieval never downloads or returns an old original', async () => {
  const f = setup();
  const token = new CancellationToken(1);
  await f.capture.begin('photo', token); f.capture.markReady('photo');
  f.setSession(11);
  await assert.rejects(f.capture.retrieveAll('photo', token, () => {}), /会话|取消/);
  assert.deepEqual(f.downloads, []);
  const g = setup(); await g.capture.begin('photo', token); g.capture.markReady('photo');
  token.cancel();
  await assert.rejects(g.capture.retrieveAll('photo', token, () => {}), /取消/);
  assert.deepEqual(g.downloads, []);
});

test('a growing video is not downloaded until its original size settles', async () => {
  const f = setup(); const token = new CancellationToken(1);
  await f.capture.begin('video', token); f.capture.markReady('video');
  let reads = 0;
  f.repo.listMedia = async () => ({ ok: true, data: [
    { path: 'new.MP4', kind: 'video', size: ++reads < 3 ? reads * 100 : 400 }
  ] });
  f.repo.downloadEntry = async entry => {
    assert.equal(entry.size, 400); assert.ok(reads >= 4);
    return { ok: true, data: { path: '/download/new.MP4' } };
  };
  assert.equal((await f.capture.retrieveAll('video', token, () => {}))[0].path, '/download/new.MP4');
});

test('missing or ambiguous new originals fail without substituting a previous file', async () => {
  for (const ambiguous of [false, true]) {
    const f = setup(); const token = new CancellationToken(1);
    await f.capture.begin('photo', token); f.capture.markReady('photo');
    if (ambiguous) f.setEntries([{path:'a.JPG',kind:'photo'}, {path:'b.JPG',kind:'photo'}]);
    await assert.rejects(f.capture.retrieveAll('photo', token, () => {}), /尚未提供|多份新增/);
    assert.deepEqual(f.downloads, []);
    assert.equal(f.capture.hasPending('photo'), true);
    assert.equal(f.capture.readyKind(), undefined);
  }
});

test('one capture returns both new video parts, including a later published part, in file order', async () => {
  const f = setup(); const token = new CancellationToken(1);
  await f.capture.begin('video', token); f.capture.markReady('video');
  let reads = 0;
  f.repo.listMedia = async () => {
    reads++;
    const parts = [{path:'part1.MP4',name:'part1.MP4',fileId:1,kind:'video',size:100}];
    if (reads >= 3) parts.unshift({path:'part2.MP4',name:'part2.MP4',fileId:2,kind:'video',size:200});
    return {ok:true,data:parts};
  };
  const result = await f.capture.retrieveAll('video', token, () => {});
  assert.deepEqual(result.map(item => item.path), ['/download/part1.MP4','/download/part2.MP4']);
  assert.deepEqual(f.downloads, ['part1.MP4','part2.MP4']);
  assert.ok(reads >= 8);
  assert.equal(f.capture.hasPending('video'), false);
});

test('retrying a partly downloaded video group does not redownload its completed part', async () => {
  const f = setup(); const token = new CancellationToken(1);
  await f.capture.begin('video', token); f.capture.markReady('video');
  f.setEntries([{path:'a.MP4',fileId:1,kind:'video',size:100},{path:'b.MP4',fileId:2,kind:'video',size:200}]);
  let fail = true; const attempts = [];
  f.repo.downloadEntry = async entry => {
    attempts.push(entry.path);
    return entry.path === 'b.MP4' && fail ? {ok:false,error:{message:'interrupted'}} :
      {ok:true,data:{path:'/download/'+entry.path}};
  };
  await assert.rejects(f.capture.retrieveAll('video', token, () => {}));
  assert.equal(f.capture.hasPending('video'), true);
  fail = false;
  const result = await f.capture.retrieveAll('video', token, () => {});
  assert.equal(result.length, 2);
  assert.equal(attempts.filter(path => path === 'a.MP4').length, 1);
});

test('a second clip published during the first download is included before returning the group', async () => {
  const f = setup(); const token = new CancellationToken(1);
  await f.capture.begin('video',token);f.capture.markReady('video');
  const a={path:'a.MP4',kind:'video',size:100}, b={path:'b.MP4',kind:'video',size:200};
  f.setEntries([a]);
  f.repo.downloadEntry=async entry=>{
    f.downloads.push(entry.path);f.setEntries([a,b]);
    return {ok:true,data:{path:'/download/'+entry.path}};
  };
  const result=await f.capture.retrieveAll('video',token,()=>{});
  assert.equal(result.length,2);
  assert.deepEqual(f.downloads,['a.MP4','b.MP4']);
});

test('cancelling after the first part prevents downloading or presenting the rest of the group', async () => {
  const f=setup();const token=new CancellationToken(1);
  await f.capture.begin('video',token);f.capture.markReady('video');
  f.setEntries([{path:'a.MP4',kind:'video',size:100},{path:'b.MP4',kind:'video',size:200}]);
  f.repo.downloadEntry=async entry=>{
    f.downloads.push(entry.path);token.cancel();return {ok:true,data:{path:'/download/'+entry.path}};
  };
  await assert.rejects(f.capture.retrieveAll('video',token,()=>{}),/取消/);
  assert.deepEqual(f.downloads,['a.MP4']);
  assert.equal(f.capture.hasPending('video'),true);
});
