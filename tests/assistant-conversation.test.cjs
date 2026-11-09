const {test}=require('node:test');const assert=require('node:assert/strict');
const {AssistantConversation,assistantStep}=require('../entry/src/main/ets/core/domain/AssistantConversation.ets');
test('conversation retains user words in order without canned assistant acknowledgments',()=>{
  const chat=new AssistantConversation();chat.submit('帮我给白色衣服的男生拍个滑动变焦运镜');
  chat.submit('再拍一次');
  assert.deepEqual(chat.snapshot().messages.map(x=>[x.role,x.text]),[
    ['user','帮我给白色衣服的男生拍个滑动变焦运镜'],['user','再拍一次']]);
  const detached=chat.snapshot();detached.messages.pop();assert.equal(chat.snapshot().messages.length,2);
  assert.notEqual(chat.snapshot().messages[0].id,chat.snapshot().messages[1].id);
});
test('assistant progress reports actual task stages without invented completion',()=>{
  const base={groundDolly:{stage:'scanning',message:'正在等待悬停并扫描主体…'},nativeTask:{},agentMediaUri:'',agentMediaKind:''};
  assert.match(assistantStep(base),/扫描/);
  assert.match(assistantStep({...base,groundDolly:{stage:'shooting',message:''},nativeTask:{activeOrUnknown:true}}),/拍摄/);
  assert.match(assistantStep({...base,groundDolly:{stage:'shooting',message:''},agentMediaKind:'video',agentMediaUri:'a'}),/录像已取回/);
  assert.doesNotMatch(assistantStep({...base,videoCapturePending:true,groundDolly:{stage:'shooting',message:''},agentMediaKind:'video',agentMediaUri:'old'}),/录像已取回/);
  assert.match(assistantStep({...base,videoCapturePending:true,agentFeedback:'自动取回未完成：第2/2段连接中断'}),/第2\/2段连接中断/);
});
