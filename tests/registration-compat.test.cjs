const {test}=require('node:test');const assert=require('node:assert/strict');
const {RegistrationExchange,builtInRegistrationProfile}=require('../entry/src/main/ets/core/transport/RegistrationExchange.ets');
const {encodeDumlFrame,decodeDumlFrame,validDumlFrames}=require('../entry/src/main/ets/core/protocol/DumlCodec.ets');
test('native flight heartbeat uses captured local state, preserving startup state',()=>{
  for(const [remote,expected] of [[[4,4,4],[5,4,4]],[[1,1,1],[1,1,1]]]){
    const reg=new RegistrationExchange(0,builtInRegistrationProfile());const p=new Uint8Array(55);p.set(remote,24);
    reg.observe(encodeDumlFrame(0xe9,0xee,1,0,0x51,0x13,p));
    let seq=0;const packets=reg.poll(0,()=>++seq,()=>++seq);
    const tunnel=packets.at(-1);const frame=decodeDumlFrame(validDumlFrames(tunnel.slice(11,-2))[0]);
    assert.deepEqual([...frame.payload.slice(24,27)],expected);
  }
});
