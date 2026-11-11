const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {SubjectTaskWorkflow}=require('../entry/src/main/ets/core/domain/SubjectTaskWorkflow.ets');
const {CloseupSequence}=require('../entry/src/main/ets/core/domain/CloseupSequence.ets');
const {CloseupMediaGroup}=require('../entry/src/main/ets/core/media/CloseupMediaGroup.ets');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');

async function fixture(command,grounded=false){
  const c=Object.create(AppController.prototype),events=[];
  const flags={airborne:!grounded,selected:undefined};
  const boxes=[11,13].map((id,index)=>({id,left:.1+index*.4,top:.1,width:.2,height:.7}));
  const state=()=>({phase:'ready',deviceVerified:true,downlinkAgeMs:0,videoAgeMs:0,telemetry:{
    flightAgeMs:0,flight:{observedAtMs:Date.now(),airborne:flags.airborne,motorsOn:flags.airborne,
      modeRaw:flags.selected===undefined?6:26},
    taskAgeMs:0,task:{observedAtMs:Date.now(),phaseRaw:0,modeRaw:0,payloadHex:'0000000100'},
    cameraAgeMs:0,camera:{observedAtMs:Date.now(),recordingCandidate:false},
    subject:{candidates:boxes,candidateCount:2,detectionAt:Date.now(),tracking:flags.selected!==undefined,
      trackingAt:Date.now(),overlay:boxes.filter(b=>b.id===flags.selected),selectedIdCandidate:flags.selected,
      scanStateRaw:1,scanObservedAt:Date.now()}}});
  const session={sessionId:()=>10,isReliableLinkFresh:()=>true,isActionLinkFresh:()=>true,snapshot:state,
    requestFlight:async()=>{events.push('takeoff');flags.airborne=true;return Uint8Array.of(0);},
    clearSubjectObservation(){},centerSticks:async()=>{}};
  Object.assign(c,{session,flight:new FlightCommandService(session),agentGeneration:0,agentRequestSequence:0,
    latestAgentRequestId:'',acceptedAgentRequestId:'',activeOperations:0,busyValue:false,
    lastErrorValue:'',lastErrorLayerValue:'',agentFeedback:'',nativeConfig:{radiusMeters:2,framing:'半身',zoom:2,retreat:true},
    defaultMovementSeconds:.5,groundDolly:new SubjectTaskWorkflow(()=>{}),closeupSequence:new CloseupSequence(()=>{}),
    closeupMedia:new CloseupMediaGroup(),captureMedia:{hasPending:()=>false},
    camera:{snapshot:()=>({operationActive:false,recordingRequested:false})},
    nativeTasks:{snapshot:()=>({busy:false,activeOrUnknown:false}),activeOrUnknown:()=>false,cancel(){}},
    video:{snapshot:()=>({state:'live'})},emit(){},log(message){events.push(message);}});
  c.waitForAutomaticSubjectScan=async()=>{events.push('scan');};c.pollAutoSubjectScan=async()=>{};
  c.captureVlmFrame=async()=>({sessionId:10,capturedAtMs:Date.now(),candidatesObservedAtMs:Date.now(),
    jpeg:new ArrayBuffer(1),width:2,height:2,candidates:boxes,currentSubjectId:flags.selected});
  c.requestCloudAgentAction=async observation=>{
    events.push('cloud:'+observation.purpose);
    return {version:2,requestId:observation.requestId,command:observation.purpose==='subject_selection'?
      {action:'select_subject',subjectId:13}:{...command}};
  };
  c.requestAgentExecution=async(observation,action)=>{
    c.ensureAgentObservation(observation,action);
    if(action.action==='select_subject'){
      flags.selected=action.subjectId;c.selectedSubjectId=action.subjectId;
      events.push(c.groundDolly.snapshot().stage==='starting'?'execute:select_subject':'select:'+action.subjectId);
    }else events.push('execute:'+action.action);
    return {message:'已执行 '+action.action};
  };
  if(!grounded){await c.flight.takeoff(true);events.length=0;}
  return {c,events,flags};
}

