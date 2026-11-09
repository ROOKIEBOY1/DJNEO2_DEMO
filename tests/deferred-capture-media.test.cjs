const {test}=require('node:test');
const assert=require('node:assert/strict');
const {CaptureMedia}=require('../entry/src/main/ets/core/media/CaptureMedia.ets');
const {CancellationToken}=require('../entry/src/main/ets/core/domain/OperationResult.ets');

function fixture(){
  let now=1000,sessionId=10,recording=false,fresh=true,queries=0,waitHook,telemetryOverride={};
  const old={path:'old.MP4',kind:'video',size:100};let entries=[old];const downloads=[];
  const session={sessionId:()=>sessionId,isReliableLinkFresh:()=>fresh,
    snapshot:()=>({telemetry:{flightAgeMs:0,flight:{observedAtMs:now,airborne:false,motorsOn:false},
      cameraAgeMs:0,camera:{observedAtMs:now,recordingCandidate:recording},
      taskAgeMs:0,task:{observedAtMs:now,phaseRaw:0,modeRaw:0},...telemetryOverride}})};
  const repo={listMedia:async()=>{queries++;return {ok:true,data:entries.slice()};},
    downloadEntry:async entry=>{downloads.push(entry.path);return {ok:true,data:{path:'/download/'+entry.path}};}};
  const capture=new CaptureMedia(session,repo,'/download',()=>now,async ms=>{now+=ms;if(waitHook)await waitHook();});
  function observe(value,active){recording=value;capture.observe(session.snapshot().telemetry,active);}
  function seal(){now++;observe(true,true);now+=100;observe(false,false);}
  return {capture,repo,session,downloads,old,seal,observe,queries:()=>queries,advance:ms=>{now+=ms;},
    setEntries:value=>{entries=value;},setSession:value=>{sessionId=value;},setFresh:value=>{fresh=value;},
    setWaitHook:hook=>{waitHook=hook;},now:()=>now,setTelemetry:value=>{telemetryOverride={...telemetryOverride,...value};}};
}

test('one deferred baseline covers both shots and returns all new videos only after the final finish',async()=>{
  const f=fixture(),token=new CancellationToken(1);
  const id=await f.capture.beginVideoSequence(token);
  assert.equal(f.capture.isVideoSequenceCurrent(id),true);assert.equal(f.queries(),1);
  const a={path:'a.MP4',kind:'video',size:200},b={path:'b.MP4',kind:'video',size:300};
  f.setEntries([f.old,a]);f.seal();
  assert.equal(f.capture.canContinueVideoSequence(id),true);assert.equal(f.capture.readyKind(),undefined);
  await assert.rejects(f.capture.retrieveAll('video',token,()=>{}),/组合|结束|序列/);
  assert.equal(f.queries(),1);assert.deepEqual(f.downloads,[]);
  f.capture.continueVideoSequence(id,token);
  assert.equal(f.queries(),1,'continuing must not replace the first baseline or list media');
  assert.equal(f.capture.canContinueVideoSequence(id),false);assert.equal(f.capture.readyKind(),undefined);
  f.setEntries([f.old,a,b]);f.seal();
  assert.equal(f.capture.readyKind(),undefined);f.capture.finishVideoSequence(id,token);
  assert.equal(f.capture.readyKind(),'video');assert.equal(f.capture.canContinueVideoSequence(id),false);
  const result=await f.capture.retrieveAll('video',token,()=>{});
  assert.deepEqual(result.map(item=>item.path),['/download/a.MP4','/download/b.MP4']);
  assert.deepEqual(f.downloads,['a.MP4','b.MP4']);assert.equal(f.capture.isVideoSequenceCurrent(id),false);
});

