const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {SubjectTaskWorkflow}=require('../entry/src/main/ets/core/domain/SubjectTaskWorkflow.ets');
const {CloseupSequence}=require('../entry/src/main/ets/core/domain/CloseupSequence.ets');
const {CloseupMediaGroup}=require('../entry/src/main/ets/core/media/CloseupMediaGroup.ets');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');

// Real controller observation/selection, real task workflow and real flight
// cancellation/finally-centering; only transport, video and cloud are replaced.
async function fixture({initialIds=[],initialSelected,afterTurnIds=[23],select,frameError,onAdvance,releaseDelayMs=150,preview,readFrame,inferredSubjectId}={}){
  const c=Object.create(AppController.prototype),events=[];
  const flags={ids:initialIds,selected:initialSelected,turning:false,decoderEpoch:1,releaseAt:undefined,centerAt:undefined,reliable:true,actionFresh:true,paused:false};
  const record=(kind,detail={})=>events.push({kind,at:Date.now(),...detail});
  const boxes=()=>flags.ids.map(id=>({id,left:.1,top:.1,width:.2,height:.6}));
  const state=()=>({phase:'ready',deviceVerified:true,downlinkAgeMs:0,videoAgeMs:0,telemetry:{
    flightAgeMs:0,flight:{observedAtMs:Date.now(),airborne:true,motorsOn:true,modeRaw:flags.selected===undefined?6:26},
    taskAgeMs:0,task:{observedAtMs:Date.now(),phaseRaw:0,modeRaw:0,payloadHex:'0000000100'},
    cameraAgeMs:0,camera:{observedAtMs:Date.now(),recordingCandidate:false},
    subject:{candidates:boxes(),candidateCount:flags.ids.length,detectionAt:Date.now(),trackingAt:Date.now(),
      selectedIdCandidate:flags.selected,tracking:flags.selected!==undefined,overlay:boxes(),scanStateRaw:1,scanObservedAt:Date.now()}}});
  const session={sessionId:()=>10,snapshot:state,isReliableLinkFresh:()=>flags.reliable,isActionLinkFresh:()=>flags.actionFresh,
    requestVideoKeyframe:async reason=>record('key-request',{reason}),
    requestFlight:async()=>Uint8Array.of(0),clearSubjectObservation(){},
    requestNative:async(receiver,set,id,payload)=>{
      assert.deepEqual([receiver,set,id,...payload],[0x92,0x0a,0xba,1,3,0]);
      record('cancel-subject');flags.releaseAt=Date.now()+releaseDelayMs;
      return Uint8Array.of(0);
    },
    setMovementAxes(axes){flags.turning=true;record('axes',{axes});},
    centerSticks:async()=>{record('center');if(flags.turning){flags.ids=afterTurnIds;flags.centerAt=Date.now();}flags.turning=false;}};
  Object.assign(c,{session,flight:new FlightCommandService(session),agentGeneration:0,agentRequestSequence:0,
    latestAgentRequestId:'',acceptedAgentRequestId:'',activeOperations:0,busyValue:false,lastErrorValue:'',lastErrorLayerValue:'',agentFeedback:'',
    nativeConfig:{radiusMeters:3,framing:'半身',zoom:2,retreat:true},defaultMovementSeconds:.5,
    groundDolly:new SubjectTaskWorkflow(()=>{}),closeupSequence:new CloseupSequence(()=>{}),closeupMedia:new CloseupMediaGroup(),
    voice:{cancelPending(){}},captureMedia:{hasPending:()=>false},camera:{snapshot:()=>({operationActive:false,recordingRequested:false})},
    nativeTasks:{snapshot:()=>({kind:'none',busy:false,prepared:false,activeOrUnknown:false}),activeOrUnknown:()=>false,cancel(){}},
    videoSessionEnabled:true,keyframeClock:()=>Date.now(),
    video:{snapshot:()=>preview?preview({now:Date.now(),flags}):freshPreview(Date.now(),flags.decoderEpoch),
      restart(){record('restart');throw Error('automatic search must not restart paused decoder');}},
    emit(){},log(message){record('log',{message});}});
  await c.flight.takeoff(true);
  const move=c.flight.move.bind(c.flight);
  c.flight.move=async(direction,seconds,...rest)=>{record('turn',{direction,seconds});return move(direction,seconds,...rest);};
  c.waitForAutomaticSubjectScan=async()=>{};c.pollAutoSubjectScan=async()=>{};
  c.captureVlmFrame=async(deadline,minimumCapturedAtMs,checkCurrent)=>{
    record('frame',{ids:flags.ids.slice()});
    if(readFrame)await readFrame({c,events,flags,record,deadline,minimumCapturedAtMs,checkCurrent});
    if(frameError&&events.some(e=>e.kind==='cloud'))throw new Error('frame capture failed');
    return {sessionId:10,capturedAtMs:Date.now(),candidatesObservedAtMs:Date.now(),
      jpeg:new ArrayBuffer(4),width:2,height:2,candidates:boxes(),currentSubjectId:flags.selected};
  };
  c.requestCloudAgentAction=async observation=>{
    record('cloud',{purpose:observation.purpose,ids:observation.frame?.candidates.map(b=>b.id)});
    const command=observation.purpose==='subject_selection'?
      await (select?select(observation,{c,events,flags}):{action:'select_subject',subjectId:flags.ids[0]}):
      {action:'circle',radiusMeters:3,...(inferredSubjectId===undefined?{}:{subjectId:inferredSubjectId})};
    return {version:2,requestId:observation.requestId,command};
  };
  c.requestAgentExecution=async(observation,command)=>{
    c.ensureAgentObservation(observation,command);
    record('execute',{command:{...command}});
    if(command.action==='select_subject'){flags.selected=command.subjectId;c.selectedSubjectId=command.subjectId;}
    return {message:'已执行'};
  };
  return {c,events,flags,advance:now=>{
    if(flags.releaseAt!==undefined&&now>=flags.releaseAt){flags.releaseAt=undefined;flags.selected=undefined;record('ordinary-hover');}
    onAdvance?.(now,{c,events,flags});
  }};
}

