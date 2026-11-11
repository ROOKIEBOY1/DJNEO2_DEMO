const {test}=require('node:test');
const assert=require('node:assert/strict');
const {SubjectSelectionWorkflow}=require('../entry/src/main/ets/core/domain/SubjectSelectionWorkflow.ets');

function deferred(){let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};}
function fixture(overrides={}){
  let now=1000;const calls=[];
  const port={isCurrent:()=>true,waitForCandidates:async()=>{calls.push('scan');},
    select:async description=>{calls.push(['select',description]);return 13;},...overrides};
  const flow=new SubjectSelectionWorkflow(()=>{},()=>now);
  return {flow,port,calls,advance:ms=>{now+=ms;}};
}

test('independent selection scans and chooses a target but requires explicit confirmation before consumption',async()=>{
  const {flow,port,calls}=fixture();
  await flow.start('白衣男生',port);
  assert.deepEqual(calls,['scan',['select','白衣男生']]);
  assert.equal(flow.snapshot().stage,'confirm');assert.equal(flow.snapshot().subjectId,13);
  assert.throws(()=>flow.consume(),/确认/);
  assert.equal(flow.confirm(),13);assert.equal(flow.snapshot().stage,'confirmed');
  assert.throws(()=>flow.confirm(),/确认/);
  assert.equal(flow.consume(),13);assert.equal(flow.snapshot().active,false);
  assert.throws(()=>flow.consume(),/确认/);
});

test('selection expires at thirty seconds both before confirmation and while a confirmed target awaits consumption',async()=>{
  for(const confirmed of [false,true]){
    const {flow,port,advance}=fixture();await flow.start('目标',port);
    if(confirmed)flow.confirm();advance(30000);
    assert.throws(()=>confirmed?flow.consume():flow.confirm(),/确认/);
    assert.equal(flow.snapshot().stage,'failed');assert.equal(flow.snapshot().subjectId,undefined);
  }
});

test('selection rejects invalid candidate identifiers and a stale host before confirmation',async()=>{
  for(const id of [undefined,-1,256,1.5,NaN]){
    const {flow,port}=fixture({select:async()=>id});await assert.rejects(flow.start('目标',port),/主体/);
    assert.equal(flow.snapshot().stage,'failed');assert.equal(flow.snapshot().subjectId,undefined);
  }
  const {flow,port}=fixture();await flow.start('目标',port);port.isCurrent=()=>false;
  assert.throws(()=>flow.confirm(),/确认/);assert.equal(flow.snapshot().active,false);
});

test('cancelling a scan prevents model selection and cancelling inference rejects its late target',async()=>{
  for(const step of ['waitForCandidates','select']){
    const wait=deferred();const {flow,port,calls}=fixture();
    port[step]=()=>wait.promise;
    const running=flow.start('旧目标',port);await Promise.resolve();
    flow.cancel();wait.resolve(13);await assert.rejects(running,/取消|变化/);
    assert.equal(flow.snapshot().stage,'cancelled');assert.equal(flow.snapshot().subjectId,undefined);
    assert.throws(()=>flow.confirm());
    if(step==='waitForCandidates')assert.deepEqual(calls,[]);
  }
});

test('a superseded inference cannot overwrite a new target or its confirmation',async()=>{
  const old=deferred();const {flow,port}=fixture({select:()=>old.promise});
  const first=flow.start('旧目标',port);await Promise.resolve();flow.cancel();
  const replacement={...port,select:async()=>21};await flow.start('新目标',replacement);
  old.resolve(13);await assert.rejects(first,/取消|变化/);
  assert.equal(flow.snapshot().subjectId,21);assert.equal(flow.confirm(),21);
});

test('an overlapping selection cannot replace its active target and inactive presentation can be retired',async()=>{
  const {flow,port}=fixture();await flow.start('目标',port);
  await assert.rejects(flow.start('另一个',port),/流程/);
  assert.equal(flow.retireInactive(),false);assert.equal(flow.snapshot().subjectId,13);
  flow.confirm();flow.consume();assert.equal(flow.retireInactive(),true);
  assert.equal(flow.snapshot().stage,'idle');assert.equal(flow.snapshot().subjectId,undefined);
});