for(const action of ['follow','circle','photo','record_start','select_subject']){
  test(action+' shares visible target confirmation and only then executes',async()=>{
    const command={action,...(['photo','record_start','select_subject'].includes(action)?{subjectRequired:true}:{})};
    const {c,events}=await fixture(command);
    const result=await c.runCloudVoiceRequest('给黑衣服男生执行当前动作');
    assert.equal(result.confirmationRequired,true);assert.equal(c.groundDolly.snapshot().stage,'confirm');
    assert.equal(c.groundDolly.snapshot().subjectId,13);assert.ok(events.includes('select:13'));
    assert.equal(events.some(e=>e.startsWith('execute:')),false);
    await c.confirmSubjectTask();
    assert.equal(events.filter(e=>e==='execute:'+action).length,1);
    assert.notEqual(c.groundDolly.snapshot().stage,'confirm');
    await assert.rejects(c.confirmSubjectTask(),/确认/);
  });
}

for(const action of ['follow','circle']){
  test('ground '+action+' takes off and scans before target confirmation, without launching the native task',async()=>{
    const {c,events}=await fixture({action},true);
    await c.runCloudVoiceRequest('让飞机跟着指定的人拍摄');
    assert.equal(events.filter(e=>e==='takeoff').length,1);assert.equal(c.groundDolly.snapshot().stage,'confirm');
    assert.equal(events.some(e=>e.startsWith('execute:')),false);
    await c.confirmSubjectTask();assert.ok(events.includes('execute:'+action));
  });
}

test('plain photo bypasses subject confirmation and does not take off',async()=>{
  const {c,events}=await fixture({action:'photo'},true);
  await c.runCloudVoiceRequest('拍一张照片');
  assert.ok(events.includes('execute:photo'));assert.equal(events.includes('takeoff'),false);
  assert.equal(c.groundDolly.snapshot().stage,'idle');
});

for(const action of ['photo','record_start','select_subject']){
  test('ground subject '+action+' cannot silently take off',async()=>{
    const {c,events}=await fixture({action,subjectRequired:true},true);
    await assert.rejects(c.runCloudVoiceRequest('请选指定的人'),/起飞|悬停/);
    assert.equal(events.includes('takeoff'),false);assert.equal(events.some(e=>e.startsWith('execute:')),false);
  });
}

test('a changed target at confirmation prevents the requested action',async()=>{
  const {c,events,flags}=await fixture({action:'follow'});
  await c.runCloudVoiceRequest('跟随黑衣服男生');flags.selected=11;
  await assert.rejects(c.confirmSubjectTask(),/主体.*变化|重新选人/);
  assert.equal(events.includes('execute:follow'),false);
});

test('cancelling a shared confirmation prevents a later follow start',async()=>{
  const {c,events}=await fixture({action:'follow'});
  await c.runCloudVoiceRequest('跟随黑衣服男生');c.cancelAgentAction();
  await assert.rejects(c.confirmSubjectTask(),/确认/);
  assert.equal(events.includes('execute:follow'),false);
});

test('switching the proposed subject reuses the pending task and asks for confirmation again',async()=>{
  const command={action:'follow'};const {c,events}=await fixture(command);
  await c.runCloudVoiceRequest('跟随黑衣服男生');
  command.action='select_subject';command.subjectId=11;
  await c.runCloudVoiceRequest('换成另外一个');
  assert.equal(c.groundDolly.snapshot().stage,'confirm');
  assert.equal(c.groundDolly.snapshot().plan.action,'follow');
  assert.equal(c.groundDolly.snapshot().subjectId,11);
  assert.equal(events.includes('execute:follow'),false);
  await c.confirmSubjectTask();assert.equal(events.filter(e=>e==='execute:follow').length,1);
});

test('a decoder restart during post-confirmation frame capture prevents action execution',async()=>{
  const {c,events}=await fixture({action:'follow'});let epoch=1;
  c.video.snapshot=()=>({state:'live',stats:{decoderEpoch:epoch,waitingForKey:false}});
  const capture=c.captureVlmFrame;
  c.captureVlmFrame=async()=>{const frame=await capture();
    if(c.groundDolly.snapshot().stage==='starting')epoch++;
    return frame;};
  await c.runCloudVoiceRequest('跟随黑衣服男生');
  await assert.rejects(c.confirmSubjectTask(),/画面.*变化|重新确认/);
  assert.equal(events.includes('execute:follow'),false);
});

test('direct model responses also reconcile prior media before any new ground takeoff',async()=>{
  const {c,events}=await fixture({action:'follow'},true);
  c.recoverPreviousGroundedVideo=async()=>{events.push('recover');};
  const observation=await c.captureAgentObservation(false);observation.purpose='ground_dolly_intent';
  await c.acceptAgentResponse(observation,{version:2,requestId:observation.requestId,command:{action:'follow'}});
  assert.ok(events.indexOf('recover')>=0);assert.ok(events.indexOf('recover')<events.indexOf('takeoff'));
  assert.equal(c.groundDolly.snapshot().stage,'confirm');
});

