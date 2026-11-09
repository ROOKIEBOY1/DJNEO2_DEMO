const {test}=require('node:test');const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {CloseupSequence}=require('../entry/src/main/ets/core/domain/CloseupSequence.ets');
const {CloseupMediaGroup}=require('../entry/src/main/ets/core/media/CloseupMediaGroup.ets');

function fixture(){
  const c=Object.create(AppController.prototype);const calls=[];const target=13;let nativeStarted;
  const obs=()=>({requestId:'frame-'+calls.length,sessionId:10,flightGeneration:2,controlGeneration:0,
    requestedAtMs:Date.now(),frame:{currentSubjectId:target,candidates:[{id:target}]}});
  Object.assign(c,{agentGeneration:0,agentMediaUris:['old'],agentMediaUri:'old',agentVideoResultReady:true,agentFeedback:'',
    closeupSequence:new CloseupSequence(()=>{}),closeupMedia:new CloseupMediaGroup(),emit(){},log(){},
    session:{sessionId:()=>10,isReliableLinkFresh:()=>true,snapshot:()=>({phase:'ready',telemetry:{
      flight:{modeRaw:26},flightAgeMs:0,subject:{tracking:true,overlay:[{id:target}],trackingAt:Date.now()}}})},
    nativeTasks:{snapshot:()=>({startedAtMs:nativeStarted})},
    captureMedia:{beginVideoSequence:async()=>{calls.push(['baseline']);return 42;},
      finishVideoSequence:id=>{calls.push(['allow-return',id]);},
      releaseVideoSequence:(id,discard)=>{calls.push(['release',id,discard]);}},
    flight:{snapshot:()=>({generation:2,landRequested:false,landSent:false})}});
  c.captureAgentObservation=async()=>obs();
  c.finishAgentObservation=id=>{calls.push(['finished',id]);};
  c.performAgentAction=async(observation,command,sequence)=>{nativeStarted=(nativeStarted??0)+1;calls.push(['start',command,sequence]);return {message:'started'};};
  let part=0;
  c.waitForCloseupStep=async(gate,target,sequence)=>{
    assert.equal(gate(),true);assert.equal(c.agentVideoResultReady,false);
    assert.equal(calls.at(-1)[0],'finished','release the observation before waiting, so automatic return is not blocked');
    assert.equal(target,13);assert.equal(sequence,42);calls.push(['step-finished',++part]);
  };
  c.waitForCloseupMedia=async gate=>{
    assert.equal(gate(),true);assert.equal(part,2,'no media return before all movements have ended');
    assert.equal(calls.at(-1)[0],'allow-return');calls.push(['media']);return ['dolly-a','dolly-b','circle-a'];
  };
  return {c,calls,obs};
}

test('closeup controller starts the same target in order and presents every returned clip as one group',async()=>{
  const {c,calls,obs}=fixture();
  await c.runCloseupSequence(obs(),{action:'dolly_zoom',recipe:'dolly_circle',subjectId:13,framing:'半身',zoom:3,retreat:true});
  assert.deepEqual(calls.filter(x=>x[0]==='start').map(x=>x[1]),[
    {action:'dolly_zoom',subjectId:13,framing:'半身',zoom:3,retreat:true},
    {action:'circle',subjectId:13,radiusMeters:2}]);
  assert.deepEqual(c.agentMediaUris,['dolly-a','dolly-b','circle-a']);assert.equal(c.agentMediaUri,'dolly-a');
  assert.equal(c.agentVideoResultReady,true);assert.equal(c.closeupSequence.snapshot().stage,'completed');
  assert.equal(calls.filter(x=>x[0]==='baseline').length,1);assert.equal(calls.filter(x=>x[0]==='media').length,1);
  assert.ok(calls.filter(x=>x[0]==='start').every(x=>x[2]===42));
});

