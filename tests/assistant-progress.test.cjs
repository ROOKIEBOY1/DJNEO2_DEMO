const {test}=require('node:test');const assert=require('node:assert/strict');
const {assistantProgress}=require('../entry/src/main/ets/core/domain/AssistantProgress.ets');
const {movieSourceReady}=require('../entry/src/main/ets/core/media/MovieEligibility.ets');
const base={groundDolly:{stage:'idle',message:'',active:false},nativeTask:{activeOrUnknown:false},
  agentMediaKind:'',agentMediaUri:'',agentMediaUris:[],agentVideoResultReady:false,videoCapturePending:false,agentFeedback:'',session:{telemetry:{}}};

test('direct basic movement reports its actual duration instead of stale shooting results',()=>{
  const previous={...base,agentMediaKind:'video',agentMediaUri:'previous',agentMediaUris:['previous'],
    agentVideoResultReady:true,groundDolly:{stage:'shooting',active:false,plan:{action:'dolly_zoom'}}};
  const active=assistantProgress({...previous,busy:true,lastOperation:'左移 1.5 秒',
    agentFeedback:'小艺正在执行左移 1.5 秒…'},'正在理解你的拍摄需求…');
  assert.match(active.title,/移动/);assert.match(active.detail,/1\.5/);assert.equal(active.busy,true);
  const complete='已完成左移 1.5 秒并回中';
  const done=assistantProgress({...previous,busy:false,lastOperation:'左移 1.5 秒',agentFeedback:complete},complete);
  assert.match(done.title,/移动/);assert.match(done.detail,/1\.5/);assert.equal(done.busy,false);
  assert.deepEqual(previous.agentMediaUris,['previous']);
});

test('previous-shot recovery is shown instead of a stale failure or model-understanding message',()=>{
  const result=assistantProgress({...base,busy:true,lastOperation:'整理上次拍摄素材',
    groundDolly:{stage:'failed',active:false},closeup:{stage:'failed',active:false,message:'上一轮未完成'},
    agentFeedback:'正在核对上次拍摄的录像目录…'},'正在理解你的拍摄需求…');
  assert.match(result.title,/整理.*素材/);assert.match(result.detail,/小艺.*核对.*目录/);assert.equal(result.busy,true);
});

test('the current failed takeoff is visible over old shooting, closeup and locally retained results',()=>{
  const error='Verified device reply, downlink and video must all be fresh';
  for(const closeup of [undefined,{active:false,stage:'failed',step:2,message:'上一轮已中断'},
    {active:false,stage:'completed',step:2,message:'上一轮全部录像已取回'}]){
    const state={...base,lastError:error,lastOperation:'起飞请求',groundDolly:{stage:'shooting',active:false},closeup,
      agentMediaKind:'video',agentMediaUri:'previous',agentMediaUris:['previous'],agentVideoResultReady:true};
    const result=assistantProgress(state,error);
    assert.equal(result.detail,error);assert.equal(result.busy,false);assert.match(result.title,/提示|未完成|失败/);
  }
  for(const error of ['尚无新鲜飞行状态，未发送起飞请求','飞机尚未处于落地停桨状态，未重复发送起飞请求']){
    const result=assistantProgress({...base,groundDolly:{stage:'shooting',active:false,plan:{action:'dolly_zoom'}}},error);
    assert.equal(result.detail,error);assert.equal(result.busy,false);
  }
});

test('current local flight success owns the reply without turning partial footage into a complete movie source',()=>{
  for(const stage of ['failed','cancelled','completed'])for(const reply of ['飞机已确认起飞请求','飞机已确认降落请求']){
    const state={...base,groundDolly:{stage:'idle',active:false},
      closeup:{active:false,stage,step:2,message:'上一轮任务提示'},lastError:'',agentFeedback:reply,
      agentMediaKind:'video',agentMediaUri:'previous',agentMediaUris:['previous'],agentVideoResultReady:true};
    const result=assistantProgress(state,reply);
    assert.equal(result.detail,reply);assert.equal(result.busy,false);assert.match(result.title,/提示/);
    assert.equal(state.closeup.stage,stage);assert.deepEqual(state.agentMediaUris,['previous']);
    assert.equal(movieSourceReady(state),stage==='completed');
  }
});

