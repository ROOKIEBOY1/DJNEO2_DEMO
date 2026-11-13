const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {SubjectTaskWorkflow}=require('../entry/src/main/ets/core/domain/SubjectTaskWorkflow.ets');
const {CloseupSequence}=require('../entry/src/main/ets/core/domain/CloseupSequence.ets');
const {CloseupMediaGroup}=require('../entry/src/main/ets/core/media/CloseupMediaGroup.ets');
const {CancellationToken}=require('../entry/src/main/ets/core/domain/OperationResult.ets');

// The controller, workflow, response validation and hover predicate are real.
// Only decoded-frame/cloud boundaries and aircraft transports are substituted.
function fixture(options={}){
  const c=Object.create(AppController.prototype),events=[];
  let selected=options.selected,mode=options.mode??(selected===undefined?6:26),generation=2,request=0;
  const flags={busy:false,nativeActive:false,recording:false,cameraAge:0,flightAge:0,
    taskPhase:0,taskMode:0,taskAge:0,movement:false,landing:false,nativeMayFly:false,pendingVideo:false,
    candidateIds:[11,13],...options};
  const boxes=[{id:11,left:.1,top:.2,width:.2,height:.5},{id:13,left:.6,top:.2,width:.2,height:.5}];
  const candidates=()=>boxes.filter(box=>flags.candidateIds.includes(box.id));
  const subject=()=>({candidates:candidates(),candidateCount:candidates().length,detectionAt:Date.now(),trackingAt:Date.now(),
    tracking:selected!==undefined,overlay:selected===undefined?boxes:[boxes.find(box=>box.id===selected)],
    selectedIdCandidate:selected,scanStateRaw:1});
  const state=()=>({phase:'ready',deviceVerified:true,downlinkAgeMs:0,videoAgeMs:0,telemetry:{
    flight:{airborne:true,motorsOn:true,modeRaw:mode,observedAtMs:Date.now()},flightAgeMs:flags.flightAge,
    task:{phaseRaw:flags.taskPhase,modeRaw:flags.taskMode,observedAtMs:Date.now()},taskAgeMs:flags.taskAge,
    camera:{recordingCandidate:flags.recording,observedAtMs:Date.now()},cameraAgeMs:flags.cameraAge,
    subject:subject()}});
  Object.assign(c,{agentGeneration:0,autoScanRequestedGeneration:generation,latestAgentRequestId:'',acceptedAgentRequestId:'',agentFeedback:'',
    emit(){},log(message){events.push(['log',message]);},busyValue:flags.busy,activeOperations:0,lastErrorValue:'',lastErrorLayerValue:'',
    groundDolly:new SubjectTaskWorkflow(()=>{}),closeupSequence:new CloseupSequence(()=>{}),closeupMedia:new CloseupMediaGroup(),
    video:{snapshot:()=>({state:'live'})},captureMedia:{hasPending:()=>flags.pendingVideo},
    camera:{snapshot:()=>({operationActive:false,recordingRequested:flags.recording})},
    nativeConfig:{radiusMeters:2,framing:'全身',zoom:2,retreat:false},
    nativeTasks:{activeOrUnknown:()=>flags.nativeActive,
      snapshot:()=>({kind:'none',activeOrUnknown:flags.nativeActive,prepared:false}),
      canCompleteForHover:()=>({ok:true,data:true}),
      completeForHover:()=>{events.push(['handoff-complete']);flags.nativeMayFly=false;return {ok:true,data:true};}},
    session:{sessionId:()=>10,isReliableLinkFresh:()=>true,isActionLinkFresh:()=>true,snapshot:state},
    flight:{newCancellationToken:()=>new CancellationToken(generation),
      snapshot:()=>({generation,takeoffSent:true,takeoffAcknowledged:true,nativeTaskMayFly:flags.nativeMayFly,
      movementActive:flags.movement,landRequested:flags.landing,landSent:false})}});
  c.captureAgentObservation=async()=>{
    const current=state(),id=`airborne-${++request}`;c.latestAgentRequestId=id;
    events.push(['frame',selected]);
    return {requestId:id,sessionId:10,flightGeneration:generation,controlGeneration:c.agentGeneration,
      requestedAtMs:Date.now(),context:{phase:'ready',airborne:true,flightStateFresh:flags.flightAge<=1000,
        flightMode:mode,tracking:selected!==undefined,currentSubjectId:selected,taskKind:'none',
        taskActive:flags.nativeActive,taskPrepared:false,cameraIdle:flags.cameraAge<=1000&&!flags.recording,
        recording:flags.recording,radiusMeters:2,framing:'全身',zoom:2,retreat:false,movementSeconds:.5},
      frame:{jpeg:new ArrayBuffer(4),width:2,height:2,sessionId:10,capturedAtMs:Date.now(),
        candidatesObservedAtMs:current.telemetry.subject.detectionAt,candidates:candidates(),currentSubjectId:selected}};
  };
  c.requestCloudAgentAction=async observation=>{
    events.push(['cloud',observation.purpose,observation.frame?.currentSubjectId]);
    const command=observation.purpose==='subject_selection'?{action:'select_subject',subjectId:13}:
      {action:'dolly_zoom',recipe:'dolly_circle',subjectId:13};
    return {version:2,requestId:observation.requestId,command};
  };
  c.performVoiceFlightAction=async()=>{events.push(['takeoff']);throw Error('airborne entry must not issue takeoff');};
  c.performAgentAction=async(observation,command)=>{
    c.ensureAgentObservation(observation,command);events.push(['transport',command]);
    if(command.action==='none')return AppController.prototype.performAgentAction.call(c,observation,command);
    if(command.action==='select_subject'){selected=command.subjectId;mode=26;return {message:'selected'};}
    throw Error('the closeup recipe must reach runCloseupSequence after plan execution');
  };
  c.requestSubjectSelection=async(token,id)=>{
    events.push(['handoff-selection',id]);selected=id;mode=id===undefined?6:26;
    flags.taskPhase=0;flags.taskMode=0;
    return {ok:true,data:'ack'};
  };
  c.runCloseupSequence=async(observation,command)=>{
    c.ensureAgentObservation(observation,command);events.push(['closeup',command,observation.frame.currentSubjectId]);
    return {message:'特写组合已完成'};
  };
  c.pollAutoSubjectScan=async()=>{events.push(['scan']);};
  return {c,events,flags,changeTarget(id){selected=id;mode=id===undefined?6:26;},
    invalidateFlight(){generation++;}};
}

