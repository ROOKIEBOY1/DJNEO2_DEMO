const {test}=require('node:test');
const assert=require('node:assert/strict');
const {flightPlanPresentation,taskProgressPresentation,videoResultReady,videoResultPresentation,flightResultMetrics}=
  require('../entry/src/main/ets/core/domain/AssistantFlightPresentation.ets');

function state(overrides={}) {
  return {groundDolly:{stage:'idle',active:false},nativeTask:{kind:'dolly',activeOrUnknown:false,executionObserved:false},
    nativeConfig:{framing:'全身',zoom:2,retreat:false},session:{telemetry:{}},agentMediaKind:'',agentMediaUri:'',
    agentMediaUris:[],agentVideoResultReady:false,videoCapturePending:false,agentFeedback:'',agentConfirmation:'',busy:false,...overrides};
}

test('flight plan uses the confirmed subject parameters without inventing takeoff, height or return-to-home',()=>{
  const result=flightPlanPresentation(state({groundDolly:{stage:'plan',active:true,
    plan:{action:'dolly_zoom',subjectId:13,framing:'半身',zoom:3,retreat:true}}}));
  assert.match(result.title,/希区柯克/);assert.match(result.detail,/小艺/);
  const lines=result.lines.join('\n');
  assert.match(lines,/半身/);assert.match(lines,/3倍/);assert.match(lines,/后退/);assert.match(lines,/任务结束.*悬停/);
  assert.doesNotMatch(result.detail+lines,/将起飞|自动返航|最佳高度|低风险|2\.5m/);
});

test('closeup plan lists both same-subject tasks with fixed circle radius and closeup defaults',()=>{
  const result=flightPlanPresentation(state({groundDolly:{stage:'plan',active:true,
    plan:{action:'dolly_zoom',recipe:'dolly_circle',subjectId:13}},nativeConfig:{radiusMeters:7,zoom:2}}));
  assert.match(result.title,/特写/);assert.match(result.detail,/同一|同一个|同主体/);
  const lines=result.lines.join('\n');assert.match(lines,/第1步.*滑动变焦/);assert.match(lines,/第2步.*同.*2米.*环绕/);
  assert.match(lines,/半身/);assert.match(lines,/3倍/);assert.doesNotMatch(lines,/7米|自动返航/);
  assert.match(lines,/全部结束后统一取回/);assert.doesNotMatch(lines,/完成并取回录像后/);
});

test('closeup progress blocks first-step video results and shows actual recording over the generic starting stage',()=>{
  const live=state({groundDolly:{stage:'starting',active:true,plan:{recipe:'dolly_circle',zoom:3}},
    closeup:{active:true,stage:'dolly_wait',step:1,message:'等待滑动变焦完成'},
    nativeTask:{kind:'dolly',activeOrUnknown:true,executionObserved:true,startedAtMs:100},
    session:{telemetry:{cameraAgeMs:0,camera:{observedAtMs:101,recordingCandidate:true}}},
    agentMediaKind:'video',agentMediaUri:'first',agentMediaUris:['first'],agentVideoResultReady:true});
  assert.equal(videoResultReady(live),false);
  const progress=taskProgressPresentation(live);assert.equal(progress.visible,true);
  const lines=progress.lines.join('\n');assert.match(lines,/1\/2.*滑动变焦/);assert.match(lines,/正在执行/);
  assert.match(lines,/正在录制/);assert.doesNotMatch(lines,/准备录像与运镜/);
  assert.equal(videoResultReady({...live,groundDolly:{stage:'shooting',active:false}}),false);
});

test('second closeup step never reports an old dolly execution as the current circle',()=>{
  const preparing=taskProgressPresentation(state({groundDolly:{stage:'starting',active:true},
    closeup:{active:true,stage:'circle',step:2,message:'准备环绕'},
    nativeTask:{kind:'dolly',activeOrUnknown:true,executionObserved:true}}));
  const lines=preparing.lines.join('\n');assert.match(lines,/2\/2.*同主体2米环绕/);
  assert.match(lines,/准备.*环绕/);assert.doesNotMatch(lines,/正在执行希区柯克/);
  const returning=taskProgressPresentation(state({groundDolly:{stage:'starting',active:true},
    closeup:{active:true,stage:'returning',step:2,message:'正在统一取回全部录像'},
    videoCapturePending:true,agentFeedback:'正在从飞机取回第1/1段录像',
    nativeTask:{kind:'circle',activeOrUnknown:false},
    session:{telemetry:{cameraAgeMs:0,camera:{recordingCandidate:false}}}}));
  assert.equal(returning.visible,false);assert.deepEqual(returning.lines,[]);
});

