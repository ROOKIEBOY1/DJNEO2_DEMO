const { test } = require('node:test');
const assert = require('node:assert/strict');
const { AppController } = require('../entry/src/main/ets/core/domain/AppController.ets');

test('executing a subject plan retains and logs the actual frame failure', async () => {
  const c = Object.create(AppController.prototype), messages = [];
  const cause = new Error('没有时间匹配的主体跟踪回报');
  c.groundDolly = { execute: async () => { throw cause; } };
  c.log = message => messages.push(message); c.emit = () => {};
  await assert.rejects(c.executeSubjectPlan(), error => error === cause);
  assert.equal(c.agentFeedback, cause.message);
  assert.deepEqual(messages, [`主体任务执行失败：${cause.message}`]);
});