test('an airborne closeup request reaches subject confirmation and a plan before executing without takeoff',async()=>{
  const {c,events}=fixture();
  const outcome=await c.runCloudVoiceRequest('帮黑色衣服的男生拍一段特写镜头');
  assert.equal(outcome.confirmationRequired,true);
  assert.equal(c.groundDolly.snapshot().stage,'confirm','airborne recipe must use the shared subject workflow');
  assert.equal(events.some(event=>event[0]==='takeoff'||event[0]==='closeup'),false);
  await c.confirmGroundDolly();
  assert.equal(c.groundDolly.snapshot().stage,'plan');
  assert.deepEqual(c.groundDolly.snapshot().plan,{action:'dolly_zoom',recipe:'dolly_circle',subjectId:13,
    framing:'半身',zoom:3,retreat:true});
  assert.equal(events.some(event=>event[0]==='closeup'),false);
  await c.executeGroundDolly();
  const shots=events.filter(event=>event[0]==='closeup');assert.equal(shots.length,1);
  assert.equal(shots[0][2],13);assert.equal(shots[0][1].recipe,'dolly_circle');
  assert.equal(events.some(event=>event[0]==='takeoff'),false);
});

test('an already tracked target is visually rechecked and retained for confirmation in mode 26',async()=>{
  const {c,events}=fixture({selected:13});
  await c.runCloudVoiceRequest('继续给黑衣男生拍一段特写');
  assert.equal(c.groundDolly.snapshot().stage,'confirm');
  assert.equal(c.groundDolly.snapshot().subjectId,13);
  assert.equal(events.filter(event=>event[0]==='cloud')[0][2],13,'model must receive the current tracked ID and image');
  assert.equal(events.filter(event=>event[0]==='cloud').length,1,'the first visual inference is sufficient');
  assert.equal(events.some(event=>event[0]==='transport'&&event[1].action==='select_subject'),false,
    'fresh same-ID tracking must not be selected twice');
  await c.confirmGroundDolly();await c.executeGroundDolly();
  assert.equal(events.filter(event=>event[0]==='closeup').length,1);
  assert.equal(events.some(event=>event[0]==='takeoff'),false);
});

