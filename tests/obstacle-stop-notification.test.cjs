const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const source=path.join(__dirname,'../entry/src/main/ets/core/domain/ObstacleStopNotification.ets');
const ctx={sessionGeneration:3,flightGeneration:4};
function create(){
  assert.ok(fs.existsSync(source),'the independent obstacle notification state machine must exist');
  return new (require(source).ObstacleStopNotification)();
}
function clock(body){const saved=Date.now;let now=2000;Date.now=()=>now;
  try{return body(at=>now=at);}finally{Date.now=saved;}}
function reason(overrides={}){return {startedAtMs:1000,terminalAtMs:2000,exceptionAtMs:1950,codeRaw:11,
  classification:'obstacle',reasonKnown:true,diagnosticCode:800013,reasonNavAtMs:1900,reasonNavModeRaw:8,
  reasonMultiQuickShotEnabled:true,payloadHex:'00000000000019000b00',appStopRequested:false,settleUntilMs:2500,
  message:'检测到障碍物，一键短片任务已终止',...overrides};}
function task(at,hex='0000000102'){return {observedAtMs:at,phaseRaw:parseInt(hex.slice(0,2),16),modeRaw:parseInt(hex.slice(2,4),16),payloadHex:hex};}
function ready(at){return {
  task:task(at),camera:{observedAtMs:at,modeRaw:1,recordingCandidate:false,recordStateRaw:0,timeSynchronized:true},
  navigation:{observedAtMs:at,modeRaw:1,navigationExecuting:true,goHomeExecuting:false,goHomeStageRaw:0,multiQuickShotEnabled:false,payloadHex:''},
  flight:{observedAtMs:at,modeRaw:26,motorsOn:true,airborne:true,velocityXMetersPerSecond:0,
    velocityYMetersPerSecond:0,velocityZMetersPerSecond:0},
  taskException:{observedAtMs:2000,codeRaw:0,inAction:false,payloadHex:'00000000000000000000',sequence:9}};}
function settle(n,set,at=2000,context=ctx){set(at);assert.equal(n.snapshot(ready(at),context),undefined);set(at+500);return n.snapshot(ready(at+500),context);}

test('confirmed reason waits for 500ms of new stationary tracking reports and publishes once',()=>clock(set=>{
  const n=create();n.capture(reason(),'dolly',ctx);const notice=settle(n,set);
  assert.equal(notice.message,'检测到障碍物，已触发避障');assert.equal(notice.observedAtMs,2500);
  set(3000);assert.deepEqual(n.snapshot(ready(3000),ctx),notice,'UI refresh must not create another delivery ID or timestamp');
}));

test('a momentary false navigation state followed by return resets the full stable window',()=>clock(set=>{
  const n=create();n.capture(reason(),'circle',ctx);n.snapshot(ready(2000),ctx);
  set(2250);const returning=ready(2250);Object.assign(returning.navigation,{modeRaw:3,navigationExecuting:true,goHomeExecuting:true,goHomeStageRaw:3});
  n.observe({navigation:returning.navigation},ctx);assert.equal(n.snapshot(returning,ctx),undefined);
  set(2500);assert.equal(n.snapshot(ready(2500),ctx),undefined);set(2750);assert.equal(n.snapshot(ready(2750),ctx),undefined);
  set(3000);assert.ok(n.snapshot(ready(3000),ctx));
}));

test('raw active edges between UI snapshots reset confirmation even when latest state is idle again',()=>clock(set=>{
  for(const key of ['camera','navigation','flight','taskException']){
    set(2000);const n=create();n.capture(reason(),'dolly',ctx);n.snapshot(ready(2000),ctx);
    set(2100);const active=ready(2100);
    if(key==='camera')Object.assign(active.camera,{recordingCandidate:true,recordStateRaw:1});
    if(key==='navigation')Object.assign(active.navigation,{modeRaw:3,navigationExecuting:true,goHomeExecuting:true});
    if(key==='flight')active.flight.velocityXMetersPerSecond=1;
    if(key==='taskException')Object.assign(active.taskException,{observedAtMs:2100,inAction:true});
    n.observe({[key]:active[key]},ctx);
    set(2500);assert.equal(n.snapshot(ready(2500),ctx),undefined,key+' pulse must survive UI coalescing');
    set(3000);assert.ok(n.snapshot(ready(3000),ctx),key);
  }
}));

