const {test}=require('node:test');const assert=require('node:assert/strict');
const output=new Map();
global.__neoKits={...global.__neoKits,
  '@kit.CoreFileKit':{fileIo:{OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},accessSync:p=>output.has(p),mkdirSync(){},
    openSync:p=>({fd:p}),writeSync:(fd,data)=>output.set(fd,new Uint8Array(data)),fsyncSync(){},closeSync(){},
    renameSync:(src,dst)=>{output.set(dst,output.get(src));output.delete(src);},unlinkSync:p=>output.delete(p)}},
  '@kit.CryptoArchitectureKit':{cryptoFramework:{createMd:()=>({update:async()=>{},digest:async()=>({data:new Uint8Array(32)})})}}};
delete require.cache[require.resolve('../entry/src/main/ets/core/media/MediaDownloader.ets')];
const {MediaDownloader,interruptedMediaTransfer}=require('../entry/src/main/ets/core/media/MediaDownloader.ets');
const {CancellationToken}=require('../entry/src/main/ets/core/domain/OperationResult.ets');
const video=Buffer.concat([Buffer.from([0,0,0,8,...Buffer.from('ftyp')]),Buffer.from([0,0,0,8,...Buffer.from('moov')]),
  Buffer.from([0,0,0,24,...Buffer.from('mdat')]),Buffer.alloc(16)]);
const entry={name:'DJI_20261105214416_0146_D.MP4',path:'DCIM/DJI_001/DJI_20261105214416_0146_D.MP4',kind:'video',size:40};
function response(range,etag='"one"'){
  const [,start,end]=/bytes=(\d+)-(\d+)/.exec(range).map(Number);
  return {status:206,headers:new Map([['content-length',`${end-start+1}`],['content-range',`bytes ${start}-${end}/40`],['etag',etag]]),body:new Uint8Array(video.subarray(start,end+1))};
}
test('interrupted video range retries only that range and retains previously verified bytes',async()=>{
  output.clear();const calls=[];let failed=false;
  const downloader=new MediaDownloader(async(_selection,_target,range)=>{
    calls.push(range);if(range==='bytes=8-15'&&!failed){failed=true;throw interruptedMediaTransfer('closed');}return response(range);});
  const result=await downloader.download(entry,'/out',{});
  assert.equal(result.size,40);assert.deepEqual(Buffer.from(output.get(result.path)),video);
  assert.deepEqual(calls,['bytes=0-7','bytes=8-15','bytes=8-15','bytes=16-23','bytes=24-31','bytes=32-39']);
});
test('bounded retries, cancellation and integrity failures never publish a partial original',async()=>{
  output.clear();let attempts=0;
  const downloader=new MediaDownloader(async()=>{attempts++;throw interruptedMediaTransfer('closed');});
  await assert.rejects(downloader.download(entry,'/out',{}));assert.equal(attempts,3);assert.equal(output.size,0);
  const token=new CancellationToken(1);attempts=0;
  await assert.rejects(new MediaDownloader(async()=>{attempts++;token.cancel();throw interruptedMediaTransfer('closed');}).download(entry,'/out',{},token));
  assert.equal(attempts,1);
  attempts=0;
  await assert.rejects(new MediaDownloader(async(_s,_t,range)=>{attempts++;return response(range,attempts===1?'"one"':'"changed"');}).download(entry,'/out',{}),/ETag changed/);
  assert.equal(attempts,2);assert.equal(output.size,0);
});
