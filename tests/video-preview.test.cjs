const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const file = require('node:path').resolve(__dirname, '../entry/src/main/ets/core/media/VideoPreview.ets');
test('video preview implementation is available', () => assert.equal(fs.existsSync(file), true));
function setup() {
  const { VideoPreview } = require(file);
  const events = [];
  const stats = { running:true, waitingForKey:true, queued:0, queuedBytes:0, queueDrops:0,
    assembledFrames:0, submittedFrames:0, decodedFrames:0, renderedFrames:0, decodeErrors:0,
    suppressedParameters:0, reorderedFrames:0, width:0,height:0,lastAssembledAgeMs:-1,
    lastDecodedAgeMs:-1,lastRenderedAgeMs:-1,lastError:'' };
  const backend = {start:id=>events.push(`start:${id}`),stop:()=>events.push('stop'),
    submit:data=>events.push(`frame:${data.byteLength}`),snapshot:()=>({...stats})};
  return {video:new VideoPreview(backend),events,stats};
}
test('preview requires both an active session and surface; replacement stops old decoder',()=>{
  const {video,events}=setup();video.attach('123');video.submit(new Uint8Array([1]));
  assert.deepEqual(events,[]);video.setSession('a');assert.deepEqual(events,['start:123']);
  video.setSession('a');assert.equal(events.length,1);video.setSession('b');
  assert.deepEqual(events,['start:123','stop','start:123']);video.detach();
  video.submit(new Uint8Array([2]));assert.equal(events.at(-1),'stop');
});
test('only new render submissions count as live and a stale picture is marked after two seconds',()=>{
  const {video,stats}=setup();video.setSession('a');video.attach('123');
  assert.equal(video.snapshot().state,'waiting_stream');stats.assembledFrames=1;
  assert.equal(video.snapshot().state,'waiting_key');stats.decodedFrames=1;
  assert.notEqual(video.snapshot().state,'live');stats.renderedFrames=1;stats.lastRenderedAgeMs=20;
  assert.equal(video.snapshot().state,'live');stats.lastRenderedAgeMs=2001;
  assert.equal(video.snapshot().state,'stale');video.setSession('');
  assert.equal(video.snapshot().state,'stopped');
});
test('frame submission copies exactly the selected view and native failure stays local to video',()=>{
  const { VideoPreview }=require(file);let received;let stopped=0;
  const video=new VideoPreview({start(){},stop(){stopped++;},submit:data=>{received=data;},snapshot(){throw Error('decoder died');}});
  video.attach('123');video.setSession('a');video.submit(new Uint8Array([9,1,2,9]).subarray(1,3));
  assert.deepEqual([...new Uint8Array(received)],[1,2]);
  assert.equal(video.snapshot().state,'error');video.detach();assert.equal(stopped,1);
});
test('late destruction of an old surface cannot stop its replacement',()=>{
  const {video,events}=setup();video.setSession('a');video.attach('123');video.attach('456');
  const count=events.length;video.detach('123');assert.equal(events.length,count);
  video.submit(new Uint8Array([1]));assert.equal(events.at(-1),'frame:1');video.detach('456');assert.equal(events.at(-1),'stop');
});
test('preview starts before opening the handshake socket so the initial codec parameters are retained',()=>{
  const { videoSessionIdentity }=require(file);
  assert.equal(videoSessionIdentity('handshaking','0x1234'),'0x1234');
  assert.equal(videoSessionIdentity('registering','0x1234'),'0x1234');
  assert.equal(videoSessionIdentity('ready','0x1234'),'0x1234');
  assert.equal(videoSessionIdentity('closing','0x1234'),'');
  assert.equal(videoSessionIdentity('selecting_network','0x1234'),'');
});
