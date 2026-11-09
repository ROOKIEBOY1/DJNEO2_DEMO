const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {GroundDollyWorkflow}=require('../entry/src/main/ets/core/domain/GroundDollyWorkflow.ets');
const {CloseupSequence}=require('../entry/src/main/ets/core/domain/CloseupSequence.ets');
const {CloseupMediaGroup}=require('../entry/src/main/ets/core/media/CloseupMediaGroup.ets');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');

// Exercise real observation capture, automatic scans, response validation,
// subject selection, flight ownership and confirmation/plan/execution. Substitute
// only decoded video/cloud, telemetry time and the final aircraft shot boundary.
async function fixture(options={}){
  const c=Object.create(AppController.prototype),events=[];
  const boxes=[{id:11,left:.1,top:.2,width:.2,height:.5},{id:13,left:.6,top:.2,width:.2,height:.5}];
  const flags={airborne:false,mode:0,selected:options.selected,candidateIds:options.initialIds??[11,13],
    scanState:options.scanReady===false?0:1,taskPhase:0,taskMode:0,recording:false};
  let resetReadyAt,candidatesAt,resetReady=false,delivered=false,frames=0;
  const record=(kind,details={})=>events.push({kind,at:Date.now(),...details});
  const candidates=()=>boxes.filter(box=>flags.candidateIds.includes(box.id));
  const subject=()=>({candidateCount:candidates().length,candidates:candidates(),detectionAt:Date.now(),
    trackingAt:Date.now(),selectedIdCandidate:flags.selected,tracking:flags.selected!==undefined,
    overlay:flags.selected===undefined?candidates():boxes.filter(box=>box.id===flags.selected),
    scanStateRaw:flags.scanState,scanObservedAt:Date.now()});
  const state=()=>({phase:'ready',deviceVerified:true,downlinkAgeMs:0,videoAgeMs:0,telemetry:{
    flightAgeMs:0,flight:{airborne:flags.airborne,motorsOn:flags.airborne,modeRaw:flags.mode,observedAtMs:Date.now()},
    taskAgeMs:0,task:{phaseRaw:flags.taskPhase,modeRaw:flags.taskMode,observedAtMs:Date.now(),
      payloadHex:flags.taskMode===9?'0500000900':flags.airborne?'0000000102':'0000000100'},
    cameraAgeMs:0,camera:{recordingCandidate:flags.recording,observedAtMs:Date.now()},subject:subject()}});
  const session={sessionId:()=>10,isReliableLinkFresh:()=>true,isActionLinkFresh:()=>true,snapshot:state,
    centerSticks:async()=>{record('center');},
    requestFlight:async action=>{
      record('flight',{action});assert.equal(action,1,'these entries must never land implicitly');
      flags.airborne=true;flags.mode=flags.selected===undefined?6:26;return Uint8Array.of(0);
    },
    requestNative:async(receiver,set,id,payload)=>{
      assert.equal(receiver,0x92);
      if(set===0x23&&id===0x15){
        record('scan-reset',{discarded:flags.candidateIds.slice()});
        flags.candidateIds=[];flags.scanState=0;flags.taskPhase=5;flags.taskMode=9;
        resetReadyAt=Date.now()+3900;candidatesAt=resetReadyAt+400;
      }else{
        assert.equal(set,0x0a);assert.equal(id,0xba);assert.deepEqual(Array.from(payload),[1,5,13]);
        record('selection',{id:payload[2]});flags.selected=payload[2];flags.mode=26;
      }
      return Uint8Array.of(0);
    }};
  Object.assign(c,{session,flight:new FlightCommandService(session),
    agentGeneration:0,agentRequestSequence:0,latestAgentRequestId:'',acceptedAgentRequestId:'',
    activeOperations:0,busyValue:false,lastErrorValue:'',lastErrorLayerValue:'',agentFeedback:'',
    autoScanGeneration:-1,autoScanRequestedGeneration:-1,autoScanGateLog:'',autoScanHoverSince:undefined,
    autoScanFailures:0,autoScanRetryAt:0,autoScanRunning:false,hoverScanAttempted:false,demoStage:'closed',
    nativeConfig:{radiusMeters:2,framing:'全身',zoom:2,retreat:false},defaultMovementSeconds:.5,
    groundDolly:new GroundDollyWorkflow(()=>{}),closeupSequence:new CloseupSequence(()=>{}),
    closeupMedia:new CloseupMediaGroup(),captureMedia:{hasPending:()=>false},
    camera:{snapshot:()=>({recordingRequested:flags.recording,operationActive:false}),
      stopRecording:async()=>{record('record-stop');flags.recording=false;return {ok:true,data:'stopped'};}},
    nativeTasks:{snapshot:()=>({kind:'none',prepared:false,busy:false,activeOrUnknown:false}),
      activeOrUnknown:()=>false,cancel(){}},
    video:{snapshot:()=>({state:'live'})},speech:{isListeningOnce:()=>false},voice:{cancelPending(){}},
    emit(){},log(message){record('log',{message});}});
  c.captureVlmFrame=async()=>{
    options.beforeFrame?.(++frames,flags);
    const report=subject();
    const frame={jpeg:new ArrayBuffer(4),width:2,height:2,sessionId:10,capturedAtMs:Date.now(),
      candidatesObservedAtMs:report.detectionAt,candidates:report.candidates,currentSubjectId:flags.selected};
    record('frame',{ids:frame.candidates.map(box=>box.id),currentSubjectId:flags.selected});return frame;
  };
  c.requestCloudAgentAction=async observation=>{
    record('cloud',{purpose:observation.purpose,ids:observation.frame?.candidates.map(box=>box.id),
      currentSubjectId:observation.frame?.currentSubjectId});
    let command;
    if(observation.purpose==='dolly_subject')command={action:'dolly_zoom',subjectId:13};
    else if(options.command)command={...options.command};
    else command={action:'dolly_zoom',framing:'半身',zoom:3,retreat:true,
      ...(observation.frame?.candidates.some(box=>box.id===13)?{subjectId:13}:{})};
    if(options.transientAfterIntent&&observation.purpose!=='dolly_subject')flags.candidateIds=[11];
    return {version:2,requestId:observation.requestId,command};
  };
  c.startAgentDolly=async(observation,command)=>{
    c.ensureAgentObservation(observation,command);
    record('dolly',{command:{...command},currentSubjectId:observation.frame?.currentSubjectId});
    return {message:'普通滑动变焦已开始'};
  };
  c.runCloseupSequence=async(observation,command)=>{
    c.ensureAgentObservation(observation,command);record('closeup',{command:{...command}});
    return {message:'组合拍摄已开始'};
  };
  c.beginRecording=async()=>{record('record-start');flags.recording=true;return {ok:true,data:'recording'};};
  if(!options.grounded){
    assert.equal((await c.flight.takeoff(true)).ok,true);events.length=0;
    if(options.scanReady!==false)c.autoScanRequestedGeneration=c.flight.snapshot().generation;
  }
  function advance(now){
    if(resetReadyAt!==undefined&&!resetReady&&now>=resetReadyAt){
      resetReady=true;flags.taskPhase=0;flags.taskMode=0;flags.scanState=1;
      record('scan-ready',{ids:flags.candidateIds.slice()});
    }
    if(candidatesAt!==undefined&&!delivered&&now>=candidatesAt){
      delivered=true;flags.candidateIds=[13];record('fresh-candidates',{ids:[13]});
    }
  }
  return {c,events,flags,advance};
}