test('recording write-out state resets timing without discarding a confirmed ending',()=>clock(set=>{
  const n=create();n.capture(reason(),'dolly',ctx);n.snapshot(ready(2000),ctx);
  set(2100);n.observe({camera:{...ready(2100).camera,recordingCandidate:true,recordStateRaw:3}},ctx);
  set(2500);assert.equal(n.snapshot(ready(2500),ctx),undefined);set(3000);assert.ok(n.snapshot(ready(3000),ctx));
}));

test('cached timestamps cannot accumulate the 500ms confirmation or bridge a stale interval',()=>clock(set=>{
  const n=create();n.capture(reason(),'dolly',ctx);const cached=ready(2000);n.snapshot(cached,ctx);
  set(2500);assert.equal(n.snapshot(cached,ctx),undefined);set(3001);assert.equal(n.snapshot(cached,ctx),undefined);
  set(3500);assert.equal(n.snapshot(ready(3500),ctx),undefined);set(4000);assert.ok(n.snapshot(ready(4000),ctx));
}));

test('older fresh streams cannot backdate the moment the aircraft first becomes stationary',()=>clock(set=>{
  const n=create();n.capture(reason(),'dolly',ctx);const initial=ready(2000);initial.flight.modeRaw=15;
  assert.equal(n.snapshot(initial,ctx),undefined);
  set(2250);initial.flight=ready(2250).flight;assert.equal(n.snapshot(initial,ctx),undefined);
  set(2500);assert.equal(n.snapshot(ready(2500),ctx),undefined,'only 250ms has elapsed since all conditions became valid');
  set(2750);assert.ok(n.snapshot(ready(2750),ctx));
}));

test('manual hover after release keeps pending reason without requiring fresh 0A39 during a long return',()=>clock(set=>{
  const n=create();n.capture(reason(),'dolly',ctx);n.capture(undefined,'dolly',ctx);
  set(7000);const first=ready(7000);first.task=task(7000,'0509000100');assert.equal(n.snapshot(first,ctx),undefined);
  set(7500);const second=ready(7500);second.task=task(7500,'0009000100');assert.ok(n.snapshot(second,ctx));
}));

test('unconfirmed, unsupported, App-stopped and incomplete reason reports cannot notify',()=>clock(set=>{
  for(const patch of [{classification:'unconfirmed'},{reasonKnown:false},{diagnosticCode:800003},{codeRaw:1},
    {appStopRequested:true},{exceptionAtMs:undefined},{reasonNavAtMs:undefined},{reasonNavModeRaw:0,reasonMultiQuickShotEnabled:false}]){
    const n=create();n.capture(reason(patch),'dolly',ctx);assert.equal(settle(n,set),undefined,JSON.stringify(patch));set(2000);
  }
  const n=create();n.capture(reason(),'follow',ctx);assert.equal(settle(n,set),undefined);
}));

test('resumed native execution or normal completion code cancels pending and cannot recapture the same ending',()=>clock(set=>{
  for(const event of [{task:task(2100,'0505000100')},{task:task(2100,'050d000100')},
    {taskException:{observedAtMs:2100,codeRaw:1,inAction:false}}]){
    set(2000);const n=create();n.capture(reason(),'dolly',ctx);n.snapshot(ready(2000),ctx);
    set(2100);n.observe(event,ctx);n.capture(reason(),'dolly',ctx);
    assert.equal(settle(n,set,2200),undefined);
  }
}));

