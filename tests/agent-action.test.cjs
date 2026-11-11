const { test } = require('node:test');
const assert = require('node:assert/strict');
const { validateAgentAction, validateAgentResponse, agentNeedsConfirmation } =
  require('../entry/src/main/ets/core/domain/AgentAction.ets');
const {parseDirectFlightVoice,parseDirectStopVoice}=require('../entry/src/main/ets/core/domain/AgentAction.ets');
const { AppController } = require('../entry/src/main/ets/core/domain/AppController.ets');
const { CancellationToken } = require('../entry/src/main/ets/core/domain/OperationResult.ets');

const observation = {
  requestId: 'r1', sessionId: 10, flightGeneration: 2, requestedAtMs: 1000,
  frame: { candidates: [{ id: 11 }, { id: 13 }] }
};

test('agent schema accepts supported actions and rejects invalid parameters and extra commands', () => {
  validateAgentAction({ action: 'select_subject', subjectId: 13 }, observation);
  validateAgentAction({ action: 'follow', subjectId: 13 }, observation);
  validateAgentAction({ action: 'takeoff' }, observation);
  validateAgentAction({ action: 'land' }, observation);
  assert.equal(agentNeedsConfirmation({action:'takeoff'}),false);
  assert.equal(agentNeedsConfirmation({ action: 'follow', subjectId: 13 }), true);
  validateAgentAction({ action: 'move', direction: 'left', seconds: 0.5 }, observation);
  validateAgentAction({ action: 'dolly_zoom', subjectId: 13, zoom: 3, framing: '全身' }, observation);
  for (const action of [
    { action: 'takeoff', seconds: 2 }, { action: 'navigate' }, { action: 'move', direction: 'diagonal' },
    { action: 'move', direction: 'left', seconds: -1 },
    { action: 'circle', radiusMeters: 11 }, { action: 'select_subject', subjectId: 99 },
    { action: 'photo', direction: 'up' }, { action: 'dolly_zoom', zoom: 5 }
  ]) assert.throws(() => validateAgentAction(action, observation));
  assert.throws(() => validateAgentAction({ action: 'select_subject', subjectId: 11 }, { ...observation, frame: undefined }));
  validateAgentAction({ action: 'photo' }, { ...observation, frame: undefined });
  assert.equal(agentNeedsConfirmation({ action: 'move' }), false);
  assert.equal(agentNeedsConfirmation({ action: 'circle' }), true);
  assert.equal(agentNeedsConfirmation({ action: 'photo' }), false);
});

test('local flight voice accepts explicit single commands but never negatives, questions or sequences', () => {
  for(const text of ['起飞','请起飞。','帮我起飞','无人机起飞','现在起飞吧']) assert.equal(parseDirectFlightVoice(text),'takeoff',text);
  for(const text of ['降落','立即降落！','请帮我降落','飞机降落吧']) assert.equal(parseDirectFlightVoice(text),'land',text);
  for(const text of ['不要起飞','别降落','起飞？','起飞了吗','可以起飞吗','如果起飞','先起飞再环绕','不要降落，继续悬停','']) {
    assert.equal(parseDirectFlightVoice(text),undefined,text);
  }
});

test('local takeoff and landing reuse the flight entry points without exporting a frame or contacting the cloud', async () => {
  for(const action of ['takeoff','land']){
    const {c}=agentController();let called=0;
    c.lastErrorValue='';c.session.snapshot=()=>({phase:'ready',telemetry:{flightAgeMs:0,flight:{airborne:false,motorsOn:false}}});
    c.takeoffConfirmed=async()=>{called++;};c.land=async()=>{called++;};
    const result=await c.executeLocalFlightVoice(action==='takeoff'?'帮我起飞':'立即降落');
    assert.equal(called,1);assert.ok(result.message.length>0);
  }
  const {c}=agentController();c.busyValue=true;let landed=false;
  c.land=async()=>{landed=true;};c.lastErrorValue='';
  await c.executeLocalFlightVoice('降落');assert.equal(landed,true);
  await assert.rejects(c.executeLocalFlightVoice('起飞'),/操作|执行|忙/);
});

