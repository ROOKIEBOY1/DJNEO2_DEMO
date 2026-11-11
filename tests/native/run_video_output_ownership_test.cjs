'use strict';
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(path.join(root, 'entry/src/main/cpp/VideoPreview.cpp'), 'utf8');
// Exercise the real worker branch, with only the unavailable device APIs replaced.
const start = source.indexOf('            for (auto &output : outputs) {');
const end = source.indexOf('            if (!recovery.Paused()) {', start);
assert.ok(start >= 0 && end > start, 'native output consumer was not found');
const consumer = source.slice(start, end);
const harness = `
using uint32_t = unsigned;
using int64_t = long long;
namespace std { struct mutex {}; template<class T> struct lock_guard { explicit lock_guard(T&) {} }; }
constexpr int AV_ERR_OK = 0;
constexpr int AVCODEC_BUFFER_FLAGS_EOS = 1, AVCODEC_BUFFER_FLAGS_CODEC_DATA = 8;
struct OH_AVBuffer { int metadataCode = 0, flags = 0; };
struct OH_AVCodecBufferAttr { int flags = 0; };
struct OH_AVCodec {};
struct Buffer { uint32_t index; OH_AVBuffer *data; };
static int owned = 0, frees = 0, renders = 0, renderCode = 0, freeCode = 0;
static int OH_AVBuffer_GetBufferAttr(OH_AVBuffer *b, OH_AVCodecBufferAttr *a) {
    if (!b || b->metadataCode) return b ? b->metadataCode : -1;
    a->flags = b->flags; return 0;
}
static int OH_VideoDecoder_FreeOutputBuffer(OH_AVCodec *, uint32_t) {
    ++frees; if (freeCode == 0) --owned; return freeCode;
}
static int OH_VideoDecoder_RenderOutputBuffer(OH_AVCodec *, uint32_t) {
    ++renders; if (renderCode == 0) --owned; return renderCode;
}
static int64_t Now() { return 123; }
struct ErrorText { template<class T> ErrorText& operator=(const T&) { return *this; } void clear() {} };
// Device logging and text formatting have no effect on pool ownership.
struct Text {};
static Text operator+(const char *, Text) { return {}; }
namespace std { static Text to_string(int) { return {}; } }
struct Recovery { bool OnRendered(int64_t) { return false; } void OnDiscontinuity() {} };
struct Worker {
    OH_AVCodec codec; OH_AVCodec *codec_ = &codec; std::mutex mutex_;
    int callbackError_ = 0;
    struct Stats { int decoded = 0, rendered = 0, errors = 0;
        int64_t decodedAt = 0, renderedAt = 0; ErrorText error; } stats_;
    void Fail(const char *) { ++stats_.errors; }
    void Fail(Text) { ++stats_.errors; }
    void LogState(const char *, unsigned long long) {}
    void consume(OH_AVBuffer *data) {
        Buffer outputs[] = {{7, data}}; Recovery recovery; unsigned long long surface = 9;
        auto recordRecovery = [] {};
${consumer}
    }
};
int main() {
    Worker worker; OH_AVBuffer buffer;
    // A failed metadata read must not permanently borrow a slot from the finite pool.
    buffer.metadataCode = -7;
    for (int frame = 0; frame < 20; ++frame) {
        owned = 1; frees = renders = 0;
        worker.consume(&buffer);
        if (owned != 0 || frees != 1 || renders != 0) return 11;
    }
    // A missing callback buffer still carries a valid slot index to return.
    owned = 1; frees = renders = 0; worker.consume(nullptr);
    if (owned != 0 || frees != 1 || renders != 0) return 12;
    buffer.metadataCode = 0;
    const int nonPictures[] = {AVCODEC_BUFFER_FLAGS_EOS, AVCODEC_BUFFER_FLAGS_CODEC_DATA};
    for (int flags : nonPictures) {
        buffer.flags = flags; owned = 1; frees = renders = 0; worker.consume(&buffer);
        if (owned != 0 || frees != 1 || renders != 0) return 13;
    }
    buffer.flags = 0; owned = 1; frees = renders = 0; worker.consume(&buffer);
    if (owned != 0 || frees != 0 || renders != 1 || worker.stats_.rendered != 1) return 14;
    // Failed release must be surfaced to the worker recovery path, including
    // non-picture output. Otherwise the same pool can stop without an error.
    buffer.flags = AVCODEC_BUFFER_FLAGS_CODEC_DATA; freeCode = -9;
    worker.callbackError_ = 0; owned = 1; worker.consume(&buffer);
    if (worker.callbackError_ != -9) return 15;
    return 0;
}
`;
const sdk = process.env.OHOS_NATIVE_SDK || 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native';
const compiler = process.env.NEO_CLANG || path.join(sdk, 'llvm/bin/clang++.exe');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'neo-video-output-'));
try {
  const input = path.join(temporary, 'video-output-test.cpp');
  const executable = path.join(temporary, 'video-output-test.exe');
  fs.writeFileSync(input, harness);
  const built = spawnSync(compiler, ['--target=x86_64-pc-windows-msvc', '-ffreestanding', '-nostdlib',
    '-fuse-ld=lld', '-std=c++17', '-O2', input, '-Wl,/entry:main,/subsystem:console', '-o', executable],
    { cwd: root, encoding: 'utf8' });
  assert.equal(built.status, 0, `Output ownership test build failed: ${built.error || built.stderr || built.stdout}`);
  const tested = spawnSync(executable, [], { cwd: root, encoding: 'utf8' });
  assert.equal(tested.status, 0,
    `Output ownership assertion ${tested.status}: 11=metadata failure leaked slot, 12=null buffer leaked slot, 13=non-picture release, 14=picture render, 15=release failure was hidden`);
  console.log('PASS: native preview returns every output slot when metadata is unreadable and renders or releases normal outputs exactly once.');
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
