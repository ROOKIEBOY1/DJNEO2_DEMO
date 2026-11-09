const {test}=require('node:test');const assert=require('node:assert/strict');
const {PreviewRecordingClock}=require('../entry/src/main/ets/core/domain/PreviewRecordingClock.ets');
function state(recording,start=10,generation=2){return {flight:{generation},nativeTask:{startedAtMs:start},recordingRequested:false,
  session:{telemetry:{cameraAgeMs:0,camera:{recordingCandidate:recording}}}};}
test('session-owned clock survives closing the panel and continues observing both video segments',()=>{
  const clock=new PreviewRecordingClock();
  clock.observe(state(true),1000);assert.equal(clock.observe(state(true),3000).label,'00:02');
  // Parent keeps observing while the child panel is absent.
  clock.observe(state(false),4000);clock.observe(state(true),6000);
  assert.equal(clock.observe(state(true),8000).label,'00:05');
  assert.equal(clock.observe(state(false),9000).label,'00:06');
  assert.equal(clock.observe(state(true,20),10000).label,'00:00');
});
test('manual capture and a new flight generation reset previous recording time, stale camera freezes',()=>{
  const clock=new PreviewRecordingClock();const manual=state(true,undefined);manual.nativeTask={};manual.recordingRequested=true;
  clock.observe(manual,1000);assert.equal(clock.observe(manual,3000).label,'00:02');
  const stale={...manual,session:{telemetry:{cameraAgeMs:2000,camera:{recordingCandidate:true}}}};
  clock.observe(stale,4000);assert.equal(clock.observe(stale,7000).label,'00:03');
  clock.observe({...manual,recordingRequested:false},8000);
  assert.equal(clock.observe(manual,9000).label,'00:00');
  assert.equal(clock.observe(state(false,undefined,3),10000).label,'00:00');
});
