import { bytesEqual, concatBytes, toHex } from '../protocol/Bytes';
import { parseRadiusValue, radiusPayload, RADIUS_HASH_BYTES, validateCircleRadius } from '../protocol/CircleCodec';
import { DollyFraming, dollyParameterWrites, NativeTaskKind, nativeSelection, nativeStart,
  validateNativeRequest } from '../protocol/NativeTaskCodec';
import { CameraService } from './CameraService';
import { DroneSession } from './DroneSession';
import { FlightCommandService } from './FlightCommandService';
import { CancellationToken, ErrorLayer, failure, OperationResult, success } from './OperationResult';
import { CameraTelemetry, TelemetryObservation } from './TelemetryStore';
import { NativeTaskStopEvidence, NativeTaskStopReport } from './NativeTaskStopEvidence';
import { TaskStopNotice } from './TaskStopNotice';
import { ObstacleNoticeContext, ObstacleStopNotification } from './ObstacleStopNotification';

export interface NativeTaskConfig { radiusMeters: number; framing: DollyFraming; zoom: number; retreat: boolean; }
export interface NativeTaskSnapshot {
  kind: string; prepared: boolean; busy: boolean; startedAtMs?: number; executionObserved: boolean; executionSeen: boolean;
  recordingSeen: boolean;
  activeOrUnknown: boolean; config: NativeTaskConfig; startReply: string; stopReply: string;
  initialTargetTrackingAtMs?: number;
  stopReport?: NativeTaskStopReport;
  stopNotice?: TaskStopNotice;
}
export class NativeTaskService {
  private readonly session: DroneSession;
  private readonly flight: FlightCommandService;
  private readonly camera: CameraService;
  private kind: NativeTaskKind = 'circle';
  private config: NativeTaskConfig = { radiusMeters: 2, framing: '半身', zoom: 2, retreat: true };
  private prepared: boolean = false;
  private busy: boolean = false;
  private startedAt?: number;
  private startReply: string = '';
  private stopReply: string = '';
  private used: NativeTaskKind[] = [];
  private token?: CancellationToken;
  private generation: number = 0;
  private preparingHover: boolean = false;
  private lastProgress: string = '';
  private executionSeen: boolean = false;
  private recordingSeen: boolean = false;
  private initialTargetTrackingAtMs?: number;
  private hoverCompletionAtMs?: number;
  private stopEvidence: NativeTaskStopEvidence = new NativeTaskStopEvidence();
  private stopContextStartedAt?: number;
  private stopContextKind: string = '';
  private stopContextSession?: number;
  private stopContextFlight?: number;
  private stopContextInvalid: boolean = false;
  private stopNotification: ObstacleStopNotification = new ObstacleStopNotification();
  private stopNoticeSuppressed: boolean = false;
  constructor(session: DroneSession, flight: FlightCommandService, camera: CameraService) {
    this.session = session; this.flight = flight; this.camera = camera;
  }
  resetForAircraftSession(): void {
    this.resetAfterGroundedCycle(); this.used = [];
  }
  // Called only after FlightCommandService has verified fresh post-cycle grounded telemetry.
  resetAfterGroundedCycle(): void {
    this.resetTaskState();
    this.stopNotification.reset();
    this.stopNoticeSuppressed = false;
  }
  private resetTaskState(): void {
    this.cancel(true); this.generation++; this.startedAt = undefined;
    this.startReply = ''; this.stopReply = '';
    this.lastProgress = ''; this.executionSeen = false; this.recordingSeen = false;
    this.hoverCompletionAtMs = undefined;
    this.initialTargetTrackingAtMs = undefined;
    this.stopEvidence.reset(); this.stopContextStartedAt = undefined; this.stopContextInvalid = false;
    // A completed imaging task may still be returning. Its notification remains
    // observational across this handoff until return/velocity reports settle.
  }

