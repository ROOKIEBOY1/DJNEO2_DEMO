'use strict';
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const root = path.resolve(__dirname, '../..');
assert.ok(fs.existsSync(path.join(root, 'entry/src/main/cpp/VideoDiagnosticGop.h')),
  'The production bounded diagnostic GOP recorder is missing');
const sdk = process.env.OHOS_NATIVE_SDK || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native';
const compiler = process.env.NEO_CLANG || path.join(sdk, 'llvm/bin/clang++.exe');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'neo-video-diagnostic-'));
try {
  const executable = path.join(temporary, 'video-diagnostic-test.exe');
  const built = spawnSync(compiler, ['--target=x86_64-pc-windows-msvc', '-ffreestanding', '-nostdlib',
    '-fuse-ld=lld', '-std=c++17', '-O2', 'tests/native/video_diagnostic_gop_test.cpp',
    '-Wl,/entry:main,/subsystem:console', '-o', executable], { cwd: root, encoding: 'utf8' });
  assert.equal(built.status, 0, `Diagnostic recorder test build failed: ${built.error || built.stderr || built.stdout}`);
  const tested = spawnSync(executable, [], { cwd: root, encoding: 'utf8' });
  assert.equal(tested.status, 0, `Diagnostic recorder assertion ${tested.status} failed`);
  console.log('PASS: diagnostic GOP recording preserves submitted bytes, caps memory, marks overflow incomplete, restarts only on IRAP and rotates two slots.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
