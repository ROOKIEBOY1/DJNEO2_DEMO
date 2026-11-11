#pragma once

namespace neo {
// The manifest is the commit marker. No raw replacement may start while the
// previous manifest is still trusted, and the new marker is published last.
template<class Sink> bool PublishVideoDiagnostic(Sink &sink, bool complete) {
    struct Cleanup { Sink &sink; ~Cleanup() { sink.CleanupTemporary(); } } cleanup{sink};
    if (!sink.InvalidateManifest()) return false;
    if (complete && !sink.WriteRawTemporary()) return false;
    if (!sink.WriteMetadataTemporary()) return false;
    if (complete ? !sink.PublishRaw() : !sink.RemoveRaw()) return false;
    return sink.PublishManifest();
}
} // namespace neo
