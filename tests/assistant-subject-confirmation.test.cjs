const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require(process.env.NEO_TYPESCRIPT ||
  'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript');
const { AssistantConversation } = require('../entry/src/main/ets/core/domain/AssistantConversation.ets');
const { selectedSubjectFrames, subjectFramePresentation, showSubjectFrame } =
  require('../entry/src/main/ets/core/domain/SubjectFramePresentation.ets');
const { subjectTaskSnapshot } = require('../entry/src/main/ets/core/domain/AssistantFlightPresentation.ets');

// ArkUI builders need a device runtime. Execute the sheet's real non-rendering methods
// in Node so the confirmation boundary and immediate frame refresh remain testable.
const source = fs.readFileSync(require.resolve('../entry/src/main/ets/components/AssistantSheet.ets'), 'utf8');
const start = source.indexOf('export struct AssistantSheet {') + 'export struct AssistantSheet {'.length;
const methods = source.slice(start, source.indexOf('\n  @Builder', start)).replace(/@(State|Link)\s+/g, '');
const compiled = ts.transpileModule(`class AssistantSheet {${methods}\n}\nmodule.exports = AssistantSheet;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
const loaded = { exports: {} };
new Function('module', 'selectedSubjectFrames', 'subjectFramePresentation', 'showSubjectFrame',
  'subjectTaskSnapshot', compiled)(loaded, selectedSubjectFrames, subjectFramePresentation,
  showSubjectFrame, subjectTaskSnapshot);
const AssistantSheet = loaded.exports;

function sheetFixture(action = 'follow') {
  let current = { subjectTask: { stage: 'confirm', active: true, subjectId: 7, plan: { action, subjectId: 7 } },
    groundDolly: { stage: 'idle', active: false },
    selectedSubjectOverlay: [{ id: 7, left: 0.3, top: 0.25, width: 0.2, height: 0.4 }] };
  const calls = [];
  let complete;
  const controller = {
    snapshot: () => current,
    confirmSubjectTask: async () => {
      calls.push('confirm');
      current = { ...current, subjectTask: { ...current.subjectTask, stage: action === 'dolly_zoom' ? 'plan' : 'starting' } };
      await new Promise(resolve => { complete = resolve; });
      return { message: '主体已确认' };
    },
    executeSubjectPlan: async () => { calls.push('execute'); return { message: '方案已执行' }; },
    confirmGroundDolly: async () => { throw Error('obsolete confirmation entry'); },
    executeGroundDolly: async () => { throw Error('obsolete execution entry'); }
  };
  const sheet = Object.create(AssistantSheet.prototype);
  Object.assign(sheet, { controller, state: current, processing: false, listening: false, accepting: false,
    epoch: 0, subjectConfirmed: true, conversation: new AssistantConversation(), messages: [] });
  return { sheet, calls, finish: () => complete() };
}

test('sheet confirms every subject action once through the generic entry and hides its frame immediately', async () => {
  for (const action of ['follow', 'circle', 'photo', 'record_start', 'select_subject', 'dolly_zoom']) {
    const { sheet, calls, finish } = sheetFixture(action);
    assert.equal(sheet.subjectFrames().length, 1, `${action}: a new workflow must override old local confirmation`);
    const pending = sheet.confirmSubject();
    assert.deepEqual(calls, ['confirm'], action);
    assert.equal(sheet.state.subjectTask.stage, action === 'dolly_zoom' ? 'plan' : 'starting');
    assert.deepEqual(sheet.subjectFrames(), [], `${action}: never wait for the next timer tick to hide the box`);
    await sheet.confirmSubject();
    assert.deepEqual(calls, ['confirm'], `${action}: duplicate taps are ignored`);
    finish(); await pending;
    assert.equal(sheet.processing, false);
  }
});

test('sheet retains one-click plan execution through the generic controller entry', async () => {
  const { sheet, calls } = sheetFixture('dolly_zoom');
  sheet.state.subjectTask.stage = 'plan';
  await sheet.executePlan();
  assert.deepEqual(calls, ['execute']);
  assert.equal(sheet.status, '方案已执行');
});

function recoverySheetFixture() {
  const { sheet } = sheetFixture();
  let generation = 1, fail;
  Object.assign(sheet, { appeared: true, status: '原状态', resultPlaybackEpoch: 0,
    autoScroll: { stop() {} } });
  sheet.controller.snapshot = () => ({ session: { generation, sessionHex: '0x0007' } });
  sheet.controller.recoverVideoPreview = () => new Promise((_resolve, reject) => { fail = reject; });
  sheet.controller.stopSubjectDescription = async () => {};
  sheet.controller.land = async () => {};
  return { sheet, fail: () => fail(new Error('旧恢复请求失败')),
    reconnect: () => { generation++; } };
}

test('sheet shows a current manual recovery failure', async () => {
  const { sheet, fail } = recoverySheetFixture();
  const pending = sheet.recoverVideoPreview(); fail(); await pending;
  assert.equal(sheet.status, '旧恢复请求失败');
});

test('a late recovery failure cannot overwrite the real landing status', async () => {
  const { sheet, fail } = recoverySheetFixture();
  const pending = sheet.recoverVideoPreview(); sheet.land();
  fail(); await pending;
  assert.equal(sheet.status, '正在请求降落…');
});

test('a late recovery failure cannot overwrite the real listening status', async () => {
  const { sheet, fail } = recoverySheetFixture();
  let finishListening;
  sheet.controller.listenForSubjectDescription = ready => {
    ready(); return new Promise(resolve => { finishListening = resolve; });
  };
  sheet.controller.executeLocalFlightVoice = async () => ({ message: '语音已处理' });
  const pending = sheet.recoverVideoPreview(), listening = sheet.speak();
  fail(); await pending;
  assert.equal(sheet.status, '请说话，我在听…');
  finishListening('降落'); await listening;
});

test('a late recovery failure cannot update a replacement session with the same session number', async () => {
  const { sheet, fail, reconnect } = recoverySheetFixture();
  const pending = sheet.recoverVideoPreview(); reconnect(); sheet.status = '新会话已连接';
  fail(); await pending;
  assert.equal(sheet.status, '新会话已连接');
});

test('a recovery failure after the sheet disappears is ignored', async () => {
  const { sheet, fail } = recoverySheetFixture();
  const pending = sheet.recoverVideoPreview(); sheet.aboutToDisappear(); sheet.status = '已关闭';
  fail(); await pending;
  assert.equal(sheet.status, '已关闭');
});
