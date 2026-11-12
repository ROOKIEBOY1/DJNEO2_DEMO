const {test}=require('node:test');const assert=require('node:assert/strict');
const {TelemetryStore}=require('../entry/src/main/ets/core/domain/TelemetryStore.ets');
const {encodeDumlFrame}=require('../entry/src/main/ets/core/protocol/DumlCodec.ets');
const active='ff020000001100000000020000030000000000';
function nav(payload=active,o={}){return encodeDumlFrame(o.sender??0x92,o.receiver??2,1,o.flags??0,o.set??10,o.id??0x5a,new Uint8Array(Buffer.from(payload,'hex')));}
test('0A/5A decodes the official navigation fields and rejects other routes/layouts',()=>{
 const s=new TelemetryStore();const e=s.observeEvent(nav(),1000).navigation;assert.ok(e);
 assert.equal(e.modeRaw,8);assert.equal(e.navigationExecuting,true);assert.equal(e.multiQuickShotEnabled,true);
 assert.equal(e.goHomeExecuting,false);assert.equal(e.goHomeStageRaw,0);assert.equal(e.payloadHex,active);
 const returning=s.observeEvent(nav('ff020000000700003100020000000000000000'),1100).navigation;
 assert.equal(returning.modeRaw,3);assert.equal(returning.navigationExecuting,true);assert.equal(returning.goHomeExecuting,true);
 assert.equal(returning.goHomeStageRaw,3);assert.equal(returning.multiQuickShotEnabled,false);
 assert.equal(s.snapshot(1101).navigation.observedAtMs,1100);
 for(const o of [{sender:3},{receiver:3},{flags:128},{id:0x39},{set:0x23}])assert.equal(s.observeEvent(nav(active,o),1200).navigation,undefined);
 for(const p of [active.slice(0,-2),active+'00','fe'+active.slice(2),'ff030000'+active.slice(8)])assert.equal(s.observeEvent(nav(p),1200).navigation,undefined);
 const bad=nav();bad[15]^=1;assert.equal(s.observeEvent(bad,1200).navigation,undefined);
});
test('QuickShot in-action is byte 9 of 0A/39, independent of byte-8 exception and navigation Multi flag',()=>{
 const s=new TelemetryStore();
 for(const [code,inAction]of [[0,1],[11,0],[1,0],[0,0]]){
  const p=new Uint8Array(10);p[8]=code;p[9]=inAction;
  const e=s.observeEvent(encodeDumlFrame(0x92,2,code+1,0,10,0x39,p),1000).taskException;
  assert.equal(e.inAction,inAction!==0);assert.equal(e.codeRaw,code);
 }
});
test('FC OSD speed uses signed int16 at 18/20/22 scaled by 0.1m/s and is observable per frame',()=>{
 const s=new TelemetryStore(),p=new Uint8Array(36),v=new DataView(p.buffer);
 v.setInt16(18,-12,true);v.setInt16(20,23,true);v.setInt16(22,-4,true);p[30]=15;p[32]=12;
 const f=s.observeEvent(encodeDumlFrame(3,2,1,0,3,0x43,p),1000).flight;assert.ok(f);
 assert.equal(f.velocityXMetersPerSecond,-1.2);assert.equal(f.velocityYMetersPerSecond,2.3);assert.equal(f.velocityZMetersPerSecond,-0.4);
 assert.equal(f.modeRaw,15);assert.equal(f.airborne,true);assert.equal(f.motorsOn,true);
});
