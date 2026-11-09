#include "MovieExport.h"
#include "MovieFrames.h"
#include "MovieAudio.h"
#include <hilog/log.h>
#include <multimedia/player_framework/native_avsource.h>
#include <multimedia/player_framework/native_avdemuxer.h>
#include <multimedia/player_framework/native_avmuxer.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace neo::movie {
namespace {
using Clock = std::chrono::steady_clock;
using Format = std::unique_ptr<OH_AVFormat, decltype(&OH_AVFormat_Destroy)>;
using Decoder = std::unique_ptr<OH_AVCodec, decltype(&OH_VideoDecoder_Destroy)>;
using Encoder = std::unique_ptr<OH_AVCodec, decltype(&OH_VideoEncoder_Destroy)>;
using AvBuffer = std::unique_ptr<OH_AVBuffer, decltype(&OH_AVBuffer_Destroy)>;
using Muxer = std::unique_ptr<OH_AVMuxer, decltype(&OH_AVMuxer_Destroy)>;
void Check(OH_AVErrCode code, const char *operation) {
    if (code != AV_ERR_OK) throw std::runtime_error(std::string(operation) + " (" + std::to_string(code) + ")");
}
void Need(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
void Cancelled(const std::atomic_bool &cancel) { Need(!cancel.load(), "Movie export cancelled"); }
int32_t Int(OH_AVFormat *f, const char *key, int32_t fallback = 0) {
    int32_t value = fallback; OH_AVFormat_GetIntValue(f, key, &value); return value;
}
int64_t Long(OH_AVFormat *f, const char *key, int64_t fallback = 0) {
    int64_t value = fallback; OH_AVFormat_GetLongValue(f, key, &value); return value;
}
std::string String(OH_AVFormat *f, const char *key) {
    const char *value = nullptr; OH_AVFormat_GetStringValue(f, key, &value); return value ? value : "";
}
struct Fd {
    int value = -1;
    ~Fd() { if (value >= 0) close(value); }
    Fd() = default;
    Fd(const Fd &) = delete;
    Fd &operator=(const Fd &) = delete;
};
struct Input {
    Fd fd;
    std::unique_ptr<OH_AVSource, decltype(&OH_AVSource_Destroy)> source{nullptr, OH_AVSource_Destroy};
    std::unique_ptr<OH_AVDemuxer, decltype(&OH_AVDemuxer_Destroy)> demux{nullptr, OH_AVDemuxer_Destroy};
    explicit Input(const std::string &path) {
        fd.value = open(path.c_str(), O_RDONLY | O_CLOEXEC);
        Need(fd.value >= 0, "Cannot open movie source");
        struct stat info{};
        Need(fstat(fd.value, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0, "Movie source is not a nonempty file");
        source.reset(OH_AVSource_CreateWithFD(fd.value, 0, info.st_size));
        Need(source != nullptr, "Cannot inspect movie source");
    }
};
struct Clip {
    std::string path, mime;
    int32_t track = -1, width = 0, height = 0, rotation = 0, primaries = 0, transfer = 0, matrix = 0;
    int64_t durationUs = 0;
};
void CheckSDR(OH_AVFormat *format) {
    const int transfer = Int(format, OH_MD_KEY_TRANSFER_CHARACTERISTICS);
    const int primaries = Int(format, OH_MD_KEY_COLOR_PRIMARIES);
    Need(transfer != TRANSFER_CHARACTERISTIC_PQ && transfer != TRANSFER_CHARACTERISTIC_HLG &&
        transfer != TRANSFER_CHARACTERISTIC_BT2020_10BIT && transfer != TRANSFER_CHARACTERISTIC_BT2020_12BIT &&
        primaries != COLOR_PRIMARY_BT2020, "HDR movies are not supported by this local export version");
}
Clip Probe(const std::string &path) {
    Input input(path);
    Format source(OH_AVSource_GetSourceFormat(input.source.get()), OH_AVFormat_Destroy);
    Need(source != nullptr, "Cannot read movie metadata");
    const int count = Int(source.get(), OH_MD_KEY_TRACK_COUNT);
    Need(count > 0 && count <= 32, "Invalid movie track count");
    for (int i = 0; i < count; ++i) {
        Format track(OH_AVSource_GetTrackFormat(input.source.get(), i), OH_AVFormat_Destroy);
        if (!track || Int(track.get(), OH_MD_KEY_TRACK_TYPE, -1) != MEDIA_TYPE_VID) continue;
        Clip clip;
        clip.path = path; clip.track = i; clip.mime = String(track.get(), OH_MD_KEY_CODEC_MIME);
        Need(clip.mime == "video/avc" || clip.mime == "video/hevc", "Only H.264 and H.265 input movies are supported");
        clip.width = Int(track.get(), OH_MD_KEY_WIDTH); clip.height = Int(track.get(), OH_MD_KEY_HEIGHT);
        clip.rotation = Int(track.get(), OH_MD_KEY_ROTATION, Int(source.get(), OH_MD_KEY_ROTATION));
        clip.durationUs = Long(track.get(), OH_MD_KEY_DURATION, Long(source.get(), OH_MD_KEY_DURATION));
        Need(clip.width >= 2 && clip.height >= 2 && clip.width <= 4096 && clip.height <= 4096 &&
            static_cast<int64_t>(clip.width) * clip.height <= 4096LL * 2160, "Movie dimensions exceed this export version");
        Need(clip.rotation == 0 || clip.rotation == 90 || clip.rotation == 180 || clip.rotation == 270,
             "Unsupported movie rotation");
        Need(clip.durationUs > 0 && clip.durationUs <= 3600000000LL, "Invalid or unsupported movie duration");
        CheckSDR(track.get());
        const int profile = Int(track.get(), OH_MD_KEY_PROFILE, -1);
        if (clip.mime == "video/hevc") Need(profile <= HEVC_PROFILE_MAIN, "10-bit/HDR HEVC export is not supported");
        clip.primaries = Int(track.get(), OH_MD_KEY_COLOR_PRIMARIES, COLOR_PRIMARY_BT709);
        clip.transfer = Int(track.get(), OH_MD_KEY_TRANSFER_CHARACTERISTICS, TRANSFER_CHARACTERISTIC_BT709);
        clip.matrix = Int(track.get(), OH_MD_KEY_MATRIX_COEFFICIENTS, MATRIX_COEFFICIENT_BT709);
        return clip;
    }
    throw std::runtime_error("Movie source has no video track");
}
struct Snapshot {
    uint32_t id = 0;
    std::string stage = "probing", error, outputPath;
    double progress = 0;
    int64_t durationMs = 0;
};
struct Job {
    Snapshot snapshot;
    std::vector<std::string> sources;
    std::string music;
    std::atomic_bool cancel{false};
};
using Progress = std::function<void(const char *, double, int64_t)>;

// The muxer is started only after actual SPS/PPS and AAC AudioSpecificConfig exist.
// Encoded video is streamed directly to disk; only the AAC music samples and two raw frames are retained.
class VideoWriter {
public:
    VideoWriter(const std::string &path, Size canvas, const Clip &first, MusicTrack &music,
                const std::atomic_bool &cancel, int64_t duration)
        : canvas_(canvas), music_(music), cancel_(cancel), duration_(duration), path_(path) {
        fd_.value = open(path.c_str(), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        Need(fd_.value >= 0, "Cannot create a new movie output; destination may already exist");
        owned_ = true;
        try {
            muxer_.reset(OH_AVMuxer_Create(fd_.value, AV_OUTPUT_FORMAT_MPEG_4));
            Need(muxer_ != nullptr, "Cannot create MP4 muxer");
            Format meta(OH_AVFormat_Create(), OH_AVFormat_Destroy);
            Need(meta != nullptr, "Cannot create MP4 metadata");
            const char *credit = "Titan by Scott Buckley / CC BY 4.0 / https://www.scottbuckley.com.au/library/titan/; looped and faded";
            OH_AVFormat_SetStringValue(meta.get(), OH_MD_KEY_TITLE, "Neo movie / Titan");
            OH_AVFormat_SetStringValue(meta.get(), OH_MD_KEY_ARTIST, "Scott Buckley");
            OH_AVFormat_SetStringValue(meta.get(), OH_MD_KEY_COPYRIGHT, credit);
            OH_AVFormat_SetStringValue(meta.get(), OH_MD_KEY_COMMENT, credit);
            Check(OH_AVMuxer_SetFormat(muxer_.get(), meta.get()), "Cannot write music credit metadata");
            encoder_.reset(OH_VideoEncoder_CreateByMime("video/avc"));
            Need(encoder_ != nullptr, "H.264 video encoder is unavailable");
            Format format(OH_AVFormat_CreateVideoFormat("video/avc", canvas.width, canvas.height), OH_AVFormat_Destroy);
            Need(format != nullptr, "Cannot create encoder format");
            OH_AVFormat_SetIntValue(format.get(), OH_MD_KEY_ENABLE_SYNC_MODE, 1);
            OH_AVFormat_SetIntValue(format.get(), OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
            OH_AVFormat_SetDoubleValue(format.get(), OH_MD_KEY_FRAME_RATE, 30.0);
            OH_AVFormat_SetLongValue(format.get(), OH_MD_KEY_BITRATE,
                std::clamp<int64_t>(static_cast<int64_t>(canvas.width) * canvas.height * 3, 1500000, 8000000));
            OH_AVFormat_SetIntValue(format.get(), OH_MD_KEY_I_FRAME_INTERVAL, 1000);
            OH_AVFormat_SetIntValue(format.get(), OH_MD_KEY_PROFILE, AVC_PROFILE_BASELINE);
            OH_AVFormat_SetIntValue(format.get(), OH_MD_KEY_VIDEO_ENCODER_ENABLE_B_FRAME, 0);
            OH_AVFormat_SetIntValue(format.get(), OH_MD_KEY_RANGE_FLAG, 0);
            OH_AVFormat_SetIntValue(format.get(), OH_MD_KEY_COLOR_PRIMARIES, first.primaries);
            OH_AVFormat_SetIntValue(format.get(), OH_MD_KEY_TRANSFER_CHARACTERISTICS, first.transfer);
            OH_AVFormat_SetIntValue(format.get(), OH_MD_KEY_MATRIX_COEFFICIENTS, first.matrix);
            Check(OH_VideoEncoder_Configure(encoder_.get(), format.get()), "Cannot configure H.264 encoder");
            Check(OH_VideoEncoder_Prepare(encoder_.get()), "Cannot prepare H.264 encoder");
            Check(OH_VideoEncoder_Start(encoder_.get()), "Cannot start H.264 encoder");
        } catch (...) { Cleanup(); throw; }
    }
    ~VideoWriter() { Cleanup(); }
    void Frame(const std::vector<uint8_t> &packed, int64_t pts) {
        Cancelled(cancel_);
        const uint32_t index = InputIndex();
        OH_AVBuffer *buffer = OH_VideoEncoder_GetInputBuffer(encoder_.get(), index);
        Need(buffer != nullptr, "Cannot obtain encoder input buffer");
        Format layout(OH_VideoEncoder_GetInputDescription(encoder_.get()), OH_AVFormat_Destroy);
        Need(layout != nullptr, "Cannot obtain encoder input layout");
        const int stride = Int(layout.get(), OH_MD_KEY_VIDEO_STRIDE, canvas_.width);
        const int slice = Int(layout.get(), OH_MD_KEY_VIDEO_SLICE_HEIGHT, canvas_.height);
        Need(stride >= canvas_.width && slice >= canvas_.height && stride <= 8192 && slice <= 8192 && !(slice & 1),
            "Unsupported H.264 encoder input layout");
        const int64_t size = static_cast<int64_t>(stride) * slice * 3 / 2;
        auto *data = OH_AVBuffer_GetAddr(buffer);
        Need(data && size <= OH_AVBuffer_GetCapacity(buffer), "Encoder buffer is too small");
        std::memset(data, 16, stride * slice);
        std::memset(data + stride * slice, 128, stride * slice / 2);
        for (int y = 0; y < canvas_.height; ++y)
            std::memcpy(data + y * stride, packed.data() + y * canvas_.width, canvas_.width);
        for (int y = 0; y < canvas_.height / 2; ++y)
            std::memcpy(data + stride * slice + y * stride,
                packed.data() + canvas_.width * canvas_.height + y * canvas_.width, canvas_.width);
        OH_AVCodecBufferAttr attr{}; attr.pts = pts; attr.size = static_cast<int32_t>(size);
        Check(OH_AVBuffer_SetBufferAttr(buffer, &attr), "Cannot set encoder frame");
        Check(OH_VideoEncoder_PushInputBuffer(encoder_.get(), index), "Cannot send encoder frame");
        ++framesSent_;
        Drain(false);
    }
    void Finish() {
        Cancelled(cancel_);
        const uint32_t index = InputIndex();
        auto *buffer = OH_VideoEncoder_GetInputBuffer(encoder_.get(), index);
        Need(buffer != nullptr, "Cannot obtain video EOS input buffer");
        OH_AVCodecBufferAttr eos{}; eos.pts = duration_; eos.flags = AVCODEC_BUFFER_FLAGS_EOS;
        Check(OH_AVBuffer_SetBufferAttr(buffer, &eos), "Cannot set video EOS");
        Check(OH_VideoEncoder_PushInputBuffer(encoder_.get(), index), "Cannot send video EOS");
        const auto deadline = Clock::now() + std::chrono::seconds(30);
        while (!eos_) { Cancelled(cancel_); Drain(true); Need(Clock::now() < deadline, "H.264 encoder EOS timed out"); }
        Need(started_ && framesWritten_ > 0 && framesWritten_ == framesSent_, "Video encoder did not finish every frame");
        WriteAudio(duration_ + 1000000);
        Need(audioCursor_ == music_.samples.size(), "Music encoder samples were not fully written");
        Check(OH_AVMuxer_Stop(muxer_.get()), "Cannot finalize MP4");
        started_ = false;
        muxer_.reset(); encoder_.reset();
        Need(fsync(fd_.value) == 0, "Cannot flush completed MP4");
        const int completedFd = fd_.value; fd_.value = -1;
        Need(close(completedFd) == 0, "Cannot close completed MP4");
    }
    void Commit() { owned_ = false; }
private:
    void Cleanup() {
        encoder_.reset(); muxer_.reset();
        if (fd_.value >= 0) { close(fd_.value); fd_.value = -1; }
        if (owned_) { unlink(path_.c_str()); owned_ = false; }
    }
    uint32_t InputIndex() {
        auto deadline = Clock::now() + std::chrono::seconds(30);
        for (;;) {
            Cancelled(cancel_);
            uint32_t index = 0;
            auto code = OH_VideoEncoder_QueryInputBuffer(encoder_.get(), &index, 10000);
            if (code == AV_ERR_OK) return index;
            if (code != AV_ERR_TRY_AGAIN_LATER) Check(code, "Cannot query encoder input");
            Drain(false);
            Need(Clock::now() < deadline, "H.264 encoder input timed out");
        }
    }
    void StartMuxer() {
        if (started_) return;
        Format format(OH_VideoEncoder_GetOutputDescription(encoder_.get()), OH_AVFormat_Destroy);
        Need(format != nullptr, "Cannot obtain encoded video description");
        // This device reports codec parameters without the MIME in its output
        // description. AddTrack requires the MIME even for a known AVC encoder.
        Need(OH_AVFormat_SetStringValue(format.get(), OH_MD_KEY_CODEC_MIME, "video/avc"),
             "Cannot identify the H.264 mux track");
        if (!config_.empty()) OH_AVFormat_SetBuffer(format.get(), OH_MD_KEY_CODEC_CONFIG, config_.data(), config_.size());
        uint8_t *config = nullptr; size_t size = 0;
        Need(OH_AVFormat_GetBuffer(format.get(), OH_MD_KEY_CODEC_CONFIG, &config, &size) && config && size > 0,
             "H.264 encoder did not provide SPS/PPS codec configuration");
        Need(music_.format && !music_.samples.empty(), "Music encoder did not produce AAC samples");
        const char *videoDescription = OH_AVFormat_DumpInfo(format.get());
        const char *audioDescription = OH_AVFormat_DumpInfo(music_.format.get());
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie", "Mux video %{public}s audio %{public}s",
            videoDescription ? videoDescription : "unavailable", audioDescription ? audioDescription : "unavailable");
        Check(OH_AVMuxer_AddTrack(muxer_.get(), &videoTrack_, format.get()), "Cannot add H.264 track");
        Check(OH_AVMuxer_AddTrack(muxer_.get(), &audioTrack_, music_.format.get()), "Cannot add Titan AAC track");
        Check(OH_AVMuxer_Start(muxer_.get()), "Cannot start MP4 muxer");
        started_ = true;
    }
    void WriteAudio(int64_t until) {
        while (audioCursor_ < music_.samples.size() && music_.samples[audioCursor_].attr.pts <= until) {
            Cancelled(cancel_);
            const auto &sample = music_.samples[audioCursor_];
            Need(!sample.bytes.empty(), "Empty AAC music sample");
            AvBuffer buffer(OH_AVBuffer_Create(static_cast<int32_t>(sample.bytes.size())), OH_AVBuffer_Destroy);
            Need(buffer != nullptr && OH_AVBuffer_GetAddr(buffer.get()), "Cannot allocate AAC mux buffer");
            std::memcpy(OH_AVBuffer_GetAddr(buffer.get()), sample.bytes.data(), sample.bytes.size());
            OH_AVCodecBufferAttr attr = sample.attr; attr.offset = 0; attr.size = static_cast<int32_t>(sample.bytes.size());
            attr.flags &= ~static_cast<uint32_t>(AVCODEC_BUFFER_FLAGS_EOS | AVCODEC_BUFFER_FLAGS_CODEC_DATA);
            Check(OH_AVBuffer_SetBufferAttr(buffer.get(), &attr), "Cannot set AAC mux sample");
            Check(OH_AVMuxer_WriteSampleBuffer(muxer_.get(), audioTrack_, buffer.get()), "Cannot write Titan AAC sample");
            ++audioCursor_;
        }
    }
    void Drain(bool wait) {
        for (int n = 0; n < 32 && !eos_; ++n) {
            Cancelled(cancel_);
            uint32_t index = 0;
            const auto code = OH_VideoEncoder_QueryOutputBuffer(encoder_.get(), &index, wait && n == 0 ? 10000 : 0);
            if (code == AV_ERR_TRY_AGAIN_LATER) return;
            if (code == AV_ERR_STREAM_CHANGED) continue;
            Check(code, "Cannot query encoded video");
            try {
                auto *buffer = OH_VideoEncoder_GetOutputBuffer(encoder_.get(), index);
                OH_AVCodecBufferAttr attr{};
                Need(buffer != nullptr, "Cannot obtain encoded video buffer");
                Check(OH_AVBuffer_GetBufferAttr(buffer, &attr), "Cannot read encoded video attributes");
                if (framesWritten_ < 3 || (attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA)) {
                    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
                        "H.264 output pts=%{public}lld size=%{public}d flags=%{public}u written=%{public}lld",
                        static_cast<long long>(attr.pts), attr.size, attr.flags, static_cast<long long>(framesWritten_));
                }
                const bool endMarker = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) && attr.pts == duration_ &&
                    framesWritten_ == framesSent_;
                if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
                    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
                        "H.264 end buffer pts=%{public}lld size=%{public}d flags=%{public}u marker=%{public}d sent=%{public}lld written=%{public}lld",
                        static_cast<long long>(attr.pts), attr.size, attr.flags, endMarker ? 1 : 0,
                        static_cast<long long>(framesSent_), static_cast<long long>(framesWritten_));
                }
                // The device's separate EOS buffer retains a nonzero size and
                // the submitted EOS timestamp. It is not an extra input picture.
                // A final picture combined with EOS still passes through below.
                if (endMarker) {
                    // All submitted pictures are already accounted for.
                } else if (attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) {
                    auto *data = OH_AVBuffer_GetAddr(buffer);
                    Need(data && attr.offset >= 0 && attr.size > 0 &&
                        static_cast<int64_t>(attr.offset) + attr.size <= OH_AVBuffer_GetCapacity(buffer), "Invalid H.264 codec data");
                    Need(config_.size() + static_cast<size_t>(attr.size) <= 1024 * 1024, "H.264 codec configuration is too large");
                    config_.insert(config_.end(), data + attr.offset, data + attr.offset + attr.size);
                } else if (attr.size > 0) {
                    StartMuxer();
                    Need(attr.pts >= 0 && attr.pts > lastVideoPts_, "H.264 encoder output timestamp did not advance");
                    Check(OH_AVMuxer_WriteSampleBuffer(muxer_.get(), videoTrack_, buffer), "Cannot write H.264 sample");
                    lastVideoPts_ = attr.pts; ++framesWritten_;
                    WriteAudio(attr.pts + 33333);
                }
                if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
                    eos_ = true;
                    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
                        "H.264 EOS sent=%{public}lld written=%{public}lld lastPts=%{public}lld",
                        static_cast<long long>(framesSent_), static_cast<long long>(framesWritten_),
                        static_cast<long long>(lastVideoPts_));
                }
            } catch (...) { OH_VideoEncoder_FreeOutputBuffer(encoder_.get(), index); throw; }
            Check(OH_VideoEncoder_FreeOutputBuffer(encoder_.get(), index), "Cannot release encoded video buffer");
        }
    }
    Size canvas_;
    MusicTrack &music_;
    const std::atomic_bool &cancel_;
    int64_t duration_;
    std::string path_;
    Fd fd_;
    Muxer muxer_{nullptr, OH_AVMuxer_Destroy};
    Encoder encoder_{nullptr, OH_VideoEncoder_Destroy};
    std::vector<uint8_t> config_;
    size_t audioCursor_ = 0;
    int32_t videoTrack_ = -1, audioTrack_ = -1;
    int64_t lastVideoPts_ = -1, framesSent_ = 0, framesWritten_ = 0;
    bool started_ = false, eos_ = false, owned_ = false;
};

