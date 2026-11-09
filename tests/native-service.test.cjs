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

function tracked(id) {
  return {tracking:true,overlay:[{id}],get trackingAt(){return Date.now();}};
}

test('native snapshot retains genuine recording evidence after the camera becomes idle and clears it for the next cycle',()=>{
  const {service,state}=rig();service.startedAt=Date.now()-100;
  service.observeProgress();assert.equal(service.snapshot().recordingSeen,false);
  state.camera.recordingCandidate=true;state.camera.observedAtMs=Date.now();
  service.observeProgress();assert.equal(service.snapshot().recordingSeen,true);
  state.camera.recordingCandidate=false;service.observeProgress();
  assert.equal(service.snapshot().recordingSeen,true,'stopping the camera must not turn a recorded task into an empty shot');
  service.resetAfterGroundedCycle();assert.equal(service.snapshot().recordingSeen,false);
});

async function circleTargetRig() {
  const f=rig();
  f.flight.snapshot=()=>({takeoffSent:true,takeoffAcknowledged:true,nativeTaskMayFly:false,movementActive:false});
  Object.assign(f.state.flight,{airborne:true,motorsOn:true,modeRaw:6});f.state.task.modeRaw=0;
  const send=f.session.requestNative;
  f.session.requestNative=async(r,s,i,p)=>i===0xf8?
    (f.calls.push({r,s,i,p:Buffer.from(p).toString('hex')}),new Uint8Array([0,0x46,0x93,0x27,3,0,0,0,0x40])):send(r,s,i,p);
  assert.equal((await f.service.prepareHover('circle',config)).ok,true);
  f.state.flight.modeRaw=26;f.state.subject=tracked(17);
  return f;
}

test('selected-subject circle preserves fresh tracking and starts directly without another mode switch or dolly settling',async()=>{
  const {service,calls,state}=await circleTargetRig();const baseline=calls.length;const started=Date.now();
  const confirmedAt=started-120;state.subject={tracking:true,overlay:[{id:17}],trackingAt:confirmedAt};
  const result=await service.start(true,undefined,17);
  assert.equal(result.ok,true,result.error?.message);assert.ok(Date.now()-started<2000);
  assert.deepEqual(calls.slice(baseline),['mayfly',{r:0x92,s:0x23,i:0x13,p:'010500'}]);
  assert.equal(service.snapshot().executionObserved,false,'a successful start reply is not execution');
  assert.equal(service.snapshot().initialTargetTrackingAtMs,confirmedAt,'startup grace must use actual confirmed tracking time');
  assert.equal((await service.start(true,undefined,17)).ok,false);
  service.resetAfterGroundedCycle();assert.equal(service.snapshot().initialTargetTrackingAtMs,undefined);
});

test('selected-subject circle rejects wrong or stale tracking, task activity, landing and unowned flight before starting',async()=>{
  const changes=[
    f=>{f.state.subject.overlay[0].id=18;},
    f=>{f.state.subject={tracking:true,overlay:[{id:17}],trackingAt:Date.now()-1001};},
    f=>{f.state.subject={tracking:true,overlay:[{id:17}]};},
    f=>{f.state.subject={tracking:true,overlay:[{id:17}],trackingAt:Date.now()+1000};},
    f=>{f.state.subject.tracking=false;},
    f=>{f.state.task.phaseRaw=5;f.state.task.modeRaw=5;},
    f=>{f.state.taskAgeMs=1001;},
    f=>{f.state.flightAgeMs=1001;},
    f=>{f.state.cameraAgeMs=1001;},
    f=>{f.state.camera.recordingCandidate=true;},
    f=>{f.state.flight.modeRaw=6;},
    f=>{f.flight.snapshot=()=>({takeoffSent:true,takeoffAcknowledged:true,landRequested:true});},
    f=>{f.flight.snapshot=()=>({takeoffSent:true,takeoffAcknowledged:true,landSent:true});},
    f=>{f.flight.snapshot=()=>({takeoffSent:true,takeoffAcknowledged:false});},
    f=>{f.flight.snapshot=()=>({takeoffSent:true,takeoffAcknowledged:true,nativeTaskMayFly:true});},
    f=>{f.flight.snapshot=()=>({takeoffSent:true,takeoffAcknowledged:true,movementActive:true});}
  ];
  for(const change of changes){
    const f=await circleTargetRig();const baseline=f.calls.length;change(f);
    assert.equal((await f.service.start(true,undefined,17)).ok,false);
    assert.equal(f.calls.length,baseline,'invalid target cannot send mode changes or start');
  }
});

test('selected-subject circle also honors external cancellation before its direct start',async()=>{
  const {service,calls}=await circleTargetRig();const baseline=calls.length;
  const token=new CancellationToken(0);token.cancel();
  assert.equal((await service.start(true,token,17)).ok,false);assert.equal(calls.length,baseline);
});

