import { NavigationTelemetry, TaskExceptionTelemetry, TaskTelemetry } from './TelemetryStore';

export interface NativeTaskStopReport {
  startedAtMs: number;
  terminalAtMs: number;
  exceptionAtMs?: number;
  codeRaw?: number;
  payloadHex?: string;
  classification: 'unconfirmed' | 'obstacle';
  reasonKnown: boolean;
  diagnosticCode?: number;
  reasonNavAtMs?: number;
  reasonNavModeRaw?: number;
  reasonMultiQuickShotEnabled?: boolean;
  message: string;
  appStopRequested: boolean;
  settleUntilMs: number;
}

interface TaskExceptionEvidence extends TaskExceptionTelemetry {
  obstacleContext: boolean;
  reasonNavAtMs?: number;
  reasonNavModeRaw?: number;
  reasonMultiQuickShotEnabled?: boolean;
}

export class NativeTaskStopEvidence {
  private startedAtMs?: number;
  private executionAtMs?: number;
  private terminalAtMs?: number;
  private appStopAtMs?: number;
  private executionPayload?: string;
  private navigation?: NavigationTelemetry;
  private navigationMinimumAtMs?: number;
  private exceptionEvents: TaskExceptionEvidence[] = [];
  private seenExceptionKeys: string[] = [];

  begin(kind: string, startedAtMs: number): void {
    this.reset();
    if ((kind === 'dolly' || kind === 'circle') && validTime(startedAtMs, Date.now())) {
      this.startedAtMs = startedAtMs; this.navigationMinimumAtMs = startedAtMs;
      this.executionPayload = kind === 'circle' ? '0505000100' : '050d000100';
    }
  }

  reset(): void {
    this.startedAtMs = undefined; this.executionAtMs = undefined; this.terminalAtMs = undefined;
    this.appStopAtMs = undefined; this.exceptionEvents = []; this.seenExceptionKeys = [];
    this.executionPayload = undefined; this.navigation = undefined; this.navigationMinimumAtMs = undefined;
  }

  markAppStopRequested(atMs: number): void {
    if (!this.fromCurrentStart(atMs)) return;
    if (this.appStopAtMs === undefined || atMs < this.appStopAtMs) this.appStopAtMs = atMs;
  }

  observeNavigation(nav: NavigationTelemetry): void {
    if (!this.fromCurrentStart(nav.observedAtMs) || this.navigationMinimumAtMs === undefined ||
      nav.observedAtMs < this.navigationMinimumAtMs ||
      (this.navigation !== undefined && nav.observedAtMs < this.navigation.observedAtMs) ||
      !Number.isInteger(nav.modeRaw) || nav.modeRaw < 0 || nav.modeRaw > 255 ||
      typeof nav.multiQuickShotEnabled !== 'boolean' || typeof nav.navigationExecuting !== 'boolean' ||
      typeof nav.goHomeExecuting !== 'boolean' || !Number.isInteger(nav.goHomeStageRaw) ||
      nav.goHomeStageRaw < 0 || nav.goHomeStageRaw > 15) return;
    this.navigation = { observedAtMs: nav.observedAtMs, modeRaw: nav.modeRaw,
      navigationExecuting: nav.navigationExecuting, goHomeExecuting: nav.goHomeExecuting,
      goHomeStageRaw: nav.goHomeStageRaw, multiQuickShotEnabled: nav.multiQuickShotEnabled,
      payloadHex: nav.payloadHex };
  }

  observeTask(task: TaskTelemetry): void {
    if (!this.fromCurrentStart(task.observedAtMs) ||
      !/^[0-9a-f]{10}$/.test(task.payloadHex) ||
      parseInt(task.payloadHex.slice(0, 2), 16) !== task.phaseRaw ||
      parseInt(task.payloadHex.slice(2, 4), 16) !== task.modeRaw) return;
    if (task.payloadHex === this.executionPayload) {
      if (this.terminalAtMs !== undefined) {
        if (task.observedAtMs < this.terminalAtMs) return;
        // A transient ending followed by fresh execution is no longer stopped.
        // Discard that ending's exception episode before observing a later end.
        this.terminalAtMs = undefined; this.exceptionEvents = [];
        this.executionAtMs = task.observedAtMs;
        this.navigation = undefined; this.navigationMinimumAtMs = task.observedAtMs;
      } else if (this.executionAtMs === undefined) this.executionAtMs = task.observedAtMs;
      return;
    }
    if (this.terminalAtMs !== undefined || this.executionAtMs === undefined || task.observedAtMs < this.executionAtMs ||
      !['0000000100', '0000000101', '0000000102', '0300000100', '0400000100'].includes(task.payloadHex)) return;
    // Repeated idle/ending reports must not extend the exception association window.
    this.terminalAtMs = task.observedAtMs;
  }

  observeException(event: TaskExceptionTelemetry): void {
    if (!this.fromCurrentStart(event.observedAtMs) ||
      !/^000000000000[0-9a-f]{6}0[01]$/.test(event.payloadHex) ||
      !Number.isInteger(event.codeRaw) || event.codeRaw < 0 || event.codeRaw > 255 ||
      parseInt(event.payloadHex.slice(16, 18), 16) !== event.codeRaw ||
      !Number.isInteger(event.sequence) || event.sequence < 0 || event.sequence > 0xffff) return;
    // This per-start identity ring survives resumed execution. An old exception
    // retransmitted near a later ending must not become a fresh reason report.
    const identity = `${event.sequence}:${event.payloadHex}`;
    if (this.seenExceptionKeys.includes(identity)) return;
    this.seenExceptionKeys.push(identity);
    if (this.seenExceptionKeys.length > 32) this.seenExceptionKeys.shift();
    const nav = this.navigationForException(event.observedAtMs);
    // Freeze the official gate when this exception arrives. Later navigation or
    // execution pushes must never retroactively qualify an earlier raw 0B.
    const obstacleContext = event.codeRaw === 0x0b && this.executionAtMs !== undefined &&
      event.observedAtMs >= this.executionAtMs && nav !== undefined &&
      (nav.modeRaw === 8 || nav.multiQuickShotEnabled);
    this.exceptionEvents.push({ observedAtMs: event.observedAtMs, codeRaw: event.codeRaw,
      payloadHex: event.payloadHex, sequence: event.sequence, inAction: event.inAction, obstacleContext: obstacleContext,
      reasonNavAtMs: nav?.observedAtMs, reasonNavModeRaw: nav?.modeRaw,
      reasonMultiQuickShotEnabled: nav?.multiQuickShotEnabled });
    this.trimExceptions();
  }

