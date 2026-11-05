const {test}=require('node:test');
const assert=require('node:assert/strict');
const {makeDeepSeekBody,parseDeepSeekResponse}=require('../entry/src/main/ets/core/domain/DeepSeekPayload.ets');
const {planWithDeepSeek}=require('../tools/deepseek-selection.cjs');

function observation(){return {requestId:'mobile-1',sessionId:10,flightGeneration:2,requestedAtMs:1000,
  context:{airborne:true},frame:{candidates:[{id:11},{id:13}],currentSubjectId:11}};}

test('phone payload matches the existing cloud prompt and sends numbered image plus current context', async()=>{
  const obs=observation();const text='换成白衣服的人';
  const body=JSON.parse(makeDeepSeekBody(obs,text,'data:image/jpeg;base64,/9j/2Q=='));
  assert.equal(body.model,'deepseek-flash');assert.equal(body.thinking.type,'disabled');
  assert.equal(body.messages[1].content[1].image_url.url,'data:image/jpeg;base64,/9j/2Q==');
  assert.deepEqual(JSON.parse(body.messages[1].content[0].text).candidates,obs.frame.candidates);
  let desktopPrompt;
  await planWithDeepSeek('fake',{selectionPrompt:text,candidates:obs.frame.candidates,context:obs.context},Buffer.from([255,216,255,217]),undefined,
    async(url,options)=>{desktopPrompt=JSON.parse(options.body).messages[0].content;return {ok:true,json:async()=>({choices:[{finish_reason:'stop',message:{content:'{"action":"none"}'}}]})};});
  assert.equal(body.messages[0].content,desktopPrompt);
});

test('phone response binds to observation and rejects invalid, oversized, truncated or stale decisions',()=>{
  const obs=observation();const raw=command=>JSON.stringify({choices:[{finish_reason:'stop',message:{content:JSON.stringify(command)}}]});
  const response=parseDeepSeekResponse(raw({action:'select_subject',subjectId:13}),obs,1100);
  assert.equal(response.requestId,obs.requestId);assert.equal(response.command.subjectId,13);
  for(const input of ['bad-json','x'.repeat(65537),raw({action:'select_subject',subjectId:99}),raw({action:'navigate'}),
    JSON.stringify({choices:[{finish_reason:'length',message:{content:'{}'}}]})]) assert.throws(()=>parseDeepSeekResponse(input,obs,1100));
  assert.throws(()=>parseDeepSeekResponse(raw({action:'photo'}),obs,22000));
  const noImage={...obs,frame:undefined};
  assert.equal(JSON.parse(makeDeepSeekBody(noImage,'拍照')).messages[1].content.length,1);
});
