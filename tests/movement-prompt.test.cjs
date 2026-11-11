const {test}=require('node:test');
const assert=require('node:assert/strict');
const {makeDeepSeekBody}=require('../entry/src/main/ets/core/domain/DeepSeekPayload.ets');
const {planWithDeepSeek,validatePlannedAction}=require('../tools/deepseek-selection.cjs');

// These offline tests cover the policy sent to the model, not live model interpretation.
function observation(movementSeconds=.5){return {requestId:'move-1',sessionId:10,flightGeneration:2,
  requestedAtMs:1000,context:{airborne:true,movementSeconds}};}

async function movementPrompts(description,movementSeconds=.5){
  const obs=observation(movementSeconds);
  const phone=JSON.parse(makeDeepSeekBody(obs,description));
  let desktop;
  await planWithDeepSeek('unused',{selectionPrompt:description,context:obs.context,candidates:[]},
    Buffer.alloc(0),undefined,async(url,options)=>{
      desktop=JSON.parse(options.body);
      return {ok:true,json:async()=>({choices:[{finish_reason:'stop',message:{content:'{"action":"none"}'}}]})};
    });
  assert.equal(desktop.messages[0].content,phone.messages[0].content);
  assert.deepEqual(desktop.messages[1].content,phone.messages[1].content);
  return phone.messages[0].content;
}

test('phone and desktop require model-chosen seconds and direct basic motion despite the manual slider',async()=>{
  for(const slider of [.5,4]){
    const prompt=await movementPrompts('前进',slider);
    assert.match(prompt,/every move must include numeric seconds from 0\.1 to 10/i);
    assert.match(prompt,/never omit seconds/i);
    assert.match(prompt,/never use context\.movementSeconds.*(?:slider|duration)/i);
    assert.match(prompt,/basic move.*(?:no|without).*subject.*(?:no|without|or).*user confirmation/i);
    assert.match(prompt,/every subject-aware action.*user confirmation/i);
    assert.doesNotMatch(prompt,/omit seconds if unspecified|App uses its slider/i);
  }
});

test('the model receives explicit-duration priority including half seconds and milliseconds',async()=>{
  const prompt=await movementPrompts('稍微前进2秒');
  assert.match(prompt,/explicit duration.*(?:priority|overrides).*qualitative/i);
  for(const example of [/前进2秒[^;]*seconds=2/,/左移半秒[^;]*seconds=0\.5/,/上升300毫秒[^;]*seconds=0\.3/]){
    assert.match(prompt,example);
  }
  assert.match(prompt,/explicit duration.*outside.*0\.1.*10.*none.*seconds/i);
});

test('duration-free movement receives conservative magnitude guidance rather than a fixed slider time',async()=>{
  const prompt=await movementPrompts('向前多飞一点');
  for(const guideline of [
    /tiny\/微调\/一点点\/稍微[^;]*0\.3/,
    /一点\/小幅[^;]*0\.5/,
    /bare directional command[^;]*1(?: second|;)/i,
    /多一点\/明显一点[^;]*1\.5/,
    /多一些\/大幅\/远一点[^;]*2(?: seconds|;)/
  ]) assert.match(prompt,guideline);
  assert.match(prompt,/without an explicit duration.*at most 2 seconds/i);
  assert.match(prompt,/never.*10 seconds.*(?:vague|qualitative)/i);
  assert.match(prompt,/indefinite.*until.*stop.*none/i);
});

test('both payloads default named in-place spin shortcuts to one bounded left yaw for 10 seconds',async()=>{
  for(const description of ['原地转圈','原地转一圈','原地自转','原地旋转','转个圈']){
    const prompt=await movementPrompts(description);
    assert.match(prompt,/in-place spin.*without a subject center.*原地转圈\/原地转一圈\/原地自转\/原地旋转\/转个圈/i);
    assert.match(prompt,/exception to the duration-free 2-second guideline.*\{"action":"move","direction":"turn_left","seconds":10\} by default/i);
    assert.match(prompt,/continuous left yaw.*10 seconds.*then center controls and stop/i);
    assert.match(prompt,/never restart.*loop.*exact 360-degree/i);
  }
});