test('an unfinished first step never starts circle, and a different target releases the pending group for partial return',async()=>{
  const a=fixture();a.c.waitForCloseupStep=async()=>{throw Error('本步录像未封存');};
  await assert.rejects(a.c.runCloseupSequence(a.obs(),{action:'dolly_zoom',recipe:'dolly_circle',subjectId:13}),/封存/);
  assert.equal(a.calls.filter(x=>x[0]==='start').length,1);assert.equal(a.c.agentVideoResultReady,false);
  const b=fixture();b.c.captureAgentObservation=async()=>({...b.obs(),frame:{currentSubjectId:11,candidates:[{id:11}]}});
  await assert.rejects(b.c.runCloseupSequence(b.obs(),{action:'dolly_zoom',recipe:'dolly_circle',subjectId:13}),/主体|跟踪/);
  assert.equal(b.calls.filter(x=>x[0]==='start').length,1);assert.equal(b.calls.some(x=>x[0]==='media'),false);
  assert.deepEqual(b.calls.at(-1),['release',42,false]);assert.equal(b.c.closeupSequence.snapshot().stage,'failed');
});

test('a generation change between steps cancels the next start and releases deferred media without downloading mid-sequence',async()=>{
  const {c,calls,obs}=fixture();const finish=c.waitForCloseupStep;
  c.waitForCloseupStep=async(...args)=>{await finish(...args);c.agentGeneration++;};
  await assert.rejects(c.runCloseupSequence(obs(),{action:'dolly_zoom',recipe:'dolly_circle',subjectId:13}),/取消|变化/);
  assert.equal(calls.filter(x=>x[0]==='start').length,1);assert.equal(calls.some(x=>x[0]==='media'),false);
  assert.deepEqual(calls.at(-1),['release',42,false]);
});

test('completion without observing the actual movement cannot authorize the next closeup step',async()=>{
  const {c}=fixture();
  c.nativeTasks={snapshot:()=>({executionSeen:false,executionObserved:false,activeOrUnknown:false}),
    canCompleteForHover:()=>({ok:true})};
  c.busyValue=false;c.captureMedia={hasPending:()=>false};c.agentMediaKind='video';c.agentFeedback='录像已取回';
  await assert.rejects(AppController.prototype.waitForCloseupStep.call(c,()=>true,13,42),/实际执行/);
});

test('observed movement with a fresh different tracked subject requests stop and never reports the step complete',async()=>{
  for(const observed of [true,false]){
    const {c}=fixture();let stopped=0;
    c.session.snapshot=()=>({phase:'ready',telemetry:{subject:{tracking:true,overlay:[{id:11}],trackingAt:Date.now()}}});
    c.nativeTasks={snapshot:()=>({executionSeen:true,executionObserved:observed,activeOrUnknown:true}),
      canCompleteForHover:()=>({ok:false}),stop:async()=>{stopped++;return {ok:true};}};
    let checks=0;
    await assert.rejects(AppController.prototype.waitForCloseupStep.call(c,()=>++checks<=2,13,42),/主体.*跟踪/);
    assert.equal(stopped,1);
  }
});

async function withCloseupClock(start,advance,body){
  let now=start;const realNow=Date.now;const realTimeout=global.setTimeout;
  Date.now=()=>now;
  global.setTimeout=(callback,delay)=>{now+=delay;advance(now);queueMicrotask(callback);return 0;};
  try { advance(now);return await body(()=>now); }
  finally { Date.now=realNow;global.setTimeout=realTimeout; }
}

