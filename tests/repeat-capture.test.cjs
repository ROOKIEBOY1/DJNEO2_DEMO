const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {SubjectTaskWorkflow}=require('../entry/src/main/ets/core/domain/SubjectTaskWorkflow.ets');
const {CloseupSequence}=require('../entry/src/main/ets/core/domain/CloseupSequence.ets');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');
const {CancellationToken}=require('../entry/src/main/ets/core/domain/OperationResult.ets');
const {CaptureMedia}=require('../entry/src/main/ets/core/media/CaptureMedia.ets');
const {CloseupMediaGroup}=require('../entry/src/main/ets/core/media/CloseupMediaGroup.ets');
const {AGENT_TEXT_TIMEOUT_MS}=require('../entry/src/main/ets/core/domain/AgentAction.ets');

function fixture({missedOriginal=false}={}){
  const c=Object.create(AppController.prototype),events=[],downloads=[];
  const old={path:'old.MP4',kind:'video',size:100};
  const a={path:'a.MP4',kind:'video',size:200};
  const b={path:'b.MP4',kind:'video',size:300};
  let now=Date.now()+10,airborne=false,recording=false,selected,startedAt;
  let request=0,takeoffs=0,starts=0,queries=0,recipe='dolly_circle',interruption=true;
  let entries=[old],listFailure=false,waitHook;
  const observedAt=()=>Math.max(now,Date.now()+1);
  const session={sessionId:()=>10,isReliableLinkFresh:()=>true,isActionLinkFresh:()=>true,
    clearSubjectObservation(){selected=undefined;},
    requestFlight:async action=>{
      assert.equal(action,1);takeoffs++;events.push(['takeoff',takeoffs]);airborne=true;
      return Uint8Array.of(0);
    },
    initialize:async()=>{events.push(['initialize']);throw Error('unexpected reinitialization');},
    snapshot:()=>({phase:'ready',deviceVerified:true,downlinkAgeMs:0,videoAgeMs:0,telemetry:{
      flightAgeMs:0,flight:{airborne,motorsOn:airborne,modeRaw:selected===undefined?6:26,observedAtMs:observedAt()},
      taskAgeMs:0,task:{phaseRaw:0,modeRaw:0,payloadHex:'0000000100',observedAtMs:observedAt()},
      cameraAgeMs:0,camera:{recordingCandidate:recording,observedAtMs:observedAt()},
      subject:{candidates:[{id:13}],candidateCount:1,detectionAt:Date.now(),trackingAt:Date.now(),
        tracking:selected!==undefined,overlay:selected===undefined?[]:[{id:selected}],selectedIdCandidate:selected}
    }})};
  const repo={listMedia:async()=>{
      queries++;events.push(['list',entries.map(entry=>entry.path)]);
      return listFailure?{ok:false,error:{message:'media directory unavailable'}}:{ok:true,data:entries.slice()};
    },
    downloadEntry:async entry=>{
      events.push(['download',entry.path]);downloads.push(entry.path);
      return {ok:true,data:{path:'/download/'+entry.path,size:entry.size}};
    }};
  const capture=new CaptureMedia(session,repo,'/download',()=>now,async ms=>{
    now+=ms;if(waitHook)await waitHook();
  });
  Object.assign(c,{agentGeneration:0,activeOperations:0,busyValue:false,lastErrorValue:'',lastErrorLayerValue:'',
    latestAgentRequestId:'',acceptedAgentRequestId:'',agentMediaUris:[],agentMediaUri:'',agentMediaKind:'video',
    agentVideoResultReady:false,agentFeedback:'',emit(){},log(message){events.push(['log',message]);},
    // These media-recovery tests substitute scan/frame boundaries; scan readiness has its own real-path replay.
    waitForAutomaticSubjectScan:async()=>{},
    groundDolly:new SubjectTaskWorkflow(()=>{}),closeupSequence:new CloseupSequence(()=>{}),
    closeupMedia:new CloseupMediaGroup(),captureMedia:capture,session,flight:new FlightCommandService(session),
    video:{snapshot:()=>({state:'live'})},
    camera:{resetAfterGroundedCycle(){},snapshot:()=>({operationActive:false,recordingRequested:false})},
    nativeTasks:{snapshot:()=>({kind:'dolly',startedAtMs:startedAt,activeOrUnknown:false}),
      resetAfterGroundedCycle(){startedAt=undefined;},cancel(){},activeOrUnknown:()=>false,
      start:async()=>{
        starts++;startedAt=observedAt();c.flight.markNativeTaskMayFly(startedAt);
        events.push(['native-start',starts]);
        if(interruption){
          interruption=false;
          if(missedOriginal)entries=[old,a];
          c.cancelAgentAction();
          throw Error('simulated interrupted closeup');
        }
        return {ok:true,data:'started'};
      }}});
  c.connectSelectedAircraft=async()=>{events.push(['connect']);throw Error('unexpected reconnection');};
  c.captureAgentObservation=async()=>{
    const id='repeat-'+(++request);c.latestAgentRequestId=id;
    return {requestId:id,sessionId:10,flightGeneration:c.flight.snapshot().generation,
      controlGeneration:c.agentGeneration,requestedAtMs:Date.now(),
      context:{flightStateFresh:true,airborne,framing:'半身',zoom:3,retreat:true},
      frame:airborne?{candidates:[{id:13}],currentSubjectId:selected}:undefined};
  };
  c.requestCloudAgentAction=async observation=>{
    events.push(['cloud',observation.purpose]);
    const command=observation.purpose==='ground_dolly_intent'?{action:'dolly_zoom',recipe}:
      {action:'select_subject',subjectId:13};
    return {version:2,requestId:observation.requestId,command};
  };
  // Only subject-selection and native transport are simulated. Capture baselines,
  // ticket ownership, flight generations and closeup cleanup use production code.
  c.performAgentAction=async(observation,command,sequence)=>{
    c.ensureAgentObservation(observation,command);
    if(command.action==='select_subject'){
      selected=command.subjectId;return {message:'selected'};
    }
    assert.equal(command.action,'dolly_zoom');
    const result=await c.startNativeWithCapture(c.flight.newCancellationToken(),command.subjectId,sequence);
    if(!result.ok)throw Error(result.error?.message??'native start failed');
    return {message:'started'};
  };
  // Harmony's URI conversion is unavailable in Node; retain the real media group
  // while collecting the local files produced by the real retrieval path.
  c.presentAgentMediaGroup=(kind,items)=>{
    const uris=items.map(item=>item.path);
    c.agentMediaUris=kind==='video'?c.closeupMedia.add(uris,10,c.flight.snapshot().generation):uris;
    c.agentMediaUri=c.agentMediaUris[0];c.agentMediaKind=kind;c.agentVideoResultReady=kind==='video';
    events.push(['present',uris]);
  };
  async function interruptFirstShot(){
    assert.equal((await c.runCloudVoiceRequest('给黑衣男生拍特写镜头')).confirmationRequired,true);
    await c.confirmGroundDolly();
    await assert.rejects(c.executeGroundDolly(),/simulated interrupted closeup/);
    assert.equal(starts,1);assert.equal(takeoffs,1);
    assert.equal(capture.hasPending('video'),true);
    assert.equal(capture.readyKind(),undefined);
    airborne=false;recording=false;selected=undefined;now+=1000;recipe=undefined;
  }
  return {c,capture,events,downloads,a,b,interruptFirstShot,queries:()=>queries,takeoffs:()=>takeoffs,starts:()=>starts,
    readyWithoutPending(){recipe=undefined;interruption=false;},
    failDirectory(){listFailure=true;},onWait(hook){waitHook=hook;},
    finishSecondShot(){
      now+=100;recording=true;capture.observe(session.snapshot().telemetry,true);
      now+=100;recording=false;entries=[old,a,b];capture.observe(session.snapshot().telemetry,false);
    }};
}

