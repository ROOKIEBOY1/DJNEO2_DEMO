const {test}=require('node:test');
const assert=require('node:assert/strict');
const {validateAgentAction,agentNeedsConfirmation,actionNeedsSubjectSelection,agentActionLabel}=
  require('../entry/src/main/ets/core/domain/AgentAction.ets');
const {makeDeepSeekBody,parseDeepSeekResponse}=require('../entry/src/main/ets/core/domain/DeepSeekPayload.ets');
const {validatePlannedAction,planWithDeepSeek}=require('../tools/deepseek-selection.cjs');

const obs={requestId:'sequence-1',sessionId:10,flightGeneration:2,controlGeneration:0,
  requestedAtMs:1000,context:{airborne:true,movementSeconds:.5}};
const metadata={selectionPrompt:'前进2秒，再左移1秒，最后右转3秒',context:obs.context,candidates:[]};
const steps=()=>[{direction:'forward',seconds:2},{direction:'left',seconds:1},{direction:'turn_right',seconds:3}];
const raw=(command,finish_reason='stop')=>JSON.stringify({choices:[{finish_reason,message:{content:JSON.stringify(command)}}]});
function rejectsBoth(command){
  assert.throws(()=>validateAgentAction(command,obs));
  assert.throws(()=>validatePlannedAction(command,metadata,false));
}
function acceptsBoth(command){
  validateAgentAction(command,obs);
  assert.equal(validatePlannedAction(command,metadata,false),command);
  assert.deepEqual(parseDeepSeekResponse(raw(command),obs,1100).command,command);
}

test('a bounded ordered movement sequence is one direct action without subject selection or confirmation',()=>{
  const command={action:'move_sequence',steps:steps()};
  acceptsBoth(command);
  assert.equal(agentNeedsConfirmation(command),false);
  assert.equal(actionNeedsSubjectSelection(command),false);
  assert.equal(agentActionLabel(command),'执行连续基础运动');
});

test('movement sequence preserves all eight directions with independent durations',()=>{
  const directions=['forward','backward','left','right','up','down','turn_left','turn_right'];
  const durations=[.1,.3,.5,1,1.5,2,3,10];
  acceptsBoth({action:'move_sequence',steps:directions.map((direction,i)=>({direction,seconds:durations[i]}))});
  acceptsBoth({action:'move_sequence',steps:[{direction:'forward',seconds:10},
    {direction:'backward',seconds:10},{direction:'turn_left',seconds:10}]});
});

test('sequence rejects a missing, non-array, too short or too long step list',()=>{
  for(const value of [undefined,null,{},'',[],[steps()[0]],Array.from({length:9},()=>steps()[0])]){
    rejectsBoth({action:'move_sequence',...(value===undefined?{}:{steps:value})});
  }
});

test('every sequence step needs one supported direction and finite numeric duration',()=>{
  for(const direction of [undefined,null,'diagonal','photo','takeoff','circle',['forward','left']]){
    rejectsBoth({action:'move_sequence',steps:[steps()[0],{direction,seconds:1}]});
  }
  for(const seconds of [undefined,null,'1',false,NaN,Infinity,-Infinity,0,-1,.09,10.01]){
    rejectsBoth({action:'move_sequence',steps:[steps()[0],{direction:'left',seconds}]});
  }
});

test('sequence rejects malformed, nested or extra-parameter steps without dropping any step',()=>{
  for(const bad of [null,undefined,[],1,'left',{},
    {action:'move',direction:'left',seconds:1},{action:'land'},
    {...steps()[1],subjectId:13},{...steps()[1],repeat:2},
    {...steps()[1],steps:steps()},{...steps()[1],axes:{yaw:1}},
    {...steps()[1],radiusMeters:2}]){
    rejectsBoth({action:'move_sequence',steps:[steps()[0],bad]});
  }
});

