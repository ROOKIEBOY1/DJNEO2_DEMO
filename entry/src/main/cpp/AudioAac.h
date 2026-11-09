#pragma once
#include <stddef.h>
#include <stdint.h>
namespace neo::movie::aac {
struct Packet { size_t offset = 0; size_t size = 0; uint8_t config[2]{}; };
struct Timeline {
    // The encoder may start before zero because of priming. Rebase that first
    // access unit, but preserve and verify the cadence of the real output.
    bool Push(int64_t pts, int64_t &normalized)
    {
        if (!seen) {
            first = pts;
            last = normalized = 0;
            seen = true;
            return true;
        }
        if (pts < first) return false;
        const uint64_t elapsed = static_cast<uint64_t>(pts) - static_cast<uint64_t>(first);
        if (elapsed > INT64_MAX) return false;
        const int64_t current = static_cast<int64_t>(elapsed);
        if (current <= last) return false;
        const int64_t step = current - last;
        // AAC-LC: exactly 1024 samples at 48 kHz. Integer microsecond PTS may
        // round either way; a missing packet causes a ~42667us gap and fails.
        if (step < 21332 || step > 21335) return false;
        last = normalized = current;
        return true;
    }
private:
    bool seen = false;
    int64_t first = 0;
    int64_t last = 0;
};
inline bool HasCompleteDuration(int64_t lastPts, size_t packetCount, int64_t durationUs)
{
    if (durationUs <= 0 || durationUs > (INT64_MAX - 999999) / 48000 ||
        lastPts < 0 || lastPts >= durationUs || packetCount == 0) return false;
    const uint64_t pcmFrames = (static_cast<uint64_t>(durationUs) * 48000 + 999999) / 1000000;
    const uint64_t requiredPackets = (pcmFrames + 1023) / 1024;
    if (packetCount != requiredPackets) return false;
    // The last codec frame is padded to 1024 samples. Allow at most one AAC
    // frame plus one PCM sample of timestamp rounding/priming tolerance.
    // The exact access-unit count above independently rejects even one lost
    // final packet, including codecs that increment an integer 21333us clock.
    return lastPts >= durationUs - 21334 - 21334 - 22;
}
enum class Disposition { Invalid, Keep, Padding };
class TrackTimeline {
public:
    explicit TrackTimeline(int64_t durationUs) : durationUs_(durationUs)
    {
        if (durationUs <= 0 || durationUs > (INT64_MAX - 999999) / 48000) return;
        const uint64_t frames = (static_cast<uint64_t>(durationUs) * 48000 + 999999) / 1000000;
        const uint64_t packets = (frames + 1023) / 1024;
        if (packets > SIZE_MAX) return;
        requiredPackets_ = static_cast<size_t>(packets);
        valid_ = true;
    }
    Disposition Push(int64_t rawPts, int64_t &normalized)
    {
        if (!valid_) return Disposition::Invalid;
        // The caller still validates each access unit and drains through EOS.
        // Codec flush packets outside our complete retained prefix do not
        // belong to its timeline and can carry a different timestamp cadence.
        if (packets_ == requiredPackets_) return Disposition::Padding;
        int64_t candidate = 0;
        if (!timeline_.Push(rawPts, candidate) || candidate >= durationUs_) {
            valid_ = false;
            return Disposition::Invalid;
        }
        ++packets_;
        lastPts_ = normalized = candidate;
        return Disposition::Keep;
    }
    bool Complete() const
    {
        return valid_ && HasCompleteDuration(lastPts_, packets_, durationUs_);
    }
private:
    Timeline timeline_;
    int64_t durationUs_ = 0;
    int64_t lastPts_ = -1;
    size_t requiredPackets_ = 0;
    size_t packets_ = 0;
    bool valid_ = false;
};
// Native AAC defaults to ADTS. MP4 needs the raw access unit and its
// AudioSpecificConfig; reject malformed, non-LC, or mismatched output.
inline bool ParseAdts48kStereo(const uint8_t *bytes, size_t size, Packet &packet)
{
    if (!bytes || size < 7 || bytes[0] != 0xff || (bytes[1] & 0xf6) != 0xf0) return false;
    const unsigned objectType = (bytes[2] >> 6) + 1;
    const unsigned rateIndex = (bytes[2] >> 2) & 15;
    const unsigned channels = ((bytes[2] & 1) << 2) | (bytes[3] >> 6);
    const size_t frameLength = ((bytes[3] & 3) << 11) | (bytes[4] << 3) | (bytes[5] >> 5);
    const size_t headerLength = (bytes[1] & 1) ? 7 : 9;
    if (objectType != 2 || rateIndex != 3 || channels != 2 ||
        (bytes[6] & 3) != 0 || frameLength != size || size <= headerLength) return false;
    packet.offset = headerLength;
    packet.size = size - headerLength;
    packet.config[0] = static_cast<uint8_t>((objectType << 3) | (rateIndex >> 1));
    packet.config[1] = static_cast<uint8_t>(((rateIndex & 1) << 7) | (channels << 3));
    return true;
}
}
