const {test}=require('node:test');
const assert=require('node:assert/strict');
const {NativeTaskStopEvidence}=require('../entry/src/main/ets/core/domain/NativeTaskStopEvidence.ets');

const raw0bA='00000000000019000b00';
const raw0bB='00000000000014000b00';
const idle='00000000000000000000';
function withNow(body,now=10000){
  const original=Date.now;Date.now=()=>now;
  try{return body(at=>{now=at;});}finally{Date.now=original;}
}
function task(payloadHex,observedAtMs){
  return {observedAtMs,phaseRaw:parseInt(payloadHex.slice(0,2),16),
    modeRaw:parseInt(payloadHex.slice(2,4),16),payloadHex};
}
function exception(observedAtMs,payloadHex=raw0bA,sequence=1){
  return {observedAtMs,codeRaw:parseInt(payloadHex.slice(16,18),16),payloadHex,sequence};
}
function running(kind='dolly',start=1000){
  const evidence=new NativeTaskStopEvidence();evidence.begin(kind,start);
  evidence.observeTask(task('050d000100',1100));return evidence;
}
function ended(evidence,at=2000,hex='0400000100'){
  evidence.observeTask(task(hex,at));return evidence;
}
function nav(observedAtMs,overrides={}){
  return {observedAtMs,modeRaw:8,navigationExecuting:false,goHomeExecuting:false,goHomeStageRaw:0,
    multiQuickShotEnabled:false,payloadHex:'',...overrides};
}
function supportedRunning(kind='dolly',start=1000){
  const evidence=new NativeTaskStopEvidence();evidence.begin(kind,start);
  evidence.observeTask(task(kind==='circle'?'0505000100':'050d000100',start+100));return evidence;
}

test('both observed 0A/39 payloads correlate before or after Dolly completion without claiming confirmation',()=>withNow(()=>{
  for(const payload of [raw0bA,raw0bB])for(const at of [1952,2100,2151])for(const first of [true,false]){
    const evidence=running();
    if(first)evidence.observeException(exception(at,payload));
    ended(evidence);
    if(!first)evidence.observeException(exception(at,payload));
    const report=evidence.snapshot();
    assert.ok(report,'observed execution and a terminal report produce a bounded stop report');
    assert.equal(report.classification,'unconfirmed');
    assert.equal(report.message,'任务状态已变化，原因未确认');
    assert.doesNotMatch(report.message,/障碍|避障|中止|已停止/,'0B also appears during normal finishing');
    assert.equal(report.startedAtMs,1000);assert.equal(report.terminalAtMs,2000);
    assert.equal(report.settleUntilMs,2500);assert.equal(report.exceptionAtMs,at);
    assert.equal(report.codeRaw,0x0b);assert.equal(report.payloadHex,payload);
    assert.equal(report.appStopRequested,false);
    assert.equal(report.reasonKnown,false,'0B without the official navigation gate remains unconfirmed');
    assert.equal(report.diagnosticCode,undefined);
  }
}));

test('same-clock progress or idle reset cannot replace any observed nonzero exception edge',()=>withNow(()=>{
  const nonzeroSamples=[raw0bA,raw0bB,'00000000000019000200','00000000000019003100','00000000000019009100'];
  for(const payload of nonzeroSamples)for(const first of [true,false]){
    const evidence=running();
    if(first){evidence.observeException(exception(2000,payload));evidence.observeException(exception(2000,idle,2));}
    ended(evidence);
    if(!first){evidence.observeException(exception(2000,payload));evidence.observeException(exception(2000,idle,2));}
    assert.equal(evidence.snapshot().classification,'unconfirmed');
    assert.equal(evidence.snapshot().codeRaw,parseInt(payload.slice(16,18),16));
    assert.equal(evidence.snapshot().payloadHex,payload);
  }
}));

