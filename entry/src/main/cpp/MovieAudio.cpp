#include "MovieAudio.h"
#include "AudioPcm.h"
#include "AudioAac.h"
#include <hilog/log.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avdemuxer.h>
#include <multimedia/player_framework/native_avsource.h>
#include <multimedia/native_audio_channel_layout.h>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

namespace neo::movie {
namespace {
using Clock = std::chrono::steady_clock;
using Format = std::unique_ptr<OH_AVFormat, decltype(&OH_AVFormat_Destroy)>;
using Source = std::unique_ptr<OH_AVSource, decltype(&OH_AVSource_Destroy)>;
using Demuxer = std::unique_ptr<OH_AVDemuxer, decltype(&OH_AVDemuxer_Destroy)>;
constexpr size_t MAX_PCM_BYTES = 128 * 1024 * 1024;
constexpr size_t MAX_AAC_BYTES = 64 * 1024 * 1024;
constexpr int64_t MAX_DURATION_US = 2LL * 60 * 60 * 1000000;

[[noreturn]] void Fail(const std::string &message)
{
    throw std::runtime_error("Music: " + message);
}
void Check(OH_AVErrCode code, const char *operation)
{
    if (code != AV_ERR_OK) Fail(std::string(operation) + " (" + std::to_string(code) + ")");
}
void CheckCancel(const std::atomic_bool &cancelled)
{
    if (cancelled.load(std::memory_order_relaxed)) throw std::runtime_error("Movie export cancelled");
}
bool IsCancelled(void *context)
{
    return static_cast<const std::atomic_bool *>(context)->load(std::memory_order_relaxed);
}
struct File {
    explicit File(const std::string &path) : fd(open(path.c_str(), O_RDONLY | O_CLOEXEC))
    {
        if (fd < 0) Fail("cannot open the bundled Titan track");
    }
    ~File() { close(fd); }
    int fd;
};
struct Codec {
    explicit Codec(const char *mime, bool encoder) : value(OH_AudioCodec_CreateByMime(mime, encoder))
    {
        if (!value) Fail(encoder ? "AAC encoder unavailable" : "MP3 decoder unavailable");
    }
    ~Codec()
    {
        if (started) OH_AudioCodec_Stop(value);
        OH_AudioCodec_Destroy(value);
    }
    void Start(OH_AVFormat *format)
    {
        if (!OH_AVFormat_SetIntValue(format, OH_MD_KEY_ENABLE_SYNC_MODE, 1)) Fail("cannot enable synchronous audio codec");
        Check(OH_AudioCodec_Configure(value, format), "configure audio codec");
        Check(OH_AudioCodec_Prepare(value), "prepare audio codec");
        Check(OH_AudioCodec_Start(value), "start audio codec");
        started = true;
    }
    OH_AVCodec *value;
    bool started = false;
};
struct OutputLease {
    OH_AVCodec *codec;
    uint32_t index;
    ~OutputLease() { OH_AudioCodec_FreeOutputBuffer(codec, index); }
};
OH_AVCodecBufferAttr Attr(OH_AVBuffer *buffer)
{
    if (!buffer) Fail("missing codec buffer");
    OH_AVCodecBufferAttr attr{};
    Check(OH_AVBuffer_GetBufferAttr(buffer, &attr), "read audio buffer attributes");
    const int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
    if (attr.offset < 0 || attr.size < 0 || attr.offset > capacity || attr.size > capacity - attr.offset ||
        (attr.size > 0 && !OH_AVBuffer_GetAddr(buffer))) Fail("invalid audio buffer bounds");
    return attr;
}
int IntValue(OH_AVFormat *format, const char *key)
{
    int value = 0;
    if (!format || !OH_AVFormat_GetIntValue(format, key, &value)) Fail(std::string("missing audio metadata: ") + key);
    return value;
}
struct Layout {
    int rate = 0;
    int channels = 0;
    int sampleFormat = -1;
    void Read(OH_AVCodec *codec)
    {
        Format description(OH_AudioCodec_GetOutputDescription(codec), OH_AVFormat_Destroy);
        rate = IntValue(description.get(), OH_MD_KEY_AUD_SAMPLE_RATE);
        channels = IntValue(description.get(), OH_MD_KEY_AUD_CHANNEL_COUNT);
        sampleFormat = IntValue(description.get(), OH_MD_KEY_AUDIO_SAMPLE_FORMAT);
        const char *details = OH_AVFormat_DumpInfo(description.get());
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
            "Titan decoder layout rate=%{public}d channels=%{public}d sampleFormat=%{public}d description=%{public}s",
            rate, channels, sampleFormat, details ? details : "(unavailable)");
        if (rate < 8000 || rate > 192000 || (channels != 1 && channels != 2)) Fail("unsupported decoded rate or channel layout");
    }
};
struct Pcm {
    std::vector<int16_t> stereo;
    int rate = 0;
    void Append(OH_AVBuffer *buffer, const OH_AVCodecBufferAttr &attr, const Layout &layout,
        const std::atomic_bool &cancelled)
    {
        if (!rate) rate = layout.rate;
        if (rate != layout.rate) Fail("MP3 sample rate changed during decoding");
        pcm::SampleKind kind;
        size_t width;
        bool planar = false;
        switch (layout.sampleFormat) {
            case SAMPLE_U8: kind = pcm::SampleKind::U8; width = 1; break;
            case SAMPLE_U8P: kind = pcm::SampleKind::U8; width = 1; planar = true; break;
            case SAMPLE_S16LE: kind = pcm::SampleKind::S16; width = 2; break;
            case SAMPLE_S16P: kind = pcm::SampleKind::S16; width = 2; planar = true; break;
            case SAMPLE_S24LE: kind = pcm::SampleKind::S24; width = 3; break;
            case SAMPLE_S24P: kind = pcm::SampleKind::S24; width = 3; planar = true; break;
            case SAMPLE_S32LE: kind = pcm::SampleKind::S32; width = 4; break;
            case SAMPLE_S32P: kind = pcm::SampleKind::S32; width = 4; planar = true; break;
            case SAMPLE_F32LE: kind = pcm::SampleKind::F32; width = 4; break;
            case SAMPLE_F32P: kind = pcm::SampleKind::F32; width = 4; planar = true; break;
            default: Fail("unsupported decoded PCM sample format " + std::to_string(layout.sampleFormat));
        }
        const size_t frameBytes = width * layout.channels;
        if (static_cast<size_t>(attr.size) % frameBytes) Fail("unaligned decoded PCM buffer");
        const size_t frames = static_cast<size_t>(attr.size) / frameBytes;
        if (frames > MAX_PCM_BYTES / 4 || stereo.size() > MAX_PCM_BYTES / 2 - frames * 2) Fail("Titan decoded audio exceeds memory limit");
        const size_t begin = stereo.size();
        stereo.resize(begin + frames * 2);
        const pcm::View view{OH_AVBuffer_GetAddr(buffer) + attr.offset, static_cast<size_t>(attr.size),
            frames, layout.channels, kind, planar ? width : frameBytes, planar ? frames * width : width};
        for (size_t frame = 0; frame < frames; ++frame) {
            if (frame % 1024 == 0) CheckCancel(cancelled);
            if (!pcm::ReadStereo(view, frame, stereo.data() + begin + frame * 2)) Fail("invalid decoded PCM layout");
        }
    }
};

Pcm Decode(const std::string &path, const std::atomic_bool &cancelled,
    const std::function<void(double)> &progress)
{
    File file(path);
    struct stat info{};
    if (fstat(file.fd, &info) != 0 || info.st_size <= 0 || info.st_size > 32 * 1024 * 1024) Fail("invalid Titan resource size");
    Source source(OH_AVSource_CreateWithFD(file.fd, 0, info.st_size), OH_AVSource_Destroy);
    if (!source) Fail("cannot parse the Titan MP3");
    Format sourceFormat(OH_AVSource_GetSourceFormat(source.get()), OH_AVFormat_Destroy);
    const int trackCount = IntValue(sourceFormat.get(), OH_MD_KEY_TRACK_COUNT);
    if (trackCount <= 0 || trackCount > 16) Fail("invalid music track count");
    int64_t duration = 0;
    if (!OH_AVFormat_GetLongValue(sourceFormat.get(), OH_MD_KEY_DURATION, &duration) || duration <= 0) Fail("missing Titan duration");
    const char *sourceDetails = OH_AVFormat_DumpInfo(sourceFormat.get());
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
        "Titan source bytes=%{public}lld tracks=%{public}d durationUs=%{public}lld description=%{public}s",
        static_cast<long long>(info.st_size), trackCount, static_cast<long long>(duration),
        sourceDetails ? sourceDetails : "(unavailable)");
    Format track(nullptr, OH_AVFormat_Destroy);
    uint32_t trackIndex = 0;
    for (int index = 0; index < trackCount; ++index) {
        Format candidate(OH_AVSource_GetTrackFormat(source.get(), index), OH_AVFormat_Destroy);
        const char *mime = nullptr;
        if (candidate && OH_AVFormat_GetStringValue(candidate.get(), OH_MD_KEY_CODEC_MIME, &mime) &&
            mime && std::strcmp(mime, "audio/mpeg") == 0) {
            track = std::move(candidate);
            trackIndex = index;
            break;
        }
    }
    if (!track) Fail("Titan resource contains no MP3 audio track");
    const char *trackDetails = OH_AVFormat_DumpInfo(track.get());
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie", "Titan selected track=%{public}u description=%{public}s",
        trackIndex, trackDetails ? trackDetails : "(unavailable)");
    Demuxer demuxer(OH_AVDemuxer_CreateWithSource(source.get()), OH_AVDemuxer_Destroy);
    if (!demuxer) Fail("cannot create Titan demuxer");
    Check(OH_AVDemuxer_SelectTrackByID(demuxer.get(), trackIndex), "select Titan track");
    Codec decoder("audio/mpeg", false);
    if (!OH_AVFormat_SetIntValue(track.get(), OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE)) Fail("cannot request MP3 PCM output");
    decoder.Start(track.get());
    Layout layout;
    Pcm pcm;
    bool inputEnded = false, outputEnded = false;
    uint64_t inputSamples = 0, outputSamples = 0, inputBytes = 0, outputBytes = 0;
    int64_t lastInputPts = -1, lastOutputPts = -1;
    auto lastActivity = Clock::now();
    while (!outputEnded) {
        CheckCancel(cancelled);
        bool activity = false;
        for (int output = 0; output < 16 && !outputEnded; ++output) {
            uint32_t index = 0;
            const auto code = OH_AudioCodec_QueryOutputBuffer(decoder.value, &index, 0);
            if (code == AV_ERR_TRY_AGAIN_LATER) break;
            if (code == AV_ERR_STREAM_CHANGED) { layout.Read(decoder.value); activity = true; continue; }
            Check(code, "query decoded Titan output");
            OutputLease lease{decoder.value, index};
            auto *buffer = OH_AudioCodec_GetOutputBuffer(decoder.value, index);
            const auto attr = Attr(buffer);
            if (outputSamples < 8 || (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) || outputSamples % 1024 == 0) {
                OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
                    "Titan decoder output packet=%{public}llu index=%{public}u pts=%{public}lld size=%{public}d offset=%{public}d capacity=%{public}d flags=%{public}u pcmBefore=%{public}zu inputs=%{public}llu inputEnded=%{public}d",
                    static_cast<unsigned long long>(outputSamples), index, static_cast<long long>(attr.pts),
                    attr.size, attr.offset, OH_AVBuffer_GetCapacity(buffer), attr.flags, pcm.stereo.size() / 2,
                    static_cast<unsigned long long>(inputSamples), inputEnded ? 1 : 0);
            }
            ++outputSamples;
            outputBytes += static_cast<uint64_t>(attr.size);
            lastOutputPts = attr.pts;
            activity = true;
            // This MP3 decoder can forward the demuxer's flags=10 on ordinary
            // PCM output. Its CODEC_DATA bit does not make the validated PCM
            // buffer an out-of-band encoder configuration packet.
            if (attr.size) {
                if (!layout.rate) layout.Read(decoder.value);
                pcm.Append(buffer, attr, layout, cancelled);
                if (progress) progress(0.2 * std::min(1.0, static_cast<double>(pcm.stereo.size() / 2) * 1000000.0 / pcm.rate / duration));
            }
            outputEnded = attr.flags & AVCODEC_BUFFER_FLAGS_EOS;
        }
        if (!inputEnded && !outputEnded) {
            uint32_t index = 0;
            const auto code = OH_AudioCodec_QueryInputBuffer(decoder.value, &index, 10000);
            if (code != AV_ERR_TRY_AGAIN_LATER) {
                Check(code, "query Titan decoder input");
                auto *buffer = OH_AudioCodec_GetInputBuffer(decoder.value, index);
                if (!buffer) Fail("missing Titan decoder input buffer");
                Check(OH_AVDemuxer_ReadSampleBuffer(demuxer.get(), trackIndex, buffer), "read Titan MP3 sample");
                const auto attr = Attr(buffer);
                if (inputSamples < 8 || (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) || inputSamples % 1024 == 0) {
                    char header[17]{};
                    constexpr char HEX[] = "0123456789abcdef";
                    if (attr.size) {
                        const auto *data = OH_AVBuffer_GetAddr(buffer) + attr.offset;
                        for (int32_t i = 0; i < std::min<int32_t>(8, attr.size); ++i) {
                            header[i * 2] = HEX[data[i] >> 4];
                            header[i * 2 + 1] = HEX[data[i] & 15];
                        }
                    }
                    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
                        "Titan decoder input sample=%{public}llu index=%{public}u pts=%{public}lld size=%{public}d offset=%{public}d capacity=%{public}d flags=%{public}u header=%{public}s",
                        static_cast<unsigned long long>(inputSamples), index, static_cast<long long>(attr.pts),
                        attr.size, attr.offset, OH_AVBuffer_GetCapacity(buffer), attr.flags, header);
                }
                ++inputSamples;
                inputBytes += static_cast<uint64_t>(attr.size);
                lastInputPts = attr.pts;
                inputEnded = attr.flags & AVCODEC_BUFFER_FLAGS_EOS;
                Check(OH_AudioCodec_PushInputBuffer(decoder.value, index), "submit Titan MP3 sample");
                activity = true;
            }
        }
        if (activity) lastActivity = Clock::now();
        else if (Clock::now() - lastActivity > std::chrono::seconds(30)) Fail("Titan decoder timed out");
        if (inputEnded && !outputEnded && !activity) usleep(1000);
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
        "Titan decoder drained inputs=%{public}llu inputBytes=%{public}llu inputEnded=%{public}d lastInputPts=%{public}lld outputs=%{public}llu outputBytes=%{public}llu outputEnded=%{public}d lastOutputPts=%{public}lld expectedDuration=%{public}lld",
        static_cast<unsigned long long>(inputSamples), static_cast<unsigned long long>(inputBytes), inputEnded ? 1 : 0,
        static_cast<long long>(lastInputPts), static_cast<unsigned long long>(outputSamples),
        static_cast<unsigned long long>(outputBytes), outputEnded ? 1 : 0, static_cast<long long>(lastOutputPts),
        static_cast<long long>(duration));
    if (pcm.stereo.empty() || !pcm.rate) Fail("Titan decoder produced no PCM audio");
    const int64_t decodedDuration = static_cast<int64_t>((pcm.stereo.size() / 2) * 1000000ULL / pcm.rate);
    // An MPEG-1 Layer III frame contains 1152 samples. Permit only one frame
    // of decoder priming/padding or metadata rounding around the source end;
    // a truncated nonempty prefix must not become looping replacement music.
    const int64_t frameTolerance = (1152LL * 1000000 + pcm.rate - 1) / pcm.rate;
    if (decodedDuration < duration - frameTolerance || decodedDuration - frameTolerance > duration) {
        Fail("Titan decoder did not cover the complete source duration (decoded=" +
            std::to_string(decodedDuration) + ", expected=" + std::to_string(duration) + ")");
    }
    int peak = 0;
    uint64_t absolute = 0;
    for (const int sample : pcm.stereo) {
        const int amplitude = sample < 0 ? -sample : sample;
        peak = std::max(peak, amplitude);
        absolute += amplitude;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
        "Titan decoded rate=%{public}d frames=%{public}zu peak=%{public}d meanAbs=%{public}llu durationUs=%{public}lld expectedUs=%{public}lld toleranceUs=%{public}lld",
        pcm.rate, pcm.stereo.size() / 2, peak, static_cast<unsigned long long>(absolute / pcm.stereo.size()),
        static_cast<long long>(decodedDuration), static_cast<long long>(duration), static_cast<long long>(frameTolerance));
    if (progress) progress(0.2);
    return pcm;
}