test('an over-thirty-second or extra-field sequence fails as a whole',()=>{
  rejectsBoth({action:'move_sequence',steps:[{direction:'forward',seconds:10},
    {direction:'backward',seconds:10},{direction:'up',seconds:10},{direction:'left',seconds:.1}]});
  for(const extra of [{direction:'left'},{seconds:2},{repeat:2},{parallel:true},
    {subjectId:13},{recipe:'dolly_circle'},{takeoff:true},{framing:'半身'}]){
    rejectsBoth({action:'move_sequence',steps:steps(),...extra});
  }
  rejectsBoth([{action:'move',direction:'forward',seconds:1},{action:'move',direction:'left',seconds:1}]);
});

test('the exact thirty-second boundary tolerates only addition noise rather than real excess',()=>{
  const durations=[9.9,9.8,10,.1,.1,.1];
  assert.ok(durations.reduce((sum,value)=>sum+value,0)>30,'fixture exercises floating-point addition noise');
  acceptsBoth({action:'move_sequence',steps:durations.map(seconds=>({direction:'forward',seconds}))});
  rejectsBoth({action:'move_sequence',steps:[9.9,9.8,10,.1,.1,.1000001]
    .map(seconds=>({direction:'forward',seconds}))});
});

test('movement steps cannot be attached to an existing single action or shooting recipe',()=>{
  for(const command of [{action:'move',direction:'left',seconds:1},
    {action:'photo'},{action:'takeoff'},{action:'land'},
    {action:'dolly_zoom',recipe:'dolly_circle'},{action:'follow'},{action:'circle',radiusMeters:2}]){
    rejectsBoth({...command,steps:steps()});
    acceptsBoth(command);
  }
});

test('visual selection phases cannot accept movement sequences and truncated model output is rejected',()=>{
  const command={action:'move_sequence',steps:steps()};
  for(const purpose of ['subject_selection','dolly_subject']){
    assert.throws(()=>parseDeepSeekResponse(raw(command),{...obs,purpose},1100));
    assert.throws(()=>validatePlannedAction(command,{...metadata,purpose},false));
  }
  assert.throws(()=>parseDeepSeekResponse(raw(command,'length'),obs,1100));
});

test('finite repeats use an expanded list rather than an executable repeat or loop field',()=>{
  const pair=[{direction:'forward',seconds:1},{direction:'backward',seconds:1}];
  acceptsBoth({action:'move_sequence',steps:[...pair,...pair]});
  rejectsBoth({action:'move_sequence',steps:pair,repeat:2});
  rejectsBoth({action:'move_sequence',steps:pair,loop:true});
});

test('phone and desktop tell the model to preserve every requested movement and clarify mixed or simultaneous actions',async()=>{
  const phone=JSON.parse(makeDeepSeekBody(obs,metadata.selectionPrompt));
  let desktop;
  const planned=await planWithDeepSeek('unused',metadata,Buffer.alloc(0),undefined,async(url,options)=>{
    desktop=JSON.parse(options.body);
    return {ok:true,json:async()=>JSON.parse(raw({action:'move_sequence',steps:steps()}))};
  });
  assert.deepEqual(planned,{action:'move_sequence',steps:steps()});
  assert.equal(phone.messages[0].content,desktop.messages[0].content);
  assert.deepEqual(phone.messages[1].content,desktop.messages[1].content);
  assert.ok(desktop.max_tokens>=512);
  assert.ok(phone.max_tokens>=512);
  const prompt=phone.messages[0].content;
  assert.match(prompt,/move_sequence.*steps/i);
  assert.match(prompt,/2.to.8.*steps.*30 seconds/i);
  assert.match(prompt,/original order.*never.*(?:omit|drop).*reorder/i);
  assert.match(prompt,/each step.*(?:duration|seconds).*single.move/i);
  assert.match(prompt,/finite repeat.*expand.*(?:limit|bound)/i);
  assert.match(prompt,/simultaneous.*none/i);
  assert.match(prompt,/mixed.*(?:takeoff|photo).*none/i);
  assert.match(prompt,/never.*(?:truncate|split|clamp).*sequence/i);
  assert.match(prompt,/no.*automatic takeoff/i);
  assert.match(prompt,/negated.*hypothetical.*quoted.*conditional.*question-only.*none/i);
});
