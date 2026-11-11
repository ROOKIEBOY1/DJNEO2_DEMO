const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const settle=()=>new Promise(resolve=>setImmediate(resolve));

function fixture(){
  const c=Object.create(AppController.prototype),events=[];
  let now=10000, fresh=true, generation=1, videoAgeMs=0;
  const stats={running:true,waitingForKey:true,recoveryPaused:false,assembledFrames:10,
    submittedFrames:0,decodedFrames:0,renderedFrames:0,lastRenderedAgeMs:-1,
    lastAssembledAgeMs:0,acceptedRandomAccessFrames:0,decoderEpoch:1,lastError:''};
  Object.assign(c,{videoSessionEnabled:true,keyframeClock:()=>now,vlmFramePending:false,
    session:{sessionId:()=>7,isReliableLinkFresh:()=>fresh,
      snapshot:()=>({generation,sessionHex:'0x0007',phase:'ready',videoAgeMs}),
      requestVideoKeyframe:async reason=>{events.push('request:'+reason);}},
    video:{snapshot:()=>({state:stats.renderedFrames>0?'live':'waiting_key',stats:{...stats}}),
      restart:()=>{events.push('restart-preview');stats.recoveryPaused=false;stats.running=true;
        stats.acceptedRandomAccessFrames=0;stats.renderedFrames=0;stats.lastRenderedAgeMs=-1;stats.decoderEpoch++;
        return true;}},
    log:message=>events.push(message),emit(){},
    flight:{land(){throw Error('video recovery must not land');}},
    camera:{startRecording(){throw Error('video recovery must not alter camera');}}});
  return {c,events,stats,setNow:value=>{now=value;},setFresh:value=>{fresh=value;},
    setGeneration:value=>{generation=value;},setVideoAge:value=>{videoAgeMs=value;}};
}

test('controller requests a keyframe after the initial wait and confirms actual new key plus rendered output',async()=>{
  const {c,events,stats,setNow}=fixture();
  c.pollVideoKeyframeRecovery(); assert.equal(events.some(value=>value.startsWith('request:')),false);
  setNow(12000); c.pollVideoKeyframeRecovery(); await settle();
  assert.deepEqual(events.filter(value=>value.startsWith('request:')),['request:automatic']);
  assert.notEqual(c.keyframeRecovery.snapshot().state,'recovered');
  stats.acceptedRandomAccessFrames=1;stats.renderedFrames=2;stats.lastRenderedAgeMs=0;
  stats.waitingForKey=false;setNow(12050);c.pollVideoKeyframeRecovery();
  assert.equal(c.keyframeRecovery.snapshot().state,'recovered');
});

test('controller never automatically requests for stale control, silent video or a paused decoder',async()=>{
  for(const mode of ['control','video','paused']){
    const {c,events,stats,setNow,setFresh,setVideoAge}=fixture();
    c.pollVideoKeyframeRecovery();setNow(13000);
    if(mode==='control')setFresh(false);
    if(mode==='video')setVideoAge(1001);
    if(mode==='paused'){stats.running=false;stats.recoveryPaused=true;}
    c.pollVideoKeyframeRecovery();await settle();
    assert.equal(events.some(value=>value.startsWith('request:')),false,mode);
    assert.equal(events.includes('restart-preview'),false,mode);
  }
});

test('manual recovery may reopen a paused local decoder before sending and uses its fresh zero counters',async()=>{
  const {c,events,stats,setNow}=fixture();
  stats.running=false;stats.recoveryPaused=true;stats.acceptedRandomAccessFrames=1;
  stats.renderedFrames=1;stats.lastRenderedAgeMs=9000;
  await c.recoverVideoPreview();
  assert.deepEqual(events.filter(value=>value==='restart-preview'||value.startsWith('request:')),
    ['restart-preview','request:manual']);
  stats.acceptedRandomAccessFrames=1;stats.renderedFrames=3;stats.lastRenderedAgeMs=0;
  stats.waitingForKey=false;setNow(10050);c.pollVideoKeyframeRecovery();
  assert.equal(c.keyframeRecovery.snapshot().state,'recovered');
});

test('manual recovery checks freshness and cooldown before reopening the decoder',async()=>{
  const {c,events,stats,setFresh}=fixture();stats.running=false;stats.recoveryPaused=true;
  setFresh(false);await assert.rejects(c.recoverVideoPreview(),/连接|新鲜|控制/);
  assert.equal(events.includes('restart-preview'),false);
  setFresh(true);await c.recoverVideoPreview();
  stats.running=false;stats.recoveryPaused=true;
  await assert.rejects(c.recoverVideoPreview(),/5|间隔|频繁|稍后/);
  assert.equal(events.filter(value=>value==='restart-preview').length,1);
});

test('manual preview recovery does not interrupt an existing subject frame readback',async()=>{
  const {c,events}=fixture();c.vlmFramePending=true;
  await assert.rejects(c.recoverVideoPreview(),/画面|取帧|取图/);
  assert.equal(events.some(value=>value.startsWith('request:')),false);
  assert.equal(events.includes('restart-preview'),false);
});

test('manual local preview restart failure stays explicit and sends no aircraft request',async()=>{
  const {c,events,stats}=fixture();stats.running=false;stats.recoveryPaused=true;
  c.video.restart=()=>false;
  await assert.rejects(c.recoverVideoPreview(),/预览.*未.*打开|未请求关键帧/);
  assert.equal(events.some(value=>value.startsWith('request:')),false);
  assert.ok(events.some(value=>/画面恢复请求未完成.*未请求关键帧/.test(value)));
});

test('controller gives reconnects distinct recovery contexts even when the aircraft session number repeats',async()=>{
  const {c,events,setNow,setGeneration}=fixture();
  c.pollVideoKeyframeRecovery();setNow(12000);c.pollVideoKeyframeRecovery();await settle();
  setGeneration(2);setNow(12100);c.pollVideoKeyframeRecovery();
  assert.equal(c.keyframeRecovery.snapshot().automaticAttempts,0);
  assert.equal(events.filter(value=>value.startsWith('request:')).length,1);
});
