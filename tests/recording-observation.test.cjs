const {test}=require('node:test');
const assert=require('node:assert/strict');
const {DroneSession}=require('../entry/src/main/ets/core/domain/DroneSession.ets');
const {NativeTaskService}=require('../entry/src/main/ets/core/domain/NativeTaskService.ets');
const {CameraService}=require('../entry/src/main/ets/core/domain/CameraService.ets');
const {CaptureMedia}=require('../entry/src/main/ets/core/media/CaptureMedia.ets');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {CancellationToken}=require('../entry/src/main/ets/core/domain/OperationResult.ets');
const {encodeDumlFrame}=require('../entry/src/main/ets/core/protocol/DumlCodec.ets');
const {buildOuterHeader}=require('../entry/src/main/ets/core/protocol/OuterCodec.ets');
const {TelemetryStore}=require('../entry/src/main/ets/core/domain/TelemetryStore.ets');

async function withClock(body){
  let now=10000,nextId=1;const timers=new Map();
  const originalNow=Date.now,originalSet=global.setTimeout,originalClear=global.clearTimeout;
  Date.now=()=>now;
  global.setTimeout=(callback,delay)=>{const id=nextId++;timers.set(id,{at:now+delay,callback});return id;};
  global.clearTimeout=id=>timers.delete(id);
  const advance=at=>{
    while(true){
      const next=[...timers].sort((a,b)=>a[1].at-b[1].at).find(([,timer])=>timer.at<=at);
      if(!next)break;now=next[1].at;timers.delete(next[0]);next[1].callback();
    }
    now=at;
  };
  try{return await body({now:()=>now,advance});}
  finally{Date.now=originalNow;global.setTimeout=originalSet;global.clearTimeout=originalClear;}
}

function cameraFrame(recording,sequence=1){
  const payload=new Uint8Array(60);payload[0]=recording?0x84:0x04;payload[4]=1;
  return encodeDumlFrame(1,2,sequence,0,2,0x80,payload);
}
function terminal(sequence=3){
  return encodeDumlFrame(0x92,2,sequence,0,0x23,0x14,Uint8Array.of(0,0,0,1,2));
}
function packet(sessionId,...frames){
  const bytes=new Uint8Array(34+frames.reduce((size,frame)=>size+frame.length,0));
  bytes.set(buildOuterHeader(sessionId,1,bytes.length,1));
  let offset=34;for(const frame of frames){bytes.set(frame,offset);offset+=frame.length;}
  return bytes;
}

async function fixture(clock){
  const session=new DroneSession(),events=[];
  Object.assign(session,{session:7,phaseValue:'ready',deviceVerified:true,lastControlReceivedAt:clock.now(),
    channel:{receivedCount:()=>1,sentCount:()=>0,lastPeer:()=>''}});
  const flight={snapshot:()=>({generation:2,landRequested:false,landSent:false})};
  const media={listMedia:async()=>{events.push('baseline');return {ok:true,data:[]};}};
  const camera=new CameraService(session,media);
  Object.assign(camera,{recordingRequested:true,recordingAttemptAtMs:clock.now()-100});
  const native=new NativeTaskService(session,flight,camera);
  Object.assign(native,{startedAt:clock.now()-100,executionSeen:true,kind:'dolly'});
  const capture=new CaptureMedia(session,media,'/unused',clock.now);
  const sequence=await capture.beginVideoSequence(new CancellationToken(2));
  const c=Object.create(AppController.prototype);
  Object.assign(c,{session,flight,camera,nativeTasks:native,captureMedia:capture,
    videoSessionEnabled:true,latestAgentRequestId:'',acceptedAgentRequestId:'',log(){},
    run(){events.push('download-or-command');throw Error('synchronous observation must not start an operation');},
    retrieveCapture(){events.push('download');throw Error('synchronous observation must not download media');}});
  session.setListener(()=>{c.pollAutomaticMedia().catch(error=>{events.push(error.message);});});
  // The old throttled consumer remains active so RED reproduces the real loss,
  // rather than failing only because the new callback API is not defined yet.
  if(typeof session.setCameraTelemetryListener==='function'){
    session.setCameraTelemetryListener(()=>c.observeShootingTelemetry());
  }
  const feed=(frames,receivedAt=clock.now())=>session.onPacket(packet(session.sessionId(),...frames),receivedAt);
  return {session,c,camera,native,capture,sequence,events,feed};
}

test('camera true then false in one UDP packet preserves native, camera and shared-video recording evidence',async()=>{
  await withClock(async clock=>{
    const f=await fixture(clock);
    f.feed([cameraFrame(true),cameraFrame(false,2),terminal()]);
    assert.equal(f.session.snapshot().telemetry.camera.recordingCandidate,false);
    assert.equal(f.native.snapshot().recordingSeen,true);
    assert.equal(f.capture.video.recordingSeen,true);
    assert.equal(f.camera.recordingObservedAtMs,clock.now());
    assert.equal(f.capture.canContinueVideoSequence(f.sequence),true);
    assert.deepEqual(f.events,['baseline'],'observing telemetry must not download or start another movement');
  });
});

test('recording inside the 250-millisecond UI throttle is observed as reliably as the normal spaced control',async()=>{
  for(const throttled of [true,false]){
    await withClock(async clock=>{
      const f=await fixture(clock);
      if(throttled){f.feed([cameraFrame(false,0)]);clock.advance(10050);}
      f.feed([cameraFrame(true,1)]);
      assert.equal(f.native.snapshot().recordingSeen,true,'save the positive edge synchronously');
      assert.equal(f.capture.video.recordingSeen,true);
      clock.advance(throttled?10100:10300);
      f.feed([cameraFrame(false,2),terminal()]);
      clock.advance(throttled?10250:10300);
      await f.c.pollAutomaticMedia();
      assert.equal(f.native.snapshot().recordingSeen,true);
      assert.equal(f.capture.canContinueVideoSequence(f.sequence),true);
      assert.deepEqual(f.events,['baseline']);
    });
  }
});