MusicTrack Encode(const Pcm &pcm, int64_t durationUs, const std::atomic_bool &cancelled,
    const std::function<void(double)> &progress)
{
    Codec encoder("audio/mp4a-latm", true);
    Format config(OH_AVFormat_CreateAudioFormat("audio/mp4a-latm", 48000, 2), OH_AVFormat_Destroy);
    if (!config || !OH_AVFormat_SetLongValue(config.get(), OH_MD_KEY_BITRATE, 192000) ||
        !OH_AVFormat_SetIntValue(config.get(), OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE) ||
        !OH_AVFormat_SetLongValue(config.get(), OH_MD_KEY_CHANNEL_LAYOUT, CH_LAYOUT_STEREO) ||
        !OH_AVFormat_SetIntValue(config.get(), OH_MD_KEY_PROFILE, AAC_PROFILE_LC)) Fail("cannot configure stereo AAC");
    encoder.Start(config.get());
    MusicTrack result;
    const uint64_t totalFrames = (static_cast<uint64_t>(durationUs) * 48000 + 999999) / 1000000;
    uint64_t submitted = 0;
    bool inputEnded = false, outputEnded = false;
    size_t compressedBytes = 0;
    uint64_t outputPackets = 0;
    int64_t previousRawPts = 0;
    std::vector<uint8_t> codecData;
    aac::TrackTimeline timing(durationUs);
    auto lastActivity = Clock::now();
    auto readFormat = [&]() {
        auto *format = OH_AudioCodec_GetOutputDescription(encoder.value);
        if (!format) Fail("missing AAC output format");
        result.format.reset(format, OH_AVFormat_Destroy);
        int rate = -1, channels = -1;
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, &rate);
        OH_AVFormat_GetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, &channels);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
            "AAC output format rate=%{public}d channels=%{public}d", rate, channels);
    };
    while (!outputEnded) {
        CheckCancel(cancelled);
        bool activity = false;
        for (int output = 0; output < 16 && !outputEnded; ++output) {
            uint32_t index = 0;
            const auto code = OH_AudioCodec_QueryOutputBuffer(encoder.value, &index, 0);
            if (code == AV_ERR_TRY_AGAIN_LATER) break;
            if (code == AV_ERR_STREAM_CHANGED) { readFormat(); activity = true; continue; }
            Check(code, "query encoded music output");
            OutputLease lease{encoder.value, index};
            auto *buffer = OH_AudioCodec_GetOutputBuffer(encoder.value, index);
            auto attr = Attr(buffer);
            const bool eos = attr.flags & AVCODEC_BUFFER_FLAGS_EOS;
            activity = true;
            const int64_t rawPts = attr.pts;
            if (outputPackets < 8 || inputEnded || rawPts >= durationUs - 100000 || eos ||
                (attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA)) {
                char header[33]{};
                constexpr char HEX[] = "0123456789abcdef";
                if (attr.size) {
                    const auto *data = OH_AVBuffer_GetAddr(buffer) + attr.offset;
                    for (int32_t i = 0; i < std::min<int32_t>(16, attr.size); ++i) {
                        header[i * 2] = HEX[data[i] >> 4];
                        header[i * 2 + 1] = HEX[data[i] & 15];
                    }
                }
                OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
                    "AAC output packet=%{public}llu pts=%{public}lld previous=%{public}lld size=%{public}d offset=%{public}d flags=%{public}u submitted=%{public}llu total=%{public}llu header=%{public}s",
                    static_cast<unsigned long long>(outputPackets), static_cast<long long>(rawPts),
                    static_cast<long long>(previousRawPts), attr.size, attr.offset, attr.flags,
                    static_cast<unsigned long long>(submitted), static_cast<unsigned long long>(totalFrames), header);
            }
            if (attr.size) {
                const auto *bytes = OH_AVBuffer_GetAddr(buffer) + attr.offset;
                if (attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) {
                    codecData.assign(bytes, bytes + attr.size);
                } else {
                    aac::Packet packet;
                    size_t payloadSize = static_cast<size_t>(attr.size);
                    // Validate every access unit, including the encoder's trailing
                    // padding, but only retain the complete requested music prefix.
                    if (payloadSize >= 2 && bytes[0] == 0xff && (bytes[1] & 0xf0) == 0xf0) {
                        if (!aac::ParseAdts48kStereo(bytes, payloadSize, packet)) Fail("invalid AAC-LC ADTS output");
                        bytes += packet.offset;
                        payloadSize = packet.size;
                        const std::vector<uint8_t> parsedConfig(packet.config, packet.config + 2);
                        if (!codecData.empty() && codecData != parsedConfig) Fail("AAC configuration changed during encoding");
                        codecData = parsedConfig;
                    }
                    const auto disposition = timing.Push(attr.pts, attr.pts);
                    if (disposition == aac::Disposition::Invalid) {
                        Fail("AAC encoder produced discontinuous timestamps (packet=" + std::to_string(outputPackets) +
                            ", pts=" + std::to_string(rawPts) + ", previous=" + std::to_string(previousRawPts) +
                            ", size=" + std::to_string(attr.size) + ", flags=" + std::to_string(attr.flags) + ")");
                    }
                    previousRawPts = rawPts;
                    ++outputPackets;
                    if (disposition == aac::Disposition::Keep) {
                        if (payloadSize > MAX_AAC_BYTES - compressedBytes) Fail("encoded music exceeds memory limit");
                        compressedBytes += payloadSize;
                        attr.size = static_cast<int32_t>(payloadSize);
                        attr.offset = 0;
                        attr.flags &= ~static_cast<uint32_t>(AVCODEC_BUFFER_FLAGS_EOS);
                        result.samples.push_back({std::vector<uint8_t>(bytes, bytes + attr.size), attr});
                        if (progress) progress(0.2 + 0.8 * std::min(1.0, static_cast<double>(attr.pts) / durationUs));
                    }
                }
            }
            outputEnded = eos;
        }
        if (!inputEnded && !outputEnded) {
            uint32_t index = 0;
            const auto code = OH_AudioCodec_QueryInputBuffer(encoder.value, &index, 10000);
            if (code != AV_ERR_TRY_AGAIN_LATER) {
                Check(code, "query AAC input buffer");
                auto *buffer = OH_AudioCodec_GetInputBuffer(encoder.value, index);
                if (!buffer) Fail("missing AAC input buffer");
                OH_AVCodecBufferAttr attr{};
                attr.pts = static_cast<int64_t>(submitted * 1000000 / 48000);
                if (submitted == totalFrames) {
                    attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
                    inputEnded = true;
                } else {
                    const int32_t capacity = OH_AVBuffer_GetCapacity(buffer);
                    if (capacity < 4096 || !OH_AVBuffer_GetAddr(buffer)) Fail("AAC input buffer cannot hold 1024 stereo frames");
                    const size_t frames = static_cast<size_t>(std::min<uint64_t>(1024, totalFrames - submitted));
                    int16_t samples[2048]{};
                    if (!pcm::Render(pcm.stereo.data(), pcm.stereo.size() / 2, pcm.rate, submitted,
                        totalFrames, frames, samples, IsCancelled, const_cast<std::atomic_bool *>(&cancelled))) {
                        CheckCancel(cancelled);
                        Fail("cannot resample or loop Titan PCM");
                    }
                    // AAC-LC consumes 1024 samples; retain the exact media end
                    // in totalFrames and pad only this final codec frame.
                    attr.size = sizeof(samples);
                    std::memcpy(OH_AVBuffer_GetAddr(buffer), samples, attr.size);
                    submitted += frames;
                }
                Check(OH_AVBuffer_SetBufferAttr(buffer, &attr), "set AAC input attributes");
                if (submitted <= 4096 || inputEnded) {
                    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
                        "AAC input pts=%{public}lld size=%{public}d flags=%{public}u submitted=%{public}llu",
                        static_cast<long long>(attr.pts), attr.size, attr.flags, static_cast<unsigned long long>(submitted));
                }
                Check(OH_AudioCodec_PushInputBuffer(encoder.value, index), "submit music PCM");
                activity = true;
            }
        }
        if (activity) lastActivity = Clock::now();
        else if (Clock::now() - lastActivity > std::chrono::seconds(30)) Fail("AAC encoder timed out");
        if (inputEnded && !outputEnded && !activity) usleep(1000);
    }
    readFormat();
    if (!timing.Complete() || result.samples.empty() || submitted != totalFrames ||
        !aac::HasCompleteDuration(result.samples.back().attr.pts, result.samples.size(), durationUs)) {
        Fail("AAC encoder did not produce the complete music track");
    }
    uint8_t *existingData = nullptr;
    size_t existingSize = 0;
    if (!codecData.empty()) {
        if (!OH_AVFormat_SetBuffer(result.format.get(), OH_MD_KEY_CODEC_CONFIG, codecData.data(), codecData.size())) Fail("cannot store AAC codec configuration");
    } else if (!OH_AVFormat_GetBuffer(result.format.get(), OH_MD_KEY_CODEC_CONFIG, &existingData, &existingSize) || !existingSize) {
        Fail("AAC encoder supplied no codec configuration");
    }
    if (!OH_AVFormat_SetLongValue(result.format.get(), OH_MD_KEY_DURATION, durationUs)) Fail("cannot store music duration");
    OH_LOG_Print(LOG_APP, LOG_INFO, 0, "NeoMovie",
        "AAC complete outputs=%{public}llu retained=%{public}zu lastPts=%{public}lld duration=%{public}lld EOS=true",
        static_cast<unsigned long long>(outputPackets), result.samples.size(),
        static_cast<long long>(result.samples.back().attr.pts), static_cast<long long>(durationUs));
    CheckCancel(cancelled);
    if (progress) progress(1.0);
    return result;
}
} // namespace

MusicTrack BuildMusicTrack(const std::string &musicPath, int64_t durationUs,
    const std::atomic_bool &cancelled, const std::function<void(double)> &progress)
{
    CheckCancel(cancelled);
    if (durationUs <= 0 || durationUs > MAX_DURATION_US) Fail("invalid movie music duration (maximum two hours)");
    if (musicPath.empty()) Fail("missing bundled Titan resource path");
    if (progress) progress(0.0);
    const auto pcm = Decode(musicPath, cancelled, progress);
    return Encode(pcm, durationUs, cancelled, progress);
}
} // namespace neo::movie
