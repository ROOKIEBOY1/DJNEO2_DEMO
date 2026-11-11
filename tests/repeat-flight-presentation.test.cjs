const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
const {GroundDollyWorkflow}=require('../entry/src/main/ets/core/domain/GroundDollyWorkflow.ets');
const {CloseupSequence}=require('../entry/src/main/ets/core/domain/CloseupSequence.ets');
const {MovieComposer}=require('../entry/src/main/ets/core/media/MovieComposer.ets');
const {taskProgressPresentation}=require('../entry/src/main/ets/core/domain/AssistantFlightPresentation.ets');

async function fixture({pending=false,active=false,movieStage='idle'}={}){
  const c=Object.create(AppController.prototype);const cancelled=[];
  const groundDolly=new GroundDollyWorkflow(()=>{});
  const host={isCurrent:()=>true,takeoff:async()=>{},waitForCandidates:async()=>{},
    select:async()=>({action:'dolly_zoom',subjectId:13,zoom:3}),shoot:async()=>({message:'已启动'})};
  await groundDolly.start('拍特写',{action:'dolly_zoom'},host);await groundDolly.confirm();
  if(!active)await groundDolly.execute();
  const movieComposer=new MovieComposer({start:()=>7,snapshot:()=>({id:7,stage:'completed',
    progress:1,durationMs:1000,error:'',outputPath:'/files/movie.mp4'}),cancel:id=>cancelled.push(id)});
  movieComposer.setSources(['file:///files/clip.mp4'],'rev');
  if(movieStage!=='idle')movieComposer.start('/files/movie.mp4','/files/music.mp3');
  if(movieStage==='completed')movieComposer.poll();
  Object.assign(c,{groundDolly,closeupSequence:new CloseupSequence(()=>{}),
    captureMedia:{hasPending:()=>pending,reset(){throw Error('a new voice must retain pending capture');}},
    nativeTasks:{snapshot:()=>({busy:false,activeOrUnknown:false}),activeOrUnknown:()=>false},
    camera:{snapshot:()=>({operationActive:false,recordingRequested:false})},
    session:{snapshot:()=>({phase:'ready',telemetry:{flightAgeMs:0,
      flight:{airborne:false,motorsOn:false},cameraAgeMs:0,camera:{recordingCandidate:false}}})},
    movieComposer,movieFiles:{revision:()=> 'rev',loadCompleted:()=>undefined},
    movieSourceIdentity:JSON.stringify(['file:///files/clip.mp4']),moviePreparationEpoch:0,
    agentMediaUris:['file:///files/clip.mp4'],agentMediaUri:'file:///files/clip.mp4',
    agentMediaKind:'video',agentVideoResultReady:true,busyValue:false,lastErrorValue:'',
    emit(){},takeoffConfirmed:async()=>{c.lastErrorValue='Verified device reply, downlink and video must all be fresh';}});
  return {c,cancelled};
}

test('a repeated local takeoff retires only old progress and retains movie sources on rejection',async()=>{
  for(const movieStage of ['idle','probing','completed']){
    const {c,cancelled}=await fixture({movieStage});const before=c.movieComposer.snapshot();
    await assert.rejects(c.executeLocalFlightVoice('起飞'),/Verified device reply/);
    assert.equal(c.groundDolly.snapshot().stage,'idle');
    assert.deepEqual(c.agentMediaUris,['file:///files/clip.mp4']);assert.equal(c.agentVideoResultReady,true);
    c.syncMovieSources();assert.deepEqual(c.movieComposer.snapshot(),before);
    assert.deepEqual(cancelled,[]);
  }
});

test('new direct voice retains a pending return or active ground plan',async()=>{
  for(const options of [{pending:true},{active:true}]){
    const {c}=await fixture(options);const before=c.groundDolly.snapshot();
    await assert.rejects(c.executeLocalFlightVoice('起飞'),/Verified device reply/);
    assert.deepEqual(c.groundDolly.snapshot(),before);
  }
});

test('presentation retirement leaves active capture operations and incomplete return groups owned by their workflow',async()=>{
  for(const operation of ['closeup','native','camera','recording','busy']){
    const {c}=await fixture();const before=c.groundDolly.snapshot();
    if(operation==='closeup')c.closeupSequence={snapshot:()=>({active:true,stage:'dolly_wait'})};
    if(operation==='native')c.nativeTasks.activeOrUnknown=()=>true;
    if(operation==='camera')c.camera.snapshot=()=>({operationActive:true});
    if(operation==='recording')c.camera.snapshot=()=>({recordingRequested:true});
    if(operation==='busy')c.busyValue=true;
    await assert.rejects(c.executeLocalFlightVoice('起飞'));
    assert.deepEqual(c.groundDolly.snapshot(),before,operation);
    assert.deepEqual(c.agentMediaUris,['file:///files/clip.mp4']);
  }
});

test('a new aircraft connection retires old shooting progress and retains any completed local movie',async()=>{
  for(const movieStage of ['idle','probing','completed']){
    const {c,cancelled}=await fixture({movieStage});let connections=0;
    const before=c.movieComposer.snapshot();
    const state=()=>({groundDolly:c.groundDolly.snapshot(),closeup:c.closeupSequence.snapshot(),
      agentMediaUris:c.agentMediaUris,agentMediaUri:c.agentMediaUri,agentMediaKind:c.agentMediaKind,
      agentVideoResultReady:c.agentVideoResultReady,videoCapturePending:false,agentConfirmation:'',
      session:c.session.snapshot(),nativeTask:c.nativeTasks.snapshot(),agentFeedback:''});
    Object.assign(c,{snapshot:state,profiles:{selected:()=>({configured:true,registrationReady:true,routingReady:true}),
      runtime:()=>({}),selectedId:()=> 'aircraft'},flight:{resetForAircraftSession(){}},
      closeupMedia:{clear(){}},run:async(_name,operation)=>operation(),
      wifi:{join:async()=>({}),leave:async()=>{}}});
    c.nativeTasks.resetForAircraftSession=()=>{};c.camera.resetForAircraftSession=()=>{};
    c.captureMedia.reset=()=>{};c.session.connect=async()=>{connections++;return {ok:true};};
    await c.connectSelectedAircraft();
    assert.equal(connections,1);assert.equal(c.groundDolly.snapshot().stage,'idle');
    assert.equal(taskProgressPresentation(state()).visible,false);
    if(movieStage!=='idle'){
      assert.deepEqual(c.agentMediaUris,['file:///files/clip.mp4']);c.syncMovieSources();
      assert.deepEqual(c.movieComposer.snapshot(),before);assert.deepEqual(cancelled,[]);
    }
  }
});