test('execution resuming after a transient terminal clears the stopped notice and its exception episode',()=>withNow(()=>{
  for(const resumedAt of [2000,2050,2300]){
    const evidence=running();evidence.observeException(exception(1952));ended(evidence);
    assert.equal(evidence.snapshot().classification,'unconfirmed');
    assert.equal(evidence.snapshot().payloadHex,raw0bA);
    evidence.observeTask(task('050d000100',resumedAt));
    assert.equal(evidence.snapshot(),undefined,'including same-clock terminal then execution arrival order');
    ended(evidence,resumedAt+100);
    const report=evidence.snapshot();
    assert.equal(report.classification,'unconfirmed','normal completion must not reuse the earlier 0B');
    assert.equal(report.terminalAtMs,resumedAt+100);assert.equal(report.settleUntilMs,resumedAt+600);
    assert.equal(report.codeRaw,undefined);assert.equal(report.payloadHex,undefined);
  }
}));

test('a new exception may correlate to a later completion after execution has resumed',()=>withNow(()=>{
  const evidence=running();evidence.observeException(exception(1952));ended(evidence);
  evidence.observeTask(task('050d000100',2050));assert.equal(evidence.snapshot(),undefined);
  evidence.observeException(exception(2152,raw0bB,2));ended(evidence,2200);
  const report=evidence.snapshot();assert.equal(report.classification,'unconfirmed');
  assert.equal(report.terminalAtMs,2200);assert.equal(report.exceptionAtMs,2152);assert.equal(report.payloadHex,raw0bB);
  evidence.observeTask(task('0000000102',2400));
  assert.equal(evidence.snapshot().terminalAtMs,2200,'repeated terminal reports still cannot slide the new anchor');
}));

test('retransmission of an earlier exception after resumed execution cannot become a new ending cause',()=>withNow(()=>{
  const evidence=running();evidence.observeException(exception(1952,raw0bA,1));ended(evidence);
  assert.equal(evidence.snapshot().classification,'unconfirmed');
  assert.equal(evidence.snapshot().exceptionAtMs,1952);
  evidence.observeTask(task('050d000100',2050));assert.equal(evidence.snapshot(),undefined);
  evidence.observeException(exception(2100,raw0bA,1));ended(evidence,2200);
  assert.equal(evidence.snapshot().classification,'unconfirmed','same-sequence replay must remain excluded across resume');
  assert.equal(evidence.snapshot().payloadHex,undefined);
  evidence.observeException(exception(2251,raw0bA,2));
  assert.equal(evidence.snapshot().classification,'unconfirmed','a genuinely new sequence may still correlate');
  assert.equal(evidence.snapshot().exceptionAtMs,2251);
  assert.equal(evidence.snapshot().payloadHex,raw0bA);
}));

test('old or malformed execution pushes cannot clear an existing stopped report',()=>withNow(()=>{
  for(const invalid of [task('050d000100',1999),task('050d000100',999),task('050d000100',10001),
    {...task('050d000100',2000),phaseRaw:4},{...task('050d000100',2100),modeRaw:9},
    {...task('050d000100',2100),observedAtMs:NaN},task('050d00010000',2100)]){
    const evidence=running();evidence.observeException(exception(1952));ended(evidence);
    evidence.observeTask(invalid);
    const report=evidence.snapshot();assert.equal(report.classification,'unconfirmed');
    assert.equal(report.terminalAtMs,2000);assert.equal(report.payloadHex,raw0bA);
  }
}));

test('progress bytes and the trailing 0/1 state are not obstacle reason fields',()=>withNow(()=>{
  for(const progress of ['0000','1900','1400','0b00','ffff'])for(const status of ['00','01']){
    const evidence=ended(running());
    const payload='000000000000'+progress+'0b'+status;
    evidence.observeException(exception(2100,payload));
    assert.equal(evidence.snapshot().classification,'unconfirmed');
    assert.equal(evidence.snapshot().codeRaw,0x0b);assert.equal(evidence.snapshot().payloadHex,payload);
    const nonzeroProgress=ended(running());
    nonzeroProgress.observeException(exception(2100,'000000000000'+progress+'00'+status));
    assert.equal(nonzeroProgress.snapshot().classification,'unconfirmed');
    assert.equal(nonzeroProgress.snapshot().codeRaw,0);
  }
}));

