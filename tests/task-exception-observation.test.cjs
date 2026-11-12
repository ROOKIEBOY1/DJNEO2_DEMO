const {test}=require('node:test');const assert=require('node:assert/strict');
const {TelemetryStore}=require('../entry/src/main/ets/core/domain/TelemetryStore.ets');
const {DroneSession}=require('../entry/src/main/ets/core/domain/DroneSession.ets');
const {NativeTaskService}=require('../entry/src/main/ets/core/domain/NativeTaskService.ets');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {encodeDumlFrame}=require('../entry/src/main/ets/core/protocol/DumlCodec.ets');
const {buildOuterHeader}=require('../entry/src/main/ets/core/protocol/OuterCodec.ets');
const hex=s=>new Uint8Array(Buffer.from(s,'hex'));
const task=(payload,seq=1)=>encodeDumlFrame(0x92,2,seq,0,0x23,0x14,hex(payload));
const exception=(payload='00000000000019000b00',o={})=>encodeDumlFrame(o.sender??0x92,o.receiver??2,o.sequence??4,
  o.flags??0,o.set??10,o.id??0x39,hex(payload));
function packet(...frames){const b=new Uint8Array(34+frames.reduce((n,f)=>n+f.length,0));
  b.set(buildOuterHeader(7,1,b.length,1));let offset=34;for(const f of frames){b.set(f,offset);offset+=f.length;}return b;}
function fixture(){const s=new DroneSession();Object.assign(s,{session:7,phaseValue:'ready',deviceVerified:true,
  channel:{receivedCount:()=>1,sentCount:()=>0,lastPeer:()=>''},emitThrottled(){}});
  const flight={snapshot:()=>({generation:1})};const native=new NativeTaskService(s,flight,{});
  Object.assign(native,{startedAt:10000,kind:'dolly'});return {s,native,flight};}
function withNow(at,body){const saved=Date.now;Date.now=()=>at;try{return body();}finally{Date.now=saved;}}
// Lifecycle tests inject a formally classified report. A raw 0B without the
// prior official navigation gate remains unconfirmed in separate regressions.
function injectClassifiedReportForUiTest(native){
  native.stopEvidence.snapshot=()=>({startedAtMs:10000,terminalAtMs:18000,exceptionAtMs:18000,codeRaw:11,
    classification:'obstacle',reasonKnown:true,diagnosticCode:800013,
    reasonNavAtMs:17950,reasonNavModeRaw:8,reasonMultiQuickShotEnabled:true,
    message:'检测到障碍物，已触发避障',appStopRequested:false,settleUntilMs:18500});
}
function settledFrames(seq=20){
  const camera=new Uint8Array(60);camera[0]=4;camera[4]=1;
  const navigation=hex('ff020000000300000000000000000000000000');
  const flight=new Uint8Array(36);flight[30]=26;flight[32]=12;
  return [task('0400000100',seq),encodeDumlFrame(1,2,seq,0,2,0x80,camera),
    encodeDumlFrame(0x92,2,seq,0,10,0x5a,navigation),encodeDumlFrame(3,2,seq,0,3,0x43,flight)];
}
function confirmedEnding(s,native){
  const navigation=hex('ff020000001100000000000000010000000000');
  s.setTaskTelemetryListener(event=>native.observeTelemetry(event));
  s.onPacket(packet(task('050d000100'),encodeDumlFrame(0x92,2,19,0,10,0x5a,navigation),
    exception(),task('0400000100',2)),Date.now());
  assert.equal(native.snapshot().stopReport.classification,'obstacle');
}

test('public cancel fences a late reason even after the task already became idle',()=>{
  const saved=Date.now;let now=18000;Date.now=()=>now;
  try{const {s,native}=fixture();s.setTaskTelemetryListener(e=>native.observeTelemetry(e));
    s.onPacket(packet(task('050d000100'),task('0400000100',2)),now);native.cancel();
    injectClassifiedReportForUiTest(native);s.onPacket(packet(exception(),...settledFrames()),now);
    assert.equal(native.snapshot().stopNotice,undefined);now=18500;
    s.onPacket(packet(...settledFrames(21)),now);
    assert.equal(native.snapshot().stopNotice,undefined,'a late classification cannot undo explicit cancellation');
  }finally{Date.now=saved;}
});

