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
  velocityXMetersPerSecond: number;
  velocityYMetersPerSecond: number;
  velocityZMetersPerSecond: number;
}

export interface NavigationTelemetry {
  observedAtMs: number;
  modeRaw: number;
  navigationExecuting: boolean;
  goHomeExecuting: boolean;
  goHomeStageRaw: number;
  multiQuickShotEnabled: boolean;
  payloadHex: string;
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

export interface TaskExceptionTelemetry {
  observedAtMs: number;
  codeRaw: number;
  payloadHex: string;
  sequence: number;
  inAction: boolean;
}

export interface TelemetryObservation {
  task?: TaskTelemetry;
  taskException?: TaskExceptionTelemetry;
  camera?: CameraTelemetry;
  navigation?: NavigationTelemetry;
  flight?: FlightTelemetry;
}

export interface TelemetrySnapshot {
  subject?: SubjectSnapshot;
  flight?: FlightTelemetry;
  flightAgeMs?: number;
  task?: TaskTelemetry;
  taskAgeMs?: number;
  camera?: CameraTelemetry;
  cameraAgeMs?: number;
  taskException?: TaskExceptionTelemetry;
  navigation?: NavigationTelemetry;
  navigationAgeMs?: number;
}

export class TelemetryStore {
  private subject: SubjectObservation = new SubjectObservation();

  clearSubject(): void { this.subject = new SubjectObservation(); }
  private flight?: FlightTelemetry;
  private task?: TaskTelemetry;
  private camera?: CameraTelemetry;
  private taskException?: TaskExceptionTelemetry;
  private navigation?: NavigationTelemetry;

  observe(rawFrame: Uint8Array, observedAtMs: number): CameraTelemetry | undefined {
    return this.observeEvent(rawFrame, observedAtMs).camera;
  }

  observeEvent(rawFrame: Uint8Array, observedAtMs: number): TelemetryObservation {
    const observed: TelemetryObservation = {};
    let frame: DumlFrame;
    try {
      frame = decodeDumlFrame(rawFrame);
    } catch (_) {
      return observed;
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
        relativeHeightCandidateMeters: view.getInt16(16, true) / 10,
        velocityXMetersPerSecond: view.getInt16(18, true) / 10,
        velocityYMetersPerSecond: view.getInt16(20, true) / 10,
        velocityZMetersPerSecond: view.getInt16(22, true) / 10
      };
      observed.flight = this.flight;
    }
    if (frame.sender === 0x92 && frame.receiver === 2 && frame.flags === 0 &&
      frame.commandSet === 0x23 && frame.commandId === 0x14 && frame.payload.length === 5) {
      this.task = {
        observedAtMs: observedAtMs,
        phaseRaw: frame.payload[0],
        modeRaw: frame.payload[1],
        payloadHex: toHex(frame.payload)
      };
      observed.task = this.task;
    }
    // Observed Neo 2 QuickShot exception layout. Keep unknown codes raw; byte 8
    // of 0A/5A is a different, packed navigation status and is not a reason.
    if (frame.sender === 0x92 && frame.receiver === 2 && frame.flags === 0 &&
      frame.commandSet === 0x0a && frame.commandId === 0x39 && frame.payload.length === 10 &&
      frame.payload.slice(0, 6).every((value: number): boolean => value === 0)) {
      this.taskException = { observedAtMs: observedAtMs, codeRaw: frame.payload[8],
        payloadHex: toHex(frame.payload), sequence: frame.sequence, inAction: frame.payload[9] !== 0 };
      observed.taskException = this.taskException;
    }
    // Current observed Neo 2 version/layout. MultiQuickShotEnabled is an enable
    // flag, not proof that a QuickShot action or return movement is executing.
    if (frame.sender === 0x92 && frame.receiver === 2 && frame.flags === 0 &&
      frame.commandSet === 0x0a && frame.commandId === 0x5a && frame.payload.length === 19 &&
      frame.payload[0] === 0xff && frame.payload[1] === 2 && frame.payload[2] === 0 && frame.payload[3] === 0) {
      this.navigation = { observedAtMs: observedAtMs, modeRaw: (frame.payload[5] >> 1) & 15,
        navigationExecuting: (frame.payload[5] & 1) !== 0,
        goHomeExecuting: (frame.payload[8] & 1) !== 0, goHomeStageRaw: frame.payload[8] >> 4,
        multiQuickShotEnabled: (frame.payload[13] & 1) !== 0, payloadHex: toHex(frame.payload) };
      observed.navigation = this.navigation;
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
      observed.camera = this.camera;
    }
    return observed;
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
    if (this.taskException !== undefined) result.taskException = this.taskException;
    if (this.navigation !== undefined) {
      result.navigation = this.navigation;
      result.navigationAgeMs = Math.max(0, nowMs - this.navigation.observedAtMs);
    }
    return result;
  }
}