test('all currently unmapped codes retain raw evidence without inventing an obstacle or stopped reason',()=>withNow(()=>{
  for(let code=0;code<=255;code++){
    const payload='0000000000001900'+code.toString(16).padStart(2,'0')+'00';
    const evidence=ended(running());evidence.observeException(exception(2100,payload));
    const report=evidence.snapshot();assert.equal(report.classification,'unconfirmed');
    assert.equal(report.message,'任务状态已变化，原因未确认');assert.equal(report.codeRaw,code);
    assert.doesNotMatch(report.message,/障碍|避障|中止|已停止/);
    assert.equal(report.payloadHex,payload);
  }
}));

test('every known terminal shape uses the first terminal anchor and never slides its 500ms window',()=>withNow(()=>{
  for(const hex of ['0000000100','0000000101','0000000102','0300000100','0400000100']){
    const evidence=ended(running(),2000,hex);
    evidence.observeTask(task('0000000102',2400));evidence.observeTask(task('0400000100',2800));
    evidence.observeException(exception(2600));
    const report=evidence.snapshot();assert.equal(report.terminalAtMs,2000);assert.equal(report.settleUntilMs,2500);
    assert.equal(report.classification,'unconfirmed');
    assert.equal(report.payloadHex,undefined,'a later idle cannot pull an out-of-window raw report into scope');
    evidence.observeException(exception(2100,raw0bB,2));
    assert.equal(evidence.snapshot().classification,'unconfirmed');
    assert.equal(evidence.snapshot().payloadHex,raw0bB);assert.equal(evidence.snapshot().exceptionAtMs,2100);
  }
}));

test('exact 500ms boundaries correlate while 501ms, pre-start and pre-execution events do not',()=>withNow(()=>{
  for(const at of [1500,2500]){
    const evidence=running();evidence.observeException(exception(at));ended(evidence);
    assert.equal(evidence.snapshot().classification,'unconfirmed');
    assert.equal(evidence.snapshot().codeRaw,0x0b);assert.equal(evidence.snapshot().exceptionAtMs,at);
  }
  for(const at of [999,1499,2501,10000]){
    const evidence=running();evidence.observeException(exception(at));ended(evidence);
    assert.equal(evidence.snapshot().classification,'unconfirmed');
    assert.equal(evidence.snapshot().payloadHex,undefined,'the nonzero raw report is outside this episode window');
  }
  const beforeExecution=running();beforeExecution.observeException(exception(1050));ended(beforeExecution,1200);
  assert.equal(beforeExecution.snapshot().classification,'unconfirmed');
  assert.equal(beforeExecution.snapshot().payloadHex,undefined);
}));

test('a single exception, an unexecuted task or another task kind cannot claim stopped Dolly',()=>withNow(()=>{
  const noTerminal=running();noTerminal.observeException(exception(2000));assert.equal(noTerminal.snapshot(),undefined);
  for(const kind of ['dolly','circle','follow','']){
    const evidence=new NativeTaskStopEvidence();evidence.begin(kind,1000);
    ended(evidence);evidence.observeException(exception(2100));
    assert.equal(evidence.snapshot(),undefined);
    evidence.observeTask(task('050d000100',2200));
    assert.equal(evidence.snapshot(),undefined,'new execution cannot retroactively turn a prior idle into completion');
    if(kind!=='dolly'){ended(evidence,2300);assert.equal(evidence.snapshot(),undefined);}
  }
}));

