#include "AvcConfiguration.h"
using namespace neo::movie;
extern "C" int main() {
    // Extracted from the real green MP4: nonempty avcC, but no SPS or PPS.
    const unsigned char emptyAvcc[] = {0x01,0x64,0x00,0x1f,0xff,0xe0,0x00,0xfc,0xf8,0xf8,0x00};
    if (InspectAvcConfiguration(emptyAvcc, sizeof(emptyAvcc)).complete) return 1;
    // Structurally complete baseline SPS/PPS, with mixed Annex-B start-code lengths.
    const unsigned char annexB[] = {0,0,0,1,0x67,0x42,0,0x1f,0x80,0,0,1,0x68,0xc0};
    const auto annex = InspectAvcConfiguration(annexB, sizeof(annexB));
    if (!annex.complete || annex.sps != 1 || annex.pps != 1) return 2;
    const unsigned char avcc[] = {1,0x42,0,0x1f,0xff,0xe1,0,5,0x67,0x42,0,0x1f,0x80,1,0,2,0x68,0xc0};
    const auto record = InspectAvcConfiguration(avcc, sizeof(avcc));
    if (!record.complete || record.sps != 1 || record.pps != 1) return 3;
    // A missing/truncated parameter set must never be accepted as playable configuration.
    if (InspectAvcConfiguration(annexB, 9).complete) return 4;
    if (InspectAvcConfiguration(avcc, sizeof(avcc) - 1).complete) return 5;
    const unsigned char onlyPps[] = {0,0,1,0x68,0xc0};
    if (InspectAvcConfiguration(onlyPps, sizeof(onlyPps)).complete) return 6;
    const unsigned char emptyNal[] = {0,0,1,0x67,0x42,0,0x1f,0x80,0,0,1};
    if (InspectAvcConfiguration(emptyNal, sizeof(emptyNal)).complete) return 7;
    const unsigned char wrongTypes[] = {1,0x42,0,0x1f,0xff,0xe1,0,5,0x65,0x42,0,0x1f,0x80,1,0,2,0x68,0xc0};
    if (InspectAvcConfiguration(wrongTypes, sizeof(wrongTypes)).complete) return 8;
    if (InspectAvcConfiguration(nullptr, 10).complete || InspectAvcConfiguration(avcc, 0).complete) return 9;
    // Demuxers may return configuration in the same Annex-B sample as an IDR picture.
    const unsigned char keyframe[] = {0,0,1,0x67,0x42,0,0x1f,0x80,0,0,1,0x68,0xc0,0,0,1,0x65,0x88};
    if (!InspectAvcConfiguration(keyframe, sizeof(keyframe)).complete) return 10;
    return 0;
}
