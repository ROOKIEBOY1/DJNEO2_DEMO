const {test}=require('node:test');const assert=require('node:assert/strict');
const {GalleryVideoReceiver}=require('../entry/src/main/ets/core/media/GalleryVideoReceiver.ets');
function fixture(){const calls=[];let failCopy=true;let failOpen=true;
  const port={authorize:async sources=>{calls.push(['authorize',sources]);return sources.map(x=>'gallery:'+x);},
    copy:async(source,dest)=>{calls.push(['copy',source,dest]);if(source==='b'&&failCopy)throw Error('copy');},
    open:async uri=>{calls.push(['open',uri]);if(failOpen)throw Error('open');}};
  return {receiver:new GalleryVideoReceiver(),port,calls,allowCopy:()=>{failCopy=false;},allowOpen:()=>{failOpen=false;}};}
test('accept saves all clips before opening the gallery and retries without duplicate authorization or completed copies',async()=>{
  const f=fixture();await assert.rejects(f.receiver.accept(['a','b'],f.port),/copy/);
  assert.equal(f.calls.some(x=>x[0]==='open'),false);f.allowCopy();
  await assert.rejects(f.receiver.accept(['a','b'],f.port),/open/);f.allowOpen();
  await f.receiver.accept(['a','b'],f.port);
  assert.equal(f.calls.filter(x=>x[0]==='authorize').length,1);
  assert.equal(f.calls.filter(x=>x[0]==='copy'&&x[1]==='a').length,1);
  assert.equal(f.calls.at(-1)[0],'open');assert.equal(f.calls.at(-1)[1],'gallery:a');
});
test('declining system save cannot open the gallery and concurrent accepts cannot save twice',async()=>{
  const f=fixture();f.port.authorize=async()=>[];
  await assert.rejects(f.receiver.accept(['a'],f.port),/取消/);
  assert.equal(f.calls.length,0);
  let done;f.port.authorize=()=>new Promise(r=>{done=r;});f.allowOpen();
  const first=f.receiver.accept(['a'],f.port);await assert.rejects(f.receiver.accept(['a'],f.port),/正在/);
  done(['gallery:a']);await first;
});

test('save keeps all clips in the app and never opens the gallery, including repeated saves',async()=>{
  const f=fixture();f.allowCopy();
  const originals=['a','b'];
  await f.receiver.save(originals,f.port);
  await f.receiver.save(originals,f.port);
  assert.deepEqual(originals,['a','b']);
  assert.deepEqual(f.calls,[['authorize',['a','b']],['copy','a','gallery:a'],['copy','b','gallery:b']]);
});

test('save retries only incomplete clips and shares successful copies with legacy accept',async()=>{
  const f=fixture();
  await assert.rejects(f.receiver.save(['a','b'],f.port),/copy/);
  assert.equal(f.calls.some(x=>x[0]==='open'),false);
  f.allowCopy();await f.receiver.save(['a','b'],f.port);
  assert.equal(f.calls.some(x=>x[0]==='open'),false);
  f.allowOpen();await f.receiver.accept(['a','b'],f.port);
  assert.equal(f.calls.filter(x=>x[0]==='authorize').length,1);
  assert.equal(f.calls.filter(x=>x[0]==='copy'&&x[1]==='a').length,1);
  assert.equal(f.calls.filter(x=>x[0]==='copy'&&x[1]==='b').length,2);
  assert.deepEqual(f.calls.at(-1),['open','gallery:a']);
});

test('save cancellation and empty groups leave sources unsaved and save shares the accept concurrency lock',async()=>{
  const f=fixture();
  await assert.rejects(f.receiver.save([],f.port),/尚未取回/);
  assert.deepEqual(f.calls,[]);
  f.port.authorize=async()=>[];
  await assert.rejects(f.receiver.save(['a'],f.port),/取消/);
  assert.deepEqual(f.calls,[]);
  let done;f.port.authorize=()=>new Promise(r=>{done=r;});
  const first=f.receiver.save(['a'],f.port);
  await assert.rejects(f.receiver.save(['a'],f.port),/正在/);
  await assert.rejects(f.receiver.accept(['a'],f.port),/正在/);
  done(['gallery:a']);await first;
  assert.deepEqual(f.calls,[['copy','a','gallery:a']]);
});
