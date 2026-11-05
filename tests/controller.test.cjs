const {test}=require('node:test');const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {CancellationToken}=require('../entry/src/main/ets/core/domain/OperationResult.ets');
const {FlightCommandService}=require('../entry/src/main/ets/core/domain/FlightCommandService.ets');
function controller(){
  const c=Object.create(AppController.prototype);const events=[];
  c.activeOperations=0;c.busyValue=false;c.log=s=>events.push(s);c.emit=()=>{};
  c.latestAgentRequestId='';c.acceptedAgentRequestId='';
  c.recordResult=(name,result)=>events.push({name,result});
  c.captureMedia={begin:async()=>{},reset(){},discard(){},hasPending:()=>false,
    markReady(){},retrieveAll:async()=>[{path:'/download/new.jpg',size:200}]};
  c.presentAgentMedia=()=>{};
  c.presentAgentMediaGroup=(kind, items)=>c.presentAgentMedia(kind, items[0]);
  c.voice={cancelPending:()=>events.push('cancel-pending')};
  c.camera={resetAfterGroundedCycle(){},observeTelemetry(){}};
  c.nativeTasks={cancel:()=>events.push('cancel-task'),resetAfterGroundedCycle(){},observeProgress:()=>undefined,
    snapshot:()=>({busy:true,prepared:false,activeOrUnknown:true}),
    stop:async()=>{events.push('stop-task');return {ok:false};}};
  c.flight={snapshot:()=>({}),newCancellationToken:()=>new CancellationToken(1),land:async()=>{events.push('land');return {ok:true};}};
  return {c,events};
}

test('auto scan waits for stable ordinary hover and stays out of tracking, busy actions and landing', async () => {
  const { c } = controller();
  c.autoScanGeneration = 2; c.autoScanFailures = 0; c.autoScanRetryAt = 0;
  c.autoScanHoverSince = Date.now() - 2500; c.autoScanMessage = '';
  c.demoStage = 'closed'; c.latestAgentRequestId = ''; c.acceptedAgentRequestId = '';
  c.nativeTasks.activeOrUnknown = () => false;
  let recording = false;
  let listening = false;
  c.camera = { snapshot: () => ({ operationActive: false, recordingRequested: recording }) };
  c.speech = { isListeningOnce: () => listening };
  const flight = { generation: 2, takeoffSent: true, takeoffAcknowledged: true };
  const subject = { tracking: false, candidateCount: 0, scanStateRaw: 0, overlay: [] };
  const task = { phaseRaw: 5, modeRaw: 9 };
  c.flight.snapshot = () => flight;
  c.session = { snapshot: () => ({ phase: 'ready', deviceVerified: true, downlinkAgeMs: 0, videoAgeMs: 0,
    telemetry: { flightAgeMs: 0, flight: { modeRaw: 6, airborne: true, motorsOn: true },
      taskAgeMs: 0, task, subject, cameraAgeMs: 0, camera: { recordingCandidate: false } } }) };
  let scans = 0;
  c.requestHoverSubjectScan = async (token, restart) => {
    assert.equal(restart, true); scans++; subject.scanStateRaw = 1;
    task.phaseRaw = 0; task.modeRaw = 0;
    return { ok: true, data: 'scan' };
  };
  c.busyValue = true; await c.pollAutoSubjectScan(); assert.equal(scans, 0);
  c.busyValue = false; subject.tracking = true; await c.pollAutoSubjectScan(); assert.equal(scans, 0);
  subject.tracking = false; flight.landRequested = true; await c.pollAutoSubjectScan(); assert.equal(scans, 0);
  flight.landRequested = false; recording = true;
  await c.pollAutoSubjectScan(); assert.equal(scans, 0);
  recording = false; listening = true;
  await c.pollAutoSubjectScan(); assert.equal(scans, 0);
  listening = false; c.autoScanHoverSince = Date.now() - 2500;
  await c.pollAutoSubjectScan(); assert.equal(scans, 1);
  await c.pollAutoSubjectScan(); assert.equal(scans, 1);
  task.phaseRaw = 0; task.modeRaw = 9; subject.scanStateRaw = 0;
  c.autoScanHoverSince = Date.now() - 2500;
  await c.pollAutoSubjectScan(); assert.equal(scans, 2);
  flight.generation = 3; await c.pollAutoSubjectScan();
  assert.equal(scans, 2); assert.equal(c.autoScanFailures, 0);
});

