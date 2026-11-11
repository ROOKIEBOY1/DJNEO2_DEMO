const {test}=require('node:test');
const assert=require('node:assert/strict');
const {makeDeepSeekBody,parseDeepSeekResponse,SubjectSelectionProtocolError}=
  require('../entry/src/main/ets/core/domain/DeepSeekPayload.ets');
const {AGENT_SYSTEM_PROMPT}=require('../entry/src/main/ets/core/domain/AgentPrompt.ets');

const jpeg='data:image/jpeg;base64,/9j/2Q==';
function observation(purpose='subject_selection'){
  return {purpose,requestId:'selector-contract',sessionId:10,flightGeneration:2,requestedAtMs:1000,
    context:{airborne:true},frame:{candidates:[{id:11},{id:13}],currentSubjectId:11}};
}
function raw(command){
  return JSON.stringify({choices:[{finish_reason:'stop',message:{content:JSON.stringify(command)}}]});
}
function body(obs=observation(),retry=false,description='给白衣男生拍一段特写镜头',reference){
  return JSON.parse(makeDeepSeekBody(obs,description,jpeg,reference,retry));
}
function protocolError(input,action,message){
  assert.throws(()=>parseDeepSeekResponse(input,observation(),1100),error=>{
    assert.equal(error.name,'SubjectSelectionProtocolError');
    assert.equal(typeof SubjectSelectionProtocolError,'function');
    assert.ok(error instanceof SubjectSelectionProtocolError);
    assert.equal(error.action,action);
    if(message) assert.match(error.message,message);
    return true;
  });
}

test('common selection sends a dedicated selector prompt with target data and two allowed outputs',()=>{
  const payload=body();const prompt=payload.messages[0].content;
  assert.ok(/^You are a visual subject selector\./.test(prompt),'selection must have its own selector role');
  assert.match(prompt,/original utterance.*description.*target.*data only/i);
  assert.match(prompt,/never.*plan or execute/i);
  assert.match(prompt,/task.*parameters.*(?:already )?frozen/i);
  assert.ok(!prompt.includes(AGENT_SYSTEM_PROMPT));
  assert.doesNotMatch(prompt,/Actions and allowed fields|"dolly_zoom":\[|"move":\[|特写镜头.*means.*dolly_zoom/i);
  const examples=(prompt.match(/\{[^{}]+\}/g)||[]).filter(text=>{
    try{JSON.parse(text);return true;}catch{return false;}
  }).map(text=>JSON.parse(text));
  assert.ok(examples.some(command=>command.action==='select_subject'&&Number.isInteger(command.subjectId)));
  assert.ok(examples.some(command=>command.action==='none'));
  assert.ok(examples.every(command=>['select_subject','none'].includes(command.action)));
  assert.equal(JSON.parse(payload.messages[1].content[0].text).description,'给白衣男生拍一段特写镜头');
  assert.match(prompt,/currentSubjectId.*visible candidate/i);
  assert.match(prompt,/exactly one visible candidate.*(?:confirm|propos)/i);
  assert.match(prompt,/explicit.*relative.*exclude currentSubjectId/i);
  assert.match(prompt,/multiple candidates.*none.*clarif/i);
});

test('selection retry adds only a fixed format reminder and retains current/reference user content',()=>{
  for(const [description,reference] of [['给白衣男生拍一段特写镜头',undefined],['拍我',jpeg]]){
    const first=body(observation(),false,description,reference),retry=body(observation(),true,description,reference);
    assert.deepEqual(retry.messages[1],first.messages[1]);
    assert.ok(retry.messages[0].content.startsWith(first.messages[0].content));
    assert.ok(retry.messages[0].content!==first.messages[0].content,'a retry must add a format reminder');
    const reminder=retry.messages[0].content.substring(first.messages[0].content.length);
    assert.match(reminder,/selection.*retry/i);
    assert.match(reminder,/select_subject.*subjectId.*none/i);
    assert.match(reminder,/only.*supplied.*candidate/i);
    assert.doesNotMatch(reminder,/dolly_circle|ground_dolly_intent|shoot_intent/);
  }
  for(const purpose of [undefined,'ground_dolly_intent','shoot_intent','dolly_subject']){
    const obs={...observation(),purpose};
    assert.deepEqual(body(obs,true),body(obs,false));
    assert.ok(body(obs).messages[0].content.startsWith(AGENT_SYSTEM_PROMPT));
  }
});

test('off-contract task actions become typed selection errors without coercion',()=>{
  for(const action of ['dolly_zoom','follow','circle','photo','record_start','takeoff','land','stop',
    'set_dolly','prepare_dolly','record_stop','cancel_subject','download_photo','download_video','move']){
    protocolError(raw({action,subjectId:11}),action,/选人阶段只能返回/);
  }
});

test('selection candidate and schema errors are typed without stripping fields or coercing IDs',()=>{
  for(const command of [{action:'select_subject'},{action:'select_subject',subjectId:99},
    {action:'select_subject',subjectId:'11'},
    ...[{zoom:3},{recipe:'dolly_circle'},{subjectRequired:true},{radiusMeters:2}]
      .map(extra=>({action:'select_subject',subjectId:11,...extra}))]){
    protocolError(raw(command),'select_subject');
  }
  protocolError(raw({action:'none',subjectId:11}),'none',/参数/);
  protocolError(raw({action:'none',message:'x'.repeat(161)}),'none',/说明/);
});

test('selection parse errors use a sanitized invalid_json label and retain the existing messages',()=>{
  for(const input of ['private model response',JSON.stringify({choices:[]}),
    JSON.stringify({choices:[{finish_reason:'length',message:{content:'{}'}}]}),
    JSON.stringify({choices:[{finish_reason:'stop',message:{content:'not-json'}}]})]){
    protocolError(input,'invalid_json',/云端未返回完整有效的动作/);
  }
  protocolError('x'.repeat(65537),'invalid_json',/云端响应超过大小限制/);
});

test('selection error action labels cannot expose arbitrary model text or prototype names',()=>{
  for(const action of ['private@example.invalid data:image/jpeg;base64,SECRET','constructor','toString',
    {private:'private@example.invalid'},'missing','invalid_json']){
    protocolError(raw({action}),'unknown');
  }
  for(const command of [{},null,[],{action:null},{action:3}]){
    protocolError(raw(command),command&&command.action===3?'unknown':'missing');
  }
});

test('valid selection and none remain successful while expiry and other stages stay ordinary errors',()=>{
  for(const command of [{action:'select_subject',subjectId:13},{action:'none'},
    {action:'none',message:'请说明要选择哪位'}]){
    assert.deepEqual(parseDeepSeekResponse(raw(command),observation(),1100).command,command);
  }
  for(const time of [999,21001]){
    for(const input of [raw({action:'select_subject',subjectId:11}),raw({action:'dolly_zoom'}),
      'invalid-json','x'.repeat(65537)]){
      assert.throws(()=>parseDeepSeekResponse(input,observation(),time),error=>{
        assert.equal(error.name,'Error');assert.equal(error.action,undefined);assert.match(error.message,/过期/);
        return true;
      });
    }
  }
  for(const purpose of [undefined,'shoot_intent','ground_dolly_intent','dolly_subject']){
    for(const input of ['invalid-json',raw({action:'select_subject',subjectId:99})]){
      assert.throws(()=>parseDeepSeekResponse(input,{...observation(),purpose},1100),error=>{
        assert.equal(error.name,'Error');assert.equal(error.action,undefined);return true;
      });
    }
  }
});
