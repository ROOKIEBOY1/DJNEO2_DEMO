import { bytesEqual, concatBytes, toHex } from '../protocol/Bytes';
import { parseRadiusValue, radiusPayload, RADIUS_HASH_BYTES, validateCircleRadius } from '../protocol/CircleCodec';
import { DollyFraming, dollyParameterWrites, NativeTaskKind, nativeSelection, nativeStart,
  validateNativeRequest } from '../protocol/NativeTaskCodec';
import { CameraService } from './CameraService';
import { DroneSession } from './DroneSession';
import { FlightCommandService } from './FlightCommandService';
import { CancellationToken, ErrorLayer, failure, OperationResult, success } from './OperationResult';

export interface NativeTaskConfig { radiusMeters: number; framing: DollyFraming; zoom: number; retreat: boolean; }
export interface NativeTaskSnapshot {
  kind: string; prepared: boolean; busy: boolean; startedAtMs?: number; executionObserved: boolean;
  activeOrUnknown: boolean; config: NativeTaskConfig; startReply: string; stopReply: string;
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
  constructor(session: DroneSession, flight: FlightCommandService, camera: CameraService) {
    this.session = session; this.flight = flight; this.camera = camera;
  }
  resetForAircraftSession(): void {
    this.cancel(); this.generation++; this.startedAt = undefined;
    this.startReply = ''; this.stopReply = ''; this.used = [];
  }
  cancel(): void { this.token?.cancel(); this.prepared = false; }
  activeOrUnknown(): boolean {
    if (this.startedAt === undefined) return false;
    const telemetry = this.session.snapshot().telemetry; const task = telemetry.task;
    return !(task !== undefined && telemetry.taskAgeMs !== undefined && telemetry.taskAgeMs <= 1000 &&
      task.observedAtMs > this.startedAt && ['0000000101', '0000000102', '0400000100', '0300000100'].includes(task.payloadHex));
  }
  snapshot(): NativeTaskSnapshot {
    const telemetry = this.session.snapshot().telemetry; const task = telemetry.task;
    const execution = this.kind === 'circle' ? '0505000100' : this.kind === 'follow' ? '050a000100' : '050d000100';
    return { kind: this.kind, prepared: this.prepared, busy: this.busy, startedAtMs: this.startedAt,
      executionObserved: task !== undefined && telemetry.taskAgeMs !== undefined && telemetry.taskAgeMs <= 1000 &&
        this.startedAt !== undefined && task.observedAtMs >= this.startedAt && task.payloadHex === execution,
      activeOrUnknown: this.activeOrUnknown(),
      config: { radiusMeters: this.config.radiusMeters, framing: this.config.framing, zoom: this.config.zoom, retreat: this.config.retreat },
      startReply: this.startReply, stopReply: this.stopReply };
  }
  async prepare(kind: NativeTaskKind, config: NativeTaskConfig, external?: CancellationToken): Promise<OperationResult<boolean>> {
    if (this.busy || this.activeOrUnknown()) return failure(ErrorLayer.TASK, 'NATIVE_BUSY', '上一原生任务尚未确认结束');
    if (kind !== 'circle' && this.used.includes(kind)) return failure(ErrorLayer.TASK, 'NATIVE_CYCLE_USED', '本连接已启动过此任务，落地后重新连接');
    const token = new CancellationToken(this.generation); this.token = token; this.prepared = false; this.busy = true;
    this.kind = kind;
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
    finally { this.busy = false; }
  }
  async start(confirmed: boolean, external?: CancellationToken): Promise<OperationResult<string>> {
    if (!confirmed || !this.prepared || this.busy || this.activeOrUnknown()) return failure(ErrorLayer.TASK, 'NATIVE_NOT_PREPARED', '需要准备任务并独立确认启动');
    const token = this.token;
    if (token === undefined) return failure(ErrorLayer.TASK, 'NATIVE_CANCELLED', '任务已取消');
    this.busy = true;
    try {
      this.ensureReady(token, external);
      if (this.kind === 'dolly') this.ensureVideoMode();
      this.prepared = false; this.startedAt = Date.now(); this.used.push(this.kind);
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
    this.cancel();
    await this.flight.centerSticks();
    try {
      const reply = await this.session.requestNative(0x92, 0x23, 0x15, new Uint8Array(0), timeoutMs);
      this.stopReply = reply === undefined ? 'no_reply' : toHex(reply);
      this.requireSuccess(reply, '停止任务未获成功回复，请观察实际状态');
      this.flight.markNativeStopConfirmed(Date.now()); return success('停止请求已获回复；需观察悬停/落地状态');
    } catch (error) { return failure(ErrorLayer.TASK, 'NATIVE_STOP_UNCONFIRMED', message(error)); }
  }
  private ensureReady(token: CancellationToken, external?: CancellationToken): void {
    if (token.isCancelled() || external?.isCancelled() || token.generation() !== this.generation) throw new Error('原生任务操作已取消');
    const flight = this.flight.snapshot();
    if (flight.landRequested || flight.landSent) throw new Error('本轮已请求降落，不能启动原生任务');
    if (!this.session.isActionLinkFresh()) throw new Error('设备、下行或视频状态不新鲜');
    const observed = this.session.snapshot().telemetry;
    const taskFresh = observed.task !== undefined && observed.taskAgeMs !== undefined && observed.taskAgeMs <= 1000;
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