test('a stale local flight reply cannot hide subsequent current workflow or capture-return feedback',()=>{
  const reply='飞机已确认起飞请求';
  const pending={...base,agentFeedback:'正在从飞机取回第1/1段录像',videoCapturePending:true};
  assert.match(assistantProgress(pending,reply).title,/取回/);
  const ground={...base,agentFeedback:reply,groundDolly:{stage:'scanning',active:true}};
  assert.match(assistantProgress(ground,reply).title,/起飞|寻找/);
  const closeup={...base,agentFeedback:reply,closeup:{active:true,stage:'circle',step:2,message:''}};
  assert.match(assistantProgress(closeup,reply).title,/2\/2/);
});

test('an unowned shooting stage is idle while a current plan still waits for capture sealing',()=>{
  const stale=assistantProgress({...base,groundDolly:{stage:'shooting',active:false}},'飞机已确认起飞请求');
  assert.equal(stale.busy,false);assert.equal(stale.detail,'飞机已确认起飞请求');
  const sealing=assistantProgress({...base,groundDolly:{stage:'shooting',active:false,plan:{action:'dolly_zoom'}}});
  assert.equal(sealing.busy,true);assert.match(sealing.title,/取回/);
});
test('progress text names Xiaoyi and reflects takeoff, visual selection and subject confirmation',()=>{
  for(const stage of ['taking_off','scanning','selecting','confirm','starting']){
    const result=assistantProgress({...base,groundDolly:{stage,active:true}},'正在理解你的拍摄需求…');
    assert.match(result.detail,/小艺/);assert.equal(result.busy,stage!=='confirm');
    if(stage==='scanning')assert.match(result.detail,/扫描/);
    if(stage==='selecting')assert.match(result.detail,/高亮框/);
    if(stage==='confirm')assert.match(result.detail,/确认/);
  }
});
test('hover scanning explains Xiaoyi is finding the subject without announcing another takeoff',()=>{
  const progress=assistantProgress({...base,groundDolly:{stage:'scanning',entry:'hover',active:true}});
  assert.match(progress.title,/寻找.*主体|扫描.*主体/);assert.doesNotMatch(progress.title,/起飞/);
  assert.match(progress.detail,/小艺.*实时画面/);assert.match(progress.detail,/扫描|寻找/);
  assert.doesNotMatch(progress.detail,/启动无人机|起飞/);assert.equal(progress.busy,true);
});
test('progress distinguishes recording, transfer failure and finished originals',()=>{
  const recording=assistantProgress({...base,groundDolly:{stage:'shooting',active:false},nativeTask:{activeOrUnknown:true,executionObserved:true,kind:'dolly'}});
  assert.match(recording.title,/拍摄/);assert.equal(recording.busy,true);
  const failed=assistantProgress({...base,videoCapturePending:true,agentFeedback:'自动取回未完成：第2/2段连接中断'});
  assert.match(failed.detail,/第2\/2段连接中断/);assert.equal(failed.busy,false);
  const completed=assistantProgress({...base,agentMediaKind:'video',agentMediaUri:'original',agentMediaUris:['original'],agentVideoResultReady:true});
  assert.match(completed.detail,/小艺已取回/);assert.equal(completed.busy,false);
  assert.doesNotMatch(completed.detail,/接收|弹窗|返航/);
  const saveFailure=assistantProgress({...base,agentMediaKind:'video',agentMediaUri:'original'},'保存失败，原片仍保留');
  assert.match(saveFailure.detail,/保存失败/);assert.equal(saveFailure.busy,false);
  const manual=assistantProgress({...base,videoCapturePending:true,
    session:{telemetry:{cameraAgeMs:0,camera:{recordingCandidate:true}}}});
  assert.match(manual.title,/录像/);assert.doesNotMatch(manual.title,/取回/);
});

test('subject confirmation leads to a generated plan rather than immediately starting recording',()=>{
  const confirm=assistantProgress({...base,groundDolly:{stage:'confirm',active:true}});
  assert.match(confirm.detail,/方案/);assert.doesNotMatch(confirm.detail,/确认后将开始录像/);
  const plan=assistantProgress({...base,groundDolly:{stage:'plan',active:true}});
  assert.match(plan.title,/方案/);assert.match(plan.detail,/小艺|一键执行/);assert.equal(plan.busy,false);
});