  private ensureStopContext(): boolean {
    if (this.startedAt === undefined) return false;
    const session = this.session.snapshot().generation;
    const flight = this.flight.snapshot().generation;
    const newStart = this.stopContextStartedAt !== this.startedAt;
    if (newStart || this.stopContextKind !== this.kind) {
      this.stopEvidence.begin(this.kind, this.startedAt);
      this.stopContextStartedAt = this.startedAt; this.stopContextKind = this.kind;
      this.stopContextSession = session; this.stopContextFlight = flight; this.stopContextInvalid = false;
      if (newStart) {
        this.stopNotification.beginTask(); this.stopNoticeSuppressed = false;
      }
    } else if (this.stopContextSession !== session || this.stopContextFlight !== flight) {
      this.stopEvidence.reset(); this.stopContextInvalid = true;
      this.stopNotification.reset();
      this.stopContextSession = session; this.stopContextFlight = flight;
    }
    return !this.stopContextInvalid;
  }

  observeTelemetry(observation: TelemetryObservation): void {
    const context = this.noticeContext();
    if (this.ensureStopContext()) {
      if (observation.navigation !== undefined) this.stopEvidence.observeNavigation(observation.navigation);
      if (observation.task !== undefined) this.stopEvidence.observeTask(observation.task);
      if (observation.taskException !== undefined) this.stopEvidence.observeException(observation.taskException);
      if (!this.stopNoticeSuppressed) this.stopNotification.capture(this.stopEvidence.snapshot(), this.kind, context);
    }
    // Continue observing return telemetry even after completeForHover clears the
    // raw task context. No part of this observer issues an aircraft operation.
    this.stopNotification.observe(observation, context);
    this.cancelNoticeForOperatorMovement();
  }

  private noticeContext(): ObstacleNoticeContext {
    return { sessionGeneration: this.session.snapshot().generation ?? 0,
      flightGeneration: this.flight.snapshot().generation ?? 0 };
  }

  private cancelNoticeForOperatorMovement(): void {
    const flight = this.flight.snapshot();
    if (flight.movementActive || flight.landRequested || flight.landSent) {
      this.stopNoticeSuppressed = true; this.stopNotification.cancel();
    }
  }

  observeCameraTelemetry(camera: CameraTelemetry): void {
    this.stopNotification.observe({ camera: camera }, this.noticeContext());
    this.cancelNoticeForOperatorMovement();
  }

