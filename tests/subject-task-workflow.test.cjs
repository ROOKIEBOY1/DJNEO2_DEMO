const {test}=require('node:test');
const assert=require('node:assert/strict');
const {SubjectTaskWorkflow}=require('../entry/src/main/ets/core/domain/SubjectTaskWorkflow.ets');

function deferred(){let resolve;const promise=new Promise(done=>{resolve=done;});return {promise,resolve};}
function fixture(overrides={}){
  let now=1000;const calls=[];
  const port={isCurrent:()=>true,takeoff:async()=>{calls.push('takeoff');},
    waitForCandidates:async()=>{calls.push('scan');},
    select:async()=>{calls.push('select');return {action:'select_subject',subjectId:13};},
    shoot:async command=>{calls.push(command);return {message:'已执行'};},...overrides};
  const flow=new SubjectTaskWorkflow(()=>{},()=>now);
  return {flow,port,calls,advance:ms=>{now+=ms;}};
}

for(const [intent,want,stage] of [
  [{action:'follow'},{action:'follow',subjectId:13},'shooting'],
  [{action:'circle',radiusMeters:5},{action:'circle',subjectId:13,radiusMeters:5},'shooting'],
  [{action:'record_start',subjectRequired:true},{action:'record_start',subjectId:13},'shooting'],
  [{action:'photo',subjectRequired:true},{action:'photo',subjectId:13},'completed'],
  [{action:'select_subject',subjectRequired:true},{action:'select_subject',subjectId:13},'completed']
])test(`${intent.action} waits for subject confirmation and then executes once without a second confirmation`,async()=>{
  const {flow,port,calls}=fixture();
  const result=await flow.start('白衣男生',intent,port,'hover');
  assert.equal(result.confirmationRequired,true);assert.equal(flow.snapshot().stage,'confirm');
  assert.equal(flow.snapshot().subjectId,13);assert.deepEqual(calls,['scan','select']);
  await assert.rejects(flow.execute(),/方案/);
  await flow.confirm();assert.deepEqual(calls.at(-1),want);
  assert.equal(flow.snapshot().stage,stage);assert.equal(flow.snapshot().active,false);
  await assert.rejects(flow.confirm(),/确认/);await assert.rejects(flow.execute(),/方案/);
  assert.equal(calls.length,3);
});

test('generic dolly confirmation produces the original plan and only execute starts it',async()=>{
  const {flow,port,calls}=fixture();
  await flow.start('特写组合',{action:'dolly_zoom',zoom:3,framing:'半身',retreat:false,recipe:'dolly_circle'},port);
  assert.deepEqual(calls,['takeoff','scan','select']);
  await flow.confirm();assert.equal(flow.snapshot().stage,'plan');
  assert.deepEqual(flow.snapshot().plan,{action:'dolly_zoom',subjectId:13,zoom:3,framing:'半身',retreat:false,recipe:'dolly_circle'});
  assert.equal(calls.length,3);await flow.execute();assert.equal(calls.length,4);
  assert.equal(flow.snapshot().stage,'shooting');await assert.rejects(flow.execute());
});

test('ground follow and circle may take off while photo, recording and selection never add a takeoff',async()=>{
  for(const action of ['follow','circle','photo','select_subject','record_start']){
    const {flow,port,calls}=fixture();await flow.start('主体',{action},port,'ground');
    assert.deepEqual(calls,action==='follow'||action==='circle'?['takeoff','scan','select']:['scan','select']);
    assert.equal(flow.snapshot().entry,'ground');assert.equal(flow.snapshot().stage,'confirm');
  }
});

test('selection cannot rewrite an action, action parameters or the frozen input and exported plan',async()=>{
  const wait=deferred();const intent={action:'circle',radiusMeters:5,zoom:3,recipe:'dolly_circle'};
  const {flow,port,calls}=fixture({select:()=>wait.promise});
  const running=flow.start('环绕',intent,port,'hover');await Promise.resolve();
  intent.radiusMeters=9;
  wait.resolve({action:'select_subject',subjectId:13,radiusMeters:10,zoom:2,recipe:'dolly_circle'});
  await running;const snapshot=flow.snapshot();snapshot.plan.radiusMeters=8;snapshot.plan.subjectId=99;
  await flow.confirm();assert.deepEqual(calls.at(-1),{action:'circle',subjectId:13,radiusMeters:5});
});

test('non-selection model replies fail without replacing the requested action',async()=>{
  for(const selected of [{action:'circle',subjectId:13,radiusMeters:4},{action:'none',message:'没有找到'},
    {action:'select_subject'},{action:'select_subject',subjectId:-1}]){
    const {flow,port,calls}=fixture({select:async()=>selected});
    await assert.rejects(flow.start('跟随',{action:'follow'},port,'hover'));
    assert.equal(flow.snapshot().stage,'failed');assert.equal(flow.snapshot().subjectId,undefined);
    await assert.rejects(flow.confirm());assert.deepEqual(calls,['scan']);
  }
});