test('beginTask, cancel and context change fence both pending and visible notice',()=>clock(set=>{
  for(const action of ['beginTask','cancel']){
    set(2000);const n=create();n.capture(reason(),'dolly',ctx);assert.ok(settle(n,set));n[action]();
    assert.equal(n.snapshot(ready(2500),ctx),undefined);n.capture(reason(),'dolly',ctx);
    assert.equal(settle(n,set,3000),undefined,'same ended task remains deduplicated after '+action);
  }
  set(2000);const n=create();n.capture(reason(),'dolly',ctx);n.snapshot(ready(2000),ctx);
  const next={...ctx,sessionGeneration:9};set(2500);assert.equal(n.snapshot(ready(2500),next),undefined);
  n.capture(reason(),'dolly',next);assert.ok(settle(n,set,2500,next));
}));

test('visible notice expires at ten seconds without resurrecting from repeated report capture',()=>clock(set=>{
  const n=create();n.capture(reason(),'dolly',ctx);const notice=settle(n,set);
  set(12501);n.capture(reason(),'dolly',ctx);assert.equal(n.snapshot(ready(12501),ctx),undefined);
  set(13001);assert.equal(n.snapshot(ready(13001),ctx),undefined);assert.ok(notice.id);
}));

test('pending expires after thirty seconds and repeating the report cannot restore it',()=>clock(set=>{
  const n=create();n.capture(reason(),'dolly',ctx);set(32001);
  assert.equal(n.snapshot(ready(32001),ctx),undefined);n.capture(reason(),'dolly',ctx);
  assert.equal(settle(n,set,32500),undefined);
}));

test('every source must be fresh, after terminal, known and physically eligible',()=>clock(set=>{
  const changes=[s=>s.task.observedAtMs=1999,s=>s.camera.observedAtMs=1999,s=>s.navigation.observedAtMs=1999,
    s=>s.flight.observedAtMs=1999,s=>s.flight.observedAtMs=3001,s=>s.taskException.inAction=undefined,
    s=>s.taskException.observedAtMs=1949,s=>s.navigation.modeRaw=8,s=>s.navigation.multiQuickShotEnabled=true,
    s=>Object.assign(s.navigation,{modeRaw:0,navigationExecuting:true}),s=>s.flight.modeRaw=15,
    s=>s.flight.modeRaw=37,s=>s.flight.velocityYMetersPerSecond=0.31,s=>s.flight.velocityZMetersPerSecond=NaN];
  for(const change of changes){set(2000);const n=create();n.capture(reason(),'dolly',ctx);n.snapshot(ready(2000),ctx);
    set(2500);const invalid=ready(2500);change(invalid);assert.equal(n.snapshot(invalid,ctx),undefined);
    set(3000);assert.equal(n.snapshot(ready(3000),ctx),undefined,'invalid source must reset the previous window');
    set(3500);assert.ok(n.snapshot(ready(3500),ctx));}
}));

test('grounded motors-off can confirm, while missing velocity and mixed airborne flags cannot',()=>clock(set=>{
  const n=create();n.capture(reason(),'dolly',ctx);
  for(const at of [2000,2500]){set(at);const s=ready(at);Object.assign(s.flight,{airborne:false,motorsOn:false,modeRaw:0});
    assert.equal(!!n.snapshot(s,ctx),at===2500);}
  set(2000);const m=create();m.capture(reason(),'dolly',ctx);const missing=ready(2000);delete missing.flight.velocityXMetersPerSecond;
  assert.equal(m.snapshot(missing,ctx),undefined);set(2500);assert.equal(m.snapshot(ready(2500),ctx),undefined);
  for(const flags of [{airborne:true,motorsOn:false},{airborne:false,motorsOn:true}]){
    set(2000);const mixed=create();mixed.capture(reason(),'dolly',ctx);const s=ready(2000);Object.assign(s.flight,flags);
    assert.equal(mixed.snapshot(s,ctx),undefined);set(2500);assert.equal(mixed.snapshot({...s,flight:{...s.flight,observedAtMs:2500}},ctx),undefined);
  }
  set(2000);const boundary=create();boundary.capture(reason(),'dolly',ctx);
  for(const at of [2000,2500]){set(at);const s=ready(at);s.flight.velocityXMetersPerSecond=3*0.1;
    assert.equal(!!boundary.snapshot(s,ctx),at===2500,'the SDK speed conversion must not reject the 0.3 m/s wire value');}
}));