test('preparing a different kind does not discard the previous pending notice before actual start',()=>{
  const saved=Date.now;let now=18000;Date.now=()=>now;
  try{const {s,native}=fixture();confirmedEnding(s,native);s.onPacket(packet(...settledFrames()),now);
    assert.equal(native.snapshot().stopNotice,undefined);
    native.kind='circle';native.snapshot();now=18500;s.onPacket(packet(...settledFrames(21)),now);
    assert.match(native.snapshot().stopNotice.id,/:dolly:/);
  }finally{Date.now=saved;}
});

test('0A/39 parser strictly preserves the exception event and keeps the camera observe API',()=>{
  const store=new TelemetryStore();assert.equal(typeof store.observeEvent,'function');
  const e=store.observeEvent(exception(),18000).taskException;
  assert.deepEqual(e,{observedAtMs:18000,codeRaw:11,payloadHex:'00000000000019000b00',sequence:4,inAction:false});
  assert.equal(store.snapshot().taskException.codeRaw,11);
  for(const o of [{sender:3},{receiver:3},{flags:0x80},{set:0x23},{id:0x5a}])
    assert.equal(store.observeEvent(exception(undefined,o),18001).taskException,undefined);
  for(const p of ['00000000000019000b','00000000000019000b0000','01000000000019000b00',
    'ff020000000700003100020000000000000000'])
    assert.equal(store.observeEvent(exception(p),18001).taskException,undefined);
  const corrupt=exception();corrupt[15]^=1;assert.equal(store.observeEvent(corrupt,18001).taskException,undefined);
  const p=new Uint8Array(60);p[0]=0x84;p[4]=1;
  assert.equal(store.observe(encodeDumlFrame(1,2,8,0,2,0x80,p),18002).recordingCandidate,true);
  assert.equal(store.observe(task('0400000100'),18003),undefined);
});

test('same-UDP 0B then clearing zero and terminal then idle preserve per-start stop evidence',()=>withNow(18000,()=>{
  const {s,native}=fixture(),events=[];assert.equal(typeof s.setTaskTelemetryListener,'function');
  s.setTaskTelemetryListener(e=>{events.push(e);native.observeTelemetry(e);});
  s.onPacket(packet(task('050d000100'),exception(),exception('00000000000000000000'),
    task('0400000100',2),task('0000000102',3)),18000);
  assert.equal(events.length,5);assert.equal(s.snapshot().telemetry.taskException.codeRaw,0);
  assert.equal(s.snapshot().telemetry.task.phaseRaw,0);
  assert.equal(native.snapshot().stopReport.classification,'unconfirmed');
  assert.equal(native.snapshot().stopReport.codeRaw,11);
  assert.equal(native.snapshot().executionSeen,false,'diagnostics must not update the existing business execution latch');
  s.generation++;assert.equal(native.snapshot().stopReport,undefined);
}));

test('changing flight generation invalidates old stop evidence without reviving the old start',()=>withNow(18000,()=>{
  const {s,native,flight}=fixture();s.setTaskTelemetryListener(e=>native.observeTelemetry(e));
  s.onPacket(packet(task('050d000100'),exception(),task('0400000100',2)),18000);
  assert.equal(native.snapshot().stopReport.classification,'unconfirmed');
  assert.equal(native.snapshot().stopReport.codeRaw,11);
  flight.snapshot=()=>({generation:2});assert.equal(native.snapshot().stopReport,undefined);
  s.onPacket(packet(task('050d000100'),exception(),task('0400000100',3)),18000);
  assert.equal(native.snapshot().stopReport,undefined,'an invalidated start cannot bind fresh events again');
}));

test('post-terminal 100/151ms exception associates without issuing any aircraft operation',()=>{
  for(const delay of [100,151]){const {s,native}=fixture();let sends=0;
    s.requestNative=()=>{sends++;throw Error('diagnostics must not send a command');};
    assert.equal(typeof s.setTaskTelemetryListener,'function');s.setTaskTelemetryListener(e=>native.observeTelemetry(e));
    s.onPacket(packet(task('050d000100')),10100);s.onPacket(packet(task('0000000102',2)),18000);
    s.onPacket(packet(exception('00000000000014000b00')),18000+delay);
    assert.equal(native.snapshot().stopReport.classification,'unconfirmed');
    assert.equal(native.snapshot().stopReport.codeRaw,11);assert.equal(sends,0);
    native.resetForAircraftSession();assert.equal(native.snapshot().stopReport,undefined);
  }
});

