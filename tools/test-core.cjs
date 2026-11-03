const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require(process.env.NEO_TYPESCRIPT || 'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript');
const assert = require('node:assert/strict');
const testApi = require('node:test');
const originalLoad = Module._load;
Module._load = function (name, parent, main) {
  if (name === '@ohos/hypium') return {
    describe: testApi.describe, it: (name, level, fn) => testApi.it(name, fn),
    expect: value => ({ assertEqual: expected => assert.equal(value, expected),
      assertTrue: () => assert.equal(value, true), assertFalse: () => assert.equal(value, false),
      assertUndefined: () => assert.equal(value, undefined) })
  };
  if (name.startsWith('@kit.')) return global.__neoKits?.[name] || { hilog: { info() {}, warn() {}, error() {} } };
  return originalLoad.call(this, name, parent, main);
};
require.extensions['.ets'] = (module, filename) => {
  const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, fileName: filename + '.ts'
  });
  module._compile(result.outputText, filename);
};
for (const file of fs.readdirSync(path.resolve(__dirname, '../tests')).filter(x => x.endsWith('.test.cjs'))) {
  require(path.resolve(__dirname, '../tests', file));
}
