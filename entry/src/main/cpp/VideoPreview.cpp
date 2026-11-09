#include "FrameQueue.h"
#include "HevcStream.h"
#include "VideoRecovery.h"
#include "MovieExport.h"
#include <napi/native_api.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <native_window/external_window.h>
#include <hilog/log.h>
#include <array>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <limits>
#include <mutex>
#include <memory>
#include <string>
#include <thread>

namespace {
using Clock = std::chrono::steady_clock;
int64_t Now() { return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count(); }
struct Stats {
    bool running = false, waitingForKey = true, recoveryPaused = false;
    uint64_t assembled = 0, submitted = 0, decoded = 0, rendered = 0, errors = 0, suppressed = 0, reordered = 0;
    uint64_t decoderEpoch = 0, randomAccess = 0, acceptedRandomAccess = 0;
    unsigned consecutiveFailures = 0, parameterMask = 0;
    int width = 0, height = 0;
    int64_t assembledAt = 0, submittedAt = 0, decodedAt = 0, renderedAt = 0;
    std::string error, lastResetReason;
};
struct Buffer { uint32_t index; OH_AVBuffer *data; };
struct CapturedFrame {
    uint32_t ticket = 0;
    int width = 0, height = 0;
    int64_t at = 0;
    std::vector<uint8_t> pixels;
};
void ReadbackStage(uint32_t ticket, const char *stage, int code = 0) {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoReadback",
        "ticket=%{public}u stage=%{public}s code=%{public}d", ticket, stage, code);
}

// Keep reference pictures across requests. Only convert an output when asked.
class FrameDecoder {
public:
    void Reset() {
        codec_.reset();
        queue_.clear();
        stride_ = sliceHeight_ = pixelFormat_ = 0;
    }

    void Feed(neo::AccessUnit unit, int width, int height,
              const std::array<neo::Bytes, 3> &parameters) {
        if (!codec_) {
            if (!unit.randomAccess) return;
            if (!Start(width, height)) { Fail("start"); return; }
            neo::Bytes key;
            for (const auto &parameter : parameters) key.insert(key.end(), parameter.begin(), parameter.end());
            key.insert(key.end(), unit.bytes.begin(), unit.bytes.end());
            unit.bytes = std::move(key);
        }
        if (queue_.size() >= 8 || unit.bytes.size() > 2 * 1024 * 1024) {
            Fail("input-queue");
            return;
        }
        lastPts_ = std::max(lastPts_ + 1, WallMs() * 1000);
        queue_.push_back({std::move(unit), lastPts_});
    }

