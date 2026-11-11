const {test}=require('node:test');
const assert=require('node:assert/strict');
const {AppController}=require('../entry/src/main/ets/core/domain/AppController.ets');

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

function freshPreview(elapsed,epoch=1){
  return {state:'live',stats:{running:true,waitingForKey:false,recoveryPaused:false,
    decoderEpoch:epoch,lastResetReason:'input-queue-discontinuity',lastAssembledAgeMs:0,
    assembledFrames:100+Math.floor(elapsed/33),submittedFrames:100+Math.floor(elapsed/33),
    decodedFrames:100+Math.floor(elapsed/100),renderedFrames:100+Math.floor(elapsed/100),
    lastRenderedAgeMs:elapsed%100,acceptedRandomAccessFrames:epoch,lastError:''}};
}

function fixture(clock,options={}){
  const c=Object.create(AppController.prototype),events=[],target=12,changes={};
  const hoverAt=options.hoverAt??0;
  const subject=()=>({tracking:clock.elapsed()>=hoverAt,trackingAt:clock.now(),detectionAt:clock.now(),
    candidates:[{id:target}],overlay:[{id:changes.target??target}]});
  const session={sessionId:()=>10,isReliableLinkFresh:()=>true,
    snapshot:()=>({phase:'ready',generation:changes.generation??4,deviceVerified:true,
      downlinkAgeMs:0,videoAgeMs:0,telemetry:{flightAgeMs:0,taskAgeMs:0,cameraAgeMs:0,
        flight:{modeRaw:clock.elapsed()>=hoverAt?26:15,airborne:true,motorsOn:true,...changes.flight},
        task:{payloadHex:'0000000102',phaseRaw:0,modeRaw:0,observedAtMs:clock.now()},
        camera:{recordingCandidate:false,recordStateRaw:0,observedAtMs:clock.now()},subject:subject()}}),
    requestVideoKeyframe:async reason=>events.push({event:'key-request',reason,at:clock.elapsed()})};
  Object.assign(c,{session,agentGeneration:0,busyValue:false,videoSessionEnabled:true,keyframeClock:clock.now,
    flight:{snapshot:()=>({generation:2,takeoffSent:true,takeoffAcknowledged:true,
      landRequested:false,landSent:false,movementActive:false,...changes.flightControl})},
    camera:{snapshot:()=>({recordingRequested:false,operationActive:false})},
    nativeTasks:{snapshot:()=>({busy:false,activeOrUnknown:false,executionObserved:false}),
      canCompleteForHover:()=>({ok:true,data:true})},
    video:{snapshot:()=>options.preview?options.preview(clock.elapsed()):freshPreview(clock.elapsed()),
      restart(){throw Error('handoff must not restart the decoder');}},
    emit(){},log(){},finishAgentObservation:id=>events.push({event:'finish',id,at:clock.elapsed()})});
  const observation=()=>({requestId:'read-'+events.length,sessionId:10,flightGeneration:2,
    controlGeneration:0,requestedAtMs:clock.now(),context:{phase:'ready',airborne:true,tracking:true},
    frame:{currentSubjectId:target,candidates:[{id:target}],sessionId:10,
      capturedAtMs:clock.now(),candidatesObservedAtMs:clock.now(),jpeg:Uint8Array.of(1).buffer,width:2,height:2}});
  c.captureAgentObservation=async waitForScan=>{
    assert.equal(waitForScan,false);events.push({event:'capture',at:clock.elapsed()});
    if(options.capture)return options.capture({clock,observation,events,changes,c});
    return observation();
  };
  return {c,events,changes,observation,
    current:()=>!(options.cancelAt!==undefined&&clock.elapsed()>=options.cancelAt),
    wait:()=>c.waitForCloseupTarget(()=>!(options.cancelAt!==undefined&&clock.elapsed()>=options.cancelAt),target)};
}

