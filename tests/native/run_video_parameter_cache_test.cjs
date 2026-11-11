'use strict';
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const root = path.resolve(__dirname, '../..');
const sdk = process.env.OHOS_NATIVE_SDK || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native';
const compiler = process.env.NEO_CLANG || path.join(sdk, 'llvm/bin/clang++.exe');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'neo-video-parameters-'));
const executable = path.join(temporary, 'video-parameter-cache-test.exe');
try {
  const built = spawnSync(compiler, ['--target=x86_64-pc-windows-msvc', '-ffreestanding', '-nostdlib',
    '-fuse-ld=lld', '-std=c++17', '-O2', 'tests/native/video_parameter_cache_test.cpp',
    '-Wl,/entry:main,/subsystem:console', '-o', executable], { cwd: root, encoding: 'utf8' });
  assert.equal(built.status, 0, `Video parameter test build failed: ${built.error || built.stderr || built.stdout}`);
  const tested = spawnSync(executable, [], { cwd: root, encoding: 'utf8' });
  assert.equal(tested.status, 0, `Video parameter cache assertion ${tested.status} failed: ${tested.error || tested.stderr}`);
  console.log('PASS: decoder recovery retains same-stream config; only a new IRAP can restart; changed/partial/new stream configuration stays distinct.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
