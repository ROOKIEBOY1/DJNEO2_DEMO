const {test}=require('node:test');
const assert=require('node:assert/strict');
const {actionNeedsSubjectSelection,validateAgentAction}=require('../entry/src/main/ets/core/domain/AgentAction.ets');
const {makeDeepSeekBody,parseDeepSeekResponse}=require('../entry/src/main/ets/core/domain/DeepSeekPayload.ets');
const {validatePlannedAction}=require('../tools/deepseek-selection.cjs');

function observation(purpose,hasImage=true){
  return {purpose,requestId:'common-subject',sessionId:10,flightGeneration:2,requestedAtMs:1000,
    context:{airborne:purpose!=='ground_dolly_intent'},
    frame:hasImage?{candidates:[{id:11},{id:13}],currentSubjectId:11}:undefined};
}
function raw(command){return JSON.stringify({choices:[{finish_reason:'stop',message:{content:JSON.stringify(command)}}]});}
function parse(command,obs){return parseDeepSeekResponse(raw(command),obs,1100).command;}
function prompt(purpose){return JSON.parse(makeDeepSeekBody(observation(purpose,false),'跟随白衣男生')).messages[0].content;}

test('subject classification covers every subject action and leaves bare or urgent actions direct',()=>{
  assert.equal(typeof actionNeedsSubjectSelection,'function');
  for(const command of [{action:'dolly_zoom'},{action:'dolly_zoom',recipe:'dolly_circle'},
    {action:'follow'},{action:'circle'},{action:'select_subject',subjectRequired:true},
    {action:'photo',subjectId:0},{action:'photo',subjectRequired:true}]) {
    assert.equal(actionNeedsSubjectSelection(command),true,JSON.stringify(command));
  }
  for(const action of ['photo','record_start','record_stop','land','stop','takeoff','cancel_subject',
    'set_dolly','prepare_dolly','download_photo','download_video','move','none']) {
    assert.equal(actionNeedsSubjectSelection({action}),false,action);
  }
  assert.equal(actionNeedsSubjectSelection({action:'photo',subjectRequired:false}),false);
});

test('initial subject intents defer target selection without inventing an image ID',()=>{
  for(const purpose of ['shoot_intent','ground_dolly_intent']) {
    const obs=observation(purpose,false);
    for(const command of [{action:'follow'},{action:'circle',radiusMeters:4},
      {action:'photo',subjectRequired:true},{action:'select_subject',subjectRequired:true},
      {action:'dolly_zoom',zoom:3,retreat:false},{action:'photo'}]) {
      assert.deepEqual(parse(command,obs),command,`${purpose}: ${JSON.stringify(command)}`);
    }
    assert.throws(()=>parse({action:'select_subject'},obs),/编号/);
    for(const action of ['select_subject','photo','follow','circle','dolly_zoom']) {
      assert.throws(()=>parse({action,subjectId:13},obs),/候选/);
    }
  }
});

test('deferred markers are boolean, action limited and never weaken execution target validation',()=>{
  const initial=observation('shoot_intent',false);
  for(const command of [{action:'photo',subjectRequired:'true'},{action:'select_subject',subjectRequired:1},
    {action:'follow',subjectRequired:true},{action:'circle',subjectRequired:true},
    {action:'dolly_zoom',subjectRequired:true},{action:'photo',subjectRequired:true,recipe:'dolly_circle'},
    {action:'select_subject',subjectRequired:false}]) assert.throws(()=>parse(command,initial));
  for(const purpose of [undefined,'dolly_subject','subject_selection']) {
    for(const action of ['select_subject','photo']) {
      assert.throws(()=>validateAgentAction({action,subjectRequired:true},observation(purpose,false)));
    }
  }
  for(const action of ['photo','select_subject']) {
    assert.doesNotThrow(()=>validateAgentAction({action,subjectId:13,subjectRequired:true},observation(undefined)));
    for(const subjectId of [-1,256,13.5,'13',null,99]) {
      assert.throws(()=>parse({action,subjectId,subjectRequired:true},observation('shoot_intent')));
    }
  }
});

test('generic visual phase only returns a real selection or none and cannot rewrite the frozen task',()=>{
  const obs=observation('subject_selection');
  for(const command of [{action:'select_subject',subjectId:11},{action:'select_subject',subjectId:13},
    {action:'none',message:'请说明要选择哪位'}]) assert.deepEqual(parse(command,obs),command);
  for(const command of [{action:'select_subject'}, {action:'select_subject',subjectId:99},
    {action:'select_subject',subjectId:13,subjectRequired:true},
    {action:'select_subject',subjectId:13,subjectRequired:false},
    ...['photo','follow','circle','dolly_zoom','takeoff','land','stop','set_dolly','prepare_dolly'].map(action=>({action})),
    ...[{zoom:2},{framing:'半身'},{retreat:true},{recipe:'dolly_circle'},{radiusMeters:3}]
      .map(extra=>({action:'select_subject',subjectId:13,...extra}))]) {
    assert.throws(()=>parse(command,obs),JSON.stringify(command));
    assert.throws(()=>validateAgentAction(command,obs),JSON.stringify(command));
  }
  assert.throws(()=>parse({action:'select_subject',subjectId:13},observation('subject_selection',false)),/候选/);
});