test('manual markReady and missing, active or pre-step camera evidence cannot seal or advance a sequence',async()=>{
  const f=fixture(),token=new CancellationToken(1);const id=await f.capture.beginVideoSequence(token);
  f.capture.markReady('video');assert.equal(f.capture.canContinueVideoSequence(id),false);
  assert.throws(()=>f.capture.continueVideoSequence(id,token),/结束|封存|就绪/);
  assert.throws(()=>f.capture.finishVideoSequence(id,token),/结束|封存|就绪/);
  f.observe(false,false);assert.equal(f.capture.canContinueVideoSequence(id),false);
  f.observe(true,true);f.advance(100);f.observe(false,true);
  assert.equal(f.capture.canContinueVideoSequence(id),false,'active task cannot produce a seal');
  f.observe(false,false);assert.equal(f.capture.canContinueVideoSequence(id),true);
  f.capture.continueVideoSequence(id,token);
  f.capture.observe({cameraAgeMs:0,camera:{observedAtMs:999,recordingCandidate:true}},false);
  f.observe(false,false);assert.equal(f.capture.canContinueVideoSequence(id),false,'the first step cannot seal the second');
});

test('ordinary pending media and old sequence IDs cannot bypass the baseline guard',async()=>{
  const f=fixture(),token=new CancellationToken(1);
  await f.capture.begin('video',token);f.capture.markReady('video');
  for(const id of [1,undefined,null,NaN,0,-1,1.1]){
    assert.equal(f.capture.isVideoSequenceCurrent(id),false);assert.equal(f.capture.canContinueVideoSequence(id),false);
  }
  assert.throws(()=>f.capture.continueVideoSequence(1,token),/序列|失效|会话/);
  await assert.rejects(f.capture.beginVideoSequence(token),/上一份/);
  f.capture.discard('video');const id=await f.capture.beginVideoSequence(token);f.seal();
  await assert.rejects(f.capture.begin('video',token),/上一份/);
  assert.throws(()=>f.capture.continueVideoSequence(id+1,token),/序列|失效|会话/);
  assert.throws(()=>f.capture.finishVideoSequence(id+1,token),/序列|失效|会话/);
  f.capture.releaseVideoSequence(id+1);assert.equal(f.capture.readyKind(),undefined);
  f.capture.discard('video');assert.equal(f.capture.isVideoSequenceCurrent(id),false);
  const next=await f.capture.beginVideoSequence(token);assert.notEqual(next,id);
  f.capture.releaseVideoSequence(id);assert.equal(f.capture.readyKind(),undefined);
});

test('released prior-step evidence never downloads while a later step is still recording',async()=>{
  const f=fixture(),token=new CancellationToken(1);const id=await f.capture.beginVideoSequence(token);
  f.seal();f.capture.continueVideoSequence(id,token);f.advance(100);f.observe(true,true);
  f.capture.releaseVideoSequence(id);assert.equal(f.capture.readyKind(),'video');
  const a={path:'a.MP4',kind:'video',size:200},b={path:'b.MP4',kind:'video',size:300};
  f.setEntries([f.old,a,b]);let waited=0;
  f.setWaitHook(()=>{
    if(++waited<=2){assert.equal(f.queries(),1);assert.deepEqual(f.downloads,[]);}
    if(waited===2)f.observe(false,false);
  });
  const result=await f.capture.retrieveAll('video',token,()=>{});
  assert.ok(waited>=2);assert.deepEqual(result.map(x=>x.path),['/download/a.MP4','/download/b.MP4']);
});

test('reset, changed session, cancelled token and lost link invalidate sequence advancement',async()=>{
  for(const change of ['reset','session','cancel','link']){
    const f=fixture(),token=new CancellationToken(1);const id=await f.capture.beginVideoSequence(token);f.seal();
    if(change==='reset')f.capture.reset();else if(change==='session')f.setSession(11);
    else if(change==='cancel')token.cancel();else f.setFresh(false);
    assert.throws(()=>f.capture.continueVideoSequence(id,token),/取消|会话|失效|序列/);
    assert.throws(()=>f.capture.finishVideoSequence(id,token),/取消|会话|失效|序列/);
    if(change==='reset'||change==='session')assert.equal(f.capture.isVideoSequenceCurrent(id),false);
    else assert.equal(f.capture.isVideoSequenceCurrent(id),true,'ownership is separate from execution permission');
    assert.deepEqual(f.downloads,[]);
  }
});