void DecodeClip(const Clip &clip, Size canvas, const std::atomic_bool &cancel,
                const std::function<void(std::vector<uint8_t>, int64_t)> &frame) {
    Input input(clip.path);
    Format format(OH_AVSource_GetTrackFormat(input.source.get(), clip.track), OH_AVFormat_Destroy);
    Need(format != nullptr, "Cannot reopen video track");
    input.demux.reset(OH_AVDemuxer_CreateWithSource(input.source.get()));
    Need(input.demux != nullptr, "Cannot create movie demuxer");
    Check(OH_AVDemuxer_SelectTrackByID(input.demux.get(), clip.track), "Cannot select video track");
    Decoder decoder(OH_VideoDecoder_CreateByMime(clip.mime.c_str()), OH_VideoDecoder_Destroy);
    Need(decoder != nullptr, "Video decoder is unavailable");
    OH_AVFormat_SetIntValue(format.get(), OH_MD_KEY_ENABLE_SYNC_MODE, 1);
    OH_AVFormat_SetIntValue(format.get(), OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetIntValue(format.get(), OH_MD_KEY_ROTATION, 0); // rotate pixels ourselves once
    Check(OH_VideoDecoder_Configure(decoder.get(), format.get()), "Cannot configure movie decoder");
    Check(OH_VideoDecoder_Prepare(decoder.get()), "Cannot prepare movie decoder");
    Check(OH_VideoDecoder_Start(decoder.get()), "Cannot start movie decoder");
    bool inputEOS = false, outputEOS = false;
    int64_t firstPts = -1, lastPts = -1, count = 0;
    auto lastActivity = Clock::now();
    Format layout(nullptr, OH_AVFormat_Destroy);
    while (!outputEOS) {
        Cancelled(cancel);
        bool activity = false;
        // Always drain before requesting another input; decoder retains/reorders B pictures internally.
        for (int n = 0; n < 16 && !outputEOS; ++n) {
            uint32_t index = 0;
            auto code = OH_VideoDecoder_QueryOutputBuffer(decoder.get(), &index, 0);
            if (code == AV_ERR_TRY_AGAIN_LATER) break;
            if (code == AV_ERR_STREAM_CHANGED) { layout.reset(); activity = true; continue; }
            Check(code, "Cannot query decoded movie frame");
            activity = true;
            try {
                OH_AVBuffer *buffer = OH_VideoDecoder_GetOutputBuffer(decoder.get(), index);
                OH_AVCodecBufferAttr attr{};
                Need(buffer != nullptr, "Cannot obtain decoded movie frame");
                Check(OH_AVBuffer_GetBufferAttr(buffer, &attr), "Cannot read movie frame attributes");
                if (count < 3) {
                    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
                        "Decoded video pts=%{public}lld size=%{public}d flags=%{public}u pictures=%{public}lld",
                        static_cast<long long>(attr.pts), attr.size, attr.flags, static_cast<long long>(count));
                }
                if (!(attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) &&
                    (attr.size > 0 || !(attr.flags & AVCODEC_BUFFER_FLAGS_EOS))) {
                    if (!layout) layout.reset(OH_VideoDecoder_GetOutputDescription(decoder.get()));
                    Need(layout != nullptr, "Decoder did not report picture layout");
                    CheckSDR(layout.get());
                    const int pixel = Int(layout.get(), OH_MD_KEY_PIXEL_FORMAT, -1);
                    Need(pixel == AV_PIXEL_FORMAT_NV12 || pixel == AV_PIXEL_FORMAT_NV21,
                        "Decoder output must be 8-bit NV12 or NV21; other formats cannot be safely exported");
                    const int width = Int(layout.get(), OH_MD_KEY_VIDEO_PIC_WIDTH, Int(layout.get(), OH_MD_KEY_WIDTH, clip.width));
                    const int height = Int(layout.get(), OH_MD_KEY_VIDEO_PIC_HEIGHT, Int(layout.get(), OH_MD_KEY_HEIGHT, clip.height));
                    Need(width == clip.width && height == clip.height, "Dynamic video size changes are unsupported");
                    const int left = Int(layout.get(), OH_MD_KEY_VIDEO_CROP_LEFT), top = Int(layout.get(), OH_MD_KEY_VIDEO_CROP_TOP);
                    Need(left == 0 && top == 0, "Nonzero decoder picture crop is unsupported");
                    FrameView view{OH_AVBuffer_GetAddr(buffer), static_cast<size_t>(std::max(0, OH_AVBuffer_GetCapacity(buffer))),
                        width, height, Int(layout.get(), OH_MD_KEY_VIDEO_STRIDE), Int(layout.get(), OH_MD_KEY_VIDEO_SLICE_HEIGHT),
                        attr.offset, pixel == AV_PIXEL_FORMAT_NV21,
                        Int(layout.get(), OH_MD_KEY_RANGE_FLAG, Int(format.get(), OH_MD_KEY_RANGE_FLAG)) != 0};
                    if (count == 0) firstPts = attr.pts;
                    const int64_t pts = attr.pts - firstPts;
                    Need(pts >= 0 && (count == 0 || pts >= lastPts), "Decoder did not return presentation-ordered frames");
                    Need(MovieSourcePtsFits(pts, clip.durationUs), "Source duration metadata ends before decoded video pictures");
                    frame(RenderMovieFrame(view, canvas, clip.rotation, 1, false), pts);
                    lastPts = pts; ++count;
                }
                if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) outputEOS = true;
            } catch (...) { OH_VideoDecoder_FreeOutputBuffer(decoder.get(), index); throw; }
            Check(OH_VideoDecoder_FreeOutputBuffer(decoder.get(), index), "Cannot release movie frame");
        }
        if (!inputEOS) {
            uint32_t index = 0;
            auto code = OH_VideoDecoder_QueryInputBuffer(decoder.get(), &index, 10000);
            if (code != AV_ERR_TRY_AGAIN_LATER) {
                Check(code, "Cannot query movie decoder input");
                auto *buffer = OH_VideoDecoder_GetInputBuffer(decoder.get(), index);
                Need(buffer != nullptr, "Cannot obtain movie decoder input");
                Check(OH_AVDemuxer_ReadSampleBuffer(input.demux.get(), clip.track, buffer), "Cannot read source video sample");
                OH_AVCodecBufferAttr attr{};
                Check(OH_AVBuffer_GetBufferAttr(buffer, &attr), "Cannot read source sample attributes");
                inputEOS = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
                Check(OH_VideoDecoder_PushInputBuffer(decoder.get(), index), "Cannot send movie decoder input");
                activity = true;
            }
        }
        if (activity) lastActivity = Clock::now();
        else std::this_thread::sleep_for(std::chrono::milliseconds(1));
        Need(Clock::now() - lastActivity < std::chrono::seconds(30), "Movie decoder stalled before EOS");
    }
    Need(count > 0, "Source movie decoded no pictures");
    // Sparse VFR tracks legitimately hold their final picture through the declared media end.
}