test('existing selected-subject dolly also rejects an expired tracking timestamp before mode switching',async()=>{
  const {service,state,flight,calls}=rig();assert.equal((await service.prepare('dolly',config)).ok,true);
  flight.snapshot=()=>({takeoffSent:true,takeoffAcknowledged:true});
  Object.assign(state.flight,{modeRaw:26,airborne:true,motorsOn:true});state.task.modeRaw=0;
  state.subject={tracking:true,overlay:[{id:17}],trackingAt:Date.now()-1001};
  const baseline=calls.length;assert.equal((await service.start(true,undefined,17)).ok,false);
  assert.equal(calls.length,baseline);
});
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
test('airborne dolly requires the prepared task and reselects mode before starting on the matching target', async () => {
  const { service, state, flight, calls } = rig();
  assert.equal((await service.prepare('dolly', config)).ok, true);
  flight.snapshot = () => ({ takeoffSent: true, takeoffAcknowledged: true, nativeTaskMayFly: false, movementActive: false });
  Object.assign(state.flight, { modeRaw: 26, airborne: true, motorsOn: true });
  state.task.modeRaw = 0;
  state.subject = tracked(17);
  const baseline = calls.length;
  assert.equal((await service.start(true, undefined, 18)).ok, false);
  assert.equal(calls.length, baseline);
  const start = Date.now();
  assert.equal((await service.start(true, undefined, 17)).ok, true);
  assert.ok(Date.now() - start >= 5000);
  assert.equal(calls[baseline].r, 0x17);
  assert.equal(calls[baseline].i, 0xf9);
  assert.equal(calls.at(-1).p, '010d00');
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

test('explicit hover preparation configures follow and dolly without requiring ground preparation', async () => {
  for (const kind of ['follow', 'dolly']) {
    const { service, state, flight, calls } = rig();
    flight.snapshot = () => ({ takeoffSent: true, takeoffAcknowledged: true });
    Object.assign(state.flight, { airborne: true, motorsOn: true, modeRaw: 6 });
    state.task.modeRaw = 0;
    const result = await service.prepareHover(kind, { ...config, zoom: 3 });
    assert.equal(result.ok, true, result.error?.message);
    assert.equal(service.snapshot().prepared, true);
    assert.equal(calls.some(call => call.i === 0x13), false);
    if (kind === 'dolly') assert.ok(calls.some(call => call.p === 'c59f793d00004040'));
  }
});

test('hover preparation rejects stale, landing, unowned, moving or executing states before sending', async () => {
  for (const change of [
    f => { f.state.flightAgeMs = 2000; },
    f => { f.state.taskAgeMs = 2000; },
    f => { f.flight.snapshot = () => ({ takeoffAcknowledged: true, landRequested: true }); },
    f => { f.flight.snapshot = () => ({ takeoffAcknowledged: false }); },
    f => { f.flight.snapshot = () => ({ takeoffAcknowledged: true, movementActive: true }); },
    f => { f.state.task.modeRaw = 10; f.state.task.phaseRaw = 5; }
  ]) {
    const f = rig();
    Object.assign(f.state.flight, { airborne: true, motorsOn: true, modeRaw: 6 });
    f.state.task.modeRaw = 0;
    f.flight.snapshot = () => ({ takeoffAcknowledged: true }); change(f);
    assert.equal((await f.service.prepareHover('dolly', config)).ok, false);
    assert.deepEqual(f.calls, []);
  }
});

test('independent follow can start on a matching airborne target after explicit hover preparation', async () => {
  const { service, state, flight, calls } = rig();
  flight.snapshot = () => ({ takeoffSent: true, takeoffAcknowledged: true });
  Object.assign(state.flight, { airborne: true, motorsOn: true, modeRaw: 6 }); state.task.modeRaw = 0;
  assert.equal((await service.prepareHover('follow', config)).ok, true);
  state.flight.modeRaw = 26; state.subject = tracked(17);
  assert.equal((await service.start(true, undefined, 17)).ok, true);
  assert.equal(calls.at(-1).p, '010a00');
  assert.equal(calls.filter(call => call.i === 0x13).length, 1);
  assert.equal(service.snapshot().executionObserved, false);
});

test('cancelling hover preparation or losing a target during mode settling never sends start', async () => {
  const f = rig(); const token = new CancellationToken(0);
  f.flight.snapshot = () => ({takeoffAcknowledged:true,takeoffSent:true});
  Object.assign(f.state.flight, {airborne:true,motorsOn:true,modeRaw:6}); f.state.task.modeRaw=0;
  const send = f.session.requestNative;
  f.session.requestNative = async (...args) => { token.cancel(); return send(...args); };
  assert.equal((await f.service.prepareHover('dolly', config, token)).ok, false);
  assert.equal(f.calls.length, 1);
  const g = rig();
  g.flight.snapshot = () => ({takeoffAcknowledged:true,takeoffSent:true});
  Object.assign(g.state.flight, {airborne:true,motorsOn:true,modeRaw:6}); g.state.task.modeRaw=0;
  await g.service.prepareHover('dolly', config);
  g.state.flight.modeRaw=26;g.state.subject=tracked(17);
  const next = g.session.requestNative;
  g.session.requestNative = async (...args) => { g.state.subject.tracking=false; return next(...args); };
  assert.equal((await g.service.start(true, undefined, 17)).ok, false);
  assert.equal(g.calls.some(call => call.i === 0x13), false);
});

test('a verified new ground cycle clears old task ownership while retaining per-connection usage limits', async () => {
  const {service,state}=rig();
  await service.prepare('follow',config);await service.start(true);
  state.task={phaseRaw:0,modeRaw:9,payloadHex:'0509000100',observedAtMs:Date.now()+1};
  assert.equal(service.activeOrUnknown(),true);
  service.resetAfterGroundedCycle();
  assert.equal(service.activeOrUnknown(),false);
  assert.equal(service.snapshot().startedAtMs,undefined);
  assert.equal((await service.prepare('follow',config)).error.code,'NATIVE_CYCLE_USED');
});

test('native progress records transitions and distinguishes accepted start from observed execution', async () => {
  const {service,state}=rig();
  assert.equal(service.observeProgress(),undefined);
  await service.prepare('follow',config);await service.start(true);
  state.task.observedAtMs=Date.now()+1;state.camera.observedAtMs=Date.now()+1;
  assert.match(service.observeProgress(),/执行已观察=false/);
  assert.equal(service.observeProgress(),undefined);
  state.task.payloadHex='050a000100';
  state.camera.recordingCandidate=true;
  assert.match(service.observeProgress(),/执行已观察=true.*录像已观察=true/);
  state.task.payloadHex='0000000101';state.camera.recordingCandidate=false;
  assert.match(service.observeProgress(),/0000000101.*录像=false.*执行已观察=true/);
  assert.equal(service.observeProgress(),undefined);
});

test('dolly can prepare again in the same connection after a verified new grounded cycle', async () => {
  const {service,state}=rig();
  assert.equal((await service.prepare('dolly',config)).ok,true);
  assert.equal((await service.start(true)).ok,true);
  assert.equal((await service.prepare('dolly',config)).ok,false,'an executing or unknown task must remain locked');
  state.task.observedAtMs=Date.now()+1;
  service.resetAfterGroundedCycle();
  const repeated=await service.prepare('dolly',{...config,zoom:3});
  assert.equal(repeated.ok,true,repeated.error?.message);
  assert.equal(service.snapshot().config.zoom,3);
});

test('an observed completed dolly hands off hover ownership and can prepare a second shot without landing', async () => {
  const {service,state,flight}=rig();const now=Date.now();let mayFly=true;
  await service.prepare('dolly',config);await service.start(true);
  state.task={phaseRaw:5,modeRaw:13,payloadHex:'050d000100',observedAtMs:now+10};
  Object.assign(state.camera,{observedAtMs:now+10,recordingCandidate:true});service.observeProgress();
  Object.assign(state.flight,{modeRaw:6,airborne:true,motorsOn:true,observedAtMs:now+20});
  state.task={phaseRaw:0,modeRaw:0,payloadHex:'0000000100',observedAtMs:now+20};
  Object.assign(state.camera,{observedAtMs:now+20,recordingCandidate:false});
  flight.snapshot=()=>({takeoffSent:true,takeoffAcknowledged:true,nativeTaskMayFly:mayFly});
  flight.releaseNativeTaskAfterHover=()=>{mayFly=false;return {ok:true,data:true};};
  assert.equal(service.completeForHover().ok,true);
  assert.equal(service.snapshot().startedAtMs,undefined);
  assert.equal((await service.prepareHover('dolly',{...config,zoom:3})).ok,true);
});

test('a start ACK without observed execution cannot unlock another airborne shot', async () => {
  const {service,state,flight}=rig();let released=false;
  await service.prepare('dolly',config);await service.start(true);
  state.task.observedAtMs=Date.now()+1;state.camera.observedAtMs=Date.now()+1;
  flight.releaseNativeTaskAfterHover=()=>{released=true;return {ok:true,data:true};};
  assert.equal(service.completeForHover().ok,false);
  assert.equal(released,false);
});

test('a verified completion can hand off through the ordinary mode9 hover reached after releasing tracking', async () => {
  const {service,state,session}=rig();
  await service.prepare('dolly',config);await service.start(true);
  const started=service.snapshot().startedAtMs;
  state.task={phaseRaw:5,modeRaw:13,payloadHex:'050d000100',observedAtMs:started+10};
  state.camera.observedAtMs=started+10;service.observeProgress();
  state.task={phaseRaw:0,modeRaw:0,payloadHex:'0000000102',observedAtMs:started+20};
  state.camera.observedAtMs=started+20;
  assert.equal(service.canCompleteForHover().ok,true);
  const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');
  const flight=new FlightCommandService(session);flight.takeoffSentValue=true;flight.takeoffAcknowledgedValue=true;
  flight.markNativeTaskMayFly(started);service.flight=flight;
  Object.assign(state.flight,{modeRaw:6,airborne:true,motorsOn:true,observedAtMs:started+30});
  state.task={phaseRaw:5,modeRaw:9,payloadHex:'0509000100',observedAtMs:started+30};
  state.camera.observedAtMs=started+30;
  assert.equal(service.completeForHover().ok,true);
  assert.equal(flight.snapshot().nativeTaskMayFly,false);
  assert.equal(service.snapshot().startedAtMs,undefined);
});
