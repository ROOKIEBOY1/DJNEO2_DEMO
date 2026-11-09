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

test('ground demo has separate intent and numbered-image selection stages with restricted results',()=>{
  const ground={...observation(),frame:undefined,purpose:'ground_dolly_intent'};
  const intent=JSON.parse(makeDeepSeekBody(ground,'帮我给白衣男生拍个滑动变焦'));
  assert.match(intent.messages[0].content,/ground_dolly_intent/);
  assert.match(intent.messages[0].content,/omit subjectId/);
  const airborne={...observation(),purpose:'dolly_subject'};
  assert.match(JSON.parse(makeDeepSeekBody(airborne,'白衣男生','data:image/jpeg;base64,aa')).messages[0].content,/dolly_subject/);
  const raw=command=>JSON.stringify({choices:[{finish_reason:'stop',message:{content:JSON.stringify(command)}}]});
  assert.throws(()=>parseDeepSeekResponse(raw({action:'takeoff'}),airborne,1100));
  assert.throws(()=>parseDeepSeekResponse(raw({action:'dolly_zoom'}),airborne,1100));
  assert.equal(parseDeepSeekResponse(raw({action:'dolly_zoom',subjectId:13}),airborne,1100).command.subjectId,13);
});

test('airborne shoot intent classifies dolly before scanning while deferring an unproven subject',async()=>{
  const obs={...observation(),purpose:'shoot_intent',frame:undefined};
  const text='给白衣男生拍一个三倍半身希区柯克';
  const body=JSON.parse(makeDeepSeekBody(obs,text));
  const prompt=body.messages[0].content;
  assert.match(prompt,/Phase shoot_intent:/);
  assert.match(prompt,/even (?:with |when )?no (?:visible )?candidates|even.*without.*(?:image|candidate)/i);
  assert.match(prompt,/omit subjectId/i);
  assert.match(prompt,/do not guess|never guess/i);
  assert.match(prompt,/ordinary.*(?:recipe omitted|omit.*recipe|never adds recipe)/i);
  assert.match(prompt,/negated.*hypothetical.*quoted.*question-only/i);
  assert.match(prompt,/settings.*preparation/i);
  assert.match(prompt,/all other requests.*normal action rules/i);
  assert.deepEqual(JSON.parse(body.messages[1].content[0].text),{
    description:text,context:obs.context,candidates:[],hasImage:false
  });
  let desktopPrompt;
  await planWithDeepSeek('fake',{purpose:'shoot_intent',selectionPrompt:text,candidates:[],context:obs.context},
    Buffer.alloc(0),undefined,async(url,options)=>{
      desktopPrompt=JSON.parse(options.body).messages[0].content;
      return {ok:true,json:async()=>({choices:[{finish_reason:'stop',message:{content:'{"action":"dolly_zoom","zoom":3,"framing":"半身"}'}}]})};
    });
  assert.equal(desktopPrompt,prompt);
});

test('shoot intent may reuse only a current image candidate and keeps other actions available without a frame',()=>{
  const raw=command=>JSON.stringify({choices:[{finish_reason:'stop',message:{content:JSON.stringify(command)}}]});
  const visual={...observation(),purpose:'shoot_intent'};
  const textOnly={...visual,frame:undefined};
  const commands=[{action:'dolly_zoom',zoom:2,framing:'全身',retreat:false},
    {action:'dolly_zoom',recipe:'dolly_circle',zoom:3,framing:'半身',retreat:true},
    {action:'stop'},{action:'set_dolly',zoom:3},{action:'prepare_dolly',zoom:2},
    {action:'none',message:'请说明是哪位男生'}];
  for(const command of commands) assert.deepEqual(parseDeepSeekResponse(raw(command),textOnly,1100).command,command);
  const targeted={action:'dolly_zoom',subjectId:13,zoom:2};
  assert.deepEqual(parseDeepSeekResponse(raw(targeted),visual,1100).command,targeted);
  for(const subjectId of [13,99]) assert.throws(()=>parseDeepSeekResponse(raw({...targeted,subjectId}),textOnly,1100),/候选/);
  assert.throws(()=>parseDeepSeekResponse(raw({...targeted,subjectId:99}),visual,1100),/候选/);
});

