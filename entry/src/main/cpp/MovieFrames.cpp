#include "MovieFrames.h"
#ifndef MOVIE_FRAMES_FREESTANDING
#include <stdexcept>
#endif
namespace neo::movie {
namespace {
int Min(int a, int b) { return a < b ? a : b; }
uint8_t Byte(double value) { return static_cast<uint8_t>(value < 0 ? 0 : value > 255 ? 255 : value + .5); }
bool Rotation(int r) { return r == 0 || r == 90 || r == 180 || r == 270; }
void SourcePoint(int x, int y, int w, int h, int rotation, int &sx, int &sy) {
    if (rotation == 90) { sx = y; sy = h - 1 - x; }
    else if (rotation == 180) { sx = w - 1 - x; sy = h - 1 - y; }
    else if (rotation == 270) { sx = w - 1 - y; sy = x; }
    else { sx = x; sy = y; }
}
// Readable 5x7 bitmap alphabet, rendered only during the existing final three seconds.
const unsigned char *Glyph(char c) {
    static const unsigned char letters[][7] = {
      {14,17,17,31,17,17,17},{30,17,17,30,17,17,30},{14,17,16,16,16,17,14},
      {30,17,17,17,17,17,30},{31,16,16,30,16,16,31},{31,16,16,30,16,16,16},
      {14,17,16,23,17,17,15},{17,17,17,31,17,17,17},{31,4,4,4,4,4,31},
      {7,2,2,2,2,18,12},{17,18,20,24,20,18,17},{16,16,16,16,16,16,31},
      {17,27,21,21,17,17,17},{17,25,21,19,17,17,17},{14,17,17,17,17,17,14},
      {30,17,17,30,16,16,16},{14,17,17,17,21,18,13},{30,17,17,30,20,18,17},
      {15,16,16,14,1,1,30},{31,4,4,4,4,4,4},{17,17,17,17,17,17,14},
      {17,17,17,17,17,10,4},{17,17,17,21,21,21,10},{17,17,10,4,10,17,17},
      {17,17,10,4,4,4,4},{31,1,2,4,8,16,31},
      {14,17,19,21,25,17,14},{4,12,4,4,4,4,14},{14,17,1,2,4,8,31},
      {30,1,1,14,1,1,30},{2,6,10,18,31,2,2},{31,16,16,30,1,1,30},
      {14,16,16,30,17,17,14},{31,1,2,4,8,8,8},{14,17,17,14,17,17,14},
      {14,17,17,15,1,1,14},{0,0,0,0,0,6,6},{1,2,2,4,8,8,16},{0,0,0,0,0,0,0}
    };
    if (c >= 'a' && c <= 'z') c -= 'a' - 'A';
    int i = c >= 'A' && c <= 'Z' ? c - 'A' : c >= '0' && c <= '9' ? c - '0' + 26 : c == '.' ? 36 : c == '/' ? 37 : 38;
    return letters[i];
}
void Credits(uint8_t *out, Size size) {
    const char *lines[] = {"TITAN / SCOTT BUCKLEY", "CC BY 4.0 / SCOTTBUCKLEY.COM.AU"};
    int scale = size.width >= 960 ? 3 : size.width >= 480 ? 2 : 1;
    if (size.width < 180 || size.height < 40) return;
    const int top = size.height - 20 * scale;
    for (int y = top; y < size.height; ++y)
        for (int x = 0; x < size.width; ++x) out[y * size.width + x] = 16;
    for (int row = 0; row < 2; ++row) {
        const char *line = lines[row];
        for (int ch = 0; line[ch]; ++ch) {
            const auto *glyph = Glyph(line[ch]);
            for (int y = 0; y < 7 * scale; ++y) for (int x = 0; x < 5 * scale; ++x) {
                const int ox = 6 * scale + ch * 6 * scale + x, oy = top + (row * 9 + 2) * scale + y;
                if (ox < size.width && oy < size.height && (glyph[y / scale] & (16 >> (x / scale))))
                    out[oy * size.width + ox] = 235;
            }
        }
    }
    for (int y = top / 2; y < size.height / 2; ++y)
        for (int x = 0; x < size.width; ++x) out[size.width * size.height + y * size.width + x] = 128;
}
}
Size MovieCanvas(int width, int height, int rotation) {
    if (width < 2 || height < 2 || !Rotation(rotation)) return {};
    if (rotation == 90 || rotation == 270) { int temp = width; width = height; height = temp; }
    double ratio = 1;
    const int boundW = width >= height ? 1920 : 1080, boundH = width >= height ? 1080 : 1920;
    if (width > boundW) ratio = static_cast<double>(boundW) / width;
    if (height * ratio > boundH) ratio = static_cast<double>(boundH) / height;
    return {static_cast<int>(width * ratio) & ~1, static_cast<int>(height * ratio) & ~1};
}
double VideoGain(int64_t ptsUs, int64_t durationUs) {
    if (durationUs <= 0 || ptsUs <= 0 || ptsUs >= durationUs) return 0;
    const int64_t fade = durationUs < 1200000 ? durationUs / 2 : 600000;
    if (!fade) return 0;
    double head = static_cast<double>(ptsUs) / fade, tail = static_cast<double>(durationUs - ptsUs) / fade;
    return head < tail ? (head < 1 ? head : 1) : (tail < 1 ? tail : 1);
}
int64_t MovieFrameTime(int64_t frame) { return frame / 30 * 1000000 + frame % 30 * 1000000 / 30; }
int64_t MovieFrameCount(int64_t durationUs) { return durationUs <= 0 ? 0 : (durationUs * 30 + 999999) / 1000000; }
int64_t MovieClipFrameTime(int64_t frame, int64_t frameCount, int64_t sourceDurationUs) {
    return frameCount > 0 && frame >= 0 && sourceDurationUs > 0 ? frame * sourceDurationUs / frameCount : 0;
}
bool MovieSourcePtsFits(int64_t ptsUs, int64_t declaredDurationUs) {
    return ptsUs >= 0 && declaredDurationUs > 0 &&
        (ptsUs < declaredDurationUs || ptsUs - declaredDurationUs < 33333);
}
bool MovieTimelineCovers(int64_t lastPtsUs, int64_t packetDurationUs, int64_t expectedDurationUs) {
    if (lastPtsUs < 0 || packetDurationUs <= 0 || packetDurationUs > 1000000 || expectedDurationUs <= 0 ||
        lastPtsUs >= expectedDurationUs) return false;
    const int64_t remaining = expectedDurationUs - lastPtsUs;
    // Permit only microsecond/millisecond container rounding, never an entire missing codec packet.
    return remaining <= packetDurationUs + 1000;
}
bool MovieTrackDurationFits(int64_t actualDurationUs, int64_t expectedDurationUs, int64_t packetDurationUs) {
    if (actualDurationUs <= 0 || expectedDurationUs <= 0 || packetDurationUs <= 0 || packetDurationUs > 1000000) return false;
    const int64_t difference = actualDurationUs > expectedDurationUs ? actualDurationUs - expectedDurationUs : expectedDurationUs - actualDurationUs;
    return difference <= packetDurationUs + 1000;
}
int64_t MoviePacketCount(int64_t durationUs, bool audio) {
    if (durationUs <= 0) return 0;
    // AAC-LC 1024/48000 seconds is exactly 64000/3 microseconds; don't accumulate rounded packet lengths.
    return audio ? durationUs / 64000 * 3 + (durationUs % 64000 * 3 + 63999) / 64000 : MovieFrameCount(durationUs);
}
bool RenderMovieFrameInto(const FrameView &s, Size c, int r, double gain, bool credit, uint8_t *out, size_t capacity) {
    if (!s.data || !out || !Rotation(r) || c.width < 2 || c.height < 2 || (c.width & 1) || (c.height & 1) ||
        c.width > 1920 || c.height > 1920 || s.width < 2 || s.height < 2 || s.width > 8192 || s.height > 8192 ||
        s.stride < ((s.width + 1) & ~1) || s.sliceHeight < s.height || s.offset < 0 || s.stride > 65536 ||
        s.sliceHeight > 8192 || !(gain >= 0 && gain <= 1)) return false;
    const size_t ysize = static_cast<size_t>(s.stride) * s.sliceHeight;
    const size_t need = static_cast<size_t>(s.offset) + ysize + static_cast<size_t>(s.stride) * ((s.height + 1) / 2);
    const size_t outputSize = static_cast<size_t>(c.width) * c.height * 3 / 2;
    if (need > s.capacity || outputSize > capacity) return false;
    const int displayW = r == 90 || r == 270 ? s.height : s.width;
    const int displayH = r == 90 || r == 270 ? s.width : s.height;
    double ratio = static_cast<double>(c.width) / displayW;
    if (displayH * ratio > c.height) ratio = static_cast<double>(c.height) / displayH;
    if (ratio > 1) ratio = 1; // Smaller later clips retain their native resolution inside the shared canvas.
    int w = static_cast<int>(displayW * ratio) & ~1, h = static_cast<int>(displayH * ratio) & ~1;
    if (w < 2 || h < 2) return false;
    const int left = ((c.width - w) / 2) & ~1, top = ((c.height - h) / 2) & ~1;
    for (size_t i = 0; i < outputSize; ++i) out[i] = i < static_cast<size_t>(c.width) * c.height ? 16 : 128;
    const uint8_t *yplane = s.data + s.offset, *uv = yplane + ysize;
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        int sx, sy;
        SourcePoint(Min(x * displayW / w, displayW - 1), Min(y * displayH / h, displayH - 1), s.width, s.height, r, sx, sy);
        double luma = yplane[sy * s.stride + sx];
        if (s.fullRange) luma = 16 + luma * 219 / 255;
        out[(y + top) * c.width + x + left] = Byte(luma);
        if (!(x & 1) && !(y & 1)) {
            const auto *chroma = uv + (sy / 2) * s.stride + (sx / 2) * 2;
            const size_t p = static_cast<size_t>(c.width) * c.height + (y + top) / 2 * c.width + x + left;
            for (int channel = 0; channel < 2; ++channel) {
                double value = chroma[s.nv21 ? 1 - channel : channel];
                if (s.fullRange) value = 128 + (value - 128) * 224 / 255;
                out[p + channel] = Byte(value);
            }
        }
    }
    if (credit) Credits(out, c);
    if (gain < 1) for (size_t i = 0; i < outputSize; ++i) {
        const double center = i < static_cast<size_t>(c.width) * c.height ? 16 : 128;
        out[i] = Byte(center + (out[i] - center) * gain);
    }
    return true;
}
#ifndef MOVIE_FRAMES_FREESTANDING
std::vector<uint8_t> RenderMovieFrame(const FrameView &source, Size canvas, int rotation, double gain, bool credit) {
    if (canvas.width < 2 || canvas.height < 2 || canvas.width > 1920 || canvas.height > 1920)
        throw std::invalid_argument("Unsupported movie canvas");
    std::vector<uint8_t> output(static_cast<size_t>(canvas.width) * canvas.height * 3 / 2);
    if (!RenderMovieFrameInto(source, canvas, rotation, gain, credit, output.data(), output.size()))
        throw std::invalid_argument("Unsupported or truncated movie frame layout");
    return output;
}
#endif
}
