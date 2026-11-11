const {test}=require('node:test');
const assert=require('node:assert/strict');
const {GroundDollyWorkflow}=require('../entry/src/main/ets/core/domain/GroundDollyWorkflow.ets');

function fixture(overrides={}) {
  const calls=[]; let now=1000;
  const host={isCurrent:()=>true,takeoff:async()=>{calls.push('takeoff');},
    waitForCandidates:async()=>{calls.push('scan');},
    select:async()=>{calls.push('select');return {action:'dolly_zoom',subjectId:13,zoom:3,framing:'半身'};},
    shoot:async command=>{calls.push(['shoot',command.subjectId,command.zoom]);return {message:'已启动'};},...overrides};
  const flow=new GroundDollyWorkflow(()=>{},()=>now);
  return {flow,host,calls,expire:()=>{now+=30001;}};
}
test('ground demo confirms a subject into a flight plan and only the execute click starts shooting once',async()=>{
  const {flow,host,calls}=fixture();
  const result=await flow.start('白衣男生三倍半身希区柯克',{action:'dolly_zoom'},host);
  assert.equal(result.confirmationRequired,true);assert.equal(flow.snapshot().subjectId,13);
  assert.deepEqual(calls,['takeoff','scan','select']);
  await flow.confirm();
  assert.equal(flow.snapshot().stage,'plan');assert.equal(flow.snapshot().active,true);
  assert.deepEqual(flow.snapshot().plan,{action:'dolly_zoom',subjectId:13,zoom:3,framing:'半身'});
  assert.deepEqual(calls,['takeoff','scan','select']);
  await assert.rejects(flow.confirm(),/确认/);
  await flow.execute();assert.deepEqual(calls[3],['shoot',13,3]);
  assert.equal(flow.snapshot().stage,'shooting');assert.equal(flow.snapshot().plan.zoom,3);
  await assert.rejects(flow.execute(),/方案/);assert.equal(calls.length,4);
});

test('hover entry scans and verifies the subject without a second takeoff, retaining the same two confirmations',async()=>{
  const {flow,host,calls}=fixture({takeoff:async()=>{throw Error('不得重复起飞');}});
  const result=await flow.start('帮黑衣男生拍特写',{action:'dolly_zoom',recipe:'dolly_circle'},host,'hover');
  assert.equal(result.confirmationRequired,true);assert.equal(flow.snapshot().entry,'hover');
  assert.deepEqual(calls,['scan','select']);assert.equal(flow.snapshot().stage,'confirm');
  await flow.confirm();assert.equal(flow.snapshot().stage,'plan');
  assert.deepEqual(calls,['scan','select']);
  await flow.execute();assert.deepEqual(calls.at(-1),['shoot',13,3]);
  assert.equal(flow.snapshot().stage,'shooting');assert.equal(flow.snapshot().entry,'hover');
});

test('hover preparation exposes scanning and can be cancelled before selection without taking off',async()=>{
  const {flow,host,calls}=fixture();let release;
  host.waitForCandidates=async()=>{calls.push('scan');await new Promise(resolve=>{release=resolve;});};
  const running=flow.start('再拍一段特写',{action:'dolly_zoom'},host,'hover');
  assert.equal(flow.snapshot().stage,'scanning');assert.equal(flow.snapshot().entry,'hover');
  assert.deepEqual(calls,['scan']);
  flow.cancel();release();await assert.rejects(running,/取消|变化/);
  await assert.rejects(flow.confirm());assert.deepEqual(calls,['scan']);
});

test('hover confirmation and accepted plans expire without ever sending a shooting or takeoff command',async()=>{
  for(const stage of ['confirm','plan']){
    const {flow,host,calls,expire}=fixture();
    await flow.start('悬停中特写',{action:'dolly_zoom'},host,'hover');
    if(stage==='plan')await flow.confirm();
    expire();
    await assert.rejects(stage==='confirm'?flow.confirm():flow.execute());
    assert.equal(flow.snapshot().active,false);assert.deepEqual(calls,['scan','select']);
  }
});

