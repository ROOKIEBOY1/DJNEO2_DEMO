const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {CloseupSequence}=require('../entry/src/main/ets/core/domain/CloseupSequence.ets');
const {CloseupMediaGroup}=require('../entry/src/main/ets/core/media/CloseupMediaGroup.ets');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');
const {NativeTaskService}=require('../entry/src/main/ets/core/domain/NativeTaskService.ets');

async function withClock(body){
  let now=10000,advance=()=>{};
  const realNow=Date.now,realTimeout=global.setTimeout;
  Date.now=()=>now;
  global.setTimeout=(callback,delay)=>{now+=delay;advance();queueMicrotask(callback);return 0;};
  try{return await body({now:()=>now,onAdvance:fn=>{advance=fn;}});}
  finally{Date.now=realNow;global.setTimeout=realTimeout;}
}

// Let immediately resolved sends settle before advancing to a policy timeout.
async function withScheduledClock(body){
  let now=10000,nextId=1,scheduled,active=true;
  const timers=new Map(),advances=[];
  const realNow=Date.now,realTimeout=global.setTimeout,realClear=global.clearTimeout;
  const flush=()=>{
    scheduled=undefined;if(!active||timers.size===0)return;
    const [id,timer]=[...timers].sort((a,b)=>a[1].at-b[1].at||a[0]-b[0])[0];
    timers.delete(id);now=Math.max(now,timer.at);for(const fn of advances)fn();
    timer.callback();if(timers.size>0)schedule();
  };
  const schedule=()=>{if(scheduled===undefined)scheduled=setImmediate(flush);};
  Date.now=()=>now;
  global.setTimeout=(callback,delay)=>{
    const id=nextId++;timers.set(id,{at:now+delay,callback});schedule();return id;
  };
  global.clearTimeout=id=>timers.delete(id);
  try{return await body({now:()=>now,onAdvance:fn=>advances.push(fn)});}
  finally{
    active=false;if(scheduled!==undefined)clearImmediate(scheduled);
    Date.now=realNow;global.setTimeout=realTimeout;global.clearTimeout=realClear;
  }
}

