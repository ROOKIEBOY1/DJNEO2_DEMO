const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {SubjectTaskWorkflow}=require('../entry/src/main/ets/core/domain/SubjectTaskWorkflow.ets');
const {CloseupSequence}=require('../entry/src/main/ets/core/domain/CloseupSequence.ets');
const {CloseupMediaGroup}=require('../entry/src/main/ets/core/media/CloseupMediaGroup.ets');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');

// Keep the real observation/automatic-scan/selection/workflow chain. Only the
// cloud, decoded video, aircraft transport and telemetry clock are substituted.
function fixture({temporaryCandidate=true,deliverCandidates=true,landAfterScanReadyMs,cancelAfterTakeoffMs}={}){
  const c=Object.create(AppController.prototype),events=[];
  const transient={id:11,left:.1,top:.2,width:.2,height:.5};
  const fresh={id:13,left:.6,top:.2,width:.2,height:.5};
  let airborne=false,mode=0,selected,boxes=[],scanState=0,taskPhase=0,taskMode=0;
  let resetReadyAt,candidatesAt,resetReady=false,candidatesDelivered=false,landing;
  let takeoffAt,cancelled=false;
  const record=(kind,details={})=>events.push({kind,at:Date.now(),...details});
  const subject=()=>({candidateCount:boxes.length,candidates:boxes.slice(),detectionAt:Date.now(),
    trackingAt:selected===undefined?undefined:Date.now(),selectedIdCandidate:selected,
    tracking:selected!==undefined,overlay:selected===undefined?boxes.slice():[fresh],
    scanStateRaw:scanState,scanObservedAt:Date.now()});
  const state=()=>({phase:'ready',deviceVerified:true,downlinkAgeMs:0,videoAgeMs:0,telemetry:{
    flightAgeMs:0,flight:{airborne,motorsOn:airborne,modeRaw:mode,observedAtMs:Date.now()},
    taskAgeMs:0,task:{phaseRaw:taskPhase,modeRaw:taskMode,
      payloadHex:taskMode===9?'0500000900':airborne?'0000000102':'0000000100',observedAtMs:Date.now()},
    cameraAgeMs:0,camera:{recordingCandidate:false,observedAtMs:Date.now()},subject:subject()}});
  const session={sessionId:()=>10,isReliableLinkFresh:()=>true,isActionLinkFresh:()=>true,snapshot:state,
    centerSticks:async()=>{},
    requestFlight:async action=>{
      record('flight',{action});
      if(action===1){
        airborne=true;mode=6;scanState=1;takeoffAt=Date.now();
        boxes=temporaryCandidate?[transient]:[];
        record('temporary-candidates',{ids:boxes.map(box=>box.id)});
      }else{
        assert.equal(action,2);airborne=false;mode=0;
      }
      return Uint8Array.of(0);
    },
    requestNative:async(receiver,set,id,payload)=>{
      assert.equal(receiver,0x92);
      if(set===0x23&&id===0x15){
        record('scan-reset');
        boxes=[];scanState=0;taskPhase=5;taskMode=9;
        resetReadyAt=Date.now()+3900;candidatesAt=resetReadyAt+400;
      }else{
        assert.equal(set,0x0a);assert.equal(id,0xba);
        assert.deepEqual(Array.from(payload),[1,5,13],
          'only the final candidate may be selected; the temporary candidate must never reach transport');
        record('selection',{id:payload[2]});selected=payload[2];mode=26;
      }
      return Uint8Array.of(0);
    }};
  Object.assign(c,{session,flight:new FlightCommandService(session),
    agentGeneration:0,agentRequestSequence:0,latestAgentRequestId:'',acceptedAgentRequestId:'',
    activeOperations:0,busyValue:false,lastErrorValue:'',lastErrorLayerValue:'',agentFeedback:'',
    autoScanGeneration:-1,autoScanRequestedGeneration:-1,autoScanGateLog:'',autoScanHoverSince:undefined,
    autoScanFailures:0,autoScanRetryAt:0,autoScanRunning:false,hoverScanAttempted:false,demoStage:'closed',
    nativeConfig:{radiusMeters:2,framing:'全身',zoom:2,retreat:false},defaultMovementSeconds:.5,
    groundDolly:new SubjectTaskWorkflow(()=>{}),closeupSequence:new CloseupSequence(()=>{}),
    closeupMedia:new CloseupMediaGroup(),captureMedia:{hasPending:()=>false},
    camera:{snapshot:()=>({recordingRequested:false,operationActive:false})},
    nativeTasks:{snapshot:()=>({kind:'none',prepared:false,busy:false,activeOrUnknown:false}),
      activeOrUnknown:()=>false,cancel(){}},
    video:{snapshot:()=>({state:'live'})},speech:{isListeningOnce:()=>false},voice:{cancelPending(){}},
    emit(){},log(message){record('log',{message});}});
  c.captureVlmFrame=async()=>{
    const report=subject();
    const frame={jpeg:new ArrayBuffer(4),width:2,height:2,sessionId:10,capturedAtMs:Date.now(),
      candidatesObservedAtMs:report.detectionAt,candidates:report.candidates,currentSubjectId:selected};
    record('frame',{ids:frame.candidates.map(box=>box.id)});
    return frame;
  };
  c.requestCloudAgentAction=async observation=>{
    record('cloud',{purpose:observation.purpose,frame:observation.frame});
    const command=observation.purpose==='ground_dolly_intent'?{action:'dolly_zoom',recipe:'dolly_circle'}:
      {action:'select_subject',subjectId:13};
    return {version:2,requestId:observation.requestId,command};
  };
  function advance(now){
    if(takeoffAt!==undefined&&cancelAfterTakeoffMs!==undefined&&!cancelled&&now>=takeoffAt+cancelAfterTakeoffMs){
      cancelled=true;record('cancel-during-scan-preparation');c.cancelAgentAction();
    }
    if(resetReadyAt!==undefined&&!resetReady&&now>=resetReadyAt){
      resetReady=true;taskPhase=0;taskMode=0;scanState=1;
      record('scan-ready',{ids:boxes.map(box=>box.id)});
    }
    if(resetReady&&landAfterScanReadyMs!==undefined&&landing===undefined&&now>=resetReadyAt+landAfterScanReadyMs){
      record('landing-during-wait',{stage:c.groundDolly.snapshot().stage});
      landing=c.land();
    }
    if(deliverCandidates&&candidatesAt!==undefined&&!candidatesDelivered&&now>=candidatesAt){
      candidatesDelivered=true;boxes=[fresh];record('fresh-candidates',{ids:[13]});
    }
  }
  return {c,events,advance,takeoffAt:()=>takeoffAt,candidatesAt:()=>candidatesAt,landing:()=>landing};
}