test('local stop voice accepts short affirmative commands and keeps negation questions hypotheticals and quotes out',()=>{
  assert.ok(parseDirectStopVoice,'direct stop parser must be available');
  for(const text of ['停止','停止任务','停止拍摄','先停止','请停止。','请帮我立即停止任务！','无人机停止一下'])
    assert.equal(parseDirectStopVoice(text),'stop',text);
  for(const text of ['停止录像','先停止录像','请帮我停止录制','马上停止录像吧'])
    assert.equal(parseDirectStopVoice(text),'record_stop',text);
  for(const text of ['不要停止','别停止录像','不停止任务','停止？','停止了吗','可以停止吗','如果停止',
    '假如停止录像','“停止”','他说停止任务','停止再起飞','先停止然后降落','停止不是我要的','停止任务吗',''])
    assert.equal(parseDirectStopVoice(text),undefined,text);
});

test('local stop interrupts a busy scan through existing stop entry points while takeoff stays blocked',async()=>{
  for(const [text,kind] of [['停止任务','stop'],['停止录像','record_stop']]) {
    const {c}=agentController();
    c.busyValue=true;c.autoScanRunning=true;c.lastErrorValue='';
    const called=[];
    c.center=async()=>{called.push('stop');};
    c.stopRecording=async()=>{called.push('record_stop');c.agentFeedback='飞机已确认停止录像请求';};
    c.captureAgentObservation=async()=>{throw new Error('local stop must not capture an image');};
    c.requestCloudAgentAction=async()=>{throw new Error('local stop must not wait for cloud classification');};
    const outcome=await c.executeLocalFlightVoice(text);
    assert.deepEqual(called,[kind]);
    assert.match(outcome.message,/停止/);
    await assert.rejects(c.executeLocalFlightVoice('起飞'),/操作|执行|忙/);
    assert.deepEqual(called,[kind]);
    assert.equal(await c.executeLocalFlightVoice('不要停止'),undefined);
    assert.deepEqual(called,[kind]);
  }
});

test('local stop reports the existing stop entry point failure instead of claiming success',async()=>{
  for(const [text,method] of [['停止任务','center'],['停止录像','stopRecording']]) {
    const {c}=agentController();c.busyValue=true;c.lastErrorValue='';
    c[method]=async()=>{c.lastErrorValue='飞机未确认停止请求';};
    await assert.rejects(c.executeLocalFlightVoice(text),/飞机未确认停止请求/);
  }
});

test('agent responses bind to a single recent request and flight cycle', () => {
  const response = { version: 2, requestId: 'r1', command: { action: 'photo' } };
  validateAgentResponse(response, observation, 10, 2, 1500);
  assert.throws(() => validateAgentResponse({ ...response, requestId: 'r2' }, observation, 10, 2, 1500));
  assert.throws(() => validateAgentResponse(response, observation, 12, 2, 1500));
  assert.throws(() => validateAgentResponse(response, observation, 10, 3, 1500));
  assert.throws(() => validateAgentResponse(response, observation, 10, 2, 22000));
});

test('text planning may take up to one minute while visual decisions keep their shorter lifetime', () => {
  const textObservation = { ...observation, frame: undefined };
  const response = { version: 2, requestId: 'r1', command: { action: 'photo' } };
  validateAgentResponse(response, textObservation, 10, 2, 31000);
  validateAgentResponse(response, textObservation, 10, 2, 61000);
  assert.throws(() => validateAgentResponse(response, textObservation, 10, 2, 61001));
  assert.throws(() => validateAgentResponse(response, observation, 10, 2, 21001));
  assert.throws(() => validateAgentResponse(response, textObservation, 11, 2, 31000));
  assert.throws(() => validateAgentResponse(response, textObservation, 10, 3, 31000));
});