test('new starts and resets discard earlier execution, terminal, exception and App-stop evidence',()=>withNow(()=>{
  for(const reset of [false,true]){
    const evidence=ended(running());evidence.observeException(exception(2100));
    evidence.markAppStopRequested(1900);assert.equal(evidence.snapshot().appStopRequested,true);
    if(reset){evidence.reset();assert.equal(evidence.snapshot(),undefined);}
    evidence.begin('dolly',3000);evidence.observeTask(task('050d000100',3100));ended(evidence,3200);
    assert.equal(evidence.snapshot().classification,'unconfirmed');assert.equal(evidence.snapshot().appStopRequested,false);
    assert.equal(evidence.snapshot().payloadHex,undefined);
    evidence.observeException(exception(2100));assert.equal(evidence.snapshot().payloadHex,undefined);
    evidence.observeException(exception(3300,raw0bA,3));assert.equal(evidence.snapshot().classification,'unconfirmed');
    assert.equal(evidence.snapshot().payloadHex,raw0bA);assert.equal(evidence.snapshot().exceptionAtMs,3300);
  }
}));

test('an old execution or a completion timestamp before execution cannot authorize this task report',()=>withNow(()=>{
  const oldExecution=new NativeTaskStopEvidence();oldExecution.begin('dolly',3000);
  oldExecution.observeTask(task('050d000100',2999));ended(oldExecution,3200);
  oldExecution.observeException(exception(3300));assert.equal(oldExecution.snapshot(),undefined);
  const reversed=running();ended(reversed,1050);reversed.observeException(exception(1200));
  assert.equal(reversed.snapshot(),undefined);
  ended(reversed,1300);assert.equal(reversed.snapshot().classification,'unconfirmed');assert.equal(reversed.snapshot().exceptionAtMs,1200);
}));

test('a new start may reuse the same DUML sequence without retaining the old event time',()=>withNow(()=>{
  const evidence=ended(running());evidence.observeException(exception(2100,raw0bA,8));
  assert.equal(evidence.snapshot().exceptionAtMs,2100);
  evidence.begin('dolly',3000);evidence.observeTask(task('050d000100',3100));ended(evidence,3200);
  evidence.observeException(exception(3300,raw0bA,8));
  assert.equal(evidence.snapshot().classification,'unconfirmed');assert.equal(evidence.snapshot().exceptionAtMs,3300);
}));

test('only an App stop request between this start and first completion is attached as an explicit request',()=>withNow(()=>{
  for(const first of [true,false]){
    const evidence=running();evidence.observeException(exception(2100));
    if(first)evidence.markAppStopRequested(1900);ended(evidence);
    if(!first)evidence.markAppStopRequested(1900);
    const report=evidence.snapshot();assert.equal(report.classification,'unconfirmed');
    assert.equal(report.appStopRequested,true);assert.equal(report.message,'任务状态已变化，原因未确认；App 已请求停止');
    assert.equal(report.payloadHex,raw0bA,'retain the accompanying report without asserting its cause');
  }
  for(const at of [999,2001,NaN,Infinity,-1]){
    const evidence=ended(running());evidence.observeException(exception(2100));evidence.markAppStopRequested(at);
    assert.equal(evidence.snapshot().classification,'unconfirmed');assert.equal(evidence.snapshot().appStopRequested,false);
  }
}));

