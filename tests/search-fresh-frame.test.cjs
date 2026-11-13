const {test}=require('node:test');
const assert=require('node:assert/strict');

async function withClock(body){
  let now=10000,nextId=1,scheduled,active=true;
  const timers=new Map();
  const realNow=Date.now,realTimeout=global.setTimeout,realClear=global.clearTimeout;
  const schedule=()=>{if(scheduled===undefined)scheduled=setImmediate(flush);};
  const flush=()=>{
    scheduled=undefined;if(!active||timers.size===0)return;
    const [id,timer]=[...timers].sort((a,b)=>a[1].at-b[1].at||a[0]-b[0])[0];
    timers.delete(id);now=Math.max(now,timer.at);timer.callback();
    if(timers.size>0)schedule();
  };
  Date.now=()=>now;
  global.setTimeout=(callback,delay)=>{
    const id=nextId++;timers.set(id,{at:now+delay,callback});schedule();return id;
  };
  global.clearTimeout=id=>timers.delete(id);
  try{return await body({now:()=>now,elapsed:()=>now-10000,
    sleep:delay=>new Promise(resolve=>setTimeout(resolve,delay))});}
  finally{
    active=false;if(scheduled!==undefined)clearImmediate(scheduled);
    Date.now=realNow;global.setTimeout=realTimeout;global.clearTimeout=realClear;
  }
}

function controllerWithReadback(backend,image){
  const Module=require('node:module');
  const modulePath=require.resolve('../entry/src/main/ets/core/domain/AppController.ets');
  const originalLoad=Module._load,originalCached=require.cache[modulePath];
  delete require.cache[modulePath];
  Module._load=function(name,parent,main){
    if(name==='libneovideo.so')return backend;
    if(name==='@kit.ImageKit')return {image};
    return originalLoad.call(this,name,parent,main);
  };
  try{return require(modulePath).AppController;}
  finally{
    Module._load=originalLoad;delete require.cache[modulePath];
    if(originalCached)require.cache[modulePath]=originalCached;
  }
}

function fixture(clock,options={}){
  const requests=[],reads=[],encoded=[],changes={};
  const backend={requestFrame(){const ticket=requests.length+1;requests.push({ticket,at:clock.elapsed()});return ticket;},
    takeFrame(ticket){reads.push({ticket,at:clock.elapsed()});
      return options.read?options.read({ticket,clock,changes,reads}):{
        width:2,height:2,rgba:new ArrayBuffer(16),capturedAtMs:ticket===1?9930:clock.now()};}};
  const image={PixelMapFormat:{RGBA_8888:1},
    async createPixelMap(rgba){encoded.push(rgba);return {release:async()=>{}};},
    createImagePacker(){return {packToData:async()=>Uint8Array.of(1).buffer,release:async()=>{}};}};
  const Controller=controllerWithReadback(backend,image),c=Object.create(Controller.prototype);
  const subject=()=>({tracking:false,overlay:[],candidates:[],detectionAt:clock.now()});
  Object.assign(c,{session:{sessionId:()=>changes.sessionId??10,isReliableLinkFresh:()=>true,
      snapshot:()=>({phase:'ready',generation:4,telemetry:{subject:subject()}})},
    video:{snapshot:()=>({state:'live',stats:{decoderEpoch:changes.epoch??1}})},
    flight:{snapshot:()=>({generation:2})},nativeTasks:{snapshot:()=>({})},
    camera:{snapshot:()=>({recordingRequested:false})},nativeConfig:{},agentGeneration:0,
    agentRequestSequence:0,log(){}});
  return {c,requests,reads,encoded,changes,read:(...args)=>c.captureVlmFrame(...args)};
}

test('settled search discards a queued frame 70 ms old and renews the ticket until fresh output arrives',async()=>{
  await withClock(async clock=>{
    const f=fixture(clock);
    const result=await f.read(undefined,clock.now());
    assert.ok(result.capturedAtMs>=10000,'a pre-settle decoded output cannot authorize search');
    assert.equal(f.requests.length,2,'discarded output requires a new native ticket');
    assert.deepEqual(f.reads.map(read=>read.ticket),[1,2]);
    assert.equal(f.encoded.length,1,'only the accepted frame is JPEG encoded');
    assert.equal(clock.elapsed(),16);
    assert.equal(f.c.vlmFramePending,false);
  });
});

