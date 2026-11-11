'use strict';
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const root = path.resolve(__dirname, '../..');
const sdk = process.env.OHOS_NATIVE_SDK || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native';
const compiler = path.join(sdk, 'llvm/bin/clang++.exe');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'neo-avc-configuration-'));
const executable = path.join(temporary, 'avc-configuration-test.exe');
try {
  const args = ['--target=x86_64-pc-windows-msvc', '-ffreestanding', '-nostdlib', '-fuse-ld=lld', '-std=c++17', '-O2',
    '-Ientry/src/main/cpp', 'tests/native/avc_configuration_test.cpp',
    '-Wl,/entry:main,/subsystem:console', '-o', executable];
  const built = spawnSync(compiler, args, { cwd: root, encoding: 'utf8' });
  if (built.status !== 0) throw new Error(`AVC test build failed: ${built.error || built.stderr || built.stdout}`);
  const tested = spawnSync(executable, [], { cwd: root, encoding: 'utf8' });
  if (tested.status !== 0) throw new Error(`AVC configuration assertion ${tested.status} failed: ${tested.error || tested.stderr}`);
  console.log('PASS: real empty avcC rejected; Annex-B/avcC SPS+PPS, truncation, missing sets and combined keyframes checked');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
