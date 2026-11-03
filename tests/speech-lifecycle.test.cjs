const {test}=require('node:test'); const assert=require('node:assert/strict');
const {VoiceCommandAdapter}=require('../entry/src/main/ets/core/domain/VoiceCommandAdapter.ets');
const api={permission:async()=>({authResults:[0]}),create:async()=>api.engine};
global.__neoKits={
  '@kit.AbilityKit':{abilityAccessCtrl:{createAtManager:()=>({requestPermissionsFromUser:()=>api.permission()})}},
  '@kit.CoreSpeechKit':{speechRecognizer:{createEngine:()=>api.create()}}
};
delete require.cache[require.resolve('../entry/src/main/ets/core/platform/LocalSpeechRecognizer.ets')];
const {LocalSpeechRecognizer}=require('../entry/src/main/ets/core/platform/LocalSpeechRecognizer.ets');
function engine(){return {starts:0,shutdowns:0,setListener(l){this.listener=l;},startListening(p){this.starts++;this.session=p.sessionId;},
  cancel(){},finish(){},shutdown(){this.shutdowns++;}};}
test('stopping during permission prompt suppresses later engine creation',async()=>{
  let resolve;let created=0;api.permission=()=>new Promise(r=>resolve=r);api.create=async()=>{created++;return engine();};
  const adapter=new VoiceCommandAdapter();adapter.setEnabled(true);const speech=new LocalSpeechRecognizer({},adapter);
  const start=speech.start();await speech.stop(false);resolve({authResults:[0]});await start;
  assert.equal(created,0);
});
test('late result after stop cannot trigger a command, duplicate final executes once',async()=>{
  api.permission=async()=>({authResults:[0]});const e=engine();api.create=async()=>e;
  const adapter=new VoiceCommandAdapter();adapter.setEnabled(true);const sent=[];adapter.setListener(c=>sent.push(c.kind));
  const speech=new LocalSpeechRecognizer({},adapter);await speech.start();
  e.listener.onResult(e.session,{isFinal:true,result:'拍照'});e.listener.onResult(e.session,{isFinal:true,result:'拍照'});
  assert.deepEqual(sent,['photo']);await speech.stop(false);
  e.listener.onResult(e.session,{isFinal:true,result:'降落'});assert.deepEqual(sent,['photo']);
});
test('completion restarts one offline session and stop cancels restart',async()=>{
  api.permission=async()=>({authResults:[0]});const engines=[];api.create=async()=>{const e=engine();engines.push(e);return e;};
  const adapter=new VoiceCommandAdapter();adapter.setEnabled(true);const speech=new LocalSpeechRecognizer({},adapter);
  await speech.start();engines[0].listener.onComplete(engines[0].session,'done');
  await new Promise(r=>setTimeout(r,400));assert.equal(engines.length,2);
  engines[1].listener.onComplete(engines[1].session,'done');await speech.stop(false);
  await new Promise(r=>setTimeout(r,400));assert.equal(engines.length,2);
});