test('release exposes only already sealed partial media and is safe when repeated',async()=>{
  const f=fixture(),token=new CancellationToken(1);const id=await f.capture.beginVideoSequence(token);
  f.capture.releaseVideoSequence(id);f.capture.releaseVideoSequence(id);
  assert.equal(f.capture.readyKind(),undefined,'release must not invent readiness');
  f.seal();assert.equal(f.capture.readyKind(),'video');
  f.setEntries([f.old,{path:'a.MP4',kind:'video',size:200}]);
  assert.equal((await f.capture.retrieveAll('video',token,()=>{})).length,1);
  f.capture.releaseVideoSequence(id);assert.equal(f.capture.hasPending('video'),false);
});

test('releasing a failed second step retains the first seal and all later completed footage',async()=>{
  const f=fixture(),token=new CancellationToken(1);const id=await f.capture.beginVideoSequence(token);
  f.seal();f.capture.continueVideoSequence(id,token);
  assert.equal(f.capture.canContinueVideoSequence(id),false);
  f.capture.releaseVideoSequence(id,true);
  assert.equal(f.capture.hasPending('video'),true,'a first sealed shot must never be discarded');
  assert.equal(f.capture.readyKind(),'video','the first genuine seal is retained for partial retrieval');
  f.setEntries([f.old,{path:'a.MP4',kind:'video',size:200}]);
  assert.deepEqual((await f.capture.retrieveAll('video',token,()=>{})).map(x=>x.path),['/download/a.MP4']);
});

test('an unstarted empty sequence may be discarded only with explicit unstarted proof',async()=>{
  const f=fixture(),token=new CancellationToken(1);const id=await f.capture.beginVideoSequence(token);
  f.capture.releaseVideoSequence(id);assert.equal(f.capture.hasPending('video'),true);
  f.capture.releaseVideoSequence(id,true);assert.equal(f.capture.hasPending('video'),false);
  const next=await f.capture.beginVideoSequence(token);f.observe(true,true);
  f.capture.releaseVideoSequence(next,true);assert.equal(f.capture.hasPending('video'),true,'observed recording is never discarded');
});

test('cancellation while the baseline is being read never commits an orphan pending sequence',async()=>{
  const f=fixture(),token=new CancellationToken(1);let finish;
  f.repo.listMedia=()=>new Promise(resolve=>{finish=resolve;});
  const pending=f.capture.beginVideoSequence(token);token.cancel();finish({ok:true,data:[f.old]});
  await assert.rejects(pending,/取消/);assert.equal(f.capture.hasPending('video'),false);
  f.repo.listMedia=async()=>({ok:true,data:[f.old]});
  const id=await f.capture.beginVideoSequence(new CancellationToken(2));f.capture.releaseVideoSequence(id,true);
  assert.equal(f.capture.hasPending('video'),false);
  await f.capture.begin('video',new CancellationToken(2));assert.equal(f.capture.hasPending('video'),true);
});

async function releasedSequence(f,token=new CancellationToken(1)){
  const id=await f.capture.beginVideoSequence(token);f.advance(1);f.capture.releaseVideoSequence(id);
  return {id,token};
}

test('grounded reconciliation retires an empty released capture only after five stable seconds',async()=>{
  const f=fixture();const {token}=await releasedSequence(f);const started=f.now();const reports=[];
  const result=await f.capture.reconcileGroundedVideo(token,message=>reports.push(message));
  assert.deepEqual(result,[]);assert.ok(f.now()-started>=5000);
  assert.ok(f.queries()>=7);assert.equal(f.capture.hasPending('video'),false);
  assert.deepEqual(f.downloads,[]);assert.ok(reports.some(message=>/未生成|没有新增/.test(message)));
});

