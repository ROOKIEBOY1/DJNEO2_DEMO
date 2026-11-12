const {test}=require('node:test');
const assert=require('node:assert/strict');
const captures=require('./fixtures/dolly-notice-raw-captures-20261112.json');
const {DroneSession}=require('../entry/src/main/ets/core/domain/DroneSession.ets');
const {NativeTaskService}=require('../entry/src/main/ets/core/domain/NativeTaskService.ets');
const {TaskStopNoticePresenter}=require('../entry/src/main/ets/core/domain/TaskStopNotice.ets');
const {encodeDumlFrame}=require('../entry/src/main/ets/core/protocol/DumlCodec.ets');
const {buildOuterHeader}=require('../entry/src/main/ets/core/protocol/OuterCodec.ets');

const endedPayloads=['0000000100','0000000101','0000000102','0300000100','0400000100'];
const message='检测到障碍物，已触发避障';
const nearZero=value=>Number.isFinite(value)&&Math.abs(value)<=0.300001;
const route=frame=>`${frame.sender}/${frame.receiver}/${frame.command_set}/${frame.command_id}`;

function packet(session,sequence,frame){
  // The fixture preserves actual DUML fields and payloads. Only the outer
  // transport framing and CRC are reconstructed for the real Session parser.
  const inner=encodeDumlFrame(frame.sender,frame.receiver,frame.sequence,frame.flags,
    frame.command_set,frame.command_id,new Uint8Array(Buffer.from(frame.payload,'hex')));
  const bytes=new Uint8Array(34+inner.length);
  bytes.set(buildOuterHeader(session,1,bytes.length,sequence));bytes.set(inner,34);return bytes;
}

function stateForNotice(telemetry,reason,now){
  const {task,camera,navigation,flight,taskException}=telemetry;
  const fresh=item=>item&&item.observedAtMs>=reason.terminalAtMs&&item.observedAtMs<=now&&now-item.observedAtMs<=1000;
  const stationary=flight&&[flight.velocityXMetersPerSecond,flight.velocityYMetersPerSecond,
    flight.velocityZMetersPerSecond].every(nearZero);
  const physicalReturn=navigation&&(navigation.goHomeExecuting||navigation.multiQuickShotEnabled||navigation.modeRaw===8);
  const moving=flight&&(!stationary||flight.modeRaw===15);
  const ended=task&&(endedPayloads.includes(task.payloadHex)||(task.modeRaw===9&&[0,5].includes(task.phaseRaw)));
  const idleNav=navigation&&!navigation.goHomeExecuting&&!navigation.multiQuickShotEnabled&&
    ((navigation.modeRaw===0&&!navigation.navigationExecuting)||navigation.modeRaw===1);
  const stoppedFlight=stationary&&flight&&((!flight.airborne&&!flight.motorsOn)||
    (flight.airborne&&flight.motorsOn&&[6,26].includes(flight.modeRaw)));
  const ready=reason&&fresh(task)&&ended&&fresh(camera)&&!camera.recordingCandidate&&camera.recordStateRaw===0&&
    fresh(navigation)&&idleNav&&fresh(flight)&&stoppedFlight&&taskException&&
    taskException.observedAtMs>=reason.exceptionAtMs&&taskException.inAction===false;
  return {ready:!!ready,moving:!!moving,returning:!!physicalReturn,mode:flight?.modeRaw};
}