void ValidateCompleted(const std::string &path, int64_t expectedDurationUs, const std::atomic_bool &cancel) {
    Input input(path);
    Format source(OH_AVSource_GetSourceFormat(input.source.get()), OH_AVFormat_Destroy);
    Need(source != nullptr, "Completed MP4 cannot be reopened");
    const int count = Int(source.get(), OH_MD_KEY_TRACK_COUNT);
    Need(count == 2, "Completed MP4 must contain both video and Titan audio");
    bool video = false, audio = false;
    std::vector<int64_t> packetDurations, packetCounts;
    for (int i = 0; i < count; ++i) {
        Format track(OH_AVSource_GetTrackFormat(input.source.get(), i), OH_AVFormat_Destroy);
        Need(track != nullptr, "Completed MP4 track is unreadable");
        const auto mime = String(track.get(), OH_MD_KEY_CODEC_MIME);
        const int type = Int(track.get(), OH_MD_KEY_TRACK_TYPE, -1);
        video = video || (type == MEDIA_TYPE_VID && mime == "video/avc");
        audio = audio || (type == MEDIA_TYPE_AUD && mime == "audio/mp4a-latm");
        const bool videoTrack = type == MEDIA_TYPE_VID && mime == "video/avc";
        if (!videoTrack) Need(type == MEDIA_TYPE_AUD && mime == "audio/mp4a-latm" &&
            Int(track.get(), OH_MD_KEY_AUD_SAMPLE_RATE) == 48000, "Completed MP4 music is not 48kHz AAC");
        const int64_t packetDuration = videoTrack ? 33334 : 21334; // 30fps / AAC-LC 1024 samples at 48kHz
        packetDurations.push_back(packetDuration);
        packetCounts.push_back(MoviePacketCount(expectedDurationUs, !videoTrack));
        const int64_t duration = Long(track.get(), OH_MD_KEY_DURATION);
        // Some AVSource versions omit per-track duration; actual packets are always checked below.
        if (duration > 0) Need(MovieTrackDurationFits(duration, expectedDurationUs, packetDuration),
            "Completed MP4 has an incomplete audio or video track duration");
    }
    Need(video && audio, "Completed MP4 audio/video tracks are invalid");
    input.demux.reset(OH_AVDemuxer_CreateWithSource(input.source.get()));
    Need(input.demux != nullptr, "Cannot verify completed MP4 samples");
    AvBuffer sample(OH_AVBuffer_Create(8 * 1024 * 1024), OH_AVBuffer_Destroy);
    Need(sample != nullptr, "Cannot allocate MP4 verification buffer");
    for (int i = 0; i < count; ++i) {
        Check(OH_AVDemuxer_SelectTrackByID(input.demux.get(), i), "Cannot verify completed MP4 track");
        // Reading the preceding track to EOF also advances the shared demux
        // position. Rewind each newly selected track before checking its data.
        Check(OH_AVDemuxer_SeekToTime(input.demux.get(), 0, SEEK_MODE_PREVIOUS_SYNC),
              "Cannot rewind completed MP4 verification track");
        bool ended = false;
        int64_t lastPts = -1, sampleCount = 0, reads = 0;
        // Verify the real end of both tracks, rather than trusting file/global duration to hide an early audio EOS.
        while (!ended) {
            Cancelled(cancel);
            Need(++reads <= packetCounts[i] + 16, "Completed MP4 track did not reach EOS");
            Check(OH_AVDemuxer_ReadSampleBuffer(input.demux.get(), i, sample.get()), "Cannot verify completed MP4 sample");
            OH_AVCodecBufferAttr attr{};
            Check(OH_AVBuffer_GetBufferAttr(sample.get(), &attr), "Cannot verify MP4 sample attributes");
            if (reads <= 3 || (attr.flags & AVCODEC_BUFFER_FLAGS_EOS)) {
                OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
                    "Verify MP4 track=%{public}d read=%{public}lld pts=%{public}lld size=%{public}d flags=%{public}u counted=%{public}lld",
                    i, static_cast<long long>(reads), static_cast<long long>(attr.pts), attr.size,
                    attr.flags, static_cast<long long>(sampleCount));
            }
            // Demuxed keyframes may carry both SYNC_FRAME and CODEC_DATA:
            // they are actual media samples containing parameter sets, not
            // separate encoder configuration events. Count their PTS as well.
            if (attr.size > 0) {
                Need(attr.pts >= 0 && attr.pts > lastPts, "Completed MP4 track timestamps are invalid");
                if (lastPts < 0) Need(attr.pts <= 1000, "Completed MP4 track starts late");
                else Need(attr.pts - lastPts <= packetDurations[i] + 1000, "Completed MP4 track has a missing packet");
                lastPts = attr.pts;
                Need(++sampleCount <= packetCounts[i] + 2, "Completed MP4 has too many packets");
            }
            ended = (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) != 0;
        }
        Need(MovieTimelineCovers(lastPts, packetDurations[i], expectedDurationUs),
            "Completed MP4 audio or video packets end before the movie timeline");
        Check(OH_AVDemuxer_UnselectTrackByID(input.demux.get(), i), "Cannot release MP4 verification track");
    }
}