test('observer errors do not swallow later task/camera events or a matching command reply',()=>{
  const {s}=fixture();let events=0,cameras=0,reply;assert.equal(typeof s.setTaskTelemetryListener,'function');
  s.setTaskTelemetryListener(()=>{events++;throw Error('consumer failed');});s.setCameraTelemetryListener(()=>{cameras++;});
  const camera=new Uint8Array(60);camera[0]=4;camera[4]=1;
  s.pending.set(17,{commandSet:0x23,commandId:0x13,sender:0x92,timer:0,resolve:v=>{reply=v;}});
  s.onPacket(packet(task('0400000100'),exception(),encodeDumlFrame(1,2,9,0,2,0x80,camera),
    encodeDumlFrame(0x92,2,17,0x80,0x23,0x13,Uint8Array.of(0))),18000);
  assert.equal(events,2);assert.equal(cameras,1);assert.deepEqual(reply,Uint8Array.of(0));
});

function isolatedController(){const Module=require('node:module'),p=require.resolve('../entry/src/main/ets/core/domain/AppController.ets');
  const oldLoad=Module._load,oldModule=require.cache[p];delete require.cache[p];
  Module._load=function(n,parent,main){if(n==='../profile/AircraftProfileStore')return {AircraftProfileStore:class {}};
    if(n==='@kit.CoreFileKit')return {fileIo:{accessSync:()=>false},fileUri:{getUriFromPath:path=>'file://'+path}};
    return oldLoad.call(this,n,parent,main);};
  try{return require(p).AppController;}finally{Module._load=oldLoad;delete require.cache[p];if(oldModule)require.cache[p]=oldModule;}}
test('real Controller wires per-event task observation even when its UI listener is absent',()=>withNow(18000,()=>{
  const c=new (isolatedController())('/unused',{}),s=c.session;Object.assign(s,{session:7,phaseValue:'ready',deviceVerified:true,
    channel:{receivedCount:()=>1,sentCount:()=>0,lastPeer:()=>''},emitThrottled(){}});
  c.log=()=>{};c.emit=()=>{};c.videoSessionEnabled=true;Object.assign(c.nativeTasks,{startedAt:10000,kind:'dolly'});
  s.setListener(undefined);s.onPacket(packet(task('050d000100'),exception(),exception('00000000000000000000'),task('0400000100',2)),18000);
  assert.equal(c.nativeTasks.snapshot().stopReport?.classification,'unconfirmed');
  assert.equal(c.nativeTasks.snapshot().stopReport?.codeRaw,11);
  assert.equal(c.nativeTasks.snapshot().executionSeen,false,'the added observer only records diagnostics');
}));

test('a recorded and sealed Dolly follows the original combination flow even with a 0B report',async()=>{
  const c=Object.create(AppController.prototype);let stops=0;
  Object.assign(c,{busyValue:false,log(){},nativeTasks:{canCompleteForHover:()=>({ok:true}),snapshot:()=>({kind:'dolly',startedAtMs:10000,
    executionSeen:true,recordingSeen:true,activeOrUnknown:false,executionObserved:false,
    stopReport:{startedAtMs:10000,classification:'suspected_obstacle',message:'任务已停止，疑似触发避障'}}),
    stop:()=>{stops++;throw Error('already ended');}},captureMedia:{canContinueVideoSequence:()=>true}});
  await c.waitForCloseupStep(()=>true,11,1);assert.equal(stops,0);
});

test('a normal sealed task stays successful after its fixed exception-settling window',async()=>{
  const c=Object.create(AppController.prototype);
  Object.assign(c,{busyValue:false,log(){},nativeTasks:{canCompleteForHover:()=>({ok:true}),snapshot:()=>({kind:'dolly',startedAtMs:10000,
    executionSeen:true,recordingSeen:true,activeOrUnknown:false,stopReport:{startedAtMs:10000,classification:'unconfirmed',settleUntilMs:1}})},
    captureMedia:{canContinueVideoSequence:()=>true}});
  await c.waitForCloseupStep(()=>true,11,1);
});

test('a pending diagnostic window never delays successful sealed-media handoff',async()=>{
  const savedNow=Date.now,savedTimeout=global.setTimeout;let now=20000;
  Date.now=()=>now;global.setTimeout=(callback,delay)=>{now+=delay;callback();return 0;};
  try{
    for(const delayedException of [true,false]){
      now=20000;const c=Object.create(AppController.prototype);
      Object.assign(c,{busyValue:false,log(){},nativeTasks:{canCompleteForHover:()=>({ok:true}),
        snapshot:()=>({kind:'dolly',startedAtMs:10000,executionSeen:true,recordingSeen:true,activeOrUnknown:false,
          stopReport:{startedAtMs:10000,settleUntilMs:20500,
            classification:delayedException&&now>=20200?'suspected_obstacle':'unconfirmed',message:'任务已停止，疑似触发避障'}})},
        captureMedia:{canContinueVideoSequence:()=>true}});
      await c.waitForCloseupStep(()=>true,11,1);assert.equal(now,20000,'notification confirmation cannot delay movement flow');
    }
  }finally{Date.now=savedNow;global.setTimeout=savedTimeout;}
});