test('active closeup steps and partial failures override stale generic start or completed-media text',()=>{
  const shooting={...base,groundDolly:{stage:'starting',active:true},
    closeup:{active:true,stage:'dolly_wait',step:1,message:'等待滑动变焦结束'},
    agentMediaKind:'video',agentMediaUri:'first',agentMediaUris:['first'],agentVideoResultReady:true};
  const first=assistantProgress(shooting,'请点击一键执行');
  assert.match(first.title,/1\/2/);assert.match(first.detail,/小艺/);assert.match(first.detail,/滑动变焦/);
  assert.equal(first.busy,true);assert.doesNotMatch(first.title,/完成/);
  assert.doesNotMatch(first.detail,/取回本步录像|完成并取回/);assert.match(first.detail,/全部.*结束后.*统一取回/);
  const second=assistantProgress({...shooting,closeup:{active:true,stage:'circle',step:2,message:'准备环绕'}});
  assert.match(second.title,/2\/2/);assert.match(second.detail,/同主体.*2米.*环绕/);
  for(const stage of ['failed','cancelled']){
    const result=assistantProgress({...shooting,groundDolly:{stage:'failed',active:false},
      closeup:{active:false,stage,step:2,message:'原主体跟踪已变化'}});
    assert.match(result.title,/未完成|取消/);assert.match(result.detail,/原主体跟踪已变化/);
    assert.match(result.detail,/保留/);assert.equal(result.busy,false);assert.doesNotMatch(result.title,/执行完成/);
  }
});

test('only the final closeup returning stage announces unified media transfer',()=>{
  const returning=assistantProgress({...base,groundDolly:{stage:'starting',active:true},
    closeup:{active:true,stage:'returning',step:2,message:'正在统一取回全部录像'},
    nativeTask:{kind:'circle',activeOrUnknown:true,executionObserved:true},
    agentFeedback:'正在从飞机取回第2/3段录像'});
  assert.match(returning.title,/统一.*取回|回传/);assert.match(returning.detail,/两步|全部/);
  assert.match(returning.detail,/小艺/);assert.match(returning.detail,/第2\/3段/);assert.equal(returning.busy,true);
  assert.doesNotMatch(returning.detail,/正在准备.*环绕|正在等待.*环绕完成/);
});

test('same-subject circle handoff reports live-picture recovery before announcing circle execution',()=>{
  const feedback='小艺正在恢复实时画面，确认原主体后继续环绕';
  const progress=assistantProgress({...base,groundDolly:{stage:'starting',active:true},
    closeup:{active:true,stage:'circle',step:2,message:'准备环绕'},agentFeedback:feedback,
    nativeTask:{kind:'dolly',activeOrUnknown:false}});
  assert.match(progress.title,/恢复.*画面/);assert.equal(progress.detail,feedback);assert.equal(progress.busy,true);
  assert.doesNotMatch(progress.title+progress.detail,/正在执行.*环绕/);
});

test('latest media return counts, waiting states and errors override stale start and native execution',()=>{
  for(const stage of ['starting','shooting']){
    const transferring={...base,groundDolly:{stage,active:true},videoCapturePending:true,
      nativeTask:{kind:'dolly',activeOrUnknown:true,executionObserved:true},
      session:{telemetry:{cameraAgeMs:0,camera:{recordingCandidate:true}}}};
    for(const feedback of ['正在从飞机取回本次录像（2/3）…','正在从飞机取回第3/3段录像',
      '正在等待飞机生成本次录像…','正在等待相机结束写入并回到空闲状态…']){
      const result=assistantProgress({...transferring,agentFeedback:feedback},'请点击一键执行');
      assert.match(result.title,/取回|回传/);assert.match(result.detail,/小艺/);
      assert.ok(result.detail.includes(feedback.replace(/^正在/,'')),result.detail);
      assert.equal(result.busy,true);assert.doesNotMatch(result.detail,/锁定主体|控制无人机完成运镜/);
    }
    const failed=assistantProgress({...transferring,agentFeedback:'自动取回未完成：第3/3段连接中断'},'正在理解需求');
    assert.match(failed.title,/回传未完成/);assert.match(failed.detail,/小艺.*第3\/3段连接中断/);
    assert.equal(failed.busy,false);
  }
});

