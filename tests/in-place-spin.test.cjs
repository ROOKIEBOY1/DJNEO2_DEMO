const {test}=require('node:test');
const assert=require('node:assert/strict');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');
const {axesForMovement}=require('../entry/src/main/ets/core/protocol/StickCodec.ets');

async function replay(interrupt){
  let now=1000,fresh=true;const events=[];
  const service=new FlightCommandService({sessionId:()=>1,isActionLinkFresh:()=>fresh,
    requestFlight:async()=>Uint8Array.of(0),
    setMovementAxes:axes=>events.push({kind:'axes',axes,at:now}),
    centerSticks:async()=>events.push({kind:'center',at:now})});
  const token=service.newCancellationToken();
  const realNow=Date.now,realTimeout=global.setTimeout;
  Date.now=()=>now;
  global.setTimeout=(callback,ms)=>{now+=ms;
    if(now<11000)assert.equal(events.filter(e=>e.kind==='center').length,0,'yaw is continuous before deadline or interrupt');
    if(now>=3500){if(interrupt==='cancel')token.cancel();if(interrupt==='link')fresh=false;}
    queueMicrotask(callback);return 0;};
  try{
    assert.equal((await service.takeoff(true)).ok,true);
    const result=await service.move('turn_left',10,token);
    return {result,events,now,service};
  }finally{Date.now=realNow;global.setTimeout=realTimeout;}
}

test('a ten-second left spin holds yaw continuously then centers once without restarting',async()=>{
  const {result,events,now,service}=await replay();
  assert.equal(result.ok,true);assert.equal(now,11000);
  assert.deepEqual(events,[{kind:'axes',axes:axesForMovement('turn_left'),at:1000},{kind:'center',at:11000}]);
  assert.equal(service.snapshot().movementActive,false);
});

for(const interrupt of ['cancel','link']){
  test(interrupt+' interrupts the bounded spin and immediately centers',async()=>{
    const {result,events,now,service}=await replay(interrupt);
    assert.equal(result.ok,false);assert.equal(now,3500);
    assert.equal(result.error.code,interrupt==='cancel'?'MOVEMENT_CANCELLED':'MOVEMENT_LINK_LOST');
    assert.equal(events.at(-1).kind,'center');assert.equal(events.at(-1).at,3500);
    assert.equal(events.filter(e=>e.kind==='axes').length,1);
    assert.equal(service.snapshot().movementActive,false);
  });
}