test('reusing confirmed same-ID tracking synchronizes the local selection used by the confirmation frame',async()=>{
  const {c,events}=fixture({selected:13});
  assert.equal(c.selectedSubjectId,undefined,'device tracking may predate the local selected-subject field');
  await c.runCloudVoiceRequest('继续给黑衣男生拍一段特写');
  assert.equal(c.groundDolly.snapshot().stage,'confirm');
  assert.equal(c.selectedSubjectId,13,'the confirmation overlay must use the visually verified tracked target');
  assert.equal(events.some(event=>event[0]==='transport'),false,'local frame synchronization must not reselect on the drone');
});

test('mode 6 with no initial candidates waits for automatic scanning before visual selection',async()=>{
  const {c,events,flags}=fixture({candidateIds:[]});const cloud=c.requestCloudAgentAction;
  c.requestCloudAgentAction=async observation=>observation.purpose==='subject_selection'?cloud(observation):
    {version:2,requestId:observation.requestId,command:{action:'dolly_zoom',recipe:'dolly_circle'}};
  c.pollAutoSubjectScan=async()=>{events.push(['scan']);flags.candidateIds=[11,13];};
  await c.runCloudVoiceRequest('帮黑衣男生拍特写');
  assert.equal(c.groundDolly.snapshot().stage,'confirm');assert.equal(c.groundDolly.snapshot().subjectId,13);
  const scan=events.findIndex(event=>event[0]==='scan');
  const select=events.findIndex(event=>event[0]==='transport'&&event[1].action==='select_subject');
  assert.ok(scan>=0&&select>scan);assert.equal(events.some(event=>event[0]==='takeoff'),false);
});

test('a proven completed native task releases its real controller handoff before the next airborne plan',async()=>{
  const {c,events,flags}=fixture({selected:13,nativeMayFly:true,taskPhase:0});
  await c.runCloudVoiceRequest('再给黑衣男生拍特写');
  assert.equal(flags.nativeMayFly,false);assert.equal(c.groundDolly.snapshot().stage,'confirm');
  assert.equal(events.filter(event=>event[0]==='handoff-selection').length,1);
  assert.equal(events.find(event=>event[0]==='handoff-selection')[1],undefined,'handoff must release previous tracking');
  assert.equal(events.filter(event=>event[0]==='handoff-complete').length,1);
  const release=events.findIndex(event=>event[0]==='handoff-complete');
  const reselect=events.findIndex(event=>event[0]==='transport'&&event[1].action==='select_subject');
  assert.ok(reselect>release);assert.equal(events.filter(event=>event[0]==='cloud').length,1);
  assert.equal(events.some(event=>event[0]==='takeoff'),false);
});

test('a completed native task with pending footage cannot discard its ticket or start the next handoff',async()=>{
  const {c,events,flags}=fixture({selected:13,nativeMayFly:true,pendingVideo:true,taskPhase:0});
  await assert.rejects(c.runCloudVoiceRequest('再拍一段特写'),/录像|取回/);
  assert.equal(flags.pendingVideo,true);assert.equal(flags.nativeMayFly,true);
  assert.equal(events.some(event=>['handoff-selection','handoff-complete','transport','closeup'].includes(event[0])),false);
  assert.notEqual(c.groundDolly.snapshot().stage,'confirm');
});

test('a terminal native phase still tracking in mode 26 preserves the real cancellation safety guard',async()=>{
  for(const taskPhase of [3,4]){
    const {c,events,flags}=fixture({selected:13,nativeMayFly:true,taskPhase});
    c.requestSubjectSelection=AppController.prototype.requestSubjectSelection.bind(c);
    c.session.requestNative=async()=>{events.push(['unexpected-native-transport']);throw Error('not safe to cancel tracking');};
    await assert.rejects(c.runCloudVoiceRequest('再给黑衣男生拍特写'),/悬停|任务空闲|新鲜连接/);
    assert.equal(flags.nativeMayFly,true,'the completed-task ownership is preserved until a safe handoff');
    assert.equal(events.some(event=>['unexpected-native-transport','transport','closeup','handoff-complete'].includes(event[0])),false);
    assert.notEqual(c.groundDolly.snapshot().stage,'confirm');
  }
});