test('latest flight replay gives picture recovery its own budget after 7.1 seconds waiting for hover',async()=>{
  await withClock(async clock=>{
    const f=fixture(clock,{hoverAt:7100,preview:elapsed=>{
      if(elapsed<5500)return freshPreview(elapsed);
      if(elapsed<8100){const p=freshPreview(5500);p.stats.lastRenderedAgeMs=elapsed-5500;return p;}
      const p=freshPreview(Math.max(0,elapsed-11000),2);p.stats.lastResetReason='decode-stall';
      if(elapsed<11000){p.state='waiting_key';p.stats.waitingForKey=elapsed<10800;
        p.stats.lastRenderedAgeMs=elapsed-5500;p.stats.renderedFrames=155;}
      return p;
    },capture:async({clock,observation})=>{
      if(clock.elapsed()<11000){await clock.sleep(600);return {...observation(),frame:undefined};}
      return observation();
    }});
    const result=await f.wait();
    assert.equal(result.frame.currentSubjectId,12);
    assert.equal(f.events.filter(e=>e.event==='capture').length,1,'do not consume the capture budget on stalled output');
    assert.ok(f.events.find(e=>e.event==='capture').at>=12000,'require one second of new rendered output');
    assert.ok(clock.elapsed()<15000,'resume after recovery without spending the full deadline');
    assert.ok(f.events.some(e=>e.event==='key-request'&&e.reason==='automatic'));
  });
});

test('hover wait and picture wait have separate 15-second limits within the 30-second absolute budget',async()=>{
  for(const [hoverAt,expectedEnd]of [[Infinity,15000],[7100,22100],[14900,29900]]){
    await withClock(async clock=>{
      const f=fixture(clock,{hoverAt,preview:elapsed=>{
        const p=freshPreview(elapsed,2);p.state='waiting_key';p.stats.waitingForKey=true;
        p.stats.lastResetReason='decode-stall';p.stats.lastRenderedAgeMs=10000+elapsed;
        p.stats.renderedFrames=10;return p;
      }});
      await assert.rejects(f.wait(),/超时|未恢复|未启动/);
      assert.equal(f.events.some(e=>e.event==='capture'),false);
      assert.ok(clock.elapsed()>=expectedEnd&&clock.elapsed()<=expectedEnd+100,
        `hoverAt=${hoverAt}, ended at ${clock.elapsed()}, expected ${expectedEnd}`);
      assert.ok(clock.elapsed()<=30000);
      const requests=f.events.filter(e=>e.event==='key-request');
      assert.ok(requests.length<=3,'reuse the global automatic attempt limit');
      if(Number.isFinite(hoverAt))assert.equal(requests.length,3,'the full picture wait reuses all three bounded automatic attempts');
      for(let i=1;i<requests.length;i++)assert.ok(requests[i].at-requests[i-1].at>=5000);
      assert.ok(requests.every(e=>e.reason==='automatic'));
    });
  }
});

test('fresh-looking timestamps with frozen counters or repeatedly changing decoder epochs never satisfy stable output',async()=>{
  for(const kind of ['frozen-count','changing-epoch']){
    await withClock(async clock=>{
      const f=fixture(clock,{preview:elapsed=>{
        const p=freshPreview(elapsed,kind==='changing-epoch'?1+Math.floor(elapsed/500):1);
        if(kind==='frozen-count')p.stats.renderedFrames=100;
        p.stats.lastRenderedAgeMs=0;return p;
      }});
      await assert.rejects(f.wait(),/超时|未恢复|未启动/);
      assert.equal(f.events.some(e=>e.event==='capture'),false,kind);
      assert.ok(clock.elapsed()>=15000&&clock.elapsed()<=15100);
    });
  }
});

