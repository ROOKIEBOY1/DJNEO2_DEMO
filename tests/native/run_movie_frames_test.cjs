'use strict';
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const root = path.resolve(__dirname, '../..');
const sdk = process.env.OHOS_NATIVE_SDK || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native';
const compiler = path.join(sdk, 'llvm/bin/clang++.exe');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'neo-movie-frames-'));
const executable = path.join(temporary, 'movie-frames-test.exe');
try {
  const args = ['--target=x86_64-pc-windows-msvc', '-ffreestanding', '-nostdlib', '-fuse-ld=lld', '-std=c++17', '-O2',
    '-DMOVIE_FRAMES_FREESTANDING', '-Ientry/src/main/cpp', 'entry/src/main/cpp/MovieFrames.cpp',
    'tests/native/movie_frames_freestanding_test.cpp', '-Wl,/entry:main,/subsystem:console', '-o', executable];
  const built = spawnSync(compiler, args, { cwd: root, encoding: 'utf8' });
  if (built.status !== 0) throw new Error(`Frame test build failed: ${built.error || built.stderr || built.stdout}`);
  const tested = spawnSync(executable, [], { cwd: root, encoding: 'utf8' });
  if (tested.status !== 0) throw new Error(`Frame algorithm assertion ${tested.status} failed: ${tested.error || tested.stderr}`);
  console.log('PASS: actual C++ scaling/rotation/stride/range/fade/credit; clip ordering, VFR duration bounds, per-track packet coverage and exact AAC/video timeline counts');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