test('a valid text-only movement decision executes its specified duration directly', async () => {
  const { c, calls, obs } = agentController();
  const textObservation = { ...obs, frame: undefined, requestedAtMs: Date.now() - 30000 };
  const response = { version: 2, requestId: 'r1', command: { action: 'move', direction: 'left', seconds: 1 } };
  const outcome = await c.acceptAgentResponse(textObservation, response);
  assert.equal(outcome.confirmationRequired, undefined);
  assert.equal(c.pendingAgentAction,undefined);
  assert.deepEqual(calls,[{direction:'left',seconds:1}]);
});


function agentController() {
  const calls = [];
  const c = Object.create(AppController.prototype);
  c.captureMedia = { begin: async () => {}, discard() {}, markReady() {},
    hasPending: () => false,
    retrieveAll: async () => [{ path: '/download/new.jpg', size: 200 }] };
  c.presentAgentMedia = (kind, media) => { c.preview = { kind, path: media.path }; };
  c.presentAgentMediaGroup = (kind, media) => c.presentAgentMedia(kind, media[0]);
  c.agentMediaUris = []; c.agentMediaIndex = 0;
  Object.assign(c, {
    agentGeneration: 0, latestAgentRequestId: 'r1', acceptedAgentRequestId: '',
    activeOperations: 0, busyValue: false, log() {}, emit() {}, recordResult() {}, recordException() {},
    nativeTasks: { cancel() {}, activeOrUnknown: () => false },
    session: { sessionId: () => 10, isReliableLinkFresh: () => true },
    flight: {
      snapshot: () => ({ generation: 2 }),
      newCancellationToken: () => new CancellationToken(2),
      move: async (direction, seconds) => { calls.push({ direction, seconds }); return { ok: true, data: true }; }
    }
  });
  const obs = { ...observation, controlGeneration: 0, requestedAtMs: Date.now(),
    context: { movementSeconds: 0.5 } };
  return { c, calls, obs };
}

test('cloud takeoff executes once without a second confirmation and rejects a duplicate response', async () => {
  const {c,obs}=agentController();let starts=0;
  c.lastErrorValue='';c.takeoffConfirmed=async()=>{starts++;};
  c.session.snapshot=()=>({phase:'ready',telemetry:{flightAgeMs:0,flight:{airborne:false,motorsOn:false}}});
  const response={version:2,requestId:'r1',command:{action:'takeoff'}};
  const result=await c.acceptAgentResponse(obs,response);
  assert.equal(starts,1);assert.equal(result.confirmationRequired,undefined);
  await assert.rejects(c.acceptAgentResponse(obs,response),/已处理/);
  assert.equal(starts,1);
});

test('voice takeoff cannot send against stale, unknown, airborne or spinning flight state', async () => {
  for(const mode of ['stale','missing','airborne','motors']){
    const {c}=agentController();let starts=0;c.takeoffConfirmed=async()=>{starts++;};
    c.session.snapshot=()=>({phase:'ready',telemetry:{flightAgeMs:mode==='stale'?2000:0,
      flight:mode==='missing'?undefined:{airborne:mode==='airborne',motorsOn:mode==='motors'}}});
    await assert.rejects(c.executeLocalFlightVoice('起飞'));
    assert.equal(starts,0);
  }
});

test('phone cloud request rejects a response when the control generation changes during inference', async()=>{
  const {c,obs}=agentController();
  c.initializeCloudVlm=async()=>{};c.session.snapshot=()=>({phase:'ready'});
  c.cloudVlm={request:async(observation,text,isCurrent)=>{
    assert.equal(isCurrent(),true);c.agentGeneration++;assert.equal(isCurrent(),false);
    return {version:2,requestId:obs.requestId,command:{action:'photo'}};
  }};
  await assert.rejects(c.requestCloudAgentAction(obs,'拍照'),/取消|变化/);
});

