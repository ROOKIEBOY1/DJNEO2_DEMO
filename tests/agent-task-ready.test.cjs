const {test}=require('node:test');const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {CancellationToken}=require('../entry/src/main/ets/core/domain/OperationResult.ets');

function fixture(){
  const c=Object.create(AppController.prototype);const calls=[];let selected=false;let mode=26;let id=13;let polls=0;let sync=true;
  const token=new CancellationToken(2);
  const observation={sessionId:10,flightGeneration:2,controlGeneration:0,frame:{currentSubjectId:13,candidates:[{id:13}]}};
  Object.assign(c,{agentGeneration:0,emit(){},log(){},nativeConfig:{framing:'半身',zoom:3,retreat:true,radiusMeters:2},
    session:{sessionId:()=>10,isReliableLinkFresh:()=>true,snapshot:()=>{
      if(selected && ++polls>=3 && sync)mode=26;
      return {telemetry:{flightAgeMs:0,flight:{modeRaw:mode,airborne:true,motorsOn:true},taskAgeMs:0,
        task:{phaseRaw:0,modeRaw:0},cameraAgeMs:0,camera:{recordingCandidate:false},
        subject:{tracking:true,overlay:[{id}],trackingAt:Date.now()}}};
    }},flight:{snapshot:()=>({generation:2,takeoffSent:true,takeoffAcknowledged:true,nativeTaskMayFly:false,movementActive:false})},
    nativeTasks:{activeOrUnknown:()=>false,prepareHover:async()=>{calls.push('prepare');return {ok:true,data:true};}}});
  c.handoffCompletedNativeTask=async()=>{};c.releaseHoverTaskTarget=async()=>{calls.push('release');};
  c.applyAgentDollySettings=()=>{};
  c.requestSubjectSelection=async()=>{calls.push('select');selected=true;mode=6;return {ok:true,data:'selected'};};
  c.startNativeWithCapture=async()=>{calls.push('start');assert.equal(mode,26,'flight mode must catch up before native start');return {ok:true,data:'started'};};
  return {c,calls,token,observation,polls:()=>polls,wrongTarget:()=>{id=11;},holdTransition:()=>{sync=false;},
    synchronize:()=>{mode=26;}};
}

test('selected task waits for the acknowledged target AND synchronized flight mode before starting exactly once',async()=>{
  const {c,calls,token,observation,polls}=fixture();
  const result=await c.startAgentSubjectTask('dolly',observation,{action:'dolly_zoom',subjectId:13},token);
  assert.equal(result.message,'started');assert.deepEqual(calls,['release','prepare','select','start']);
  assert.ok(polls()>=3);
});

test('a new tracked ID during readiness never authorizes a start',async()=>{
  const {c,calls,token,observation,wrongTarget}=fixture();const select=c.requestSubjectSelection;
  c.requestSubjectSelection=async()=>{const result=await select();wrongTarget();return result;};
  await assert.rejects(c.startAgentSubjectTask('dolly',observation,{action:'dolly_zoom',subjectId:13},token),/主体|跟踪/);
  assert.equal(calls.includes('start'),false);
});

test('cancellation while flight mode is catching up stops readiness without queuing the movement',async()=>{
  const {c,calls,token,observation,holdTransition}=fixture();holdTransition();
  const cancel=setTimeout(()=>token.cancel(),10);
  try {
    await assert.rejects(c.startAgentSubjectTask('dolly',observation,{action:'dolly_zoom',subjectId:13},token),/取消|变化/);
    assert.equal(calls.includes('start'),false);
  } finally {clearTimeout(cancel);}
});

test('a flight mode that never catches up times out without starting',async()=>{
  const {c,calls,token,observation,holdTransition}=fixture();holdTransition();
  await assert.rejects(c.startAgentSubjectTask('dolly',observation,{action:'dolly_zoom',subjectId:13},token),/尚未同步/);
  assert.equal(calls.includes('start'),false);
});

test('a changed session, flight, control or ownership during selection cannot queue a start',async()=>{
  for(const change of [
    c=>{c.agentGeneration++;},c=>{c.session.sessionId=()=>11;},
    c=>{c.flight.snapshot=()=>({generation:3,takeoffSent:true,takeoffAcknowledged:true});},
    c=>{c.flight.snapshot=()=>({generation:2,takeoffSent:true,takeoffAcknowledged:true,landRequested:true});},
    c=>{c.flight.snapshot=()=>({generation:2,takeoffSent:true,takeoffAcknowledged:true,movementActive:true});},
    c=>{c.nativeTasks.activeOrUnknown=()=>true;}
  ]) {
    const {c,calls,token,observation}=fixture();const select=c.requestSubjectSelection;
    c.requestSubjectSelection=async()=>{const result=await select();change(c);return result;};
    await assert.rejects(c.startAgentSubjectTask('dolly',observation,{action:'dolly_zoom',subjectId:13},token),/取消|变化/);
    assert.equal(calls.includes('start'),false);
  }
});

test('an already synchronized target starts on the first ready snapshot without a fixed sleep',async()=>{
  const {c,calls,token,observation,synchronize,polls}=fixture();const select=c.requestSubjectSelection;
  c.requestSubjectSelection=async()=>{const result=await select();synchronize();return result;};
  await c.startAgentSubjectTask('dolly',observation,{action:'dolly_zoom',subjectId:13},token);
  assert.equal(polls(),1);assert.equal(calls.filter(x=>x==='start').length,1);
});
