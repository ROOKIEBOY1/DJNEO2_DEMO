const {test}=require('node:test');
const assert=require('node:assert/strict');
const {makeDeepSeekBody,parseDeepSeekResponse}=require('../entry/src/main/ets/core/domain/DeepSeekPayload.ets');

// Offline fixtures contain JPEG boundary markers only, never a portrait or a cloud call.
const jpeg='data:image/jpeg;base64,/9j/2Q==';
const currentJpeg='data:image/jpeg;base64,/9j/AAH/2Q==';
function observation(purpose='subject_selection'){
  return {requestId:'self-1',sessionId:10,flightGeneration:2,requestedAtMs:1000,purpose,
    context:{airborne:true},frame:{candidates:[{id:11},{id:13}],currentSubjectId:11}};
}
function body(obs=observation(),description='给我拍个滑动变焦',reference=jpeg){
  return JSON.parse(makeDeepSeekBody(obs,description,obs.frame?currentJpeg:undefined,reference));
}

test('self selection labels reference and live images separately and marks reference metadata',()=>{
  const payload=body();
  const parts=payload.messages[1].content;
  const images=parts.filter(part=>part.type==='image_url');
  assert.equal(images.length,2);
  assert.equal(images[0].image_url.url,jpeg);
  assert.equal(images[1].image_url.url,currentJpeg);
  const referenceIndex=parts.indexOf(images[0]),currentIndex=parts.indexOf(images[1]);
  assert.match(parts[referenceIndex-1].text,/reference photo/i);
  assert.match(parts[currentIndex-1].text,/current image/i);
  const metadata=JSON.parse(parts[0].text);
  assert.equal(metadata.selfReference.referenceImage,'reference_photo');
  assert.equal(metadata.selfReference.currentImage,'current_image');
  assert.deepEqual(metadata.candidates,[{id:11},{id:13}]);
  assert.equal(metadata.currentSubjectId,11);
});

test('self selection overrides ordinary fallbacks and restricts IDs to current image candidates',()=>{
  for(const frame of [{candidates:[{id:11}],currentSubjectId:11},
    {candidates:[{id:11},{id:13}],currentSubjectId:11}]){
    const prompt=body({...observation(),frame}).messages[0].content;
    const override=prompt.split('Self reference override:')[1];
    assert.ok(override,'reference selection must override the ordinary selection policy');
    assert.match(override,/uncertain.*absent.*ambiguous.*none/i);
    assert.match(override,/never.*currentSubjectId.*sole.*first.*fallback/i);
    assert.match(override,/only.*current image.*candidate IDs/i);
    assert.match(override,/never.*(?:ID|number).*reference photo/i);
    assert.match(override,/select_subject.*subjectId/);
    assert.match(override,/frozen parameters.*confirmation/i);
  }
});

test('self selection rejects missing, malformed, non-JPEG and oversized references',()=>{
  const invalid=[undefined,'','data:image/png;base64,/9j/2Q==',
    'data:image/jpeg;base64,','data:image/jpeg;base64,hello',
    'data:image/jpeg;base64,aGVsbG8=','data:image/jpeg;base64,/9j/!Q==',
    'data:image/jpeg;base64,/9j/AAA=','data:image/jpeg;base64,/9j/2Q=',
    'data:image/jpeg;base64,'+'A'.repeat(1000004)];
  for(const reference of invalid){
    assert.throws(()=>makeDeepSeekBody(observation(),'拍我',currentJpeg,reference),/参考照片/);
  }
});

test('self reference accepts the 750000 byte bound and rejects one byte over it',()=>{
  function boundedFixture(size){
    const bytes=Buffer.alloc(size);bytes.set([255,216,255]);bytes.set([255,217],size-2);
    return 'data:image/jpeg;base64,'+bytes.toString('base64');
  }
  const maximum=boundedFixture(750000);
  assert.equal(maximum.length,1000023);
  assert.ok(body(observation(),'拍我',maximum).messages[1].content
    .filter(part=>part.type==='image_url')[0].image_url.url===maximum,'the maximum reference must be attached intact');
  assert.throws(()=>makeDeepSeekBody(observation(),'拍我',currentJpeg,boundedFixture(750001)),/参考照片/);
});

test('self subject selection requires a live frame instead of using the reference as the scene',()=>{
  assert.throws(()=>makeDeepSeekBody({...observation(),frame:undefined},'拍我',undefined,jpeg),/当前画面/);
  assert.throws(()=>makeDeepSeekBody(observation(),'拍我',undefined,jpeg),/画面/);
});

test('ordinary requests ignore a supplied reference and keep their payload unchanged',()=>{
  for(const description of ['帮我起飞','帮我给白衣男生拍照','给白衣男生拍个滑动变焦']){
    for(const purpose of ['shoot_intent','ground_dolly_intent','dolly_subject','subject_selection']){
      const obs=observation(purpose);
      assert.equal(makeDeepSeekBody(obs,description,currentJpeg,jpeg),
        makeDeepSeekBody(obs,description,currentJpeg));
    }
  }
});

