export interface RecordingClockSnapshot {
  label: string;
  recording: boolean;
}

// Counts only intervals confirmed as recording, across all clips of one capture.
export class RecordingClock {
  private captureId?: string;
  private elapsedMs: number = 0;
  private recordingSince?: number;

  update(nowMs: number, recording: boolean | undefined, captureId: string): void {
    if (captureId !== this.captureId) {
      this.captureId = captureId;
      this.elapsedMs = 0;
      this.recordingSince = undefined;
    }
    if (recording === true) {
      if (this.recordingSince === undefined) this.recordingSince = nowMs;
    } else if (this.recordingSince !== undefined) {
      this.elapsedMs += Math.max(0, nowMs - this.recordingSince);
      this.recordingSince = undefined;
    }
  }

  snapshot(nowMs: number): RecordingClockSnapshot {
    const currentMs = this.recordingSince === undefined ? 0 : Math.max(0, nowMs - this.recordingSince);
    const seconds = Math.floor((this.elapsedMs + currentMs) / 1000);
    const label = `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}`;
    return { label: label, recording: this.recordingSince !== undefined };
  }
}