test('desktop and phone phase prompts agree with and without an initial ready image',async()=>{
  for(const purpose of ['shoot_intent','ground_dolly_intent','dolly_subject']) {
    for(const hasImage of [false,true]) {
      const obs={...observation(),purpose,...(!hasImage?{frame:undefined}:{})};
      const text='给白衣男生拍特写镜头';
      const data=hasImage?'data:image/jpeg;base64,/9j/2Q==':undefined;
      const body=JSON.parse(makeDeepSeekBody(obs,text,data));
      const metadata={purpose,selectionPrompt:text,context:obs.context,candidates:obs.frame?.candidates??[],
        currentSubjectId:obs.frame?.currentSubjectId};
      let desktopBody;
      await planWithDeepSeek('fake',metadata,hasImage?Buffer.from([255,216,255,217]):Buffer.alloc(0),undefined,
        async(url,options)=>{
          desktopBody=JSON.parse(options.body);
          return {ok:true,json:async()=>({choices:[{finish_reason:'stop',message:{content:'{"action":"none","message":"需要确认目标"}'}}]})};
        });
      assert.equal(desktopBody.messages[0].content,body.messages[0].content,`${purpose}, image=${hasImage}`);
      assert.deepEqual(desktopBody.messages[1].content,body.messages[1].content);
    }
  }
});

test('shoot phases retain a visible current subject or propose a sole candidate before asking for clarification',()=>{
  for(const purpose of ['shoot_intent','dolly_subject']) {
    const obs={...observation(),purpose};
    const body=JSON.parse(makeDeepSeekBody(obs,'拍一个希区柯克','data:image/jpeg;base64,/9j/2Q=='));
    const phase=body.messages[0].content.split(`Phase ${purpose}:`)[1];
    assert.ok(phase,`${purpose} phase must be sent`);
    assert.match(phase,/without (?:a )?specified person.*currentSubjectId.*visible candidate/i);
    assert.match(phase,/no (?:visible )?currentSubjectId.*(?:only one|exactly one|sole) (?:visible )?candidate.*(?:confirm|propos)/i);
    assert.match(phase,/(?:with|when|if) no visible currentSubjectId[^.]*multiple candidates[^.]*no specified person[^.]*none[^.]*clarif/i);
  }
});

test('visual selection excludes the current subject for an explicit relative switch',()=>{
  const obs={...observation(),purpose:'dolly_subject'};
  const prompt=JSON.parse(makeDeepSeekBody(obs,'换另外一个人拍希区柯克','data:image/jpeg;base64,/9j/2Q=='))
    .messages[0].content.split('Phase dolly_subject:')[1];
  assert.match(prompt,/relative.*exclude currentSubjectId.*none.*unique visible alternative/i);
});

test('desktop phase response validation retains the authorized shoot parameters and candidate boundary',async()=>{
  const metadata={purpose:'dolly_subject',selectionPrompt:'白衣男生',context:{airborne:true},candidates:[{id:13}]};
  let command={action:'dolly_zoom',subjectId:13};
  const request=async()=>({ok:true,json:async()=>({choices:[{finish_reason:'stop',message:{content:JSON.stringify(command)}}]})});
  const jpeg=Buffer.from([255,216,255,217]);
  assert.deepEqual(await planWithDeepSeek('fake',metadata,jpeg,undefined,request),command);
  for(const extra of [{zoom:2},{framing:'半身'},{retreat:true},{recipe:'dolly_circle'}]) {
    command={action:'dolly_zoom',subjectId:13,...extra};
    await assert.rejects(planWithDeepSeek('fake',metadata,jpeg,undefined,request),/parameters|recipe/i);
  }
  for(const invalid of [{action:'stop'},{action:'dolly_zoom'}]) {
    command=invalid;
    await assert.rejects(planWithDeepSeek('fake',metadata,jpeg,undefined,request),/subject|selection/i);
  }
  command={action:'dolly_zoom',subjectId:13};
  await assert.rejects(planWithDeepSeek('fake',{...metadata,purpose:'ground_dolly_intent'},jpeg,undefined,request),/ground|subject/i);
  await assert.rejects(planWithDeepSeek('fake',{...metadata,purpose:'shoot_intent'},Buffer.alloc(0),undefined,request),/candidate/i);
  command={action:'dolly_zoom',subjectId:99};
  await assert.rejects(planWithDeepSeek('fake',{...metadata,purpose:'shoot_intent'},jpeg,undefined,request),/candidate/i);
  for(const allowed of [{action:'dolly_zoom',zoom:2},
    {action:'dolly_zoom',recipe:'dolly_circle',zoom:3,framing:'半身',retreat:true},{action:'stop'}]) {
    command=allowed;
    assert.deepEqual(await planWithDeepSeek('fake',{...metadata,purpose:'shoot_intent'},Buffer.alloc(0),undefined,request),allowed);
  }
});