for(const replay of require('./fixtures/closeup-native-dolly-ending.json').cases){
  test('original successful '+replay.name+' waits through empty native tracking until real completion and sealing',async()=>{
    const {TelemetryStore}=require('../entry/src/main/ets/core/domain/TelemetryStore.ets');
    const {NativeTaskService}=require('../entry/src/main/ets/core/domain/NativeTaskService.ets');
    const {CaptureMedia}=require('../entry/src/main/ets/core/media/CaptureMedia.ets');
    const {CancellationToken}=require('../entry/src/main/ets/core/domain/OperationResult.ets');
    const {encodeDumlFrame}=require('../entry/src/main/ets/core/protocol/DumlCodec.ets');
    const telemetry=new TelemetryStore();let index=0,stopRequests=0,sequence;
    const session={sessionId:()=>1,isReliableLinkFresh:()=>true,
      snapshot:()=>({phase:'ready',telemetry:telemetry.snapshot(Date.now())}),
      requestNative:async(receiver,set,id)=>{assert.equal(id,0x15);stopRequests++;return Uint8Array.of(0);}};
    const flight={snapshot:()=>({landRequested:false,landSent:false}),centerSticks:async()=>({ok:true}),
      markNativeStopConfirmed(){}};
    const native=new NativeTaskService(session,flight,{});native.kind='dolly';native.startedAt=replay.startAtMs-100;
    const media=new CaptureMedia(session,{listMedia:async()=>({ok:true,data:[]})},'');
    const c=Object.create(AppController.prototype);const logs=[];
    Object.assign(c,{session,flight,nativeTasks:native,captureMedia:media,busyValue:false,log:message=>logs.push(message)});
    const advance=now=>{
      while(index<replay.reports.length&&replay.reports[index][0]<=now){
        const [at,sender,receiver,flags,set,id,hex]=replay.reports[index++];
        telemetry.observe(encodeDumlFrame(sender,receiver,index,flags,set,id,new Uint8Array(Buffer.from(hex,'hex'))),at);
      }
      native.observeProgress();media.observe(telemetry.snapshot(now),native.activeOrUnknown());
    };
    await withCloseupClock(replay.startAtMs,advance,async now=>{
      sequence=await media.beginVideoSequence(new CancellationToken(0));
      await c.waitForCloseupStep(()=>true,replay.targetId,sequence);
      assert.ok(now()>=replay.completedAtMs,'empty tracking cannot authorize an early return');
      assert.ok(now()<replay.completedAtMs+300,'the real terminal report and sealed media finish the step');
      assert.equal(native.canCompleteForHover().ok,true);assert.equal(media.canContinueVideoSequence(sequence),true);
    });
    assert.equal(stopRequests,0,'a proven normal native ending must not be interrupted');
    assert.ok(logs.some(message=>/跟踪框.*未知/.test(message)),'report missing visual feedback as unknown');
  });
}

test('native circle recording with no displayable tracking remains pending until its actual terminal report',async()=>{
  const {c}=fixture();let active=true,stopped=0;
  c.nativeTasks={canCompleteForHover:()=>({ok:!active}),
    snapshot:()=>({kind:'circle',executionSeen:true,executionObserved:active,activeOrUnknown:active}),
    stop:async()=>{stopped++;return {ok:true};}};
  c.session.snapshot=()=>({telemetry:{task:{payloadHex:active?'0505000100':'0000000102'},taskAgeMs:0,
    camera:{recordingCandidate:active},cameraAgeMs:0,subject:{tracking:false,overlay:[{id:13}],candidates:[{id:13}]}}});
  c.busyValue=false;c.captureMedia={canContinueVideoSequence:()=>!active};
  await withCloseupClock(1000,now=>{active=now<6000;},async now=>{
    await AppController.prototype.waitForCloseupStep.call(c,()=>true,13,42);assert.ok(now()>=6000);
  });
  assert.equal(stopped,0);
});

test('closeup deadline requests native stop and distinguishes acknowledgement from uncertain stop',async()=>{
  for(const ok of [true,false]){
    const {c}=fixture();let stopped=0;
    c.nativeTasks={canCompleteForHover:()=>({ok:false}),
      snapshot:()=>({kind:'circle',executionSeen:true,executionObserved:true,activeOrUnknown:true}),
      stop:async()=>{stopped++;return {ok,error:ok?undefined:{message:'no reply'}};}};
    c.session.snapshot=()=>({telemetry:{subject:{tracking:false,overlay:[]}}});
    await withCloseupClock(1000,()=>{},async()=>{
      await assert.rejects(AppController.prototype.waitForCloseupStep.call(c,()=>true,13,42),
        ok?/超时.*已请求停止/:/超时.*停止尚未确认/);
    });
    assert.equal(stopped,1);
  }
});