async function withReplayClock(f,body){
  let now=Date.UTC(2026,10,9,15,32,1);
  const realNow=Date.now,realTimeout=global.setTimeout;
  Date.now=()=>now;
  const advance=ms=>{now+=ms;f.advance(now);};
  global.setTimeout=(callback,delay,...args)=>{
    advance(delay);queueMicrotask(()=>callback(...args));return 0;
  };
  try{return await body(advance);}
  finally{Date.now=realNow;global.setTimeout=realTimeout;}
}

test('a ground closeup waits through automatic scan reset and its empty ready report before requesting a fresh subject frame',async()=>{
  const f=fixture();
  await withReplayClock(f,async()=>{
    const outcome=await f.c.runCloudVoiceRequest('给黑衣男生拍一段特写镜头');
    assert.equal(outcome.confirmationRequired,true);
    assert.equal(f.c.groundDolly.snapshot().stage,'confirm');
    assert.equal(f.c.groundDolly.snapshot().subjectId,13);
    assert.deepEqual(f.events.filter(event=>event.kind==='cloud').map(event=>event.purpose),
      ['ground_dolly_intent','subject_selection']);
    const ready=f.events.find(event=>event.kind==='scan-ready');
    const arrived=f.events.find(event=>event.kind==='fresh-candidates');
    const visual=f.events.find(event=>event.kind==='cloud'&&event.purpose==='subject_selection');
    assert.deepEqual(ready.ids,[],'scan-ready is deliberately received before the new candidates');
    assert.ok(arrived.at>ready.at);
    assert.ok(visual.at>=arrived.at,'visual selection must wait until the reset generation has a fresh nonempty frame');
    assert.deepEqual(visual.frame.candidates.map(box=>box.id),[13]);
    assert.ok(visual.at-visual.frame.candidatesObservedAtMs<=500);
    assert.equal(f.events.filter(event=>event.kind==='scan-reset').length,1);
    assert.deepEqual(f.events.filter(event=>event.kind==='selection').map(event=>event.id),[13]);
    assert.deepEqual(f.events.filter(event=>event.kind==='flight').map(event=>event.action),[1]);
    await f.c.confirmGroundDolly();
    assert.equal(f.c.groundDolly.snapshot().stage,'plan');
  });
});

