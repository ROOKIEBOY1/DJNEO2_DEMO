#include "../../entry/src/main/cpp/VideoDiagnosticGop.h"

extern "C" void *memcpy(void *destination, const void *source, size_t size) {
    auto *out = static_cast<volatile unsigned char *>(destination);
    const auto *in = static_cast<const volatile unsigned char *>(source);
    for (size_t i = 0; i < size; ++i) out[i] = in[i];
    return destination;
}

struct Bytes {
    unsigned char data[128]{};
    size_t size_ = 0;
    Bytes() = default;
    Bytes(unsigned char value, size_t size) : size_(size) {
        for (size_t i = 0; i < size; ++i) data[i] = value;
    }
    bool empty() const { return size_ == 0; }
    size_t size() const { return size_; }
    void reserve(size_t) {}
    void clear() { size_ = 0; }
    const unsigned char *begin() const { return data; }
    const unsigned char *end() const { return data + size_; }
    unsigned char *end() { return data + size_; }
    void insert(unsigned char *, const unsigned char *first, const unsigned char *last) {
        while (first != last) data[size_++] = *first++;
    }
};

int main() {
    neo::VideoDiagnosticGop<Bytes> recorder(8);
    recorder.Record(Bytes(0x11, 2), false);
    if (recorder.Started() || recorder.Complete() || !recorder.Data().empty()) return 1;
    recorder.Record(Bytes(0x22, 3), true);
    recorder.Record(Bytes(0x33, 5), false);
    if (!recorder.Complete() || recorder.Overflowed() || recorder.Frames() != 2 ||
        recorder.InputBytes() != 8 || recorder.Data().size() != 8) return 2;
    for (size_t i = 0; i < 8; ++i)
        if (recorder.Data().data[i] != (i < 3 ? 0x22 : 0x33)) return 3;
    recorder.Record(Bytes(0x44, 1), false);
    if (recorder.Complete() || !recorder.Overflowed() || !recorder.Data().empty()) return 4;
    recorder.Record(Bytes(0x55, 2), false);
    if (!recorder.Overflowed() || !recorder.Data().empty() || recorder.Frames() != 4 ||
        recorder.InputBytes() != 11) return 5;
    recorder.Record(Bytes(0x66, 4), true);
    if (!recorder.Complete() || recorder.Overflowed() || recorder.Frames() != 1 ||
        recorder.InputBytes() != 4 || recorder.Data().data[0] != 0x66) return 6;
    if (recorder.NextSlot() != 0 || recorder.NextSlot() != 1 || recorder.NextSlot() != 0) return 7;
    recorder.Reset();
    if (recorder.Started() || recorder.Complete() || recorder.Overflowed() ||
        !recorder.Data().empty() || recorder.Frames() != 0) return 8;
    if (recorder.NextSlot() != 1) return 9;
    recorder.Record(Bytes(0x77, 9), true);
    if (!recorder.Started() || !recorder.Overflowed() || recorder.Complete() || !recorder.Data().empty()) return 10;
    recorder.Record(Bytes(0x88, 2), true);
    if (!recorder.Complete() || recorder.Data().size() != 2 || recorder.Data().data[1] != 0x88) return 11;
    recorder.SetNextSlot(1);
    if (recorder.NextSlot() != 1 || recorder.NextSlot() != 0) return 12;
    return 0;
}
