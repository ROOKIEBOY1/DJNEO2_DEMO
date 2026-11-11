#pragma once

namespace neo::movie {
struct AvcConfiguration { unsigned sps = 0, pps = 0; bool complete = false; };
namespace avc_detail {
using Size = decltype(sizeof(0));
inline unsigned StartCode(const unsigned char *data, Size size, Size at) {
    if (size - at >= 4 && data[at] == 0 && data[at + 1] == 0 && data[at + 2] == 0 && data[at + 3] == 1) return 4;
    if (size - at >= 3 && data[at] == 0 && data[at + 1] == 0 && data[at + 2] == 1) return 3;
    return 0;
}
inline Size NextStart(const unsigned char *data, Size size, Size at) {
    while (at < size && !StartCode(data, size, at)) ++at;
    return at;
}
}
// Check that configuration actually carries both parameter-set types, rather
// than accepting a nonempty avcC with zero SPS/PPS. This checks framing and
// lengths, not the full H.264 syntax; actual picture decoding is still required.
inline AvcConfiguration InspectAvcConfiguration(const unsigned char *data, decltype(sizeof(0)) size) {
    using avc_detail::Size;
    AvcConfiguration result;
    if (!data || size == 0) return result;
    if (data[0] == 1) { // AVCDecoderConfigurationRecord (avcC).
        if (size < 7) return result;
        Size at = 6;
        const auto parameterSet = [&](unsigned type) {
            if (size - at < 2) return false;
            const Size length = static_cast<Size>(data[at]) * 256 + data[at + 1];
            at += 2;
            if (length > size - at || length < (type == 7 ? 4 : 2) ||
                (data[at] & 0x80) || (data[at] & 31) != type) return false;
            at += length;
            return true;
        };
        const unsigned sps = data[5] & 31;
        for (unsigned i = 0; i < sps; ++i) {
            if (!parameterSet(7)) return {};
            ++result.sps;
        }
        if (at == size) return {};
        const unsigned pps = data[at++];
        for (unsigned i = 0; i < pps; ++i) {
            if (!parameterSet(8)) return {};
            ++result.pps;
        }
        // High-profile records may contain extension fields after the PPS list.
    } else { // Annex-B configuration, or a demuxed keyframe including SPS/PPS.
        Size start = avc_detail::NextStart(data, size, 0);
        for (Size i = 0; i < start; ++i) if (data[i] != 0) return {};
        if (start == size) return {};
        while (start < size) {
            const Size nal = start + avc_detail::StartCode(data, size, start);
            const Size next = avc_detail::NextStart(data, size, nal);
            Size end = next;
            while (end > nal && data[end - 1] == 0) --end;
            if (end == nal || (data[nal] & 0x80)) return {};
            const unsigned type = data[nal] & 31;
            if (type == 7) { if (end - nal < 4) return {}; ++result.sps; }
            if (type == 8) { if (end - nal < 2) return {}; ++result.pps; }
            start = next;
        }
    }
    result.complete = result.sps > 0 && result.pps > 0;
    return result;
}
}