test('movement executes once without another confirmation and rejects duplicate responses', async () => {
  const { c, calls, obs } = agentController();
  const response = { version: 2, requestId: 'r1', command: { action: 'move', direction: 'left', seconds: 1.5 } };
  const result = await c.acceptAgentResponse(obs, response);
  assert.equal(result.confirmationRequired,undefined);
  assert.equal(c.pendingAgentAction,undefined);
  assert.deepEqual(calls,[{direction:'left',seconds:1.5}]);
  await assert.rejects(c.acceptAgentResponse(obs, response), /已处理/);
  assert.equal(calls.length,1);
  await assert.rejects(c.confirmAgentAction(), /没有有效/);
});

test('cancellation, expired responses and flight generation changes suppress direct movement', async () => {
  for (const invalidate of [
    c => c.cancelAgentAction(),
    (c,obs) => { obs.requestedAtMs=Date.now()-20001; },
    c => { c.flight.snapshot = () => ({ generation: 3 }); }
  ]) {
    const { c, calls, obs } = agentController();
    invalidate(c,obs);
    await assert.rejects(c.acceptAgentResponse(obs, { version: 2, requestId: 'r1',
      command: { action: 'move', direction: 'up', seconds: 1 } }));
    assert.deepEqual(calls, []);
  }
});

test('all eight directions preserve different VLM durations instead of replacing them with the slider',async()=>{
  const directions=['forward','backward','left','right','up','down','turn_left','turn_right'];
  for(const [index,direction] of directions.entries()){
    const {c,calls,obs}=agentController();obs.context.movementSeconds=4;
    const seconds=[.1,.3,.5,1,1.5,2,3,10][index];
    const result=await c.acceptAgentResponse(obs,{version:2,requestId:'r1',command:{action:'move',direction,seconds}});
    assert.deepEqual(calls,[{direction,seconds}]);assert.equal(result.confirmationRequired,undefined);
    assert.equal(c.pendingAgentAction,undefined);
  }
});

test('missing or invalid model movement duration never falls back to a default or sends a motion',async()=>{
  for(const seconds of [undefined,0,-1,.09,10.01,NaN,Infinity,'2']){
    const {c,calls,obs}=agentController();obs.context.movementSeconds=.5;
    await assert.rejects(c.acceptAgentResponse(obs,{version:2,requestId:'r1',
      command:{action:'move',direction:'forward',...(seconds===undefined?{}:{seconds})}}),/时长/);
    assert.deepEqual(calls,[]);assert.equal(c.pendingAgentAction,undefined);
  }
});

test('a busy controller never queues a direct movement for later execution',async()=>{
  const {c,calls,obs}=agentController();c.busyValue=true;
  await assert.rejects(c.acceptAgentResponse(obs,{version:2,requestId:'r1',
    command:{action:'move',direction:'forward',seconds:1}}),/执行|操作/);
  assert.deepEqual(calls,[]);assert.equal(c.pendingAgentAction,undefined);
});

test('a failed target selection prevents the airborne dolly start', async () => {
  const { c, obs } = agentController();
  const subject = { tracking: true, overlay: [{ id: 11 }] };
  obs.frame.currentSubjectId = 11;
  c.nativeConfig = { radiusMeters: 2, framing: '半身', zoom: 2, retreat: true };
  c.session.snapshot = () => ({ telemetry: { flightAgeMs: 0, flight: { airborne: true, motorsOn: true }, subject } });
  c.nativeTasks.snapshot = () => ({ kind: 'dolly', prepared: true });
  c.requestSubjectSelection = async () => ({ ok: false, error: { message: 'target lost' } });
  let starts = 0;
  c.nativeTasks.start = async () => { starts++; return { ok: true, data: 'started' }; };
  await assert.rejects(c.startAgentDolly(obs, { action: 'dolly_zoom', subjectId: 13 }, new CancellationToken(2)), /target lost/);
  assert.equal(starts, 0);
});