void Export(Job &job, const Progress &progress) {
    std::vector<Clip> clips;
    int64_t durationUs = 0, frames = 0;
    for (const auto &path : job.sources) {
        Cancelled(job.cancel);
        clips.push_back(Probe(path)); durationUs += clips.back().durationUs;
        frames += MovieFrameCount(clips.back().durationUs);
        progress("probing", .08 * clips.size() / job.sources.size(), durationUs / 1000);
    }
    Need(durationUs > 0 && durationUs <= 3600000000LL, "Movie exceeds the local export duration limit");
    // Round each segment once, so sub-frame clips are never silently omitted by a global sampling grid.
    // The difference from the sum of original durations is less than one encoded frame per source clip.
    durationUs = MovieFrameTime(frames);
    const Size canvas = MovieCanvas(clips[0].width, clips[0].height, clips[0].rotation);
    Need(canvas.width >= 192 && canvas.height >= 40, "Movie is too small for readable music credit");
    for (const auto &clip : clips) {
        Need(clip.primaries == clips[0].primaries && clip.transfer == clips[0].transfer && clip.matrix == clips[0].matrix,
             "Mixed video color spaces require conversion and cannot be exported by this version");
    }
    progress("rendering", .08, durationUs / 1000);
    auto music = BuildMusicTrack(job.music, durationUs, job.cancel,
        [&](double value) { progress("rendering", .08 + .14 * std::clamp(value, 0.0, 1.0), durationUs / 1000); });
    Cancelled(job.cancel);
    VideoWriter writer(job.snapshot.outputPath, canvas, clips[0], music, job.cancel, durationUs);
    int64_t next = 0;
    for (const auto &clip : clips) {
        const int64_t clipStart = next, clipFrames = MovieFrameCount(clip.durationUs);
        std::vector<uint8_t> previous;
        auto emitUntil = [&](int64_t until) {
            while (next - clipStart < clipFrames &&
                   MovieClipFrameTime(next - clipStart, clipFrames, clip.durationUs) < until) {
                Cancelled(job.cancel);
                Need(!previous.empty(), "Source movie has no frame to render");
                const auto pts = MovieFrameTime(next);
                FrameView packed{previous.data(), previous.size(), canvas.width, canvas.height,
                    canvas.width, canvas.height, 0, false, false};
                // Sample the fade at the exposure midpoint. Sampling t=0 alone would turn a one-frame movie black.
                const auto exposure = pts + std::min<int64_t>(16666, durationUs - pts);
                auto output = RenderMovieFrame(packed, canvas, 0, VideoGain(exposure, durationUs), durationUs - pts <= 3000000);
                writer.Frame(output, pts);
                ++next;
                progress("rendering", .22 + .72 * static_cast<double>(next) / frames, durationUs / 1000);
            }
        };
        DecodeClip(clip, canvas, job.cancel, [&](std::vector<uint8_t> image, int64_t pts) {
            if (previous.empty()) previous = std::move(image);
            else { emitUntil(std::min(pts, clip.durationUs)); previous = std::move(image); }
        });
        emitUntil(clip.durationUs);
    }
    Need(next == frames, "Movie timeline did not cover all source clips");
    progress("finalizing", .95, durationUs / 1000);
    writer.Finish();
    Cancelled(job.cancel);
    ValidateCompleted(job.snapshot.outputPath, durationUs, job.cancel);
    Cancelled(job.cancel);
    writer.Commit();
}