test('a new flight explicitly starts scanning even when the aircraft reports scan enabled with no candidates', async () => {
  const {c}=controller();let requests=0;
  c.autoScanGeneration=4;c.autoScanRequestedGeneration=3;c.autoScanFailures=0;c.autoScanRetryAt=0;
  c.autoScanHoverSince=Date.now()-2500;c.hoverScanAttempted=false;c.demoStage='closed';
  c.nativeTasks.activeOrUnknown=()=>false;
  c.camera={snapshot:()=>({operationActive:false,recordingRequested:false})};
  c.speech={isListeningOnce:()=>false};
  c.flight.snapshot=()=>({generation:4,takeoffSent:true,takeoffAcknowledged:true});
  c.session={snapshot:()=>({phase:'ready',deviceVerified:true,downlinkAgeMs:0,videoAgeMs:0,telemetry:{
    flightAgeMs:0,flight:{modeRaw:6,airborne:true,motorsOn:true},taskAgeMs:0,task:{phaseRaw:0,modeRaw:0},
    cameraAgeMs:0,camera:{recordingCandidate:false},
    subject:{tracking:false,candidateCount:0,candidates:[],scanStateRaw:1}
  }})};
  c.requestHoverSubjectScan=async()=>{requests++;return {ok:true,data:'requested'};};
  await c.pollAutoSubjectScan();
  assert.equal(requests,1);
  await c.pollAutoSubjectScan();assert.equal(requests,1);
  assert.equal(c.autoScanRequestedGeneration,4);
});

test('forced rescan clears the aircraft native context even when its idle task reports scan enabled', async () => {
  const {c}=controller();const sent=[];
  c.nativeTasks.activeOrUnknown=()=>false;
  c.flight.snapshot=()=>({takeoffSent:true,takeoffAcknowledged:true});
  const task={phaseRaw:0,modeRaw:0,observedAtMs:0};
  const subject={candidateCount:0,candidates:[],scanStateRaw:1,scanObservedAt:0};
  c.session={sessionId:()=>42,snapshot:()=>({phase:'ready',deviceVerified:true,downlinkAgeMs:0,videoAgeMs:0,
    telemetry:{flightAgeMs:0,flight:{modeRaw:6,airborne:true,motorsOn:true},taskAgeMs:0,task,subject}}),
    requestNative:async(receiver,set,id,payload)=>{
      sent.push([receiver,set,id,...payload]);task.observedAtMs=Date.now();subject.scanObservedAt=Date.now();
      return Uint8Array.of(0);
    }};
  const result=await c.requestHoverSubjectScan(new CancellationToken(1),true);
  assert.equal(result.ok,true);
  assert.deepEqual(sent,[[0x92,0x23,0x15]]);
});

test('voice observation waits for this flight scan request instead of accepting a retained scan-enabled bit', async () => {
  const {c}=controller();let polls=0;
  c.autoScanRequestedGeneration=3;c.autoScanFailures=0;
  c.flight.snapshot=()=>({generation:4});c.isOrdinarySubjectHover=()=>true;
  c.camera={snapshot:()=>({recordingRequested:false})};
  c.session={snapshot:()=>({telemetry:{subject:{tracking:false,scanStateRaw:1},task:{modeRaw:0},camera:{recordingCandidate:false}}})};
  c.pollAutoSubjectScan=async()=>{polls++;c.autoScanRequestedGeneration=4;};
  await c.waitForAutomaticSubjectScan();assert.equal(polls,1);
});

test('simple connection initializes only after a successful connection and never starts flight', async () => {
  const { c, events } = controller();
  let phase = 'disconnected';
  c.session = { snapshot: () => ({ phase }) };
  c.connectSelectedAircraft = async () => { events.push('connect'); phase = 'registering'; };
  c.initialize = async () => { events.push('initialize'); phase = 'ready'; };
  await c.ensureReadyConnection();
  assert.deepEqual(events, ['connect', 'initialize']);
  await c.ensureReadyConnection();
  assert.equal(events.length, 2);
});

