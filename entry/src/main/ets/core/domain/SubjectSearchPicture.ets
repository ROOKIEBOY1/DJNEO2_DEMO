import { VideoPreviewSnapshot } from '../media/VideoPreview';

export const SEARCH_PICTURE_WAIT_MS: number = 15000;
export const SEARCH_PICTURE_STABLE_MS: number = 500;

export class SubjectSearchFrameUnavailable extends Error {
  readonly reason: 'readback_timeout' | 'decoder_changed' | 'decoder_unready';

  constructor(reason: 'readback_timeout' | 'decoder_changed' | 'decoder_unready', message: string) {
    super(message);
    this.name = 'SubjectSearchFrameUnavailable';
    this.reason = reason;
  }
}

export function searchPictureNeedsRecovery(preview: VideoPreviewSnapshot): boolean {
  if (preview.state !== 'live') return true;
  const stats = preview.stats;
  if (stats === undefined) return false;
  if (stats.running === false || stats.waitingForKey === true ||
    stats.recoveryPaused === true) return true;
  // Existing lightweight controller fixtures omit age. Native snapshots always
  // supply it, and a supplied invalid age must never authorize fresh capture.
  const age = stats.lastRenderedAgeMs;
  return age !== undefined && (!Number.isFinite(age) || age < 0 || age > SEARCH_PICTURE_STABLE_MS);
}

export class SubjectSearchPictureStability {
  private startedAtMs: number = -1;
  private observedAtMs: number = -1;
  private outputAtMs: number = -1;
  private renderedFrames: number = 0;
  private decoderEpoch: number = -1;

  reset(): void {
    this.startedAtMs = -1;
    this.observedAtMs = -1;
    this.outputAtMs = -1;
    this.renderedFrames = 0;
    this.decoderEpoch = -1;
  }

  observe(preview: VideoPreviewSnapshot, nowMs: number): boolean {
    const stats = preview.stats;
    if (stats === undefined) {
      this.reset();
      return false;
    }
    const count = stats.renderedFrames;
    const age = stats.lastRenderedAgeMs;
    const epoch = stats.decoderEpoch;
    if (searchPictureNeedsRecovery(preview) || stats.running !== true || stats.waitingForKey !== false ||
      !Number.isInteger(count) || count <= 0 || !Number.isFinite(age) || age < 0 ||
      age > SEARCH_PICTURE_STABLE_MS || epoch === undefined || !Number.isInteger(epoch) || epoch < 0 ||
      !Number.isFinite(nowMs) || nowMs < 0) {
      this.reset();
      return false;
    }
    const outputAtMs = nowMs - age;
    if (this.startedAtMs < 0 || this.decoderEpoch !== epoch || count < this.renderedFrames ||
      nowMs < this.observedAtMs || nowMs - this.observedAtMs > SEARCH_PICTURE_STABLE_MS ||
      outputAtMs < this.outputAtMs || outputAtMs - this.outputAtMs > SEARCH_PICTURE_STABLE_MS ||
      (count === this.renderedFrames && outputAtMs > this.outputAtMs)) {
      // A fresh observation starts at observation time, never at the timestamp
      // of a cached frame which predates this recovery attempt.
      this.startedAtMs = nowMs;
      this.observedAtMs = nowMs;
      this.outputAtMs = outputAtMs;
      this.renderedFrames = count;
      this.decoderEpoch = epoch;
      return false;
    }
    const advanced = count > this.renderedFrames && outputAtMs > this.outputAtMs;
    this.observedAtMs = nowMs;
    this.outputAtMs = outputAtMs;
    this.renderedFrames = count;
    return advanced && outputAtMs - this.startedAtMs >= SEARCH_PICTURE_STABLE_MS;
  }
}