// Keep the controller's sequence, action validation, subject-task handoff and
// readiness wait real. Only camera/media and aircraft command boundaries are fake.
function fixture(clock,frameChange=frame=>frame,options={}){
  const c=Object.create(AppController.prototype),events=[];
  const target=13;
  let mode=26,tracking=true,selected=13,running=false,completedAt,readyAt;
  let pending=true,starts=0,sessionGeneration=4,manual=false;
  const box=id=>({id,left:0.2,top:0.2,width:0.2,height:0.5});
  const advance=()=>{
    if(readyAt!==undefined&&clock.now()>=readyAt){mode=26;readyAt=undefined;}
    if(completedAt!==undefined&&clock.now()>=completedAt){
      running=false;completedAt=undefined;mode=6;tracking=false;selected=undefined;
      events.push('terminal:'+c.nativeTasks.kind);
    }
  };
  clock.onAdvance(advance);
  const telemetry=()=>{
    advance();
    const now=clock.now();
    const terminal=starts>0&&!running;
    return {flightAgeMs:0,taskAgeMs:0,cameraAgeMs:0,
      flight:{modeRaw:mode,airborne:true,motorsOn:true,observedAtMs:now},
      task:{phaseRaw:manual?5:running?5:0,modeRaw:manual?9:running?(c.nativeTasks.kind==='circle'?5:13):0,
        payloadHex:running?(c.nativeTasks.kind==='circle'?'0505000100':'050d000100'):
          manual?'0509000100':terminal?'0000000102':'0000000100',observedAtMs:now},
      camera:{recordingCandidate:running,recordStateRaw:running?1:0,observedAtMs:now},
      subject:{tracking,overlay:tracking?[box(selected)]:[],selectedIdCandidate:selected,
        candidates:[box(target)],candidateCount:1,detectionAt:now,trackingAt:now}};
  };
  const session={sessionId:()=>10,isReliableLinkFresh:()=>true,isActionLinkFresh:()=>true,
    snapshot:()=>({phase:'ready',generation:sessionGeneration,deviceVerified:true,
      downlinkAgeMs:0,videoAgeMs:0,telemetry:telemetry()})};
  const flight=new FlightCommandService(session);
  flight.takeoffSentValue=true;flight.takeoffAcknowledgedValue=true;flight.generationValue=2;
  const camera={snapshot:()=>({operationActive:false,recordingRequested:running})};
  const native=new NativeTaskService(session,flight,camera);
  if(options.manualAfterTerminal){
    const completed=native.canCompleteForHover.bind(native);
    native.canCompleteForHover=()=>{
      const result=completed();
      if(result.ok&&native.kind==='dolly'&&starts===1&&!manual){
        manual=true;events.push('manual-after-terminal');
      }
      return result;
    };
  }
  Object.assign(c,{session,flight,camera,nativeTasks:native,agentGeneration:0,
    activeOperations:0,busyValue:false,lastErrorValue:'',agentFeedback:'',
    agentMediaUris:[],agentMediaUri:'',agentMediaKind:'video',agentVideoResultReady:false,
    nativeConfig:{radiusMeters:2,framing:'半身',zoom:3,retreat:true},
    closeupSequence:new CloseupSequence(()=>{}),closeupMedia:new CloseupMediaGroup(),emit(){},
    log(message){if(message.startsWith('运镜启动状态已同步'))events.push('ready:'+native.kind);},
    video:{snapshot:()=>({state:'live',stats:{running:true,waitingForKey:false,
      lastAssembledAgeMs:0,lastRenderedAgeMs:0,renderedFrames:Math.floor(clock.now()/100),
      recoveryPaused:false,decoderEpoch:1}})},
    captureMedia:{beginVideoSequence:async()=>{events.push('baseline');return 42;},
      hasPending:()=>pending,isVideoSequenceCurrent:id=>id===42&&pending,
      canContinueVideoSequence:id=>id===42&&starts>0&&!running,
      finishVideoSequence(){events.push('return-media');pending=false;c.agentVideoResultReady=true;
        c.agentMediaUris=['dolly.mp4','circle.mp4'];},
      releaseVideoSequence(){events.push('release-media');}}});
  const observation=()=>({requestId:'frame-'+events.length,sessionId:10,flightGeneration:2,
    controlGeneration:0,requestedAtMs:clock.now(),context:{phase:'ready',airborne:true,
      flightStateFresh:true,flightMode:mode,tracking,currentSubjectId:tracking?selected:undefined,
      taskKind:native.kind,taskPrepared:false,taskActive:running,cameraIdle:!running,
      recording:running,radiusMeters:2,framing:'半身',zoom:3,retreat:true,movementSeconds:0.5},
    frame:{sessionId:10,capturedAtMs:clock.now(),candidatesObservedAtMs:clock.now(),
      jpeg:Uint8Array.of(0xff,0xd8,0xff,0xd9).buffer,width:2,height:2,candidates:[box(target)],
      currentSubjectId:tracking?selected:undefined}});
  native.prepareHover=async(kind,config)=>{
    events.push('prepare:'+kind);native.kind=kind;native.config=config;native.prepared=true;
    return {ok:true,data:true};
  };
  c.requestHoverSubjectScan=async()=>{
    events.push('scan:'+native.kind);manual=false;
    return {ok:true,data:true};
  };
  c.requestSubjectSelection=async(token,id)=>{
    assert.equal(token.isCancelled(),false);
    if(id===undefined){events.push('cancel:'+native.kind);tracking=false;selected=undefined;mode=6;}
    else{
      assert.equal(id,target);events.push('select:'+native.kind);tracking=true;selected=id;mode=6;
      readyAt=clock.now()+100;
    }
    return {ok:true,data:'00'};
  };
  c.startNativeWithCapture=async(token,id,sequence)=>{
    assert.equal(token.isCancelled(),false);assert.equal(id,target);assert.equal(sequence,42);
    assert.equal(mode,26,'the real readiness wait must see mode 26 before starting');
    assert.equal(tracking,true);assert.equal(flight.snapshot().nativeTaskMayFly,false);
    events.push('start:'+native.kind);starts++;running=true;completedAt=clock.now()+200;
    native.startedAt=clock.now();native.executionSeen=true;native.recordingSeen=true;
    flight.markNativeTaskMayFly(clock.now());
    return {ok:true,data:'started'};
  };
  c.captureAgentObservation=async(requireTracking)=>{
    events.push('capture');assert.equal(requireTracking,false,'ordinary hover must capture real candidates');
    assert.equal(mode,6);assert.equal(tracking,false);
    const obs=observation();obs.frame=frameChange(obs.frame);
    return obs;
  };
  return {c,events,observation,reconnect:()=>{sessionGeneration++;},
    completedDolly(){
      starts=1;mode=6;tracking=false;selected=undefined;running=false;
      native.kind='dolly';native.startedAt=clock.now()-200;
      native.executionSeen=true;native.recordingSeen=true;
      flight.markNativeTaskMayFly(native.startedAt);
    },
    run:()=>c.runCloseupSequence(observation(),{action:'dolly_zoom',recipe:'dolly_circle',
      subjectId:target,framing:'半身',zoom:3,retreat:true})};
}

