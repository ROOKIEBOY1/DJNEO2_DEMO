const { test } = require('node:test');
const assert = require('node:assert/strict');
const { selectWithDeepSeek, planWithDeepSeek } = require('../tools/deepseek-selection.cjs');

test('DeepSeek receives the image and candidate boxes and can only return a submitted ID', async () => {
  const jpeg = Buffer.from([255, 216, 255, 217]);
  const sample = {
    selectionPrompt: '换成另外一个',
    currentSubjectId: 11,
    candidates: [{ id: 29, left: 0.5, top: 0.1, width: 0.3, height: 0.8 }]
  };
  let id = 29;
  const request = async (url, options) => {
    const body = JSON.parse(options.body);
    assert.equal(url, 'https://api.deepseek.com/chat/completions');
    assert.equal(body.model, 'deepseek-flash');
    assert.equal(body.thinking.type, 'disabled');
    assert.match(body.messages[0].content, /exclude the current subject/i);
    assert.deepEqual(JSON.parse(body.messages[1].content[0].text), sample);
    assert.equal(body.messages[1].content[1].image_url.url, 'data:image/jpeg;base64,/9j/2Q==');
    return { ok: true, json: async () => ({
      choices: [{ finish_reason: 'stop', message: { content: JSON.stringify({ id }) } }]
    }) };
  };
  assert.equal(await selectWithDeepSeek('test-key', sample, jpeg, undefined, request), 29);
  id = null;
  assert.equal(await selectWithDeepSeek('test-key', sample, jpeg, undefined, request), null);
  id = 42;
  await assert.rejects(selectWithDeepSeek('test-key', sample, jpeg, undefined, request), /outside/);
});

test('cloud action planner supports flight without an image and rejects arbitrary navigation or invalid candidates', async () => {
  const meta = { selectionPrompt: '向左飞两秒', context: { movementSeconds: 0.5 }, candidates: [] };
  let command = { action: 'move', direction: 'left', seconds: 2 };
  const request = async (url, options) => {
    const body = JSON.parse(options.body);
    assert.equal(body.messages[1].content.length, 1);
    assert.match(body.messages[0].content, /dolly_zoom/);
    return { ok: true, json: async () => ({
      choices: [{ finish_reason: 'stop', message: { content: JSON.stringify(command) } }]
    }) };
  };
  assert.deepEqual(await planWithDeepSeek('key', meta, Buffer.alloc(0), undefined, request), command);
  for(const action of ['takeoff','land']) {
    command={action};
    assert.deepEqual(await planWithDeepSeek('key',meta,Buffer.alloc(0),undefined,request),command);
  }
  command = { action: 'navigate' };
  await assert.rejects(planWithDeepSeek('key', meta, Buffer.alloc(0), undefined, request), /Unsupported/);
  command = { action: 'select_subject', subjectId: 11 };
  await assert.rejects(planWithDeepSeek('key', meta, Buffer.alloc(0), undefined, request), /candidate/);
});

test('cloud planner distinguishes independent follow from selecting and supports airborne task requests', async () => {
  const meta = {selectionPrompt:'跟随黑衣服的男生',candidates:[{id:11}],context:{airborne:true}};
  const request = async (url, options) => {
    const prompt = JSON.parse(options.body).messages[0].content;
    assert.match(prompt, /independent native flight task/);
    assert.match(prompt, /airborne hover/);
    return {ok:true,json:async()=>({choices:[{finish_reason:'stop',message:{content:'{"action":"follow","subjectId":11}'}}]})};
  };
  assert.deepEqual(await planWithDeepSeek('key',meta,Buffer.from([255,216,255,217]),undefined,request),
    {action:'follow',subjectId:11});
});