test('malformed timestamps, inconsistent bytes, bad shapes and non-terminal lookalikes are rejected',()=>withNow(()=>{
  for(const at of [NaN,Infinity,-1,undefined,'2100',2100.5]){
    const evidence=running();evidence.observeTask({...task('0400000100',2000),observedAtMs:at});
    assert.equal(evidence.snapshot(),undefined);
    ended(evidence);evidence.observeException({...exception(2100),observedAtMs:at});
    assert.equal(evidence.snapshot().classification,'unconfirmed');
    assert.equal(evidence.snapshot().payloadHex,undefined);
  }
  for(const invalid of [
    {...exception(2100),codeRaw:0},{...exception(2100),codeRaw:NaN},
    {...exception(2100),payloadHex:raw0bA.toUpperCase()},
    {...exception(2100),payloadHex:'01'+raw0bA.slice(2)},
    {...exception(2100),payloadHex:raw0bA.slice(0,-2)+'02'},
    {...exception(2100),payloadHex:raw0bA+'00'},
    {...exception(2100),payloadHex:raw0bA.slice(2)},
    {...exception(2100),sequence:-1},{...exception(2100),sequence:65536},{...exception(2100),sequence:NaN}]){
    const evidence=ended(running());evidence.observeException(invalid);
    assert.equal(evidence.snapshot().classification,'unconfirmed');
    assert.equal(evidence.snapshot().payloadHex,undefined);
  }
  for(const invalid of [
    {...task('0400000100',2000),phaseRaw:0},{...task('0400000100',2000),modeRaw:9},
    task('0400000101',2000),task('040000010000',2000)]){
    const evidence=running();evidence.observeTask(invalid);assert.equal(evidence.snapshot(),undefined);
  }
  for(const at of [NaN,Infinity,-1,undefined,'1000',1000.5]){
    const evidence=new NativeTaskStopEvidence();evidence.begin('dolly',at);
    evidence.observeTask(task('050d000100',1100));ended(evidence);evidence.observeException(exception(2100));
    assert.equal(evidence.snapshot(),undefined);
  }
}));

test('future observations cannot create execution, terminal or exception evidence',()=>withNow(setNow=>{
  setNow(2000);
  const futureStart=running('dolly',2001);ended(futureStart,2002);assert.equal(futureStart.snapshot(),undefined);
  const futureExecution=new NativeTaskStopEvidence();futureExecution.begin('dolly',1000);
  futureExecution.observeTask(task('050d000100',2001));ended(futureExecution,2000);
  assert.equal(futureExecution.snapshot(),undefined);
  const futureTerminal=running();ended(futureTerminal,2001);assert.equal(futureTerminal.snapshot(),undefined);
  const futureException=ended(running());futureException.observeException(exception(2001));
  assert.equal(futureException.snapshot().classification,'unconfirmed');
  assert.equal(futureException.snapshot().payloadHex,undefined);
  futureException.markAppStopRequested(2001);assert.equal(futureException.snapshot().appStopRequested,false);
  assert.equal(futureException.snapshot(NaN),undefined);assert.equal(futureException.snapshot(1999),undefined);
}));

test('retransmitting the same sequence and payload cannot move its first observation into the cause window',()=>withNow(()=>{
  const evidence=running();evidence.observeException(exception(1400,raw0bA,5));ended(evidence);
  evidence.observeException(exception(2100,raw0bA,5));
  assert.equal(evidence.snapshot().classification,'unconfirmed');
  assert.equal(evidence.snapshot().payloadHex,undefined,'a replay cannot supply fresh raw evidence');
  evidence.observeException(exception(2151,raw0bB,6));
  assert.equal(evidence.snapshot().classification,'unconfirmed');assert.equal(evidence.snapshot().exceptionAtMs,2151);
  assert.equal(evidence.snapshot().payloadHex,raw0bB);
}));

test('observed inputs and returned snapshots cannot mutate saved task evidence',()=>withNow(()=>{
  const evidence=running(),terminal=task('0400000100',2000),event=exception(2100);
  evidence.observeTask(terminal);evidence.observeException(event);
  terminal.observedAtMs=3000;event.payloadHex=idle;event.codeRaw=0;
  const report=evidence.snapshot();assert.equal(report.payloadHex,raw0bA);
  report.classification='obstacle';report.payloadHex=idle;report.terminalAtMs=3000;
  assert.equal(evidence.snapshot().classification,'unconfirmed');assert.equal(evidence.snapshot().terminalAtMs,2000);
  assert.equal(evidence.snapshot().payloadHex,raw0bA);
}));

