import { NativeTaskStopReport } from './NativeTaskStopEvidence';
import { CameraTelemetry, FlightTelemetry, NavigationTelemetry, TaskExceptionTelemetry,
  TaskTelemetry, TelemetryObservation, TelemetrySnapshot } from './TelemetryStore';
import { TaskStopNotice } from './TaskStopNotice';

export interface ObstacleNoticeContext {
  sessionGeneration: number;
  flightGeneration: number;
}

interface PendingObstacleNotice {
  id: string;
  terminalAtMs: number;
  exceptionAtMs: number;
  capturedAtMs: number;
  published: boolean;
}

// An observation-only owner. Releasing the native task does not release its
// pending notice; starting another task explicitly does. This class has no
// control, media or scheduling dependency and never delays an operation.
export class ObstacleStopNotification {
  private context?: ObstacleNoticeContext;
  private pending?: PendingObstacleNotice;
  private notice?: TaskStopNotice;
  private seenReportKeys: string[] = [];
  private stableSince?: number;
  private stableLastAt?: number;

  reset(): void {
    this.cancel();
    this.context = undefined;
    this.seenReportKeys = [];
  }

  beginTask(): void { this.cancel(); }

  cancel(): void {
    this.pending = undefined;
    this.notice = undefined;
    this.clearConfirmation();
  }

  capture(report: NativeTaskStopReport | undefined, kind: string, ctx: ObstacleNoticeContext): void {
    this.useContext(ctx);
    const now = Date.now();
    if (report === undefined || (kind !== 'dolly' && kind !== 'circle') ||
      report.classification !== 'obstacle' || report.reasonKnown !== true ||
      report.diagnosticCode !== 800013 || report.codeRaw !== 0x0b || report.appStopRequested !== false ||
      !validAt(report.startedAtMs, now) || !validAt(report.terminalAtMs, now) ||
      !validAt(report.exceptionAtMs, now) || !validAt(report.reasonNavAtMs, now) ||
      report.terminalAtMs < report.startedAtMs || report.exceptionAtMs! < report.startedAtMs ||
      Math.abs(report.exceptionAtMs! - report.terminalAtMs) > 500 ||
      report.reasonNavAtMs! < report.startedAtMs || report.reasonNavAtMs! > report.exceptionAtMs! ||
      report.exceptionAtMs! - report.reasonNavAtMs! > 1000 ||
      (report.reasonNavModeRaw !== 8 && report.reasonMultiQuickShotEnabled !== true)) return;
    const id = `${ctx.sessionGeneration}:${ctx.flightGeneration}:${kind}:${report.startedAtMs}:${report.terminalAtMs}:800013`;
    if (this.seenReportKeys.includes(id)) return;
    this.seenReportKeys.push(id);
    if (this.seenReportKeys.length > 32) this.seenReportKeys.shift();
    this.pending = { id: id, terminalAtMs: report.terminalAtMs, exceptionAtMs: report.exceptionAtMs!,
      capturedAtMs: now, published: false };
    this.notice = undefined;
    this.clearConfirmation();
  }

  observe(event: TelemetryObservation, ctx: ObstacleNoticeContext): void {
    this.useContext(ctx);
    const pending = this.pending;
    if (pending === undefined) return;
    const now = Date.now();
    const task = event.task;
    const exception = event.taskException;
    if ((task !== undefined && validAt(task.observedAtMs, now) &&
      task.observedAtMs >= pending.terminalAtMs && resumedTask(task)) ||
      (exception !== undefined && validAt(exception.observedAtMs, now) &&
      exception.observedAtMs >= pending.exceptionAtMs && exception.codeRaw === 1)) {
      this.cancel(); return;
    }
    if (task !== undefined && task.observedAtMs >= pending.terminalAtMs &&
      (!freshAfter(task.observedAtMs, pending.terminalAtMs, now) || !endedTask(task))) this.clearConfirmation();
    const camera = event.camera;
    if (camera !== undefined && camera.observedAtMs >= pending.terminalAtMs &&
      (!freshAfter(camera.observedAtMs, pending.terminalAtMs, now) || !idleCamera(camera))) this.clearConfirmation();
    const navigation = event.navigation;
    if (navigation !== undefined && navigation.observedAtMs >= pending.terminalAtMs &&
      (!freshAfter(navigation.observedAtMs, pending.terminalAtMs, now) || !idleNavigation(navigation))) this.clearConfirmation();
    const flight = event.flight;
    if (flight !== undefined && flight.observedAtMs >= pending.terminalAtMs &&
      (!freshAfter(flight.observedAtMs, pending.terminalAtMs, now) || !stationaryFlight(flight))) this.clearConfirmation();
    // 0A/39 normally stops pushing while the aircraft returns. Its last known
    // false is valid local evidence; it is not a one-second keepalive source.
    if (exception !== undefined && exception.observedAtMs >= pending.exceptionAtMs &&
      (!validAt(exception.observedAtMs, now) || exception.inAction !== false)) this.clearConfirmation();
  }

