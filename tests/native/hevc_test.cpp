#include "HevcStream.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <iterator>
using namespace neo;
Bytes join(const std::vector<AccessUnit> &a) {
  Bytes b;
  for (auto &x : a)
    b.insert(b.end(), x.bytes.begin(), x.bytes.end());
  return b;
}
Bytes picture(int p, bool b = false) {
  unsigned v = b ? ((7u << 5) | (unsigned(p) << 1) | 1)
                 : ((26u << 5) | (unsigned(p) << 1) | 1);
  return {0,
          0,
          0,
          1,
          2,
          1,
          uint8_t((v << (b ? 7 : 6)) >> 8),
          uint8_t(v << (b ? 7 : 6))};
}
std::vector<Bytes> fixture(const char *p) {
  std::ifstream f(p, std::ios::binary);
  assert(f);
  std::vector<Bytes> v;
  while (f) {
    char t[8];
    uint32_t n = 0;
    f.read(t, 8);
    f.read(reinterpret_cast<char *>(&n), 4);
    if (!f)
      break;
    assert(n < 2000000);
    Bytes b(n);
    f.read(reinterpret_cast<char *>(b.data()), n);
    assert(f);
    v.push_back(b);
  }
  return v;
}
void seed(HevcStream &s, const std::vector<Bytes> &f) {
  s.Feed(f[0], 0);
  s.Feed(f[1], 0);
}
int main(int argc, char **argv) {
  assert(argc == 2);
  auto f = fixture(argv[1]);
  assert(f.size() > 5);
  HevcStream s;
  size_t count = 0;
  for (auto &b : f)
    for (auto &a : s.Feed(b, 0))
      if (a.randomAccess || a.bytes.size() > 1000)
        ++count;
  assert(s.Width() == 1280 && s.Height() == 720);
  assert(s.Reordered() == 1);
  assert(count >= 6);
  s.Reset();
  assert(s.Width() == 0 && s.Suppressed() == 0);
  seed(s, f);
  assert(s.Feed(picture(2), 0).empty());
  auto o = s.Feed(picture(1), 0);
  assert(o.size() == 2);
  assert(o[0].bytes == picture(1));
  assert(o[1].bytes == picture(2));
  s.Reset();
  seed(s, f);
  for (int p = 1; p < 15; ++p)
    assert(join(s.Feed(picture(p), 0)) == picture(p));
  assert(s.Feed(picture(0), 0).empty());
  assert(s.Feed(picture(15), 0).size() == 2);
  s.Reset();
  seed(s, f);
  assert(s.Feed(picture(2), 0).empty());
  assert(s.Feed(picture(3), 0).empty());
  assert(s.Feed(picture(4), 0).size() == 3);
  assert(s.Feed(picture(1), 0).empty());
  assert(s.Feed(picture(2), 0).empty());
  assert(s.Feed(picture(5), 0).size() == 1);
  s.Reset();
  seed(s, f);
  assert(s.Feed(picture(2), 0).empty());
  assert(s.Feed(picture(3), 121).size() == 2);
  s.Reset();
  seed(s, f);
  for (int p : {14, 15, 0, 1, 3, 2})
    assert(join(s.Feed(picture(p), 0)) == picture(p));
  s.Reset();
  seed(s, f);
  assert(s.Feed(picture(2), 0).empty());
  auto unknown = Bytes{0, 0, 0, 1, 2};
  assert(s.Feed(unknown, 0).size() == 2);
  s.Reset();
  seed(s, f);
  Bytes both = picture(1);
  auto p2 = picture(2);
  both.insert(both.end(), p2.begin(), p2.end());
  assert(s.Feed(both, 0).size() == 2);
  s.Reset();
  auto a = s.Feed(f[0], 0);
  assert(!a.empty());
  s.Feed(f[0], 0);
  assert(s.Suppressed() >= 2);
  assert(!s.ConfigChanged());

  s.Reset();
  seed(s, f);
  Bytes timing = {0,   0,  0,  1,   64,  1,   12,  1,   255, 255, 33,  96, 0,
                  0,   3,  0,  0,   3,   0,   0,   3,   0,   0,   3,   0,  150,
                  172, 12, 0,  0,   3,   0,   8,   0,   0,   3,   0,   61, 64,
                  0,   0,  0,  1,   66,  1,   1,   33,  96,  0,   0,   3,  0,
                  0,   3,  0,  0,   3,   0,   0,   3,   0,   150, 160, 2,  128,
                  128, 45, 31, 250, 238, 220, 154, 229, 212, 212, 4,   4,  4,
                  16,  0,  0,  3,   0,   32,  0,   0,   3,   0,   240, 128};
  auto before = s.Suppressed();
  assert(s.Feed(timing, 0).empty());
  assert(s.Suppressed() == before + 2);
  assert(!s.ConfigChanged());
  s.Reset();
  seed(s, f);
  assert(s.Feed(picture(2), 0).empty());
  auto bp = picture(1, true);
  assert(s.Feed(bp, 0).size() == 2);
  assert(join(s.Feed(picture(3), 0)) == picture(3));
  s.Reset();
  seed(s, f);
  assert(s.Feed(picture(2), 0).empty());
  Bytes pps = {0, 0, 0, 1, 0x44, 1, 0xd1, 0x73, 0x12, 0x24, 8, 0x90};
  assert(join(s.Feed(pps, 0)) == pps);
  assert(s.ConfigChanged());
  assert(s.Feed(picture(1), 0).size() == 1);
  s.Reset();
  seed(s, f);
  assert(s.Feed(picture(2), 0).empty());
  auto refresh = s.Feed(f[1], 0);
  assert(!refresh.empty());
  assert(s.Feed(picture(2), 0).empty());
  assert(s.Feed(picture(1), 0).size() == 2);
  s.Reset();
  seed(s, f);
  for (int i = 1; i < 8; ++i)
    s.Feed(picture(i), 0);
  assert(s.Feed(picture(14), 0).empty());
  assert(s.Feed(picture(15), 0).empty());
  assert(s.Feed(picture(0), 0).size() == 3);
  s.Reset();
  seed(s, f);
  assert(s.Feed(picture(2), 0).empty());
  assert(s.Feed({}, 120).empty());
  assert(s.Drain(119).empty());
  auto expired = s.Drain(120);
  assert(expired.size() == 1 && expired[0].bytes == picture(2));
  assert(s.Drain(121).empty());
  assert(s.Feed(picture(1), 121).empty());
  assert(join(s.Feed(picture(3), 121)) == picture(3));
  std::cout << "HEVC fixture, AU split, timing repeats, dimensions, reorder, "
               "wrap, retirement, timeout, bypass, truncation: PASS\n";
}
