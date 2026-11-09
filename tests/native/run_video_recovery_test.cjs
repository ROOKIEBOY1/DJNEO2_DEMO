'use strict';
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const root = path.resolve(__dirname, '../..');
const header = path.join(root, 'entry/src/main/cpp/VideoRecovery.h');
assert.ok(fs.existsSync(header), 'VideoRecovery production policy is missing');
const sdk = process.env.OHOS_NATIVE_SDK || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native';
const compiler = process.env.NEO_CLANG || path.join(sdk, 'llvm/bin/clang++.exe');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'neo-video-recovery-'));
const executable = path.join(temporary, 'video-recovery-test.exe');
try {
  const args = ['--target=x86_64-pc-windows-msvc', '-ffreestanding', '-nostdlib', '-fuse-ld=lld', '-std=c++17', '-O2',
    'tests/native/video_recovery_test.cpp', '-Wl,/entry:main,/subsystem:console', '-o', executable];
  const built = spawnSync(compiler, args, { cwd: root, encoding: 'utf8' });
  assert.equal(built.status, 0, `Video recovery test build failed: ${built.error || built.stderr || built.stdout}`);
  const tested = spawnSync(executable, [], { cwd: root, encoding: 'utf8' });
  assert.equal(tested.status, 0, `Video recovery assertion ${tested.status} failed: ${tested.error || tested.stderr}`);
  console.log('PASS: video recovery separates healthy periods from consecutive failures; short output, silence, discontinuity and clock rollback retain the budget; pause is terminal.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
