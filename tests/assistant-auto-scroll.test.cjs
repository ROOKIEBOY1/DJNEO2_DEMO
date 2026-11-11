const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AssistantAutoScroll}=require('../entry/src/main/ets/core/domain/AssistantAutoScroll.ets');

function content() {
  const task={stage:'idle',active:false,message:''};
  return {
    messages:[{id:1,role:'user',text:'拍一段视频'}],
    listening:false,processing:false,accepting:false,status:'',mediaNote:'',showingMovie:false,savedMediaGroup:'',
    state:{subjectTask:task,groundDolly:task,closeup:{stage:'idle',active:false,step:0,message:''},
      agentConfirmation:'',agentFeedback:'',lastError:'',videoCapturePending:false,
      agentVideoResultReady:false,agentMediaKind:'',agentMediaUri:'',agentMediaUris:[],
      movie:{stage:'idle',progress:0,outputPath:'',error:'',busy:false,durationMs:0},
      moviePreparing:false,movieCanCompose:false,session:{telemetry:{}}}
  };
}

function returnedVideo(value) {
  value.state.subjectTask={stage:'completed',active:false,message:''};
  Object.assign(value.state,{agentVideoResultReady:true,agentMediaKind:'video',agentMediaUri:'take-1.mp4',
    agentMediaUris:['take-1.mp4'],movieCanCompose:true});
  return value;
}

test('new messages and several changes before layout coalesce into one pending scroll',()=>{
  const policy=new AssistantAutoScroll(),epoch=policy.start(),value=content();
  assert.equal(policy.observe(value),true);
  value.messages.push({id:2,role:'user',text:'一键执行'});
  assert.equal(policy.observe(value),true);
  assert.equal(policy.hasPending(),true);
  assert.equal(policy.takePending(epoch),true);
  assert.equal(policy.takePending(epoch),false);
  assert.equal(policy.observe(structuredClone(value)),false);
  assert.equal(policy.hasPending(),false);
  value.messages.push({id:3,role:'assistant',text:'新的回复'});
  assert.equal(policy.observe(value),true);
  assert.equal(policy.takePending(epoch),true);
});

test('confirmation, execution, returned-video and new completed-movie actions request a scroll',()=>{
  const policy=new AssistantAutoScroll(),epoch=policy.start(),value=content();
  policy.observe(value); policy.takePending(epoch);
  const changes=[
    ()=>{value.state.subjectTask={stage:'confirm',active:true,message:'',plan:{action:'dolly_zoom',subjectId:7}};},
    ()=>{value.state.subjectTask={...value.state.subjectTask,stage:'plan'};},
    ()=>{returnedVideo(value);},
    ()=>{value.state.movie={...value.state.movie,stage:'completed',outputPath:'movie-1.mp4'};value.showingMovie=true;},
    ()=>{value.state.movie.outputPath='movie-2.mp4';},
    ()=>{value.state.agentConfirmation='确认执行环绕';}
  ];
  for(const change of changes){
    change();
    assert.equal(policy.observe(value),true);
    assert.equal(policy.takePending(epoch),true);
    assert.equal(policy.observe(structuredClone(value)),false);
  }
});

test('hidden returned-video actions request a scroll when processing finishes',()=>{
  const policy=new AssistantAutoScroll(),epoch=policy.start(),value=returnedVideo(content());
  value.processing=true;
  policy.observe(value);policy.takePending(epoch);
  value.processing=false;
  assert.equal(policy.observe(value),true);
  assert.equal(policy.takePending(epoch),true);
  value.state.movieCanCompose=false;
  policy.observe(value);policy.takePending(epoch);
  value.state.movieCanCompose=true;
  assert.equal(policy.observe(value),true);
});

test('recording, telemetry and download numeric progress do not pull a reader away from history',()=>{
  const policy=new AssistantAutoScroll(),epoch=policy.start(),value=content();
  value.state.videoCapturePending=true;
  value.state.agentFeedback='正在从飞机取回第1/2段录像 1%（已用 1 秒）';
  value.status='正在下载录像 1%';
  assert.equal(policy.observe(value),true);assert.equal(policy.takePending(epoch),true);
  for(let index=2;index<=100;index++){
    value.state.agentFeedback=`正在从飞机取回第${index<50?1:2}/2段录像 ${index}%（已用 ${index} 秒）`;
    value.status=`正在下载录像 ${index}%`;
    value.state.session.telemetry={flightAgeMs:index*250,cameraAgeMs:index*250,camera:{recordingCandidate:index<50}};
    value.state.videoPreview={stats:{width:index,height:index,lastRenderedAgeMs:index}};
    value.recordingTime=`00:${index}`;
    assert.equal(policy.observe(value),false);
    assert.equal(policy.hasPending(),false);
  }
});

test('movie percentages stay quiet while a failure, retry and saved-result notice request a scroll',()=>{
  const policy=new AssistantAutoScroll(),epoch=policy.start(),value=returnedVideo(content());
  value.state.movie={...value.state.movie,stage:'rendering',busy:true};
  policy.observe(value);policy.takePending(epoch);
  for(const progress of [0.1,0.25,0.5,0.9]){
    value.state.movie.progress=progress;
    value.state.movie.durationMs+=1000;
    assert.equal(policy.observe(value),false);
  }
  value.state.movie={...value.state.movie,stage:'failed',busy:false,error:'无法导出，可重新成片'};
  assert.equal(policy.observe(value),true);assert.equal(policy.takePending(epoch),true);
  value.state.movie={...value.state.movie,stage:'probing',busy:true,error:''};
  assert.equal(policy.observe(value),true);assert.equal(policy.takePending(epoch),true);
  value.mediaNote='当前视频已保存至相册';
  assert.equal(policy.observe(value),true);assert.equal(policy.takePending(epoch),true);
});

test('a return failure and error/retry notices request a new scroll once',()=>{
  const policy=new AssistantAutoScroll(),epoch=policy.start(),value=content();
  value.state.videoCapturePending=true;
  policy.observe(value);policy.takePending(epoch);
  value.state.agentFeedback='自动取回未完成：连接中断';
  assert.equal(policy.observe(value),true);assert.equal(policy.takePending(epoch),true);
  assert.equal(policy.observe(structuredClone(value)),false);
  value.status='正在重试取回本次录像…';
  assert.equal(policy.observe(value),true);assert.equal(policy.takePending(epoch),true);
  value.status='没有听清，请再试一次';
  assert.equal(policy.observe(value),true);assert.equal(policy.takePending(epoch),true);
});

test('closing drops pending work and an old delayed callback cannot consume a reopened conversation',()=>{
  const policy=new AssistantAutoScroll(),oldEpoch=policy.start(),value=content();
  policy.observe(value);
  policy.stop();
  assert.equal(policy.hasPending(),false);
  assert.equal(policy.takePending(oldEpoch),false);
  value.status='迟到的上一轮状态';
  assert.equal(policy.observe(value),false);
  const newEpoch=policy.start();
  assert.equal(policy.observe(value),true);
  assert.equal(policy.takePending(oldEpoch),false);
  assert.equal(policy.hasPending(),true);
  assert.equal(policy.takePending(newEpoch),true);
  assert.equal(policy.takePending(newEpoch),false);
});