test('grounded reconciliation retrieves a new original even when no recording was observed',async()=>{
  const f=fixture();const {token}=await releasedSequence(f);
  f.setEntries([f.old,{path:'unobserved.MP4',kind:'video',size:200}]);
  const result=await f.capture.reconcileGroundedVideo(token,()=>{});
  assert.deepEqual(result.map(item=>item.path),['/download/unobserved.MP4']);
  assert.deepEqual(f.downloads,['unobserved.MP4']);assert.equal(f.capture.hasPending('video'),false);
});

test('grounded reconciliation retains a sealed first step and reuses completed downloads on retry',async()=>{
  const f=fixture(),token=new CancellationToken(1);const id=await f.capture.beginVideoSequence(token);
  f.seal();f.capture.continueVideoSequence(id,token);f.capture.releaseVideoSequence(id,true);
  f.setEntries([f.old,{path:'a.MP4',kind:'video',size:200},{path:'b.MP4',kind:'video',size:300}]);
  let fail=true;f.repo.downloadEntry=async entry=>{f.downloads.push(entry.path);
    return fail&&entry.path==='b.MP4'?{ok:false,error:{message:'interrupted'}}:{ok:true,data:{path:'/download/'+entry.path}};};
  await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/interrupted/);
  assert.equal(f.capture.hasPending('video'),true);fail=false;
  const result=await f.capture.reconcileGroundedVideo(token,()=>{});
  assert.deepEqual(result.map(item=>item.path),['/download/a.MP4','/download/b.MP4']);
  assert.equal(f.downloads.filter(path=>path==='a.MP4').length,1);
});

test('an empty directory cannot retire known cached originals after an interrupted partial return',async()=>{
  const f=fixture();const {token}=await releasedSequence(f);
  const originals=[f.old,{path:'a.MP4',kind:'video',size:200},{path:'b.MP4',kind:'video',size:300}];
  f.setEntries(originals);let fail=true;
  f.repo.downloadEntry=async entry=>{f.downloads.push(entry.path);
    return fail&&entry.path==='b.MP4'?{ok:false,error:{message:'interrupted'}}:{ok:true,data:{path:'/download/'+entry.path}};};
  await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/interrupted/);
  f.setEntries([f.old]);
  await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/原片|目录|重试/);
  assert.equal(f.capture.hasPending('video'),true,'a temporarily missing directory must retain downloaded originals');
  f.setEntries(originals);fail=false;
  const result=await f.capture.reconcileGroundedVideo(token,()=>{});
  assert.deepEqual(result.map(item=>item.path),['/download/a.MP4','/download/b.MP4']);
  assert.equal(f.downloads.filter(path=>path==='a.MP4').length,1);
  assert.equal(f.capture.hasPending('video'),false);
});

for(const missingPath of ['a.MP4','b.MP4']){
  test(`a shortened nonempty directory cannot lose previously observed ${missingPath} from a partial return`,async()=>{
    const f=fixture();const {token}=await releasedSequence(f);
    const a={path:'a.MP4',kind:'video',size:200},b={path:'b.MP4',kind:'video',size:300};
    f.setEntries([f.old,a,b]);let fail=true;
    f.repo.downloadEntry=async entry=>{f.downloads.push(entry.path);
      return fail&&entry.path==='b.MP4'?{ok:false,error:{message:'interrupted'}}:{ok:true,data:{path:'/download/'+entry.path}};};
    await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/interrupted/);
    f.setEntries([f.old,...[a,b].filter(entry=>entry.path!==missingPath)]);fail=false;
    await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/原片|目录|重试/);
    assert.equal(f.capture.hasPending('video'),true);
    f.setEntries([f.old,a,b]);
    const result=await f.capture.reconcileGroundedVideo(token,()=>{});
    assert.deepEqual(result.map(item=>item.path),['/download/a.MP4','/download/b.MP4']);
    assert.equal(f.downloads.filter(path=>path==='a.MP4').length,1,'the completed original stays cached');
    assert.equal(f.downloads.filter(path=>path==='b.MP4').length,2,'only the failed original is retried');
    assert.equal(f.capture.hasPending('video'),false);
  });
}

