const {test}=require('node:test');
const assert=require('node:assert/strict');
const {CloseupSubjectGuard}=require('../entry/src/main/ets/core/domain/CloseupSubjectGuard.ets');

const track=(id,at)=>({tracking:true,trackingAt:at,overlay:[{id}],candidates:[{id}],selectedIdCandidate:id});

test('native runtime absence stays unknown without becoming target evidence or a different identity',()=>{
  const guard=new CloseupSubjectGuard(11);
  assert.equal(guard.assess(track(11,1000),1000),'confirmed');
  for(const now of [1250,2001,5000]){
    assert.equal(guard.assess(undefined,now),'unknown');
    assert.equal(guard.assess({tracking:false,candidates:[{id:11}],overlay:[{id:11}]},now),'unknown');
    assert.equal(guard.assess({tracking:false,candidates:[],overlay:[],detectionAt:now},now),'unknown');
  }
  assert.equal(guard.assess(track(11,5001),5001),'confirmed');
});

test('only a fresh positive different tracking identity requests native runtime stop',()=>{
  const guard=new CloseupSubjectGuard(11);
  assert.equal(guard.assess(track(12,1000),1000),'different');
  assert.equal(guard.assess(track(12,1000),2000),'different');
  assert.equal(guard.assess(track(12,1000),2001),'unknown');
  assert.equal(guard.assess({tracking:false,candidates:[{id:12}],overlay:[{id:12}]},1000),'unknown');
  assert.equal(guard.assess({...track(12,1000),overlay:[{id:12},{id:13}]},1000),'unknown');
});

test('stale future missing or invalid timestamps cannot identify a current target or replacement',()=>{
  for(const id of [11,12])for(const at of [0,2500,NaN,Infinity,-1,undefined]){
    assert.equal(new CloseupSubjectGuard(11).assess(track(id,at),1999),'unknown',String(at));
  }
  for(const now of [NaN,Infinity,-Infinity,-1]){
    assert.equal(new CloseupSubjectGuard(11).assess(track(11,1000),now),'unknown');
  }
});