test('each action copies only its own parameters when sent to the execution port',async()=>{
  for(const [intent,want] of [
    [{action:'dolly_zoom',zoom:2,framing:'全身',retreat:true,recipe:'dolly_circle',radiusMeters:5,seconds:2},
      {action:'dolly_zoom',subjectId:13,zoom:2,framing:'全身',retreat:true,recipe:'dolly_circle'}],
    [{action:'follow',radiusMeters:4,zoom:3},{action:'follow',subjectId:13}],
    [{action:'photo',recipe:'dolly_circle'},{action:'photo',subjectId:13}],
    [{action:'record_start',subjectRequired:true,radiusMeters:4,zoom:3,recipe:'dolly_circle'},
      {action:'record_start',subjectId:13}],
    [{action:'select_subject',zoom:3},{action:'select_subject',subjectId:13}]
  ]){
    const {flow,port,calls}=fixture();await flow.start('主体',intent,port,'hover');await flow.confirm();
    if(intent.action==='dolly_zoom')await flow.execute();assert.deepEqual(calls.at(-1),want);
  }
});

test('duplicate confirmation during an awaited action cannot dispatch a second action and hides the selected frame immediately',async()=>{
  for(const action of ['follow','record_start']){
    const wait=deferred();const {flow,port,calls}=fixture({shoot:async command=>{calls.push(command);return wait.promise;}});
    await flow.start('指定主体',{action},port,'hover');const first=flow.confirm();
    assert.equal(flow.snapshot().stage,'starting');assert.equal(flow.snapshot().active,true);
    await assert.rejects(flow.confirm());await assert.rejects(flow.execute());
    assert.equal(calls.length,3);wait.resolve({message:'已启动'});await first;
    assert.equal(flow.snapshot().stage,'shooting');
  }
});

test('expiry, session changes and cancel prevent confirmed actions from starting',async()=>{
  for(const action of ['follow','circle','photo','select_subject','record_start','dolly_zoom'])for(const reason of ['expire','session','cancel']){
    const {flow,port,calls,advance}=fixture();await flow.start('主体',{action},port,'hover');
    if(action==='dolly_zoom')await flow.confirm();
    if(reason==='expire')advance(30000);else if(reason==='session')port.isCurrent=()=>false;else flow.cancel();
    await assert.rejects(action==='dolly_zoom'?flow.execute():flow.confirm());
    assert.equal(flow.snapshot().active,false);assert.equal(flow.snapshot().plan,undefined);
    assert.deepEqual(calls,['scan','select']);
  }
});

test('cancellation after each awaited preparation step cannot progress or revive a replaced request',async()=>{
  for(const step of ['takeoff','waitForCandidates','select']){
    const wait=deferred();const {flow,port}=fixture({[step]:()=>wait.promise});
    const first=flow.start('旧目标',{action:'follow'},port,'ground');
    await Promise.resolve();await Promise.resolve();flow.cancel();
    const fresh={...port,takeoff:async()=>{},waitForCandidates:async()=>{},select:async()=>({action:'select_subject',subjectId:21})};
    await flow.start('新目标',{action:'circle',radiusMeters:4},fresh,'hover');
    wait.resolve({action:'select_subject',subjectId:13});await assert.rejects(first,/取消|变化/);
    assert.equal(flow.snapshot().subjectId,21);assert.equal(flow.snapshot().plan.action,'circle');
  }
});

test('cancel while an action awaits cannot revive old progress after a new selection',async()=>{
  const wait=deferred();const {flow,port}=fixture({shoot:()=>wait.promise});
  await flow.start('旧目标',{action:'follow'},port,'hover');const first=flow.confirm();flow.cancel();
  await flow.start('新目标',{action:'photo'},port,'hover');
  wait.resolve({message:'旧任务返回'});await assert.rejects(first,/取消|变化/);
  assert.equal(flow.snapshot().stage,'confirm');assert.equal(flow.snapshot().plan.action,'photo');
});

test('pending media outcomes preserve shooting and active work cannot be retired',async()=>{
  for(const action of ['follow','circle','dolly_zoom','record_start']){
    const result={message:'录像待回传',confirmationRequired:false};const {flow,port}=fixture({shoot:async()=>result});
    await flow.start('主体',{action},port,'hover');assert.equal(flow.retireInactive(),false);
    const confirmed=await flow.confirm();const outcome=action==='dolly_zoom'?await flow.execute():confirmed;
    assert.equal(outcome,result);assert.equal(flow.snapshot().stage,'shooting');
    assert.equal(flow.retireInactive(),true);assert.equal(flow.snapshot().stage,'idle');assert.equal(flow.snapshot().plan,undefined);
  }
});

test('unsupported intents fail before scanning or takeoff',async()=>{
  const {flow,port,calls}=fixture();await assert.rejects(flow.start('起飞',{action:'takeoff'},port),/主体/);
  assert.deepEqual(calls,[]);
});
