const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');
const {axesForMovement}=require('../entry/src/main/ets/core/protocol/StickCodec.ets');
const {assistantProgress}=require('../entry/src/main/ets/core/domain/AssistantProgress.ets');
const directions=['forward','backward','left','right','up','down','turn_left','turn_right'];
const step=(direction='forward',seconds=.1)=>({direction,seconds});
function deferred(){let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};}

async function fixture(){
  const events=[],feedback=[],state={fresh:true,airborne:true,motorsOn:true,mode:6,flightAge:0,native:false,subjectActive:false};
  const c=Object.create(AppController.prototype);
  c.session={sessionId:()=>10,isReliableLinkFresh:()=>state.fresh,isActionLinkFresh:()=>state.fresh,
    snapshot:()=>({phase:'ready',deviceVerified:true,telemetry:{flightAgeMs:state.flightAge,
      flight:{airborne:state.airborne,motorsOn:state.motorsOn,modeRaw:state.mode}}}),
    requestFlight:async mode=>{events.push(['flight',mode]);return Uint8Array.of(0);},
    setMovementAxes:axes=>events.push(['axes',{...axes}]),
    centerSticks:async()=>{events.push(['center']);if(state.centerHook)await state.centerHook();}};
  c.flight=new FlightCommandService(c.session);await c.flight.takeoff(true);events.length=0;
  Object.assign(c,{agentGeneration:0,latestAgentRequestId:'seq-1',acceptedAgentRequestId:'',
    busyValue:false,activeOperations:0,lastErrorValue:'',agentFeedback:'',lastOperationValue:'',
    nativeTasks:{activeOrUnknown:()=>state.native,snapshot:()=>({}),cancel(){}},
    groundDolly:{snapshot:()=>({active:state.subjectActive,stage:'idle'}),retireInactive:()=>true,cancel(){}},
    closeupSequence:{snapshot:()=>({active:false}),cancel(){}},
    captureMedia:{hasPending:()=>false},camera:{snapshot:()=>({operationActive:false,recordingRequested:false})},
    voice:{cancelPending(){}},log(){},emit(){feedback.push({busy:this.busyValue,text:this.agentFeedback});},
    recordResult(name,result){if(!result.ok)this.lastErrorValue=result.error.message;},
    recordException(name,error){this.lastErrorValue=error.message;}});
  const observation={requestId:'seq-1',sessionId:10,flightGeneration:c.flight.snapshot().generation,
    controlGeneration:0,requestedAtMs:Date.now(),context:{airborne:true,flightStateFresh:true},frame:undefined};
  return {c,events,feedback,state,observation};
}
function response(steps){return {version:2,requestId:'seq-1',command:{action:'move_sequence',steps}};}
async function withClock(operation,onTick=()=>{}){
  let now=1000;const realNow=Date.now,realTimeout=global.setTimeout;
  Date.now=()=>now;global.setTimeout=(fn,ms)=>{now+=ms;onTick(now);queueMicrotask(fn);return 0;};
  try{return await operation(()=>now);}finally{Date.now=realNow;global.setTimeout=realTimeout;}
}

test('the real controller and flight service execute all eight steps directly in order with centering and one busy owner',async()=>{
  await withClock(async()=>{
    const {c,events,feedback,observation}=await fixture();
    const result=await c.acceptAgentResponse(observation,response(directions.map(d=>step(d))));
    assert.equal(result.confirmationRequired,undefined);assert.match(result.message,/8.*完成|完成.*8/);
    assert.deepEqual(events,directions.flatMap(d=>[['axes',axesForMovement(d)],['center']]));
    assert.equal(c.busyValue,false);assert.equal(c.activeOperations,0);
    assert.equal(c.pendingAgentAction,undefined);
    assert.equal(feedback.filter(x=>/第\s*\d+\s*\/\s*8\s*步/.test(x.text)&&x.busy).length>=8,true);
    await assert.rejects(c.acceptAgentResponse(observation,response(directions.map(d=>step(d)))),/已处理/);
    assert.equal(events.length,16);
  });
});

test('a valid 25-second sequence does not expire because its original image becomes older than 20 seconds',async()=>{
  await withClock(async now=>{
    const {c,events,observation}=await fixture();observation.frame={candidates:[]};
    const result=await c.acceptAgentResponse(observation,response([step('forward',10),step('left',10),step('right',5)]));
    assert.match(result.message,/完成/);assert.equal(now(),26000);
    assert.equal(events.filter(x=>x[0]==='axes').length,3);
  });
});