test('dolly demo only offers playback after observed execution and fresh idle camera telemetry', () => {
  const { c } = controller();
  c.demoStage = 'shooting'; c.demoStartAt = Date.now() - 10;
  c.demoSessionId = 10; c.session = { sessionId: () => 10 };
  const task = { startedAtMs: c.demoStartAt, executionObserved: false };
  const telemetry = { task: { payloadHex: '0000000101', observedAtMs: Date.now() }, taskAgeMs: 0,
    camera: { recordingCandidate: true }, cameraAgeMs: 0 };
  const session = { phase: 'ready', telemetry };
  c.updateDollyDemo(session, task);
  assert.equal(c.demoStage, 'shooting');
  task.executionObserved = true;
  telemetry.task.payloadHex = '050d000100';
  c.updateDollyDemo(session, task);
  task.executionObserved = false;
  telemetry.task.payloadHex = '0000000101';
  c.updateDollyDemo(session, task);
  assert.equal(c.demoStage, 'shooting');
  telemetry.camera.recordingCandidate = false;
  c.updateDollyDemo(session, task);
  assert.equal(c.demoStage, 'recorded');
});

test('demo confirmation reuses a fresh matching track in mode 26 without sending another selection', async () => {
  const { c, events } = controller();
  c.demoStage = 'confirm'; c.demoSessionId = 42; c.demoCandidate = { id: 17 };
  c.flight.snapshot = () => ({ takeoffSent: true });
  c.video = { snapshot: () => ({ state: 'live', stats: { lastRenderedAgeMs: 0 } }) };
  const telemetry = { flightAgeMs: 0, flight: { modeRaw: 26, airborne: true, motorsOn: true }, taskAgeMs: 0,
    task: { phaseRaw: 0, modeRaw: 0 }, subject: { scanStateRaw: 2, tracking: true, overlay: [{ id: 18 }] } };
  c.session = { sessionId: () => 42, isActionLinkFresh: () => true, snapshot: () => ({ telemetry }) };
  let startedAtMs;
  c.nativeTasks.snapshot = () => ({ kind: 'dolly', prepared: true, startedAtMs });
  c.nativeTasks.activeOrUnknown = () => false;
  c.requestSubjectSelection = async () => { events.push('reselect'); return { ok: false }; };
  c.nativeTasks.start = async (confirmed, token, target) => {
    events.push(target); startedAtMs = Date.now(); return { ok: true };
  };
  await c.confirmDollyDemo();
  assert.equal(events.includes(17), false);
  telemetry.subject.overlay[0].id = 17;
  await c.confirmDollyDemo();
  assert.equal(events.includes('reselect'), false);
  assert.equal(events.includes(17), true);
  assert.equal(c.demoStage, 'shooting');
});

