#pragma once
#ifdef MOVIE_FRAMES_FREESTANDING
using uint8_t = unsigned char;
using int64_t = long long;
using size_t = __SIZE_TYPE__;
#else
#include <cstddef>
#include <cstdint>
#include <vector>
#endif

namespace neo::movie {
struct Size { int width = 0; int height = 0; };
struct FrameView {
    const uint8_t *data = nullptr;
    size_t capacity = 0;
    int width = 0, height = 0, stride = 0, sliceHeight = 0, offset = 0;
    bool nv21 = false, fullRange = false;
};
Size MovieCanvas(int width, int height, int rotation);
double VideoGain(int64_t ptsUs, int64_t durationUs);
int64_t MovieFrameTime(int64_t frame);
int64_t MovieFrameCount(int64_t durationUs);
int64_t MovieClipFrameTime(int64_t frame, int64_t frameCount, int64_t sourceDurationUs);
bool MovieSourcePtsFits(int64_t ptsUs, int64_t declaredDurationUs);
bool MovieTimelineCovers(int64_t lastPtsUs, int64_t packetDurationUs, int64_t expectedDurationUs);
bool MovieTrackDurationFits(int64_t actualDurationUs, int64_t expectedDurationUs, int64_t packetDurationUs);
int64_t MoviePacketCount(int64_t durationUs, bool audio);
bool RenderMovieFrameInto(const FrameView &source, Size canvas, int rotation,
                         double gain, bool credit, uint8_t *output, size_t capacity);
#ifndef MOVIE_FRAMES_FREESTANDING
// Produces tightly packed limited-range NV12. Invalid layout throws before reading any bytes.
std::vector<uint8_t> RenderMovieFrame(const FrameView &source, Size canvas, int rotation,
                                    double gain, bool credit);
#endif
}