test('cancelled or landing closeup wait leaves stop ownership to the existing safety operation',async()=>{
  for(const landing of [false,true]){
    const {c}=fixture();let stopped=0;
    c.flight.snapshot=()=>({landRequested:landing,landSent:false});
    c.nativeTasks={snapshot:()=>({executionSeen:true,activeOrUnknown:true}),
      stop:async()=>{stopped++;return {ok:true};}};
    await assert.rejects(AppController.prototype.waitForCloseupStep.call(c,()=>false,13,42),/取消/);
    assert.equal(stopped,0);
  }
});

test('cancellation exactly at the closeup deadline does not send a competing stop',async()=>{
  const {c}=fixture();let stopped=0,cancelled=false;
  c.nativeTasks={canCompleteForHover:()=>({ok:false}),
    snapshot:()=>({kind:'circle',executionSeen:true,executionObserved:true,activeOrUnknown:true}),
    stop:async()=>{stopped++;return {ok:true};}};
  c.session.snapshot=()=>({telemetry:{subject:{tracking:false,overlay:[]}}});
  await withCloseupClock(1000,now=>{cancelled=now>=181000;},async()=>{
    await assert.rejects(AppController.prototype.waitForCloseupStep.call(c,()=>!cancelled,13,42),/取消/);
  });
  assert.equal(stopped,0);
});

test('an already terminal native task waiting for sealing is not stopped again at the deadline',async()=>{
  const {c}=fixture();let stopped=0;
  c.nativeTasks={canCompleteForHover:()=>({ok:true}),
    snapshot:()=>({executionSeen:true,executionObserved:false,activeOrUnknown:false}),
    stop:async()=>{stopped++;return {ok:true};}};
  c.busyValue=false;c.captureMedia={canContinueVideoSequence:()=>false};
  await withCloseupClock(1000,()=>{},async()=>{
    await assert.rejects(AppController.prototype.waitForCloseupStep.call(c,()=>true,13,42),/录像封存超时/);
  });
  assert.equal(stopped,0);
});

test('same-ID candidates or expired same-ID tracking cannot authorize the circle handoff',async()=>{
  for(const tracking of [false,true]){
    const {c}=fixture();let frames=0;
    c.session.snapshot=()=>({telemetry:{flight:{modeRaw:26},flightAgeMs:0,
      subject:{tracking,trackingAt:0,overlay:[{id:13}],candidates:[{id:13}],selectedIdCandidate:13}}});
    c.captureAgentObservation=async()=>{frames++;throw Error('must not capture without fresh tracking');};
    await withCloseupClock(1000,()=>{},async()=>{
      await assert.rejects(c.waitForCloseupTarget(()=>true,13),/未恢复原主体.*未启动环绕/);
    });
    assert.equal(frames,0);
  }
});

test('a brief startup tracking gap recovers to the confirmed subject without sending stop',async()=>{
  const {c}=fixture();const confirmedAt=Date.now();let poll=0;let stopped=0;
  c.nativeTasks={canCompleteForHover:()=>({ok:++poll>=5}),
    snapshot:()=>({executionSeen:true,executionObserved:true,activeOrUnknown:poll<5,
      initialTargetTrackingAtMs:confirmedAt}),stop:async()=>{stopped++;return {ok:true};}};
  c.session.snapshot=()=>({telemetry:{subject:poll<4?{tracking:false,overlay:[]}:
    {tracking:true,overlay:[{id:13}],trackingAt:Date.now()}}});
  c.busyValue=false;c.captureMedia={canContinueVideoSequence:()=>poll>=5};
  await AppController.prototype.waitForCloseupStep.call(c,()=>poll<8,13,42);
  assert.equal(stopped,0);assert.ok(poll>=5);
});