test('a diagnostic 0B report never intercepts or fails the existing combination flow',async()=>{
  const {CancellationToken}=require('../entry/src/main/ets/core/domain/OperationResult.ets');
  const savedNow=Date.now,savedTimeout=global.setTimeout;let now=20000;
  Date.now=()=>now;global.setTimeout=(callback,delay)=>{now+=delay;callback();return 0;};
  try{
    const c=new (isolatedController())('/unused',{}),s=c.session,starts=[],downloads=[],releases=[];
    Object.assign(s,{session:7,phaseValue:'ready',deviceVerified:true,
      channel:{receivedCount:()=>1,sentCount:()=>0,lastPeer:()=>''},emitThrottled(){}});
    s.setListener(undefined);s.isReliableLinkFresh=()=>true;
    const originalSnapshot=s.snapshot.bind(s);
    s.snapshot=()=>{const state=originalSnapshot();return {...state,telemetry:{...state.telemetry,taskAgeMs:0,cameraAgeMs:0,
      camera:state.telemetry.camera?{...state.telemetry.camera,observedAtMs:now}:undefined,
      subject:{tracking:true,trackingAt:now,overlay:[{id:11}],candidates:[{id:11}]}}};};
    c.flight.snapshot=()=>({generation:2,landRequested:false,landSent:false});
    c.log=()=>{};c.emit=()=>{};c.videoSessionEnabled=true;c.finishAgentObservation=()=>{};
    let entries=[];c.media.listMedia=async()=>({ok:true,data:entries.slice()});
    c.media.downloadEntry=async entry=>{downloads.push(entry.path);return {ok:true,data:{path:'/download/partial.MP4',size:500}};};
    const release=c.captureMedia.releaseVideoSequence.bind(c.captureMedia);
    c.captureMedia.releaseVideoSequence=(id,discard)=>{releases.push({id,discard});release(id,discard);};
    c.performAgentAction=async(_,command)=>{
      starts.push(command.action);
      if(command.action==='circle')c.captureMedia.continueVideoSequence(1,new CancellationToken(2));
      Object.assign(c.nativeTasks,{startedAt:now,kind:command.action==='circle'?'circle':'dolly',executionSeen:true});
      s.onPacket(packet(task(command.action==='circle'?'0505000100':'050d000100')),now);
      const camera=new Uint8Array(60);camera[0]=0x84;camera[4]=1;now+=100;
      s.onPacket(packet(encodeDumlFrame(1,2,9,0,2,0x80,camera)),now);
      now+=100;s.onPacket(packet(exception(),exception('00000000000000000000'),task('0400000100',2)),now);
      camera[0]=4;now+=100;s.onPacket(packet(encodeDumlFrame(1,2,10,0,2,0x80,camera)),now);
      entries=[{path:'partial.MP4',name:'partial.MP4',kind:'video',size:500}];return {message:'started'};
    };
    c.nativeTasks.stop=()=>{throw Error('notifications must not send a stop');};
    c.waitForCloseupTarget=async()=>({requestId:'next',sessionId:7,flightGeneration:2,controlGeneration:c.agentGeneration,
      frame:{currentSubjectId:11}});
    c.waitForCloseupMedia=async()=>{
      const items=await c.captureMedia.retrieveAll('video',new CancellationToken(2),()=>{});
      return items.map(item=>'file://'+item.path);
    };
    const observation={requestId:'initial',sessionId:7,flightGeneration:2,controlGeneration:c.agentGeneration,
      frame:{currentSubjectId:11}};
    await c.runCloseupSequence(observation,{action:'dolly_zoom',recipe:'dolly_circle',subjectId:11});
    assert.deepEqual(starts,['dolly_zoom','circle']);assert.equal(releases.length,1);assert.equal(releases[0].discard,false);
    assert.deepEqual(downloads,['partial.MP4']);assert.equal(c.captureMedia.hasPending('video'),false);
    assert.equal(c.closeupSequence.snapshot().stage,'completed');
  }finally{Date.now=savedNow;global.setTimeout=savedTimeout;}
});