for(const run of require('./fixtures/dolly-notice-raw-captures-20261112.json').runs.filter(r=>r.scenarioLabel==='operator_obstacle_and_hover')){
  test('real captured return waits for navigation, camera and stationary aircraft: '+run.name,()=>clock(set=>{
    const n=create(),state={};let captured=false,notice,firstHover;
    const rawReason=run.frames.find(e=>e.command_set===10&&e.command_id===57&&parseInt(e.payload.slice(16,18),16)===11);
    const navAtReason=run.frames.filter(e=>e.command_set===10&&e.command_id===90&&e.atMs<=rawReason.atMs).at(-1);
    for(const e of run.frames){set(e.atMs);const p=Buffer.from(e.payload,'hex');const event={};
      if(e.side!=='plane')continue;
      if(e.command_set===35&&e.command_id===20)state.task=event.task=task(e.atMs,e.payload);
      if(e.command_set===2&&e.command_id===128)state.camera=event.camera={observedAtMs:e.atMs,modeRaw:p[4],recordingCandidate:(p[0]&0xc0)!==0,recordStateRaw:p[0]>>6&3};
      if(e.command_set===3&&e.command_id===67){state.flight=event.flight={observedAtMs:e.atMs,modeRaw:p[30]&127,airborne:!!(p.readUInt32LE(32)&4),motorsOn:!!(p.readUInt32LE(32)&8),
        velocityXMetersPerSecond:p.readInt16LE(18)/10,velocityYMetersPerSecond:p.readInt16LE(20)/10,velocityZMetersPerSecond:p.readInt16LE(22)/10};
        const flight=state.flight,grounded=!flight.airborne&&!flight.motorsOn;
        const flightEligible=(grounded||([6,26].includes(flight.modeRaw)&&flight.airborne&&flight.motorsOn))&&
          [flight.velocityXMetersPerSecond,flight.velocityYMetersPerSecond,flight.velocityZMetersPerSecond].every(v=>Math.abs(v)<=0.300001);
        if(e.atMs>=run.firstTerminalAtMs&&flightEligible&&firstHover===undefined)firstHover=e.atMs;}
      if(e.command_set===10&&e.command_id===90)state.navigation=event.navigation={observedAtMs:e.atMs,modeRaw:p[5]>>1&15,navigationExecuting:!!(p[5]&1),goHomeExecuting:!!(p[8]&1),goHomeStageRaw:p[8]>>4,multiQuickShotEnabled:!!(p[13]&1),payloadHex:e.payload};
      if(e.command_set===10&&e.command_id===57)state.taskException=event.taskException={observedAtMs:e.atMs,codeRaw:p[8],inAction:p[9]!==0,payloadHex:e.payload,sequence:e.sequence};
      n.observe(event,ctx);
      if(!captured&&e.command_set===35&&e.command_id===20&&e.atMs>=run.firstTerminalAtMs&&
        ['0000000100','0000000101','0000000102','0300000100','0400000100'].includes(e.payload)){captured=true;n.capture(reason({startedAtMs:run.taskStartAtMs,terminalAtMs:run.firstTerminalAtMs,
        exceptionAtMs:rawReason.atMs,reasonNavAtMs:navAtReason.atMs,reasonNavModeRaw:8}), 'dolly',ctx);}
      const shown=n.snapshot(state,ctx);
      if(shown){notice=shown;assert.ok(firstHover!==undefined&&shown.observedAtMs>=firstHover+500,'a task/camera ending cannot announce a stopped aircraft during its return');}
    }
    assert.ok(notice,'confirmed obstacle ending eventually produces one notice after the real return');
  }));
}