test('in-place spin retains explicit right yaw, supported durations and short qualitative yaw',async()=>{
  const prompt=await movementPrompts('向右原地转圈500毫秒');
  assert.match(prompt,/explicit right.*turn_right.*(?:default|10 seconds)/i);
  assert.match(prompt,/explicit supported duration.*overrides.*10-second.*default/i);
  assert.match(prompt,/原地转圈3秒[^;]*direction=turn_left[^;]*seconds=3/);
  assert.match(prompt,/向右原地转圈500毫秒[^;]*direction=turn_right[^;]*seconds=0\.5/);
  assert.match(prompt,/slight yaw.*稍微左转\/右转一点点.*short qualitative duration.*unless.*clearly.*spin-circle shortcut/i);
});

test('spin shortcut preserves subject circles and bounded, measurable, affirmative request requirements',async()=>{
  const prompt=await movementPrompts('围着我转圈');
  assert.match(prompt,/围着我转圈\/绕着某主体转圈.*native circle.*subject selection and user confirmation.*never.*in-place/i);
  assert.match(prompt,/circle requests.*never add subjectRequired.*only allowed for photo\/record_start\/select_subject/i);
  assert.match(prompt,/原地转圈直到我喊停\/原地旋转不限时间.*none.*bounded seconds.*never.*10-second.*loop/i);
  assert.match(prompt,/distance in meters or angles in degrees.*精确360度.*none.*seconds.*never convert/i);
  assert.match(prompt,/never execute a negated, hypothetical, quoted, conditional or question-only flight request.*none/i);
});

test('spin duration and indefinite checks override the default with valid none JSON rather than clamping',async()=>{
  const prompt=await movementPrompts('原地转圈20秒');
  assert.match(prompt,/before.*spin default.*indefinite.*explicit duration outside 0\.1 to 10.*none/i);
  assert.match(prompt,/原地转圈20秒 => \{"action":"none","message":"请指定0\.1到10秒的时长"\}/);
  assert.match(prompt,/原地转圈直到我喊停 => \{"action":"none","message":"请指定0\.1到10秒的时长"\}/);
  assert.match(prompt,/原地旋转不限时间 => \{"action":"none","message":"请指定0\.1到10秒的时长"\}/);
  assert.match(prompt,/never silently clamp 20 seconds to 10 seconds/i);
});

test('movement policy keeps eight directions and clarifies unsupported or non-affirmative requests',async()=>{
  const prompt=await movementPrompts('左转30度');
  assert.match(prompt,/move direction is forward\/backward\/left\/right\/up\/down\/turn_left\/turn_right\./);
  assert.match(prompt,/distance in meters or angles in degrees.*none.*(?:ask|request).*seconds.*never convert/i);
  assert.match(prompt,/never execute a negated, hypothetical, quoted, conditional or question-only flight request.*none/i);
});

test('desktop schema requires numeric bounded seconds for movement',()=>{
  const meta={selectionPrompt:'前进',context:{movementSeconds:.5},candidates:[]};
  for(const seconds of [undefined,null,'2',0,-1,.09,10.01,NaN,Infinity]){
    const command={action:'move',direction:'forward',...(seconds===undefined?{}:{seconds})};
    assert.throws(()=>validatePlannedAction(command,meta,false),/duration/i,`seconds=${String(seconds)}`);
  }
});

test('desktop schema preserves all eight movement directions and model durations',()=>{
  const meta={selectionPrompt:'按指令移动',context:{movementSeconds:.5},candidates:[]};
  const examples=[['forward',.1],['backward',.3],['left',.5],['right',1],['up',1.5],
    ['down',2],['turn_left',3],['turn_right',10]];
  for(const [direction,seconds] of examples){
    const command={action:'move',direction,seconds};
    assert.deepEqual(validatePlannedAction(command,meta,false),command);
  }
  for(const direction of [undefined,'diagonal','rotate_left']){
    assert.throws(()=>validatePlannedAction({action:'move',direction,seconds:1},meta,false),/direction/i);
  }
});
