#pragma once

#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace neo::movie {
struct AudioSample {
    std::vector<uint8_t> bytes;
    OH_AVCodecBufferAttr attr{};
};

struct MusicTrack {
    std::shared_ptr<OH_AVFormat> format;
    std::vector<AudioSample> samples;
};

// Throws on cancellation or codec/file failures. Progress is in [0, 1].
MusicTrack BuildMusicTrack(const std::string &musicPath, int64_t durationUs,
    const std::atomic_bool &cancelled, const std::function<void(double)> &progress);
} // namespace neo::movie
