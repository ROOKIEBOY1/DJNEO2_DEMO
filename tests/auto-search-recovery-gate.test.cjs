const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');

function fixture(){
  const faults={};const c=Object.create(AppController.prototype);
  Object.assign(c,{busyValue:false,
    session:{isReliableLinkFresh:()=>!faults.control,snapshot:()=>({phase:'ready',deviceVerified:true,
      downlinkAgeMs:faults.downlink?1001:0,videoAgeMs:0,telemetry:{flightAgeMs:0,taskAgeMs:0,cameraAgeMs:0,
        flight:{modeRaw:6,airborne:true,motorsOn:true},task:{phaseRaw:0,modeRaw:0},camera:{recordingCandidate:!!faults.recording}}})},
    flight:{snapshot:()=>({takeoffSent:true,takeoffAcknowledged:true,nativeTaskMayFly:false,
      movementActive:!!faults.moving,landRequested:!!faults.landing,landSent:false})},
    camera:{snapshot:()=>({operationActive:false,recordingRequested:false})},
    nativeTasks:{snapshot:()=>({busy:false}),activeOrUnknown:()=>false},
    video:{snapshot:()=>({state:'stale',stats:{running:true,lastRenderedAgeMs:2200}})}});
  return {c,faults};
}

test('a fresh controlled hover can wait for temporarily stale video without authorizing rotation',()=>{
  const {c}=fixture();
  assert.doesNotThrow(()=>c.ensureSubjectSearchCurrent(()=>{},Date.now()+1000,false,true));
  assert.throws(()=>c.ensureSubjectSearchCurrent(()=>{},Date.now()+1000,true));
});

test('video waiting never relaxes control, landing, movement, recording or cancellation gates',()=>{
  for(const fault of ['control','downlink','landing','moving','recording']){
    const {c,faults}=fixture();faults[fault]=true;
    assert.throws(()=>c.ensureSubjectSearchCurrent(()=>{},Date.now()+1000,false,true),undefined,fault);
  }
  const {c}=fixture();
  assert.throws(()=>c.ensureSubjectSearchCurrent(()=>{throw Error('cancelled');},Date.now()+1000,false,true),/cancelled/);
});