test('closeup waiting phases never show intermediate download and final return overrides stale circle execution',()=>{
  for(const [stage,step,kind] of [['dolly_wait',1,'dolly'],['circle_wait',2,'circle']]){
    const waiting=taskProgressPresentation(state({groundDolly:{stage:'starting',active:true},
      closeup:{active:true,stage,step,message:''},nativeTask:{kind,activeOrUnknown:false},
      videoCapturePending:true,agentFeedback:'正在从飞机取回第1/1段录像'}));
    assert.equal(waiting.visible,true);assert.match(waiting.lines.join('\n'),/等待.*结束|相机空闲/);
    assert.doesNotMatch(waiting.lines.join('\n'),/正在从飞机取回|本步录像回传|正在取回/);
  }
  const returned=state({groundDolly:{stage:'starting',active:true},
    closeup:{active:true,stage:'returning',step:2,message:''},
    nativeTask:{kind:'circle',activeOrUnknown:true,executionObserved:true},
    videoCapturePending:true,agentFeedback:'正在从飞机取回第2/3段录像'});
  const view=taskProgressPresentation(returned);assert.equal(view.visible,false);assert.deepEqual(view.lines,[]);
  assert.equal(videoResultReady(returned),false);
});

test('partial closeup footage stays playable and its result does not claim full completion',()=>{
  const partial=state({groundDolly:{stage:'failed',active:false},
    closeup:{active:false,stage:'failed',step:2,message:'原主体跟踪已变化'},
    agentMediaKind:'video',agentMediaUri:'first',agentMediaUris:['first','second'],agentVideoResultReady:true});
  assert.equal(videoResultReady(partial),true);
  assert.equal(videoResultReady({...partial,videoCapturePending:true}),true,
    'unfinished second-step transfer must not hide clips already saved locally from the first step');
  for(const stage of ['failed','cancelled']){
    const result=videoResultPresentation({...partial,closeup:{...partial.closeup,stage}});
    assert.match(result.title,/部分/);assert.match(result.detail,/未完成|取消/);assert.match(result.detail,/保留/);
    assert.doesNotMatch(result.detail,/全部录像已取回|任务已完成/);
  }
  const completed=videoResultPresentation({...partial,groundDolly:{stage:'shooting',active:false},
    closeup:{active:false,stage:'completed',step:2,message:''}});
  assert.match(completed.detail,/全部录像/);
});

test('missing plan parameters stay unknown and disabled retreat is described without a backwards-flight promise',()=>{
  const missing=flightPlanPresentation(state()).lines.join('\n');
  assert.match(missing,/待确认/);assert.doesNotMatch(missing,/2倍/);
  const result=flightPlanPresentation(state({groundDolly:{stage:'plan',active:true,
    plan:{action:'dolly_zoom',subjectId:3,framing:'远景',zoom:2,retreat:false}}}));
  assert.match(result.lines.join('\n'),/渐远关闭/);
  assert.doesNotMatch(result.lines.join('\n'),/后退拍摄/);
});

test('task progress reports observed execution and fresh recording while marking zoom as a target',()=>{
  const result=taskProgressPresentation(state({groundDolly:{stage:'shooting',active:false,
    plan:{zoom:3}},nativeTask:{kind:'dolly',activeOrUnknown:true,executionObserved:true,startedAtMs:100},
    session:{telemetry:{cameraAgeMs:0,camera:{observedAtMs:101,recordingCandidate:true}}}}));
  assert.equal(result.visible,true);assert.equal(result.title,'飞行任务进度');
  const lines=result.lines.join('\n');assert.match(lines,/正在执行/);assert.match(lines,/正在录制/);
  assert.match(lines,/目标倍率：3倍/);assert.doesNotMatch(lines,/当前焦段|低风险|高度/);
});

test('progress does not present stale camera states or an unverified candidate altitude as facts',()=>{
  const result=taskProgressPresentation(state({groundDolly:{stage:'shooting',active:false},
    nativeTask:{kind:'dolly',activeOrUnknown:true,executionObserved:false},
    session:{telemetry:{cameraAgeMs:1001,camera:{recordingCandidate:true},flightAgeMs:0,
      flight:{relativeHeightCandidateMeters:2.5}}}}));
  const lines=result.lines.join('\n');assert.match(lines,/等待.*回报/);assert.match(lines,/录制状态：等待/);
  assert.doesNotMatch(lines,/正在录制|2\.5|当前焦段|风险/);
  const previous=taskProgressPresentation(state({groundDolly:{stage:'starting',active:true},
    nativeTask:{kind:'dolly',activeOrUnknown:true,startedAtMs:200},
    session:{telemetry:{cameraAgeMs:0,camera:{observedAtMs:100,recordingCandidate:true}}}}));
  assert.doesNotMatch(previous.lines.join('\n'),/正在录制/);
});