test('a confirmed completed task can return its video during the normal ending tracking gap',async()=>{
  const {c}=fixture();c.nativeTasks={canCompleteForHover:()=>({ok:true}),
    snapshot:()=>({executionSeen:true,executionObserved:false,activeOrUnknown:false})};
  c.session.snapshot=()=>({telemetry:{subject:{tracking:false,overlay:[]}}});
  c.busyValue=false;c.captureMedia={canContinueVideoSequence:()=>true};
  await AppController.prototype.waitForCloseupStep.call(c,()=>true,13,42);
});

test('a missing handoff frame is refreshed, while an explicit different fresh ID is never retried',async()=>{
  const {c,obs,calls}=fixture();let frames=0;
  c.captureAgentObservation=async()=>({...obs(),frame:++frames===1?undefined:obs().frame});
  const fresh=await c.waitForCloseupTarget(()=>true,13);assert.equal(fresh.frame.currentSubjectId,13);
  assert.equal(frames,2);assert.equal(calls.filter(x=>x[0]==='finished').length,1);
  const b=fixture();let attempts=0;b.c.captureAgentObservation=async()=>{attempts++;return {...b.obs(),frame:{currentSubjectId:11}};};
  await assert.rejects(b.c.waitForCloseupTarget(()=>true,13),/主体|跟踪/);assert.equal(attempts,1);
});

test('cancelling after baseline but before any start releases the empty sequence as proven unstarted',async()=>{
  const {c,obs,calls}=fixture();c.captureMedia.beginVideoSequence=async()=>{c.agentGeneration++;return 42;};
  await assert.rejects(c.runCloseupSequence(obs(),{action:'dolly_zoom',recipe:'dolly_circle',subjectId:13}),/取消|变化/);
  assert.equal(calls.some(x=>x[0]==='start'),false);assert.deepEqual(calls.at(-1),['release',42,true]);
  assert.equal(c.closeupMedia.owns(10,2),false);
});

test('cancellation while refreshing the handoff frame finishes that observation without accepting or starting it',async()=>{
  const {c,obs,calls}=fixture();
  c.captureAgentObservation=async()=>{c.agentGeneration++;return obs();};
  await assert.rejects(c.waitForCloseupTarget(()=>c.agentGeneration===0,13),/取消/);
  assert.equal(calls.filter(x=>x[0]==='finished').length,1);assert.equal(calls.some(x=>x[0]==='start'),false);
});

test('a cancelled flight context cannot use a reset native timestamp to discard an uncertain start',async()=>{
  const {c,obs,calls}=fixture();
  c.performAgentAction=async()=>{c.agentGeneration++;throw Error('启动未确认且飞行上下文已变化');};
  await assert.rejects(c.runCloseupSequence(obs(),{action:'dolly_zoom',recipe:'dolly_circle',subjectId:13}),/未确认/);
  assert.deepEqual(calls.at(-1),['release',42,false]);
});

test('a failed second start keeps the shared baseline, and a finished-phase ticket cannot start another movement',async()=>{
  const {c}=fixture();const calls=[];let phase='circle';
  c.closeupSequence={snapshot:()=>({active:true,stage:phase})};
  c.nativeTasks={snapshot:()=>({kind:'circle',startedAtMs:1}),start:async()=>{calls.push('start');return {ok:false};}};
  c.captureMedia={isVideoSequenceCurrent:id=>id===42,canContinueVideoSequence:()=>true,
    continueVideoSequence:()=>calls.push('continue'),begin:async()=>{throw Error('duplicate baseline');},
    discard:()=>calls.push('discard')};
  assert.equal((await c.startNativeWithCapture({},13,42)).ok,false);
  assert.deepEqual(calls,['continue','start']);
  phase='returning';
  await assert.rejects(c.startNativeWithCapture({},13,42),/阶段|序列/);
  assert.deepEqual(calls,['continue','start']);
});

