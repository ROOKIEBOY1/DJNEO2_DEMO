'use strict';
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/cpp/VideoPreview.cpp'), 'utf8');
const start = source.indexOf('        for (int i = 0; i < 8; ++i) {');
const end = source.indexOf('        while (!queue_.empty()) {', start);
assert.ok(start >= 0 && end > start);
function method(signature) {
  const start = source.indexOf(signature), open = source.indexOf('{', start);
  assert.ok(start >= 0);
  let depth = 1, end = open + 1;
  while (depth) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; end++; }
  return source.slice(start, end);
}
const harness = `
using uint32_t = unsigned; using int64_t = long long;
namespace std { template<class T> T&& move(T& value) { return static_cast<T&&>(value); } }
const int AV_ERR_OK = 0, AV_ERR_TRY_AGAIN_LATER = -10, AV_ERR_STREAM_CHANGED = -11;
const int LOG_APP = 0, LOG_WARN = 1;
static int OH_LOG_Print(int, int, int, const char *, const char *, ...) { return 0; }
struct OH_AVCodec {};
struct Pixels { bool empty() const { return true; } };
struct CapturedFrame { Pixels pixels; int64_t at = 0; };
static int queryCount = 0, freeCount = 0, releaseCode = 0;
static int64_t Now() { return 1; }
static int OH_VideoDecoder_QueryOutputBuffer(OH_AVCodec *, uint32_t *index, int64_t) {
    *index = 3; return queryCount++ == 0 ? 0 : AV_ERR_TRY_AGAIN_LATER;
}
static void *OH_VideoDecoder_GetOutputBuffer(OH_AVCodec *, uint32_t) { return nullptr; }
static int OH_VideoDecoder_FreeOutputBuffer(OH_AVCodec *, uint32_t) { ++freeCount; return releaseCode; }
struct Decoder {
    struct Handle { bool valid = true; void reset() { valid = false; } } codec_;
    struct Queue { void clear() {} } queue_;
    int stride_ = 0, sliceHeight_ = 0, pixelFormat_ = 0, apiErrors_ = 0, outputs_ = 0;
    int64_t lastOutputAt_ = 0; uint32_t lastTicket_ = 0;
    void LogState(const char *, uint32_t) {}
    void ReadLayout() {}
    CapturedFrame Capture(void *, uint32_t) { return {}; }
    ${method('void Reset()')}
    ${method('void Fail(const char *stage, int code = 0)')}
    CapturedFrame pump() {
        CapturedFrame sample; OH_AVCodec instance; auto *codec = &instance; uint32_t ticket = 0;
${source.slice(start, end)}
        return sample;
    }
};
int main() {
    Decoder failure; releaseCode = -9; failure.pump();
    if (failure.codec_.valid || failure.apiErrors_ != 1 || freeCount != 1) return 1;
    Decoder success; releaseCode = 0; freeCount = queryCount = 0; success.pump();
    if (!success.codec_.valid || success.apiErrors_ != 0 || freeCount != 1 || success.outputs_ != 1) return 2;
    return 0;
}
`;
const sdk = process.env.OHOS_NATIVE_SDK || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native';
const compiler = process.env.NEO_CLANG || path.join(sdk, 'llvm/bin/clang++.exe');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'neo-video-readback-'));
try {
  const input = path.join(temporary, 'video-readback-test.cpp');
  const executable = path.join(temporary, 'video-readback-test.exe');
  fs.writeFileSync(input, harness);
  const built = spawnSync(compiler, ['--target=x86_64-pc-windows-msvc', '-ffreestanding', '-nostdlib',
    '-fuse-ld=lld', '-std=c++17', '-O2', input, '-Wl,/entry:main,/subsystem:console', '-o', executable],
    { cwd: root, encoding: 'utf8' });
  assert.equal(built.status, 0, `Readback release test build failed: ${built.error || built.stderr || built.stdout}`);
  const tested = spawnSync(executable, [], { cwd: root, encoding: 'utf8' });
  assert.equal(tested.status, 0, `Readback release assertion ${tested.status} failed`);
  console.log('PASS: readback output release failure is reported and resets only its decoder; successful releases keep it running.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
