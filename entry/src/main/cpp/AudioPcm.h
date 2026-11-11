#pragma once
#include <stddef.h>
#include <stdint.h>

namespace neo::movie::pcm {
enum class SampleKind { U8, S16, S24, S32, F32 };
struct View {
    const uint8_t *bytes = nullptr;
    size_t byteCount = 0;
    size_t frames = 0;
    int channels = 0;
    SampleKind kind = SampleKind::S16;
    size_t frameStride = 0;
    size_t channelStride = 0;
};
inline int16_t Saturate(double value)
{
    if (value != value) return 0; // NaN cannot be converted to an integer.
    if (value >= 32767.0) return 32767;
    if (value <= -32768.0) return -32768;
    return static_cast<int16_t>(value >= 0.0 ? value + 0.5 : value - 0.5);
}

inline bool ReadStereo(const View &view, size_t frame, int16_t *stereo)
{
    if (!view.bytes || !stereo || frame >= view.frames ||
        (view.channels != 1 && view.channels != 2)) return false;
    size_t width = 0;
    switch (view.kind) {
        case SampleKind::U8: width = 1; break;
        case SampleKind::S16: width = 2; break;
        case SampleKind::S24: width = 3; break;
        case SampleKind::S32: case SampleKind::F32: width = 4; break;
    }
    if (!width || view.frameStride < width ||
        (view.channels == 2 && view.channelStride < width) ||
        frame > SIZE_MAX / view.frameStride) return false;
    const size_t base = frame * view.frameStride;
    for (int channel = 0; channel < view.channels; ++channel) {
        const size_t offset = channel ? view.channelStride : 0;
        if (base > view.byteCount || offset > view.byteCount - base ||
            width > view.byteCount - base - offset) return false;
        const auto *p = view.bytes + base + offset;
        uint32_t bits = 0;
        for (size_t byte = 0; byte < width; ++byte) bits |= static_cast<uint32_t>(p[byte]) << (8 * byte);
        double value;
        if (view.kind == SampleKind::U8) {
            value = (static_cast<int>(bits) - 128) * 256;
        } else if (view.kind == SampleKind::F32) {
            float sample;
            __builtin_memcpy(&sample, &bits, sizeof(sample));
            value = static_cast<double>(sample) * 32768.0;
        } else {
            const unsigned bitCount = static_cast<unsigned>(width * 8);
            const int64_t signedValue = (bits & (uint32_t{1} << (bitCount - 1)))
                ? static_cast<int64_t>(bits) - (int64_t{1} << bitCount) : bits;
            value = static_cast<double>(signedValue) / static_cast<double>(uint32_t{1} << (bitCount - 16));
        }
        stereo[channel] = Saturate(value);
    }
    if (view.channels == 1) stereo[1] = stereo[0];
    return true;
}

// The decoded source stays at its actual rate; interpolation and looping are
// evaluated per requested output frame, without allocating a whole movie PCM.
inline bool ResampleLoop(const int16_t *source, size_t sourceFrames, int sourceRate,
    uint64_t outputFrame, int16_t *stereo)
{
    if (!source || !stereo || sourceFrames == 0 || sourceFrames > 120000000 ||
        sourceRate < 8000 || sourceRate > 192000) return false;
    const uint64_t wholeSeconds = (outputFrame / 48000) % sourceFrames;
    const uint64_t numerator = (outputFrame % 48000) * static_cast<uint64_t>(sourceRate);
    const size_t first = (wholeSeconds * sourceRate + numerator / 48000) % sourceFrames;
    const size_t second = (first + 1) % sourceFrames;
    const double fraction = static_cast<double>(numerator % 48000) / 48000.0;
    for (int channel = 0; channel < 2; ++channel) {
        const double a = source[first * 2 + channel];
        const double b = source[second * 2 + channel];
        stereo[channel] = Saturate(a + (b - a) * fraction);
    }
    return true;
}

inline double Envelope(uint64_t frame, uint64_t totalFrames)
{
    if (totalFrames < 2 || frame >= totalFrames) return 0.0;
    const uint64_t half = (totalFrames - 1) / 2;
    const uint64_t fade = half < 48000 ? half : 48000;
    if (fade == 0) return 0.0;
    const uint64_t fromEnd = totalFrames - 1 - frame;
    const uint64_t edge = frame < fromEnd ? frame : fromEnd;
    return edge >= fade ? 1.0 : static_cast<double>(edge) / static_cast<double>(fade);
}

inline bool Render(const int16_t *source, size_t sourceFrames, int sourceRate,
    uint64_t start, uint64_t totalFrames, size_t frames, int16_t *output,
    bool (*cancelled)(void *), void *context, uint64_t sourceStartFrames = 0)
{
    if (!source || !sourceFrames || sourceFrames > 120000000 || sourceFrames > SIZE_MAX / 2 ||
        sourceStartFrames >= sourceFrames || !output || sourceRate < 8000 || sourceRate > 192000 ||
        start > totalFrames || frames > totalFrames - start || frames > SIZE_MAX / 2) return false;
    // The offset is in decoded source frames, before resampling. Restrict both
    // interpolation neighbors and every loop to the selected source tail.
    const size_t sourceStart = static_cast<size_t>(sourceStartFrames);
    const auto *excerpt = source + sourceStart * 2;
    const size_t excerptFrames = sourceFrames - sourceStart;
    for (size_t frame = 0; frame < frames; ++frame) {
        if ((frame % 64 == 0) && cancelled && cancelled(context)) return false;
        int16_t stereo[2];
        if (!ResampleLoop(excerpt, excerptFrames, sourceRate, start + frame, stereo)) return false;
        const double gain = Envelope(start + frame, totalFrames);
        output[frame * 2] = Saturate(stereo[0] * gain);
        output[frame * 2 + 1] = Saturate(stereo[1] * gain);
    }
    return true;
}
} // namespace neo::movie::pcm
