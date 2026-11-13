const {test}=require('node:test');
const assert=require('node:assert/strict');
const {SEARCH_PICTURE_WAIT_MS,SEARCH_PICTURE_STABLE_MS,SubjectSearchFrameUnavailable,
  searchPictureNeedsRecovery,SubjectSearchPictureStability}=require('../entry/src/main/ets/core/domain/SubjectSearchPicture.ets');

const frame=(count=1,age=0,epoch=1,extra={})=>({state:'live',stats:{running:true,
  waitingForKey:false,recoveryPaused:false,renderedFrames:count,lastRenderedAgeMs:age,decoderEpoch:epoch,...extra}});

test('picture recovery budgets and typed recoverable errors are explicit',()=>{
  assert.equal(SEARCH_PICTURE_WAIT_MS,15000);
  assert.equal(SEARCH_PICTURE_STABLE_MS,500);
  for(const reason of ['readback_timeout','decoder_changed','decoder_unready']){
    const error=new SubjectSearchFrameUnavailable(reason,'恢复画面');
    assert.ok(error instanceof Error);assert.equal(error.reason,reason);assert.equal(error.message,'恢复画面');
  }
});

test('availability rejects stale and unavailable output while retaining legacy lightweight fixtures',()=>{
  assert.equal(searchPictureNeedsRecovery(frame()),false);
  assert.equal(searchPictureNeedsRecovery(frame(1,500)),false);
  assert.equal(searchPictureNeedsRecovery({state:'live',stats:{decoderEpoch:1,waitingForKey:false}}),false);
  assert.equal(searchPictureNeedsRecovery({state:'live'}),false);
  assert.equal(searchPictureNeedsRecovery({state:'stale'}),true);
  for(const age of [-1,501,NaN,Infinity,-Infinity])assert.equal(searchPictureNeedsRecovery(frame(1,age)),true);
  for(const patch of [{running:false},{waitingForKey:true},{recoveryPaused:true}])
    assert.equal(searchPictureNeedsRecovery(frame(1,0,1,patch)),true);
  for(const state of ['stopped','stale','error','waiting_key'])
    assert.equal(searchPictureNeedsRecovery({...frame(),state}),true);
});

test('recovery requires 500 ms of observed real output progress in one decoder epoch',()=>{
  const stable=new SubjectSearchPictureStability();
  assert.equal(stable.observe(frame(1),1000),false);
  for(let step=1;step<5;step++)assert.equal(stable.observe(frame(step+1),1000+step*100),false);
  assert.equal(stable.observe(frame(6),1500),true);
  stable.reset();assert.equal(stable.observe(frame(7),1600),false);
});

test('the initial cached output timestamp cannot backdate the recovery interval',()=>{
  const stable=new SubjectSearchPictureStability();
  assert.equal(stable.observe(frame(1,400),1000),false);
  for(let step=1;step<5;step++)assert.equal(stable.observe(frame(step+1),1000+step*100),false);
  assert.equal(stable.observe(frame(6),1500),true);
});

test('wall clock elapsed, repeated cached output, or frozen render counts cannot establish stability',()=>{
  for(const mode of ['cached','frozen_count','frozen_timestamp']){
    const stable=new SubjectSearchPictureStability();
    for(let step=0;step<=8;step++){
      const count=mode==='frozen_timestamp'?step+1:1;
      const age=mode==='frozen_count'?0:step*100;
      assert.equal(stable.observe(frame(count,age),1000+step*100),false,mode);
    }
  }
});

test('incomplete or invalid recovery observations cannot establish a stability window',()=>{
  const invalid=[{state:'live'},{state:'live',stats:{decoderEpoch:1,waitingForKey:false}},
    frame(0),frame(1.5),frame(NaN),frame(1,-1),frame(1,501),frame(1,NaN),
    {state:'live',stats:{...frame().stats,decoderEpoch:undefined}},frame(1,0,NaN),frame(1,0,1,{running:undefined}),
    frame(1,0,1,{running:false}),frame(1,0,1,{waitingForKey:true}),
    frame(1,0,1,{waitingForKey:undefined}),frame(1,0,1,{lastRenderedAgeMs:undefined}),
    frame(1,0,1,{recoveryPaused:true}),{...frame(),state:'stale'}];
  for(const preview of invalid){
    const stable=new SubjectSearchPictureStability();
    stable.observe(frame(1),1000);stable.observe(frame(2),1400);
    assert.equal(stable.observe(preview,1500),false);
    assert.equal(stable.observe(frame(20),1600),false);
    assert.equal(stable.observe(frame(21),2000),false);
    assert.equal(stable.observe(frame(22),2100),true);
  }
});

test('epoch changes, count rollback, output rollback and long gaps restart the full window',()=>{
  for(const variant of ['epoch','count','output','poll_gap','output_gap']){
    const stable=new SubjectSearchPictureStability();
    stable.observe(frame(10,100),1000);stable.observe(frame(11,100),1300);
    const time=variant==='poll_gap'?1900:1400;
    const epoch=variant==='epoch'?2:1;
    const count=variant==='count'?1:12;
    const age=variant==='output'?300:variant==='output_gap'?0:100;
    // output_gap uses a previous output 500 ms old and a new one 600 ms later.
    if(variant==='output_gap'){
      stable.reset();stable.observe(frame(10,500),1000);
    }
    const observedAt=variant==='output_gap'?1100:time;
    assert.equal(stable.observe(frame(count,age,epoch),observedAt),false,variant);
    for(let step=1;step<5;step++)
      assert.equal(stable.observe(frame(count+step,0,epoch),observedAt+step*100),false,variant);
    assert.equal(stable.observe(frame(count+5,0,epoch),observedAt+500),true,variant);
  }
});
