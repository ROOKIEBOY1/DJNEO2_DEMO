const {test}=require('node:test');const assert=require('node:assert/strict');

test('phone cloud client posts directly over HTTPS and rejects cancelled, redirected or failed requests',async()=>{
  const previous=global.__neoKits;const requests=[];let mode='ok',internet=true,drone=false;let cancelReject;
  global.__neoKits={...previous,
    '@kit.ArkTS':{util:{TextDecoder:{create:()=>({decodeToString:bytes=>new TextDecoder().decode(bytes)})},
      Base64Helper:class{encodeToStringSync(bytes){return Buffer.from(bytes).toString('base64');}}}},
    '@kit.NetworkKit':{connection:{NetCap:{NET_CAPABILITY_INTERNET:12},getDefaultNet:async()=>({netId:100}),
      getNetCapabilities:async()=>({networkCap:internet?[12,16]:[]}),
      getConnectionProperties:async()=>({interfaceName:'hotspot0',linkAddresses:[{address:{address:drone?'192.168.2.2':'192.168.43.2'}}]})}},
    '@kit.RemoteCommunicationKit':{rcp:{Request:class{constructor(url,method,headers,content,cookies,range,configuration){Object.assign(this,{url,method,headers,content,configuration});}},
      createSession:()=>({close(){},cancel(){if(cancelReject)cancelReject({code:1007900992});},fetch:async request=>{
        requests.push(request);if(mode==='pending')return new Promise((resolve,reject)=>{cancelReject=reject;});
        const bytes=new TextEncoder().encode(JSON.stringify({choices:[{finish_reason:'stop',message:{content:'{"action":"photo"}'}}]}));
        request.destination(mode==='oversize'?new ArrayBuffer(65537):bytes.buffer);
        return {statusCode:mode==='redirect'?302:mode==='auth'?401:mode==='quota'?429:200};
      }})}},
    '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){},error(){}}}
  };
  const modulePath=require.resolve('../entry/src/main/ets/core/platform/CloudVlmClient.ets');delete require.cache[modulePath];
  try{
    const {CloudVlmClient}=require(modulePath);const client=new CloudVlmClient({read:async()=> 'fake-test-key'});
    const observation=()=>({requestId:'cloud-1',sessionId:10,flightGeneration:2,requestedAtMs:Date.now(),context:{airborne:true}});
    const response=await client.request(observation(),'拍照',()=>true);
    assert.equal(response.command.action,'photo');assert.equal(requests[0].url,'https://api.deepseek.com/chat/completions');
    assert.equal(requests[0].configuration.transfer.autoRedirect,false);
    assert.equal(requests[0].headers.Authorization,'Bearer fake-test-key');
    assert.ok(requests[0].configuration.transfer.timeout.transferMs > 20000);
    assert.ok(requests[0].configuration.transfer.timeout.transferMs <= 60000);
    const slowText={...observation(),requestedAtMs:Date.now()-30000};
    assert.equal((await client.request(slowText,'拍照',()=>true)).command.action,'photo');
    const visual={...observation(),frame:{jpeg:new ArrayBuffer(4),candidates:[]}};
    await client.request(visual,'拍照',()=>true);
    assert.ok(requests.at(-1).configuration.transfer.timeout.transferMs <= 20000);
    const expiredVisual={...visual,requestedAtMs:Date.now()-21000};
    const visualCount=requests.length;
    await assert.rejects(client.request(expiredVisual,'拍照',()=>true),/过期/);
    assert.equal(requests.length,visualCount);
    internet=false;await assert.rejects(client.request(observation(),'拍照',()=>true),/网络|热点|互联网/);internet=true;
    drone=true;await assert.rejects(client.request(observation(),'拍照',()=>true),/网络|热点|互联网/);drone=false;
    mode='redirect';await assert.rejects(client.request(observation(),'拍照',()=>true),/跳转|302/);
    mode='auth';await assert.rejects(client.request(observation(),'拍照',()=>true),/密钥|401/);
    mode='quota';await assert.rejects(client.request(observation(),'拍照',()=>true),/频繁|额度/);
    mode='oversize';await assert.rejects(client.request(observation(),'拍照',()=>true),/大小限制/);
    const expired={...observation(),requestedAtMs:Date.now()-61000};
    const count=requests.length;await assert.rejects(client.request(expired,'拍照',()=>true),/过期/);assert.equal(requests.length,count);
    mode='pending';let current=true;
    const pending=client.request(observation(),'拍照',()=>current);
    await new Promise(resolve=>setImmediate(resolve));current=false;
    await assert.rejects(pending,/取消|变化/);
    client.close();
  }finally{global.__neoKits=previous;delete require.cache[modulePath];}
});