async function withReplayClock(f,body){
  let now=Date.UTC(2026,10,9,15,32,1);
  const realNow=Date.now,realTimeout=global.setTimeout;
  Date.now=()=>now;
  global.setTimeout=(callback,delay,...args)=>{
    now+=delay;f.advance(now);queueMicrotask(()=>callback(...args));return 0;
  };
  try{return await body();}
  finally{Date.now=realNow;global.setTimeout=realTimeout;}
}

test('an ordinary airborne dolly confirms its visually selected subject and plan before the final dolly transport',async()=>{
  const {c,events}=await fixture();
  const outcome=await c.runCloudVoiceRequest('给黑衣男生拍希区柯克运镜');
  assert.equal(outcome.confirmationRequired,true);
  assert.equal(c.groundDolly.snapshot().stage,'confirm','ordinary airborne dolly must use subject confirmation');
  assert.equal(c.groundDolly.snapshot().subjectId,13);
  assert.deepEqual(events.filter(event=>event.kind==='cloud').map(event=>event.purpose),['shoot_intent']);
  assert.equal(events.filter(event=>event.kind==='frame').length,2,'the initial visual ID must be checked against a fresh frame');
  assert.deepEqual(events.filter(event=>event.kind==='selection').map(event=>event.id),[13]);
  assert.equal(events.some(event=>['dolly','closeup','flight'].includes(event.kind)),false);
  await c.confirmGroundDolly();
  assert.equal(c.groundDolly.snapshot().stage,'plan');
  assert.deepEqual(c.groundDolly.snapshot().plan,{action:'dolly_zoom',subjectId:13,framing:'半身',zoom:3,retreat:true});
  assert.equal(events.some(event=>event.kind==='dolly'),false);
  await c.executeGroundDolly();
  assert.equal(events.filter(event=>event.kind==='dolly').length,1);
  assert.equal(events.find(event=>event.kind==='dolly').currentSubjectId,13);
  assert.equal(events.find(event=>event.kind==='dolly').command.recipe,undefined);
  assert.equal(events.some(event=>event.kind==='closeup'||event.kind==='flight'),false);
});