test('a single airborne request prepares new dolly parameters, reselects its target, then starts', async () => {
  for (const kind of ['dolly', 'follow']) {
    const { c, obs } = agentController();
    const events = [];
    obs.frame.currentSubjectId = 11;
    const state = { telemetry: { flightAgeMs: 0, taskAgeMs: 0, cameraAgeMs: 0,
      flight: { airborne: true, motorsOn: true, modeRaw: 26 },
      task: { modeRaw: 0, phaseRaw: 0 }, camera: { recordingCandidate: false },
      subject: { tracking: true, overlay: [{ id: 11 }], get trackingAt() { return Date.now(); } } } };
    c.session.snapshot = () => state;
    c.flight.snapshot = () => ({ generation: 2, takeoffSent: true, takeoffAcknowledged: true });
    c.nativeConfig = { radiusMeters: 2, framing: '全身', zoom: 2, retreat: false };
    c.nativeTasks.snapshot = () => ({ kind: '', prepared: false });
    c.nativeTasks.prepareHover = async (task, config) => {
      assert.equal(state.telemetry.subject.tracking, false);
      assert.equal(state.telemetry.flight.modeRaw, 6);
      if (task === 'dolly') assert.equal(config.zoom, 3);
      events.push('prepare:' + task); return { ok: true, data: true };
    };
    c.waitAgentPhotoHover = async () => { events.push('hover'); };
    c.requestSubjectSelection = async (token, target) => {
      events.push('select:' + target);
      state.telemetry.subject.tracking = target !== undefined;
      state.telemetry.subject.overlay = target === undefined ? [] : [{ id: target }];
      state.telemetry.flight.modeRaw = target === undefined ? 6 : 26;
      return { ok: true, data: 'selected' };
    };
    c.nativeTasks.start = async (confirmed, token, target) => {
      assert.equal(target, 13); assert.equal(confirmed, true);
      events.push('start'); return { ok: true, data: 'start acknowledged' };
    };
    const command = kind === 'dolly' ? {action:'dolly_zoom',subjectId:13,zoom:3,framing:'半身'} :
      {action:'follow',subjectId:13};
    const result = await c.requestAgentExecution(obs, command, new CancellationToken(2));
    assert.equal(result.message, 'start acknowledged');
    assert.deepEqual(events, ['select:undefined', 'hover', 'prepare:' + kind, 'select:13', 'start']);
  }
});

test('independent follow enters the shared subject confirmation instead of generic flight confirmation', async () => {
  const { c, obs } = agentController();
  let entered=0;c.session.snapshot=()=>({telemetry:{flight:{motorsOn:true}}});
  c.groundDolly=new (require('../entry/src/main/ets/core/domain/SubjectTaskWorkflow.ets').SubjectTaskWorkflow)(()=>{});
  c.startGroundDolly=async(description,intent,original,entry,inferred)=>{
    entered++;assert.equal(intent.action,'follow');assert.equal(original,obs);assert.equal(entry,'hover');
    assert.equal(inferred.subjectId,13);return {message:'请确认主体',confirmationRequired:true};
  };
  const result = await c.acceptAgentResponse(obs, {version:2,requestId:'r1',command:{action:'follow',subjectId:13}});
  assert.equal(result.confirmationRequired, true);
  assert.equal(entered,1);assert.equal(c.pendingAgentAction,undefined);
});

test('another airborne dolly hands off the completed task before changing parameters or preparing', async () => {
  const {c,obs}=agentController();const events=[];let owned=true;
  obs.frame.currentSubjectId=11;
  const state={telemetry:{flightAgeMs:0,taskAgeMs:0,cameraAgeMs:0,flight:{modeRaw:26,airborne:true,motorsOn:true},
    task:{modeRaw:0,phaseRaw:0},camera:{recordingCandidate:false},
    subject:{tracking:true,overlay:[{id:11}],get trackingAt(){return Date.now();}}}};
  c.session.snapshot=()=>state;
  c.flight.snapshot=()=>({generation:2,takeoffSent:true,takeoffAcknowledged:true,nativeTaskMayFly:owned});
  c.nativeConfig={radiusMeters:2,framing:'半身',zoom:2,retreat:true};
  c.nativeTasks.canCompleteForHover=()=>({ok:true,data:true});
  c.nativeTasks.completeForHover=()=>{
    assert.equal(state.telemetry.flight.modeRaw,6);events.push('handoff');owned=false;return {ok:true,data:true};
  };
  c.requestSubjectSelection=async(token,target)=>{
    events.push('select:'+target);state.telemetry.subject.tracking=target!==undefined;
    state.telemetry.subject.overlay=target===undefined?[]:[{id:target}];state.telemetry.flight.modeRaw=target===undefined?6:26;
    return {ok:true,data:'selected'};
  };
  c.waitAgentPhotoHover=async()=>{};
  c.nativeTasks.prepareHover=async(kind,config)=>{
    assert.equal(owned,false);assert.equal(config.zoom,3);events.push('prepare');return {ok:true,data:true};
  };
  c.nativeTasks.snapshot=()=>({});c.nativeTasks.start=async()=>{events.push('start');return {ok:true,data:'started'};};
  await c.startAgentDolly(obs,{action:'dolly_zoom',subjectId:13,zoom:3},new CancellationToken(2));
  assert.deepEqual(events,['select:undefined','handoff','prepare','select:13','start']);
});

