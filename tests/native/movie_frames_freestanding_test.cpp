#include "MovieFrames.h"
using namespace neo::movie;
extern "C" { int _fltused = 0; }
extern "C" int runMovieFrameTests() {
    auto landscape = MovieCanvas(3840, 2160, 0);
    if (landscape.width != 1920 || landscape.height != 1080) return 1;
    auto portrait = MovieCanvas(3840, 2160, 90);
    if (portrait.width != 1080 || portrait.height != 1920) return 2;
    if (MovieFrameCount(1000001) != 31 || MovieFrameTime(30) != 1000000) return 3;
    if (VideoGain(0,10000000) != 0 || VideoGain(50000,100000) != 1 || VideoGain(100000,100000) != 0) return 4;
    if (VideoGain(300000,10000000) < .499 || VideoGain(300000,10000000) > .501) return 5;
    uint8_t data[40] = {};
    data[2]=20; data[3]=40; data[6]=60; data[7]=80; data[18]=160; data[19]=100;
    FrameView source{data,sizeof(data),2,2,4,4,2,true,false};
    uint8_t output[54] = {};
    if (!RenderMovieFrameInto(source,{2,2},90,1,false,output,sizeof(output))) return 6;
    const uint8_t rotated[6]={60,20,80,40,100,160};
    for (int i=0;i<6;++i) if (output[i]!=rotated[i]) return 7;
    if (!RenderMovieFrameInto(source,{4,2},0,0,false,output,sizeof(output))) return 8;
    for (int i=0;i<12;++i) if (output[i]!=(i<8?16:128)) return 9;
    if (!RenderMovieFrameInto(source,{6,2},0,1,false,output,sizeof(output))) return 10;
    if (output[0]!=16 || output[2]!=20 || output[3]!=40 || output[4]!=16) return 11;
    source.capacity=18;
    if (RenderMovieFrameInto(source,{2,2},0,1,false,output,sizeof(output))) return 12;
    source.capacity=sizeof(data); source.fullRange=true; data[2]=255; data[3]=0;
    if (!RenderMovieFrameInto(source,{2,2},0,1,false,output,sizeof(output))) return 13;
    if (output[0]!=235 || output[1]!=16) return 14;
    source.fullRange=false; data[2]=20; data[3]=40;
    if (!RenderMovieFrameInto(source,{2,2},180,1,false,output,sizeof(output))) return 15;
    const uint8_t upsideDown[4]={80,60,40,20};
    for (int i=0;i<4;++i) if(output[i]!=upsideDown[i]) return 16;
    if (!RenderMovieFrameInto(source,{2,2},270,1,false,output,sizeof(output))) return 17;
    const uint8_t counterclockwise[4]={40,80,20,60};
    for (int i=0;i<4;++i) if(output[i]!=counterclockwise[i]) return 18;
    source.offset=-1;
    if (RenderMovieFrameInto(source,{2,2},0,1,false,output,sizeof(output))) return 19;
    source.offset=2;
    if (RenderMovieFrameInto(source,{2,2},0,1,false,output,5)) return 20;
    if (RenderMovieFrameInto(source,{3,2},0,1,false,output,sizeof(output))) return 21;
    if (RenderMovieFrameInto(source,{2,2},45,1,false,output,sizeof(output))) return 22;
    static uint8_t large[320*180*3/2] = {};
    static uint8_t credited[320*180*3/2] = {};
    static uint8_t plain[320*180*3/2] = {};
    FrameView creditSource{large,sizeof(large),320,180,320,180,0,false,false};
    if (!RenderMovieFrameInto(creditSource,{320,180},0,1,true,credited,sizeof(credited))) return 23;
    if (!RenderMovieFrameInto(creditSource,{320,180},0,1,false,plain,sizeof(plain))) return 24;
    bool changed=false;
    for (unsigned i=0;i<sizeof(plain);++i) if(plain[i]!=credited[i]) changed=true;
    if (!changed) return 25;
    if (MovieClipFrameTime(1,31,1000001) != 32258) return 26;
    // Even a one-millisecond source occupies one output frame, preserving every clip in source order.
    const int64_t firstCount=MovieFrameCount(1000), secondCount=MovieFrameCount(16666);
    if (firstCount!=1 || secondCount!=1 || MovieFrameTime(firstCount+secondCount)!=66666) return 27;
    if (MovieClipFrameTime(0,firstCount,1000)!=0) return 28;
    if (!RenderMovieFrameInto(source,{6,6},0,1,false,output,sizeof(output))) return 29;
    if (output[0]!=16 || output[14]!=20 || output[15]!=40 || output[20]!=60 || output[21]!=80) return 30;
    // A second of extra decoded pictures must fail instead of being silently dropped at the metadata end.
    if (MovieSourcePtsFits(2000000,1000000)) return 31;
    if (!MovieSourcePtsFits(1033332,1000000) || MovieSourcePtsFits(1033333,1000000)) return 32;
    if (MovieSourcePtsFits(-1,1000000) || MovieSourcePtsFits(0,0)) return 33;
    // A legitimately sparse VFR track may hold its last picture; no arbitrary last-frame-gap rejection.
    if (!MovieSourcePtsFits(0,10000000)) return 34;
    if (!MovieTimelineCovers(966666,33334,1000000)) return 35;
    if (!MovieTimelineCovers(981333,21334,1000000)) return 36;
    if (MovieTimelineCovers(960000,21334,1000000)) return 37; // AAC ends early, even if video duration is correct
    if (MovieTimelineCovers(999999,33334,500000) || MovieTimelineCovers(-1,21334,1000000)) return 38;
    if (!MovieTrackDurationFits(1002667,1000000,21334)) return 39;
    if (MovieTrackDurationFits(750000,1000000,21334)) return 40;
    if (MoviePacketCount(3600000000LL,true)!=168750 || MoviePacketCount(3600000000LL,false)!=108000) return 41;
    if (MoviePacketCount(33333,true)!=2 || MoviePacketCount(33333,false)!=1) return 42;
    return 0;
}
extern "C" int main() { return runMovieFrameTests(); }