test('an empty initial airborne frame retains ordinary dolly intent until reset scanning provides a fresh subject',async()=>{
  const f=await fixture({initialIds:[],scanReady:false,transientAfterIntent:true});
  await withReplayClock(f,async()=>{
    const outcome=await f.c.runCloudVoiceRequest('给黑衣男生拍一段滑动变焦');
    const cloud=f.events.filter(event=>event.kind==='cloud');
    assert.deepEqual(cloud.map(event=>event.purpose),['shoot_intent','dolly_subject']);
    assert.deepEqual(cloud[0].ids,[],'intent classification must see the initial empty frame without waiting for scanning');
    assert.equal(outcome.confirmationRequired,true);assert.equal(f.c.groundDolly.snapshot().stage,'confirm');
    assert.equal(f.c.groundDolly.snapshot().subjectId,13);
    const reset=f.events.find(event=>event.kind==='scan-reset');
    const ready=f.events.find(event=>event.kind==='scan-ready');
    const fresh=f.events.find(event=>event.kind==='fresh-candidates');
    assert.deepEqual(reset.discarded,[11]);assert.deepEqual(ready.ids,[]);
    assert.ok(cloud[0].at<reset.at);assert.ok(fresh.at>ready.at);assert.ok(cloud[1].at>=fresh.at);
    assert.deepEqual(cloud[1].ids,[13]);
    assert.deepEqual(f.events.filter(event=>event.kind==='selection').map(event=>event.id),[13]);
    assert.equal(f.events.some(event=>['dolly','closeup','flight'].includes(event.kind)),false);
    await f.c.confirmGroundDolly();await f.c.executeGroundDolly();
    assert.equal(f.events.filter(event=>event.kind==='dolly').length,1);
    assert.equal(f.events.some(event=>event.kind==='closeup'),false);
  });
});

test('ordinary airborne dolly visually rechecks the already tracked target and retains it without reselecting',async()=>{
  const {c,events}=await fixture({selected:13});
  await c.runCloudVoiceRequest('继续给黑衣男生拍希区柯克');
  assert.equal(c.groundDolly.snapshot().stage,'confirm');assert.equal(c.groundDolly.snapshot().subjectId,13);
  assert.equal(c.selectedSubjectId,13,'the confirmation overlay must use the visually verified current target');
  assert.deepEqual(events.filter(event=>event.kind==='frame').map(event=>event.currentSubjectId),[13,13]);
  assert.equal(events.filter(event=>event.kind==='cloud').length,1);
  assert.equal(events.find(event=>event.kind==='cloud').currentSubjectId,13);
  assert.equal(events.some(event=>event.kind==='selection'),false);
  await c.confirmGroundDolly();await c.executeGroundDolly();
  assert.equal(events.filter(event=>event.kind==='dolly').length,1);
  assert.equal(events.some(event=>event.kind==='closeup'||event.kind==='flight'),false);
});

