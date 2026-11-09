const {test}=require('node:test');const assert=require('node:assert/strict');
const calls=[];let failCopy=false;
global.__neoKits={...global.__neoKits,
  '@kit.AbilityKit':{wantConstant:{Flags:{FLAG_AUTH_READ_URI_PERMISSION:1}}},
  '@kit.CoreFileKit':{fileIo:{OpenMode:{READ_ONLY:1,READ_WRITE:2,TRUNC:4},
    open:async(uri,mode)=>{calls.push(['open',uri,mode]);return {fd:uri};},
    close:async file=>{calls.push(['close',file.fd]);},
    copyFile:async(src,dst)=>{calls.push(['copy',src,dst]);if(failCopy)throw Error('write failed');}}},
  '@kit.MediaLibraryKit':{photoAccessHelper:{PhotoType:{VIDEO:2},getPhotoAccessHelper:()=>({
    showAssetsCreationDialog:async(sources,configs)=>{calls.push(['authorize',sources,configs]);return ['file://media/1'];},
    release:async()=>{calls.push(['release']);}})}}};
delete require.cache[require.resolve('../entry/src/main/ets/core/platform/SystemGallery.ets')];
const {systemGalleryPort}=require('../entry/src/main/ets/core/platform/SystemGallery.ets');
test('system gallery authorizes videos, copies through file descriptors and closes them before handoff',async()=>{
  const port=systemGalleryPort({startAbility:async want=>calls.push(['launch',want])});
  assert.deepEqual(await port.authorize(['original.mp4']),['file://media/1']);
  assert.equal(calls[0][2][0].photoType,2);assert.equal(calls[1][0],'release');
  await port.copy('original.mp4','file://media/1');await port.open('file://media/1');
  assert.deepEqual(calls.slice(2,7).map(x=>x[0]),['open','open','copy','close','close']);
  assert.equal(calls.at(-1)[1].uri,'file://media/1');
  assert.equal(calls.at(-1)[1].bundleName,'com.huawei.hmos.photos');
});
test('copy errors release both descriptors and launch errors remain retryable',async()=>{
  calls.length=0;failCopy=true;
  const port=systemGalleryPort({startAbility:async()=>{throw Error('launch');}});
  await assert.rejects(port.copy('original.mp4','file://media/1'),/write failed/);
  assert.deepEqual(calls.slice(-2),[['close','file://media/1'],['close','original.mp4']]);
  await assert.rejects(port.open('file://media/1'),/已保存到图库/);failCopy=false;
});
