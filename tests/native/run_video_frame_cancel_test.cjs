'use strict';
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/cpp/VideoPreview.cpp'), 'utf8');
function method(signature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, `Production frame method is missing: ${signature}`);
  const opening = source.indexOf('{', start);
  let depth = 1, end = opening + 1;
  while (depth && end < source.length) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; end++; }
  assert.equal(depth, 0);
  return source.slice(start, end);
}
const methods = ['uint32_t RequestFrame()', 'void CancelFrame(uint32_t ticket)',
  'CapturedFrame TakeFrame(uint32_t ticket)'].map(method).join('\n');
const harness = `
using uint32_t = unsigned;
namespace std {
struct mutex {};
template<class T> struct lock_guard { explicit lock_guard(T&) {} };
template<class T> T&& move(T& value) { return static_cast<T&&>(value); }
}
struct CapturedFrame { uint32_t ticket = 0; int pixels = 0; };
struct Worker {
    std::mutex mutex_; bool stopping_ = false;
    struct Stats { bool running = true; } stats_;
    uint32_t captureSequence_ = 0, captureTicket_ = 0;
    CapturedFrame captured_;
${methods}
};
int main() {
    Worker worker;
    const auto expired = worker.RequestFrame();
    worker.captured_ = {expired, 17};
    worker.CancelFrame(expired);
    if (worker.captureTicket_ != 0 || worker.captured_.ticket != 0) return 1;
    const auto current = worker.RequestFrame();
    worker.captured_ = {current, 23};
    worker.CancelFrame(expired);
    if (worker.captureTicket_ != current || worker.captured_.pixels != 23) return 2;
    worker.CancelFrame(0);
    const auto taken = worker.TakeFrame(current);
    if (taken.ticket != current || taken.pixels != 23 || worker.captureTicket_ != 0) return 3;
    worker.CancelFrame(current);
    // Start clears pending tickets but never rewinds the facade's sequence.
    worker.captureTicket_ = 0; worker.captured_ = {};
    const auto laterSession = worker.RequestFrame();
    if (laterSession == expired || laterSession == current) return 4;
    worker.CancelFrame(current);
    if (worker.captureTicket_ != laterSession) return 5;
    worker.CancelFrame(laterSession);
    if (worker.stats_.running != true || worker.stopping_ != false) return 6;
    return 0;
}
`;
const sdk = process.env.OHOS_NATIVE_SDK || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native';
const compiler = process.env.NEO_CLANG || path.join(sdk, 'llvm/bin/clang++.exe');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'neo-video-cancel-'));
try {
  const input = path.join(temporary, 'video-cancel-test.cpp');
  const executable = path.join(temporary, 'video-cancel-test.exe');
  fs.writeFileSync(input, harness);
  const built = spawnSync(compiler, ['--target=x86_64-pc-windows-msvc', '-ffreestanding', '-nostdlib',
    '-fuse-ld=lld', '-std=c++17', '-O2', input, '-Wl,/entry:main,/subsystem:console', '-o', executable],
    { cwd: root, encoding: 'utf8' });
  assert.equal(built.status, 0, `Frame cancellation test build failed: ${built.error || built.stderr || built.stdout}`);
  const tested = spawnSync(executable, [], { cwd: root, encoding: 'utf8' });
  assert.equal(tested.status, 0, `Frame cancellation assertion ${tested.status} failed`);
  console.log('PASS: native cancellation removes only the matching ticket and result, preserving newer requests and sessions.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