test('ordinary dolly rejects a first visual ID missing from its fresh confirmation frame',async()=>{
  const {c,events}=await fixture({beforeFrame(number,flags){if(number===2)flags.candidateIds=[11];}});
  await assert.rejects(c.runCloudVoiceRequest('给黑衣男生拍希区柯克'),/编号|候选/);
  assert.equal(events.filter(event=>event.kind==='cloud').length,1);
  assert.equal(events.some(event=>['selection','dolly','closeup','flight'].includes(event.kind)),false);
  assert.notEqual(c.groundDolly.snapshot().stage,'confirm');
});

test('ordinary ground dolly takes off once, confirms its subject and executes without adding a circle recipe',async()=>{
  const f=await fixture({grounded:true,initialIds:[],scanReady:false});
  await withReplayClock(f,async()=>{
    const outcome=await f.c.runCloudVoiceRequest('给黑衣男生拍三倍半身希区柯克运镜');
    assert.equal(outcome.confirmationRequired,true);assert.equal(f.c.groundDolly.snapshot().stage,'confirm');
    assert.deepEqual(f.events.filter(event=>event.kind==='cloud').map(event=>event.purpose),['ground_dolly_intent','dolly_subject']);
    assert.equal(f.events.find(event=>event.kind==='cloud').ids,undefined);
    assert.deepEqual(f.events.filter(event=>event.kind==='flight').map(event=>event.action),[1]);
    assert.deepEqual(f.events.filter(event=>event.kind==='selection').map(event=>event.id),[13]);
    assert.equal(f.events.some(event=>event.kind==='dolly'||event.kind==='closeup'),false);
    await f.c.confirmGroundDolly();assert.equal(f.c.groundDolly.snapshot().stage,'plan');
    await f.c.executeGroundDolly();
    assert.deepEqual(f.events.filter(event=>event.kind==='dolly').map(event=>event.command),
      [{action:'dolly_zoom',subjectId:13,framing:'半身',zoom:3,retreat:true}]);
    assert.equal(f.events.some(event=>event.kind==='closeup'),false);
    assert.equal(f.events.filter(event=>event.kind==='flight').length,1);
  });
});

for(const entry of [
  {name:'stop',text:'先停止',command:{action:'stop'},event:'center'},
  {name:'record start',text:'开始录像',command:{action:'record_start'},event:'record-start'},
  {name:'record stop',text:'停止录像',command:{action:'record_stop'},event:'record-stop'},
  {name:'parameter setting',text:'设置全身两倍关闭渐远',command:{action:'set_dolly',framing:'全身',zoom:2,retreat:false}}
])test(`${entry.name} reaches the normal action handler without waiting for an automatic subject scan`,async()=>{
  const f=await fixture({initialIds:[],scanReady:false,command:entry.command});
  await withReplayClock(f,async()=>{
    const started=Date.now();const outcome=await f.c.runCloudVoiceRequest(entry.text);
    assert.equal(Date.now(),started,'automatic scan preparation must not delay a non-shooting voice command');
    assert.deepEqual(f.events.filter(event=>event.kind==='cloud').map(event=>event.purpose),['shoot_intent']);
    assert.deepEqual(f.events.find(event=>event.kind==='cloud').ids,[]);
    assert.equal(f.events.some(event=>event.kind==='scan-reset'||event.kind==='fresh-candidates'),false);
    assert.equal(outcome.confirmationRequired,undefined);
    assert.equal(f.c.groundDolly.snapshot().stage,'idle');
    if(entry.event)assert.equal(f.events.filter(event=>event.kind===entry.event).length,1);
    else assert.match(outcome.message,/全身.*2/);
    assert.equal(f.events.some(event=>['dolly','closeup','selection','flight'].includes(event.kind)),false);
  });
});

test('direct observation capture keeps its default automatic scan barrier',async()=>{
  const f=await fixture({initialIds:[],scanReady:false});
  await withReplayClock(f,async()=>{
    const observation=await f.c.captureAgentObservation();
    assert.equal(f.events.filter(event=>event.kind==='scan-reset').length,1);
    assert.ok(f.events.find(event=>event.kind==='frame').at>=f.events.find(event=>event.kind==='scan-ready').at);
    assert.equal(observation.context.airborne,true);
  });
});