test('selected command and exported plan cannot be mutated to change the confirmed execution',async()=>{
  const selected={action:'dolly_zoom',subjectId:13,zoom:3,framing:'半身',retreat:false};
  const {flow,host,calls}=fixture({select:async()=>selected});
  await flow.start('拍运镜',{action:'dolly_zoom'},host);
  selected.zoom=2;selected.subjectId=99;
  await flow.confirm();
  const snapshot=flow.snapshot();snapshot.plan.zoom=2;snapshot.plan.subjectId=101;
  await flow.execute();
  assert.deepEqual(calls.at(-1),['shoot',13,3]);
});
test('ground demo stops on missing or ambiguous targets and never starts filming',async()=>{
  for(const selected of [{action:'none',message:'没有找到白衣男生'},{action:'dolly_zoom'}, {action:'photo',subjectId:13}]){
    const {flow,host,calls}=fixture({select:async()=>selected});
    await assert.rejects(flow.start('拍运镜',{action:'dolly_zoom'},host));
    assert.equal(flow.snapshot().stage,'failed');await assert.rejects(flow.confirm());
    assert.deepEqual(calls,['takeoff','scan']);
  }
});
test('cancellation during takeoff or inference prevents all later steps and confirmation',async()=>{
  for(const step of ['takeoff','select']){
    const {flow,host,calls}=fixture();
    const original=host[step];host[step]=async(...args)=>{const result=await original(...args);flow.cancel();return result;};
    await assert.rejects(flow.start('拍运镜',{action:'dolly_zoom'},host),/取消|变化/);
    await assert.rejects(flow.confirm());assert.equal(calls.some(x=>Array.isArray(x)),false);
    if(step==='takeoff')assert.deepEqual(calls,['takeoff']);
  }
});
test('expired or invalidated confirmation cannot start and concurrent starts are rejected',async()=>{
  for(const invalidate of ['expired','session','cancel']){
    const {flow,host,calls,expire}=fixture();await flow.start('拍运镜',{action:'dolly_zoom'},host);
    await assert.rejects(flow.start('再拍',{action:'dolly_zoom'},host),/流程/);
    if(invalidate==='expired')expire();else if(invalidate==='session')host.isCurrent=()=>false;else flow.cancel();
    await assert.rejects(flow.confirm());assert.equal(calls.length,3);
  }
});
test('expired, cancelled or invalidated flight plans cannot execute or queue another start',async()=>{
  for(const invalidate of ['expired','session','cancel']){
    const {flow,host,calls,expire}=fixture();await flow.start('拍运镜',{action:'dolly_zoom'},host);
    await flow.confirm();
    await assert.rejects(flow.start('再拍',{action:'dolly_zoom'},host),/流程/);
    if(invalidate==='expired')expire();else if(invalidate==='session')host.isCurrent=()=>false;else flow.cancel();
    await assert.rejects(flow.execute(),/方案/);
    assert.equal(flow.snapshot().active,false);assert.equal(flow.snapshot().plan,undefined);
    assert.deepEqual(calls,['takeoff','scan','select']);
  }
});

test('takeoff failure prevents scan and duplicate execution while shooting does not double start',async()=>{
  const failed=fixture({takeoff:async()=>{throw new Error('未确认起飞');}});
  await assert.rejects(failed.flow.start('拍运镜',{action:'dolly_zoom'},failed.host),/未确认起飞/);
  assert.deepEqual(failed.calls,[]);
  const {flow,host,calls}=fixture();await flow.start('拍运镜',{action:'dolly_zoom'},host);
  await flow.confirm();
  let done;host.shoot=async()=>{calls.push('shoot');await new Promise(r=>{done=r;});return {message:'启动'};};
  const first=flow.execute();await assert.rejects(flow.execute());done();await first;
  assert.equal(calls.filter(x=>x==='shoot').length,1);
});

test('cancelling an inactive shooting workflow retires its old progress without starting another action',async()=>{
  const {flow,host,calls}=fixture();
  await flow.start('拍运镜',{action:'dolly_zoom'},host);await flow.confirm();await flow.execute();
  flow.cancel();
  assert.equal(flow.snapshot().stage,'idle');assert.equal(flow.snapshot().active,false);
  assert.equal(flow.snapshot().plan,undefined);assert.equal(flow.snapshot().message,'');
  assert.equal(calls.length,4);
});

test('inactive presentation can be retired while active subject confirmation and execution stay intact',async()=>{
  const {flow,host}=fixture();
  await flow.start('拍运镜',{action:'dolly_zoom'},host);await flow.confirm();
  assert.equal(flow.retireInactive(),false);assert.equal(flow.snapshot().stage,'plan');
  await flow.execute();
  assert.equal(flow.retireInactive(),true);assert.equal(flow.snapshot().stage,'idle');
  assert.equal(flow.snapshot().plan,undefined);
});

test('legacy visual selection cannot overwrite explicit frozen dolly parameters or inject a recipe',async()=>{
  const intent={action:'dolly_zoom',framing:'全身',zoom:2,retreat:false};
  const selected={action:'dolly_zoom',subjectId:13,framing:'半身',zoom:3,retreat:true,recipe:'dolly_circle'};
  let executed;
  const {flow,host}=fixture({select:async()=>selected,shoot:async command=>{executed=command;return {message:'启动'};}});
  await flow.start('全身两倍关闭渐远',intent,host,'hover');
  intent.zoom=3;intent.recipe='dolly_circle';
  await flow.confirm();
  assert.deepEqual(flow.snapshot().plan,{action:'dolly_zoom',subjectId:13,framing:'全身',zoom:2,retreat:false});
  await flow.execute();
  assert.deepEqual(executed,{action:'dolly_zoom',subjectId:13,framing:'全身',zoom:2,retreat:false});
});

test('legacy selection cannot remove frozen parameters or a recipe omitted from its reply',async()=>{
  const {flow,host}=fixture({select:async()=>({action:'dolly_zoom',subjectId:13})});
  await flow.start('拍特写组合',{action:'dolly_zoom',framing:'半身',zoom:3,retreat:true,recipe:'dolly_circle'},host,'hover');
  await flow.confirm();
  assert.deepEqual(flow.snapshot().plan,{action:'dolly_zoom',subjectId:13,framing:'半身',zoom:3,retreat:true,recipe:'dolly_circle'});
});

test('legacy bare dolly selection may fill missing shooting defaults but cannot add a new recipe',async()=>{
  const {flow,host}=fixture({select:async()=>({action:'dolly_zoom',subjectId:13,framing:'半身',zoom:3,retreat:false,recipe:'dolly_circle'})});
  await flow.start('拍运镜',{action:'dolly_zoom'},host,'hover');await flow.confirm();
  assert.deepEqual(flow.snapshot().plan,{action:'dolly_zoom',subjectId:13,framing:'半身',zoom:3,retreat:false});
});