test('direct and cloud closeup intents use the same recipe defaults before subject confirmation',async()=>{
  for(const direct of [false,true]){
    const command={action:'dolly_zoom',recipe:'dolly_circle'};const {c}=await fixture(command);
    if(direct){const observation=await c.captureAgentObservation(false);observation.purpose='shoot_intent';
      await c.acceptAgentResponse(observation,{version:2,requestId:observation.requestId,command});
    }else await c.runCloudVoiceRequest('给男生拍一段特写');
    assert.equal(c.groundDolly.snapshot().plan.zoom,3);
    assert.equal(c.groundDolly.snapshot().plan.framing,'半身');
    assert.equal(c.groundDolly.snapshot().plan.retreat,true);
  }
});

test('cancelling a subject request invalidates an already prepared native command token',async()=>{
  const {NativeTaskService}=require('../entry/src/main/ets/core/domain/NativeTaskService.ets');
  const {CancellationToken}=require('../entry/src/main/ets/core/domain/OperationResult.ets');
  const {c}=await fixture({action:'follow'});
  const native=new NativeTaskService(c.session,c.flight,c.camera);
  const token=new CancellationToken(0);native.token=token;native.prepared=true;c.nativeTasks=native;
  c.cancelAgentAction();
  assert.equal(token.isCancelled(),true);assert.equal(native.snapshot().prepared,false);
});

for(const action of ['follow','circle','dolly_zoom','photo']){
  test('self-reference '+action+' resolves again with the reference instead of reusing an initial ID',async()=>{
    const {c,events}=await fixture({action,subjectId:11});
    const result=await c.runCloudVoiceRequest('给我拍一段运镜');
    assert.equal(result.confirmationRequired,true);
    assert.ok(events.includes('cloud:subject_selection'));
    assert.equal(c.groundDolly.snapshot().subjectId,13);
    assert.equal(c.groundDolly.snapshot().stage,'confirm');
    assert.equal(events.includes('select:11'),false);
    assert.equal(events.some(e=>e.startsWith('execute:')),false);
  });
}

test('a reference mismatch cannot fall back to the earlier candidate or execute the task',async()=>{
  const {c,events}=await fixture({action:'follow',subjectId:11});
  c.requestCloudAgentAction=async observation=>({version:2,requestId:observation.requestId,
    command:observation.purpose==='subject_selection'?{action:'none',message:'未找到参考照片对应的主体'}:
      {action:'follow',subjectId:11}});
  await assert.rejects(c.runCloudVoiceRequest('跟随我'),/未找到参考照片/);
  assert.equal(c.groundDolly.snapshot().stage,'failed');
  assert.equal(events.some(e=>e.startsWith('select:')||e.startsWith('execute:')),false);
});

test('a described other subject still reuses the valid initial selection',async()=>{
  const {c,events}=await fixture({action:'follow',subjectId:11});
  await c.runCloudVoiceRequest('帮我跟随黑衣服男生');
  assert.equal(c.groundDolly.snapshot().subjectId,11);
  assert.equal(events.includes('cloud:subject_selection'),false);
  assert.equal(c.groundDolly.snapshot().stage,'confirm');
});

for(const action of ['photo','record_start']){
  test('a bare model '+action+' cannot skip reference selection for an explicit self request',async()=>{
    const {c,events}=await fixture({action});
    await c.runCloudVoiceRequest('给我拍一张照片');
    assert.equal(c.groundDolly.snapshot().stage,'confirm');
    assert.equal(c.groundDolly.snapshot().subjectId,13);
    assert.ok(events.includes('cloud:subject_selection'));
    assert.equal(events.some(e=>e.startsWith('execute:')),false);
  });
}

test('a ground self photo cannot bypass the hover requirement through a bare model response',async()=>{
  const {c,events}=await fixture({action:'photo'},true);
  await assert.rejects(c.runCloudVoiceRequest('给我拍一张照片'),/起飞|悬停/);
  assert.equal(events.some(e=>e==='takeoff'||e.startsWith('execute:')),false);
});