async function replay(f,body){
  let now=Date.UTC(2026,10,12,10);
  const realNow=Date.now,realTimeout=global.setTimeout;
  Date.now=()=>now;
  global.setTimeout=(callback,delay,...args)=>{now+=Number(delay)||0;f.advance(now);queueMicrotask(()=>callback(...args));return 0;};
  try{return await body();}finally{Date.now=realNow;global.setTimeout=realTimeout;}
}
const turns=f=>f.events.filter(e=>e.kind==='turn');
const selections=f=>f.events.filter(e=>e.kind==='execute'&&e.command.action==='select_subject');

// Full native snapshot: input can continue while decoded/rendered output freezes.
function freshPreview(now,epoch=1){
  const count=100+Math.floor(now/50);
  return {state:'live',label:'实时画面',stats:{running:true,waitingForKey:false,recoveryPaused:false,
    queued:0,queuedBytes:0,queueDrops:0,assembledFrames:count,submittedFrames:count,
    decodedFrames:count,renderedFrames:count,decodeErrors:0,suppressedParameters:0,reorderedFrames:0,
    width:1280,height:720,lastAssembledAgeMs:0,lastSubmittedAgeMs:0,lastDecodedAgeMs:now%50,
    lastRenderedAgeMs:now%50,lastError:'',decoderEpoch:epoch,consecutiveFailures:0,
    configurationRetained:true,waitingForKeyAgeMs:-1,lastResetReason:'',parameterMask:7,
    randomAccessFrames:1,acceptedRandomAccessFrames:1}};
}
function stalledAfterTurn({now,flags}){
  const p=freshPreview(now,flags.decoderEpoch);
  if(flags.centerAt===undefined||now>=flags.centerAt+969)return p;
  const renderedAt=flags.centerAt-1779;
  p.stats.renderedFrames=100+Math.floor(renderedAt/50);
  p.stats.decodedFrames=p.stats.renderedFrames;
  p.stats.lastRenderedAgeMs=now-renderedAt;p.stats.lastDecodedAgeMs=now-renderedAt;
  p.state=p.stats.lastRenderedAgeMs>2000?'stale':'live';return p;
}