test('formal obstacle reason needs the current Dolly or Circle execution and the preceding Mode 8 gate',()=>withNow(()=>{
  for(const kind of ['dolly','circle'])for(const payload of [raw0bA,raw0bB])for(const at of [1952,2100,2151]){
    const evidence=supportedRunning(kind);evidence.observeNavigation(nav(1800));
    if(at<2000)evidence.observeException(exception(at,payload));
    ended(evidence);
    if(at>=2000)evidence.observeException(exception(at,payload));
    const report=evidence.snapshot();assert.ok(report);
    assert.equal(report.classification,'obstacle');assert.equal(report.reasonKnown,true);
    assert.equal(report.diagnosticCode,800013);assert.equal(report.message,'检测到障碍物，已触发避障');
    assert.equal(report.codeRaw,0x0b);assert.equal(report.payloadHex,payload);assert.equal(report.exceptionAtMs,at);
    assert.equal(report.reasonNavAtMs,1800);assert.equal(report.reasonNavModeRaw,8);
    assert.equal(report.reasonMultiQuickShotEnabled,false);
  }
}));

test('MultiQuickShot is the complete alternative navigation gate independent of other execution flags',()=>withNow(()=>{
  for(const modeRaw of [0,7,9,15]){
    const evidence=supportedRunning();
    evidence.observeNavigation(nav(1800,{modeRaw,multiQuickShotEnabled:true,navigationExecuting:false,goHomeExecuting:false}));
    evidence.observeException(exception(1952));ended(evidence);
    const report=evidence.snapshot();assert.equal(report.classification,'obstacle');assert.equal(report.reasonKnown,true);
    assert.equal(report.reasonNavModeRaw,modeRaw);assert.equal(report.reasonMultiQuickShotEnabled,true);
  }
}));

test('other navigation modes cannot turn 0B into a known reason without MultiQuickShot',()=>withNow(()=>{
  for(const modeRaw of [0,1,6,7,9,15,26]){
    const evidence=supportedRunning();evidence.observeNavigation(nav(1800,{modeRaw}));
    evidence.observeException(exception(1952));ended(evidence);
    const report=evidence.snapshot();assert.equal(report.classification,'unconfirmed');assert.equal(report.reasonKnown,false);
    assert.equal(report.diagnosticCode,undefined);assert.equal(report.codeRaw,0x0b);
    assert.equal(report.reasonNavModeRaw,modeRaw);
  }
}));

test('navigation freshness is measured at exception arrival and rejects old, future or newer-than-exception inputs',()=>withNow(()=>{
  for(const at of [1100,2100]){
    const evidence=supportedRunning();evidence.observeNavigation(nav(at));ended(evidence);
    evidence.observeException(exception(2100));assert.equal(evidence.snapshot().classification,'obstacle');
  }
  for(const at of [999,1099,2101,10001,NaN,Infinity,-1]){
    const evidence=supportedRunning();evidence.observeNavigation(nav(at));ended(evidence);
    evidence.observeException(exception(2100));
    assert.equal(evidence.snapshot().classification,'unconfirmed');assert.equal(evidence.snapshot().reasonKnown,false);
  }
}));

test('navigation arriving after 0B cannot backfill it, even at the same timestamp or on retransmission',()=>withNow(()=>{
  const evidence=supportedRunning();evidence.observeException(exception(1952,raw0bA,1));
  evidence.observeNavigation(nav(1952));ended(evidence);
  assert.equal(evidence.snapshot().classification,'unconfirmed');assert.equal(evidence.snapshot().reasonKnown,false);
  evidence.observeException(exception(2100,raw0bA,1));
  assert.equal(evidence.snapshot().classification,'unconfirmed','same identity keeps its original missing gate');
  evidence.observeException(exception(2151,raw0bB,2));
  assert.equal(evidence.snapshot().classification,'obstacle');assert.equal(evidence.snapshot().exceptionAtMs,2151);
}));

