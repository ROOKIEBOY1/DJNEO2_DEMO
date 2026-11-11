#include "../../entry/src/main/cpp/VideoDiagnosticPublish.h"

struct Sink {
    int fail = 0, rawVersion = 1, manifestVersion = 1;
    bool trusted = true, unsafeWrite = false, touchedRaw = false, cleaned = false;
    bool InvalidateManifest() { if (fail == 1) return false; trusted = false; return true; }
    bool WriteRawTemporary() { unsafeWrite = trusted; touchedRaw = true; return fail != 2; }
    bool WriteMetadataTemporary() { return fail != 3; }
    bool PublishRaw() { if (fail == 4) return false; rawVersion = 2; return true; }
    bool RemoveRaw() { if (fail == 4) return false; touchedRaw = true; rawVersion = 0; return true; }
    bool PublishManifest() { if (fail == 5) return false; manifestVersion = 2; trusted = true; return true; }
    void CleanupTemporary() { cleaned = true; }
};

int main() {
    for (int failure = 1; failure <= 5; ++failure) {
        Sink sink; sink.fail = failure;
        if (neo::PublishVideoDiagnostic(sink, true)) return 1;
        if (sink.unsafeWrite || !sink.cleaned) return 2;
        if (failure == 1) {
            if (!sink.trusted || sink.touchedRaw || sink.rawVersion != 1) return 3;
        } else if (sink.trusted) return 4;
    }
    Sink complete;
    if (!neo::PublishVideoDiagnostic(complete, true) || complete.unsafeWrite ||
        !complete.trusted || complete.rawVersion != 2 || complete.manifestVersion != 2 || !complete.cleaned) return 5;
    Sink incomplete;
    if (!neo::PublishVideoDiagnostic(incomplete, false) || !incomplete.trusted ||
        incomplete.rawVersion != 0 || incomplete.manifestVersion != 2) return 6;
    Sink undeletable; undeletable.fail = 4;
    if (neo::PublishVideoDiagnostic(undeletable, false) || undeletable.trusted || undeletable.rawVersion != 1) return 7;
    return 0;
}