bool Terminal(const std::string &stage) { return stage == "completed" || stage == "failed" || stage == "cancelled"; }
// One persistent worker avoids joining an active codec from the JS thread. Jobs retain immutable source order.
class ExportService {
public:
    ExportService() : worker_([this] { Loop(); }) {}
    ~ExportService() {
        { std::lock_guard<std::mutex> lock(mutex_); stopping_ = true; if (active_) active_->cancel = true; }
        condition_.notify_all(); if (worker_.joinable()) worker_.join();
    }
    uint32_t Start(std::vector<std::string> sources, std::string output, std::string music) {
        std::lock_guard<std::mutex> lock(mutex_);
        Need(!active_ || Terminal(active_->snapshot.stage), "A movie export is already running or cancelling");
        Need(sequence_ < 0xFFFFFFFFu, "Movie export identifier limit reached");
        auto job = std::make_shared<Job>();
        job->snapshot.id = ++sequence_; job->snapshot.outputPath = std::move(output);
        job->sources = std::move(sources); job->music = std::move(music);
        active_ = job; jobs_[sequence_] = job;
        while (jobs_.size() > 32) jobs_.erase(jobs_.begin());
        condition_.notify_one(); return sequence_;
    }
    Snapshot Read(uint32_t id) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = jobs_.find(id);
        if (found != jobs_.end()) return found->second->snapshot;
        Snapshot missing; missing.id = id; missing.stage = "failed"; missing.error = "Unknown movie export"; return missing;
    }
    void Cancel(uint32_t id) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = jobs_.find(id);
        if (found != jobs_.end() && !Terminal(found->second->snapshot.stage)) found->second->cancel = true;
    }