test('repeated pre-settle outputs exhaust the original 600 ms or shorter external deadline without encoding',async()=>{
  for(const budget of [600,97])await withClock(async clock=>{
    const f=fixture(clock,{read:()=>({width:2,height:2,rgba:new ArrayBuffer(16),capturedAtMs:9930})});
    await assert.rejects(f.read(budget===600?undefined:clock.now()+budget,clock.now()),/超时/);
    assert.equal(clock.elapsed(),budget,'renewing tickets cannot renew the total deadline');
    assert.equal(f.encoded.length,0);
    assert.ok(f.requests.length>1);
    assert.ok(f.reads.every(read=>read.at<budget));
    assert.equal(f.c.vlmFramePending,false);
  });
});

test('cancellation while waiting for fresh output stops further readback and releases ownership',async()=>{
  await withClock(async clock=>{
    const f=fixture(clock);
    const checkCurrent=()=>{if(f.reads.length)throw Error('search cancelled');};
    await assert.rejects(f.read(undefined,clock.now(),checkCurrent),/search cancelled/);
    assert.equal(f.reads.length,1);
    assert.equal(f.encoded.length,0);
    assert.equal(f.c.vlmFramePending,false);
  });
});

test('session or decoder epoch changes during the fresh-frame wait cannot authorize queued output',async()=>{
  for(const kind of ['sessionId','epoch'])await withClock(async clock=>{
    const f=fixture(clock,{read:({ticket,changes})=>{
      changes[kind]=kind==='sessionId'?11:2;
      return {width:2,height:2,rgba:new ArrayBuffer(16),capturedAtMs:ticket===1?9930:clock.now()};
    }});
    await assert.rejects(f.read(undefined,clock.now()),/变化|断开|超时|解码/);
    assert.equal(f.encoded.length,0,kind);
    assert.equal(f.reads.length,1,kind);
    assert.equal(f.c.vlmFramePending,false);
  });
});

test('ordinary callers without a minimum capture time still accept the first matching queued frame',async()=>{
  await withClock(async clock=>{
    const f=fixture(clock),result=await f.read();
    assert.equal(result.capturedAtMs,9930);
    assert.equal(f.requests.length,1);
    assert.equal(f.encoded.length,1);
    assert.equal(clock.elapsed(),0);
  });
});

test('observation capture forwards the exact frame deadline, minimum time and cancellation callback',async()=>{
  await withClock(async clock=>{
    const f=fixture(clock),calls=[];
    const deadline=clock.now()+97,minimum=clock.now(),checkCurrent=()=>{};
    const frame={jpeg:new ArrayBuffer(1),capturedAtMs:minimum};
    f.c.captureVlmFrame=async(...args)=>{calls.push(args);return frame;};
    const observation=await f.c.captureAgentObservation(false,deadline,minimum,checkCurrent);
    assert.deepEqual(calls,[[deadline,minimum,checkCurrent]]);
    assert.equal(observation.frame,frame);
  });
});

test('real observation capture waits past queued output and propagates cancellation instead of making an image-less request',async()=>{
  await withClock(async clock=>{
    const f=fixture(clock);
    const observation=await f.c.captureAgentObservation(false,undefined,clock.now(),()=>{});
    assert.ok(observation.frame.capturedAtMs>=10000);
    assert.equal(f.encoded.length,1);
  });
  await withClock(async clock=>{
    const f=fixture(clock);
    await assert.rejects(f.c.captureAgentObservation(false,undefined,clock.now(),()=>{
      if(f.reads.length)throw Error('search cancelled');
    }),/search cancelled/);
    assert.equal(f.reads.length,1);
    assert.equal(f.encoded.length,0);
    assert.equal(f.c.latestAgentRequestId,undefined);
  });
});