test('empty candidates after scan readiness time out clearly without a visual request or subject selection',async()=>{
  const f=fixture({temporaryCandidate:false,deliverCandidates:false});
  await withReplayClock(f,async()=>{
    await assert.rejects(f.c.runCloudVoiceRequest('给黑衣男生拍一段特写镜头'),/未找到候选主体.*未开始拍摄/);
    assert.equal(f.c.groundDolly.snapshot().stage,'failed');
    assert.ok(Date.now()-f.takeoffAt()>=30000,'an empty scan must receive the full candidate wait instead of failing on its ready report');
    assert.ok(Date.now()-f.takeoffAt()<=31000,'the wait must stop at its bounded timeout');
    assert.deepEqual(f.events.filter(event=>event.kind==='cloud').map(event=>event.purpose),['ground_dolly_intent']);
    assert.equal(f.events.some(event=>event.kind==='selection'),false);
    assert.equal(f.events.filter(event=>event.kind==='scan-reset').length,1);
  });
});

test('landing while a reset scan is waiting for its candidates prevents any late visual selection',async()=>{
  const f=fixture({landAfterScanReadyMs:100});
  await withReplayClock(f,async advance=>{
    await assert.rejects(f.c.runCloudVoiceRequest('给黑衣男生拍一段特写镜头'),/取消|变化/);
    assert.ok(f.landing(),'the landing request must happen during the empty post-reset interval');
    await f.landing();
    const cancelledAt=f.events.find(event=>event.kind==='landing-during-wait').at;
    assert.ok(Date.now()-cancelledAt<=100,'landing must stop the candidate wait without consuming the scan timeout');
    advance(1000);
    assert.ok(f.events.some(event=>event.kind==='fresh-candidates'),'the delayed candidates still arrive after cancellation');
    assert.equal(f.c.groundDolly.snapshot().stage,'cancelled');
    assert.deepEqual(f.events.filter(event=>event.kind==='flight').map(event=>event.action),[1,2]);
    assert.deepEqual(f.events.filter(event=>event.kind==='cloud').map(event=>event.purpose),['ground_dolly_intent']);
    assert.equal(f.events.some(event=>event.kind==='selection'),false);
  });
});

test('cancelling during automatic scan preparation promptly stops the wait before scan transport or selection',async()=>{
  const f=fixture({cancelAfterTakeoffMs:100});
  await withReplayClock(f,async()=>{
    await assert.rejects(f.c.runCloudVoiceRequest('给黑衣男生拍一段特写镜头'),/取消|变化/);
    const cancelledAt=f.events.find(event=>event.kind==='cancel-during-scan-preparation').at;
    assert.ok(Date.now()-cancelledAt<=100,'control cancellation must interrupt the automatic-scan barrier promptly');
    assert.equal(f.c.groundDolly.snapshot().stage,'cancelled');
    assert.equal(f.events.some(event=>event.kind==='scan-reset'||event.kind==='selection'),false);
    assert.deepEqual(f.events.filter(event=>event.kind==='cloud').map(event=>event.purpose),['ground_dolly_intent']);
  });
});
