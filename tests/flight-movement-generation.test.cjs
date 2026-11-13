const {test}=require('node:test');
const assert=require('node:assert/strict');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');

async function replay(run){
  let now=1000,sessionId=1,fresh=true;const timers=[],events=[];
  const session={sessionId:()=>sessionId,isActionLinkFresh:()=>fresh,
    requestFlight:async()=>Uint8Array.of(0),setMovementAxes:()=>events.push(['move',sessionId]),
    centerSticks:async()=>events.push(['center',sessionId])};
  const flight=new FlightCommandService(session);
  const realNow=Date.now,realTimeout=global.setTimeout;
  Date.now=()=>now;global.setTimeout=callback=>{timers.push(callback);return 0;};
  const tick=async()=>{assert.ok(timers.length,'movement should be waiting for its tick');now+=50;timers.shift()();
    for(let i=0;i<8;i++)await Promise.resolve();};
  try{await flight.takeoff(true);await run({flight,events,tick,setSession:value=>{sessionId=value;},loseLink:()=>{fresh=false;}});}
  finally{Date.now=realNow;global.setTimeout=realTimeout;}
}

test('a retired flight generation cannot center or clear the new movement owner',async()=>{
  await replay(async({flight,events,tick,setSession})=>{
    const old=flight.move('turn_left',2,flight.newCancellationToken());
    setSession(2);flight.resetForAircraftSession();await flight.takeoff(true);
    const token=flight.newCancellationToken();const fresh=flight.move('forward',2,token);
    await tick();assert.equal((await old).ok,false);
    assert.deepEqual(events,[['move',1],['move',2]]);
    assert.equal(flight.snapshot().movementActive,true,'old finally must not clear the fresh movement');
    token.cancel();await tick();assert.equal((await fresh).ok,false);
    assert.deepEqual(events,[['move',1],['move',2],['center',2]]);
    assert.equal(flight.snapshot().movementActive,false);
  });
});

test('a changed aircraft session alone prevents a late movement callback from centering',async()=>{
  await replay(async({flight,events,tick,setSession})=>{
    const old=flight.move('turn_left',2,flight.newCancellationToken());
    let finished=false;old.then(()=>{finished=true;});
    setSession(2);await tick();assert.equal(finished,true,'session change must terminate the old movement');
    const result=await old;
    assert.equal(result.ok,false);assert.equal(result.error.code,'MOVEMENT_CANCELLED');
    assert.deepEqual(events,[['move',1]]);
    assert.equal(flight.snapshot().movementActive,false);
  });
});

test('manual center retires the old move before a replacement starts in the same generation',async()=>{
  await replay(async({flight,events,tick})=>{
    const old=flight.move('turn_left',2,flight.newCancellationToken());
    assert.equal((await flight.centerSticks()).ok,true);
    const token=flight.newCancellationToken();const fresh=flight.move('right',2,token);
    assert.equal(flight.snapshot().movementActive,true);
    assert.deepEqual(events,[['move',1],['center',1],['move',1]]);
    await tick();assert.equal((await old).ok,false);
    assert.deepEqual(events,[['move',1],['center',1],['move',1]]);
    assert.equal(flight.snapshot().movementActive,true);
    token.cancel();await tick();await fresh;
    assert.deepEqual(events,[['move',1],['center',1],['move',1],['center',1]]);
  });
});

for(const reason of ['cancel','link'])test(`an unchanged movement owner still centers on ${reason}`,async()=>{
  await replay(async({flight,events,tick,loseLink})=>{
    const token=flight.newCancellationToken();const moving=flight.move('turn_left',2,token);
    if(reason==='cancel')token.cancel();else loseLink();
    await tick();assert.equal((await moving).ok,false);
    assert.deepEqual(events,[['move',1],['center',1]]);
    assert.equal(flight.snapshot().movementActive,false);
  });
});