    CapturedFrame Pump(uint32_t ticket) {
        CapturedFrame sample;
        auto *codec = codec_.get();
        if (!codec) return sample;
        for (int i = 0; i < 8; ++i) {
            uint32_t index = 0;
            auto code = OH_VideoDecoder_QueryOutputBuffer(codec, &index, 0);
            if (code == AV_ERR_TRY_AGAIN_LATER) break;
            if (code == AV_ERR_STREAM_CHANGED) { ReadLayout(); continue; }
            if (code != AV_ERR_OK) { Fail("output-query", code); return {}; }
            if (ticket != 0) {
                if (stride_ == 0) ReadLayout();
                auto frame = Capture(OH_VideoDecoder_GetOutputBuffer(codec, index), ticket);
                if (!frame.pixels.empty() && frame.at >= sample.at) sample = std::move(frame);
            }
            OH_VideoDecoder_FreeOutputBuffer(codec, index);
        }
        while (!queue_.empty()) {
            uint32_t index = 0;
            auto code = OH_VideoDecoder_QueryInputBuffer(codec, &index, 0);
            if (code == AV_ERR_TRY_AGAIN_LATER) break;
            if (code != AV_ERR_OK) { Fail("input-query", code); return {}; }
            auto *buffer = OH_VideoDecoder_GetInputBuffer(codec, index);
            auto *data = buffer ? OH_AVBuffer_GetAddr(buffer) : nullptr;
            const auto &input = queue_.front();
            const int size = static_cast<int>(input.unit.bytes.size());
            if (!data || OH_AVBuffer_GetCapacity(buffer) < size) { Fail("input-buffer"); return {}; }
            std::memcpy(data, input.unit.bytes.data(), size);
            OH_AVCodecBufferAttr attr{};
            attr.pts = input.pts;
            attr.size = size;
            attr.flags = input.unit.randomAccess ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;
            code = OH_AVBuffer_SetBufferAttr(buffer, &attr);
            if (code == AV_ERR_OK) code = OH_VideoDecoder_PushInputBuffer(codec, index);
            if (code != AV_ERR_OK) { Fail("input-submit", code); return {}; }
            queue_.pop_front();
        }
        return sample;
    }

private:
    struct Input { neo::AccessUnit unit; int64_t pts; };
    static int64_t WallMs() {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
    }
    void Fail(const char *stage, int code = 0) {
        OH_LOG_Print(LOG_APP, LOG_WARN, 0, "NeoReadback", "continuous %{public}s code=%{public}d", stage, code);
        Reset();
    }
    bool Start(int width, int height) {
        const uint32_t ticket = 0;
        auto *raw = OH_VideoDecoder_CreateByMime("video/hevc");
        if (!raw) { ReadbackStage(ticket, "create-decoder"); return false; }
        codec_.reset(raw);
        auto *format = OH_AVFormat_CreateVideoFormat("video/hevc", width, height);
        if (!format) { ReadbackStage(ticket, "create-format"); return false; }
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_ENABLE_SYNC_MODE, 1);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_MAX_INPUT_SIZE, 2 * 1024 * 1024);
        const auto configured = OH_VideoDecoder_Configure(raw, format);
        OH_AVFormat_Destroy(format);
        ReadbackStage(ticket, "configure", configured);
        if (configured != AV_ERR_OK) return false;
        const auto prepared = OH_VideoDecoder_Prepare(raw);
        ReadbackStage(ticket, "prepare", prepared);
        if (prepared != AV_ERR_OK) return false;
        const auto started = OH_VideoDecoder_Start(raw);
        ReadbackStage(ticket, "start", started);
        if (started != AV_ERR_OK) return false;
        width_ = width;
        height_ = height;
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoReadback", "continuous decoder started");
        return true;
    }
    void ReadLayout() {
        auto *format = OH_VideoDecoder_GetOutputDescription(codec_.get());
        if (!format) return;
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_STRIDE, &stride_);
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_SLICE_HEIGHT, &sliceHeight_);
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, &pixelFormat_);
        OH_AVFormat_Destroy(format);
    }
    CapturedFrame Capture(OH_AVBuffer *buffer, uint32_t ticket) const {
        CapturedFrame sample;
        sample.ticket = ticket;
        OH_AVCodecBufferAttr attr{};
        if (!buffer || OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK ||
            (attr.flags & (AVCODEC_BUFFER_FLAGS_EOS | AVCODEC_BUFFER_FLAGS_CODEC_DATA))) return {};
        const auto age = WallMs() - attr.pts / 1000;
        if (age < 0 || age > 180) return {};
        const int width = width_, height = height_;
        const int stride = stride_, sliceHeight = sliceHeight_, pixelFormat = pixelFormat_;
        auto *data = OH_AVBuffer_GetAddr(buffer);
        const int capacity = OH_AVBuffer_GetCapacity(buffer);
        const int64_t size = static_cast<int64_t>(stride) * sliceHeight;
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoReadback",
            "ticket=%{public}u layout=%{public}dx%{public}d stride=%{public}d slice=%{public}d format=%{public}d offset=%{public}d capacity=%{public}d address=%{public}d",
            ticket, width, height, stride, sliceHeight, pixelFormat, attr.offset, capacity, data != nullptr);
        if (data && attr.offset >= 0 && stride >= (width + 1) / 2 * 2 && sliceHeight >= height &&
            attr.offset + size + static_cast<int64_t>(stride) * ((height + 1) / 2) <= capacity &&
            (pixelFormat == AV_PIXEL_FORMAT_NV12 || pixelFormat == AV_PIXEL_FORMAT_NV21)) {
            const bool uv = pixelFormat == AV_PIXEL_FORMAT_NV12;
            const auto *y = data + attr.offset;
            const auto *chroma = y + size;
            const int scale = std::max(width, height);
            sample.width = scale > 640 ? std::max(1, width * 640 / scale) : width;
            sample.height = scale > 640 ? std::max(1, height * 640 / scale) : height;
            sample.at = attr.pts / 1000;
            sample.pixels.resize(static_cast<size_t>(sample.width) * sample.height * 4);
            for (int row = 0; row < sample.height; ++row) {
                const int sy = row * height / sample.height;
                for (int col = 0; col < sample.width; ++col) {
                    const int sx = col * width / sample.width;
                    const auto *c = chroma + (sy / 2) * stride + (sx / 2) * 2;
                    const int u = c[uv ? 0 : 1] - 128, v = c[uv ? 1 : 0] - 128;
                    const int luma = std::max(0, y[sy * stride + sx] - 16);
                    const size_t p = (static_cast<size_t>(row) * sample.width + col) * 4;
                    sample.pixels[p] = std::clamp((298 * luma + 409 * v + 128) >> 8, 0, 255);
                    sample.pixels[p + 1] = std::clamp((298 * luma - 100 * u - 208 * v + 128) >> 8, 0, 255);
                    sample.pixels[p + 2] = std::clamp((298 * luma + 516 * u + 128) >> 8, 0, 255);
                    sample.pixels[p + 3] = 255;
                }
            }
        }
        return sample;
    }

    std::unique_ptr<OH_AVCodec, decltype(&OH_VideoDecoder_Destroy)> codec_{nullptr, OH_VideoDecoder_Destroy};
    std::deque<Input> queue_;
    int width_ = 0, height_ = 0;
    int32_t stride_ = 0, sliceHeight_ = 0, pixelFormat_ = 0;
    int64_t lastPts_ = 0;
};

