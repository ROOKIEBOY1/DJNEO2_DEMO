const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {SubjectTaskWorkflow}=require('../entry/src/main/ets/core/domain/SubjectTaskWorkflow.ets');
const {CloseupSequence}=require('../entry/src/main/ets/core/domain/CloseupSequence.ets');
const {CloseupMediaGroup}=require('../entry/src/main/ets/core/media/CloseupMediaGroup.ets');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');

// Real controller observation/selection, real task workflow and real flight
// cancellation/finally-centering; only transport, video and cloud are replaced.
async function fixture({initialIds=[],initialSelected,afterTurnIds=[23],select,frameError,onAdvance,releaseDelayMs=150}={}){
  const c=Object.create(AppController.prototype),events=[];
  const flags={ids:initialIds,selected:initialSelected,turning:false,decoderEpoch:1,releaseAt:undefined};
  const record=(kind,detail={})=>events.push({kind,at:Date.now(),...detail});
  const boxes=()=>flags.ids.map(id=>({id,left:.1,top:.1,width:.2,height:.6}));
  const state=()=>({phase:'ready',deviceVerified:true,downlinkAgeMs:0,videoAgeMs:0,telemetry:{
    flightAgeMs:0,flight:{observedAtMs:Date.now(),airborne:true,motorsOn:true,modeRaw:flags.selected===undefined?6:26},
    taskAgeMs:0,task:{observedAtMs:Date.now(),phaseRaw:0,modeRaw:0,payloadHex:'0000000100'},
    cameraAgeMs:0,camera:{observedAtMs:Date.now(),recordingCandidate:false},
    subject:{candidates:boxes(),candidateCount:flags.ids.length,detectionAt:Date.now(),trackingAt:Date.now(),
      selectedIdCandidate:flags.selected,tracking:flags.selected!==undefined,overlay:boxes(),scanStateRaw:1,scanObservedAt:Date.now()}}});
  const session={sessionId:()=>10,snapshot:state,isReliableLinkFresh:()=>true,isActionLinkFresh:()=>true,
    requestFlight:async()=>Uint8Array.of(0),clearSubjectObservation(){},
    requestNative:async(receiver,set,id,payload)=>{
      assert.deepEqual([receiver,set,id,...payload],[0x92,0x0a,0xba,1,3,0]);
      record('cancel-subject');flags.releaseAt=Date.now()+releaseDelayMs;
      return Uint8Array.of(0);
    },
    setMovementAxes(axes){flags.turning=true;record('axes',{axes});},
    centerSticks:async()=>{record('center');if(flags.turning)flags.ids=afterTurnIds;flags.turning=false;}};
  Object.assign(c,{session,flight:new FlightCommandService(session),agentGeneration:0,agentRequestSequence:0,
    latestAgentRequestId:'',acceptedAgentRequestId:'',activeOperations:0,busyValue:false,lastErrorValue:'',lastErrorLayerValue:'',agentFeedback:'',
    nativeConfig:{radiusMeters:3,framing:'半身',zoom:2,retreat:true},defaultMovementSeconds:.5,
    groundDolly:new SubjectTaskWorkflow(()=>{}),closeupSequence:new CloseupSequence(()=>{}),closeupMedia:new CloseupMediaGroup(),
    captureMedia:{hasPending:()=>false},camera:{snapshot:()=>({operationActive:false,recordingRequested:false})},
    nativeTasks:{snapshot:()=>({kind:'none',busy:false,prepared:false,activeOrUnknown:false}),activeOrUnknown:()=>false,cancel(){}},
    video:{snapshot:()=>({state:'live',stats:{decoderEpoch:flags.decoderEpoch,waitingForKey:false}})},
    emit(){},log(message){record('log',{message});}});
  await c.flight.takeoff(true);
  const move=c.flight.move.bind(c.flight);
  c.flight.move=async(direction,seconds,...rest)=>{record('turn',{direction,seconds});return move(direction,seconds,...rest);};
  c.waitForAutomaticSubjectScan=async()=>{};c.pollAutoSubjectScan=async()=>{};
  c.captureVlmFrame=async()=>{
    record('frame',{ids:flags.ids.slice()});
    if(frameError&&events.some(e=>e.kind==='cloud'))throw new Error('frame capture failed');
    return {sessionId:10,capturedAtMs:Date.now(),candidatesObservedAtMs:Date.now(),
      jpeg:new ArrayBuffer(4),width:2,height:2,candidates:boxes(),currentSubjectId:flags.selected};
  };
  c.requestCloudAgentAction=async observation=>{
    record('cloud',{purpose:observation.purpose,ids:observation.frame?.candidates.map(b=>b.id)});
    const command=observation.purpose==='subject_selection'?
      await (select?select(observation,{c,events,flags}):{action:'select_subject',subjectId:flags.ids[0]}):
      {action:'circle',radiusMeters:3};
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

test('empty scan turns left for two seconds, settles, selects a new frame and waits for confirmation',async()=>{
  const f=await fixture();
  await replay(f,async()=>{
    const result=await f.c.runCloudVoiceRequest('跟随黑衣男生');
    assert.equal(result.confirmationRequired,true);
    assert.deepEqual(turns(f).map(e=>[e.direction,e.seconds]),[['turn_left',2]]);
    const turn=turns(f)[0],center=f.events.find(e=>e.kind==='center'&&e.at>=turn.at);
    assert.ok(center.at-turn.at>=2000);
    const visual=f.events.find(e=>e.kind==='cloud'&&e.purpose==='subject_selection');
    assert.deepEqual(visual.ids,[23]);assert.ok(visual.at-center.at>=500);
    assert.equal(f.c.groundDolly.snapshot().stage,'confirm');
    assert.equal(f.c.groundDolly.snapshot().subjectId,23);
    assert.equal(f.events.some(e=>e.kind==='execute'&&e.command.action==='circle'),false);
    await f.c.confirmSubjectTask();
    const executed=f.events.find(e=>e.kind==='execute'&&e.command.action==='circle');
    assert.equal(executed.command.subjectId,23);assert.equal(executed.command.radiusMeters,3);
  });
});

test('explicit VLM not_found turns and obtains a fresh candidate ID before selection',async()=>{
  let calls=0;
  const f=await fixture({initialIds:[11],afterTurnIds:[23],select:async observation=>{
    calls++;
    return calls===1?{action:'none',selectionStatus:'not_found',message:'画面里没有黑衣男生'}:
      {action:'select_subject',subjectId:23};
  }});
  await replay(f,async()=>{
    await f.c.runCloudVoiceRequest('环绕黑衣男生');
    const visuals=f.events.filter(e=>e.kind==='cloud'&&e.purpose==='subject_selection');
    assert.deepEqual(visuals.map(e=>e.ids),[[11],[23]]);
    assert.deepEqual(turns(f).map(e=>[e.direction,e.seconds]),[['turn_left',2]]);
    assert.deepEqual(selections(f).map(e=>e.command.subjectId),[23]);
    assert.equal(f.c.groundDolly.snapshot().stage,'confirm');
  });
});

for(const selectionStatus of ['ambiguous',undefined]){
  test(`${selectionStatus??'legacy none'} never authorizes a search turn`,async()=>{
    const f=await fixture({initialIds:[11,13],select:async()=>({action:'none',
      ...(selectionStatus?{selectionStatus}:{}),message:'请明确描述主体'})});
    await replay(f,async()=>{
      await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'));
      assert.ok(f.events.some(e=>e.kind==='cloud'&&e.purpose==='subject_selection'));
      assert.equal(turns(f).length,0);assert.equal(selections(f).length,0);
    });
  });
}

test('a VLM transport failure cannot authorize a turn',async()=>{
  const f=await fixture({initialIds:[11],select:async()=>{throw new Error('cloud transport failed');}});
  await replay(f,async()=>{
    await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'),/cloud transport failed/);
    assert.equal(turns(f).length,0);assert.equal(selections(f).length,0);
  });
});

test('a failed frame capture cannot authorize a turn or a visual request',async()=>{
  const f=await fixture({initialIds:[11],frameError:true});
  await replay(f,async()=>{
    await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'));
    assert.ok(f.events.some(e=>e.kind==='log'&&e.message.includes('frame capture failed')));
    assert.equal(turns(f).length,0);assert.equal(selections(f).length,0);
    assert.equal(f.events.some(e=>e.kind==='cloud'&&e.purpose==='subject_selection'),false);
  });
});

test('cancel during a real flight turn centers sticks and prevents later selection',async()=>{
  let cancelled=false;
  const f=await fixture({onAdvance:(_now,{c,flags})=>{
    if(flags.turning&&!cancelled){cancelled=true;c.cancelAgentAction();}
  }});
  await replay(f,async()=>{
    await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'));
    assert.equal(cancelled,true);assert.equal(turns(f).length,1);
    assert.ok(f.events.some(e=>e.kind==='center'),'Flight.move finally must center on cancellation');
    assert.equal(selections(f).length,0);
    assert.equal(f.events.some(e=>e.kind==='cloud'&&e.purpose==='subject_selection'),false);
    assert.equal(f.c.groundDolly.snapshot().stage,'cancelled');
  });
});

test('a VLM match arriving after cancellation is discarded without a selection command',async()=>{
  const f=await fixture({initialIds:[11],select:async(_observation,{c})=>{
    await new Promise(resolve=>queueMicrotask(()=>{c.cancelAgentAction();resolve();}));
    return {action:'select_subject',subjectId:11};
  }});
  await replay(f,async()=>{
    await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'));
    assert.equal(turns(f).length,0);assert.equal(selections(f).length,0);
    assert.equal(f.c.groundDolly.snapshot().stage,'cancelled');
  });
});

for(const phase of ['turn','settling','late VLM']){
  test(`manual movement during search ${phase} cancels search before further turns or selection`,async()=>{
    let manual;
    const issueManual=c=>{if(!manual)manual=c.move('right',.5);};
    const f=await fixture({initialIds:phase==='late VLM'?[11]:[],
      onAdvance:(_now,{c,events,flags})=>{
        const started=events.some(e=>e.kind==='turn'&&e.direction==='turn_left');
        if(phase==='turn'&&flags.turning&&started)issueManual(c);
        if(phase==='settling'&&started&&!flags.turning)issueManual(c);
      },select:async(_observation,{c})=>{
        if(phase==='late VLM'){issueManual(c);await manual;}
        return {action:'select_subject',subjectId:11};
      }});
    await replay(f,async()=>{
      await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'));
      assert.ok(manual,'the manual movement must actually interrupt the intended phase');await manual;
      assert.equal(f.c.lastErrorValue,'','manual movement should execute after interrupting search');
      assert.deepEqual(turns(f).filter(e=>e.direction==='right').map(e=>e.seconds),[.5]);
      assert.equal(turns(f).filter(e=>e.direction==='turn_left').length,phase==='late VLM'?0:1);
      assert.equal(selections(f).length,0);assert.equal(f.c.groundDolly.snapshot().stage,'cancelled');
    });
  });
}

test('a decoder epoch change during VLM identification discards the match',async()=>{
  const f=await fixture({initialIds:[11],select:async(_observation,{flags})=>{
    flags.decoderEpoch++;return {action:'select_subject',subjectId:11};
  }});
  await replay(f,async()=>{
    await assert.rejects(f.c.runCloudVoiceRequest('环绕黑衣男生'),/解码器|画面|变化/);
    assert.equal(turns(f).length,0);assert.equal(selections(f).length,0);
  });
});

test('a tracking-mode no-match releases tracking and waits for ordinary hover before turning',async()=>{
  let calls=0;
  const f=await fixture({initialIds:[11],initialSelected:11,releaseDelayMs:150,
    select:async()=>++calls===1?{action:'none',selectionStatus:'not_found',message:'目标不在画面'}:
      {action:'select_subject',subjectId:23}});
  await replay(f,async()=>{
    await f.c.runCloudVoiceRequest('环绕黑衣男生');
    const release=f.events.find(e=>e.kind==='cancel-subject'),hover=f.events.find(e=>e.kind==='ordinary-hover');
    assert.ok(release);assert.ok(hover);assert.ok(hover.at-release.at>=150);
    assert.ok(turns(f)[0].at>=hover.at,'a transport acknowledgement alone cannot authorize rotation in mode 26');
    assert.equal(turns(f).length,1);assert.deepEqual(selections(f).map(e=>e.command.subjectId),[23]);
    assert.equal(f.c.groundDolly.snapshot().stage,'confirm');
  });
});
