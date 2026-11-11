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