test('initial self intents defer selection even with multiple candidates and without an image',()=>{
  for(const purpose of ['shoot_intent','ground_dolly_intent']){
    for(const hasFrame of [true,false]){
      const obs={...observation(purpose),...(!hasFrame?{frame:undefined}:{})};
      const payload=body(obs);
      const override=payload.messages[0].content.split('Self reference initial intent:')[1];
      assert.ok(override,`${purpose}, frame=${hasFrame}`);
      assert.match(override,/later.*subject_selection/i);
      assert.match(override,/classify.*original.*task.*retain.*parameters/i);
      assert.match(override,/omit subjectId/i);
      assert.match(override,/never.*currentSubjectId.*sole.*first/i);
      assert.match(override,/never.*none.*(?:missing|unavailable).*reference/i);
      assert.match(override,/photo.*record_start.*select_subject.*subjectRequired=true/i);
      assert.match(override,/photo.*select_subject.*record_start.*never authorize takeoff/i);
      assert.equal(payload.messages[1].content.filter(part=>part.type==='image_url').length,hasFrame?1:0);
      assert.equal(JSON.parse(payload.messages[1].content[0].text).selfReference,undefined);
    }
  }
});

test('initial self policy gives schema-valid examples and forbids subjectRequired on subject flight tasks',()=>{
  for(const purpose of ['shoot_intent','ground_dolly_intent']){
    const obs={...observation(purpose),frame:undefined};
    const policy=body(obs,'跟随我').messages[0].content.split('Self reference initial intent:')[1];
    const examples=(policy.match(/\{[^{}]+\}/g)||[]).map(text=>JSON.parse(text));
    assert.deepEqual(examples,[{action:'follow'},{action:'circle',radiusMeters:2},
      {action:'dolly_zoom',zoom:3,framing:'半身'},{action:'photo',subjectRequired:true}]);
    assert.match(policy,/subjectRequired must never be emitted for follow, circle or dolly_zoom/i);
    assert.match(policy,/reserved for photo, record_start and select_subject/i);
    for(const command of examples){
      const raw=JSON.stringify({choices:[{finish_reason:'stop',message:{content:JSON.stringify(command)}}]});
      assert.deepEqual(parseDeepSeekResponse(raw,obs,1100).command,command);
    }
  }
});

test('legacy or unrelated stages never attach the reference for a self request',()=>{
  for(const purpose of [undefined,'dolly_subject']){
    const obs={...observation(),purpose};
    assert.equal(makeDeepSeekBody(obs,'拍我',currentJpeg,jpeg),makeDeepSeekBody(obs,'拍我',currentJpeg));
    assert.equal(body(obs,'拍我').messages[1].content.filter(part=>part.type==='image_url').length,1);
  }
});

test('self subject wording routes explicit targets but excludes helpers and described other people',()=>{
  const {isSelfSubjectRequest}=require('../entry/src/main/ets/core/domain/SelfReference.ets');
  for(const description of ['给我拍个滑动变焦','为我拍照','拍我','请拍我一段视频','跟随我',
    '跟着我','围着我转圈','锁定我','切换到我','帮我拍我','给 我 拍个三倍半身希区柯克',
    '给我拍个三倍半身希区柯克','给我拍一段视频','给我拍张照片',
    '给我拍个滑动变焦运镜','给我拍一段运镜','给我拍一段特写组合镜头']){
    assert.equal(isSelfSubjectRequest(description),true,description);
  }
  for(const description of ['','帮我起飞','帮我给白衣男生拍照','帮我拍一下白衣男生','帮我拍照',
    '给我拍白衣男生','为我拍那个女生','拍我的朋友','跟随我的同事','围着我的朋友转圈',
    '拍我们','跟随我们','锁定我们的同事',
    '帮我把主体切换到白衣男生','原地转圈直到我喊停']){
    assert.equal(isSelfSubjectRequest(description),false,description);
  }
});

test('helper requests and relational descriptions never replace a described other person with the owner',()=>{
  const {isSelfSubjectRequest}=require('../entry/src/main/ets/core/domain/SelfReference.ets');
  for(const description of ['给我拍一下他','给我拍一下她','给我拍一下我们',
    '给我拍那个穿红衣服的','给我拍穿红衣服的','给我拍戴帽子的','给我拍左边那位',
    '给我拍黑衣服的人','给我拍一个人','给我拍小王','给我拍我和他',
    '拍我身边的男生','跟随我旁边的人','拍我身后的男生','锁定我前面的女生',
    '拍我朋友','跟随我同事','给我拍那个跟着我的人']){
    assert.equal(isSelfSubjectRequest(description),false,description);
  }
});

test('negated or mixed self targets stay with ordinary model selection',()=>{
  const {isSelfSubjectRequest}=require('../entry/src/main/ets/core/domain/SelfReference.ets');
  for(const description of ['不要拍我，拍白衣男生','别跟随我，跟随旁边的人','不要拍我',
    '不要再锁定我','拍我和他','跟随我和她']){
    assert.equal(isSelfSubjectRequest(description),false,description);
  }
});

test('self reference routing requires the common selection stage and a current frame',()=>{
  const {needsSelfReference}=require('../entry/src/main/ets/core/domain/SelfReference.ets');
  assert.equal(needsSelfReference(observation(),'给我拍个滑动变焦'),true);
  assert.equal(needsSelfReference({...observation(),frame:{candidates:[]}},'拍我'),true);
  assert.equal(needsSelfReference({...observation(),frame:undefined},'拍我'),false);
  assert.equal(needsSelfReference(observation(),'帮我给白衣男生拍照'),false);
  for(const purpose of [undefined,'shoot_intent','ground_dolly_intent','dolly_subject']){
    assert.equal(needsSelfReference({...observation(),purpose},'拍我'),false,String(purpose));
  }
});