async function withRealCloud(c,commands,run){
  const previousKits=global.__neoKits,requests=[];
  global.__neoKits={...previousKits,
    '@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:bytes=>new TextDecoder().decode(bytes)})},
      Base64Helper:class{encodeToStringSync(bytes){return Buffer.from(bytes).toString('base64');}}}},
    '@kit.NetworkKit':{connection:{NetCap:{NET_CAPABILITY_INTERNET:12},getDefaultNet:async()=>({netId:100}),
      getNetCapabilities:async()=>({networkCap:[12]}),
      getConnectionProperties:async()=>({interfaceName:'test0',linkAddresses:[]})}},
    '@kit.RemoteCommunicationKit':{rcp:{Request:class{
      constructor(url,method,headers,content){Object.assign(this,{url,method,headers,content});}},
      createSession:()=>({close(){},cancel(){},fetch:async request=>{
        const index=requests.length;requests.push(JSON.parse(request.content));
        assert.ok(index<commands.length,'no unexpected cloud retry');
        const bytes=new TextEncoder().encode(JSON.stringify({choices:[{finish_reason:'stop',
          message:{content:JSON.stringify(commands[index])}}]}));
        request.destination(bytes.buffer);return {statusCode:200};
      }})}},
    '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){},error(){}}}
  };
  const modulePath=require.resolve('../entry/src/main/ets/core/platform/CloudVlmClient.ets');
  const previousModule=require.cache[modulePath];delete require.cache[modulePath];
  try{
    const {CloudVlmClient}=require(modulePath);
    c.cloudVlm=new CloudVlmClient({read:async()=> 'fake-test-key'});
    c.initializeCloudVlm=async()=>{};
    c.requestCloudAgentAction=AppController.prototype.requestCloudAgentAction;
    await run(requests);
  }finally{
    c.cloudVlm?.close();global.__neoKits=previousKits;
    if(previousModule)require.cache[modulePath]=previousModule;else delete require.cache[modulePath];
  }
}

test('ground closeup recovers one wrong selection response without repeating takeoff or changing the recipe',async()=>{
  const intent={action:'dolly_zoom',recipe:'dolly_circle',framing:'半身',zoom:3,retreat:true};
  const {c,events}=await fixture(intent,true);
  await withRealCloud(c,[intent,{...intent,subjectId:13},{action:'select_subject',subjectId:13}],async requests=>{
    const result=await c.runCloudVoiceRequest('给穿黑色衣服的男生拍特写镜头');
    assert.equal(result.confirmationRequired,true);
    assert.equal(requests.length,3);
    assert.equal(events.filter(e=>e==='takeoff').length,1);
    assert.equal(c.groundDolly.snapshot().stage,'confirm');
    assert.deepEqual(c.groundDolly.snapshot().plan,{...intent,subjectId:13});
    assert.equal(events.some(e=>e.startsWith('execute:')),false);
    assert.equal(requests[1].messages[1].content[0].text,requests[2].messages[1].content[0].text);
    assert.deepEqual(requests[1].messages[1].content.filter(p=>p.type==='image_url'),
      requests[2].messages[1].content.filter(p=>p.type==='image_url'));
    await c.confirmSubjectTask();
    assert.equal(c.groundDolly.snapshot().stage,'plan');
    assert.equal(events.some(e=>e.startsWith('execute:')),false);
  });
});

test('ground selection stops after one retry without selecting a fallback or restarting flight',async()=>{
  const intent={action:'dolly_zoom',recipe:'dolly_circle'};
  const {c,events,flags}=await fixture(intent,true);
  await withRealCloud(c,[intent,{action:'follow',subjectId:13},{action:'circle',subjectId:13}],async requests=>{
    await assert.rejects(c.runCloudVoiceRequest('给穿黑色衣服的男生拍特写镜头'),/选人阶段/);
    assert.equal(requests.length,3);
    assert.equal(events.filter(e=>e==='takeoff').length,1);
    assert.equal(flags.airborne,true);
    assert.equal(c.groundDolly.snapshot().stage,'failed');
    assert.equal(events.some(e=>e.startsWith('select:')||e.startsWith('execute:')),false);
  });
});

test('hover closeup still reuses a valid initial target with only one cloud request',async()=>{
  const intent={action:'dolly_zoom',recipe:'dolly_circle',subjectId:13,framing:'半身',zoom:3,retreat:true};
  const {c,events}=await fixture(intent);
  await withRealCloud(c,[intent],async requests=>{
    await c.runCloudVoiceRequest('给穿黑色衣服的男生拍特写镜头');
    assert.equal(requests.length,1);
    assert.equal(events.includes('takeoff'),false);
    assert.equal(c.groundDolly.snapshot().stage,'confirm');
    assert.deepEqual(c.groundDolly.snapshot().plan,intent);
    assert.equal(events.some(e=>e.startsWith('execute:')),false);
  });
});
