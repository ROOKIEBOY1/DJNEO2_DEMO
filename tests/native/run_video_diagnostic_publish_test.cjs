'use strict';
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const root = path.resolve(__dirname, '../..');
const sdk = process.env.OHOS_NATIVE_SDK || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native';
const compiler = process.env.NEO_CLANG || path.join(sdk, 'llvm/bin/clang++.exe');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'neo-video-publish-'));
try {
  const executable = path.join(temporary, 'video-publish-test.exe');
  const built = spawnSync(compiler, ['--target=x86_64-pc-windows-msvc', '-ffreestanding', '-nostdlib',
    '-fuse-ld=lld', '-fno-exceptions', '-std=c++17', '-O2', 'tests/native/video_diagnostic_publish_test.cpp',
    '-Wl,/entry:main,/subsystem:console', '-o', executable], { cwd: root, encoding: 'utf8' });
  assert.equal(built.status, 0, `Diagnostic publication test build failed: ${built.error || built.stderr || built.stdout}`);
  const tested = spawnSync(executable, [], { cwd: root, encoding: 'utf8' });
  assert.equal(tested.status, 0, `Diagnostic publication assertion ${tested.status} failed`);
  console.log('PASS: diagnostic manifest is invalidated before writes and committed last; write, rename and delete failures cannot publish mismatched evidence.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