function replay(run,{releaseAfterFirstTerminal=false}={}){
  const originalNow=Date.now;
  let now=run.frames[0].atMs,outerSequence=1,started=false,released=false,readySince;
  Date.now=()=>now;
  try{
    const session=new DroneSession();
    const sessionIds=[...new Set(run.frames.filter(frame=>frame.side==='plane').map(frame=>frame.session))];
    assert.equal(sessionIds.length,1,'one captured aircraft session per replay');
    let commandCount=0;
    const forbidden=()=>{commandCount++;throw Error('notification replay must not issue an aircraft operation');};
    Object.assign(session,{session:sessionIds[0],generation:1,phaseValue:'ready',deviceVerified:true,
      channel:{receivedCount:()=>outerSequence,sentCount:()=>0,lastPeer:()=>'',send:forbidden},emitThrottled(){}});
    session.requestNative=forbidden;
    const flight={snapshot:()=>({generation:1,movementActive:false,landRequested:false,landSent:false}),
      centerSticks:forbidden,releaseNativeTaskAfterHover:forbidden};
    const native=new NativeTaskService(session,flight,{}),presenter=new TaskStopNoticePresenter();
    Object.assign(native,{kind:'dolly'});
    session.setTaskTelemetryListener(event=>native.observeTelemetry(event));
    session.setCameraTelemetryListener(()=>{
      const camera=session.snapshot().telemetry.camera;
      assert.ok(camera);native.observeCameraTelemetry(camera);
    });
    const timeline=[],displays=[],latestRaw=new Map();let reason;
    function feed(frame,atMs,synthetic=false){
      assert.ok(atMs>=now,'replay keeps the original capture frame ordering');now=atMs;
      if(!started&&now>=run.taskStartAtMs){
        Object.assign(native,{startedAt:run.taskStartAtMs});started=true;
      }
      if(frame.side!=='plane')return; // Recorded phone TX is metadata, never resent.
      session.onPacket(packet(session.sessionId(),outerSequence++&0xffff,frame),now);
      if(!synthetic)latestRaw.set(route(frame),frame);
      const snapshot=native.snapshot(),telemetry=session.snapshot().telemetry;
      if(snapshot.stopReport?.classification==='obstacle')reason??={...snapshot.stopReport};
      assert.equal(snapshot.executionSeen,false,'the diagnostic path must not alter business execution evidence');
      assert.equal(snapshot.recordingSeen,false,'the diagnostic path must not alter business recording evidence');
      const status=reason?stateForNotice(telemetry,reason,now):{ready:false,moving:false,returning:false,mode:telemetry.flight?.modeRaw};
      if(!status.ready)readySince=undefined;else readySince??=now;
      if(displays.length===0&&(status.returning||status.moving||status.mode===15)){
        assert.equal(snapshot.stopNotice,undefined,`no notice during return/motion at ${now} source ${frame.sourceLine}`);
      }
      presenter.present(snapshot.stopNotice,text=>{
        assert.equal(text,message);assert.ok(status.ready,'notification requires real settled telemetry');
        assert.ok(readySince!==undefined&&now-readySince>=500,'at least 500ms after the last non-stationary transition');
        displays.push({atMs:now,text,synthetic,notice:{...snapshot.stopNotice},status});
      });
      timeline.push({atMs:now,sourceLine:frame.sourceLine,synthetic,...status,hasNotice:snapshot.stopNotice!==undefined});
      if(releaseAfterFirstTerminal&&!released&&reason&&now>=run.firstTerminalAtMs){
        assert.equal(snapshot.stopNotice,undefined,'release imaging ownership while return is still being observed');
        native.resetTaskState();released=true;
        assert.equal(native.snapshot().startedAtMs,undefined);
        assert.equal(native.snapshot().stopReport,undefined,'the raw task lifetime ended at the simulated handoff');
      }
    }
    for(const frame of run.frames)feed(frame,frame.atMs);
    // Synthetic extension: repeat only the last REAL raw flight/task/camera/NAV
    // samples unchanged for 800ms. This is a stability-boundary check, not extra
    // capture evidence or an invented NAV gate. The obstacle reason must already
    // have been established exclusively by the original capture frames above.
    const originalReason=reason&&{...reason};
    const refreshRoutes=['3/14/3/67','146/2/35/20','1/2/2/128','146/2/10/90'];
    const refresh=refreshRoutes.map(key=>{
      const frame=latestRaw.get(key);assert.ok(frame,`captured refresh source ${key}`);return frame;
    }).sort((left,right)=>left.sourceLine-right.sourceLine);
    for(let elapsed=100;elapsed<=800;elapsed+=100)for(const frame of refresh)feed(frame,run.windowEndAtMs+elapsed,true);
    assert.deepEqual(reason,originalReason,'synthetic refresh must not create or rewrite the raw reason');
    assert.equal(commandCount,0);if(releaseAfterFirstTerminal)assert.equal(released,true);
    return {reason,timeline,displays,released,commandCount,phoneStopCount:run.frames.filter(frame=>
      frame.side==='app'&&frame.command_set===0x23&&frame.command_id===0x15).length};
  }finally{Date.now=originalNow;}
}

const obstacles=captures.runs.filter(run=>run.scenarioLabel==='operator_obstacle_and_hover');
for(const [index,run] of obstacles.entries()){
  test(`real Session and NativeTaskService replay ${run.name}${index===0?' across task ownership release':''}`,t=>{
    const result=replay(run,{releaseAfterFirstTerminal:index===0});
    assert.ok(result.reason,'actual raw frames establish the obstacle exit reason');
    assert.equal(result.reason.classification,'obstacle');assert.equal(result.reason.reasonKnown,true);
    assert.equal(result.reason.diagnosticCode,800013);assert.equal(result.reason.codeRaw,0x0b);
    assert.equal(result.reason.reasonNavModeRaw,8);assert.equal(result.reason.reasonMultiQuickShotEnabled,true);
    assert.equal(result.phoneStopCount,0);assert.equal(result.reason.appStopRequested,false);
    assert.ok(result.timeline.some(point=>point.atMs>=run.firstTerminalAtMs&&(point.mode===15||point.returning||point.moving)),
      'the captured post-terminal return/motion interval is actually exercised');
    assert.equal(result.displays.length,1,'one popup for this captured ending, including repeated UI polls');
    assert.equal(result.displays[0].text,message);
    assert.ok(result.displays[0].atMs>run.firstTerminalAtMs+500);
    t.diagnostic(`notice delay after first terminal=${result.displays[0].atMs-run.firstTerminalAtMs}ms; `+
      `first popup source=${result.displays[0].synthetic?'synthetic unchanged-sample extension':'original capture'}; `+
      `native task state released=${result.released}`);
  });
}
for(const run of captures.runs.filter(run=>run.scenarioLabel!=='operator_obstacle_and_hover')){
  test(`real raw negative control ${run.name} never produces an obstacle notification`,()=>{
    const result=replay(run);
    assert.equal(result.reason,undefined,'normal/manual raw reports must not establish diagnostic 800013');
    assert.equal(result.displays.length,0);assert.ok(result.timeline.every(point=>!point.hasNotice));
    if(run.scenarioLabel==='operator_manually_stopped')assert.ok(result.phoneStopCount>0);
    else assert.equal(result.phoneStopCount,0);
  });
}
