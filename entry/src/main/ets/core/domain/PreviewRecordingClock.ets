import { ConsoleSnapshot } from './AppController';
import { RecordingClock, RecordingClockSnapshot } from './RecordingClock';

// Owned and observed by the main page, so dismissing the child panel does not reset or stop the clock.
export class PreviewRecordingClock {
  private clock = new RecordingClock();
  private captureId: string = '';
  private flightGeneration: number = -1;
  private nativeStart?: number;
  private manualRequested: boolean = false;
  private manualSequence: number = 0;

  observe(state: ConsoleSnapshot, now: number): RecordingClockSnapshot {
    const generation = state.flight.generation;
    if (generation !== this.flightGeneration) {
      this.flightGeneration = generation; this.captureId = `${generation}:idle`;
      this.nativeStart = undefined; this.manualRequested = false;
    }
    const nativeStart = state.nativeTask.startedAtMs;
    if (nativeStart !== undefined && nativeStart !== this.nativeStart) {
      this.nativeStart = nativeStart; this.captureId = `${generation}:native:${nativeStart}`;
    }
    if (state.recordingRequested && !this.manualRequested) {
      this.captureId = `${generation}:manual:${++this.manualSequence}`;
    }
    this.manualRequested = state.recordingRequested;
    const telemetry = state.session.telemetry;
    const recording = (telemetry.cameraAgeMs ?? Infinity) <= 1000 ? telemetry.camera?.recordingCandidate : undefined;
    this.clock.update(now, recording, this.captureId);
    return this.clock.snapshot(now);
  }
}
