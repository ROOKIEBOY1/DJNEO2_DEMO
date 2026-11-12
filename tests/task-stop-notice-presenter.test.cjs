const {test}=require('node:test');const assert=require('node:assert/strict');
const {TaskStopNoticePresenter}=require('../entry/src/main/ets/core/domain/TaskStopNotice.ets');
test('one UI owner shows the exact requested message once per ended task despite repeated refreshes',()=>{
  const p=new TaskStopNoticePresenter(),shown=[];
  const notice={id:'1:2:1000:2000:0b',message:'检测到障碍物，已触发避障',observedAtMs:2500};
  p.present(undefined,m=>shown.push(m));p.present(notice,m=>shown.push(m));
  p.present({...notice},m=>shown.push(m));p.present(undefined,m=>shown.push(m));p.present(notice,m=>shown.push(m));
  assert.deepEqual(shown,['检测到障碍物，已触发避障']);
  p.present({...notice,id:'2:2:3000:4000:0b'},m=>shown.push(m));assert.equal(shown.length,2);
});
test('a failed toast cannot retry on each snapshot or disrupt task notifications',()=>{
  const p=new TaskStopNoticePresenter();let attempts=0;
  const n={id:'first',message:'检测到障碍物，已触发避障',observedAtMs:2500};
  assert.doesNotThrow(()=>p.present(n,()=>{attempts++;throw Error('UI gone');}));
  p.present(n,()=>{attempts++;});assert.equal(attempts,1);
  p.present({...n,id:'next'},()=>{attempts++;});assert.equal(attempts,2);
});
