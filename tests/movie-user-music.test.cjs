const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const asset=new Uint8Array(fs.readFileSync(require('node:path').resolve(__dirname,
  '../entry/src/main/resources/rawfile/movie-bgm-user-v1.mp3')));
const destination='/files/movie-bgm-user-v1.mp3';

async function withMusicFiles(initial,run){
  const previous=global.__neoKits;const sizes=new Map(Object.entries(initial)),reads=[],writes=[],renames=[];
  global.__neoKits={...previous,'@kit.CoreFileKit':{fileIo:{
    statSync(path){if(!sizes.has(path))throw Error('missing');return {size:sizes.get(path)};},
    renameSync(from,to){renames.push([from,to]);sizes.set(to,sizes.get(from));sizes.delete(from);}
  }}};
  const modulePath=require.resolve('../entry/src/main/ets/core/platform/NativeMovieExport.ets');delete require.cache[modulePath];
  try{
    const {NativeMovieFiles}=require(modulePath);const files=new NativeMovieFiles();
    files.writeBytes=(path,bytes)=>{writes.push({path,bytes:bytes.slice()});sizes.set(path,bytes.byteLength);};
    const context={resourceManager:{async getRawFileContent(name){reads.push(name);return asset;}}};
    await run({files,context,reads,writes,renames,sizes});
  }finally{global.__neoKits=previous;delete require.cache[modulePath];}
}

test('new music is copied from the supplied clip even when the old Titan private cache exists',async()=>{
  await withMusicFiles({'/files/titan-scott-buckley-v1.mp3':7034419},async f=>{
    assert.equal(await f.files.prepareMusic(f.context,'/files'),destination);
    assert.deepEqual(f.reads,['movie-bgm-user-v1.mp3']);
    assert.equal(f.writes.length,1);assert.deepEqual(f.writes[0].bytes,asset);
    assert.deepEqual(f.renames,[[destination+'.part',destination]]);
    assert.equal(f.sizes.get('/files/titan-scott-buckley-v1.mp3'),7034419);
  });
});

test('a complete copy of the new music is reused without loading or rewriting the resource',async()=>{
  await withMusicFiles({[destination]:asset.length},async f=>{
    assert.equal(await f.files.prepareMusic(f.context,'/files'),destination);
    assert.deepEqual(f.reads,[]);assert.deepEqual(f.writes,[]);assert.deepEqual(f.renames,[]);
  });
});

test('a truncated new music copy is replaced atomically before it is used',async()=>{
  await withMusicFiles({[destination]:asset.length-1,[destination+'.part']:200},async f=>{
    assert.equal(await f.files.prepareMusic(f.context,'/files'),destination);
    assert.deepEqual(f.reads,['movie-bgm-user-v1.mp3']);assert.equal(f.sizes.get(destination),asset.length);
    assert.equal(f.sizes.has(destination+'.part'),false);
  });
});

test('an incomplete bundled music resource is rejected without publishing a private copy',async()=>{
  await withMusicFiles({},async f=>{
    f.context.resourceManager.getRawFileContent=async()=>asset.slice(0,-1);
    await assert.rejects(f.files.prepareMusic(f.context,'/files'),/配乐.*不完整/);
    assert.deepEqual(f.writes,[]);assert.deepEqual(f.renames,[]);
  });
});