test('camera or task deterioration after plan confirmation prevents an airborne execution',async()=>{
  for(const changed of [{recording:true},{cameraAge:1001},{taskAge:1001},{taskPhase:5,taskMode:5},{nativeActive:true}]){
    const {c,events,flags}=fixture({selected:13});await c.runCloudVoiceRequest('给黑衣男生拍特写');
    await c.confirmGroundDolly();Object.assign(flags,changed);
    await assert.rejects(c.executeGroundDolly());
    assert.equal(events.some(event=>event[0]==='closeup'||event[0]==='takeoff'),false,JSON.stringify(changed));
  }
});

test('the first airborne visual inference cannot be reused after its response lifetime expires',async()=>{
  const {c,events}=fixture();const capture=c.captureAgentObservation;const realNow=Date.now,realTimeout=global.setTimeout;
  let now=realNow(),captures=0;Date.now=()=>now;
  // The search settles before capturing: advance the same clock for its waits.
  global.setTimeout=(callback,delay,...args)=>{now+=Number(delay)||0;queueMicrotask(()=>callback(...args));return 0;};
  c.captureAgentObservation=async()=>{if(++captures===2)now+=21000;return capture();};
  try{
    await assert.rejects(c.runCloudVoiceRequest('给黑衣男生拍特写'),/过期/);
    assert.equal(events.some(event=>event[0]==='transport'||event[0]==='closeup'||event[0]==='takeoff'),false);
    assert.equal(events.filter(event=>event[0]==='cloud').length,1);
  }finally{Date.now=realNow;global.setTimeout=realTimeout;}
});

test('a candidate disappearing from the fresh frame prevents selection based on an older inference',async()=>{
  const {c,events,flags}=fixture();const capture=c.captureAgentObservation;let captures=0;
  c.captureAgentObservation=async()=>{if(++captures===2)flags.candidateIds=[11];return capture();};
  await assert.rejects(c.runCloudVoiceRequest('给黑衣男生拍特写'),/编号|候选/);
  assert.equal(events.some(event=>event[0]==='transport'||event[0]==='closeup'||event[0]==='takeoff'),false);
  assert.equal(events.filter(event=>event[0]==='cloud').length,1);
});

test('a new voice request during the completed-task handoff supersedes the older closeup intent',async()=>{
  const {c,events}=fixture({selected:13,nativeMayFly:true,taskPhase:0});
  let release,entered;const suspended=new Promise(resolve=>{release=resolve;});
  const reachedHandoff=new Promise(resolve=>{entered=resolve;});
  const selection=c.requestSubjectSelection,cloud=c.requestCloudAgentAction;
  c.requestSubjectSelection=async(...args)=>{entered();await suspended;return selection(...args);};
  c.requestCloudAgentAction=async(observation,text)=>text==='先等等，不拍了'?
    {version:2,requestId:observation.requestId,command:{action:'none',message:'先不拍摄'}}:cloud(observation,text);
  const old=c.runCloudVoiceRequest('给黑衣男生拍特写');
  const settled=old.then(value=>({value}),error=>({error}));
  try{
    await reachedHandoff;
    assert.equal((await c.runCloudVoiceRequest('先等等，不拍了')).message,'先不拍摄');
    release();const outcome=await settled;
    assert.ok(outcome.error,'an older intent must not resume after a newer request replaces it');
    assert.match(outcome.error.message,/替代|新请求|取消|变化/);
    assert.notEqual(c.groundDolly.snapshot().stage,'confirm');
    assert.equal(events.some(event=>event[0]==='closeup'||event[0]==='takeoff'),false);
  }finally{release();await settled;}
});

