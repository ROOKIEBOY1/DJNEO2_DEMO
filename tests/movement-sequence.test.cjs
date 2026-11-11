const {test}=require('node:test');
const assert=require('node:assert/strict');
const {validateMovementSteps,runMovementSequence}=require('../entry/src/main/ets/core/domain/MovementSequence.ets');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');
const {axesForMovement}=require('../entry/src/main/ets/core/protocol/StickCodec.ets');

const directions=['forward','backward','left','right','up','down','turn_left','turn_right'];
const step=(direction='forward',seconds=.1)=>({direction,seconds});
function deferred(){let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};}

test('sequence validates the entire bounded list and all eight directions',()=>{
  validateMovementSteps(directions.map(d=>step(d)));
  validateMovementSteps([step('forward',10),step('right',10),step('up',10)]);
  for(const invalid of [undefined,null,{},[],[step()],Array.from({length:9},()=>step()),
    [step(),null],[step(),{direction:'diagonal',seconds:1}],
    [step(),{direction:'up',seconds:'2'}],[step(),{direction:'up'}],
    [step(),step('up',0)],[step(),step('up',.09)],[step(),step('up',10.01)],
    [step(),{...step(),action:'land'}],[step(),{...step(),steps:[]}],
    [step('forward',10),step('backward',10),step('up',10),step('down',.1)]]){
    assert.throws(()=>validateMovementSteps(invalid),undefined,JSON.stringify(invalid));
  }
});

test('a bad final step causes zero movement or progress callbacks',async()=>{
  const calls=[];
  await assert.rejects(runMovementSequence([step(),step('left'),step('up',40)],{
    assertCurrent(){},onStep(){calls.push('progress');},move:async()=>calls.push('move')
  }));
  assert.deepEqual(calls,[]);
});

test('sequence awaits every step completion and uses a frozen copy of the validated plan',async()=>{
  const first=deferred(),entered=deferred(),calls=[];
  const plan=[step('forward',2),step('left',1),step('turn_right',3)];
  const running=runMovementSequence(plan,{assertCurrent(){},
    onStep(current,index,total){calls.push(['progress',index,total,current.direction]);},
    async move(current){calls.push(['move',current.direction,current.seconds]);
      if(current.direction==='forward'){entered.resolve();await first.promise;}}
  });
  await entered.promise;
  assert.deepEqual(calls,[['progress',1,3,'forward'],['move','forward',2]]);
  plan[1].direction='down';plan.push(step('up'));
  first.resolve();await running;
  assert.deepEqual(calls,[['progress',1,3,'forward'],['move','forward',2],
    ['progress',2,3,'left'],['move','left',1],['progress',3,3,'turn_right'],['move','turn_right',3]]);
});

for(const boundary of ['before','progress','move','centering']){
  test('cancellation '+boundary+' prevents later steps',async()=>{
    const calls=[];let current=boundary!=='before';
    await assert.rejects(runMovementSequence([step(),step('left')],{
      assertCurrent(){if(!current)throw new Error('cancelled');},
      onStep(){if(boundary==='progress')current=false;},
      async move(value){calls.push(value.direction);if(['move','centering'].includes(boundary))current=false;}
    }),/cancelled/);
    assert.deepEqual(calls,['move','centering'].includes(boundary)?['forward']:[]);
  });
}

test('a failed movement or failed centering never starts another direction',async()=>{
  for(const failure of ['movement failed','center failed']){
    const calls=[];
    await assert.rejects(runMovementSequence([step(),step('left')],{assertCurrent(){},onStep(){},
      async move(value){calls.push(value.direction);throw new Error(failure);}}),new RegExp(failure));
    assert.deepEqual(calls,['forward']);
  }
});

test('a progress observer cannot mutate the step that will be sent',async()=>{
  const sent=[];
  await runMovementSequence([step(),step('left')],{assertCurrent(){},
    onStep(value){value.direction='down';value.seconds=10;},
    async move(value){sent.push({...value});}});
  assert.deepEqual(sent,[step(),step('left')]);
});

test('the optional flight context guard blocks before send and centers promptly if context changes mid-step',async()=>{
  let now=0,allowed=false;const events=[];
  const flight=new FlightCommandService({isActionLinkFresh:()=>true,
    requestFlight:async()=>Uint8Array.of(0),setMovementAxes:axes=>events.push(['axes',axes,now]),
    centerSticks:async()=>events.push(['center',now])});
  await flight.takeoff(true);const token=flight.newCancellationToken();
  const refused=await flight.move('forward',1,token,()=>allowed);
  assert.equal(refused.ok,false);assert.deepEqual(events,[]);
  allowed=true;
  const realNow=Date.now,realTimeout=global.setTimeout;
  Date.now=()=>now;global.setTimeout=(fn,ms)=>{now+=ms;if(now>=150)allowed=false;queueMicrotask(fn);return 0;};
  try{
    const result=await flight.move('turn_left',10,token,()=>allowed);
    assert.equal(result.ok,false);assert.equal(result.error.code,'MOVEMENT_CONTEXT_CHANGED');
    assert.deepEqual(events,[['axes',axesForMovement('turn_left'),0],['center',150]]);
    assert.equal(flight.snapshot().movementActive,false);
  }finally{Date.now=realNow;global.setTimeout=realTimeout;}
});
