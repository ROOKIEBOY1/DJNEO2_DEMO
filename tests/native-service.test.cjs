const {test}=require('node:test'); const assert=require('node:assert/strict');
const {CancellationToken}=require('../entry/src/main/ets/core/domain/OperationResult.ets');
const config={radiusMeters:2,framing:'半身',zoom:2,retreat:true};
function rig() {
  const calls=[]; const state={flight:{motorsOn:false,airborne:false,modeRaw:0,observedAtMs:Date.now()},flightAgeMs:0,
    task:{phaseRaw:0,payloadHex:'0000000102',observedAtMs:Date.now()},taskAgeMs:0,
    camera:{modeRaw:1,timeSynchronized:true,recordingCandidate:false,observedAtMs:Date.now()},cameraAgeMs:0};
  const session={isActionLinkFresh:()=>true,snapshot:()=>({telemetry:state}),
    requestNative:async(r,s,i,p)=>{calls.push({r,s,i,p:Buffer.from(p).toString('hex')});return new Uint8Array(i===0xf9?[0,...p]:[0]);}};
  const flight={snapshot:()=>({landRequested:false,landSent:false}),centerSticks:async()=>({ok:true}),
    markNativeTaskMayFly:()=>calls.push('mayfly'),markNativeStopConfirmed:()=>calls.push('stopped')};
  const camera={prepareVideoMode:async()=>{calls.push('video-mode');return {ok:true};}};
  const {NativeTaskService}=require('../entry/src/main/ets/core/domain/NativeTaskService.ets');
  return {service:new NativeTaskService(session,flight,camera),session,flight,camera,state,calls};
}
test('follow prepares ground only, starts once, and ACK is not execution',async()=>{
  const {service,calls}=rig(); assert.equal((await service.prepare('follow',config)).ok,true);
  assert.equal((await service.start(true)).ok,true); assert.equal(service.snapshot().executionObserved,false);
  assert.ok(calls.some(c=>c.p==='010a00')); assert.equal((await service.start(true)).ok,false);
});
test('dolly selects captured config and waits for idle video mode',async()=>{
  const {service,calls}=rig(); assert.equal((await service.prepare('dolly',config)).ok,true);
  assert.equal(calls[0].i,0x15); assert.ok(calls.includes('video-mode'));
  assert.equal((await service.start(false)).ok,false);
  assert.equal((await service.start(true)).ok,true); assert.ok(calls.some(c=>c.p==='010d00'));
});
test('airborne or stale task does not prepare follow/dolly',async()=>{
  for(const kind of ['follow','dolly']){ const {service,state,calls}=rig();state.flight.airborne=true;
    assert.equal((await service.prepare(kind,config)).ok,false);assert.equal(calls.length,0);
    state.flight.airborne=false;state.taskAgeMs=2000;assert.equal((await service.prepare(kind,config)).ok,false);
  }
});
test('stop during pending prepare cancels subsequent parameter/start',async()=>{
  const {service,session,calls}=rig();let release;
  session.requestNative=async(r,s,i,p)=>{
    calls.push({r,s,i,p:Buffer.from(p).toString('hex')});
    if(i===0xf9) await new Promise(resolve=>release=resolve);
    return new Uint8Array(i===0xf9?[0,...p]:[0]);
  };
  const preparing=service.prepare('follow',config);
  await new Promise(resolve=>setImmediate(resolve));
  await service.stop();release();assert.equal((await preparing).ok,false);
  assert.equal((await service.start(true)).ok,false);
  assert.equal(calls.filter(c=>c.i===0x13).length,0);
});
test('NACK, camera failure and mode switch cannot silently prepare',async()=>{
  let r=rig();r.session.requestNative=async()=>new Uint8Array([2]);
  assert.equal((await r.service.prepare('follow',config)).ok,false);
  r=rig();r.camera.prepareVideoMode=async()=>({ok:false,error:{message:'camera failed'}});
  assert.equal((await r.service.prepare('dolly',config)).ok,false);
  r=rig();await r.service.prepare('follow',config);await r.service.start(true);
  assert.equal((await r.service.prepare('dolly',config)).ok,false);
});
test('stale completion does not unlock a native task',async()=>{
  const {service,state}=rig();await service.prepare('follow',config);await service.start(true);
  state.task.observedAtMs=Date.now()+1;state.taskAgeMs=2000;
  assert.equal(service.activeOrUnknown(),true);
});
test('circle cannot steal an externally active follow or stale unknown native mode',async()=>{
  const {service,state,calls}=rig();state.task.phaseRaw=5;state.task.payloadHex='050a000100';
  assert.equal((await service.prepare('circle',config)).ok,false);assert.equal(calls.length,0);
  state.task.phaseRaw=0;state.taskAgeMs=2000;
  assert.equal((await service.prepare('circle',config)).ok,false);assert.equal(calls.length,0);
});
test('circle may transition from owned fresh manual hover even without native task reports',async()=>{
  const {service,state,flight,session}=rig();
  flight.snapshot=()=>({takeoffAcknowledged:true,nativeTaskMayFly:false,landRequested:false,landSent:false});
  state.flight={motorsOn:true,airborne:true,modeRaw:6,observedAtMs:Date.now()};state.task=undefined;state.taskAgeMs=undefined;
  session.requestNative=async(r,s,i,p)=>new Uint8Array(i===0xf9?[0,...p]:i===0xf8?[0,0x46,0x93,0x27,3,0,0,0,0x40]:[0]);
  assert.equal((await service.prepare('circle',config)).ok,true);
  assert.equal((await service.start(true)).ok,true);
});
test('manual hover mode9 is not an executing follow/circle, but native mode10 remains protected',async()=>{
  const {service,state,flight,session}=rig();
  flight.snapshot=()=>({takeoffAcknowledged:true,nativeTaskMayFly:false,landRequested:false,landSent:false});
  state.flight={motorsOn:true,airborne:true,modeRaw:6,observedAtMs:Date.now()};
  state.task.phaseRaw=5;state.task.modeRaw=9;state.task.payloadHex='0509000100';
  session.requestNative=async(r,s,i,p)=>new Uint8Array(i===0xf9?[0,...p]:i===0xf8?[0,0x46,0x93,0x27,3,0,0,0,0x40]:[0]);
  assert.equal((await service.prepare('circle',config)).ok,true);
  state.task.modeRaw=10;state.task.payloadHex='050a000100';
  assert.equal((await service.start(true)).ok,false);
});