test('demo prepares on the ground, takes off before confirmation and starts dolly only on confirmation', async () => {
  const { c, events } = controller();
  c.demoStage = 'closed';
  c.video = { snapshot: () => ({ state: 'live', stats: { lastRenderedAgeMs: 0 } }) };
  let airborne = false;
  let stopped = false;
  c.session = { sessionId: () => 42, isActionLinkFresh: () => true,
    snapshot: () => ({ phase: 'ready', deviceVerified: true, downlinkAgeMs: 0, videoAgeMs: 0,
      telemetry: { flightAgeMs: 0, flight: { airborne, motorsOn: airborne, modeRaw: 6 }, taskAgeMs: 0,
        task: { phaseRaw: stopped ? 0 : 5, modeRaw: stopped ? 0 : 9, observedAtMs: Date.now() },
        subject: { candidateCount: 1, candidates: [{ id: 17 }], scanStateRaw: stopped ? 1 : 0,
          scanObservedAt: Date.now(), detectionAt: Date.now() } } }),
    requestNative: async (receiver, set, id, payload) => {
      assert.deepEqual([receiver, set, id, ...payload], [0x92, 0x23, 0x15]);
      events.push('hover-stop'); stopped = true; return Uint8Array.of(0);
    } };
  c.flight.snapshot = () => ({ takeoffSent: airborne });
  c.flight.takeoff = async () => { events.push('takeoff'); airborne = true; return { ok: true }; };
  c.media = { listMedia: async () => { events.push('directory'); return { ok: true, data: [{ path: 'old.MP4' }] }; } };
  let startedAtMs;
  c.nativeTasks.activeOrUnknown = () => false;
  c.nativeTasks.snapshot = () => ({ kind: 'dolly', prepared: true, startedAtMs });
  c.nativeTasks.prepare = async kind => { events.push(`prepare:${kind}`); return { ok: true }; };
  c.requestSubjectSelection = async (token, target) => {
    events.push(`select:${target}`); c.selectedSubjectId = target; return { ok: true };
  };
  c.nativeTasks.start = async (confirmed, token, target) => {
    assert.equal(confirmed, true);
    assert.equal(target, 17);
    events.push('start'); startedAtMs = Date.now(); return { ok: true };
  };
  c.openDollyDemo();
  assert.deepEqual(events, []);
  await c.takeoffForDollyDemo();
  assert.deepEqual(events.slice(0, 4), ['prepare:dolly', 'directory', 'takeoff', 'hover-stop']);
  assert.equal(c.demoStage, 'confirm');
  assert.equal(events.includes('start'), false);
  await c.confirmDollyDemo();
  assert.ok(events.indexOf('select:17') < events.indexOf('start'));
  assert.ok(events.includes('start'));
  assert.equal(c.demoMediaBefore.has('old.MP4'), true);
  assert.equal(c.demoStage, 'shooting');
});

test('ordinary 5/9 hover enters selection through one stop request before selecting a candidate', async () => {
  const { c, events } = controller();
  c.nativeTasks.activeOrUnknown = () => false;
  const flight = { takeoffSent: false, movementActive: false };
  const subject = { candidateCount: 0 };
  let stopped = false;
  c.flight.snapshot = () => flight;
  c.session = {
    sessionId: () => 42,
    isReliableLinkFresh: () => true,
    snapshot: () => ({ phase: 'ready', deviceVerified: true, downlinkAgeMs: 0, videoAgeMs: 0,
      telemetry: { flightAgeMs: 0, flight: { modeRaw: 6, airborne: true, motorsOn: true },
        taskAgeMs: 0, task: { phaseRaw: stopped ? 0 : 5, modeRaw: stopped ? 0 : 9, observedAtMs: Date.now() }, subject } }),
    requestNative: async (receiver, set, id, payload) => {
      events.push([receiver, set, id, ...payload]);
      if (id === 0x15) {
        stopped = true;
        Object.assign(subject, { scanStateRaw: 1, scanObservedAt: Date.now() });
      }
      if (payload[1] === 5) Object.assign(subject, { detectionAt: Date.now(), trackingAt: Date.now(),
        selectedIdCandidate: 17, overlay: [{ id: 17 }] });
      return Uint8Array.of(0);
    }
  };
  await c.startHoverSubjectScan();
  assert.equal(events.at(-1).result.error.code, 'SUBJECT_HOVER_REQUIRED');
  flight.takeoffSent = true;
  const start = Date.now();
  await c.startHoverSubjectScan();
  assert.ok(Date.now() - start >= 2000);
  assert.deepEqual(events.filter(Array.isArray), [[0x92, 0x23, 0x15]]);
  await c.startHoverSubjectScan();
  assert.equal(events.at(-1).result.error.code, 'SUBJECT_SCAN_ALREADY_ATTEMPTED');
  assert.equal(events.filter(Array.isArray).length, 1);
  Object.assign(subject, { candidateCount: 1, candidates: [{ id: 17 }], detectionAt: Date.now() });
  await c.selectSubject(17);
  assert.deepEqual(events.filter(Array.isArray).at(-1), [0x92, 0x0a, 0xba, 1, 5, 17]);
  assert.match(events.at(-1).result.data, /匹配编号/);
});