// The worker is the only owner of codec APIs and NativeWindow. Callbacks just
// enqueue buffer handles; Destroy joins codec callbacks before their context dies.
class Preview {
public:
    ~Preview() { Stop(); }
    void Start(uint64_t surface) {
        Stop();
        { std::lock_guard<std::mutex> lock(mutex_); stats_ = {}; stats_.running = true;
          frames_ = neo::FrameQueue(); rejected_ = 0; stopping_ = false; discontinuity_ = false; callbackError_ = 0;
          pendingSurface_ = 0; captureTicket_ = 0; captured_ = {}; stats_.lastResetReason = "session-start"; }
        worker_ = std::thread([this, surface] { Run(surface); });
    }
    uint32_t RequestFrame() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!stats_.running || stopping_) return 0;
        if (++captureSequence_ == 0) ++captureSequence_;
        captured_ = {};
        captureTicket_ = captureSequence_;
        return captureTicket_;
    }
    CapturedFrame TakeFrame(uint32_t ticket) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (ticket == 0 || captured_.ticket != ticket) return {};
        auto result = std::move(captured_);
        captured_ = {};
        captureTicket_ = 0;
        return result;
    }
    bool SwitchSurface(uint64_t surface) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_ || !stats_.running) return false;
        pendingSurface_ = surface;
        stats_.renderedAt = 0;
        wake_.notify_one();
        return true;
    }
    void Stop() {
        { std::lock_guard<std::mutex> lock(mutex_); stopping_ = true; }
        wake_.notify_all();
        if (worker_.joinable()) worker_.join();
        std::lock_guard<std::mutex> lock(mutex_);
        stats_.running = false; frames_.Clear();
    }
    void Submit(const uint8_t *bytes, size_t size) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_ || !stats_.running) return;
        if (size == 0 || size > 2 * 1024 * 1024) { discontinuity_ = true; ++rejected_; wake_.notify_one(); return; }
        auto result = frames_.Push(neo::Bytes(bytes, bytes + size));
        if (result != neo::QueueResult::Accepted) discontinuity_ = true;
        ++stats_.assembled; stats_.assembledAt = Now(); wake_.notify_one();
    }
    Stats Snapshot(size_t &queued, size_t &bytes, uint64_t &dropped) {
        std::lock_guard<std::mutex> lock(mutex_);
        queued = frames_.Size(); bytes = frames_.Bytes(); dropped = frames_.Dropped() + rejected_;
        return stats_;
    }