  canCompleteForHover(): OperationResult<boolean> {
    if (this.busy || this.startedAt === undefined || (!this.executionSeen && !this.recordingSeen && this.stopReply !== '00')) {
      return failure(ErrorLayer.TASK, 'NATIVE_COMPLETION_UNOBSERVED', '尚未确认上一轮实际执行或停止，不能重复拍摄');
    }
    const telemetry = this.session.snapshot().telemetry;
    const terminal = telemetry.task !== undefined &&
      ['0000000100', '0000000101', '0000000102', '0300000100', '0400000100'].includes(telemetry.task.payloadHex);
    const manualAfterCompletion = this.hoverCompletionAtMs !== undefined && telemetry.task !== undefined &&
      telemetry.task.modeRaw === 9 && [0, 5].includes(telemetry.task.phaseRaw) &&
      telemetry.task.observedAtMs >= this.hoverCompletionAtMs;
    if ((telemetry.taskAgeMs ?? Infinity) > 1000 || (telemetry.cameraAgeMs ?? Infinity) > 1000 ||
      telemetry.camera === undefined || telemetry.camera.recordingCandidate !== false ||
      telemetry.camera.observedAtMs < this.startedAt || telemetry.task === undefined ||
      telemetry.task.observedAtMs < this.startedAt ||
      (!terminal && !manualAfterCompletion)) {
      this.hoverCompletionAtMs = undefined;
      return failure(ErrorLayer.TASK, 'NATIVE_NOT_COMPLETED', '上一轮任务仍在执行或结束状态已过期');
    }
    if (terminal) this.hoverCompletionAtMs = telemetry.task.observedAtMs;
    return success(true);
  }
  completeForHover(): OperationResult<boolean> {
    const completed = this.canCompleteForHover();
    if (!completed.ok) return completed;
    const handoff = this.flight.releaseNativeTaskAfterHover(this.hoverCompletionAtMs);
    if (!handoff.ok) return handoff;
    this.resetTaskState();
    return success(true);
  }
  observeProgress(): string | undefined {
    if (this.startedAt === undefined) return undefined;
    const telemetry = this.session.snapshot().telemetry;
    const task = telemetry.task;
    if (task !== undefined) this.observeTelemetry({ task: task });
    const camera = telemetry.camera;
    const taskFresh = task !== undefined && (telemetry.taskAgeMs ?? Infinity) <= 1000 && task.observedAtMs >= this.startedAt;
    const cameraFresh = camera !== undefined && (telemetry.cameraAgeMs ?? Infinity) <= 1000 && camera.observedAtMs >= this.startedAt;
    const expected = this.kind === 'circle' ? '0505000100' : this.kind === 'follow' ? '050a000100' : '050d000100';
    if (taskFresh && task?.payloadHex === expected) this.executionSeen = true;
    if (cameraFresh && camera?.recordingCandidate === true) this.recordingSeen = true;
    const flight = this.flight.snapshot();
    const message = `原生${this.kind}状态：任务=${taskFresh ? task?.payloadHex : '未收到新鲜状态'}，` +
      `飞行模式=${(telemetry.flightAgeMs ?? Infinity) <= 1000 ? telemetry.flight?.modeRaw : '过期'}，` +
      `录像=${cameraFresh ? camera?.recordingCandidate : '未收到新鲜状态'}，` +
      `执行已观察=${this.executionSeen}，录像已观察=${this.recordingSeen}，` +
      `跟踪=${telemetry.subject?.tracking === true}，目标=${telemetry.subject?.overlay[0]?.id ?? '无'}，` +
      `降落中=${flight.landRequested === true || flight.landSent === true}，` +
      `任务状态线索=${JSON.stringify(this.stopEvidence.snapshot()) ?? '无'}`;
    if (message === this.lastProgress) return undefined;
    this.lastProgress = message;
    return message;
  }
  cancel(preserveStopNotice: boolean = false): void {
    this.token?.cancel(); this.prepared = false;
    if (!preserveStopNotice) {
      this.stopNoticeSuppressed = true; this.stopNotification.cancel();
    }
  }
  activeOrUnknown(): boolean {
    if (this.startedAt === undefined) return false;
    const telemetry = this.session.snapshot().telemetry; const task = telemetry.task;
    return !(task !== undefined && telemetry.taskAgeMs !== undefined && telemetry.taskAgeMs <= 1000 &&
      task.observedAtMs > this.startedAt &&
      (['0000000101', '0000000102', '0400000100', '0300000100'].includes(task.payloadHex) ||
        (task.payloadHex === '0000000100' && (this.executionSeen || this.recordingSeen || this.stopReply === '00'))));
  }
  snapshot(): NativeTaskSnapshot {
    const stopReport = this.ensureStopContext() ? this.stopEvidence.snapshot() : undefined;
    const telemetry = this.session.snapshot().telemetry; const task = telemetry.task;
    const execution = this.kind === 'circle' ? '0505000100' : this.kind === 'follow' ? '050a000100' : '050d000100';
    const context = this.noticeContext();
    if (!this.stopNoticeSuppressed) this.stopNotification.capture(stopReport, this.kind, context);
    this.cancelNoticeForOperatorMovement();
    const stopNotice = this.stopNotification.snapshot(telemetry, context);
    return { kind: this.kind, prepared: this.prepared, busy: this.busy, startedAtMs: this.startedAt, executionSeen: this.executionSeen,
      recordingSeen: this.recordingSeen,
      executionObserved: task !== undefined && telemetry.taskAgeMs !== undefined && telemetry.taskAgeMs <= 1000 &&
        this.startedAt !== undefined && task.observedAtMs >= this.startedAt && task.payloadHex === execution,
      activeOrUnknown: this.activeOrUnknown(),
      config: { radiusMeters: this.config.radiusMeters, framing: this.config.framing, zoom: this.config.zoom, retreat: this.config.retreat },
      initialTargetTrackingAtMs: this.initialTargetTrackingAtMs,
      stopReport: stopReport,
      stopNotice: stopNotice,
      startReply: this.startReply, stopReply: this.stopReply };
  }
  async prepareHover(kind: NativeTaskKind, config: NativeTaskConfig, external?: CancellationToken): Promise<OperationResult<boolean>> {
    return this.prepare(kind, config, external, true);
  }
  async prepare(kind: NativeTaskKind, config: NativeTaskConfig, external?: CancellationToken,
    fromHover: boolean = false): Promise<OperationResult<boolean>> {
    if (this.busy || this.activeOrUnknown()) return failure(ErrorLayer.TASK, 'NATIVE_BUSY', '上一原生任务尚未确认结束');
    if (kind === 'follow' && this.used.includes(kind)) return failure(ErrorLayer.TASK, 'NATIVE_CYCLE_USED', '本连接已启动过跟随任务，落地后重新连接');
    const token = new CancellationToken(this.generation); this.token = token; this.prepared = false; this.busy = true;
    this.kind = kind;
    this.preparingHover = fromHover;
    this.config = { radiusMeters: config.radiusMeters, framing: config.framing, zoom: config.zoom, retreat: config.retreat };
    try {
      validateCircleRadius(config.radiusMeters); dollyParameterWrites(config.framing, config.zoom, config.retreat);
      this.ensureReady(token, external); await this.flight.centerSticks(); this.ensureReady(token, external);
      if (kind === 'dolly') {
        const cleanup = await this.request(kind, 0x92, 0x23, 0x15, new Uint8Array(0), token, external);
        this.requireSuccess(cleanup, '旧任务清理未确认');
      }
      await this.write(kind, 0x17, nativeSelection(kind), token, external);
      if (kind === 'circle') {
        await this.write(kind, 0x92, radiusPayload(config.radiusMeters), token, external);
        const reply = await this.request(kind, 0x92, 3, 0xf8, RADIUS_HASH_BYTES, token, external);
        if (reply === undefined || Math.abs(parseRadiusValue(reply) - config.radiusMeters) > 0.00001) throw new Error('环绕半径读回不一致');
      }
      if (kind === 'dolly') {
        const writes = dollyParameterWrites(config.framing, config.zoom, config.retreat);
        for (let index = 0; index < writes.length; index++) await this.write(kind, 0x92, writes[index], token, external);
        this.ensureReady(token, external);
        const result = await this.camera.prepareVideoMode(token);
        if (!result.ok) throw new Error(result.error?.message ?? '相机录像模式未准备好');
      }
      this.ensureReady(token, external); this.prepared = true; return success(true);
    } catch (error) { return failure(ErrorLayer.TASK, 'NATIVE_PREPARE_FAILED', message(error)); }
    finally { this.preparingHover = false; this.busy = false; }
  }
  async start(confirmed: boolean, external?: CancellationToken, selectedTarget?: number): Promise<OperationResult<string>> {
    if (!confirmed || !this.prepared || this.busy || this.activeOrUnknown()) return failure(ErrorLayer.TASK, 'NATIVE_NOT_PREPARED', '需要准备任务并独立确认启动');
    const token = this.token;
    if (token === undefined) return failure(ErrorLayer.TASK, 'NATIVE_CANCELLED', '任务已取消');
    this.busy = true;
    try {
      this.ensureReady(token, external, selectedTarget);
      if (this.kind === 'dolly') this.ensureVideoMode();
      // The original selected-subject Circle trial starts directly from its live
      // mode-26 lock. Rewriting the mode here would risk replacing that target.
      if (selectedTarget !== undefined && this.kind !== 'circle') {
        const selection = nativeSelection(this.kind);
        validateNativeRequest(this.kind, 0x17, 3, 0xf9, selection);
        const reply = await this.session.requestNative(0x17, 3, 0xf9, selection, 2000, token);
        if (reply === undefined || !bytesEqual(reply, concatBytes(new Uint8Array([0]), selection))) {
          throw new Error('空中任务模式切换未收到匹配回显');
        }
        const settleUntil = Date.now() + 5000;
        while (Date.now() < settleUntil) {
          this.ensureReady(token, external, selectedTarget);
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
        }
        this.ensureReady(token, external, selectedTarget);
        if (this.kind === 'dolly') this.ensureVideoMode();
      }
      // Retain the actual final tracking evidence before startup can briefly change
      // the reporting channel. An ACK or the current clock is not target evidence.
      this.initialTargetTrackingAtMs = selectedTarget === undefined ? undefined :
        this.session.snapshot().telemetry.subject?.trackingAt;
      this.prepared = false; this.startedAt = Date.now(); this.used.push(this.kind);
      this.stopContextStartedAt = undefined; this.ensureStopContext();
      this.lastProgress = ''; this.executionSeen = false; this.recordingSeen = false;
      this.hoverCompletionAtMs = undefined;
      this.stopReply = '';
      // An unanswered start may already have taken off; keep the conservative flight lock.
      this.flight.markNativeTaskMayFly(this.startedAt);
      validateNativeRequest(this.kind, 0x92, 0x23, 0x13, nativeStart(this.kind));
      const reply = await this.session.requestNative(0x92, 0x23, 0x13, nativeStart(this.kind), 2000, token);
      this.startReply = reply === undefined ? 'no_reply' : toHex(reply);
      if (token.isCancelled() || external?.isCancelled()) throw new Error('启动等待已取消；请观察停止后的实际状态');
      this.requireSuccess(reply, '启动未获成功回复；任务仍可能已启动，请观察或停止');
      return success('启动请求已获回复；等待任务执行遥测');
    } catch (error) { return failure(ErrorLayer.TASK, 'NATIVE_START_UNCONFIRMED', message(error)); }
    finally { this.busy = false; }
  }
  async stop(timeoutMs: number = 400): Promise<OperationResult<string>> {
    if (this.ensureStopContext()) this.stopEvidence.markAppStopRequested(Date.now());
    this.cancel();
    await this.flight.centerSticks();
    try {
      const reply = await this.session.requestNative(0x92, 0x23, 0x15, new Uint8Array(0), timeoutMs);
      this.stopReply = reply === undefined ? 'no_reply' : toHex(reply);
      this.requireSuccess(reply, '停止任务未获成功回复，请观察实际状态');
      this.flight.markNativeStopConfirmed(Date.now()); return success('停止请求已获回复；需观察悬停/落地状态');
    } catch (error) { return failure(ErrorLayer.TASK, 'NATIVE_STOP_UNCONFIRMED', message(error)); }
  }
  private ensureReady(token: CancellationToken, external?: CancellationToken, selectedTarget?: number): void {
    if (token.isCancelled() || external?.isCancelled() || token.generation() !== this.generation) throw new Error('原生任务操作已取消');
    const flight = this.flight.snapshot();
    if (flight.landRequested || flight.landSent) throw new Error('本轮已请求降落，不能启动原生任务');
    if (!this.session.isActionLinkFresh()) throw new Error('设备、下行或视频状态不新鲜');
    const observed = this.session.snapshot().telemetry;
    const taskFresh = observed.task !== undefined && observed.taskAgeMs !== undefined && observed.taskAgeMs <= 1000;
    if (this.preparingHover) {
      if (!flight.takeoffAcknowledged || flight.nativeTaskMayFly || flight.movementActive ||
        (observed.flightAgeMs ?? Infinity) > 1000 || observed.flight?.modeRaw !== 6 ||
        !observed.flight.airborne || !observed.flight.motorsOn || observed.subject?.tracking === true ||
        !taskFresh || observed.task === undefined || !((observed.task.phaseRaw === 0 && observed.task.modeRaw === 0) ||
          (observed.task.modeRaw === 9 && [0, 5].includes(observed.task.phaseRaw))) ||
        (observed.cameraAgeMs ?? Infinity) > 1000 || observed.camera?.recordingCandidate !== false) {
        throw new Error('空中准备需要本轮普通起飞后的新鲜悬停、任务空闲及相机空闲状态');
      }
      return;
    }
    if (selectedTarget !== undefined) {
      const subject = observed.subject;
      const trackingAt = subject?.trackingAt;
      const trackingAge = Date.now() - (trackingAt ?? -Infinity);
      if (!['dolly', 'follow', 'circle'].includes(this.kind) || !flight.takeoffSent || !flight.takeoffAcknowledged ||
        flight.nativeTaskMayFly || flight.movementActive ||
        !taskFresh || observed.task?.phaseRaw !== 0 || observed.task?.modeRaw !== 0 ||
        (observed.flightAgeMs ?? Infinity) > 1000 || observed.flight?.modeRaw !== 26 ||
        !observed.flight.airborne || !observed.flight.motorsOn || subject?.tracking !== true ||
        subject.overlay.length !== 1 || subject.overlay[0].id !== selectedTarget ||
        !Number.isFinite(trackingAge) || trackingAge < 0 || trackingAge > 1000 ||
        (this.kind === 'circle' && ((observed.cameraAgeMs ?? Infinity) > 1000 ||
          observed.camera?.recordingCandidate !== false))) {
        throw new Error('空中任务需要新鲜的飞机跟踪框、普通起飞和空闲任务状态');
      }
      return;
    }
    const terminal = taskFresh && observed.task !== undefined && ['0400000100', '0300000100'].includes(observed.task.payloadHex);
    const ownManualHover = this.kind === 'circle' && flight.takeoffAcknowledged && !flight.nativeTaskMayFly &&
      observed.flight !== undefined && observed.flightAgeMs !== undefined && observed.flightAgeMs <= 1000 &&
      observed.flight.motorsOn && observed.flight.airborne && observed.flight.modeRaw === 6;
    // Native task reports may be absent in ordinary manual flight. The original Circle
    // path permits a fresh owned manual hover, including mode 9 photo/manual context.
    const manualContext = ownManualHover && (!taskFresh || (observed.task !== undefined &&
      (observed.task.modeRaw === 0 || observed.task.modeRaw === 9)));
    if (!(taskFresh && observed.task !== undefined && observed.task.phaseRaw === 0) && !terminal && !manualContext) {
      throw new Error(`原生任务状态不明或仍在执行，未切换任务模式（任务=${observed.task?.payloadHex ?? '无'}，年龄=${observed.taskAgeMs ?? -1}ms，飞行模式=${observed.flight?.modeRaw ?? -1}）`);
    }
    if (this.kind !== 'circle') {
      const telemetry = this.session.snapshot().telemetry;
      if (telemetry.flight === undefined || telemetry.flightAgeMs === undefined || telemetry.flightAgeMs > 1000 ||
        telemetry.flight.motorsOn || telemetry.flight.airborne) throw new Error('跟随和滑动变焦仅支持从地面启动');
      if (telemetry.task === undefined || telemetry.taskAgeMs === undefined || telemetry.taskAgeMs > 1000 ||
        telemetry.task.phaseRaw !== 0) throw new Error('尚无新鲜的原生任务空闲状态');
    }
  }
  private ensureVideoMode(): void {
    const telemetry = this.session.snapshot().telemetry; const camera = telemetry.camera;
    if (camera === undefined || telemetry.cameraAgeMs === undefined || telemetry.cameraAgeMs > 1000 ||
      camera.modeRaw !== 1 || !camera.timeSynchronized || camera.recordingCandidate) throw new Error('相机录像模式、校时或空闲状态已变化');
  }
  private async write(kind: NativeTaskKind, receiver: number, payload: Uint8Array,
    token: CancellationToken, external?: CancellationToken): Promise<void> {
    const reply = await this.request(kind, receiver, 3, 0xf9, payload, token, external);
    if (reply === undefined || !bytesEqual(reply, concatBytes(new Uint8Array([0]), payload))) throw new Error('原生任务参数没有完整匹配回显');
  }
  private async request(kind: NativeTaskKind, receiver: number, set: number, id: number,
    payload: Uint8Array, token: CancellationToken, external?: CancellationToken): Promise<Uint8Array | undefined> {
    this.ensureReady(token, external); validateNativeRequest(kind, receiver, set, id, payload);
    const reply = await this.session.requestNative(receiver, set, id, payload, 2000, token);
    this.ensureReady(token, external); return reply;
  }
  private requireSuccess(reply: Uint8Array | undefined, reason: string): void {
    if (reply === undefined || reply.length !== 1 || reply[0] !== 0) throw new Error(reason);
  }
}
function message(error: Object): string { return error instanceof Error ? error.message : String(error); }