test('subject selection rejects a stale candidate and sends only the captured select and cancel commands', async () => {
  const {c,events}=controller();
  c.nativeTasks.activeOrUnknown=()=>false;
  c.flight.snapshot=()=>({landRequested:false});
  const subject={detectionAt:Date.now()-501,candidates:[{id:17}]};
  c.session={isReliableLinkFresh:()=>true,
    snapshot:()=>({telemetry:{task:{phaseRaw:0},taskAgeMs:0,subject}}),
    requestNative:async(receiver,set,id,payload)=>{
      events.push([receiver,set,id,...payload]);
      Object.assign(subject,{detectionAt:Date.now(),trackingAt:Date.now(),selectedIdCandidate:17,overlay:[{id:17}]});
      return Uint8Array.of(0);
    }};
  await c.selectSubject(17);
  assert.equal(events.at(-1).result.error.code,'SUBJECT_STALE');
  assert.equal(events.some(Array.isArray),false);
  subject.detectionAt=Date.now();
  await c.selectSubject(17);
  assert.deepEqual(events.find(Array.isArray),[0x92,0x0a,0xba,1,5,17]);
  assert.match(events.at(-1).result.data,/匹配编号/);
  await c.selectSubject();
  assert.deepEqual(events.filter(Array.isArray).at(-1),[0x92,0x0a,0xba,1,3,0]);
});
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
  const {c,events}=controller();let takeoffs=0, clears=0, airborne=false;
  let nativeResets=0;c.nativeTasks.resetAfterGroundedCycle=()=>{nativeResets++;};
  const session={isActionLinkFresh:()=>true,requestFlight:async()=>{takeoffs++;return new Uint8Array([0]);},
    clearSubjectObservation:()=>{clears++;},
    snapshot:()=>({telemetry:{flight:{observedAtMs:Date.now()+1,motorsOn:airborne,airborne},flightAgeMs:0}})};
  c.session=session;c.flight=new FlightCommandService(session);await c.takeoffConfirmed();
  c.hoverScanAttempted=true;c.selectedSubjectId=17;
  airborne=true;await c.takeoffConfirmed();
  assert.equal(takeoffs,1);assert.equal(clears,0);assert.equal(c.hoverScanAttempted,true);
  assert.equal(c.selectedSubjectId,17);assert.equal(events.at(-1).result.ok,false);
  assert.equal(nativeResets,0);
  airborne=false;await c.takeoffConfirmed();
  assert.equal(takeoffs,2);assert.equal(clears,1);assert.equal(c.hoverScanAttempted,false);
  assert.equal(c.selectedSubjectId,undefined);assert.equal(events.at(-1).result.ok,true);
  assert.equal(nativeResets,1);
});
test('photo context invalidates an already prepared native selection',async()=>{
  const {c,events}=controller();let prepared=true;
  c.nativeTasks.snapshot=()=>({busy:false,prepared,activeOrUnknown:false});
  c.nativeTasks.activeOrUnknown=()=>false;c.nativeTasks.cancel=()=>{prepared=false;};
  c.camera={shoot:async()=>({ok:true})};await c.shoot();assert.equal(prepared,false);
});

test('record stop retrieves this recording only after a successful stop reply', async () => {
  const { c, events } = controller();
  let accepted = false;
  c.camera = { stopRecording: async () => ({ ok: accepted }) };
  c.captureMedia.hasPending = () => true;
  c.captureMedia.markReady = kind => events.push('ready:' + kind);
  c.captureMedia.retrieveAll = async kind => {
    events.push('retrieve:' + kind); return [{ path: '/download/clip.mp4', size: 500 }];
  };
  c.presentAgentMedia = (kind, media) => events.push(media.path);
  await c.stopRecording();
  assert.equal(events.includes('retrieve:video'), false);
  accepted = true; await c.stopRecording();
  assert.ok(events.indexOf('ready:video') < events.indexOf('retrieve:video'));
  assert.ok(events.includes('/download/clip.mp4'));
});

test('landing cancels a transfer started by stop recording', async () => {
  const { c } = controller(); let transferToken;
  c.camera = { stopRecording: async () => ({ ok: true }) };
  c.captureMedia.hasPending = () => true;
  let finish;
  c.captureMedia.retrieveAll = async (kind, token) => {
    transferToken = token;
    await new Promise(resolve => { finish = resolve; });
    throw new Error('cancelled');
  };
  const stopping = c.stopRecording();
  await new Promise(resolve => setImmediate(resolve));
  await c.land();
  assert.equal(transferToken.isCancelled(), true);
  finish(); await stopping;
});

