#include "../../entry/src/main/cpp/AudioPcm.h"
#include "../../entry/src/main/cpp/AudioAac.h"
using namespace neo::movie::pcm;
#if defined(_WIN32)
extern "C" { int _fltused = 0; }
#endif

static bool Cancelled(void *value) { return *static_cast<bool *>(value); }
static bool CancelDuringBlock(void *value) { return ++*static_cast<int *>(value) == 2; }

// Hand-checked fixtures catch offset/stride errors, lost channels, wrong rate,
// repeated one-second fades, missing final fade, and ignored cancellation.
extern "C" int RunMovieAudioTests()
{
    int16_t stereo[2]{};
    const uint8_t padded[] = {0xe8, 0x03, 0x18, 0xfc, 0xff, 0xff, 0xd0, 0x07, 0x30, 0xf8};
    View packed{padded, sizeof(padded), 2, 2, SampleKind::S16, 6, 2};
    if (!ReadStereo(packed, 1, stereo) || stereo[0] != 2000 || stereo[1] != -2000) return 1;
    packed.byteCount = 9;
    if (ReadStereo(packed, 1, stereo)) return 2;
    const float planes[] = {0.5f, -0.5f, 1.0f, -1.0f};
    View planar{reinterpret_cast<const uint8_t *>(planes), sizeof(planes), 2, 2, SampleKind::F32, 4, 8};
    if (!ReadStereo(planar, 1, stereo) || stereo[0] != -16384 || stereo[1] != -32768) return 3;
    const uint8_t mono[] = {0, 128, 255};
    View monoView{mono, sizeof(mono), 3, 1, SampleKind::U8, 1, 1};
    if (!ReadStereo(monoView, 2, stereo) || stereo[0] != 32512 || stereo[1] != 32512) return 4;
    const int16_t source[] = {0, 1000, 10000, 11000, 20000, 21000, 30000, 31000};
    if (!ResampleLoop(source, 4, 24000, 3, stereo) || stereo[0] != 15000 || stereo[1] != 16000) return 5;
    if (!ResampleLoop(source, 4, 24000, 8, stereo) || stereo[0] != 0 || stereo[1] != 1000) return 6;
    if (Envelope(0, 240000) != 0.0 || Envelope(239999, 240000) != 0.0 ||
        Envelope(24000, 240000) != 0.5 || Envelope(100000, 240000) != 1.0) return 7;
    if (Envelope(0, 5) != 0.0 || Envelope(1, 5) != 0.5 || Envelope(2, 5) != 1.0 ||
        Envelope(3, 5) != 0.5 || Envelope(4, 5) != 0.0 || Envelope(0, 1) != 0.0) return 8;
    const int16_t tone[] = {10000, -10000};
    int16_t output[10]{};
    bool cancelled = false;
    if (!Render(tone, 1, 48000, 0, 5, 5, output, Cancelled, &cancelled) ||
        output[0] != 0 || output[2] != 5000 || output[4] != 10000 ||
        output[5] != -10000 || output[6] != 5000 || output[8] != 0) return 9;
    cancelled = true;
    output[0] = 1234;
    if (Render(tone, 1, 48000, 0, 5, 5, output, Cancelled, &cancelled) || output[0] != 1234) return 10;
    if (Render(tone, 0, 48000, 0, 5, 5, output, nullptr, nullptr) ||
        Render(tone, 1, 0, 0, 5, 5, output, nullptr, nullptr) ||
        Render(tone, 1, 48000, 4, 5, 2, output, nullptr, nullptr)) return 11;
    const uint8_t adts[] = {0xff, 0xf1, 0x4c, 0x80, 0x01, 0x5f, 0xfc, 0x11, 0x22, 0x33};
    neo::movie::aac::Packet packet;
    if (!neo::movie::aac::ParseAdts48kStereo(adts, sizeof(adts), packet) ||
        packet.offset != 7 || packet.size != 3 || packet.config[0] != 0x11 || packet.config[1] != 0x90) return 12;
    if (neo::movie::aac::ParseAdts48kStereo(adts, 6, packet) ||
        neo::movie::aac::ParseAdts48kStereo(adts, 9, packet)) return 13;
    const uint8_t wrongRate[] = {0xff, 0xf1, 0x50, 0x80, 0x01, 0x5f, 0xfc, 0x11, 0x22, 0x33};
    if (neo::movie::aac::ParseAdts48kStereo(wrongRate, sizeof(wrongRate), packet)) return 14;
    const uint8_t s24[] = {0, 0, 0x40, 0, 0, 0xc0};
    View s24View{s24, sizeof(s24), 1, 2, SampleKind::S24, 6, 3};
    if (!ReadStereo(s24View, 0, stereo) || stereo[0] != 16384 || stereo[1] != -16384) return 15;
    const uint8_t s32[] = {0, 0, 0, 0x40, 0, 0, 0, 0xc0};
    View s32View{s32, sizeof(s32), 1, 2, SampleKind::S32, 8, 4};
    if (!ReadStereo(s32View, 0, stereo) || stereo[0] != 16384 || stereo[1] != -16384) return 16;
    if (!ResampleLoop(source, 4, 24000, 7, stereo) || stereo[0] != 15000 || stereo[1] != 16000 ||
        !ResampleLoop(source, 4, 96000, 1, stereo) || stereo[0] != 20000 || stereo[1] != 21000) return 17;
    int16_t block[256];
    int checks = 0;
    block[128] = 1234;
    if (Render(tone, 1, 48000, 50000, 240000, 128, block, CancelDuringBlock, &checks) ||
        block[126] != 10000 || block[128] != 1234) return 18;
    const uint8_t crcAdts[] = {0xff, 0xf0, 0x4c, 0x80, 0x01, 0x9f, 0xfc, 0, 0, 0x11, 0x22, 0x33};
    if (!neo::movie::aac::ParseAdts48kStereo(crcAdts, sizeof(crcAdts), packet) ||
        packet.offset != 9 || packet.size != 3) return 19;
    // All PCM may be accepted before a codec prematurely emits EOS. The actual
    // packets must still cover the movie; a nonempty 46-packet prefix of 1s fails.
    using neo::movie::aac::HasCompleteDuration;
    if (HasCompleteDuration(960000, 46, 1000000)) return 20;
    if (!HasCompleteDuration(981333, 47, 1000000) ||
        !HasCompleteDuration(0, 1, 1) || !HasCompleteDuration(21333, 2, 42666)) return 21;
    if (HasCompleteDuration(981333, 46, 1000000) ||
        HasCompleteDuration(1000000, 47, 1000000) ||
        HasCompleteDuration(0, 0, 1) || HasCompleteDuration(0, 1, 0)) return 22;
    neo::movie::aac::Timeline timing;
    int64_t normalized = -1;
    if (!timing.Push(-21333, normalized) || normalized != 0 ||
        !timing.Push(0, normalized) || normalized != 21333 ||
        !timing.Push(21333, normalized) || normalized != 42666 ||
        !timing.Push(42667, normalized) || normalized != 64000) return 23;
    if (timing.Push(42667, normalized) || timing.Push(42666, normalized) ||
        timing.Push(85333, normalized)) return 24;
    if (!timing.Push(64000, normalized) || normalized != 85333) return 25;
    // Some codecs increment each packet by the integer 21333us period, rather
    // than rounding the cumulative rational clock. At 120s that is a 1874us
    // timestamp drift, while 5625 access units still contain exactly 120s PCM.
    if (!HasCompleteDuration(119976792, 5625, 120000000) ||
        HasCompleteDuration(119955459, 5624, 120000000)) return 26;
    // Phone capture, 2026-11-09: the target is 534400 PCM samples (522 AAC
    // access units). Two additional drain packets carry a 42666us jump even
    // though the complete retained prefix has already passed its checks.
    using neo::movie::aac::Disposition;
    using neo::movie::aac::TrackTimeline;
    TrackTimeline phoneTrack(11133333);
    if (phoneTrack.Complete()) return 30;
    for (int64_t i = 0; i < 522; ++i) {
        if (phoneTrack.Push(-42666 + i * 21333, normalized) != Disposition::Keep) return 28;
        if (i < 521 && phoneTrack.Complete()) return 31;
    }
    if (normalized != 11114493 || !phoneTrack.Complete()) return 29;
    if (phoneTrack.Push(11114493, normalized) != Disposition::Padding ||
        phoneTrack.Push(11135826, normalized) != Disposition::Padding ||
        normalized != 11114493 || !phoneTrack.Complete()) return 27;
    // A gap before the target is complete must still fail permanently. Later
    // output cannot turn a truncated prefix into a complete music track.
    TrackTimeline missing(11133333);
    if (missing.Push(-42666, normalized) != Disposition::Keep ||
        missing.Push(0, normalized) != Disposition::Invalid || normalized != 0 ||
        missing.Complete() || missing.Push(-21333, normalized) != Disposition::Invalid) return 32;
    TrackTimeline duplicate(1000000);
    if (duplicate.Push(100, normalized) != Disposition::Keep ||
        duplicate.Push(100, normalized) != Disposition::Invalid || duplicate.Complete()) return 33;
    TrackTimeline backwards(1000000);
    if (backwards.Push(100, normalized) != Disposition::Keep ||
        backwards.Push(99, normalized) != Disposition::Invalid || backwards.Complete()) return 34;
    // A single AAC packet covers even a sub-sample movie; extra drain data
    // does not change its saved PTS, and no packet means no complete track.
    TrackTimeline shortest(1);
    if (shortest.Complete() || shortest.Push(-42666, normalized) != Disposition::Keep ||
        normalized != 0 || !shortest.Complete() ||
        shortest.Push(-21333, normalized) != Disposition::Padding || normalized != 0) return 35;
    TrackTimeline zero(0), negative(-1), excessive(INT64_MAX);
    normalized = 1234;
    if (zero.Push(0, normalized) != Disposition::Invalid || zero.Complete() ||
        negative.Push(0, normalized) != Disposition::Invalid || negative.Complete() ||
        excessive.Push(0, normalized) != Disposition::Invalid || excessive.Complete() ||
        normalized != 1234) return 36;
    // Valid cadence still cannot put a retained packet outside the target.
    TrackTimeline tooLate(21334);
    if (tooLate.Push(0, normalized) != Disposition::Keep ||
        tooLate.Push(21334, normalized) != Disposition::Invalid || tooLate.Complete()) return 37;
    // The wrapper also preserves the original overflow-safe raw PTS handling.
    TrackTimeline overflow(1000000);
    if (overflow.Push(INT64_MIN, normalized) != Disposition::Keep ||
        overflow.Push(INT64_MAX, normalized) != Disposition::Invalid || overflow.Complete()) return 38;
    // MovieAudio passes attr.pts as both the copied raw input and normalized
    // output. This must preserve priming rebasing without corrupting raw PTS.
    TrackTimeline aliased(42666);
    int64_t attrPts = -42666;
    if (aliased.Push(attrPts, attrPts) != Disposition::Keep || attrPts != 0) return 39;
    attrPts = -21333;
    if (aliased.Push(attrPts, attrPts) != Disposition::Keep || attrPts != 21333 ||
        !aliased.Complete()) return 40;
    attrPts = 11135826;
    if (aliased.Push(attrPts, attrPts) != Disposition::Padding || attrPts != 11135826 ||
        !aliased.Complete()) return 41;
    return 0;
}

#ifndef __wasm__
int main() { return RunMovieAudioTests(); }
#endif
