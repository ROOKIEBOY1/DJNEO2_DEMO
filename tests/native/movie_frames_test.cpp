#include "MovieFrames.h"
#include <cassert>
#include <cmath>
#include <iostream>
#include <stdexcept>
using namespace neo::movie;
int main() {
    auto landscape = MovieCanvas(3840, 2160, 0);
    assert(landscape.width == 1920 && landscape.height == 1080);
    auto portrait = MovieCanvas(3840, 2160, 90);
    assert(portrait.width == 1080 && portrait.height == 1920);
    assert(MovieFrameCount(1000001) == 31);
    assert(MovieFrameTime(30) == 1000000);
    assert(VideoGain(0, 10000000) == 0);
    assert(VideoGain(50000, 100000) == 1); // short movie must still reach full brightness
    assert(VideoGain(100000, 100000) == 0);
    assert(std::abs(VideoGain(300000, 10000000) - .5) < .001);
    // Padded decoder planes, offset and NV21 are all real device layouts.
    std::vector<uint8_t> bytes(40, 0);
    bytes[2] = 20; bytes[3] = 40; bytes[6] = 60; bytes[7] = 80;
    bytes[18] = 160; bytes[19] = 100;
    FrameView source{bytes.data(), bytes.size(), 2, 2, 4, 4, 2, true, false};
    auto rotated = RenderMovieFrame(source, {2, 2}, 90, 1, false);
    assert(rotated == std::vector<uint8_t>({60, 20, 80, 40, 100, 160}));
    auto black = RenderMovieFrame(source, {4, 2}, 0, 0, false);
    assert(black == std::vector<uint8_t>({16,16,16,16,16,16,16,16,128,128,128,128}));
    auto boxed = RenderMovieFrame(source, {6, 2}, 0, 1, false);
    assert(boxed[0] == 16 && boxed[2] == 20 && boxed[3] == 40 && boxed[4] == 16);
    auto bad = source; bad.capacity = 18;
    bool rejected = false;
    try { RenderMovieFrame(bad, {2, 2}, 0, 1, false); } catch (const std::invalid_argument &) { rejected = true; }
    assert(rejected);
    auto full = source; full.fullRange = true; bytes[2] = 255; bytes[3] = 0;
    auto limited = RenderMovieFrame(full, {2, 2}, 0, 1, false);
    assert(limited[0] == 235 && limited[1] == 16);
    // Visible credit must alter pixels at supported output sizes, without increasing frame count.
    std::vector<uint8_t> solid(320 * 180 * 3 / 2, 128);
    FrameView large{solid.data(),solid.size(),320,180,320,180,0,false,false};
    assert(RenderMovieFrame(large,{320,180},0,1,true) != RenderMovieFrame(large,{320,180},0,1,false));
    std::cout << "movie frame, rotation, stride, range, fade, timeline and credit tests passed\n";
}
