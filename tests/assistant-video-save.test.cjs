const {test}=require('node:test');const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');
function fixture(){
  const c=Object.create(AppController.prototype);const calls=[];
  Object.assign(c,{agentMediaSaving:false,agentMediaKind:'video',agentMediaUris:['a','b'],agentMediaUri:'a',
    emit(){},log(){},galleryVideoReceiver:{save:async sources=>{calls.push(sources);},accept(){throw Error('must not open gallery');}}});
  return {c,calls};
}
test('dialogue saves every returned video without opening the gallery or clearing inline previews',async()=>{
  const {c,calls}=fixture();await c.saveVideosToGallery({});
  assert.deepEqual(calls,[['a','b']]);assert.deepEqual(c.agentMediaUris,['a','b']);assert.equal(c.agentMediaUri,'a');
  assert.equal(c.agentMediaSaving,false);
});
test('saving uses the captured group, rejects concurrent saves and keeps originals on failure',async()=>{
  const {c}=fixture();let fail;let received;
  c.galleryVideoReceiver.save=async sources=>{received=sources;await new Promise((_,reject)=>{fail=reject;});};
  const pending=c.saveVideosToGallery({});assert.equal(c.agentMediaSaving,true);
  await assert.rejects(c.saveVideosToGallery({}),/正在/);
  c.agentMediaUris=['new'];c.agentMediaUri='new';fail(Error('copy failed'));
  await assert.rejects(pending,/copy failed/);assert.deepEqual(received,['a','b']);
  assert.deepEqual(c.agentMediaUris,['new']);assert.equal(c.agentMediaUri,'new');assert.equal(c.agentMediaSaving,false);
});
test('starting a new recording retires the old completed-video result before any camera operation',async()=>{
  const {c}=fixture();c.agentVideoResultReady=true;
  c.captureMedia={begin:async()=>{assert.equal(c.agentVideoResultReady,false);}};
  c.camera={startRecording:async()=>({ok:true})};
  await c.beginRecording({});assert.equal(c.agentVideoResultReady,false);
});
