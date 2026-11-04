#include "HevcStream.h"
#include <algorithm>
#include <map>
#include <stdexcept>
#include <string>
#include <tuple>
namespace neo {
namespace {
struct Bits {
  Bytes data;
  size_t pos = 0;
  explicit Bits(const Bytes &b, size_t start = 2) {
    for (size_t i = start; i < b.size(); ++i) {
      if (i >= start + 2 && b[i] == 3 && b[i - 1] == 0 && b[i - 2] == 0 &&
          i + 1 < b.size() && b[i + 1] <= 3)
        continue;
      data.push_back(b[i]);
    }
  }
  uint64_t read(size_t n = 1) {
    if (n > 64 || pos + n > data.size() * 8)
      throw std::runtime_error("truncated");
    uint64_t v = 0;
    while (n--) {
      v = (v << 1) | ((data[pos / 8] >> (7 - pos % 8)) & 1);
      ++pos;
    }
    return v;
  }
  void skip(size_t n) {
    while (n) {
      auto k = std::min<size_t>(n, 64);
      read(k);
      n -= k;
    }
  }
  unsigned ue() {
    unsigned z = 0;
    while (!read()) {
      if (++z > 31)
        throw std::runtime_error("ue");
    }
    return unsigned((uint64_t(1) << z) - 1 + read(z));
  }
};
void ptl(Bits &b, unsigned l) {
  b.skip(96);
  std::vector<std::pair<bool, bool>> f;
  for (unsigned i = 0; i < l; ++i) {
    bool p = b.read(), v = b.read();
    f.emplace_back(p, v);
  }
  if (l)
    b.skip(2 * (8 - l));
  for (auto a : f) {
    if (a.first)
      b.skip(88);
    if (a.second)
      b.skip(8);
  }
}
int kind(const Bytes &b) { return b.empty() ? -1 : (b[0] >> 1) & 63; }
void layer(const Bytes &b) {
  if (b.size() < 2 || (b[0] & 1) || b[1] != 1)
    throw std::runtime_error("layer");
}
struct Nal {
  Bytes raw, nal;
};
std::vector<Nal> split(const Bytes &b) {
  std::vector<std::pair<size_t, size_t>> starts;
  for (size_t i = 0; i + 2 < b.size();) {
    size_t n = 0;
    if (b[i] == 0 && b[i + 1] == 0) {
      if (b[i + 2] == 1)
        n = 3;
      else if (i + 3 < b.size() && b[i + 2] == 0 && b[i + 3] == 1)
        n = 4;
    }
    if (n) {
      starts.emplace_back(i, n);
      i += n;
    } else
      ++i;
  }
  std::vector<Nal> r;
  for (size_t i = 0; i < starts.size(); ++i) {
    auto a = starts[i];
    size_t e = i + 1 < starts.size() ? starts[i + 1].first : b.size();
    r.push_back({Bytes(b.begin() + a.first, b.begin() + e),
                 Bytes(b.begin() + a.first + a.second, b.begin() + e)});
  }
  if (!r.empty() && starts[0].first)
    r[0].raw.insert(r[0].raw.begin(), b.begin(), b.begin() + starts[0].first);
  return r;
}
std::pair<int, Bytes> signature(const Bytes &n) {
  layer(n);
  if (n.size() > 4096)
    throw std::runtime_error("size");
  Bits b(n);
  int k = kind(n), id = 0;
  if (k == 32) {
    id = b.read(4);
    b.skip(2);
    auto max = b.read(6), l = b.read(3);
    b.skip(17);
    ptl(b, l);
    bool o = b.read();
    for (unsigned i = o ? 0 : l; i <= l; ++i)
      for (int j = 0; j < 3; ++j)
        b.ue();
    auto lid = b.read(6);
    auto sets = b.ue();
    if (max || sets > 1024)
      throw std::runtime_error("multi");
    b.skip(sets * (lid + 1));
  } else if (k == 33) {
    b.skip(4);
    auto l = b.read(3);
    b.read();
    ptl(b, l);
    id = b.ue();
    auto c = b.ue();
    if (id > 15 || c > 3)
      throw std::runtime_error("sps");
    if (c == 3)
      b.read();
    b.ue();
    b.ue();
    if (b.read())
      for (int i = 0; i < 4; ++i)
        b.ue();
    b.ue();
    b.ue();
    auto w = uint64_t(b.ue()) + 4;
    if (w > 16)
      throw std::runtime_error("poc");
    bool o = b.read();
    for (unsigned i = o ? 0 : l; i <= l; ++i)
      for (int j = 0; j < 3; ++j)
        b.ue();
    for (int i = 0; i < 6; ++i)
      b.ue();
    if (b.read() && b.read())
      throw std::runtime_error("scaling");
    b.skip(2);
    if (b.read()) {
      b.skip(8);
      b.ue();
      b.ue();
      b.read();
    }
    auto nr = b.ue();
    if (nr > 64)
      throw std::runtime_error("rps");
    unsigned prev = 0;
    for (unsigned i = 0; i < nr; ++i) {
      unsigned count = 0;
      if (i && b.read()) {
        b.read();
        b.ue();
        for (unsigned j = 0; j <= prev; ++j) {
          bool used = b.read();
          if (used || b.read())
            ++count;
        }
      } else {
        auto neg = b.ue(), pos = b.ue();
        if (neg > 64 || pos > 64)
          throw std::runtime_error("rps");
        count = neg + pos;
        if (count > 64)
          throw std::runtime_error("rps");
        for (unsigned j = 0; j < count; ++j) {
          b.ue();
          b.read();
        }
      }
      prev = count;
    }
    if (b.read()) {
      auto count = b.ue();
      if (count > 32)
        throw std::runtime_error("long rps");
      b.skip(count * (w + 1));
    }
    b.skip(2);
    if (!b.read())
      throw std::runtime_error("vui");
    if (b.read() && b.read(8) == 255)
      b.skip(32);
    if (b.read())
      b.read();
    if (b.read()) {
      b.skip(4);
      if (b.read())
        b.skip(24);
    }
    if (b.read()) {
      b.ue();
      b.ue();
    }
    b.skip(3);
    if (b.read())
      for (int i = 0; i < 4; ++i)
        b.ue();
  } else
    throw std::runtime_error("parameter");
  if (!b.read())
    throw std::runtime_error("timing");
  size_t p = b.pos;
  if (!b.read(32) || !b.read(32))
    throw std::runtime_error("zero timing");
  for (size_t i = p; i < p + 64; ++i)
    b.data[i / 8] &= uint8_t(~(1u << (7 - i % 8)));
  return {id, b.data};
}
struct Sps {
  int poc = 0, width = 0, height = 0;
};
Sps sps(const Bytes &n, unsigned &id) {
  layer(n);
  Bits b(n);
  b.skip(4);
  auto l = b.read(3);
  b.read();
  ptl(b, l);
  id = b.ue();
  auto c = b.ue();
  if (id > 15 || c > 3)
    throw std::runtime_error("sps");
  bool separate = c == 3 && b.read();
  auto w = b.ue(), h = b.ue();
  uint64_t x0 = 0, x1 = 0, y0 = 0, y1 = 0;
  if (b.read()) {
    x0 = b.ue();
    x1 = b.ue();
    y0 = b.ue();
    y1 = b.ue();
  }
  unsigned subx = (c == 1 || c == 2) && !separate ? 2 : 1,
           suby = c == 1 && !separate ? 2 : 1;
  uint64_t cropx = (x0 + x1) * subx, cropy = (y0 + y1) * suby;
  if (!w || !h || w > 16384 || h > 16384 || cropx >= w || cropy >= h)
    throw std::runtime_error("dimensions");
  Sps out;
  out.width = w - cropx;
  out.height = h - cropy;
  b.ue();
  b.ue();
  uint64_t bits = uint64_t(b.ue()) + 4;
  bool order = b.read();
  bool low = true;
  for (unsigned i = order ? 0 : l; i <= l; ++i) {
    b.ue();
    if (b.ue())
      low = false;
    b.ue();
  }
  if (!l && c <= 2 && bits <= 16 && low)
    out.poc = bits;
  return out;
}
struct Pps {
  unsigned sps;
  bool output;
  unsigned extra;
  bool simple;
};
} // namespace
struct HevcStream::Impl {
  std::map<std::pair<int, int>, Bytes> signatures, parameters;
  std::map<unsigned, Sps> spss;
  std::map<unsigned, Pps> ppss;
  struct Pending {
    int poc;
    int modulus;
    int64_t at;
    AccessUnit au;
  };
  std::vector<Pending> pending;
  // Serial ages distinguish a proven stale POC from an ambiguous large loss.
  std::map<int, int64_t> retired;
  int expected = -1;
  std::string active;
  bool bypass = false, changed = false;
  int width = 0, height = 0;
  uint64_t suppressed = 0, reordered = 0;
  int64_t serial = 0;
  void clearOrder() {
    pending.clear();
    expected = -1;
    retired.clear();
    serial = 0;
  }
  std::vector<AccessUnit> drain() {
    std::vector<AccessUnit> o;
    for (auto &p : pending)
      o.push_back(std::move(p.au));
    clearOrder();
    return o;
  }
  void advance(int p, int mod) {
    int delta = (p - expected + mod) % mod;
    for (int i = std::max(0, delta - 31); i <= delta; ++i)
      retired[(expected + i) % mod] = serial + i;
    serial += delta + 1;
    expected = (p + 1) % mod;
    for (auto it = retired.begin(); it != retired.end();)
      if (serial - it->second >= mod / 2)
        it = retired.erase(it);
      else
        ++it;
    while (retired.size() > 32) {
      auto it = std::min_element(
          retired.begin(), retired.end(),
          [](auto &a, auto &b) { return a.second < b.second; });
      retired.erase(it);
    }
  }
  void emit(size_t i, int mod, std::vector<AccessUnit> &o) {
    int p = pending[i].poc;
    o.push_back(std::move(pending[i].au));
    pending.erase(pending.begin() + i);
    advance(p, mod);
  }
  size_t nearest(int mod) {
    size_t n = 0;
    for (size_t i = 1; i < pending.size(); ++i)
      if ((pending[i].poc - expected + mod) % mod <
          (pending[n].poc - expected + mod) % mod)
        n = i;
    return n;
  }
  std::vector<AccessUnit> order(AccessUnit au, int64_t now) {
    auto ns = split(au.bytes);
    int pic = -1, poc = 0, mod = 0;
    std::string key;
    try {
      if (ns.empty())
        throw std::runtime_error("annexb");
      for (auto &n : ns) {
        layer(n.nal);
        int k = kind(n.nal);
        Bits b(n.nal);
        if (k == 33) {
          unsigned id;
          auto s = sps(n.nal, id);
          spss[id] = s;
          width = s.width;
          height = s.height;
        } else if (k == 34) {
          auto id = b.ue(), sid = b.ue();
          bool dep = b.read(), out = b.read();
          auto extra = b.read(3);
          if (id > 63 || sid > 15)
            throw std::runtime_error("pps");
          ppss[id] = {sid, out, unsigned(extra), !dep};
        } else if (k <= 31) {
          if (pic != -1 || !(k == 1 || k == 19 || k == 20) || !b.read())
            throw std::runtime_error("slice");
          if (k == 19 || k == 20)
            b.read();
          auto id = b.ue();
          auto pp = ppss.find(id);
          if (pp == ppss.end() || !pp->second.simple)
            throw std::runtime_error("pps");
          auto ppv = pp->second;
          auto ss = spss.find(ppv.sps);
          if (ss == spss.end() || !ss->second.poc)
            throw std::runtime_error("sps");
          b.skip(ppv.extra);
          auto st = b.ue();
          if (st != 1 && st != 2)
            throw std::runtime_error("b");
          if (ppv.output)
            b.read();
          pic = k;
          poc = (k == 19 || k == 20) ? 0 : b.read(ss->second.poc);
          mod = 1 << ss->second.poc;
          key = std::to_string(ppv.sps) + ":" + std::to_string(id) + ":" +
                std::to_string(ppv.output) + ":" + std::to_string(ppv.extra) +
                ":" + std::to_string(mod);
        }
      }
    } catch (...) {
      spss.clear();
      ppss.clear();
      active.clear();
      auto o = drain();
      o.push_back(std::move(au));
      return o;
    }
    if (pic < 0)
      return {std::move(au)};
    if (key != active || pic == 19 || pic == 20) {
      clearOrder();
      active = key;
      bypass = false;
    }
    if (bypass)
      return {std::move(au)};
    if (expected < 0) {
      expected = poc;
      advance(poc, mod);
      return {std::move(au)};
    }
    std::vector<AccessUnit> o;
    if ((poc - expected + mod) % mod >= mod / 2 && !pending.empty() &&
        (pending.size() + 1 >= 3 || now - pending.front().at >= 120))
      while (!pending.empty())
        emit(nearest(mod), mod, o);
    if ((poc - expected + mod) % mod >= mod / 2) {
      if (retired.count(poc))
        return o;
      bypass = true;
      auto old = drain();
      for (auto &a : old)
        o.push_back(std::move(a));
      o.push_back(std::move(au));
      return o;
    }
    auto dup = std::find_if(pending.begin(), pending.end(),
                            [poc](auto &p) { return p.poc == poc; });
    if (dup == pending.end())
      pending.push_back({poc, mod, now, std::move(au)});
    else {
      dup->at = now;
      dup->au = std::move(au);
    }
    release(now, true, o);
    return o;
  }
  // Both arrival-triggered and timer-triggered release advance the same retired
  // positions. A timer must not reset order state, or a late predecessor could
  // rewind the decoder reference chain after a missing picture was skipped.
  void release(int64_t now, bool capacity, std::vector<AccessUnit> &o) {
    while (!pending.empty()) {
      int mod = pending.front().modulus;
      auto it = std::find_if(pending.begin(), pending.end(),
                             [this](auto &p) { return p.poc == expected; });
      size_t i;
      if (it == pending.end()) {
        if ((!capacity || pending.size() < 3) && now - pending.front().at < 120)
          break;
        i = nearest(mod);
      } else
        i = it - pending.begin();
      if (i)
        ++reordered;
      emit(i, mod, o);
    }
  }
};
HevcStream::HevcStream() : impl_(new Impl) {}
HevcStream::~HevcStream() = default;
std::vector<AccessUnit> HevcStream::Drain(int64_t now) {
  std::vector<AccessUnit> output;
  impl_->release(now, false, output);
  return output;
}
void HevcStream::Reset() { impl_.reset(new Impl); }
int HevcStream::Width() const { return impl_->width; }
int HevcStream::Height() const { return impl_->height; }
uint64_t HevcStream::Suppressed() const { return impl_->suppressed; }
uint64_t HevcStream::Reordered() const { return impl_->reordered; }
bool HevcStream::ConfigChanged() const { return impl_->changed; }
std::vector<AccessUnit> HevcStream::Feed(const Bytes &payload, int64_t now) {
  auto &s = *impl_;
  s.changed = false;
  if (payload.empty())
    return {};
  auto ns = split(payload);
  if (ns.empty())
    return s.order({payload, false}, now);
  std::vector<Nal> kept;
  for (auto &n : ns) {
    int k = kind(n.nal);
    if (k == 32 || k == 33) {
      try {
        auto sig = signature(n.nal);
        auto key = std::make_pair(k, sig.first);
        auto it = s.signatures.find(key);
        if (it != s.signatures.end() && it->second == sig.second) {
          ++s.suppressed;
          continue;
        }
        s.signatures[key] = sig.second;
      } catch (...) {
        for (auto it = s.signatures.begin(); it != s.signatures.end();)
          if (it->first.first == k)
            it = s.signatures.erase(it);
          else
            ++it;
      }
    }
    if (k >= 32 && k <= 34) {
      int id = 0;
      try {
        if (k == 32) {
          Bits b(n.nal);
          id = b.read(4);
        }
        if (k == 33) {
          unsigned sid;
          auto v = sps(n.nal, sid);
          id = sid;
          s.width = v.width;
          s.height = v.height;
        }
        if (k == 34) {
          Bits b(n.nal);
          auto parsed = b.ue();
          if (parsed > 63)
            throw std::runtime_error("PPS id");
          id = parsed;
        }
      } catch (...) {
        id = -1;
      }
      auto key = std::make_pair(k, id);
      auto it = s.parameters.find(key);
      if (it != s.parameters.end() && it->second != n.nal) {
        s.changed = true;
        s.clearOrder();
        s.active.clear();
        s.bypass = false;
      }
      s.parameters[key] = n.nal;
    }
    kept.push_back(std::move(n));
  }
  // Prefix NALs start a following AU; suffix SEI and EOS stay with the picture.
  std::vector<AccessUnit> aus;
  AccessUnit current;
  bool vcl = false;
  for (auto &n : kept) {
    int k = kind(n.nal);
    bool first = k >= 0 && k <= 31 && n.nal.size() > 2 && (n.nal[2] & 128);
    bool prefix = k == 32 || k == 33 || k == 34 || k == 35 || k == 39 ||
                  (k >= 41 && k <= 44) || (k >= 48 && k <= 55);
    if (vcl && (first || prefix)) {
      aus.push_back(std::move(current));
      current = {};
      vcl = false;
    }
    current.bytes.insert(current.bytes.end(), n.raw.begin(), n.raw.end());
    if (k >= 0 && k <= 31) {
      vcl = true;
      if (k >= 16 && k <= 23)
        current.randomAccess = true;
    }
    if (k == 36 || k == 37) {
      aus.push_back(std::move(current));
      current = {};
      vcl = false;
    }
  }
  if (!current.bytes.empty())
    aus.push_back(std::move(current));
  std::vector<AccessUnit> result;
  for (auto &a : aus) {
    auto out = s.order(std::move(a), now);
    for (auto &b : out)
      result.push_back(std::move(b));
  }
  return result;
}
} // namespace neo