test('16:50:58.972 replay: output crosses stale during settling then recovers to confirmation without another turn',async()=>{
  const f=await fixture({preview:stalledAfterTurn});
  await replay(f,async()=>{
    const result=await f.c.runCloudVoiceRequest('环绕黑衣男生');
    assert.equal(result.confirmationRequired,true);
    assert.deepEqual(turns(f).map(e=>[e.direction,e.seconds]),[['turn_left',2]]);
    const visual=f.events.find(e=>e.kind==='cloud'&&e.purpose==='subject_selection');
    assert.deepEqual(visual.ids,[23]);
    assert.ok(visual.at>=f.flags.centerAt+969+500+500,'recover output for 500ms then rebuild a full telemetry settle window');
    assert.deepEqual(selections(f).map(e=>e.command.subjectId),[23]);
    assert.equal(f.c.groundDolly.snapshot().stage,'confirm');
    assert.equal(f.events.some(e=>e.kind==='restart'),false);
    assert.equal(f.events.some(e=>e.kind==='execute'&&e.command.action==='circle'),false,'confirmation stays mandatory');
    await f.c.confirmSubjectTask();
    const command=f.events.find(e=>e.kind==='execute'&&e.command.action==='circle').command;
    assert.equal(command.subjectId,23);assert.equal(command.radiusMeters,3);
  });
});

const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function unavailable(reason='readback_timeout'){
  const {SubjectSearchFrameUnavailable}=require('../entry/src/main/ets/core/domain/SubjectSearchPicture.ets');
  return new SubjectSearchFrameUnavailable(reason,'temporary readback unavailable');
}

test('16:52:57.404 replay: 600ms readback timeout waits for output at +1033ms and retries the same view',async()=>{
  let attempts=0;
  const f=await fixture({preview:({now,flags})=>{
    const p=freshPreview(now,flags.decoderEpoch);
    if(flags.failedReadAt!==undefined&&now<flags.failedReadAt+1033){
      const renderedAt=flags.failedReadAt-50;
      p.stats.renderedFrames=100+Math.floor(renderedAt/50);
      p.stats.lastRenderedAgeMs=now-renderedAt;
    }
    return p;
  },readFrame:async({flags,record})=>{
    if(flags.centerAt===undefined)return;
    attempts++;
    if(attempts===1){flags.failedReadAt=Date.now();await delay(600);record('readback-timeout');throw unavailable();}
  }});
  await replay(f,async()=>{
    const result=await f.c.runCloudVoiceRequest('环绕黑衣男生');
    assert.equal(result.confirmationRequired,true);assert.equal(attempts,2);
    assert.equal(turns(f).length,1);assert.deepEqual(selections(f).map(e=>e.command.subjectId),[23]);
    const visual=f.events.find(e=>e.kind==='cloud'&&e.purpose==='subject_selection');
    assert.ok(visual.at>=f.flags.failedReadAt+1033+500);
    assert.equal(f.c.groundDolly.snapshot().stage,'confirm');
    assert.equal(f.events.some(e=>e.kind==='restart'),false);
  });
});

function frozenAfterTurn({now,flags}){
  const p=stalledAfterTurn({now:flags.centerAt===undefined?now:Math.min(now,flags.centerAt+968),flags});
  // Keep input current even when no decoder output ever advances.
  const input=freshPreview(now,flags.decoderEpoch);
  p.stats.assembledFrames=input.stats.assembledFrames;p.stats.submittedFrames=input.stats.submittedFrames;
  if(flags.centerAt!==undefined){p.stats.lastRenderedAgeMs=now-(flags.centerAt-1779);
    p.state=p.stats.lastRenderedAgeMs>2000?'stale':'live';}
  return p;
}

for(const interrupt of ['cancel','land','control stale','manual move']){
  test(interrupt+' while recovering exits before any further search turn or selection',async()=>{
    let triggered=false,pending;
    const f=await fixture({preview:frozenAfterTurn,onAdvance:(now,{c,flags})=>{
      if(triggered||flags.centerAt===undefined||now-flags.centerAt<300)return;
      triggered=true;
      if(interrupt==='cancel')c.cancelAgentAction();
      if(interrupt==='land')pending=c.land();
      if(interrupt==='control stale')flags.reliable=false;
      if(interrupt==='manual move')pending=c.move('right',.5);
    }});
    await replay(f,async()=>{
      await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'));
      if(pending)await pending;
      assert.equal(triggered,true);assert.equal(selections(f).length,0);
      assert.equal(turns(f).filter(e=>e.direction==='turn_left').length,1);
      assert.equal(f.events.some(e=>e.kind==='cloud'&&e.purpose==='subject_selection'),false);
      if(interrupt==='land')assert.equal(f.c.flight.snapshot().landRequested,true);
      if(interrupt==='manual move')assert.equal(turns(f).filter(e=>e.direction==='right').length,1);
    });
  });
}

