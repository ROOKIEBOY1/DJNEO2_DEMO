const {test}=require('node:test');const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {CancellationToken}=require('../entry/src/main/ets/core/domain/OperationResult.ets');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');
function controller(){
  const c=Object.create(AppController.prototype);const events=[];
  c.activeOperations=0;c.busyValue=false;c.log=s=>events.push(s);c.emit=()=>{};
  c.recordResult=(name,result)=>events.push({name,result});
  c.voice={cancelPending:()=>events.push('cancel-pending')};
  c.nativeTasks={cancel:()=>events.push('cancel-task'),snapshot:()=>({busy:true,prepared:false,activeOrUnknown:true}),
    stop:async()=>{events.push('stop-task');return {ok:false};}};
  c.flight={newCancellationToken:()=>new CancellationToken(1),land:async()=>{events.push('land');return {ok:true};}};
  return {c,events};
}
test('land cancels pending command and stops native task before landing even when stop unconfirmed',async()=>{
  const {c,events}=controller();const token=new CancellationToken(1);c.operationToken=token;
  await c.land();assert.equal(token.isCancelled(),true);
  assert.ok(events.indexOf('stop-task')<events.indexOf('land'));assert.ok(events.includes('cancel-pending'));
});
test('overlapping emergency completion does not unlock a still-running ordinary operation',async()=>{
  const {c}=controller();let release;
  const ordinary=c.run('slow',()=>new Promise(r=>release=r));
  await c.run('emergency',async()=>({ok:true}),false);
  assert.equal(c.busyValue,true);let sent=false;
  await c.run('another',async()=>{sent=true;return {ok:true};});assert.equal(sent,false);
  release({ok:true});await ordinary;assert.equal(c.busyValue,false);
});
test('takeoff timeout is not reported as a successful command',async()=>{
  const service=new FlightCommandService({isActionLinkFresh:()=>true,requestFlight:async()=>undefined});
  assert.equal((await service.takeoff(true)).ok,false);
  assert.equal(service.snapshot().takeoffSent,true);
});
test('landing NACK is not reported as landed/successful',async()=>{
  const service=new FlightCommandService({centerSticks:async()=>{},requestFlight:async()=>new Uint8Array([2])});
  assert.equal((await service.land()).ok,false);assert.equal(service.snapshot().landAcknowledged,false);
});
test('grounded second takeoff obtains a token from the new flight cycle',async()=>{
  const {c,events}=controller();let takeoffs=0;
  const session={isActionLinkFresh:()=>true,requestFlight:async()=>{takeoffs++;return new Uint8Array([0]);},
    snapshot:()=>({telemetry:{flight:{observedAtMs:Date.now()+1,motorsOn:false,airborne:false},flightAgeMs:0}})};
  c.flight=new FlightCommandService(session);await c.takeoffConfirmed();await c.takeoffConfirmed();
  assert.equal(takeoffs,2);assert.equal(events.filter(x=>x.result?.ok===false).length,0);
});
test('photo context invalidates an already prepared native selection',async()=>{
  const {c,events}=controller();let prepared=true;
  c.nativeTasks.snapshot=()=>({busy:false,prepared,activeOrUnknown:false});
  c.nativeTasks.activeOrUnknown=()=>false;c.nativeTasks.cancel=()=>{prepared=false;};
  c.camera={shoot:async()=>({ok:true})};await c.shoot();assert.equal(prepared,false);
});
test('native task ownership overrides an earlier manual takeoff ACK',async()=>{
  let changed=false;const service=new FlightCommandService({isActionLinkFresh:()=>true,
    setMovementAxes:()=>{changed=true;},centerSticks:async()=>{},snapshot:()=>({telemetry:{}})});
  service.takeoffAcknowledgedValue=true;service.markNativeTaskMayFly(Date.now());
  assert.equal((await service.move('forward',.001)).ok,false);assert.equal(changed,false);
});
