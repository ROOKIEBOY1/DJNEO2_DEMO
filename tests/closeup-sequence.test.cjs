const {test}=require('node:test');
const assert=require('node:assert/strict');
const {CloseupSequence}=require('../entry/src/main/ets/core/domain/CloseupSequence.ets');

function deferred(){let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};}
const names=['startDolly','finishDolly','startCircle','finishCircle','returnMedia'];
function fixture(){
  const calls=[];const states=[];const gates=[];let current=true;
  const sequence=new CloseupSequence(()=>states.push(sequence.snapshot()));
  const port={isCurrent:()=>current};
  for(const name of names){
    port[name]=async gate=>{calls.push(name);gates.push(gate);assert.equal(gate(),true);};
  }
  return {sequence,port,calls,states,gates,invalidate:()=>{current=false;}};
}

test('closeup sequence finishes both movements before returning media once at the end',async()=>{
  const {sequence,port,calls,states}=fixture();
  assert.deepEqual(sequence.snapshot(),{active:false,stage:'idle',step:0,message:''});
  await sequence.run(port);
  assert.deepEqual(calls,names);
  assert.deepEqual(states.map(x=>[x.stage,x.step,x.active]),[
    ['dolly',1,true],['dolly_wait',1,true],['circle',2,true],['circle_wait',2,true],['returning',2,true],['completed',2,false]]);
  assert.doesNotMatch(states.filter(x=>['dolly','dolly_wait','circle','circle_wait'].includes(x.stage)).map(x=>x.message).join('\n'),/取回/);
  assert.equal(sequence.snapshot().stage,'completed');
});

test('a deferred first task completion blocks circle and rejects a concurrent run without queuing',async()=>{
  const {sequence,port,calls}=fixture();const waiting=deferred();
  port.finishDolly=async gate=>{calls.push('finishDolly');assert.equal(gate(),true);await waiting.promise;};
  const running=sequence.run(port);await Promise.resolve();
  assert.deepEqual(calls,['startDolly','finishDolly']);
  assert.deepEqual([sequence.snapshot().stage,sequence.snapshot().active],['dolly_wait',true]);
  await assert.rejects(sequence.run(port),/流程|执行/);
  assert.deepEqual(calls,['startDolly','finishDolly']);
  waiting.resolve();await running;
  assert.deepEqual(calls,names);
});

test('ending circle is not complete until the single final media return settles',async()=>{
  const {sequence,port,calls}=fixture();const entered=deferred();const waiting=deferred();
  port.returnMedia=async gate=>{calls.push('returnMedia');entered.resolve();assert.equal(gate(),true);await waiting.promise;};
  const running=sequence.run(port);await Promise.race([entered.promise,running]);
  assert.deepEqual(calls,names);assert.equal(sequence.snapshot().stage,'returning');
  assert.equal(sequence.snapshot().step,2);assert.equal(sequence.snapshot().active,true);
  await assert.rejects(sequence.run(port),/流程|执行/);
  waiting.resolve();await running;assert.equal(sequence.snapshot().stage,'completed');
  assert.equal(calls.filter(x=>x==='returnMedia').length,1);
});

test('cancellation at any in-flight stage invalidates supplied gates and prevents every following stage',async()=>{
  for(let index=0;index<names.length;index++){
    const {sequence,port,calls}=fixture();const entered=deferred();const waiting=deferred();let gate;
    port[names[index]]=async isCurrent=>{calls.push(names[index]);gate=isCurrent;entered.resolve();await waiting.promise;};
    const running=sequence.run(port);await Promise.race([entered.promise,running]);
    assert.equal(typeof gate,'function','the requested stage must be entered');
    sequence.cancel();assert.equal(gate(),false);
    assert.equal(sequence.snapshot().stage,'cancelled');assert.equal(sequence.snapshot().active,false);
    await assert.rejects(sequence.run(port),/流程|执行/);
    waiting.resolve();await assert.rejects(running,/取消|变化/);
    assert.deepEqual(calls,names.slice(0,index+1));
    assert.equal(sequence.snapshot().stage,'cancelled');
  }
});