test('paused decoder fails closed without automatically restarting it',async()=>{
  const f=await fixture({preview:({now,flags})=>{
    const p=frozenAfterTurn({now,flags});
    if(flags.centerAt!==undefined){p.stats.recoveryPaused=true;p.state='error';p.stats.lastError='failure budget exhausted';}
    return p;
  }});
  await replay(f,async()=>{
    await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'));
    assert.equal(turns(f).length,1);assert.equal(selections(f).length,0);
    assert.equal(f.events.some(e=>e.kind==='restart'),false);
    assert.equal(f.events.some(e=>e.kind==='key-request'),false);
  });
});

test('permanent render freeze exhausts one 15s picture budget while keeping sticks centered',async()=>{
  const f=await fixture({preview:frozenAfterTurn});
  await replay(f,async()=>{
    await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'));
    const elapsed=Date.now()-f.flags.centerAt;
    assert.ok(elapsed>=15000,'a transient freeze gets its full recovery allowance');
    assert.ok(elapsed<=15100,'waiting cannot renew the 15 second allowance');
    assert.equal(turns(f).length,1);assert.equal(selections(f).length,0);
    assert.equal(f.c.flight.snapshot().movementActive,false);
    assert.ok(f.events.some(e=>e.kind==='key-request'&&e.reason==='automatic'),'use the existing keyframe recovery mechanism');
  });
});

test('repeated typed readback timeouts share one picture budget and never add a turn',async()=>{
  let attempts=0,firstFailure;
  const f=await fixture({readFrame:async({flags,deadline})=>{
    if(flags.centerAt===undefined)return;
    attempts++;await delay(Math.min(600,Math.max(0,(deadline??Infinity)-Date.now())));firstFailure??=Date.now();throw unavailable();
  }});
  await replay(f,async()=>{
    await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'));
    assert.ok(attempts>1,'retry transient readback on this view');
    assert.ok(Date.now()-firstFailure<=15000,'retry never renews the first picture deadline');
    assert.equal(turns(f).length,1);assert.equal(selections(f).length,0);
  });
});

test('plain frame faults remain fatal and cannot be classified by their error text',async()=>{
  let attempts=0;
  const f=await fixture({readFrame:async({flags})=>{
    if(flags.centerAt===undefined)return;
    attempts++;throw new Error('temporary readback unavailable decoder timeout');
  }});
  await replay(f,async()=>{
    await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'),/temporary readback/);
    assert.equal(attempts,1);assert.equal(turns(f).length,1);assert.equal(selections(f).length,0);
  });
});

test('decoder epoch changes during VLM discard the old matched ID without a selection command',async()=>{
  const f=await fixture({initialIds:[11],select:async(_observation,{flags})=>{
    flags.decoderEpoch++;flags.ids=[23];return {action:'select_subject',subjectId:11};
  }});
  await replay(f,async()=>{
    await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'));
    assert.equal(turns(f).length,0);assert.equal(selections(f).length,0);
  });
});


test('typed decoder change discards the inferred subject ID and asks VLM again on this view',async()=>{
  let failed=false;
  const f=await fixture({initialIds:[11],inferredSubjectId:11,
    readFrame:async({c,flags})=>{
      if(c.subjectSearch?.snapshot().active!==true||failed)return;
      failed=true;flags.ids=[23];flags.decoderEpoch++;
      throw unavailable('decoder_changed');
    }});
  await replay(f,async()=>{
    const result=await f.c.runCloudVoiceRequest('环绕黑衣男生');
    assert.equal(result.confirmationRequired,true);assert.equal(failed,true);
    assert.equal(turns(f).length,0);
    const visuals=f.events.filter(e=>e.kind==='cloud'&&e.purpose==='subject_selection');
    assert.deepEqual(visuals.map(e=>e.ids),[[23]],'a fault invalidates the pre-fault model inference');
    assert.deepEqual(selections(f).map(e=>e.command.subjectId),[23]);
  });
});

test('picture recovery cannot outlive the original global search deadline',async()=>{
  const f=await fixture({preview:frozenAfterTurn});
  await replay(f,async()=>{
    const start=Date.now();f.flags.centerAt=start;
    await assert.rejects(f.c.waitForSubjectSearchPicture(()=>{},start+275,true));
    assert.ok(Date.now()-start<=300,'the global deadline overrides the local 15s allowance');
    assert.equal(turns(f).length,0);assert.equal(selections(f).length,0);
  });
});
