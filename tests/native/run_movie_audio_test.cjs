const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const clang = process.env.NEO_CLANG || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native/llvm/bin/clang++.exe';
const output = path.join(root, 'diagnostics/movie-audio-test.exe');
const build = spawnSync(clang, ['--target=x86_64-pc-windows-msvc', '-ffreestanding', '-nostdlib',
  '-fuse-ld=lld', '-std=c++17', '-O2', '-Wl,/entry:main,/subsystem:console', '-o', output,
  path.join(__dirname, 'movie_audio_test.cpp')], { encoding: 'utf8' });
if (build.status !== 0) {
  process.stderr.write(build.stdout + build.stderr);
  process.exit(build.status || 1);
}
const result = spawnSync(output, [], { encoding: 'utf8' });
assert.equal(result.status, 0, `PCM fixture failed (exit identifies assertion): ${result.error || result.stderr}`);
console.log('Movie audio: PCM stride/format, stereo resample, loop, short/long fade, cancellation, AAC ADTS and complete output timeline passed; source double-EOS, 144ms trim, fixed 250ms/+1-sample boundaries, shortfall and invalid-input checks passed (assertions 1-71).');