test('completed dolly in ordinary hover captures the original candidate, relocks, waits ready, then starts circle',async()=>{
  await withClock(async clock=>{
    const f=fixture(clock);await f.run();
    const {events}=f;
    assert.deepEqual(events.filter(x=>x.startsWith('start:')),['start:dolly','start:circle']);
    assert.equal(events.filter(x=>x==='capture').length,1,'use one fresh candidate image before locking');
    const capture=events.indexOf('capture'),select=events.indexOf('select:circle');
    const ready=events.indexOf('ready:circle'),start=events.indexOf('start:circle');
    assert.ok(capture>=0&&capture<select&&select<ready&&ready<start,events.join(' -> '));
    assert.equal(events.slice(capture,start).some(x=>x.startsWith('cancel:')),false,
      'do not lock then cancel and lock again during the circle handoff');
    assert.equal(f.c.closeupSequence.snapshot().stage,'completed');
    assert.deepEqual(f.c.agentMediaUris,['dolly.mp4','circle.mp4']);
  });
});

for(const [label,frameChange]of [
  ['stale new image',frame=>({...frame,capturedAtMs:frame.capturedAtMs-2000})],
  ['cached image from before this handoff',frame=>({...frame,capturedAtMs:10000})],
  ['stale candidate report',frame=>({...frame,candidatesObservedAtMs:frame.candidatesObservedAtMs-600})],
  ['different candidate',frame=>({...frame,candidates:frame.candidates.map(box=>({...box,id:11}))})],
  ['different image session',frame=>({...frame,sessionId:11})],
  ['empty image',frame=>({...frame,jpeg:new ArrayBuffer(0)})]
]){
  test('ordinary-hover handoff does not lock or start circle with '+label,async()=>{
    await withClock(async clock=>{
      const f=fixture(clock,frameChange);
      await assert.rejects(f.run(),/画面|主体|跟踪|候选|会话|未启动/);
      assert.equal(f.events.includes('capture'),true,'exercise image validation after verified ordinary hover');
      assert.equal(f.events.includes('select:circle'),false);
      assert.equal(f.events.includes('start:circle'),false);
      assert.equal(f.events.includes('return-media'),false);
    });
  });
}

test('reconnection with the same public session ID invalidates a pending handoff image',async()=>{
  await withClock(async clock=>{
    const f=fixture(clock),capture=f.c.captureAgentObservation;
    f.c.captureAgentObservation=async(...args)=>{const obs=await capture(...args);f.reconnect();return obs;};
    await assert.rejects(f.run(),/取消|变化|会话/);
    assert.equal(f.events.includes('capture'),true);
    assert.equal(f.events.includes('select:circle'),false);
    assert.equal(f.events.includes('start:circle'),false);
  });
});

test('observed terminal followed by fresh manual mode 9 reuses the real completed-task handoff',async()=>{
  await withClock(async clock=>{
    const f=fixture(clock,frame=>frame,{manualAfterTerminal:true});await f.run();
    assert.equal(f.events.includes('manual-after-terminal'),true);
    const capture=f.events.indexOf('capture'),select=f.events.indexOf('select:circle');
    const ready=f.events.indexOf('ready:circle'),start=f.events.indexOf('start:circle');
    assert.ok(capture>=0&&capture<select&&select<ready&&ready<start,f.events.join(' -> '));
    assert.equal(f.c.closeupSequence.snapshot().stage,'completed');
  });
});

test('direct handoff wait returns an untracked real image and never locks before the task handoff',async()=>{
  await withClock(async clock=>{
    const f=fixture(clock);f.completedDolly();
    const obs=await f.c.waitForCloseupTarget(()=>true,13);
    assert.equal(obs.frame.currentSubjectId,undefined);
    assert.equal(obs.context.tracking,false);
    assert.equal(obs.frame.candidates[0].id,13);
    assert.deepEqual(f.events,['capture']);
  });
});

