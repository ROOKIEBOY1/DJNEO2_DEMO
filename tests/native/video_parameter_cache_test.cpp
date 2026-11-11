#include "../../entry/src/main/cpp/VideoParameterCache.h"

// Fixed storage keeps this policy test runnable without a host C++ runtime.
// Production instantiates the same cache with the HEVC byte vector.
struct Bytes {
    unsigned char data[4]{};
    unsigned size = 0;
    bool empty() const { return size == 0; }
    bool operator!=(const Bytes &other) const {
        if (size != other.size) return true;
        for (unsigned i = 0; i < size; ++i) if (data[i] != other.data[i]) return true;
        return false;
    }
};

int main()
{
    neo::VideoParameterCache<Bytes> cache;
    const Bytes vps{{0x40, 1, 3}, 3}, sps{{0x42, 1, 4}, 3}, pps{{0x44, 1, 5}, 3};
    if (cache.Update(0, vps) || cache.Update(1, sps) || cache.Update(2, pps)) return 1;
    if (cache.Mask() != 7 || !cache.CanStart(true, 1280, 720)) return 2;

    // Recreating only the codec must not require the camera to repeat config.
    cache.Reset(neo::VideoResetScope::Decoder);
    if (cache.Mask() != 7 || cache[0] != vps || cache[1] != sps || cache[2] != pps) return 3;
    if (cache.CanStart(false, 1280, 720)) return 4; // A P picture cannot restore references.
    if (!cache.CanStart(true, 1280, 720)) return 5; // A new IRAP can use same-stream config.
    if (cache.CanStart(true, 0, 720) || cache.CanStart(true, 1280, 0) ||
        cache.CanStart(true, 8193, 720) || cache.CanStart(true, 1280, 8193)) return 6;

    // A changed parameter is reported, and the next rebuild uses the new bytes.
    const Bytes newSps{{0x42, 1, 6}, 3};
    if (!cache.Update(1, newSps) || cache[1] != newSps || cache.Update(1, newSps)) return 7;

    // Queue/transport discontinuity and a new stream must not reuse old config.
    cache.Reset(neo::VideoResetScope::Stream);
    if (cache.Mask() != 0 || cache.CanStart(true, 1280, 720)) return 8;
    cache.Update(0, vps); cache.Update(2, pps);
    if (cache.Mask() != 5 || cache.CanStart(true, 1280, 720)) return 9;
    cache.Update(1, newSps);
    if (!cache.CanStart(true, 1920, 1080)) return 10;
    neo::VideoParameterCache<Bytes> newStream;
    if (newStream.Mask() != 0 || newStream.CanStart(true, 1280, 720)) return 11;
    return 0;
}
