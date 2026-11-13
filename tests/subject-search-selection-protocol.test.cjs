const {test}=require('node:test');
const assert=require('node:assert/strict');
const {validateAgentAction}=require('../entry/src/main/ets/core/domain/AgentAction.ets');
const {validatePlannedAction}=require('../tools/deepseek-selection.cjs');
const {makeDeepSeekBody,parseDeepSeekResponse,SubjectSelectionProtocolError}=
  require('../entry/src/main/ets/core/domain/DeepSeekPayload.ets');

const jpeg='data:image/jpeg;base64,/9j/2Q==';
function observation(purpose='subject_selection') {
  return {purpose,requestId:'search-selection',sessionId:1,flightGeneration:2,requestedAtMs:1000,
    context:{airborne:true},frame:{candidates:[{id:11},{id:13}],currentSubjectId:11}};
}
function raw(command) {
  return JSON.stringify({choices:[{finish_reason:'stop',message:{content:JSON.stringify(command)}}]});
}
function prompt(description='选择白衣男生',retry=false,reference) {
  return JSON.parse(makeDeepSeekBody(observation(),description,jpeg,reference,retry)).messages[0].content;
}

test('selection none preserves explicit absence and ambiguity as distinct outcomes',()=>{
  for(const selectionStatus of ['not_found','ambiguous']) {
    const command={action:'none',selectionStatus,message:'请复核目标'};
    assert.doesNotThrow(()=>validateAgentAction(command,observation()));
    assert.deepEqual(parseDeepSeekResponse(raw(command),observation(),1100).command,command);
  }
});

test('legacy selection none remains accepted without assigning an absence status',()=>{
  assert.deepEqual(parseDeepSeekResponse(raw({action:'none'}),observation(),1100).command,{action:'none'});
});

test('selection status rejects unknown values through the retryable protocol error',()=>{
  for(const selectionStatus of ['',null,true,0,{},[],'missing','NOT_FOUND']) {
    assert.throws(()=>parseDeepSeekResponse(raw({action:'none',selectionStatus}),observation(),1100),
      error=>error instanceof SubjectSelectionProtocolError&&error.action==='none');
  }
});

test('selection status is forbidden outside selection none including other observation purposes',()=>{
  for(const selectionStatus of ['not_found','ambiguous']) {
    assert.throws(()=>validateAgentAction({action:'select_subject',subjectId:13,selectionStatus},observation()));
    for(const purpose of [undefined,'shoot_intent','ground_dolly_intent','dolly_subject']) {
      const obs={...observation(),purpose};
      assert.throws(()=>validateAgentAction({action:'none',selectionStatus},obs));
      assert.throws(()=>parseDeepSeekResponse(raw({action:'none',selectionStatus}),obs,1100));
    }
  }
});

test('selection status cannot bypass supplied candidate or frozen parameter validation',()=>{
  for(const command of [{action:'select_subject',subjectId:99},
    {action:'none',selectionStatus:'not_found',subjectId:13},
    ...[{zoom:3},{recipe:'dolly_circle'},{framing:'半身'},{retreat:true},{radiusMeters:2},{subjectRequired:true}]
      .map(extra=>({action:'none',selectionStatus:'ambiguous',...extra}))]) {
    assert.throws(()=>parseDeepSeekResponse(raw(command),observation(),1100),SubjectSelectionProtocolError);
  }
});

test('selector and retry payloads explain absence separately from ambiguity and uncertainty',()=>{
  for(const retry of [false,true]) {
    const text=prompt('选择白衣男生',retry);
    assert.match(text,/not_found/);
    assert.match(text,/ambiguous/);
    assert.match(text,/not_found[^.]*only[^.]*absent/i);
    assert.match(text,/uncertain[^.]*ambiguous/i);
    assert.match(text,/only[^.]*supplied[^.]*candidate/i);
    assert.match(text,/Never change the authorized action or parameters/);
    if(retry) {
      const reminder=text.split('Selection protocol retry:')[1];
      assert.match(reminder,/selectionStatus/);
      assert.match(reminder,/not_found/);
      assert.match(reminder,/ambiguous/);
    }
  }
});

test('self reference selector uses ambiguous for insufficient appearance evidence',()=>{
  const override=prompt('拍我',false,jpeg).split('Self reference override:')[1];
  assert.match(override,/insufficient[^.]*ambiguous/i);
  assert.match(override,/not_found[^.]*only[^.]*absent/i);
  assert.match(override,/Never use currentSubjectId, a sole candidate or the first candidate as a fallback/);
});

test('desktop selector accepts the same status outcomes and rejects them in other contexts',()=>{
  const metadata={purpose:'subject_selection',candidates:[{id:13}]};
  for(const selectionStatus of ['not_found','ambiguous']) {
    const command={action:'none',selectionStatus};
    assert.deepEqual(validatePlannedAction(command,metadata,true),command);
    assert.throws(()=>validatePlannedAction({action:'select_subject',subjectId:13,selectionStatus},metadata,true));
    for(const purpose of [undefined,'shoot_intent','ground_dolly_intent','dolly_subject']) {
      assert.throws(()=>validatePlannedAction(command,{...metadata,purpose},true));
    }
  }
  for(const selectionStatus of ['',null,true,0,{},[],'missing','NOT_FOUND']) {
    assert.throws(()=>validatePlannedAction({action:'none',selectionStatus},metadata,true));
  }
  assert.deepEqual(validatePlannedAction({action:'none'},metadata,true),{action:'none'});
});
