const {test}=require('node:test');const assert=require('node:assert/strict');
const {assistantProgress}=require('../entry/src/main/ets/core/domain/AssistantProgress.ets');
const base={groundDolly:{stage:'idle',message:'',active:false},nativeTask:{activeOrUnknown:false},
  agentMediaKind:'',agentMediaUri:'',agentMediaUris:[],agentVideoResultReady:false,videoCapturePending:false,agentFeedback:'',session:{telemetry:{}}};

test('previous-shot recovery is shown instead of a stale failure or model-understanding message',()=>{
  const result=assistantProgress({...base,busy:true,lastOperation:'整理上次拍摄素材',
    groundDolly:{stage:'failed',active:false},closeup:{stage:'failed',active:false,message:'上一轮未完成'},
    agentFeedback:'正在核对上次拍摄的录像目录…'},'正在理解你的拍摄需求…');
  assert.match(result.title,/整理.*素材/);assert.match(result.detail,/小艺.*核对.*目录/);assert.equal(result.busy,true);
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