private:
    void Loop() {
        for (;;) {
            std::shared_ptr<Job> job;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                condition_.wait(lock, [&] { return stopping_ || (active_ && !Terminal(active_->snapshot.stage)); });
                if (stopping_) return;
                job = active_;
            }
            std::string stage = "completed", error;
            try {
                Export(*job, [&](const char *phase, double value, int64_t duration) {
                    std::lock_guard<std::mutex> lock(mutex_);
                    job->snapshot.stage = phase;
                    job->snapshot.progress = std::max(job->snapshot.progress, std::clamp(value, 0.0, .99));
                    job->snapshot.durationMs = duration;
                });
            } catch (const std::exception &e) {
                stage = job->cancel.load() ? "cancelled" : "failed"; error = e.what();
            } catch (...) { stage = job->cancel.load() ? "cancelled" : "failed"; error = "Unexpected local movie export failure"; }
            {
                std::lock_guard<std::mutex> lock(mutex_);
                job->snapshot.stage = stage; job->snapshot.error = error;
                if (stage == "completed") job->snapshot.progress = 1;
            }
        }
    }
    std::mutex mutex_;
    std::condition_variable condition_;
    std::map<uint32_t, std::shared_ptr<Job>> jobs_;
    std::shared_ptr<Job> active_;
    uint32_t sequence_ = 0;
    bool stopping_ = false;
    std::thread worker_;
};
ExportService &Service() { static ExportService instance; return instance; }