test('a changed aircraft context before or after each stage stops the remaining sequence',async()=>{
  const initial=fixture();initial.invalidate();
  await assert.rejects(initial.sequence.run(initial.port),/取消|变化/);assert.deepEqual(initial.calls,[]);
  for(let index=0;index<names.length;index++){
    const {sequence,port,calls,invalidate}=fixture();const original=port[names[index]];
    port[names[index]]=async gate=>{await original(gate);invalidate();assert.equal(gate(),false);};
    await assert.rejects(sequence.run(port),/取消|变化/);
    assert.deepEqual(calls,names.slice(0,index+1));assert.equal(sequence.snapshot().stage,'failed');
    assert.equal(sequence.snapshot().active,false);
  }
});

test('a failure at each stage retains its original reason without starting or retrying following steps',async()=>{
  for(let index=0;index<names.length;index++){
    const {sequence,port,calls}=fixture();const failure=new Error(`exact failure ${index}`);
    port[names[index]]=async()=>{calls.push(names[index]);throw failure;};
    await assert.rejects(sequence.run(port),error=>error===failure);
    assert.deepEqual(calls,names.slice(0,index+1));
    assert.equal(sequence.snapshot().message,failure.message);assert.equal(sequence.snapshot().stage,'failed');
    assert.equal(sequence.snapshot().active,false);
  }
});

test('cancelling from a stage notification prevents that stage from sending any command',async()=>{
  const calls=[];let sequence;
  sequence=new CloseupSequence(()=>{if(sequence.snapshot().stage==='circle')sequence.cancel();});
  const port={isCurrent:()=>true,startDolly:async()=>calls.push('dolly'),finishDolly:async()=>calls.push('media'),
    startCircle:async()=>calls.push('circle'),finishCircle:async()=>calls.push('circle_wait'),returnMedia:async()=>calls.push('return')};
  await assert.rejects(sequence.run(port),/取消|变化/);assert.deepEqual(calls,['dolly','media']);
  assert.equal(sequence.snapshot().stage,'cancelled');
});

test('completed run can be reused and snapshot mutation never changes the controller state',async()=>{
  const {sequence,port,calls,gates,invalidate}=fixture();await sequence.run(port);
  const firstGate=gates[0];assert.equal(firstGate(),false);
  const snapshot=sequence.snapshot();snapshot.stage='circle';snapshot.active=true;snapshot.step=99;
  assert.equal(sequence.snapshot().stage,'completed');assert.equal(sequence.snapshot().active,false);
  await sequence.run(port);assert.equal(calls.length,10);assert.equal(firstGate(),false);
  assert.equal(sequence.snapshot().stage,'completed');
  invalidate();await assert.rejects(sequence.run(port),/取消|变化/);
  assert.equal(sequence.snapshot().step,0);assert.equal(calls.length,10);
});

test('reset invalidates in-flight gates and keeps idle despite late success or failure without allowing overlapping runs',async()=>{
  for(let index=0;index<names.length;index++){
    const {sequence,port,calls}=fixture();const entered=deferred();const waiting=deferred();let gate;
    port[names[index]]=async isCurrent=>{calls.push(names[index]);gate=isCurrent;entered.resolve();await waiting.promise;};
    const running=sequence.run(port);await Promise.race([entered.promise,running]);
    assert.equal(typeof gate,'function','the requested stage must be entered');
    sequence.reset();assert.equal(gate(),false);
    assert.deepEqual(sequence.snapshot(),{active:false,stage:'idle',step:0,message:''});
    await assert.rejects(sequence.run(port),/流程|执行/);
    if(index%2===0){waiting.resolve();await assert.rejects(running,/取消|变化/);}
    else {const failure=new Error('late operation failure');waiting.reject(failure);await assert.rejects(running,e=>e===failure);}
    assert.deepEqual(calls,names.slice(0,index+1));
    assert.deepEqual(sequence.snapshot(),{active:false,stage:'idle',step:0,message:''});
    port[names[index]]=async()=>{calls.push(names[index]);};
    await sequence.run(port);assert.equal(calls.length,index+1+names.length);
    assert.equal(sequence.snapshot().stage,'completed');
  }
});

test('reset clears failed and completed lifecycle states before a later ordinary or new request',async()=>{
  const {sequence,port}=fixture();await sequence.run(port);sequence.reset();
  assert.deepEqual(sequence.snapshot(),{active:false,stage:'idle',step:0,message:''});
  port.finishDolly=async()=>{throw Error('download failed');};
  await assert.rejects(sequence.run(port),/download failed/);assert.equal(sequence.snapshot().stage,'failed');
  sequence.reset();assert.deepEqual(sequence.snapshot(),{active:false,stage:'idle',step:0,message:''});
});