test('a newer voice request during prior-media recovery supersedes the old takeoff intent',async()=>{
  const f=fixture();await f.interruptFirstShot();let superseded=false;
  const cloud=f.c.requestCloudAgentAction,perform=f.c.performAgentAction;
  f.c.requestCloudAgentAction=async(observation,text)=>text==='先等等不要拍摄'?
    {version:2,requestId:observation.requestId,command:{action:'none',message:'先不拍摄'}}:cloud(observation,text);
  f.c.performAgentAction=async(observation,command,sequence)=>command.action==='none'?
    AppController.prototype.performAgentAction.call(f.c,observation,command,sequence):perform(observation,command,sequence);
  f.onWait(async()=>{
    if(superseded)return;superseded=true;
    const outcome=await f.c.runCloudVoiceRequest('先等等不要拍摄');assert.equal(outcome.message,'先不拍摄');
  });
  await assert.rejects(f.c.runCloudVoiceRequest('再拍希区柯克'),/替代|新请求|取消/);
  assert.equal(f.takeoffs(),1,'a completed old recovery cannot revive an intent superseded by newer speech');
});

test('prior-media recovery never launches from an intent whose response lifetime has expired',async()=>{
  const f=fixture();await f.interruptFirstShot();const realNow=Date.now;let offset=0;
  Date.now=()=>realNow()+offset;
  try{
    f.onWait(()=>{offset=AGENT_TEXT_TIMEOUT_MS+1000;});
    await assert.rejects(f.c.runCloudVoiceRequest('再拍希区柯克'),/过期/);
    assert.equal(f.takeoffs(),1);
  }finally{Date.now=realNow;}
});

