import { toHex } from '../protocol/Bytes';
import { decodeDumlFrame, DumlFrame } from '../protocol/DumlCodec';
import { SubjectObservation, SubjectSnapshot } from './SubjectObservation';

export interface FlightTelemetry {
  observedAtMs: number;
  modeRaw: number;
  lastCommandRaw: number;
  flagsRaw: number;
  motorsOn: boolean;
  airborne: boolean;
  relativeHeightCandidateMeters: number;
}

export interface TaskTelemetry {
  observedAtMs: number;
  phaseRaw: number;
  modeRaw: number;
  payloadHex: string;
}

export interface CameraTelemetry {
  observedAtMs: number;
  modeRaw: number;
  recordingCandidate: boolean;
  recordStateRaw: number;
  timeSynchronized: boolean;
}

export interface TelemetrySnapshot {
  subject?: SubjectSnapshot;
  flight?: FlightTelemetry;
  flightAgeMs?: number;
  task?: TaskTelemetry;
  taskAgeMs?: number;
  camera?: CameraTelemetry;
  cameraAgeMs?: number;
}

export class TelemetryStore {
  private subject: SubjectObservation = new SubjectObservation();

  clearSubject(): void { this.subject = new SubjectObservation(); }
  private flight?: FlightTelemetry;
  private task?: TaskTelemetry;
  private camera?: CameraTelemetry;

  observe(rawFrame: Uint8Array, observedAtMs: number): CameraTelemetry | undefined {
    let frame: DumlFrame;
    try {
      frame = decodeDumlFrame(rawFrame);
    } catch (_) {
      return undefined;
    }
    this.subject.observe(frame, observedAtMs);
    if (frame.sender === 3 && frame.commandSet === 3 && frame.commandId === 0x43 &&
      frame.payload.length >= 36) {
      const view = new DataView(frame.payload.buffer, frame.payload.byteOffset, frame.payload.byteLength);
      const flags = view.getUint32(32, true);
      this.flight = {
        observedAtMs: observedAtMs,
        modeRaw: frame.payload[30] & 0x7f,
        lastCommandRaw: frame.payload[31],
        flagsRaw: flags,
        motorsOn: (flags & 8) !== 0,
        airborne: (flags & 4) !== 0,
        relativeHeightCandidateMeters: view.getInt16(16, true) / 10
      };
    }
    if (frame.sender === 0x92 && frame.receiver === 2 && frame.flags === 0 &&
      frame.commandSet === 0x23 && frame.commandId === 0x14 && frame.payload.length === 5) {
      this.task = {
        observedAtMs: observedAtMs,
        phaseRaw: frame.payload[0],
        modeRaw: frame.payload[1],
        payloadHex: toHex(frame.payload)
      };
    }
    if (frame.sender === 1 && frame.receiver === 2 && frame.flags === 0 &&
      frame.commandSet === 2 && frame.commandId === 0x80 && frame.payload.length === 60) {
      const flags = new DataView(frame.payload.buffer, frame.payload.byteOffset,
        frame.payload.byteLength).getUint32(0, true);
      this.camera = {
        observedAtMs: observedAtMs,
        modeRaw: frame.payload[4],
        recordingCandidate: (flags & 0xc0) !== 0,
        recordStateRaw: (flags >>> 6) & 3,
        timeSynchronized: (flags & 4) !== 0
      };
      // Preserve this accepted event before a later report replaces latest state.
      return this.camera;
    }
    return undefined;
  }

  snapshot(nowMs: number = Date.now()): TelemetrySnapshot {
    const result: TelemetrySnapshot = { subject: this.subject.snapshot(nowMs) };
    if (this.flight !== undefined) {
      result.flight = this.flight;
      result.flightAgeMs = Math.max(0, nowMs - this.flight.observedAtMs);
    }
    if (this.task !== undefined) {
      result.task = this.task;
      result.taskAgeMs = Math.max(0, nowMs - this.task.observedAtMs);
    }
    if (this.camera !== undefined) {
      result.camera = this.camera;
      result.cameraAgeMs = Math.max(0, nowMs - this.camera.observedAtMs);
    }
    return result;
  }
}