test('only the owned sealed video sequence can bypass the ordinary pending-media handoff block',async()=>{
  const {c,obs}=fixture();let released=0;
  c.ensureAgentPhotoSession=()=>{};c.flight.snapshot=()=>({nativeTaskMayFly:true});
  c.captureMedia={hasPending:()=>true,canContinueVideoSequence:id=>id===42};
  c.nativeTasks={canCompleteForHover:()=>({ok:true,data:true}),completeForHover:()=>({ok:true,data:true})};
  c.releaseHoverTaskTarget=async()=>{released++;};
  await assert.rejects(c.handoffCompletedNativeTask(obs(),{}),/取回/);
  await assert.rejects(c.handoffCompletedNativeTask(obs(),{},41),/取回/);
  assert.equal(released,0);await c.handoffCompletedNativeTask(obs(),{},42);assert.equal(released,1);
});

test('completed-task handoff binds to the captured context when the optional intent image is absent',async()=>{
  for(const scenario of [{frame:undefined,current:13,allowed:true},{frame:undefined,current:11,allowed:false},
    {frame:{currentSubjectId:11},current:13,allowed:false}]){
    const {c,obs}=fixture();let released=0;
    c.ensureAgentPhotoSession=()=>{};c.flight.snapshot=()=>({nativeTaskMayFly:true});
    c.captureMedia={hasPending:()=>false};
    c.nativeTasks={canCompleteForHover:()=>({ok:true,data:true}),completeForHover:()=>({ok:true,data:true})};
    c.releaseHoverTaskTarget=async()=>{released++;};
    const observation={...obs(),frame:scenario.frame,context:{currentSubjectId:scenario.current}};
    if(scenario.allowed)await c.handoffCompletedNativeTask(observation,{});
    else await assert.rejects(c.handoffCompletedNativeTask(observation,{}),/锁定状态已变化/);
    assert.equal(released,scenario.allowed?1:0);
  }
});

test('a terminated grounded movement without recording stops waiting but keeps its unresolved media ticket',async()=>{
  const {c}=fixture();let discarded=0,stopped=0;
  c.busyValue=false;
  c.nativeTasks={canCompleteForHover:()=>({ok:true}),snapshot:()=>({kind:'dolly',startedAtMs:1000,
    executionSeen:true,recordingSeen:false,activeOrUnknown:false}),stop:async()=>{stopped++;return {ok:true};}};
  c.captureMedia={canContinueVideoSequence:()=>false,discard:()=>discarded++};
  c.session.snapshot=()=>({telemetry:{flightAgeMs:0,flight:{observedAtMs:Date.now(),airborne:false,motorsOn:false},
    cameraAgeMs:0,camera:{observedAtMs:Date.now(),recordingCandidate:false},taskAgeMs:0,
    task:{observedAtMs:Date.now(),payloadHex:'0000000102'},subject:{tracking:false,overlay:[]}}});
  await withCloseupClock(2000,()=>{},async now=>{
    await assert.rejects(AppController.prototype.waitForCloseupStep.call(c,()=>true,13,42),/未观察到录像/);
    assert.ok(now()<3000,'a finished empty shot must not stay busy for the full 180-second deadline');
  });
  assert.equal(discarded,0,'only a later verified directory reconciliation can retire the ticket');
  assert.equal(stopped,0);
});

test('unknown flight or stale camera state never authorizes the grounded empty-shot exit',async()=>{
  for(const condition of ['airborne','stale-flight','stale-camera','pre-start-flight']){
    const {c}=fixture();let checks=0;
    c.busyValue=false;c.captureMedia={canContinueVideoSequence:()=>false};
    c.nativeTasks={canCompleteForHover:()=>({ok:true}),snapshot:()=>({kind:'dolly',startedAtMs:1000,
      executionSeen:true,recordingSeen:false,activeOrUnknown:false})};
    c.session.snapshot=()=>({telemetry:{flightAgeMs:condition==='stale-flight'?1001:0,
      flight:{observedAtMs:condition==='pre-start-flight'?999:Date.now(),airborne:condition==='airborne',motorsOn:condition==='airborne'},
      cameraAgeMs:condition==='stale-camera'?1001:0,camera:{observedAtMs:Date.now(),recordingCandidate:false}}});
    await withCloseupClock(2000,()=>{},async()=>{
      await assert.rejects(AppController.prototype.waitForCloseupStep.call(c,()=>++checks<4,13,42),/取消|变化/);
    });
  }
});