test('observed originals remain protected even when no download has completed',async()=>{
  const f=fixture();const {token}=await releasedSequence(f);
  const clip={path:'observed.MP4',kind:'video',size:200};let reads=0;
  f.repo.listMedia=async()=>++reads===1?{ok:true,data:[f.old,clip]}:{ok:false,error:{message:'directory failed'}};
  await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/尚未提供|directory failed/);
  assert.deepEqual(f.downloads,[]);f.repo.listMedia=async()=>({ok:true,data:[f.old]});
  await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/原片|目录|重试/);
  assert.equal(f.capture.hasPending('video'),true);
  f.repo.listMedia=async()=>({ok:true,data:[f.old,clip]});
  const result=await f.capture.reconcileGroundedVideo(token,()=>{});
  assert.deepEqual(result.map(item=>item.path),['/download/observed.MP4']);
});

test('a final directory cannot omit an observed original before returning and clearing the group',async()=>{
  const f=fixture();const {token}=await releasedSequence(f);
  const a={path:'a.MP4',kind:'video',size:200},b={path:'b.MP4',kind:'video',size:300};
  f.setEntries([f.old,a,b]);
  f.repo.downloadEntry=async entry=>{f.downloads.push(entry.path);if(entry.path==='b.MP4')f.setEntries([f.old,a]);
    return {ok:true,data:{path:'/download/'+entry.path}};};
  await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/原片|目录|重试/);
  assert.equal(f.capture.hasPending('video'),true);assert.deepEqual(f.downloads,['a.MP4','b.MP4']);
  f.setEntries([f.old,a,b]);
  const result=await f.capture.reconcileGroundedVideo(token,()=>{});
  assert.deepEqual(result.map(item=>item.path),['/download/a.MP4','/download/b.MP4']);
  assert.deepEqual(f.downloads,['a.MP4','b.MP4'],'restored directory returns both cached originals');
});

test('a growing original at the same path replaces its older cached version without becoming an extra clip',async()=>{
  const f=fixture();const {token}=await releasedSequence(f);
  const a={path:'a.MP4',kind:'video',size:200},b={path:'b.MP4',kind:'video',size:300};
  f.setEntries([f.old,a,b]);let fail=true;const versions=[];
  f.repo.downloadEntry=async entry=>{versions.push(`${entry.path}|${entry.size}`);
    return fail&&entry.path==='b.MP4'?{ok:false,error:{message:'interrupted'}}:
      {ok:true,data:{path:`/download/${entry.path}-${entry.size}`}};};
  await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/interrupted/);
  f.setEntries([f.old,{...a,size:400},b]);fail=false;
  const result=await f.capture.reconcileGroundedVideo(token,()=>{});
  assert.deepEqual(result.map(item=>item.path),['/download/a.MP4-400','/download/b.MP4-300']);
  assert.deepEqual(versions,['a.MP4|200','b.MP4|300','a.MP4|400','b.MP4|300']);
  assert.equal(f.capture.hasPending('video'),false);
});

test('grounded reconciliation includes late files and waits for growing originals to stabilize',async()=>{
  const f=fixture();const {token}=await releasedSequence(f);const started=f.now();let reads=0;
  f.repo.listMedia=async()=>{const age=f.now()-started;reads++;
    return {ok:true,data:age<4000?[f.old]:[f.old,{path:'late.MP4',kind:'video',size:age<6000?100:200}]};};
  f.repo.downloadEntry=async entry=>{assert.equal(entry.size,200);assert.ok(f.now()-started>=11000);
    f.downloads.push(entry.path);return {ok:true,data:{path:'/download/'+entry.path}};};
  const result=await f.capture.reconcileGroundedVideo(token,()=>{});
  assert.deepEqual(result.map(item=>item.path),['/download/late.MP4']);assert.ok(reads>=12);
});

test('grounded reconciliation refuses active deferred captures and preserves ordinary pending guards',async()=>{
  const f=fixture(),token=new CancellationToken(1);await f.capture.beginVideoSequence(token);
  await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/组合|拍摄|结束/);
  await assert.rejects(f.capture.begin('video',token),/上一份/);assert.equal(f.queries(),1);
  assert.equal(f.capture.hasPending('video'),true);
});

