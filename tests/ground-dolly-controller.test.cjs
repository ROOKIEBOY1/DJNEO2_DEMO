const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {SubjectTaskWorkflow}=require('../entry/src/main/ets/core/domain/SubjectTaskWorkflow.ets');

function fixture(){
  const c=Object.create(AppController.prototype);const calls=[];let airborne=false;let gen=2;let selected;
  const boxes=[{id:11},{id:13}];
  const subject=()=>({candidates:boxes,detectionAt:Date.now(),trackingAt:Date.now(),
    tracking:selected!==undefined,overlay:selected===undefined?boxes:[{id:selected}],selectedIdCandidate:selected});
  Object.assign(c,{agentGeneration:0,emit(){},log(){},finishAgentObservation(id){calls.push(['finish',id]);},
    ensureAgentObservation(){},busyValue:false,isOrdinarySubjectHover:()=>true,
    // This fixture checks retained task parameters/confirmation. Search motion
    // and the real stable-hover barrier have dedicated Controller replays.
    ensureDollyHoverReady(){},settleSubjectSearch:async()=>Date.now(),
    video:{snapshot:()=>({state:'live'})},groundDolly:new SubjectTaskWorkflow(()=>{}),captureMedia:{hasPending:()=>false},
    session:{sessionId:()=>10,isReliableLinkFresh:()=>true,snapshot:()=>({phase:'ready',telemetry:{
      flight:{airborne,motorsOn:airborne},flightAgeMs:0,task:{phaseRaw:0,modeRaw:0},subject:subject()}})},
    flight:{snapshot:()=>({generation:gen})}});
  let request=0;
  c.captureAgentObservation=async()=>{
    c.latestAgentRequestId=`r${++request}`;
    return {requestId:c.latestAgentRequestId,sessionId:10,flightGeneration:gen,
    controlGeneration:0,requestedAtMs:Date.now(),context:{flightStateFresh:true,airborne,framing:'全身',zoom:2,retreat:true},
    frame:airborne?{sessionId:10,capturedAtMs:Date.now(),candidatesObservedAtMs:Date.now(),candidates:boxes,currentSubjectId:selected}:undefined};
  };
  c.requestCloudAgentAction=async(obs,text)=>{
    calls.push(['cloud',obs.purpose,obs.flightGeneration,text]);
    return {version:2,requestId:obs.requestId,command:obs.purpose==='ground_dolly_intent'?
      {action:'dolly_zoom',framing:'半身',zoom:3,retreat:false}:{action:'select_subject',subjectId:13}};
  };
  c.performVoiceFlightAction=async()=>{calls.push(['takeoff']);airborne=true;gen++;return {message:'起飞'};};
  c.performAgentAction=async(obs,command)=>{
    calls.push(['execute',command,obs.flightGeneration,obs.frame?.currentSubjectId]);
    if(command.action==='select_subject')selected=command.subjectId;
    return {message:'已执行'};
  };
  return {c,calls,changeTarget:()=>{selected=11;},loseSession:()=>{c.agentGeneration++;}};
}
test('controller uses ground intent and airborne VLM selection, then confirms a plan before executing retained parameters',async()=>{
  const {c,calls}=fixture();
  const result=await c.runCloudVoiceRequest('帮我给白衣男生拍三倍半身滑动变焦');
  assert.equal(result.confirmationRequired,true);
  assert.deepEqual(calls.filter(x=>x[0]==='cloud').map(x=>[x[1],x[2]]),[['ground_dolly_intent',2],['subject_selection',3]]);
  const before=calls.filter(x=>x[0]==='execute');assert.equal(before.length,1);
  assert.equal(before[0][1].action,'select_subject');
  await c.confirmGroundDolly();
  assert.equal(c.groundDolly.snapshot().stage,'plan');
  assert.equal(calls.filter(x=>x[0]==='execute').length,1);
  await c.executeGroundDolly();
  const shot=calls.filter(x=>x[0]==='execute')[1];
  assert.deepEqual(shot[1],{action:'dolly_zoom',subjectId:13,framing:'半身',zoom:3,retreat:false});
  assert.equal(shot[2],3);assert.equal(shot[3],13);
});

test('misheard Hitchcock request is normalized before both ground intent and airborne subject inference',async()=>{
  const {c,calls}=fixture();
  await c.runCloudVoiceRequest('给黑色衣服的男生拍一个戏曲QQ运镜。');
  const requests=calls.filter(x=>x[0]==='cloud');
  assert.equal(requests.length,2);
  for(const request of requests)assert.equal(request[3],'给黑色衣服的男生拍一个希区柯克运镜。');
});

test('closeup recipe and its defaults survive visual selection and subject confirmation into the plan',async()=>{
  const {c}=fixture();const cloud=c.requestCloudAgentAction;
  c.requestCloudAgentAction=async(obs,text)=>obs.purpose==='ground_dolly_intent'?
    {version:2,requestId:obs.requestId,command:{action:'dolly_zoom',recipe:'dolly_circle'}}:cloud(obs,text);
  await c.runCloudVoiceRequest('帮黑色衣服的男生拍一段特写镜头');await c.confirmGroundDolly();
  assert.deepEqual(c.groundDolly.snapshot().plan,{action:'dolly_zoom',recipe:'dolly_circle',subjectId:13,
    framing:'半身',zoom:3,retreat:true});
});
test('controller never shoots if target changed or control cancelled before executing a confirmed plan',async()=>{
  for(const change of ['target','cancel']){
    const {c,calls,changeTarget,loseSession}=fixture();await c.runCloudVoiceRequest('白衣男生滑动变焦');
    await c.confirmGroundDolly();
    if(change==='target')changeTarget();else loseSession();
    await assert.rejects(c.executeGroundDolly());
    assert.equal(calls.filter(x=>x[0]==='execute'&&x[1].action==='dolly_zoom').length,0);
  }
});
test('ground photo and unclear visual selection retain normal action handling or stop without filming',async()=>{
  const normal=fixture();let accepted=0;
  normal.c.requestCloudAgentAction=async obs=>({version:2,requestId:obs.requestId,command:{action:'photo'}});
  normal.c.acceptAgentResponse=async()=>{accepted++;return {message:'拍照'};};
  await normal.c.runCloudVoiceRequest('拍张照片');assert.equal(accepted,1);
  assert.equal(normal.calls.some(x=>x[0]==='takeoff'),false);
  const missing=fixture();const cloud=missing.c.requestCloudAgentAction;
  missing.c.requestCloudAgentAction=async(obs,text)=>obs.purpose==='subject_selection'?
    {version:2,requestId:obs.requestId,command:{action:'none',message:'未找到白衣男生'}}:cloud(obs,text);
  await assert.rejects(missing.c.runCloudVoiceRequest('白衣男生滑动变焦'),/未找到/);
  assert.equal(missing.calls.some(x=>x[0]==='execute'),false);
});