test('latest airborne dolly exit without recording fails after confirmed idle and never starts circle or discards media',async()=>{
  const replay=require('./fixtures/closeup-native-dolly-no-recording.json');
  const {NativeTaskService}=require('../entry/src/main/ets/core/domain/NativeTaskService.ets');
  const {CaptureMedia}=require('../entry/src/main/ets/core/media/CaptureMedia.ets');
  const {c,calls,obs}=fixture();const logs=[];let telemetry;
  c.log=message=>logs.push(message);c.busyValue=false;
  c.session.snapshot=()=>({phase:'ready',telemetry});
  c.flight.centerSticks=async()=>{calls.push(['center']);return {ok:true};};
  c.session.requestNative=async()=>{calls.push(['native-request']);return Uint8Array.of(0);};
  const native=new NativeTaskService(c.session,c.flight,{});native.kind='dolly';native.config=replay.config;
  c.nativeTasks=native;
  const media=new CaptureMedia(c.session,{listMedia:async()=>({ok:true,data:[]})},'');
  c.captureMedia=media;
  c.performAgentAction=async(observation,command)=>{
    calls.push(['start',command]);native.startedAt=Date.now();native.startReply=replay.startReply;
    return {message:'started'};
  };
  c.waitForCloseupStep=AppController.prototype.waitForCloseupStep;
  const advance=now=>{
    const elapsed=now-replay.startAtMs;
    const [,payloadHex,modeRaw,tracking]=replay.transitions.findLast(row=>row[0]<=elapsed);
    telemetry={taskAgeMs:0,task:{observedAtMs:now,payloadHex,phaseRaw:parseInt(payloadHex.slice(0,2),16),modeRaw:0},
      flightAgeMs:0,flight:{observedAtMs:now,modeRaw,airborne:true,motorsOn:true},
      cameraAgeMs:0,camera:{observedAtMs:now,recordingCandidate:false,recordStateRaw:0},
      subject:{tracking,trackingAt:now,overlay:[{id:replay.targetId}]}};
    native.observeProgress();media.observe(telemetry,native.activeOrUnknown());
  };
  await withCloseupClock(replay.startAtMs,advance,async now=>{
    await assert.rejects(c.runCloseupSequence({...obs(),frame:{currentSubjectId:11,candidates:[{id:11}]}},
      {action:'dolly_zoom',recipe:'dolly_circle',subjectId:11,framing:'半身',zoom:3,retreat:true}),/未观察到录像/);
    assert.ok(now()>=replay.startAtMs+5305,'wait for two seconds of confirmed terminal camera idle');
    assert.ok(now()<replay.startAtMs+5505,'fail while hovering instead of waiting for landing or the 180-second deadline');
  });
  assert.deepEqual(calls.filter(row=>row[0]==='start').map(row=>row[1].action),['dolly_zoom']);
  assert.equal(calls.some(row=>row[0]==='native-request'||row[0]==='center'||row[0]==='media'),false);
  assert.equal(c.closeupSequence.snapshot().stage,'failed');assert.equal(media.hasPending('video'),true);
  assert.equal(native.snapshot().recordingSeen,false);assert.equal(telemetry.flight.airborne,true);
  const failure=logs.find(message=>/未观察到录像/.test(message));
  assert.ok(failure,'record diagnostic context when the empty shot is confirmed');
  for(const field of ['startReply=00','任务=dolly/0000000102','相机模式=无','录像状态=0','飞行模式=26','目标=11','配置=']){
    assert.ok(failure.includes(field),'failure diagnostic missing '+field);
  }
});