test('a temporarily unavailable intent frame falls back to fresh visual selection for the existing tracked target',async()=>{
  const {c,events}=await fixture({selected:13,beforeFrame(number){
    if(number===1)throw Error('intent frame temporarily unavailable');
  }});
  const outcome=await c.runCloudVoiceRequest('继续给黑衣男生拍希区柯克');
  assert.equal(outcome.confirmationRequired,true);
  assert.equal(c.groundDolly.snapshot().stage,'confirm');assert.equal(c.groundDolly.snapshot().subjectId,13);
  const cloud=events.filter(event=>event.kind==='cloud');
  assert.deepEqual(cloud.map(event=>event.purpose),['shoot_intent','dolly_subject']);
  assert.equal(cloud[0].ids,undefined);assert.deepEqual(cloud[1].ids,[11,13]);
  assert.equal(cloud[1].currentSubjectId,13);assert.equal(c.selectedSubjectId,13);
  assert.equal(events.some(event=>['selection','dolly','closeup','flight'].includes(event.kind)),false);
});

test('an intent frame failure still detects tracking changed during the first cloud request',async()=>{
  const {c,events,flags}=await fixture({selected:13,beforeFrame(number){
    if(number===1)throw Error('intent frame temporarily unavailable');
  }});
  const cloud=c.requestCloudAgentAction;
  c.requestCloudAgentAction=async observation=>{
    const response=await cloud(observation);
    if(observation.purpose==='shoot_intent'){flags.selected=11;flags.mode=26;}
    return response;
  };
  await assert.rejects(c.runCloudVoiceRequest('继续给黑衣男生拍希区柯克'),/锁定|变化/);
  assert.notEqual(c.groundDolly.snapshot().stage,'confirm');
  assert.equal(events.filter(event=>event.kind==='cloud').length,1);
  assert.equal(events.some(event=>['selection','dolly','closeup','flight'].includes(event.kind)),false);
});

for(const stage of ['confirm','plan'])test(`a cloud-recognized stop cancels an existing ${stage} flow and centers the aircraft`,async()=>{
  const options={selected:13};const {c,events}=await fixture(options);
  await c.runCloudVoiceRequest('给黑衣男生拍希区柯克');
  if(stage==='plan')await c.confirmGroundDolly();
  assert.equal(c.groundDolly.snapshot().stage,stage);
  options.command={action:'stop'};
  const outcome=await c.runCloudVoiceRequest('请帮我终止这次运镜');
  assert.match(outcome.message,/停止/);assert.equal(outcome.confirmationRequired,undefined);
  assert.equal(c.groundDolly.snapshot().stage,'cancelled');assert.equal(c.groundDolly.snapshot().active,false);
  assert.equal(events.filter(event=>event.kind==='cloud').length,2);
  assert.equal(events.filter(event=>event.kind==='center').length,1);
  assert.equal(events.some(event=>['dolly','closeup','record-start','flight'].includes(event.kind)),false);
});

for(const command of [{action:'dolly_zoom'},{action:'record_start'},
  {action:'set_dolly',framing:'全身',zoom:2,retreat:false}]){
  test(`an existing subject confirmation rejects a new ${command.action} and preserves its original plan`,async()=>{
    const options={selected:13};const {c,events}=await fixture(options);
    await c.runCloudVoiceRequest('给黑衣男生拍希区柯克');
    const original=c.groundDolly.snapshot().plan;
    options.command=command;
    await assert.rejects(c.runCloudVoiceRequest('执行另一条非停止指令'),/流程|进行中|确认|取消|降落/);
    assert.equal(c.groundDolly.snapshot().stage,'confirm');assert.deepEqual(c.groundDolly.snapshot().plan,original);
    assert.equal(events.some(event=>['center','dolly','closeup','record-start','selection','flight'].includes(event.kind)),false);
    assert.deepEqual(c.nativeConfig,{radiusMeters:2,framing:'全身',zoom:2,retreat:false});
  });
}