test('closeup return errors remain visible with their newest detail and do not claim completion',()=>{
  const result=assistantProgress({...base,groundDolly:{stage:'starting',active:true},
    closeup:{active:true,stage:'returning',step:2,message:'正在统一取回全部录像'},videoCapturePending:true,
    nativeTask:{kind:'circle',activeOrUnknown:true,executionObserved:true},
    agentFeedback:'自动取回未完成：第2/3段连接中断'});
  assert.match(result.title,/未完成/);assert.match(result.detail,/小艺.*第2\/3段连接中断/);
  assert.equal(result.busy,false);assert.doesNotMatch(result.detail,/全部录像已取回/);
});

test('completed replies retain the real returned segment count after transfer feedback is replaced',()=>{
  const completed={...base,agentMediaKind:'video',agentMediaUri:'one',agentMediaUris:['one','two','three'],
    agentVideoResultReady:true,agentFeedback:'本次录像已取回，共3段'};
  for(const closeup of [undefined,{active:false,stage:'completed',step:2,message:'全部录像已取回'}]){
    const result=assistantProgress({...completed,closeup});
    assert.match(result.detail,/小艺.*3段/);assert.equal(result.busy,false);
    if(closeup)assert.match(result.detail,/两步|全部/);
  }
});

test('partial closeup results retain failure context alongside the latest return error',()=>{
  const result=assistantProgress({...base,groundDolly:{stage:'failed',active:false},
    closeup:{active:false,stage:'failed',step:2,message:'原主体跟踪已变化'},videoCapturePending:true,
    agentMediaKind:'video',agentMediaUri:'first',agentMediaUris:['first'],agentVideoResultReady:true,
    agentFeedback:'自动取回未完成：第2/2段连接中断'});
  assert.match(result.title,/未完成/);assert.match(result.detail,/原主体跟踪已变化/);
  assert.match(result.detail,/保留1段录像/);assert.match(result.detail,/第2\/2段连接中断/);
  assert.equal(result.busy,false);assert.doesNotMatch(result.detail,/全部录像已取回/);
});

test('generic subject confirmation uses the selected action and ignores a stale dolly alias',()=>{
  for(const [action,want] of [['follow',/跟随/],['circle',/环绕/],['photo',/拍照|拍摄该主体/],['select_subject',/选定.*主体/]]){
    const result=assistantProgress({...base,groundDolly:{stage:'plan',active:true},
      subjectTask:{stage:'confirm',active:true,subjectId:7,plan:{action,subjectId:7}}});
    assert.match(result.title,/确认.*主体/);assert.match(result.detail,want);
    assert.equal(result.busy,false);assert.doesNotMatch(result.detail,/生成.*方案|一键执行|滑动变焦/);
    if(action==='select_subject')assert.doesNotMatch(result.title+result.detail,/拍摄|拍照|录像|飞行/);
  }
});

test('each generic action reports its own preparation and photo or selection completion without a flight promise',()=>{
  for(const [action,want] of [['follow',/跟随/],['circle',/环绕/],['photo',/拍照/],['select_subject',/主体/]]){
    const task={stage:'starting',active:true,plan:{action,subjectId:7}};
    const result=assistantProgress({...base,subjectTask:task},'正在理解你的拍摄需求…');
    assert.equal(result.busy,true);assert.match(result.title+result.detail,want);
    assert.doesNotMatch(result.title+result.detail,/滑动变焦|生成.*方案|一键执行/);
    if(action==='select_subject')assert.doesNotMatch(result.title+result.detail,/拍摄|录像|运镜/);
  }
  for(const [action,want] of [['photo',/拍照/],['select_subject',/主体/]]){
    const result=assistantProgress({...base,subjectTask:{stage:'completed',active:false,
      plan:{action,subjectId:7},message:action==='photo'?'照片已取回':'主体已选定'},
      nativeTask:{kind:'dolly',activeOrUnknown:true},session:{telemetry:{cameraAgeMs:0,camera:{recordingCandidate:true}}}},
      '正在理解你的拍摄需求…');
    assert.equal(result.busy,false);assert.match(result.title+result.detail,want);
    assert.doesNotMatch(result.title+result.detail,/正在.*录像|正在.*运镜|飞行任务|滑动变焦/);
  }
});

