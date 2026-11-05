const {test}=require('node:test');const assert=require('node:assert/strict');

test('phone API key uses the asset store and consumes its private one-time import file',async()=>{
  const previous=global.__neoKits;let stored;const deleted=[];let fail=false;
  const tag={ALIAS:1,SECRET:2,ACCESSIBILITY:3,CONFLICT_RESOLUTION:4,RETURN_TYPE:5,RETURN_LIMIT:6};
  const key='sk-'+ 'x'.repeat(24);
  global.__neoKits={...previous,
    '@kit.ArkTS':{util:{TextEncoder:{create:()=>({encodeInto:text=>new TextEncoder().encode(text)})},
      TextDecoder:{create:()=>({decodeToString:bytes=>new TextDecoder().decode(bytes)})}}},
    '@kit.CoreFileKit':{fileIo:{accessSync:()=>true,readTextSync:()=>key,unlinkSync:path=>deleted.push(path)}},
    '@kit.AssetStoreKit':{asset:{Tag:tag,Accessibility:{DEVICE_UNLOCKED:2},ConflictResolution:{OVERWRITE:0},ReturnType:{ALL:0},
      add:async attrs=>{if(fail)throw {code:24000009};stored=new Map(attrs);},
      query:async()=>{if(!stored)throw {code:24000002};return [new Map(stored)];},
      remove:async()=>{stored=undefined;}}}
  };
  const path=require.resolve('../entry/src/main/ets/core/platform/CloudVlmKeyStore.ets');delete require.cache[path];
  try{
    const {CloudVlmKeyStore}=require(path);const store=new CloudVlmKeyStore();
    assert.equal(await store.read(),undefined);await assert.rejects(store.save('not-a-key'));
    assert.equal(await store.importPrivateFile('/private/cloud-key-import.txt'),true);
    assert.equal(await store.read(),key);assert.equal(stored.get(tag.ACCESSIBILITY),2);
    assert.deepEqual(deleted,['/private/cloud-key-import.txt']);
    fail=true;await assert.rejects(store.importPrivateFile('/private/second.txt'));
    assert.deepEqual(deleted,['/private/cloud-key-import.txt','/private/second.txt']);
    await store.clear();assert.equal(await store.read(),undefined);
  }finally{global.__neoKits=previous;delete require.cache[path];}
});