test('false-only camera reports and positive reports older than this start cannot invent recording evidence',async()=>{
  for(const oldPositive of [false,true]){
    await withClock(async clock=>{
      const f=await fixture(clock);
      f.feed(oldPositive?[cameraFrame(true),cameraFrame(false,2),terminal()]:
        [cameraFrame(false,2),terminal()],oldPositive?9800:10000);
      await f.c.pollAutomaticMedia();
      assert.equal(f.native.snapshot().recordingSeen,false);
      assert.equal(f.capture.video.recordingSeen,false);
      assert.equal(f.capture.canContinueVideoSequence(f.sequence),false);
      assert.equal(f.camera.recordingObservedAtMs,undefined);
    });
  }
});

test('the next sequence part or reconnected session needs its own positive recording report',async()=>{
  for(const reconnect of [false,true]){
    await withClock(async clock=>{
      const f=await fixture(clock);
      f.feed([cameraFrame(true),cameraFrame(false,2),terminal()]);
      assert.equal(f.capture.canContinueVideoSequence(f.sequence),true);
      clock.advance(10100);
      let sequence=f.sequence;
      if(reconnect){
        f.native.resetForAircraftSession();f.camera.resetForAircraftSession();f.capture.reset();
        f.session.generation++;f.session.telemetry=new TelemetryStore();
        sequence=await f.capture.beginVideoSequence(new CancellationToken(2));
      }else{
        f.native.resetAfterGroundedCycle();
        f.capture.continueVideoSequence(sequence,new CancellationToken(2));
      }
      Object.assign(f.native,{startedAt:clock.now(),executionSeen:true,kind:'circle'});
      clock.advance(10200);f.feed([cameraFrame(false,4),terminal(5)]);
      await f.c.pollAutomaticMedia();
      assert.equal(f.native.snapshot().recordingSeen,false);
      assert.equal(f.capture.video.recordingSeen,false);
      assert.equal(f.capture.canContinueVideoSequence(sequence),false);
      assert.equal(f.events.filter(event=>event==='download-or-command'||event==='download').length,0);
    });
  }
});

test('TelemetryStore returns only the camera report accepted by this exact observe call',()=>{
  const store=new TelemetryStore();
  const positive=store.observe(cameraFrame(true),10000);
  assert.equal(positive.recordingCandidate,true);assert.equal(positive.recordStateRaw,2);
  assert.equal(positive.observedAtMs,10000);
  assert.equal(store.observe(terminal(),10001),undefined,'an unrelated frame cannot replay the previous camera edge');
  const corrupt=cameraFrame(false,2);corrupt[20]^=1;
  assert.equal(store.observe(corrupt,10002),undefined);
  const idle=store.observe(cameraFrame(false,3),10003);
  assert.equal(idle.recordingCandidate,false);assert.equal(idle.observedAtMs,10003);
  assert.equal(positive.recordingCandidate,true,'a later idle report must not mutate the already-returned positive report');
});

function isolatedControllerConstructor(){
  const Module=require('node:module');
  const modulePath=require.resolve('../entry/src/main/ets/core/domain/AppController.ets');
  const previousLoad=Module._load,previousModule=require.cache[modulePath];
  delete require.cache[modulePath];
  Module._load=function(name,parent,main){
    if(name==='../profile/AircraftProfileStore')return {AircraftProfileStore:class {}};
    if(name==='@kit.CoreFileKit')return {fileIo:{accessSync:()=>false}};
    return previousLoad.call(this,name,parent,main);
  };
  try{return require(modulePath).AppController;}
  finally{
    Module._load=previousLoad;delete require.cache[modulePath];
    if(previousModule)require.cache[modulePath]=previousModule;
  }
}

test('the real AppController constructor wires per-report observation independently from its UI listener',async()=>{
  await withClock(async clock=>{
    const IsolatedController=isolatedControllerConstructor();
    const c=new IsolatedController('/unused',{}),session=c.session;
    Object.assign(session,{session:7,phaseValue:'ready',deviceVerified:true,lastControlReceivedAt:clock.now(),
      channel:{receivedCount:()=>1,sentCount:()=>0,lastPeer:()=>''}});
    c.log=()=>{};c.emit=()=>{};c.videoSessionEnabled=true;
    c.media.listMedia=async()=>({ok:true,data:[]});
    const sequence=await c.captureMedia.beginVideoSequence(new CancellationToken(2));
    Object.assign(c.nativeTasks,{startedAt:clock.now()-100,executionSeen:true,kind:'dolly'});
    session.setListener(undefined);
    c.run=()=>{throw Error('the telemetry observer must not start an operation');};
    session.onPacket(packet(7,cameraFrame(true),cameraFrame(false,2),terminal()),clock.now());
    assert.equal(c.nativeTasks.snapshot().recordingSeen,true);
    assert.equal(c.captureMedia.video.recordingSeen,true);
    // A later ordinary poll seals the terminal state; constructor wiring already
    // preserved the positive edge even though the UI never observed that state.
    await c.pollAutomaticMedia();
    assert.equal(c.captureMedia.canContinueVideoSequence(sequence),true);
  });
});
