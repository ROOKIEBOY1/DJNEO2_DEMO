#pragma once
#include <cstdint>
#include <memory>
#include <vector>
namespace neo {
using Bytes = std::vector<uint8_t>;
struct AccessUnit {
  Bytes bytes;
  bool randomAccess = false;
};
// One Feed is a complete transport payload, never a partial NAL byte chunk.
class HevcStream {
public:
  HevcStream();
  ~HevcStream();
  HevcStream(const HevcStream &) = delete;
  HevcStream &operator=(const HevcStream &) = delete;
  std::vector<AccessUnit> Feed(const Bytes &, int64_t nowMs);
  // Release aged pending pictures without flushing the codec or changing
  // config.
  std::vector<AccessUnit> Drain(int64_t nowMs);
  void Reset();
  int Width() const;
  int Height() const;
  uint64_t Suppressed() const;
  uint64_t Reordered() const;
  // True for the latest Feed only: a previously seen parameter ID changed.
  // Timing-only VPS/SPS repetitions are suppressed before this comparison.
  bool ConfigChanged() const;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
} // namespace neo