test('pending video or unconfirmed task completion prevents hover handoff and a second shot', async () => {
  for(const pending of [true,false]){
    const {c,obs}=agentController();let selection=false;
    c.flight.snapshot=()=>({nativeTaskMayFly:true});c.captureMedia.hasPending=()=>pending;
    c.nativeTasks.canCompleteForHover=()=>({ok:false,error:{message:'completion unknown'}});
    c.requestSubjectSelection=async()=>{selection=true;return {ok:true,data:true};};
    await assert.rejects(c.handoffCompletedNativeTask(obs,new CancellationToken(2)));
    assert.equal(selection,false);
  }
});

test('targeted photo cannot fire the shutter if subject selection fails', async () => {
  const { c, obs } = agentController();
  obs.frame = { ...obs.frame, currentSubjectId: undefined };
  c.session.snapshot = () => ({ telemetry: { subject: { tracking: false, overlay: [] } } });
  c.media = { listMedia: async () => ({ ok: true, data: [] }) };
  c.requestSubjectSelection = async () => ({ ok: false, error: { message: 'target lost' } });
  let shutters = 0;
  c.camera = { shoot: async () => { shutters++; return { ok: true, data: 'ok' }; } };
  await assert.rejects(c.requestAgentExecution(obs, { action: 'photo', subjectId: 13 }, new CancellationToken(2)), /target lost/);
  assert.equal(shutters, 0);
});

test('saving a preview clears it only after success and preserves a newer download', async () => {
  const { c } = agentController();
  c.agentMediaUri = 'file://photo-1.jpg'; c.agentMediaKind = 'photo';
  let complete;
  c.gallerySaver = { save: async () => new Promise(resolve => { complete = resolve; }) };
  const saving = c.saveAgentMedia({});
  assert.equal(c.agentMediaUri, 'file://photo-1.jpg');
  await assert.rejects(c.saveAgentMedia({}), /正在保存/);
  complete(); await saving;
  assert.equal(c.agentMediaUri, '');
  assert.equal(c.agentMediaKind, '');
  c.agentMediaUri = 'file://video-1.mp4'; c.agentMediaKind = 'video';
  const second = c.saveAgentMedia({});
  c.agentMediaUri = 'file://photo-2.jpg'; c.agentMediaKind = 'photo';
  complete(); await second;
  assert.equal(c.agentMediaUri, 'file://photo-2.jpg');
});

test('failed gallery save keeps the original preview available for retry', async () => {
  const { c } = agentController();
  c.agentMediaUri = 'file://photo.jpg'; c.agentMediaKind = 'photo';
  c.gallerySaver = { save: async () => { throw new Error('write denied'); } };
  await assert.rejects(c.saveAgentMedia({}), /write denied/);
  assert.equal(c.agentMediaUri, 'file://photo.jpg');
  assert.equal(c.agentMediaSaving, false);
});