test('a failed image readback requires another full second of new output and keeps polling the existing recovery policy',async()=>{
  await withClock(async clock=>{
    let captures=0,failedAt;
    const f=fixture(clock,{capture:async({clock,observation,events})=>{
      if(++captures===1){
        await clock.sleep(600);failedAt=clock.elapsed();events.push({event:'capture-failed',at:failedAt});
        return {...observation(),frame:undefined};
      }
      return observation();
    }});
    const poll=f.c.pollVideoKeyframeRecovery.bind(f.c);
    f.c.pollVideoKeyframeRecovery=()=>{f.events.push({event:'policy-poll',at:clock.elapsed()});poll();};
    await f.wait();
    const reads=f.events.filter(e=>e.event==='capture');
    assert.equal(reads.length,2);assert.ok(reads[0].at>=1000);
    assert.ok(reads[1].at>=failedAt+1000,'the failed read cannot reuse the previous stability window');
    assert.ok(f.events.some(e=>e.event==='policy-poll'&&e.at>=failedAt));
    assert.equal(f.events.filter(e=>e.event==='finish').length,1,'finish the discarded observation exactly once');
    assert.ok(clock.elapsed()<4000);
  });
});

test('cancellation, a reconnected generation or an explicit different target interrupts picture recovery immediately',async()=>{
  for(const kind of ['cancel','generation','target']){
    await withClock(async clock=>{
      const f=fixture(clock,{cancelAt:kind==='cancel'?1500:undefined,preview:elapsed=>{
        const p=freshPreview(elapsed);p.stats.renderedFrames=100;p.stats.lastRenderedAgeMs=elapsed;return p;
      }});
      const snapshot=f.c.session.snapshot;
      f.c.session.snapshot=()=>{
        if(clock.elapsed()>=1500){
          if(kind==='generation')f.changes.generation=5;
          if(kind==='target')f.changes.target=11;
        }
        return snapshot();
      };
      await assert.rejects(f.wait(),/取消|变化|其他人|失效/);
      assert.equal(f.events.some(e=>e.event==='capture'),false,kind);
      assert.ok(clock.elapsed()>=1500&&clock.elapsed()<=1600,kind);
    });
  }
});

test('hover, identity and session changes while awaiting the image cannot authorize that observation',async()=>{
  for(const kind of ['flight','target','generation']){
    await withClock(async clock=>{
      const f=fixture(clock,{capture:async({observation,changes})=>{
        const obs=observation();
        if(kind==='flight')changes.flight={airborne:false,motorsOn:false};
        if(kind==='target')changes.target=11;
        if(kind==='generation')changes.generation=5;
        return obs;
      }});
      await assert.rejects(f.wait(),/取消|变化|其他人|悬停|失效/);
      assert.equal(f.events.filter(e=>e.event==='capture').length,1,kind);
      assert.equal(f.events.filter(e=>e.event==='finish').length,1,kind);
      assert.ok(clock.elapsed()>=1000&&clock.elapsed()<2000,kind);
    });
  }
});

function controllerWithReadback(backend){
  const Module=require('node:module');
  const modulePath=require.resolve('../entry/src/main/ets/core/domain/AppController.ets');
  const originalLoad=Module._load,originalCached=require.cache[modulePath];
  delete require.cache[modulePath];
  Module._load=function(name,parent,main){
    if(name==='libneovideo.so')return backend;
    return originalLoad.call(this,name,parent,main);
  };
  try{return require(modulePath).AppController;}
  finally{
    Module._load=originalLoad;delete require.cache[modulePath];
    if(originalCached)require.cache[modulePath]=originalCached;
  }
}

test('real frame readback spends only the remaining phase budget and preserves the default 600 milliseconds',async()=>{
  for(const remaining of [97,undefined]){
    await withClock(async clock=>{
      const reads=[];let requests=0;
      const IsolatedController=controllerWithReadback({requestFrame(){requests++;return 7;},
        takeFrame(ticket){assert.equal(ticket,7);reads.push(clock.elapsed());return undefined;}});
      const f=fixture(clock),budget=remaining??600;
      await assert.rejects(IsolatedController.prototype.captureVlmFrame.call(f.c,
        remaining===undefined?undefined:clock.now()+remaining),/取帧超时/);
      assert.equal(requests,1);assert.equal(clock.elapsed(),budget);
      assert.equal(f.c.vlmFramePending,false,'the real operation settles and releases ownership at its own deadline');
      assert.equal(reads[0],0);assert.ok(reads.at(-1)<budget);
      assert.ok(budget-reads.at(-1)<=16,'the final polling sleep is capped to the actual remaining time');
    });
  }
});