test('automatic native recording retrieval waits for task completion and preserves the operation lock', async () => {
  const { c, events } = controller();
  c.videoSessionEnabled = true;
  const telemetry = { flightAgeMs: 0, flight: { airborne: true, motorsOn: true } };
  c.session = { snapshot: () => ({ phase: 'ready', telemetry }) };
  c.speech = { isListeningOnce: () => false };
  c.camera = { snapshot: () => ({ operationActive: false }), observeTelemetry() {} };
  let active = true, ready = false;
  c.nativeTasks.activeOrUnknown = () => active;
  c.captureMedia.observe = (telemetry, running) => { if (!running) ready = true; };
  c.captureMedia.readyKind = () => ready ? 'video' : undefined;
  c.captureMedia.retrieveAll = async () => {
    assert.equal(c.busyValue, true); events.push('download');
    ready = false; return [{ path: '/download/native.mp4', size: 500 }];
  };
  await c.pollAutomaticMedia(); assert.equal(events.includes('download'), false);
  active = false;
  c.flight.snapshot = () => ({ landRequested: true });
  await c.pollAutomaticMedia(); assert.equal(events.includes('download'), false);
  telemetry.flight.airborne = false; telemetry.flight.motorsOn = false;
  await c.pollAutomaticMedia();
  assert.equal(events.filter(x => x === 'download').length, 1);
  assert.equal(c.busyValue, false);
  await c.pollAutomaticMedia();
});

test('a photo failure before trigger frees its baseline so the next shot can proceed', async () => {
  const { c } = controller(); let pending = false;
  c.captureMedia.begin = async () => { assert.equal(pending, false); pending = true; };
  c.captureMedia.discard = () => { pending = false; };
  c.camera = { shoot: async () => ({ok:false,error:{code:'CAMERA_CAPTURE_FAILED',message:'context timeout'}}) };
  const token = new CancellationToken(1);
  assert.equal((await c.shootAndRetrieve(token)).ok, false);
  assert.equal(pending, false);
  c.camera.shoot = async () => ({ok:true});
  assert.equal((await c.shootAndRetrieve(token)).ok, true);
});
test('native task ownership overrides an earlier manual takeoff ACK',async()=>{
  let changed=false;const service=new FlightCommandService({isActionLinkFresh:()=>true,
    setMovementAxes:()=>{changed=true;},centerSticks:async()=>{},snapshot:()=>({telemetry:{}})});
  service.takeoffAcknowledgedValue=true;service.markNativeTaskMayFly(Date.now());
  assert.equal((await service.move('forward',.001)).ok,false);assert.equal(changed,false);
});

test('native control returns to an owned hover only with fresh terminal task and idle camera evidence', () => {
  for (const mode of ['ready','executing','stale','recording','landing','tracking','unowned']) {
    const now=Date.now();
    const telemetry={flightAgeMs:0,flight:{modeRaw:mode==='tracking'?26:6,airborne:true,motorsOn:true,observedAtMs:now+1},
      taskAgeMs:mode==='stale'?2000:0,task:{payloadHex:mode==='executing'?'050d000100':'0000000100',observedAtMs:now+1},
      cameraAgeMs:0,camera:{recordingCandidate:mode==='recording',observedAtMs:now+1}};
    const flight=new FlightCommandService({isActionLinkFresh:()=>true,snapshot:()=>({telemetry})});
    flight.takeoffSentValue=true;flight.takeoffAcknowledgedValue=mode!=='unowned';
    flight.landRequestedValue=mode==='landing';flight.markNativeTaskMayFly(now);
    const result=flight.releaseNativeTaskAfterHover();
    assert.equal(result.ok,mode==='ready',mode);
    assert.equal(flight.snapshot().nativeTaskMayFly,mode!=='ready',mode);
    assert.equal(flight.snapshot().generation,1);
  }
});