function emptyAirborneWaitFixture(){
  const {c}=fixture();let telemetry,completed=true;
  c.busyValue=false;
  const native={kind:'dolly',startedAtMs:1000,executionSeen:true,recordingSeen:false,
    executionObserved:false,activeOrUnknown:false,startReply:'00',config:{framing:'半身',zoom:3,retreat:true}};
  c.nativeTasks={canCompleteForHover:()=>({ok:completed}),snapshot:()=>native};
  c.captureMedia={canContinueVideoSequence:()=>false};c.session.snapshot=()=>({telemetry});
  const advance=now=>{telemetry={taskAgeMs:0,task:{observedAtMs:now,payloadHex:'0000000102'},
    flightAgeMs:0,flight:{observedAtMs:now,modeRaw:26,airborne:true,motorsOn:true},
    cameraAgeMs:0,camera:{observedAtMs:now,recordingCandidate:false,recordStateRaw:0,modeRaw:1},
    subject:{tracking:true,trackingAt:now,overlay:[{id:13}]}};};
  return {c,native,advance,telemetry:()=>telemetry,setCompleted:value=>{completed=value;}};
}

test('airborne empty-shot confirmation restarts after a gap in fresh camera idle evidence',async()=>{
  const f=emptyAirborneWaitFixture();
  await withCloseupClock(2000,now=>{
    f.advance(now);if(now>=2900&&now<3400) f.telemetry().cameraAgeMs=1001;
  },async now=>{
    await assert.rejects(AppController.prototype.waitForCloseupStep.call(f.c,()=>true,13,42),/未观察到录像/);
    assert.ok(now()>=5400,'the stale interval must reset the continuous confirmation');
    assert.ok(now()<5500,'fresh idle is confirmed two seconds after the gap');
  });
});

test('airborne empty-shot detection keeps unknown stale active busy and already-recorded evidence pending',async()=>{
  for(const condition of ['no-camera','stale-camera','pre-start-camera','future-camera','unknown-recording',
    'unknown-record-state','recording','active','incomplete','busy','recorded']){
    const f=emptyAirborneWaitFixture();
    await withCloseupClock(2000,now=>{
      f.advance(now);const camera=f.telemetry().camera;
      if(condition==='no-camera') f.telemetry().camera=undefined;
      if(condition==='stale-camera') f.telemetry().cameraAgeMs=1001;
      if(condition==='pre-start-camera') camera.observedAtMs=999;
      if(condition==='future-camera') camera.observedAtMs=now+100;
      if(condition==='unknown-recording') camera.recordingCandidate=undefined;
      if(condition==='unknown-record-state') camera.recordStateRaw=undefined;
      if(condition==='recording') {camera.recordingCandidate=true;camera.recordStateRaw=2;}
      if(condition==='active') {f.native.activeOrUnknown=true;f.native.executionObserved=true;}
      if(condition==='incomplete') f.setCompleted(false);
      if(condition==='busy') f.c.busyValue=true;
      if(condition==='recorded') f.native.recordingSeen=true;
    },async now=>{
      await assert.rejects(AppController.prototype.waitForCloseupStep.call(f.c,()=>now()<7000,13,42),/取消|变化/,condition);
    });
  }
});

test('recording observed during the terminal idle grace period is sealed rather than reported as an empty shot',async()=>{
  const f=emptyAirborneWaitFixture();
  f.c.captureMedia.canContinueVideoSequence=()=>f.native.recordingSeen&&f.telemetry().camera.recordingCandidate===false;
  await withCloseupClock(2000,now=>{
    f.advance(now);
    if(now>=3500) f.native.recordingSeen=true;
    if(now>=3500&&now<4300){f.telemetry().camera.recordingCandidate=true;f.telemetry().camera.recordStateRaw=2;f.setCompleted(false);}
    else f.setCompleted(true);
  },async now=>{
    await AppController.prototype.waitForCloseupStep.call(f.c,()=>now()<6000,13,42);
    assert.ok(now()>=4300,'late recording must finish before handing off');
  });
});