test('an exception during retreat with recording and execution continuing produces no stopped notification',()=>{
  withNow(18000,()=>{
    const {s,native}=fixture();s.setTaskTelemetryListener(e=>native.observeTelemetry(e));
    const p=new Uint8Array(60);p[0]=0x84;p[4]=1;
    s.onPacket(packet(task('050d000100'),exception(),encodeDumlFrame(1,2,8,0,2,0x80,p)),18000);
    assert.equal(native.snapshot().stopNotice,undefined);
    s.onPacket(packet(task('050d000100',2)),18000);
    assert.equal(native.snapshot().stopNotice,undefined);
  });
});

test('an independently classified notice needs sustained fresh idle, navigation and stationary flight before UI delivery',()=>{
  const savedNow=Date.now;let now=18000;Date.now=()=>now;
  try{
    const {s,native}=fixture();s.setTaskTelemetryListener(e=>native.observeTelemetry(e));
    const camera=new Uint8Array(60);camera[0]=4;camera[4]=1;
    s.onPacket(packet(task('050d000100'),exception(),task('0400000100',2),encodeDumlFrame(1,2,8,0,2,0x80,camera)),now);
    injectClassifiedReportForUiTest(native);
    s.onPacket(packet(...settledFrames()),now);
    assert.equal(native.snapshot().stopNotice,undefined);
    now=18500;assert.equal(native.snapshot().stopNotice,undefined,'the same cached idle report cannot confirm a sustained end');
    s.onPacket(packet(...settledFrames(21)),now);
    const notice=native.snapshot().stopNotice;assert.ok(notice);
    assert.equal(notice.message,'检测到障碍物，已触发避障');
    assert.equal(native.snapshot().stopNotice.id,notice.id);
    native.resetTaskState();assert.equal(native.snapshot().stopNotice.id,notice.id,'normal handoff may clear raw task evidence without losing the popup');
    now=28501;assert.equal(native.snapshot().stopNotice,undefined,'an old notification expires');
    native.resetForAircraftSession();assert.equal(native.snapshot().stopNotice,undefined);
  }finally{Date.now=savedNow;}
});

test('transient ending followed by resumed retreat/forward recording does not create a stopped notice',()=>{
  const savedNow=Date.now;let now=18000;Date.now=()=>now;
  try{
    const {s,native}=fixture();s.setTaskTelemetryListener(e=>native.observeTelemetry(e));
    const p=new Uint8Array(60);p[0]=4;p[4]=1;
    s.onPacket(packet(task('050d000100'),exception(),task('0400000100',2),encodeDumlFrame(1,2,8,0,2,0x80,p)),now);
    assert.equal(native.snapshot().stopNotice,undefined);
    now+=100;p[0]=0x84;s.onPacket(packet(task('050d000100',3),encodeDumlFrame(1,2,9,0,2,0x80,p)),now);
    assert.equal(native.snapshot().stopReport,undefined);assert.equal(native.snapshot().stopNotice,undefined);
    now+=1000;s.onPacket(packet(task('050d000100',4),encodeDumlFrame(1,2,10,0,2,0x80,p)),now);
    assert.equal(native.snapshot().stopNotice,undefined);
    now+=100;p[0]=4;s.onPacket(packet(task('0400000100',5),encodeDumlFrame(1,2,11,0,2,0x80,p)),now);
    native.snapshot();now+=500;s.onPacket(packet(encodeDumlFrame(1,2,12,0,2,0x80,p)),now);
    assert.equal(native.snapshot().stopNotice,undefined,'later ordinary completion must not reuse the soft-block exception');
  }finally{Date.now=savedNow;}
});

