const { test } = require('node:test');
const assert = require('node:assert/strict');
const core = '../entry/src/main/ets/core/';
const { parseVoiceCommand, VoiceCommandAdapter } = require(core + 'domain/VoiceCommandAdapter.ets');

test('Chinese directions, durations and physical units match original parser', () => {
  for (const [text, direction, amount, unit] of [
    ['请无人机往前飞两秒。', 'forward', 2, 'seconds'], ['向后飞十米', 'backward', 10, 'meters'],
    ['上升一点', 'up', .5, 'seconds'], ['向下飞五十厘米', 'down', .5, 'meters'],
    ['左移半秒', 'left', .5, 'seconds'], ['向右飞０．５秒', 'right', .5, 'seconds'],
    ['向左转九十度', 'turn_left', 90, 'degrees'], ['右转一下', 'turn_right', .5, 'seconds']
  ]) {
    const result = parseVoiceCommand(text);
    assert.ok(result, text);
    assert.equal(result.direction, direction, text);
    assert.equal(result.amount, amount, text);
    assert.equal(result.unit, unit, text);
  }
});

test('reject negative, mixed, excessive and mismatched-unit commands', () => {
  for (const text of ['不要起飞', '前进两秒然后降落', '左转十米', '上升九十度', '前进-1秒', '前进十一秒', '随便飞', '前进0秒']) {
    assert.equal(parseVoiceCommand(text), undefined, text);
  }
});

test('task settings and media vocabulary', () => {
  for (const [text, kind] of [['跟随我','follow_start'],['停止跟随','follow_stop'],['滑动变焦','dolly_start'],
    ['准备滑动变焦','dolly_prepare'],['全身','dolly_framing'],['倍率三倍','dolly_zoom'],
    ['渐远关闭','dolly_retreat'],['相册','media_list'],['下载最新录像','download_video'],['再次起飞','takeoff_again']]) {
    assert.equal(parseVoiceCommand(text)?.kind, kind, text);
  }
  assert.equal(parseVoiceCommand('环绕五米')?.radiusMeters, 5);
  assert.equal(parseVoiceCommand('环绕一米'), undefined);
});

test('dangerous actions need independent matching confirmation within 10s', () => {
  let now = 1000;
  const adapter = new VoiceCommandAdapter(() => now);
  const sent = [];
  adapter.setListener(c => sent.push(c.kind)); adapter.setEnabled(true);
  adapter.acceptTranscript('跟随我'); assert.equal(sent.length, 0);
  adapter.acceptTranscript('确认起飞'); assert.equal(sent.length, 0);
  adapter.acceptTranscript('确认'); assert.deepEqual(sent, ['follow_start']);
  adapter.acceptTranscript('确认'); assert.equal(sent.length, 1);
  adapter.acceptTranscript('起飞'); now += 10001;
  adapter.confirmPending(); assert.equal(sent.length, 1);
  adapter.setEnabled(false);
});

test('stop, land, settings change and voice disable invalidate pending starts', () => {
  for (const interrupt of ['停止','降落','倍率三倍','暂停语音']) {
    const adapter = new VoiceCommandAdapter(); const sent=[];
    adapter.setEnabled(true); adapter.setListener(c=>sent.push(c.kind));
    adapter.acceptTranscript('滑动变焦'); adapter.acceptTranscript(interrupt); adapter.confirmPending();
    assert.ok(!sent.includes('dolly_start'), interrupt); adapter.setEnabled(false);
  }
});

test('busy voice intents never queue a start for later confirmation',()=>{
  const adapter=new VoiceCommandAdapter();let busy=true;const sent=[];
  adapter.setEnabled(true);adapter.setBusyProvider(()=>busy);adapter.setListener(c=>sent.push(c.kind));
  adapter.acceptTranscript('跟随我');busy=false;adapter.acceptTranscript('确认');
  assert.deepEqual(sent,[]);busy=true;adapter.acceptTranscript('降落');assert.deepEqual(sent,['land']);
  adapter.setEnabled(false);
});

test('captured native task parameter bytes and whitelist', () => {
  const { nativeSelection, nativeStart, dollyParameterWrites, validateNativeRequest } = require(core+'protocol/NativeTaskCodec.ets');
  const hex=b=>Buffer.from(b).toString('hex');
  assert.equal(hex(nativeSelection('follow')), '878867a30a000000');
  assert.equal(hex(nativeStart('follow')), '010a00');
  assert.equal(hex(nativeSelection('dolly')), '878867a30d000000');
  assert.equal(hex(nativeStart('dolly')), '010d00');
  assert.deepEqual(dollyParameterWrites('全身',3,false).map(hex), ['1756ad4101','ae918fe402','c59f793d00004040','a602eb5900']);
  assert.throws(()=>dollyParameterWrites('半身',4,true));
  assert.throws(()=>validateNativeRequest('follow',0x92,0x23,0x15,new Uint8Array([0])));
});

test('motion planning requires calibration and caps segments/total', () => {
  const { VoiceMotion }=require(core+'domain/VoiceMotion.ets');
  const motion=new VoiceMotion();
  assert.throws(()=>motion.plan(parseVoiceCommand('前进两米')), /标定/);
  motion.record('forward',2,1);
  assert.deepEqual(motion.plan(parseVoiceCommand('前进两米')), [4]);
  assert.throws(()=>motion.plan(parseVoiceCommand('前进十一米')));
  assert.deepEqual(motion.plan(parseVoiceCommand('前进半秒')), [.5]);
});
test('unspecified voice duration follows slider, explicit duration wins',()=>{
  const adapter=new VoiceCommandAdapter();const sent=[];let slider=4;
  adapter.setEnabled(true);adapter.setMovementDurationProvider(()=>slider);adapter.setListener(c=>sent.push(c));
  adapter.acceptTranscript('后退');assert.equal(sent[0].durationSeconds,4);assert.equal(sent[0].amount,4);
  assert.match(adapter.snapshot().feedback,/4/);slider=6;
  adapter.acceptTranscript('上升一点');assert.equal(sent[1].durationSeconds,6);
  adapter.acceptTranscript('前进两秒');assert.equal(sent[2].durationSeconds,2);
  adapter.setEnabled(false);
});