  snapshot(telemetry: TelemetrySnapshot, ctx: ObstacleNoticeContext, nowMs: number = Date.now()): TaskStopNotice | undefined {
    this.useContext(ctx);
    const pending = this.pending;
    if (pending === undefined) return this.visible(nowMs);
    const age = nowMs - pending.capturedAtMs;
    if (!Number.isSafeInteger(nowMs) || age < 0) { this.cancel(); return undefined; }
    if (age > 30000) {
      this.pending = undefined; this.clearConfirmation(); return this.visible(nowMs);
    }
    const task = telemetry.task;
    const exception = telemetry.taskException;
    if ((task !== undefined && validAt(task.observedAtMs, nowMs) &&
      task.observedAtMs >= pending.terminalAtMs && resumedTask(task)) ||
      (exception !== undefined && validAt(exception.observedAtMs, nowMs) &&
      exception.observedAtMs >= pending.exceptionAtMs && exception.codeRaw === 1)) {
      this.cancel(); return undefined;
    }
    if (pending.published) return this.visible(nowMs);
    const camera = telemetry.camera;
    const navigation = telemetry.navigation;
    const flight = telemetry.flight;
    if (task === undefined || camera === undefined || navigation === undefined || flight === undefined ||
      !freshAfter(task.observedAtMs, pending.terminalAtMs, nowMs) || !endedTask(task) ||
      !freshAfter(camera.observedAtMs, pending.terminalAtMs, nowMs) || !idleCamera(camera) ||
      !freshAfter(navigation.observedAtMs, pending.terminalAtMs, nowMs) || !idleNavigation(navigation) ||
      !freshAfter(flight.observedAtMs, pending.terminalAtMs, nowMs) || !stationaryFlight(flight) ||
      exception === undefined || !validAt(exception.observedAtMs, nowMs) ||
      exception.observedAtMs < pending.exceptionAtMs || exception.inAction !== false) {
      this.clearConfirmation(); return undefined;
    }
    // The slowest of these four streams must supply new observations. Cached
    // reports and elapsed UI time alone can never confirm 500ms of stability.
    const at = Math.min(task.observedAtMs, camera.observedAtMs, navigation.observedAtMs, flight.observedAtMs);
    if (this.stableSince === undefined || this.stableLastAt === undefined ||
      at < this.stableLastAt || at - this.stableLastAt > 1000) {
      // Other streams may predate the last transition to stationary. Never
      // backdate the beginning to their cached minimum timestamp.
      this.stableSince = nowMs;
    }
    this.stableLastAt = at;
    if (at - this.stableSince < 500) return undefined;
    pending.published = true;
    this.notice = { id: pending.id, message: '检测到障碍物，已触发避障', observedAtMs: nowMs };
    return this.visible(nowMs);
  }

  private useContext(ctx: ObstacleNoticeContext): void {
    if (this.context === undefined || this.context.sessionGeneration !== ctx.sessionGeneration ||
      this.context.flightGeneration !== ctx.flightGeneration) {
      this.reset();
      this.context = { sessionGeneration: ctx.sessionGeneration, flightGeneration: ctx.flightGeneration };
    }
  }

  private clearConfirmation(): void { this.stableSince = undefined; this.stableLastAt = undefined; }

  private visible(nowMs: number): TaskStopNotice | undefined {
    const notice = this.notice;
    if (notice === undefined) return undefined;
    const age = nowMs - notice.observedAtMs;
    if (!Number.isSafeInteger(nowMs) || age < 0 || age > 10000) { this.notice = undefined; return undefined; }
    return { id: notice.id, message: notice.message, observedAtMs: notice.observedAtMs };
  }
}

function validAt(atMs: number | undefined, nowMs: number): boolean {
  return atMs !== undefined && Number.isSafeInteger(atMs) && atMs >= 0 && atMs <= nowMs;
}

function freshAfter(atMs: number, terminalAtMs: number, nowMs: number): boolean {
  return validAt(atMs, nowMs) && atMs >= terminalAtMs && nowMs - atMs <= 1000;
}

function resumedTask(task: TaskTelemetry): boolean {
  return task.phaseRaw === 5 && task.modeRaw !== 0 && task.modeRaw !== 9;
}

function endedTask(task: TaskTelemetry): boolean {
  return ['0000000100', '0000000101', '0000000102', '0300000100', '0400000100'].includes(task.payloadHex) ||
    (task.modeRaw === 9 && (task.phaseRaw === 0 || task.phaseRaw === 5));
}

function idleCamera(camera: CameraTelemetry): boolean {
  return camera.recordingCandidate === false && camera.recordStateRaw === 0;
}

function idleNavigation(navigation: NavigationTelemetry): boolean {
  return navigation.goHomeExecuting === false && navigation.multiQuickShotEnabled === false &&
    ((navigation.modeRaw === 0 && navigation.navigationExecuting === false) ||
    (navigation.modeRaw === 1 && typeof navigation.navigationExecuting === 'boolean'));
}

function stationaryFlight(flight: FlightTelemetry): boolean {
  const grounded = flight.airborne === false && flight.motorsOn === false;
  const flyingHover = flight.airborne === true && flight.motorsOn === true && (flight.modeRaw === 6 || flight.modeRaw === 26);
  return (grounded || flyingHover) && nearZero(flight.velocityXMetersPerSecond) &&
    nearZero(flight.velocityYMetersPerSecond) && nearZero(flight.velocityZMetersPerSecond);
}

function nearZero(value: number): boolean {
  // The native SDK multiplies signed integer speed by 0.1; accept its rounding
  // of 3 * 0.1 without relaxing the physical threshold to the next wire value.
  return Number.isFinite(value) && Math.abs(value) <= 0.300001;
}