private:
    struct Context { Preview *owner; std::atomic<bool> accepting{true}; };
    static void Error(OH_AVCodec *, int32_t code, void *data) {
        auto &ctx = *static_cast<Context *>(data);
        std::lock_guard<std::mutex> lock(ctx.owner->mutex_);
        if (ctx.accepting) { ctx.owner->callbackError_ = code; ctx.owner->wake_.notify_one(); }
    }
    static void Changed(OH_AVCodec *, OH_AVFormat *format, void *data) {
        auto &ctx = *static_cast<Context *>(data); int32_t width = 0, height = 0;
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &width);
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &height);
        std::lock_guard<std::mutex> lock(ctx.owner->mutex_);
        if (ctx.accepting && width > 0 && height > 0) { ctx.owner->stats_.width = width; ctx.owner->stats_.height = height; }
    }
    static void Input(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer, void *data) {
        auto &ctx = *static_cast<Context *>(data);
        std::lock_guard<std::mutex> lock(ctx.owner->mutex_);
        if (ctx.accepting) { ctx.owner->inputs_.push_back({index, buffer}); ctx.owner->wake_.notify_one(); }
    }
    static void Output(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer, void *data) {
        auto &ctx = *static_cast<Context *>(data);
        std::lock_guard<std::mutex> lock(ctx.owner->mutex_);
        if (ctx.accepting) { ctx.owner->outputs_.push_back({index, buffer}); ctx.owner->wake_.notify_one(); }
    }
    void Fail(const std::string &message) {
        std::lock_guard<std::mutex> lock(mutex_); ++stats_.errors; stats_.error = message;
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0, "NeoVideo", "%{public}s", message.c_str());
    }
    void LogState(const char *event, uint64_t surface) {
        size_t queued, bytes; uint64_t dropped;
        const auto s = Snapshot(queued, bytes, dropped);
        const auto now = Now();
        const auto age = [now](int64_t at) -> long long { return at ? now - at : -1; };
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoVideo",
            "event=%{public}s epoch=%{public}llu surface=%{public}llu reset=%{public}s failures=%{public}u paused=%{public}d running=%{public}d waitingKey=%{public}d mask=%{public}u size=%{public}dx%{public}d irap=%{public}llu accepted=%{public}llu frames=%{public}llu submitted=%{public}llu decoded=%{public}llu rendered=%{public}llu queue=%{public}zu bytes=%{public}zu drops=%{public}llu errors=%{public}llu assembledAge=%{public}lld submittedAge=%{public}lld decodedAge=%{public}lld age=%{public}lld",
            event, static_cast<unsigned long long>(s.decoderEpoch), static_cast<unsigned long long>(surface),
            s.lastResetReason.c_str(), s.consecutiveFailures, s.recoveryPaused, s.running, s.waitingForKey,
            s.parameterMask, s.width, s.height, static_cast<unsigned long long>(s.randomAccess),
            static_cast<unsigned long long>(s.acceptedRandomAccess), static_cast<unsigned long long>(s.assembled),
            static_cast<unsigned long long>(s.submitted), static_cast<unsigned long long>(s.decoded),
            static_cast<unsigned long long>(s.rendered), queued, bytes, static_cast<unsigned long long>(dropped),
            static_cast<unsigned long long>(s.errors), age(s.assembledAt), age(s.submittedAt),
            age(s.decodedAt), age(s.renderedAt));
    }
    bool Create(int width, int height) {
        { std::lock_guard<std::mutex> lock(mutex_); stats_.decoderEpoch = ++codecSequence_; }
        codec_ = OH_VideoDecoder_CreateByMime("video/hevc");
        if (!codec_) { Fail("设备无法创建 HEVC 解码器"); return false; }
        context_ = std::make_unique<Context>(); context_->owner = this;
        OH_AVCodecCallback callback{Error, Changed, Input, Output};
        auto code = OH_VideoDecoder_RegisterCallback(codec_, callback, context_.get());
        auto *format = OH_AVFormat_CreateVideoFormat("video/hevc", width, height);
        if (!format) { Fail("创建视频格式失败"); Destroy(); return false; }
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_MAX_INPUT_SIZE, 2 * 1024 * 1024);
        if (code == AV_ERR_OK) code = OH_VideoDecoder_Configure(codec_, format);
        OH_AVFormat_Destroy(format);
        if (code == AV_ERR_OK && window_) code = OH_VideoDecoder_SetSurface(codec_, window_);
        if (code == AV_ERR_OK) code = OH_VideoDecoder_Prepare(codec_);
        if (code == AV_ERR_OK) code = OH_VideoDecoder_Start(codec_);
        if (code != AV_ERR_OK) { Fail("启动 HEVC 解码失败，错误码 " + std::to_string(code)); Destroy(); return false; }
        { std::lock_guard<std::mutex> lock(mutex_); stats_.width = width; stats_.height = height; stats_.error.clear(); }
        return true;
    }
    void Destroy() {
        if (codec_) {
            context_->accepting = false;
            // No preview mutex may be held: Stop/Destroy can wait for callbacks.
            OH_VideoDecoder_Stop(codec_); OH_VideoDecoder_Destroy(codec_); codec_ = nullptr;
        }
        context_.reset();
        std::lock_guard<std::mutex> lock(mutex_); inputs_.clear(); outputs_.clear(); callbackError_ = 0;
        stats_.waitingForKey = true;
    }
    // Cache the original Annex B parameter NALs. Do not keep stale P pictures
    // after an actual parameter change; the next random access includes config.
    bool Parameters(const neo::Bytes &bytes, bool &hasPicture, std::array<neo::Bytes, 3> &parameters) {
        struct Nal { size_t start, head; };
        std::vector<Nal> nals;
        for (size_t i = 0; i + 3 < bytes.size();) {
            size_t count = 0;
            if (bytes[i] == 0 && bytes[i+1] == 0) {
                if (bytes[i+2] == 1) count = 3;
                else if (bytes[i+2] == 0 && bytes[i+3] == 1) count = 4;
            }
            if (count) { nals.push_back({i, i + count}); i += count; } else ++i;
        }
        bool changed = false;
        for (size_t i = 0; i < nals.size(); ++i) {
            auto n = nals[i]; if (n.head + 1 >= bytes.size()) continue;
            int kind = (bytes[n.head] >> 1) & 63;
            if (kind < 32) hasPicture = true;
            if (kind >= 32 && kind <= 34) {
                size_t end = i + 1 < nals.size() ? nals[i+1].start : bytes.size();
                neo::Bytes value(bytes.begin() + n.start, bytes.begin() + end);
                auto &old = parameters[kind - 32];
                if (!old.empty() && old != value) changed = true;
                old = std::move(value);
            }
        }
        return changed;
    }
    void Run(uint64_t surface) {
        LogState("worker-start", surface);
        if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(surface, &window_) != 0 || !window_) {
            Fail("无法绑定视频显示区域");
            { std::lock_guard<std::mutex> lock(mutex_); stats_.running = false; stats_.lastResetReason = "surface-bind-failed"; }
            LogState("worker-failed", surface);
            return;
        }
        neo::HevcStream stream; std::deque<neo::AccessUnit> ready;
        // Parameters belong to this worker session, never to the reusable facade.
        std::array<neo::Bytes, 3> parameters;
        FrameDecoder readback;
        neo::VideoRecovery recovery;
        bool waitingKey = true; unsigned startupLogs = 0; int64_t startedAt = 0, lastInput = 0, lastPts = 0;
        int64_t lastStatsLog = Now();
        auto recordRecovery = [&] {
            std::lock_guard<std::mutex> lock(mutex_);
            stats_.consecutiveFailures = recovery.Failures(); stats_.recoveryPaused = recovery.Paused();
        };
        auto restartEvidence = [&](const char *reason) {
            recovery.OnDiscontinuity(); startupLogs = 0;
            std::lock_guard<std::mutex> lock(mutex_);
            stats_.lastResetReason = reason;
        };
        auto reset = [&](const char *reason) {
            restartEvidence(reason);
            Destroy(); ready.clear(); waitingKey = true; stream.Reset(); parameters = {};
            readback.Reset();
            { std::lock_guard<std::mutex> lock(mutex_); frames_.Clear(); stats_.parameterMask = 0; }
            recordRecovery(); LogState("reset", surface);
        };
        while (true) {
            neo::Bytes frame; bool discontinuity = false; int32_t error = 0;
            uint64_t nextSurface = 0;
            std::deque<Buffer> outputs;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                wake_.wait_for(lock, std::chrono::milliseconds(20), [&] {
                    return stopping_ || pendingSurface_ || frames_.Size() || !outputs_.empty() || callbackError_ || discontinuity_ || (!ready.empty() && !inputs_.empty());
                });
                if (stopping_) break;
                nextSurface = pendingSurface_; pendingSurface_ = 0;
                discontinuity = discontinuity_; discontinuity_ = false; error = callbackError_; callbackError_ = 0;
                if (frames_.Size()) frame = frames_.Pop();
                outputs.swap(outputs_);
            }
            if (discontinuity || error) {
                if (error) { Fail("HEVC 解码异常，错误码 " + std::to_string(error)); recovery.Failed(); }
                reset(error ? "codec-callback-error" : "input-queue-discontinuity"); outputs.clear(); frame.clear();
            }
            if (nextSurface != 0) {
                OHNativeWindow *nextWindow = nullptr;
                if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(nextSurface, &nextWindow) != 0 || !nextWindow) {
                    if (nextWindow) OH_NativeWindow_DestroyNativeWindow(nextWindow);
                    Fail("无法切换视频显示区域");
                    { std::lock_guard<std::mutex> lock(mutex_); stats_.running = false; stats_.lastResetReason = "surface-bind-failed"; }
                    LogState("worker-failed", nextSurface);
                    break;
                }
                const int code = codec_ ? OH_VideoDecoder_SetSurface(codec_, nextWindow) : AV_ERR_OK;
                if (code != AV_ERR_OK) {
                    // Devices that cannot switch a running decoder still retain this session's VPS/SPS/PPS.
                    Destroy(); ready.clear(); outputs.clear(); waitingKey = true;
                    readback.Reset();
                    restartEvidence("surface-switch-recreate");
                }
                recovery.OnDiscontinuity();
                OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoVideo", "surface-switch from=%{public}llu to=%{public}llu code=%{public}d",
                    static_cast<unsigned long long>(surface), static_cast<unsigned long long>(nextSurface), code);
                OH_NativeWindow_DestroyNativeWindow(window_);
                window_ = nextWindow; surface = nextSurface;
                { std::lock_guard<std::mutex> lock(mutex_); stats_.renderedAt = 0; }
                LogState("surface-switch", surface);
            }
            // Output handles cannot outlive their codec generation. Reset above
            // discards all handles from the destroyed generation before rendering.
            for (auto &output : outputs) {
                OH_AVCodecBufferAttr attr{};
                if (!codec_ || OH_AVBuffer_GetBufferAttr(output.data, &attr) != AV_ERR_OK) continue;
                if (attr.flags & (AVCODEC_BUFFER_FLAGS_EOS | AVCODEC_BUFFER_FLAGS_CODEC_DATA)) {
                    OH_VideoDecoder_FreeOutputBuffer(codec_, output.index); continue;
                }
                const auto result = OH_VideoDecoder_RenderOutputBuffer(codec_, output.index);
                bool stable = false;
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    ++stats_.decoded; stats_.decodedAt = Now();
                    if (result == AV_ERR_OK) {
                        ++stats_.rendered; stats_.renderedAt = Now(); stats_.error.clear();
                        stable = recovery.OnRendered(stats_.renderedAt);
                    } else {
                        ++stats_.errors; stats_.error = "视频送显失败，错误码 " + std::to_string(result); callbackError_ = result;
                        recovery.OnDiscontinuity();
                    }
                }
                if (stable) { recordRecovery(); LogState("recovery-stable", surface); }
            }
            if (!recovery.Paused()) {
                auto units = frame.empty() ? stream.Drain(Now()) : stream.Feed(frame, Now());
                { std::lock_guard<std::mutex> lock(mutex_); stats_.suppressed = stream.Suppressed(); stats_.reordered = stream.Reordered(); }
                for (auto &unit : units) {
                    bool picture = false;
                    bool changed = Parameters(unit.bytes, picture, parameters);
                    {
                        std::lock_guard<std::mutex> lock(mutex_);
                        stats_.parameterMask = (!parameters[0].empty() ? 1u : 0u) |
                            (!parameters[1].empty() ? 2u : 0u) | (!parameters[2].empty() ? 4u : 0u);
                        if (unit.randomAccess) ++stats_.randomAccess;
                    }
                    if (changed) {
                        Destroy(); ready.clear(); waitingKey = true; readback.Reset();
                        restartEvidence("parameter-change"); LogState("reset", surface);
                    }
                    if (startupLogs++ < 8) OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoVideo",
                        "startup epoch=%{public}llu bytes=%{public}zu picture=%{public}d random=%{public}d config=%{public}d%{public}d%{public}d size=%{public}dx%{public}d",
                        static_cast<unsigned long long>(codecSequence_), unit.bytes.size(), picture, unit.randomAccess,
                        !parameters[0].empty(), !parameters[1].empty(), !parameters[2].empty(), stream.Width(), stream.Height());
                    if (!picture) continue;
                    if (waitingKey) {
                        if (!unit.randomAccess || parameters[0].empty() || parameters[1].empty() || parameters[2].empty()) continue;
                        int width = stream.Width(), height = stream.Height();
                        if (width <= 0 || height <= 0 || width > 8192 || height > 8192) continue;
                        if (!Create(width, height)) {
                            recovery.Failed(); restartEvidence("codec-create-failed"); recordRecovery();
                            LogState("create-failed", surface);
                            if (recovery.Paused()) break;
                            continue;
                        }
                        neo::Bytes prefix;
                        for (const auto &parameter : parameters) prefix.insert(prefix.end(), parameter.begin(), parameter.end());
                        prefix.insert(prefix.end(), unit.bytes.begin(), unit.bytes.end()); unit.bytes = std::move(prefix);
                        waitingKey = false; startedAt = Now();
                        { std::lock_guard<std::mutex> lock(mutex_); stats_.waitingForKey = false; }
                        LogState("key-ready", surface);
                    }
                    ready.push_back(std::move(unit));
                }
            }
            size_t readyBytes = 0; for (const auto &unit : ready) readyBytes += unit.bytes.size();
            if (ready.size() > 16 || readyBytes > 8 * 1024 * 1024) {
                { std::lock_guard<std::mutex> lock(mutex_); rejected_ += ready.size(); }
                reset("ready-queue-overflow");
            }
            while (codec_ && !ready.empty()) {
                Buffer input{};
                { std::lock_guard<std::mutex> lock(mutex_); if (inputs_.empty()) break; input = inputs_.front(); inputs_.pop_front(); }
                auto unit = std::move(ready.front()); ready.pop_front();
                auto capacity = OH_AVBuffer_GetCapacity(input.data); auto *address = OH_AVBuffer_GetAddr(input.data);
                if (!address || unit.bytes.size() > static_cast<size_t>(std::max(capacity, 0))) {
                    Fail("解码器输入空间不足"); recovery.Failed(); reset("input-buffer-too-small"); break;
                }
                std::memcpy(address, unit.bytes.data(), unit.bytes.size());
                OH_AVCodecBufferAttr attr{}; lastPts = std::max(Now() * 1000, lastPts + 1);
                attr.pts = lastPts; attr.size = static_cast<int32_t>(unit.bytes.size());
                attr.flags = unit.randomAccess ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;
                int code = OH_AVBuffer_SetBufferAttr(input.data, &attr);
                if (code == AV_ERR_OK) code = OH_VideoDecoder_PushInputBuffer(codec_, input.index);
                if (code != AV_ERR_OK) {
                    Fail("提交视频帧失败，错误码 " + std::to_string(code)); recovery.Failed(); reset("input-submit-failed"); break;
                }
                {
                    std::lock_guard<std::mutex> lock(mutex_); ++stats_.submitted; stats_.submittedAt = Now();
                    if (unit.randomAccess) ++stats_.acceptedRandomAccess;
                }
                readback.Feed(std::move(unit), stream.Width(), stream.Height(), parameters);
                lastInput = Now();
            }
            uint32_t ticket = 0;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (captured_.ticket == 0) ticket = captureTicket_;
            }
            auto sample = readback.Pump(ticket);
            if (!sample.pixels.empty()) {
                std::lock_guard<std::mutex> lock(mutex_);
                if (sample.ticket == captureTicket_) {
                    ReadbackStage(ticket, "rgba-bytes", static_cast<int>(sample.pixels.size()));
                    captured_ = std::move(sample);
                }
            }
            int64_t lastOutput;
            { std::lock_guard<std::mutex> lock(mutex_); lastOutput = stats_.decodedAt; }
            if (codec_ && lastInput > std::max(startedAt, lastOutput) && Now() - std::max(startedAt, lastOutput) > 2500) {
                Fail("视频解码停滞，正在等待新的关键帧"); recovery.Failed(); reset("decode-stall");
            }
            if (recovery.Paused()) {
                {
                    std::lock_guard<std::mutex> lock(mutex_); frames_.Clear(); stats_.running = false;
                    stats_.recoveryPaused = true; stats_.consecutiveFailures = recovery.Failures();
                    stats_.error = "视频连续恢复失败，恢复已暂停，请重新连接飞机或重新打开页面";
                }
                LogState("recovery-paused", surface);
                break;
            }
            if (Now() - lastStatsLog >= 5000) {
                lastStatsLog = Now(); LogState("stats", surface);
            }
        }
        Destroy();
        if (window_) { OH_NativeWindow_DestroyNativeWindow(window_); window_ = nullptr; }
        { std::lock_guard<std::mutex> lock(mutex_); stats_.running = false; }
        LogState("worker-stop", surface);
    }
    std::mutex mutex_; std::condition_variable wake_; std::thread worker_;
    bool stopping_ = true, discontinuity_ = false; int32_t callbackError_ = 0;
    uint64_t pendingSurface_ = 0;
    uint64_t codecSequence_ = 0;
    uint32_t captureSequence_ = 0, captureTicket_ = 0;
    CapturedFrame captured_;
    uint64_t rejected_ = 0;
    neo::FrameQueue frames_; Stats stats_;
    std::deque<Buffer> inputs_, outputs_;
    OH_AVCodec *codec_ = nullptr; OHNativeWindow *window_ = nullptr;
    std::unique_ptr<Context> context_;
};
Preview preview;
napi_value Undefined(napi_env env) { napi_value result; napi_get_undefined(env, &result); return result; }
uint64_t SurfaceId(napi_env env, napi_callback_info info) {
    size_t count = 1; napi_value arg; napi_get_cb_info(env, info, &count, &arg, nullptr, nullptr);
    char text[32]{}; size_t size = 0;
    if (count != 1 || napi_get_value_string_utf8(env, arg, text, sizeof(text), &size) != napi_ok || size == 0 || size >= sizeof(text)-1) {
        napi_throw_type_error(env, nullptr, "Invalid video surface ID"); return 0;
    }
    uint64_t id = 0;
    for (size_t i = 0; i < size; ++i) {
        if (text[i] < '0' || text[i] > '9' || id > (std::numeric_limits<uint64_t>::max() - 9) / 10) {
            napi_throw_type_error(env, nullptr, "Invalid video surface ID"); return 0;
        }
        id = id * 10 + text[i] - '0';
    }
    if (!id) napi_throw_type_error(env, nullptr, "Empty video surface ID");
    return id;
}
napi_value Start(napi_env env, napi_callback_info info) {
    const auto id = SurfaceId(env, info);
    if (!id) return nullptr;
    preview.Start(id); return Undefined(env);
}
napi_value SwitchSurface(napi_env env, napi_callback_info info) {
    const auto id = SurfaceId(env, info);
    if (!id) return nullptr;
    napi_value result;
    napi_get_boolean(env, preview.SwitchSurface(id), &result);
    return result;
}
napi_value Stop(napi_env env, napi_callback_info) { preview.Stop(); return Undefined(env); }
napi_value RequestFrame(napi_env env, napi_callback_info) {
    napi_value result;
    napi_create_uint32(env, preview.RequestFrame(), &result);
    return result;
}
napi_value TakeFrame(napi_env env, napi_callback_info info) {
    size_t count = 1;
    napi_value arg;
    uint32_t ticket = 0;
    napi_get_cb_info(env, info, &count, &arg, nullptr, nullptr);
    if (count != 1 || napi_get_value_uint32(env, arg, &ticket) != napi_ok) return Undefined(env);
    auto frame = preview.TakeFrame(ticket);
    if (!frame.ticket) return Undefined(env);
    napi_value result, pixels, value;
    void *data = nullptr;
    napi_create_object(env, &result);
    if (napi_create_arraybuffer(env, frame.pixels.size(), &data, &pixels) != napi_ok) return Undefined(env);
    if (!frame.pixels.empty()) std::memcpy(data, frame.pixels.data(), frame.pixels.size());
    napi_set_named_property(env, result, "rgba", pixels);
    napi_create_int32(env, frame.width, &value); napi_set_named_property(env, result, "width", value);
    napi_create_int32(env, frame.height, &value); napi_set_named_property(env, result, "height", value);
    napi_create_double(env, frame.at, &value); napi_set_named_property(env, result, "capturedAtMs", value);
    return result;
}
napi_value Submit(napi_env env, napi_callback_info info) {
    size_t count = 1; napi_value arg; void *data = nullptr; size_t size = 0;
    napi_get_cb_info(env, info, &count, &arg, nullptr, nullptr);
    if (count != 1 || napi_get_arraybuffer_info(env, arg, &data, &size) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Expected video ArrayBuffer"); return nullptr;
    }
    preview.Submit(static_cast<uint8_t *>(data), size); return Undefined(env);
}
napi_value Snapshot(napi_env env, napi_callback_info) {
    size_t queued, bytes; uint64_t dropped; auto s = preview.Snapshot(queued, bytes, dropped); napi_value result;
    napi_create_object(env, &result);
    auto number = [&](const char *name, double value) { napi_value v; napi_create_double(env, value, &v); napi_set_named_property(env, result, name, v); };
    auto boolean = [&](const char *name, bool value) { napi_value v; napi_get_boolean(env, value, &v); napi_set_named_property(env, result, name, v); };
    auto age = [&](int64_t value) -> double { return value ? Now() - value : -1; };
    boolean("running", s.running); boolean("waitingForKey", s.waitingForKey);
    boolean("recoveryPaused", s.recoveryPaused);
    number("decoderEpoch", s.decoderEpoch); number("consecutiveFailures", s.consecutiveFailures);
    number("parameterMask", s.parameterMask); number("randomAccessFrames", s.randomAccess);
    number("acceptedRandomAccessFrames", s.acceptedRandomAccess);
    number("queued", queued); number("queuedBytes", bytes); number("queueDrops", dropped);
    number("assembledFrames", s.assembled); number("submittedFrames", s.submitted); number("decodedFrames", s.decoded);
    number("renderedFrames", s.rendered); number("decodeErrors", s.errors); number("suppressedParameters", s.suppressed);
    number("reorderedFrames", s.reordered); number("width", s.width); number("height", s.height);
    number("lastAssembledAgeMs", age(s.assembledAt)); number("lastSubmittedAgeMs", age(s.submittedAt));
    number("lastDecodedAgeMs", age(s.decodedAt)); number("lastRenderedAgeMs", age(s.renderedAt));
    napi_value error; napi_create_string_utf8(env, s.error.c_str(), NAPI_AUTO_LENGTH, &error); napi_set_named_property(env, result, "lastError", error);
    napi_value reason; napi_create_string_utf8(env, s.lastResetReason.c_str(), NAPI_AUTO_LENGTH, &reason); napi_set_named_property(env, result, "lastResetReason", reason);
    return result;
}
napi_value Init(napi_env env, napi_value exports) {
    napi_add_env_cleanup_hook(env, [](void *) { preview.Stop(); }, nullptr);
    napi_property_descriptor props[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"switchSurface", nullptr, SwitchSurface, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"requestFrame", nullptr, RequestFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"takeFrame", nullptr, TakeFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"submit", nullptr, Submit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"snapshot", nullptr, Snapshot, nullptr, nullptr, nullptr, napi_default, nullptr}};
    napi_define_properties(env, exports, sizeof(props)/sizeof(props[0]), props);
    return RegisterMovieExports(env, exports);
}
}
static napi_module module = {1, 0, nullptr, Init, "neovideo", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterNeoVideo() { napi_module_register(&module); }