test('grounded reconciliation preserves the ticket for unsafe, stale or pre-request evidence',async()=>{
  for(const changed of [
    {flight:{observedAtMs:2000,airborne:true,motorsOn:true}},
    {flightAgeMs:1001},{cameraAgeMs:1001},{taskAgeMs:1001},
    {flight:{observedAtMs:999,airborne:false,motorsOn:false}},
    {camera:{observedAtMs:999,recordingCandidate:false}},
    {task:{observedAtMs:999,phaseRaw:0,modeRaw:0}},
    {task:{observedAtMs:2000,phaseRaw:5,modeRaw:13}},
    {camera:{observedAtMs:2000,recordingCandidate:true}}
  ]){
    const f=fixture();const {token}=await releasedSequence(f);f.setTelemetry(changed);
    await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/落地|状态|新鲜|空闲/);
    assert.equal(f.capture.hasPending('video'),true);assert.equal(f.queries(),1);
  }
});

test('grounded reconciliation never clears after cancellation, a changed session or lost link',async()=>{
  for(const changed of ['cancel','session','link','airborne','recording','stale']){
    const f=fixture();const {token}=await releasedSequence(f);
    f.setWaitHook(()=>{if(changed==='cancel')token.cancel();else if(changed==='session')f.setSession(11);
      else if(changed==='link')f.setFresh(false);else if(changed==='recording')f.observe(true,true);
      else if(changed==='stale')f.setTelemetry({flightAgeMs:1001});
      else f.setTelemetry({flight:{observedAtMs:f.now(),airborne:true,motorsOn:true}});});
    await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/取消|会话|落地|状态|新鲜|空闲/);
    assert.equal(f.capture.hasPending('video'),true);assert.deepEqual(f.downloads,[]);
  }
});

test('grounded reconciliation checks context after directory and download awaits without losing originals',async()=>{
  for(const moment of ['list','download']){
    const f=fixture();const {token}=await releasedSequence(f);
    const clip={path:'a.MP4',kind:'video',size:200};
    if(moment==='list')f.repo.listMedia=async()=>{token.cancel();return {ok:true,data:[f.old]};};
    else {f.setEntries([f.old,clip]);f.repo.downloadEntry=async entry=>{
      f.setTelemetry({flightAgeMs:1001});return {ok:true,data:{path:'/download/'+entry.path}};};}
    await assert.rejects(f.capture.reconcileGroundedVideo(token,()=>{}),/取消|状态|新鲜|落地/);
    assert.equal(f.capture.hasPending('video'),true);
  }
});

test('grounded reconciliation retains the ticket on directory failure and locks a competing baseline',async()=>{
  const f=fixture();const {token}=await releasedSequence(f);let finish;
  f.repo.listMedia=()=>new Promise(resolve=>{finish=resolve;});
  const pending=f.capture.reconcileGroundedVideo(token,()=>{});
  await assert.rejects(f.capture.beginVideoSequence(token),/处理|稍后/);
  finish({ok:false,error:{message:'directory failed'}});
  await assert.rejects(pending,/directory failed/);assert.equal(f.capture.hasPending('video'),true);
});

test('an empty reconciled capture allows a new baseline that returns only the new shot',async()=>{
  const f=fixture();const {token}=await releasedSequence(f);
  await f.capture.reconcileGroundedVideo(token,()=>{});
  const unrelated={path:'between.MP4',kind:'video',size:200};f.setEntries([f.old,unrelated]);
  const next=await f.capture.beginVideoSequence(token);f.setEntries([f.old,unrelated,{path:'new.MP4',kind:'video',size:300}]);
  f.seal();f.capture.finishVideoSequence(next,token);
  const result=await f.capture.retrieveAll('video',token,()=>{});
  assert.deepEqual(result.map(item=>item.path),['/download/new.MP4']);assert.deepEqual(f.downloads,['new.MP4']);
});