test('a new ground voice request clears an interrupted empty ticket before taking off and starts the next shot',async()=>{
  const f=fixture();await f.interruptFirstShot();
  const result=await f.c.runCloudVoiceRequest('再给黑衣男生拍希区柯克');
  assert.equal(result.confirmationRequired,true);
  assert.equal(f.capture.hasPending('video'),false,'the interrupted ticket must be reconciled before the new confirmation');
  assert.equal(f.takeoffs(),2);
  await f.c.confirmGroundDolly();await f.c.executeGroundDolly();
  assert.equal(f.starts(),2);assert.equal(f.capture.hasPending('video'),true);
  assert.deepEqual(f.downloads,[]);
});

test('a missed recording report preserves the first original before takeoff and gives the next shot a separate baseline',async()=>{
  const f=fixture({missedOriginal:true});await f.interruptFirstShot();
  await f.c.runCloudVoiceRequest('再给黑衣男生拍希区柯克');
  assert.deepEqual(f.downloads,['a.MP4'],'a file recorded without matching telemetry must be recovered');
  const recovered=f.events.findIndex(event=>event[0]==='download'&&event[1]==='a.MP4');
  const takeoff=f.events.findIndex(event=>event[0]==='takeoff'&&event[1]===2);
  assert.ok(recovered>=0&&takeoff>recovered,'recover the previous original before the next flight');
  assert.deepEqual(f.c.agentMediaUris,['/download/a.MP4']);
  await f.c.confirmGroundDolly();await f.c.executeGroundDolly();assert.equal(f.starts(),2);
  const nextBaseline=f.events.findIndex((event,index)=>index>takeoff&&event[0]==='list');
  assert.ok(nextBaseline>takeoff);assert.deepEqual(f.events[nextBaseline][1],['old.MP4','a.MP4']);
  f.finishSecondShot();
  await f.c.retrieveCapture('video',new CancellationToken(f.c.flight.snapshot().generation));
  assert.deepEqual(f.downloads,['a.MP4','b.MP4']);
  assert.deepEqual(f.c.agentMediaUris,['/download/b.MP4']);
  assert.equal(f.capture.hasPending('video'),false);
});

test('a ready connection with no pending video reaches ground confirmation without listing media or reconnecting',async()=>{
  const f=fixture();f.readyWithoutPending();
  assert.equal((await f.c.runCloudVoiceRequest('给黑衣男生拍希区柯克')).confirmationRequired,true);
  assert.equal(f.c.groundDolly.snapshot().stage,'confirm');assert.equal(f.takeoffs(),1);
  assert.equal(f.queries(),0);
  assert.equal(f.events.some(event=>event[0]==='connect'||event[0]==='initialize'),false);
});

test('cancelling recovery of an interrupted ticket never starts another flight',async()=>{
  const f=fixture();await f.interruptFirstShot();let cancelled=false;
  f.onWait(()=>{if(!cancelled){cancelled=true;f.c.cancelAgentAction();}});
  await assert.rejects(f.c.runCloudVoiceRequest('再拍一次'));
  assert.equal(cancelled,true);assert.equal(f.takeoffs(),1);assert.equal(f.starts(),1);
  assert.equal(f.capture.hasPending('video'),true);
});

test('an unreadable interrupted directory keeps its ticket and prevents the next flight',async()=>{
  const f=fixture({missedOriginal:true});await f.interruptFirstShot();f.failDirectory();
  await assert.rejects(f.c.runCloudVoiceRequest('再拍一次'));
  assert.equal(f.takeoffs(),1);assert.equal(f.starts(),1);
  assert.equal(f.capture.hasPending('video'),true);assert.deepEqual(f.downloads,[]);
});