  snapshot(nowMs: number = Date.now()): NativeTaskStopReport | undefined {
    const started = this.startedAtMs; const terminal = this.terminalAtMs;
    if (started === undefined || terminal === undefined || !validTime(nowMs, Date.now()) || nowMs < terminal) return undefined;
    let exception: TaskExceptionEvidence | undefined;
    let nonzero: TaskExceptionEvidence | undefined;
    let obstacle: TaskExceptionEvidence | undefined;
    for (const event of this.exceptionEvents) {
      if (!this.inTerminalWindow(event, nowMs)) continue;
      if (exception === undefined || event.observedAtMs >= exception.observedAtMs) exception = event;
      if (nonzero === undefined && event.codeRaw !== 0) nonzero = event;
      if (obstacle === undefined && event.obstacleContext) obstacle = event;
    }
    // QM_OBSTACLE_AVOID maps to diagnostic 800013 only under its captured NAV
    // gate. This identifies the imaging-task exit cause, not physical stopping.
    if (nonzero !== undefined) exception = nonzero;
    if (obstacle !== undefined) exception = obstacle;
    const appRequested = this.appStopAtMs !== undefined && this.appStopAtMs <= terminal;
    const knownObstacle = obstacle !== undefined && !appRequested;
    const message = knownObstacle ? '检测到障碍物，已触发避障' :
      appRequested ? '任务状态已变化，原因未确认；App 已请求停止' : '任务状态已变化，原因未确认';
    return { startedAtMs: started, terminalAtMs: terminal, exceptionAtMs: exception?.observedAtMs,
      codeRaw: exception?.codeRaw, payloadHex: exception?.payloadHex,
      classification: knownObstacle ? 'obstacle' : 'unconfirmed', reasonKnown: knownObstacle,
      diagnosticCode: knownObstacle ? 800013 : undefined, reasonNavAtMs: exception?.reasonNavAtMs,
      reasonNavModeRaw: exception?.reasonNavModeRaw,
      reasonMultiQuickShotEnabled: exception?.reasonMultiQuickShotEnabled, message: message,
      appStopRequested: appRequested, settleUntilMs: terminal + 500 };
  }

  private fromCurrentStart(atMs: number): boolean {
    return this.startedAtMs !== undefined && validTime(atMs, Date.now()) && atMs >= this.startedAtMs;
  }

  private navigationForException(atMs: number): NavigationTelemetry | undefined {
    const nav = this.navigation;
    if (nav === undefined || this.startedAtMs === undefined || nav.observedAtMs < this.startedAtMs ||
      nav.observedAtMs > atMs || atMs - nav.observedAtMs > 1000) return undefined;
    return nav;
  }

  private inTerminalWindow(event: TaskExceptionTelemetry, nowMs: number): boolean {
    return this.terminalAtMs !== undefined && this.executionAtMs !== undefined &&
      event.observedAtMs >= this.executionAtMs && event.observedAtMs <= nowMs &&
      Math.abs(event.observedAtMs - this.terminalAtMs) <= 500;
  }

  private trimExceptions(): void {
    if (this.exceptionEvents.length <= 8) return;
    let protectedIndex = this.exceptionEvents.findIndex((event: TaskExceptionEvidence): boolean =>
      event.obstacleContext && this.inTerminalWindow(event, Date.now()));
    if (protectedIndex < 0) protectedIndex = this.exceptionEvents.findIndex((event: TaskExceptionEvidence): boolean =>
      event.codeRaw !== 0 && this.inTerminalWindow(event, Date.now()));
    if (protectedIndex < 0) {
      for (let index = 0; index < this.exceptionEvents.length; index++) {
        if (!this.exceptionEvents[index].obstacleContext) continue;
        if (protectedIndex < 0 || this.exceptionEvents[index].observedAtMs >=
          this.exceptionEvents[protectedIndex].observedAtMs) protectedIndex = index;
      }
    }
    if (protectedIndex < 0) {
      // Before an ending report arrives, retain the newest nonzero event as well as
      // the recent nonzero reports rather than allowing repeated zeros to evict it.
      for (let index = 0; index < this.exceptionEvents.length; index++) {
        if (this.exceptionEvents[index].codeRaw === 0) continue;
        if (protectedIndex < 0 || this.exceptionEvents[index].observedAtMs >=
          this.exceptionEvents[protectedIndex].observedAtMs) protectedIndex = index;
      }
    }
    let discard = this.exceptionEvents.findIndex((event: TaskExceptionTelemetry, index: number): boolean =>
      index !== protectedIndex && event.codeRaw === 0);
    if (discard < 0) discard = protectedIndex === 0 ? 1 : 0;
    this.exceptionEvents.splice(discard, 1);
  }
}

function validTime(atMs: number, nowMs: number): boolean {
  return Number.isSafeInteger(atMs) && Number.isSafeInteger(nowMs) && atMs >= 0 && atMs <= nowMs;
}