test('same-clock navigation, execution and exception inputs follow their actual arrival order',()=>withNow(()=>{
  for(const order of ['nav-exec-reason','exec-reason-nav','nav-reason-exec']){
    const evidence=new NativeTaskStopEvidence();evidence.begin('dolly',1000);
    for(const step of order.split('-')){
      if(step==='nav')evidence.observeNavigation(nav(2000));
      if(step==='exec')evidence.observeTask(task('050d000100',2000));
      if(step==='reason')evidence.observeException(exception(2000,raw0bA,1));
    }
    evidence.observeException(exception(2000,idle,2));ended(evidence);
    const report=evidence.snapshot();assert.equal(report.classification,order==='nav-exec-reason'?'obstacle':'unconfirmed');
    assert.equal(report.reasonKnown,order==='nav-exec-reason');assert.equal(report.payloadHex,raw0bA);
  }
}));

test('latest preceding navigation wins and old navigation cannot overwrite a newer gate',()=>withNow(()=>{
  for(const sameClock of [false,true]){
    const evidence=supportedRunning();evidence.observeNavigation(nav(1800));
    evidence.observeNavigation(nav(sameClock?1800:1900,{modeRaw:9}));
    if(!sameClock)evidence.observeNavigation(nav(1850));
    evidence.observeException(exception(1952));ended(evidence);
    assert.equal(evidence.snapshot().classification,'unconfirmed');assert.equal(evidence.snapshot().reasonNavModeRaw,9);
  }
  const reverse=supportedRunning();reverse.observeNavigation(nav(1800,{modeRaw:9}));
  reverse.observeNavigation(nav(1800));reverse.observeException(exception(1952));ended(reverse);
  assert.equal(reverse.snapshot().classification,'obstacle');
}));

test('only QM_OBSTACLE_AVOID maps to diagnostic 800013 even with a valid navigation gate',()=>withNow(()=>{
  for(let code=0;code<=255;code++){
    const evidence=supportedRunning();evidence.observeNavigation(nav(1800));
    const payload='0000000000001900'+code.toString(16).padStart(2,'0')+'00';
    evidence.observeException(exception(1952,payload));ended(evidence);
    const report=evidence.snapshot(),known=code===0x0b;
    assert.equal(report.classification,known?'obstacle':'unconfirmed');assert.equal(report.reasonKnown,known);
    assert.equal(report.diagnosticCode,known?800013:undefined);
    assert.equal(report.codeRaw,code);assert.equal(report.payloadHex,payload);
    if(!known)assert.doesNotMatch(report.message,/障碍|避障|中止/);
  }
}));

test('App stop intent suppresses obstacle cause assignment while keeping its navigation evidence',()=>withNow(()=>{
  const evidence=supportedRunning();evidence.observeNavigation(nav(1800));evidence.observeException(exception(1952));
  evidence.markAppStopRequested(1900);ended(evidence);
  const report=evidence.snapshot();assert.equal(report.classification,'unconfirmed');assert.equal(report.reasonKnown,false);
  assert.equal(report.diagnosticCode,undefined);assert.equal(report.reasonNavModeRaw,8);assert.equal(report.codeRaw,0x0b);
  assert.equal(report.message,'任务状态已变化，原因未确认；App 已请求停止');
}));

test('new starts and reset clear the navigation gate as well as formal cause metadata',()=>withNow(()=>{
  for(const reset of [false,true]){
    const evidence=supportedRunning();evidence.observeNavigation(nav(1800));evidence.observeException(exception(1952));ended(evidence);
    assert.equal(evidence.snapshot().classification,'obstacle');
    if(reset)evidence.reset();evidence.begin('circle',3000);evidence.observeTask(task('0505000100',3100));
    evidence.observeException(exception(3152));ended(evidence,3200);
    assert.equal(evidence.snapshot().classification,'unconfirmed');assert.equal(evidence.snapshot().reasonNavAtMs,undefined);
    evidence.observeNavigation(nav(3250));evidence.observeException(exception(3300,raw0bB,2));
    assert.equal(evidence.snapshot().classification,'obstacle');assert.equal(evidence.snapshot().reasonNavAtMs,3250);
  }
}));

