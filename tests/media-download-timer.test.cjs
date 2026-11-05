const {test}=require('node:test');
const assert=require('node:assert/strict');

test('media download never clears another component timer with ID zero', async () => {
  const savedKits=global.__neoKits;
  const savedSet=global.setTimeout,savedClear=global.clearTimeout;
  const timers=new Set([0]);let nextId=1;
  global.setTimeout=()=>{const id=nextId++;timers.add(id);return id;};
  global.clearTimeout=id=>timers.delete(id);
  const listeners={};
  global.__neoKits={...savedKits,
    '@kit.CoreFileKit':{fileIo:{accessSync:()=>false}},
    '@kit.NetworkKit':{socket:{constructTCPSocketInstance:()=>({
      on:(name,fn)=>{listeners[name]=fn;},off:name=>{delete listeners[name];},
      bind:async()=>{},connect:async()=>{},close:async()=>{},
      send:async()=>{
        const bytes=Buffer.from('HTTP/1.1 500 Failed\r\nContent-Length: 0\r\n\r\n');
        listeners.message({message:bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.length)});
      }
    })}}
  };
  const modulePath=require.resolve('../entry/src/main/ets/core/media/MediaDownloader.ets');
  const cached=require.cache[modulePath];delete require.cache[modulePath];
  try {
    const {MediaDownloader}=require(modulePath);
    const name='DJI_20261105182000_0001_D.JPG';
    await assert.rejects(new MediaDownloader().download({name,path:'DCIM/DJI_001/'+name,kind:'photo'},
      '/download',{localAddress:'192.168.2.2',handle:{bindSocket:async()=>{}}}),/HTTP/);
    assert.equal(timers.has(0),true,'the pre-existing App scan interval must survive HTTP download cleanup');
    assert.deepEqual([...timers],[0],'download must clean up only timers it created');
  } finally {
    global.__neoKits=savedKits;global.setTimeout=savedSet;global.clearTimeout=savedClear;
    if(cached)require.cache[modulePath]=cached;else delete require.cache[modulePath];
  }
});
