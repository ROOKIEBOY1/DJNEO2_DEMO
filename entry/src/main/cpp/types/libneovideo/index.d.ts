export interface VideoPreviewStats {
  running: boolean;
  waitingForKey: boolean;
  queued: number;
  queuedBytes: number;
  queueDrops: number;
  assembledFrames: number;
  submittedFrames: number;
  decodedFrames: number;
  renderedFrames: number;
  decodeErrors: number;
  suppressedParameters: number;
  reorderedFrames: number;
  width: number;
  height: number;
  lastAssembledAgeMs: number;
  lastDecodedAgeMs: number;
  lastRenderedAgeMs: number;
  lastError: string;
  decoderEpoch: number;
  consecutiveFailures: number;
  recoveryPaused: boolean;
  configurationRetained: boolean;
  waitingForKeyAgeMs: number;
  lastResetReason: string;
  parameterMask: number;
  randomAccessFrames: number;
  acceptedRandomAccessFrames: number;
  lastSubmittedAgeMs: number;
}
export const start: (surfaceId: string) => void;
export const switchSurface: (surfaceId: string) => boolean;
export const stop: () => void;
export const submit: (bytes: ArrayBuffer) => void;
export const snapshot: () => VideoPreviewStats;
export interface DecodedFrame {
  rgba: ArrayBuffer;
  width: number;
  height: number;
  capturedAtMs: number;
}
export const requestFrame: () => number;
export const takeFrame: (ticket: number) => DecodedFrame | undefined;
export interface MovieExportSnapshot {
  id: number;
  stage: string;
  progress: number;
  durationMs: number;
  error: string;
  outputPath: string;
}
export const startMovieExport: (sources: string[], outputPath: string, musicPath: string) => number;
export const movieExportSnapshot: (id: number) => MovieExportSnapshot;
export const cancelMovieExport: (id: number) => void;