test('resume discards navigation and linked reasons but preserves replay identities',()=>withNow(()=>{
  const evidence=supportedRunning();evidence.observeNavigation(nav(1800));evidence.observeException(exception(1952,raw0bA,1));ended(evidence);
  assert.equal(evidence.snapshot().classification,'obstacle');evidence.observeTask(task('050d000100',2050));
  evidence.observeNavigation(nav(1900));evidence.observeException(exception(2100,raw0bA,1));
  evidence.observeException(exception(2152,raw0bB,2));ended(evidence,2200);
  assert.equal(evidence.snapshot().classification,'unconfirmed');assert.equal(evidence.snapshot().reasonNavAtMs,undefined);
  evidence.observeNavigation(nav(2250));assert.equal(evidence.snapshot().classification,'unconfirmed');
  evidence.observeException(exception(2251,raw0bA,3));
  assert.equal(evidence.snapshot().classification,'obstacle');assert.equal(evidence.snapshot().exceptionAtMs,2251);
}));

test('a gated 0B is retained over unrelated nonzero and zero reports while raw caches remain bounded',()=>withNow(()=>{
  const evidence=supportedRunning();evidence.observeException(exception(1900,'00000000000019000200',1));
  evidence.observeNavigation(nav(1951));evidence.observeException(exception(1952,raw0bA,2));ended(evidence);
  for(let index=0;index<100;index++)evidence.observeException(exception(2100+index,'00000000000019000100',index+3));
  evidence.observeException(exception(2200,idle,104));
  const report=evidence.snapshot();assert.equal(report.classification,'obstacle');assert.equal(report.reasonKnown,true);
  assert.equal(report.codeRaw,0x0b);assert.equal(report.payloadHex,raw0bA);assert.equal(report.reasonNavAtMs,1951);
}));

test('navigation and report copies cannot rewrite an already captured formal gate',()=>withNow(()=>{
  const evidence=supportedRunning(),navigation=nav(1800);evidence.observeNavigation(navigation);
  navigation.modeRaw=9;navigation.multiQuickShotEnabled=true;navigation.observedAtMs=100;
  evidence.observeException(exception(1952));ended(evidence);
  const report=evidence.snapshot();assert.equal(report.classification,'obstacle');assert.equal(report.reasonNavAtMs,1800);
  assert.equal(report.reasonNavModeRaw,8);assert.equal(report.reasonMultiQuickShotEnabled,false);
  report.reasonKnown=false;report.diagnosticCode=0;report.reasonNavModeRaw=9;
  assert.equal(evidence.snapshot().reasonKnown,true);assert.equal(evidence.snapshot().diagnosticCode,800013);
  assert.equal(evidence.snapshot().reasonNavModeRaw,8);
}));

test('bounded repeated, zero and unknown noise does not overwrite a current nonzero exception',()=>withNow(()=>{
  const evidence=ended(running());evidence.observeException(exception(2100));
  for(let index=0;index<1000;index++){
    const code=index%256,payload='0000000000000000'+code.toString(16).padStart(2,'0')+'00';
    evidence.observeException(exception(2100+index%150,payload,index+2));
  }
  assert.equal(evidence.snapshot().classification,'unconfirmed');
  assert.equal(evidence.snapshot().payloadHex,raw0bA,'zero/noisy latest state must not erase the retained nonzero edge');
  const arrays=Object.values(evidence).filter(value=>Array.isArray(value));
  assert.ok(arrays.length>0,'the collector retains a bounded set of accepted exception events');
  for(const events of arrays){
    assert.ok(events.length<=32,'any independent replay-identity ring stays bounded at 32');
    assert.ok(events.filter(value=>typeof value==='object').length<=8,'retain at most eight raw exception events');
  }
}));