test('progress is hidden before execution and during media transfer or transfer failure',()=>{
  for(const stage of ['idle','taking_off','scanning','selecting','confirm','plan'])
    assert.equal(taskProgressPresentation(state({groundDolly:{stage,active:stage!=='idle'}})).visible,false);
  assert.equal(taskProgressPresentation(state({groundDolly:{stage:'starting',active:true}})).visible,true);
  const transfer=taskProgressPresentation(state({videoCapturePending:true,
    agentFeedback:'正在从飞机取回第2/2段录像',session:{telemetry:{cameraAgeMs:0,camera:{recordingCandidate:false}}}}));
  assert.equal(transfer.visible,false);assert.deepEqual(transfer.lines,[]);
  const failed=taskProgressPresentation(state({videoCapturePending:true,agentFeedback:'自动取回未完成：第2/2段连接中断'}));
  assert.equal(failed.visible,false);assert.deepEqual(failed.lines,[]);
});

test('confirmed media return hides the lower progress even when start, shooting and native flags are stale',()=>{
  for(const stage of ['starting','shooting']) for(const agentFeedback of [
    '正在从飞机取回本次录像（2/3）…','正在等待飞机生成本次录像…',
    '正在等待相机结束写入并回到空闲状态…','自动取回未完成：第2/3段连接中断'
  ]){
    const result=taskProgressPresentation(state({groundDolly:{stage,active:true},videoCapturePending:true,
      agentFeedback,nativeTask:{kind:'dolly',activeOrUnknown:true,executionObserved:true},
      session:{telemetry:{cameraAgeMs:0,camera:{recordingCandidate:true}}}}));
    assert.equal(result.visible,false,`${stage}: ${agentFeedback}`);assert.deepEqual(result.lines,[]);
  }
  const recording=taskProgressPresentation(state({videoCapturePending:true,
    nativeTask:{kind:'dolly',activeOrUnknown:true,executionObserved:true},
    session:{telemetry:{cameraAgeMs:0,camera:{recordingCandidate:true}}}}));
  assert.equal(recording.visible,true);assert.match(recording.lines.join('\n'),/正在录制/);
});

test('flight results provide four metrics with a real fresh device state and explicit mock provenance',()=>{
  const result=flightResultMetrics(state({session:{phase:'ready',telemetry:{flightAgeMs:0,
    flight:{airborne:true,motorsOn:true,observedAtMs:1500}}},
    nativeTask:{startedAtMs:1000,activeOrUnknown:false},
    flight:{nativeStartedAtMs:1000,nativeStopConfirmedAtMs:15000,generation:1}}));
  assert.deepEqual(result,[
    {label:'设备状态：',value:'飞行中',mocked:false},
    {label:'剩余电量：',value:'80%',mocked:true},
    {label:'实际飞行时长：',value:'40秒',mocked:true},
    {label:'实际飞行距离：',value:'10米',mocked:true}
  ]);
  assert.doesNotMatch(result.map(metric=>metric.value).join('\n'),/返航|接管|14秒/);
});

test('flight result device state never treats stale flight telemetry or a disconnect as a safe landed aircraft',()=>{
  for(const [phase,ageMs,airborne,motorsOn,want] of [
    ['ready',0,false,false,'已着陆'],['ready',0,false,true,'电机运行中'],
    ['ready',1001,false,false,'已连接，飞行状态待更新'],
    ['disconnected',0,true,true,'未连接'],['failed',0,false,false,'连接异常']
  ]){
    const result=flightResultMetrics(state({session:{phase,telemetry:{flightAgeMs:ageMs,flight:{airborne,motorsOn}}}}));
    assert.deepEqual(result[0],{label:'设备状态：',value:want,mocked:false});
    assert.equal(result.length,4);assert.equal(result[1].mocked,true);
  }
});

test('completed local video survives later stale telemetry while new capture and preparation hide it',()=>{
  const result=state({agentMediaKind:'video',agentMediaUri:'file:a',agentMediaUris:['file:a','file:b'],agentVideoResultReady:true});
  assert.equal(videoResultReady(result),true);
  for(const patch of [{videoCapturePending:true},{agentVideoResultReady:false},
    {agentMediaKind:'photo'},{agentMediaUri:''},{agentMediaUris:[]},{agentMediaUri:'file:old'},
    {agentConfirmation:'请确认其他动作'}])
    assert.equal(videoResultReady({...result,...patch}),false,JSON.stringify(patch));
  for(const stage of ['taking_off','scanning','selecting','confirm','plan','starting'])
    assert.equal(videoResultReady({...result,groundDolly:{stage,active:false}}),false,stage);
  assert.equal(videoResultReady({...result,groundDolly:{stage:'shooting',active:false}}),true);
  for(const patch of [{busy:true},{nativeTask:{activeOrUnknown:true}},
    {groundDolly:{stage:'failed',active:false}},{groundDolly:{stage:'cancelled',active:false}},
    {session:{phase:'disconnected',telemetry:{}}},
    {session:{telemetry:{cameraAgeMs:0,camera:{recordingCandidate:true}}}},
    {session:{telemetry:{cameraAgeMs:1001,camera:{recordingCandidate:true}}}}]) {
    const local={...result,...patch};assert.equal(videoResultReady(local),true);
    assert.equal(taskProgressPresentation(local).visible,false);
  }
});