test('invalid later steps reject the whole response before any axes are sent',async()=>{
  const {c,events,observation}=await fixture();
  await assert.rejects(c.acceptAgentResponse(observation,response([step(),step('left',40)])));
  assert.deepEqual(events,[]);
});

for(const problem of ['grounded','stale','native','tracking','subject','session']){
  test(problem+' context never starts a sequence or takes off',async()=>{
    const {c,state,events,observation}=await fixture();
    if(problem==='grounded')state.airborne=state.motorsOn=false;
    if(problem==='stale')state.flightAge=1001;
    if(problem==='native')state.native=true;
    if(problem==='tracking')state.mode=26;
    if(problem==='subject')state.subjectActive=true;
    if(problem==='session')c.session.sessionId=()=>11;
    await assert.rejects(c.acceptAgentResponse(observation,response([step(),step('left')])));
    assert.deepEqual(events,[]);assert.equal(c.busyValue,false);
  });
}

for(const interrupt of ['cancel','land','stop','link','ground','generation','session','flight-mode','stale']){
  test(interrupt+' interrupts the current step and prevents every remaining step',async()=>{
    let f,triggered=false,pending;
    await withClock(async()=>{
      f=await fixture();
      await assert.rejects(f.c.acceptAgentResponse(f.observation,response([step('forward',3),step('left',3)])));
      if(pending)await pending;
      assert.equal(triggered,true);assert.equal(f.events.filter(x=>x[0]==='axes').length,1);
      assert.equal(f.c.flight.snapshot().movementActive,false);assert.equal(f.c.busyValue,false);
      assert.equal(f.events.some(x=>x[0]==='center'),!['generation','session'].includes(interrupt));
      assert.equal(f.events.some(x=>x[0]==='flight'&&x[1]===2),interrupt==='land');
    },now=>{
      if(triggered||now<1150||!f)return;triggered=true;
      if(interrupt==='cancel')f.c.cancelAgentAction();
      if(interrupt==='land')pending=f.c.land();
      if(interrupt==='stop')pending=f.c.center();
      if(interrupt==='link')f.state.fresh=false;
      if(interrupt==='ground')f.state.airborne=f.state.motorsOn=false;
      if(interrupt==='generation')f.c.flight.resetForAircraftSession();
      if(interrupt==='session')f.c.session.sessionId=()=>11;
      if(interrupt==='flight-mode')f.state.mode=26;
      if(interrupt==='stale')f.state.flightAge=1001;
    });
  });
}

test('cancelling while centering is awaiting cannot start another direction and preserves the busy lock until unwind',async()=>{
  const f=await fixture(),entered=deferred(),release=deferred();
  f.state.centerHook=async()=>{entered.resolve();await release.promise;};
  const running=f.c.acceptAgentResponse(f.observation,response([step(),step('left')]));
  const settled=running.then(value=>({value}),error=>({error}));
  await entered.promise;assert.equal(f.c.busyValue,true);
  f.c.cancelAgentAction();assert.equal(f.c.busyValue,true);
  release.resolve();assert.match((await settled).error.message,/取消|状态|变化/);
  assert.equal(f.events.filter(x=>x[0]==='axes').length,1);assert.equal(f.c.busyValue,false);
});

test('busy controller rejects a new sequence without replacing its operation token or queuing moves',async()=>{
  const f=await fixture();f.c.busyValue=true;const original=f.c.flight.newCancellationToken();f.c.operationToken=original;
  await assert.rejects(f.c.acceptAgentResponse(f.observation,response([step(),step('left')])),/操作|执行/);
  assert.equal(f.c.operationToken,original);assert.deepEqual(f.events,[]);
});

test('an error from the real centering operation stops the sequence and clears its busy owner',async()=>{
  await withClock(async()=>{
    const f=await fixture();f.state.centerHook=async()=>{throw new Error('center failed');};
    await assert.rejects(f.c.acceptAgentResponse(f.observation,response([step(),step('left')])),/center failed/);
    assert.equal(f.events.filter(x=>x[0]==='axes').length,1);assert.equal(f.c.busyValue,false);
  });
});

test('continuous movement progress is shown ahead of old subject or media cards',()=>{
  const result=assistantProgress({busy:true,lastOperation:'执行连续基础运动',agentFeedback:'小艺正在执行第 2/3 步：左移 1 秒'});
  assert.deepEqual(result,{title:'正在执行连续基础运动',detail:'小艺正在执行第 2/3 步：左移 1 秒',busy:true});
});
