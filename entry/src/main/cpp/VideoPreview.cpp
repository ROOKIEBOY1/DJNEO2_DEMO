#include "FrameQueue.h"
#include "HevcStream.h"
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
    bool running = false, waitingForKey = true;
    uint64_t assembled = 0, submitted = 0, decoded = 0, rendered = 0, errors = 0, suppressed = 0, reordered = 0;
    int width = 0, height = 0;
    int64_t assembledAt = 0, decodedAt = 0, renderedAt = 0;
    std::string error;
};
struct Buffer { uint32_t index; OH_AVBuffer *data; };

// The worker is the only owner of codec APIs and NativeWindow. Callbacks just
// enqueue buffer handles; Destroy joins codec callbacks before their context dies.
class Preview {
public:
    ~Preview() { Stop(); }
    void Start(uint64_t surface) {
        Stop();
        { std::lock_guard<std::mutex> lock(mutex_); stats_ = {}; stats_.running = true;
          frames_ = neo::FrameQueue(); rejected_ = 0; stopping_ = false; discontinuity_ = false; callbackError_ = 0; }
        worker_ = std::thread([this, surface] { Run(surface); });
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
    bool Create(int width, int height) {
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
        if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(surface, &window_) != 0 || !window_) {
            Fail("无法绑定视频显示区域");
            std::lock_guard<std::mutex> lock(mutex_); stats_.running = false; return;
        }
        neo::HevcStream stream; std::deque<neo::AccessUnit> ready;
        // Parameters belong to this worker session, never to the reusable facade.
        std::array<neo::Bytes, 3> parameters;
        bool waitingKey = true; unsigned retries = 0, startupLogs = 0; int64_t startedAt = 0, lastInput = 0, lastPts = 0;
        int64_t lastStatsLog = Now();
        auto reset = [&] {
            Destroy(); ready.clear(); waitingKey = true; stream.Reset(); parameters = {};
            std::lock_guard<std::mutex> lock(mutex_); frames_.Clear();
        };
        while (true) {
            neo::Bytes frame; bool discontinuity = false; int32_t error = 0;
            std::deque<Buffer> outputs;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                wake_.wait_for(lock, std::chrono::milliseconds(20), [&] {
                    return stopping_ || frames_.Size() || !outputs_.empty() || callbackError_ || discontinuity_ || (!ready.empty() && !inputs_.empty());
                });
                if (stopping_) break;
                discontinuity = discontinuity_; discontinuity_ = false; error = callbackError_; callbackError_ = 0;
                if (frames_.Size()) frame = frames_.Pop();
                outputs.swap(outputs_);
            }
            if (discontinuity || error) {
                if (error) { Fail("HEVC 解码异常，错误码 " + std::to_string(error)); ++retries; }
                reset(); outputs.clear(); frame.clear();
            }
            // Output handles cannot outlive their codec generation. Reset above
            // discards all handles from the destroyed generation before rendering.
            for (auto &output : outputs) {
                OH_AVCodecBufferAttr attr{};
                if (!codec_ || OH_AVBuffer_GetBufferAttr(output.data, &attr) != AV_ERR_OK) continue;
                if (attr.flags & (AVCODEC_BUFFER_FLAGS_EOS | AVCODEC_BUFFER_FLAGS_CODEC_DATA)) {
                    OH_VideoDecoder_FreeOutputBuffer(codec_, output.index); continue;
                }
                auto result = OH_VideoDecoder_RenderOutputBuffer(codec_, output.index);
                std::lock_guard<std::mutex> lock(mutex_);
                ++stats_.decoded; stats_.decodedAt = Now();
                if (result == AV_ERR_OK) { ++stats_.rendered; stats_.renderedAt = Now(); stats_.error.clear(); }
                else { ++stats_.errors; stats_.error = "视频送显失败，错误码 " + std::to_string(result); callbackError_ = result; }
            }
            if (retries < 3) {
                auto units = frame.empty() ? stream.Drain(Now()) : stream.Feed(frame, Now());
                { std::lock_guard<std::mutex> lock(mutex_); stats_.suppressed = stream.Suppressed(); stats_.reordered = stream.Reordered(); }
                for (auto &unit : units) {
                    bool picture = false;
                    bool changed = Parameters(unit.bytes, picture, parameters);
                    if (startupLogs++ < 8) OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoVideo",
                        "startup bytes=%{public}zu picture=%{public}d random=%{public}d config=%{public}d%{public}d%{public}d size=%{public}dx%{public}d",
                        unit.bytes.size(), picture, unit.randomAccess, !parameters[0].empty(), !parameters[1].empty(), !parameters[2].empty(), stream.Width(), stream.Height());
                    if (changed) { Destroy(); ready.clear(); waitingKey = true; }
                    if (!picture) continue;
                    if (waitingKey) {
                        if (!unit.randomAccess || parameters[0].empty() || parameters[1].empty() || parameters[2].empty()) continue;
                        int width = stream.Width(), height = stream.Height();
                        if (width <= 0 || height <= 0 || width > 8192 || height > 8192) continue;
                        if (!Create(width, height)) { ++retries; continue; }
                        neo::Bytes prefix;
                        for (const auto &parameter : parameters) prefix.insert(prefix.end(), parameter.begin(), parameter.end());
                        prefix.insert(prefix.end(), unit.bytes.begin(), unit.bytes.end()); unit.bytes = std::move(prefix);
                        waitingKey = false; startedAt = Now();
                        std::lock_guard<std::mutex> lock(mutex_); stats_.waitingForKey = false;
                    }
                    ready.push_back(std::move(unit));
                }
            }
            size_t readyBytes = 0; for (const auto &unit : ready) readyBytes += unit.bytes.size();
            if (ready.size() > 16 || readyBytes > 8 * 1024 * 1024) {
                { std::lock_guard<std::mutex> lock(mutex_); rejected_ += ready.size(); }
                reset();
            }
            while (codec_ && !ready.empty()) {
                Buffer input{};
                { std::lock_guard<std::mutex> lock(mutex_); if (inputs_.empty()) break; input = inputs_.front(); inputs_.pop_front(); }
                auto unit = std::move(ready.front()); ready.pop_front();
                auto capacity = OH_AVBuffer_GetCapacity(input.data); auto *address = OH_AVBuffer_GetAddr(input.data);
                if (!address || unit.bytes.size() > static_cast<size_t>(std::max(capacity, 0))) {
                    Fail("解码器输入空间不足"); ++retries; reset(); break;
                }
                std::memcpy(address, unit.bytes.data(), unit.bytes.size());
                OH_AVCodecBufferAttr attr{}; lastPts = std::max(Now() * 1000, lastPts + 1);
                attr.pts = lastPts; attr.size = static_cast<int32_t>(unit.bytes.size());
                attr.flags = unit.randomAccess ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;
                int code = OH_AVBuffer_SetBufferAttr(input.data, &attr);
                if (code == AV_ERR_OK) code = OH_VideoDecoder_PushInputBuffer(codec_, input.index);
                if (code != AV_ERR_OK) { Fail("提交视频帧失败，错误码 " + std::to_string(code)); ++retries; reset(); break; }
                lastInput = Now(); std::lock_guard<std::mutex> lock(mutex_); ++stats_.submitted;
            }
            int64_t lastOutput;
            { std::lock_guard<std::mutex> lock(mutex_); lastOutput = stats_.decodedAt; }
            if (codec_ && lastInput > std::max(startedAt, lastOutput) && Now() - std::max(startedAt, lastOutput) > 2500) {
                Fail("视频解码停滞，正在等待新的关键帧"); ++retries; reset();
            }
            if (retries >= 3) {
                std::lock_guard<std::mutex> lock(mutex_); frames_.Clear(); stats_.running = false;
                stats_.error = "视频恢复已暂停，请重新连接飞机或重新打开页面";
                break;
            }
            if (Now() - lastStatsLog >= 5000) {
                lastStatsLog = Now(); std::lock_guard<std::mutex> lock(mutex_);
                OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoVideo", "frames=%{public}llu decoded=%{public}llu rendered=%{public}llu queue=%{public}zu drops=%{public}llu errors=%{public}llu age=%{public}lld",
                    static_cast<unsigned long long>(stats_.assembled), static_cast<unsigned long long>(stats_.decoded),
                    static_cast<unsigned long long>(stats_.rendered), frames_.Size(), static_cast<unsigned long long>(frames_.Dropped()+rejected_),
                    static_cast<unsigned long long>(stats_.errors), static_cast<long long>(stats_.renderedAt ? Now()-stats_.renderedAt : -1));
            }
        }
        Destroy();
        if (window_) { OH_NativeWindow_DestroyNativeWindow(window_); window_ = nullptr; }
    }
    std::mutex mutex_; std::condition_variable wake_; std::thread worker_;
    bool stopping_ = true, discontinuity_ = false; int32_t callbackError_ = 0;
    uint64_t rejected_ = 0;
    neo::FrameQueue frames_; Stats stats_;
    std::deque<Buffer> inputs_, outputs_;
    OH_AVCodec *codec_ = nullptr; OHNativeWindow *window_ = nullptr;
    std::unique_ptr<Context> context_;
};
Preview preview;
napi_value Undefined(napi_env env) { napi_value result; napi_get_undefined(env, &result); return result; }
napi_value Start(napi_env env, napi_callback_info info) {
    size_t count = 1; napi_value arg; napi_get_cb_info(env, info, &count, &arg, nullptr, nullptr);
    char text[32]{}; size_t size = 0;
    if (count != 1 || napi_get_value_string_utf8(env, arg, text, sizeof(text), &size) != napi_ok || size == 0 || size >= sizeof(text)-1) {
        napi_throw_type_error(env, nullptr, "Invalid video surface ID"); return nullptr;
    }
    uint64_t id = 0;
    for (size_t i = 0; i < size; ++i) {
        if (text[i] < '0' || text[i] > '9' || id > (std::numeric_limits<uint64_t>::max() - 9) / 10) {
            napi_throw_type_error(env, nullptr, "Invalid video surface ID"); return nullptr;
        }
        id = id * 10 + text[i] - '0';
    }
    if (!id) { napi_throw_type_error(env, nullptr, "Empty video surface ID"); return nullptr; }
    preview.Start(id); return Undefined(env);
}
napi_value Stop(napi_env env, napi_callback_info) { preview.Stop(); return Undefined(env); }
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
    number("queued", queued); number("queuedBytes", bytes); number("queueDrops", dropped);
    number("assembledFrames", s.assembled); number("submittedFrames", s.submitted); number("decodedFrames", s.decoded);
    number("renderedFrames", s.rendered); number("decodeErrors", s.errors); number("suppressedParameters", s.suppressed);
    number("reorderedFrames", s.reordered); number("width", s.width); number("height", s.height);
    number("lastAssembledAgeMs", age(s.assembledAt)); number("lastDecodedAgeMs", age(s.decodedAt)); number("lastRenderedAgeMs", age(s.renderedAt));
    napi_value error; napi_create_string_utf8(env, s.error.c_str(), NAPI_AUTO_LENGTH, &error); napi_set_named_property(env, result, "lastError", error);
    return result;
}
napi_value Init(napi_env env, napi_value exports) {
    napi_add_env_cleanup_hook(env, [](void *) { preview.Stop(); }, nullptr);
    napi_property_descriptor props[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"submit", nullptr, Submit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"snapshot", nullptr, Snapshot, nullptr, nullptr, nullptr, napi_default, nullptr}};
    napi_define_properties(env, exports, sizeof(props)/sizeof(props[0]), props); return exports;
}
}
static napi_module module = {1, 0, nullptr, Init, "neovideo", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterNeoVideo() { napi_module_register(&module); }