test('direct handoff wait rejects a reconnected generation even when its caller gate stays true',async()=>{
  await withClock(async clock=>{
    const f=fixture(clock);f.completedDolly();const capture=f.c.captureAgentObservation;
    f.c.captureAgentObservation=async(...args)=>{const obs=await capture(...args);f.reconnect();return obs;};
    await assert.rejects(f.c.waitForCloseupTarget(()=>true,13),/取消|变化|会话/);
    assert.equal(f.events.includes('capture'),true);
    assert.equal(f.events.some(event=>event.startsWith('select:')),false);
  });
});

test('ordinary-hover closeup automatically requests recovery and waits for both the new keyframe and rendered pixels',async()=>{
  await withScheduledClock(async clock=>{
    const f=fixture(clock);let requestedAt,keyAccepted=false,rendered=false,renderedAt;
    f.c.videoSessionEnabled=true;f.c.keyframeClock=clock.now;
    f.c.confirmAgentAction=async()=>{throw Error('automatic handoff must not ask for another confirmation');};
    f.c.session.requestVideoKeyframe=async reason=>{
      assert.equal(reason,'automatic');f.events.push('key-request');requestedAt=clock.now();
    };
    clock.onAdvance(()=>{
      if(requestedAt!==undefined&&clock.now()>=requestedAt+200&&!keyAccepted){
        keyAccepted=true;f.events.push('new-key');
      }
      if(requestedAt!==undefined&&clock.now()>=requestedAt+400&&!rendered){
        rendered=true;renderedAt=clock.now();f.events.push('new-pixels');
      }
    });
    const preview=f.c.video.snapshot,capture=f.c.captureAgentObservation;
    f.c.video.snapshot=()=>{
      if(!f.events.includes('terminal:dolly')||f.events.includes('start:circle'))return preview();
      return {state:rendered?'live':'waiting_key',stats:{running:true,waitingForKey:!keyAccepted,
        lastAssembledAgeMs:0,recoveryPaused:false,decoderEpoch:2,lastResetReason:'decode-stall',
        assembledFrames:10,submittedFrames:0,decodedFrames:rendered?1+Math.floor((clock.now()-renderedAt)/100):0,
        renderedFrames:rendered?1+Math.floor((clock.now()-renderedAt)/100):0,
        lastRenderedAgeMs:rendered?0:-1,acceptedRandomAccessFrames:keyAccepted?1:0,lastError:''}};
    };
    f.c.captureAgentObservation=async(...args)=>{
      assert.equal(keyAccepted,true);assert.equal(rendered,true);
      return capture(...args);
    };
    await f.run();
    assert.equal(f.events.filter(event=>event==='key-request').length,1);
    const events=f.events;
    assert.ok(events.indexOf('key-request')<events.indexOf('new-key'));
    assert.ok(events.indexOf('new-key')<events.indexOf('new-pixels'));
    assert.ok(events.indexOf('new-pixels')<events.indexOf('capture'));
    assert.ok(events.indexOf('capture')<events.indexOf('select:circle'));
    assert.equal(f.c.closeupSequence.snapshot().stage,'completed');
    assert.ok(clock.now()<16000,'successful automatic recovery stays within a bounded handoff');
  });
});

test('camera activity, loss of airborne hover or cancellation during the new image readback blocks relocking',async()=>{
  for(const change of ['camera','flight','cancel']){
    await withClock(async clock=>{
      const f=fixture(clock),capture=f.c.captureAgentObservation;
      f.c.captureAgentObservation=async(...args)=>{
        const obs=await capture(...args);
        if(change==='camera')f.c.camera.snapshot=()=>({operationActive:true,recordingRequested:false});
        if(change==='flight'){
          const snapshot=f.c.session.snapshot;
          f.c.session.snapshot=()=>{const state=snapshot();return {...state,telemetry:{...state.telemetry,
            flight:{...state.telemetry.flight,airborne:false,motorsOn:false}}};};
        }
        if(change==='cancel')f.c.agentGeneration++;
        return obs;
      };
      await assert.rejects(f.run(),/取消|变化|悬停|失效/);
      assert.equal(f.events.includes('capture'),true);
      assert.equal(f.events.includes('select:circle'),false,change);
      assert.equal(f.events.includes('start:circle'),false,change);
      assert.ok(clock.now()<12000,'reject changed ownership immediately after readback');
    });
  }
});
