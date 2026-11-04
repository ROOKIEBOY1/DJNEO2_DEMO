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
}
export const start: (surfaceId: string) => void;
export const stop: () => void;
export const submit: (bytes: ArrayBuffer) => void;
export const snapshot: () => VideoPreviewStats;
