const {test}=require('node:test');
const assert=require('node:assert/strict');

function withFiles(run){
  const previous=global.__neoKits;const writes=[];
  let record={version:1,sourceKey:'titan-v1|["r","/files/a.mp4"]',sources:['/files/a.mp4'],
    revision:'r',outputPath:'/files/neo_movie_old.mp4',durationMs:12000,size:100};
  global.__neoKits={...previous,'@kit.CoreFileKit':{fileIo:{
    statSync:()=>({size:100}),readTextSync:()=>JSON.stringify(record),renameSync(){}
  }},'@kit.ArkTS':{util:{TextEncoder:{create:()=>({encodeInto:text=>new TextEncoder().encode(text)})}}}};
  const modulePath=require.resolve('../entry/src/main/ets/core/platform/NativeMovieExport.ets');
  delete require.cache[modulePath];
  try{
    const {NativeMovieFiles}=require(modulePath);const files=new NativeMovieFiles();
    files.revision=()=> 'r';files.validMovie=()=>true;files.writeBytes=()=>writes.push('write');
    run(files,record,writes,value=>{record=value;});
  }finally{global.__neoKits=previous;delete require.cache[modulePath];}
}

test('legacy movie template cannot be restored by latest or explicit source cache',()=>withFiles((files,record)=>{
  assert.equal(files.loadLatest('/files'),undefined);
  assert.equal(files.loadCompleted('/files',record.sourceKey),undefined);
}));

test('legacy completed snapshot cannot republish the broken output into the cache',()=>withFiles((files,record,writes)=>{
  files.saveCompleted('/files',{...record,stage:'completed'},'r');
  assert.deepEqual(writes,[]);
}));

test('current user-provided music template cache can be saved and restored',()=>withFiles((files,record,writes,setRecord)=>{
  const current={...record,sourceKey:'user-bgm-v5|["r","/files/a.mp4"]'};setRecord(current);
  files.saveCompleted('/files',{...current,stage:'completed'},'r');
  assert.equal(writes.length,2);
  assert.deepEqual(files.loadLatest('/files'),current);
  assert.deepEqual(files.loadCompleted('/files',current.sourceKey),current);
}));

test('previous Titan movie caches cannot mask the user-provided replacement music',()=>withFiles((files,record,writes,setRecord)=>{
  for(const template of ['titan-v1','titan-avc-v2','titan-climax-v3','titan-13s-v4']){
    const previous={...record,sourceKey:template+'|["r","/files/a.mp4"]'};setRecord(previous);
    assert.equal(files.loadLatest('/files'),undefined);
    assert.equal(files.loadCompleted('/files',previous.sourceKey),undefined);
    files.saveCompleted('/files',{...previous,stage:'completed'},'r');
    assert.deepEqual(writes,[]);
  }
}));
