const {test}=require('node:test');
const assert=require('node:assert/strict');
const {validateAgentAction,agentNeedsConfirmation,agentActionLabel}=require('../entry/src/main/ets/core/domain/AgentAction.ets');
const {makeDeepSeekBody,parseDeepSeekResponse}=require('../entry/src/main/ets/core/domain/DeepSeekPayload.ets');
const {validatePlannedAction}=require('../tools/deepseek-selection.cjs');

const frame={candidates:[{id:11},{id:13}],currentSubjectId:11};
const obs={requestId:'closeup-1',sessionId:10,flightGeneration:2,requestedAtMs:1000,
  context:{airborne:true},frame};
const raw=command=>JSON.stringify({choices:[{finish_reason:'stop',message:{content:JSON.stringify(command)}}]});

test('closeup is one whitelisted dolly recipe, with only its fixed sequence and no arbitrary plan',()=>{
  const command={action:'dolly_zoom',subjectId:13,recipe:'dolly_circle',framing:'半身',zoom:3,retreat:true};
  validateAgentAction(command,obs);
  assert.equal(agentNeedsConfirmation(command),true);
  assert.match(agentActionLabel(command),/特写|环绕/);
  assert.equal(validatePlannedAction(command,{candidates:frame.candidates},true),command);
  for(const bad of [
    {...command,recipe:'circle_dolly'}, {...command,recipe:true}, {...command,recipe:['dolly_circle']},
    {...command,radiusMeters:5}, {...command,steps:['dolly_zoom','circle']},
    {action:'circle',recipe:'dolly_circle',subjectId:13,radiusMeters:2},
    {action:'photo',recipe:'dolly_circle',subjectId:13},
    {action:'set_dolly',recipe:'dolly_circle',zoom:3},
    {action:'closeup'}, [command]
  ]) {
    assert.throws(()=>validateAgentAction(bad,obs),JSON.stringify(bad));
    assert.throws(()=>validatePlannedAction(bad,{candidates:frame.candidates},true),JSON.stringify(bad));
  }
});

test('targeted circle only accepts a candidate from this image and ordinary circle and dolly stay supported',()=>{
  for(const command of [{action:'circle',radiusMeters:2,subjectId:13},
    {action:'circle',radiusMeters:2},{action:'dolly_zoom',subjectId:11,framing:'全身',zoom:2}]) {
    validateAgentAction(command,obs);
    assert.deepEqual(parseDeepSeekResponse(raw(command),obs,1100).command,command);
    assert.equal(validatePlannedAction(command,{candidates:frame.candidates},true),command);
  }
  for(const command of [{action:'circle',radiusMeters:2,subjectId:99},
    {action:'dolly_zoom',recipe:'dolly_circle',subjectId:99}]) {
    assert.throws(()=>validateAgentAction(command,obs));
    assert.throws(()=>validatePlannedAction(command,{candidates:frame.candidates},true));
  }
  assert.throws(()=>validateAgentAction({action:'circle',subjectId:11},{...obs,frame:undefined}));
});

test('ground closeup preserves its recipe while the visual stage may only choose a candidate',()=>{
  const ground={...obs,frame:undefined,purpose:'ground_dolly_intent',context:{airborne:false}};
  const command={action:'dolly_zoom',recipe:'dolly_circle',framing:'半身',zoom:3,retreat:true};
  assert.deepEqual(parseDeepSeekResponse(raw(command),ground,1100).command,command);
  assert.throws(()=>parseDeepSeekResponse(raw({...command,subjectId:11}),ground,1100));
  const visual={...obs,purpose:'dolly_subject'};
  assert.equal(parseDeepSeekResponse(raw({action:'dolly_zoom',subjectId:13}),visual,1100).command.subjectId,13);
  for(const extra of [{recipe:'dolly_circle'},{zoom:2},{framing:'远景'},{retreat:false}])
    assert.throws(()=>parseDeepSeekResponse(raw({action:'dolly_zoom',subjectId:13,...extra}),visual,1100));
  const declined={action:'none',message:'没有找到明确的黑衣男生'};
  assert.deepEqual(parseDeepSeekResponse(raw(declined),visual,1100).command,declined);
});

test('cloud prompt defines the fixed closeup recipe and excludes photos, settings and non-affirmative requests',()=>{
  const ground={...obs,frame:undefined,purpose:'ground_dolly_intent',context:{airborne:false}};
  const prompt=JSON.parse(makeDeepSeekBody(ground,'帮黑色衣服的男生拍一段特写镜头')).messages[0].content;
  assert.match(prompt,/特写镜头/);assert.match(prompt,/dolly_circle/);assert.match(prompt,/2 meter/i);
  assert.match(prompt,/default.*半身.*3.*true/i);
  assert.match(prompt,/photo|拍.*照片/i);assert.match(prompt,/settings/i);
  assert.match(prompt,/negated.*hypothetical.*quoted.*question-only/i);
  assert.match(prompt,/不要起飞/);assert.match(prompt,/不要环绕/);
  for(const text of ['不要起飞，也不要拍特写镜头','拍特写镜头是什么意思？','把滑动变焦设成三倍半身']) {
    const body=JSON.parse(makeDeepSeekBody(ground,text));
    assert.equal(JSON.parse(body.messages[1].content[0].text).description,text);
    assert.equal(parseDeepSeekResponse(raw({action:'none',message:'未请求拍摄'}),ground,1100).command.action,'none');
  }
});