test('a new voice request clears an inactive previous failure while its cloud response is still pending',async()=>{
  const {c}=fixture({selected:13});
  await assert.rejects(c.closeupSequence.run({isCurrent:()=>true,startDolly:async()=>{throw Error('上次失败');},
    finishDolly:async()=>{},startCircle:async()=>{},finishCircle:async()=>{},returnMedia:async()=>{}}),/上次失败/);
  assert.equal(c.closeupSequence.snapshot().stage,'failed');
  let release,entered;const pending=new Promise(resolve=>{release=resolve;});
  const reachedCloud=new Promise(resolve=>{entered=resolve;});const cloud=c.requestCloudAgentAction;
  c.requestCloudAgentAction=async(...args)=>{entered();await pending;return cloud(...args);};
  const request=c.runCloudVoiceRequest('重新拍特写');
  try{await reachedCloud;assert.equal(c.closeupSequence.snapshot().stage,'idle');}
  finally{release();await request;}
});

test('a tracked subject is not blindly reused when the visual response selects the other candidate',async()=>{
  const {c,events}=fixture({selected:11});
  await c.runCloudVoiceRequest('换成黑衣男生拍一段特写');
  assert.equal(c.groundDolly.snapshot().stage,'confirm');
  assert.equal(c.groundDolly.snapshot().subjectId,13);
  assert.deepEqual(events.filter(event=>event[0]==='transport').map(event=>event[1]),[{action:'select_subject',subjectId:13}]);
  await c.confirmGroundDolly();await c.executeGroundDolly();
  assert.equal(events.find(event=>event[0]==='closeup')[2],13);
});

test('an airborne intent without an ID performs visual selection before asking for subject confirmation',async()=>{
  const {c,events}=fixture();const cloud=c.requestCloudAgentAction;
  c.requestCloudAgentAction=async observation=>observation.purpose==='subject_selection'?cloud(observation):
    {version:2,requestId:observation.requestId,command:{action:'dolly_zoom',recipe:'dolly_circle'}};
  await c.runCloudVoiceRequest('帮我拍一段特写');
  assert.equal(c.groundDolly.snapshot().stage,'confirm');assert.equal(c.groundDolly.snapshot().subjectId,13);
  assert.equal(events.some(event=>event[0]==='cloud'&&event[1]==='subject_selection'),true);
  assert.equal(events.some(event=>event[0]==='takeoff'),false);
});

test('unsafe or unknown airborne states cannot select a subject or begin another closeup',async()=>{
  for(const options of [{busy:true},{nativeActive:true},{recording:true},{cameraAge:1001},
    {flightAge:1001},{taskAge:1001},{taskPhase:5,taskMode:5},{mode:10},{movement:true},{landing:true}]){
    const {c,events}=fixture(options);
    await assert.rejects(c.runCloudVoiceRequest('帮黑衣男生拍一段特写'),undefined,JSON.stringify(options));
    assert.equal(events.some(event=>['takeoff','transport','closeup'].includes(event[0])),false,JSON.stringify(options));
    assert.notEqual(c.groundDolly.snapshot().stage,'confirm',JSON.stringify(options));
  }
});

test('target or flight changes after an airborne plan confirmation prevent recipe execution',async()=>{
  for(const change of ['target','flight']){
    const f=fixture({selected:13});await f.c.runCloudVoiceRequest('给黑衣男生拍一段特写');
    await f.c.confirmGroundDolly();
    if(change==='target')f.changeTarget(11);else f.invalidateFlight();
    await assert.rejects(f.c.executeGroundDolly());
    assert.equal(f.events.some(event=>event[0]==='takeoff'||event[0]==='closeup'),false,change);
  }
});

test('a new closeup request cannot reset an active sequence while waiting for the current task to end',async()=>{
  const {c,events}=fixture({selected:13});let release;
  const suspended=new Promise(resolve=>{release=resolve;});
  const running=c.closeupSequence.run({isCurrent:()=>true,startDolly:async()=>suspended,
    finishDolly:async()=>{},startCircle:async()=>{},finishCircle:async()=>{},returnMedia:async()=>{}});
  assert.equal(c.closeupSequence.snapshot().active,true);
  try{
    await assert.rejects(c.runCloudVoiceRequest('再拍一段特写'));
    assert.equal(c.closeupSequence.snapshot().active,true,'rejecting another recipe must preserve the active sequence');
    assert.equal(events.some(event=>event[0]==='takeoff'||event[0]==='transport'||event[0]==='closeup'),false);
  }finally{c.closeupSequence.cancel();release();await assert.rejects(running,/取消/);}
});