test('a momentary recording edge between UI snapshots resets notification idle confirmation',()=>{
  const savedNow=Date.now;let now=18000;Date.now=()=>now;
  try{
    const c=new (isolatedController())('/unused',{}),s=c.session;
    Object.assign(s,{session:7,phaseValue:'ready',deviceVerified:true,
      channel:{receivedCount:()=>1,sentCount:()=>0,lastPeer:()=>''},emitThrottled(){}});
    s.setListener(undefined);c.log=()=>{};c.emit=()=>{};c.videoSessionEnabled=true;
    Object.assign(c.nativeTasks,{startedAt:10000,kind:'dolly'});
    const p=new Uint8Array(60);p[0]=4;p[4]=1;
    s.onPacket(packet(task('050d000100'),exception(),task('0400000100',2),encodeDumlFrame(1,2,8,0,2,0x80,p)),now);
    injectClassifiedReportForUiTest(c.nativeTasks);
    s.onPacket(packet(...settledFrames()),now);
    assert.equal(c.nativeTasks.snapshot().stopNotice,undefined);
    now=18050;p[0]=0x84;s.onPacket(packet(encodeDumlFrame(1,2,9,0,2,0x80,p)),now);
    now=18500;p[0]=4;s.onPacket(packet(encodeDumlFrame(1,2,10,0,2,0x80,p)),now);
    s.onPacket(packet(...settledFrames(21)),now);
    assert.equal(c.nativeTasks.snapshot().stopNotice,undefined,'latest idle alone cannot hide the recording edge');
    now=19000;s.onPacket(packet(...settledFrames(22)),now);
    assert.ok(c.nativeTasks.snapshot().stopNotice);
  }finally{Date.now=savedNow;}
});

test('an expired notification cannot republish from the same still-fresh terminal stream',()=>{
  const savedNow=Date.now;let now=18000;Date.now=()=>now;
  try{
    const {s,native}=fixture();s.setTaskTelemetryListener(e=>native.observeTelemetry(e));
    const p=new Uint8Array(60);p[0]=4;p[4]=1;
    const feed=()=>s.onPacket(packet(...settledFrames(Math.floor(now/100))),now);
    s.onPacket(packet(task('050d000100'),exception()),now);feed();native.snapshot();
    injectClassifiedReportForUiTest(native);native.snapshot();
    now=18500;feed();const id=native.snapshot().stopNotice.id;
    for(now=18750;now<=28500;now+=250){feed();assert.equal(native.snapshot().stopNotice.id,id);}
    now=28501;feed();assert.equal(native.snapshot().stopNotice,undefined);
    now=28502;feed();assert.equal(native.snapshot().stopNotice,undefined,'published IDs survive visible notice expiration');
    assert.ok(id);
  }finally{Date.now=savedNow;}
});

for(const run of require('./fixtures/dolly-return-obstacle-false-notice-20261112.json').runs){
  test(`captured Dolly ${run.exceptionAtMs}: 0B plus ending and camera idle cannot assert obstacle-aborted motion`,()=>{
    const savedNow=Date.now;let now=run.startedAtMs;Date.now=()=>now;
    try{
      const {s,native}=fixture();Object.assign(native,{startedAt:run.startedAtMs,kind:'dolly'});
      s.setTaskTelemetryListener(event=>native.observeTelemetry(event));
      const camera=(recording,seq)=>{const p=new Uint8Array(60);p[0]=recording?0x84:4;p[4]=1;
        return encodeDumlFrame(1,2,seq,0,2,0x80,p);};
      const flight=(mode,seq)=>{const p=new Uint8Array(36);p[30]=mode;p[32]=12;
        return encodeDumlFrame(3,2,seq,0,3,0x43,p);};
      const events=[
        [run.executionAtMs,[task('050d000100'),flight(37,1),camera(true,1)]],
        [run.cameraIdleAtMs,[camera(false,2)]],
        [run.exceptionAtMs,[exception(run.payload,{sequence:run.sequence}),exception('00000000000000000000',{sequence:run.sequence+1})]],
        [run.firstTerminalAtMs,[task('0400000100',2)]],
        [run.returnModeAtMs,[flight(15,2)]]
      ].sort((a,b)=>a[0]-b[0]);
      for(const [at,frames] of events){now=at;s.onPacket(packet(...frames),now);assert.equal(native.snapshot().stopNotice,undefined);}
      // HiLog logs state changes, not every unchanged push. Repeated fresh
      // terminal/idle frames model the actual 500ms UI rule during mode-15 return.
      for(now+=100;now<run.trackingModeAtMs;now+=100){
        s.onPacket(packet(task('0400000100',3),camera(false,3),flight(15,3)),now);
        assert.equal(native.snapshot().stopNotice,undefined,'ongoing return cannot produce a task-aborted popup');
      }
      now=run.trackingModeAtMs;s.onPacket(packet(task('0000000102',4),camera(false,4),flight(26,4)),now);
      const snapshot=native.snapshot();assert.equal(snapshot.stopNotice,undefined);
      assert.equal(snapshot.stopReport.classification,'unconfirmed');
      assert.equal(snapshot.stopReport.codeRaw,11);assert.equal(snapshot.stopReport.payloadHex,run.payload);
    }finally{Date.now=savedNow;}
  });
}