std::string JsString(napi_env env, napi_value value) {
    size_t size = 0;
    Need(napi_get_value_string_utf8(env, value, nullptr, 0, &size) == napi_ok && size > 0 && size <= 4096,
        "Movie paths must be nonempty strings of at most 4096 bytes");
    std::string text(size + 1, '\0');
    Need(napi_get_value_string_utf8(env, value, text.data(), text.size(), &size) == napi_ok, "Invalid movie path string");
    text.resize(size);
    Need(text.front() == '/' && text.find('\0') == std::string::npos, "Movie paths must be absolute local filesystem paths");
    return text;
}
uint32_t JsId(napi_env env, napi_value value) {
    double id = 0;
    Need(napi_get_value_double(env, value, &id) == napi_ok && id >= 1 && id <= 4294967295.0 && id == static_cast<uint32_t>(id),
        "Invalid movie export identifier");
    return static_cast<uint32_t>(id);
}
napi_value JsStart(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 3; napi_value args[3]{};
        Need(napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) == napi_ok && argc == 3, "Expected sources, outputPath and musicPath");
        bool isArray = false; uint32_t count = 0;
        Need(napi_is_array(env, args[0], &isArray) == napi_ok && isArray &&
            napi_get_array_length(env, args[0], &count) == napi_ok && count >= 1 && count <= 8,
            "Movie export requires between one and eight source clips");
        std::vector<std::string> sources;
        for (uint32_t i = 0; i < count; ++i) { napi_value value = nullptr;
            Need(napi_get_element(env, args[0], i, &value) == napi_ok, "Invalid movie source list"); sources.push_back(JsString(env, value)); }
        std::string output = JsString(env, args[1]), music = JsString(env, args[2]);
        Need(output != music && std::find(sources.begin(), sources.end(), output) == sources.end(), "Movie output must be a new file");
        const auto id = Service().Start(std::move(sources), std::move(output), std::move(music));
        napi_value result = nullptr; napi_create_uint32(env, id, &result); return result;
    } catch (const std::exception &e) { napi_throw_error(env, nullptr, e.what()); return nullptr; }
}
void Property(napi_env env, napi_value result, const char *name, const std::string &text) {
    napi_value value = nullptr; napi_create_string_utf8(env, text.c_str(), text.size(), &value); napi_set_named_property(env, result, name, value);
}
void Property(napi_env env, napi_value result, const char *name, double number) {
    napi_value value = nullptr; napi_create_double(env, number, &value); napi_set_named_property(env, result, name, value);
}
napi_value JsSnapshot(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 1; napi_value arg = nullptr;
        Need(napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) == napi_ok && argc == 1, "Expected movie export identifier");
        auto snapshot = Service().Read(JsId(env, arg));
        napi_value result = nullptr; napi_create_object(env, &result);
        Property(env, result, "id", snapshot.id); Property(env, result, "stage", snapshot.stage);
        Property(env, result, "progress", snapshot.progress); Property(env, result, "durationMs", snapshot.durationMs);
        Property(env, result, "error", snapshot.error); Property(env, result, "outputPath", snapshot.outputPath); return result;
    } catch (const std::exception &e) { napi_throw_error(env, nullptr, e.what()); return nullptr; }
}
napi_value JsCancel(napi_env env, napi_callback_info info) {
    try {
        size_t argc = 1; napi_value arg = nullptr;
        Need(napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) == napi_ok && argc == 1, "Expected movie export identifier");
        Service().Cancel(JsId(env, arg));
        napi_value result = nullptr; napi_get_undefined(env, &result); return result;
    } catch (const std::exception &e) { napi_throw_error(env, nullptr, e.what()); return nullptr; }
}
}
} // namespace neo::movie

napi_value RegisterMovieExports(napi_env env, napi_value exports) {
    const napi_property_descriptor properties[] = {
        {"startMovieExport", nullptr, neo::movie::JsStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"movieExportSnapshot", nullptr, neo::movie::JsSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelMovieExport", nullptr, neo::movie::JsCancel, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}