test('generic follow and circle shooting identify the requested task rather than an old dolly plan',()=>{
  for(const [action,want] of [['follow',/跟随/],['circle',/环绕/]]){
    const result=assistantProgress({...base,subjectTask:{stage:'shooting',active:false,plan:{action,subjectId:7}},
      nativeTask:{kind:action,activeOrUnknown:true,executionObserved:true}});
    assert.equal(result.busy,true);assert.match(result.title+result.detail,want);
    assert.doesNotMatch(result.title+result.detail,/滑动变焦/);
  }
});

test('a new generic task owns its prompt while previous partial footage retains failure context',()=>{
  for(const oldStage of ['failed','cancelled'])for(const [stage,action,want] of [
    ['confirm','follow',/确认.*主体/],['starting','photo',/拍照/],['completed','select_subject',/主体已确认/]
  ]){
    const result=assistantProgress({...base,closeup:{stage:oldStage,active:false,message:'上一轮原主体变化'},
      subjectTask:{stage,active:stage!=='completed',plan:{action,subjectId:7},message:'主体已选定'},
      agentMediaKind:'video',agentMediaUri:'first',agentMediaUris:['first'],agentVideoResultReady:true});
    assert.match(result.title,want,`${oldStage} -> ${action} ${stage}`);
    assert.doesNotMatch(result.detail,/上一轮原主体变化/);
  }
});

test('subject recording confirms and prepares recording without inventing a flight plan',()=>{
  for(const [stage,want] of [['confirm',/确认录像主体/],['starting',/正在准备录像/]]){
    const result=assistantProgress({...base,subjectTask:{stage,active:true,plan:{action:'record_start',subjectId:7}}});
    assert.match(result.title,want);assert.match(result.detail,/主体|录像/);
    assert.doesNotMatch(result.title+result.detail,/滑动变焦|运镜|飞行方案|一键执行/);
    assert.equal(result.busy,stage==='starting');
  }
});

test('subject recording distinguishes fresh recording from an unobserved start and returns footage after stop',()=>{
  const recording={...base,subjectTask:{stage:'shooting',active:false,plan:{action:'record_start',subjectId:7}},
    recordingRequested:true,videoCapturePending:true,nativeTask:{kind:'dolly',activeOrUnknown:false}};
  for(const activeOrUnknown of [false,true]){
    const result=assistantProgress({...recording,nativeTask:{kind:'dolly',activeOrUnknown,executionObserved:true},
      session:{telemetry:{cameraAgeMs:0,camera:{recordingCandidate:true}}}});
    assert.equal(result.title,'正在录像');assert.match(result.detail,/主体/);assert.equal(result.busy,true);
    assert.doesNotMatch(result.title+result.detail,/滑动变焦|运镜|飞行任务/);
  }
  const waiting=assistantProgress({...recording,session:{telemetry:{cameraAgeMs:1001,camera:{recordingCandidate:true}}}});
  assert.match(waiting.title,/等待.*录像.*状态/);assert.doesNotMatch(waiting.title+waiting.detail,/取回|正在录像|运镜/);
  assert.equal(waiting.busy,true);
  const returned=assistantProgress({...recording,recordingRequested:false,
    agentFeedback:'正在从飞机取回第1/2段录像',session:{telemetry:{cameraAgeMs:0,camera:{recordingCandidate:false}}}});
  assert.match(returned.title,/取回/);assert.match(returned.detail,/第1\/2段/);assert.equal(returned.busy,true);
  const completed=assistantProgress({...recording,recordingRequested:false,videoCapturePending:false,
    agentMediaKind:'video',agentMediaUri:'one',agentMediaUris:['one','two'],agentVideoResultReady:true});
  assert.match(completed.title,/录像已完成/);assert.match(completed.detail,/2段/);assert.equal(completed.busy,false);
  assert.doesNotMatch(completed.title,/飞行任务/);
});