test('video group can be switched and saving removes only the current part', async () => {
  const { c } = agentController();
  c.agentMediaUris = ['file://part1.mp4','file://part2.mp4'];
  c.agentMediaKind = 'video'; c.agentMediaUri = c.agentMediaUris[0];
  c.gallerySaver = {save:async()=>{}};
  c.selectAgentMedia(1); assert.equal(c.agentMediaUri, 'file://part2.mp4');
  await c.saveAgentMedia({});
  assert.deepEqual(c.agentMediaUris, ['file://part1.mp4']);
  assert.equal(c.agentMediaUri, 'file://part1.mp4');
  assert.equal(c.agentMediaKind, 'video');
  await c.saveAgentMedia({});
  assert.equal(c.agentMediaUri, ''); assert.equal(c.agentMediaKind, '');
  assert.deepEqual(c.agentMediaUris, []);
});

test('saving an old part never clears a newer capture group', async () => {
  const { c } = agentController();
  c.agentMediaUris = ['file://old1.mp4','file://old2.mp4'];
  c.agentMediaKind='video';c.agentMediaUri=c.agentMediaUris[0];
  let finish;
  c.gallerySaver = {save:async()=>new Promise(resolve=>{finish=resolve;})};
  const saving = c.saveAgentMedia({});
  c.selectAgentMedia(1); assert.equal(c.agentMediaUri,'file://old1.mp4');
  c.agentMediaUris=['file://new1.mp4','file://new2.mp4'];c.agentMediaUri=c.agentMediaUris[0];
  finish();await saving;
  assert.deepEqual(c.agentMediaUris,['file://new1.mp4','file://new2.mp4']);
  assert.equal(c.agentMediaUri,'file://new1.mp4');
});

test('reconnecting while saving a group cannot resurrect its remaining video preview', async () => {
  const { c } = agentController();
  c.agentMediaUris=['file://old1.mp4','file://old2.mp4'];c.agentMediaUri=c.agentMediaUris[0];c.agentMediaKind='video';
  let finish;
  c.gallerySaver={save:async()=>new Promise(resolve=>{finish=resolve;})};
  const saving=c.saveAgentMedia({});
  c.profiles={selected:()=>({configured:true,registrationReady:true,routingReady:true}),selectedId:()=> 'a',runtime:()=>({})};
  c.flight.resetForAircraftSession=()=>{};c.nativeTasks.resetForAircraftSession=()=>{};
  c.camera={resetForAircraftSession(){}};c.captureMedia.reset=()=>{};
  c.wifi={join:async()=>({}),leave:async()=>{}};c.session.connect=async()=>({ok:true});
  await c.connectSelectedAircraft();
  finish();await saving;
  assert.equal(c.agentMediaUri,'');assert.deepEqual(c.agentMediaUris,[]);assert.equal(c.agentMediaIndex,0);
});

test('photo releases tracking and waits for manual hover before switching camera context', async () => {
  const { c, obs } = agentController();
  const state = { telemetry: {
    flightAgeMs: 0, flight: { modeRaw: 26, airborne: true, motorsOn: true },
    taskAgeMs: 0, task: { phaseRaw: 0, modeRaw: 0 },
    subject: { tracking: true, overlay: [{ id: 11 }] }
  } };
  c.session.snapshot = () => state;
  c.voice = { cancelPending() {} };
  const calls = [];
  c.requestSubjectSelection = async (token, id) => {
    calls.push(['selection', id]);
    state.telemetry.subject.tracking = false;
    state.telemetry.subject.overlay = [];
    state.telemetry.flight.modeRaw = 6;
    return { ok: true, data: 'cancelled' };
  };
  c.camera = { shoot: async () => {
    assert.equal(state.telemetry.subject.tracking, false);
    assert.equal(state.telemetry.flight.modeRaw, 6);
    calls.push(['shutter']);
    return { ok: true, data: 'capture acknowledged' };
  } };
  const result = await c.requestAgentExecution(obs, { action: 'photo' }, new CancellationToken(2));
  assert.deepEqual(calls, [['selection', undefined], ['shutter']]);
  assert.equal(result.message, '本次照片已取回');
  assert.deepEqual(c.preview, { kind: 'photo', path: '/download/new.jpg' });
});