test('initial phase contracts classify follow circle photo and selection before the common scan',()=>{
  for(const purpose of ['shoot_intent','ground_dolly_intent']) {
    const phase=prompt(purpose).split(`Phase ${purpose}:`)[1];
    assert.match(phase,/follow/);assert.match(phase,/circle/);
    assert.match(phase,/photo/);assert.match(phase,/select_subject/);
    assert.match(phase,/subjectRequired/);
    assert.match(phase,/without (?:an? )?(?:image|ready image)|no (?:usable )?image/i);
    assert.match(phase,/negated.*hypothetical.*quoted.*question-only/i);
    assert.match(phase,/photo.*select_subject.*(?:never|do not).*takeoff/i);
  }
  const text=prompt('shoot_intent');
  assert.match(text,/bare photo.*(?:direct|subjectRequired)/i);
  assert.match(text,/Only exclude currentSubjectId when the user explicitly requests another person/);
});

test('common visual prompt freezes task parameters and requires confirmation even for current or sole candidates',()=>{
  const phase=prompt('subject_selection').split('Phase subject_selection:')[1];
  assert.ok(phase);
  assert.match(phase,/Return only.*select_subject.*subjectId.*none/i);
  assert.match(phase,/never.*(?:change|modify).*action.*parameters/i);
  assert.match(phase,/framing.*zoom.*retreat.*recipe/i);
  assert.match(phase,/explicit.*(?:another person|relative).*exclude currentSubjectId/i);
  assert.match(phase,/currentSubjectId.*visible candidate/i);
  assert.match(phase,/exactly one visible candidate.*(?:confirm|propos)/i);
  assert.match(phase,/multiple candidates.*none.*clarif/i);
  assert.match(phase,/every.*(?:user confirmation|confirm)/i);
});

test('desktop debug parser enforces the same deferred and visual-only boundaries as the phone',()=>{
  for(const purpose of ['shoot_intent','ground_dolly_intent']) {
    const metadata={purpose,candidates:[]};
    for(const command of [{action:'photo',subjectRequired:true},{action:'select_subject',subjectRequired:true},
      {action:'follow'},{action:'circle',radiusMeters:3}]) {
      assert.deepEqual(validatePlannedAction(command,metadata,false),command);
    }
    assert.throws(()=>validatePlannedAction({action:'photo',subjectRequired:'true'},metadata,false));
    assert.throws(()=>validatePlannedAction({action:'select_subject',subjectRequired:false},metadata,false));
  }
  const metadata={purpose:'subject_selection',candidates:[{id:13}]};
  const selected={action:'select_subject',subjectId:13};
  assert.deepEqual(validatePlannedAction(selected,metadata,true),selected);
  assert.deepEqual(validatePlannedAction({action:'none'},metadata,true),{action:'none'});
  for(const command of [{action:'photo'},{action:'dolly_zoom',subjectId:13},
    {action:'select_subject',subjectRequired:true},{...selected,subjectRequired:false},
    {...selected,recipe:'dolly_circle'},{...selected,subjectId:99}]) {
    assert.throws(()=>validatePlannedAction(command,metadata,true));
  }
  assert.throws(()=>validatePlannedAction(selected,metadata,false));
  for(const action of ['photo','select_subject']) {
    assert.throws(()=>validatePlannedAction({action,subjectRequired:true},{candidates:[]},false));
  }
});

test('subject recording joins common selection while bare recording stays direct',()=>{
  assert.equal(actionNeedsSubjectSelection({action:'record_start',subjectRequired:true}),true);
  assert.equal(actionNeedsSubjectSelection({action:'record_start',subjectId:0}),true);
  assert.equal(actionNeedsSubjectSelection({action:'record_start'}),false);
  assert.equal(actionNeedsSubjectSelection({action:'record_start',subjectRequired:false}),false);
  for(const purpose of ['shoot_intent','ground_dolly_intent']) {
    const initial=observation(purpose,false);
    for(const command of [{action:'record_start'},{action:'record_start',subjectRequired:true}]) {
      assert.deepEqual(parse(command,initial),command);
      assert.deepEqual(validatePlannedAction(command,{purpose,candidates:[]},false),command);
    }
    assert.throws(()=>parse({action:'record_start',subjectId:13},initial),/候选/);
    assert.throws(()=>parse({action:'record_start',subjectRequired:'true'},initial));
    assert.throws(()=>validatePlannedAction({action:'record_start',subjectRequired:'true'},
      {purpose,candidates:[]},false));
  }
  const targeted={action:'record_start',subjectId:13,subjectRequired:true};
  assert.deepEqual(parse(targeted,observation(undefined)),targeted);
  assert.deepEqual(validatePlannedAction(targeted,{candidates:[{id:13}]},true),targeted);
  assert.throws(()=>parse({action:'record_start',subjectRequired:true},observation(undefined)));
  assert.throws(()=>validatePlannedAction({action:'record_start',subjectRequired:true},{candidates:[]},false));
  for(const subjectId of [-1,256,13.5,'13',null,99]) {
    assert.throws(()=>parse({...targeted,subjectId},observation('shoot_intent')));
    assert.throws(()=>validatePlannedAction({...targeted,subjectId},{purpose:'shoot_intent',candidates:[{id:13}]},true));
  }
  assert.throws(()=>parse(targeted,observation('subject_selection')));
  assert.throws(()=>validatePlannedAction(targeted,{purpose:'subject_selection',candidates:[{id:13}]},true));
});

test('subject recording intent contract defers recording without authorizing takeoff or changing bare recording',()=>{
  for(const purpose of ['shoot_intent','ground_dolly_intent']) {
    const text=prompt(purpose);
    assert.match(text,/"record_start":\["subjectId","subjectRequired"\]/);
    const phase=text.split(`Phase ${purpose}:`)[1];
    assert.match(phase,/record_start.*subjectRequired=true.*omit subjectId/i);
    assert.match(phase,/record_start.*never authorize takeoff/i);
    assert.match(phase,/bare.*record_start.*(?:direct|subjectRequired)/i);
  }
});
