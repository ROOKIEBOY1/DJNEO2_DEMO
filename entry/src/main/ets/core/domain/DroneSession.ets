import { hilog } from '@kit.PerformanceAnalysisKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { allDumlMessages, buildFlyTunnel, buildTunnelCommand, buildTunneledRequest,
  findCommandReply } from '../protocol/CommandCodec';
import { concatBytes, toHex } from '../protocol/Bytes';
import { decodeDumlFrame, encodeDumlFrame } from '../protocol/DumlCodec';
import { buildHandshake, isMatchingHandshakeReply, newAlignedSeed } from '../protocol/HandshakeCodec';
import { OuterPacket, parseOuterPacket } from '../protocol/OuterCodec';
import { axesForMovement, buildStickPayload, INITIAL_PAYLOAD, StickAxes } from '../protocol/StickCodec';
import { VideoAssembler, VideoAssemblerSnapshot } from '../media/VideoAssembler';
import { DroneUdpChannel, DroneWifiSelection } from '../platform/DroneUdpChannel';
import { CancellationToken, ErrorLayer, failure, OperationResult, success } from './OperationResult';
import { TelemetrySnapshot, TelemetryStore } from './TelemetryStore';
import { RegistrationExchange, RegistrationSnapshot } from '../transport/RegistrationExchange';
import { ReliableTransport, ReliableTransportSnapshot } from '../transport/ReliableTransport';
import { resequenceTunnels, RoutingSequenceSnapshot, RoutingSequenceStore } from '../transport/RoutingSequenceStore';
import { AircraftProfileRuntime } from '../profile/AircraftProfileStore';
import { buildVideoKeyframeRequest } from '../protocol/VideoKeyframeCodec';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'NeoSession';
// Python FlightController.connect() default prepare_seconds: the aircraft expects the
// short 01/0a initial frame phase for this long after the handshake reply, before full sticks.
const INITIAL_STICK_PHASE_MS: number = 2000;

export enum SessionPhase {
  DISCONNECTED = 'disconnected',
  SELECTING_NETWORK = 'selecting_network',
  HANDSHAKING = 'handshaking',
  REGISTERING = 'registering',
  READY = 'ready',
  CLOSING = 'closing',
  FAILED = 'failed'
}

interface PendingCommand {
  commandSet: number;
  commandId: number;
  sender: number;
  resolve: (payload?: Uint8Array) => void;
  timer: number;
}

export interface VideoKeyframeClock {
  nowMs(): number;
  schedule(callback: () => void, delayMs: number): number;
  cancel(timer: number): void;
}

interface VideoKeyframePulse {
  generation: number;
  session: number;
  transport: ReliableTransport;
  channel: DroneUdpChannel;
  resetTimer?: number;
  cancelSends: (() => void)[];
  trueDone: boolean;
  resetDone: boolean;
}

export interface DroneSessionSnapshot {
  generation: number;
  phase: SessionPhase;
  sessionHex: string;
  networkInterface: string;
  localAddress: string;
  deviceVerified: boolean;
  receivedPackets: number;
  handshakeAttempt: number;
  receivedDatagrams: number;
  sentDatagrams: number;
  lastUdpPeer: string;
  downlinkAgeMs?: number;
  controlDownlinkAgeMs?: number;
  videoAgeMs?: number;
  lastError: string;
  transport?: ReliableTransportSnapshot;
  registration?: RegistrationSnapshot;
  routing?: RoutingSequenceSnapshot;
  video: VideoAssemblerSnapshot;
  telemetry: TelemetrySnapshot;
}

export type SessionListener = (snapshot: DroneSessionSnapshot) => void;
export type VideoFrameListener = (frame: Uint8Array) => void;
export type Channel3Handler = (packet: Uint8Array) => void;

export class DroneSession {
  private readonly channel: DroneUdpChannel = new DroneUdpChannel();
  private routing?: RoutingSequenceStore;
  private telemetry: TelemetryStore = new TelemetryStore();
  private videoAssembler: VideoAssembler = new VideoAssembler();
  private readonly pending: Map<number, PendingCommand> = new Map();
  private phaseValue: SessionPhase = SessionPhase.DISCONNECTED;
  private selection?: DroneWifiSelection;
  private transport?: ReliableTransport;
  private registration?: RegistrationExchange;
  private session: number = 0;
  private videoSeed: number = 0;
  private innerSequence: number = 0;
  private outerSequence: number = 0;
  private stickCounter: number = 0;
  private axes: StickAxes = { roll: 1024, pitch: 1024, throttle: 1024, yaw: 1024 };
  private tickTimer?: number;
  private emitTimer?: number;
  private lastEmitAt: number = 0;
  private ticking: boolean = false;
  private handshakeMatched: boolean = false;
  private shortPhaseUntil: number = 0;
  private channel1HexLogged: number = 0;
  private queryReplyHexLogged: number = 0;
  private reliableSendHexLogged: number = 0;
  private deviceVerified: boolean = false;
  private receivedPackets: number = 0;
  private handshakeAttemptValue: number = 0;
  private lastReceivedAt?: number;
  private lastControlReceivedAt?: number;
  private lastVideoAt?: number;
  private lastError: string = '';
  private listener?: SessionListener;
  private videoListener?: VideoFrameListener;
  private channel3Handler?: Channel3Handler;
  private profileId: string = '';
  private generation: number = 0;
  private packetParseFailures: number = 0;
  private sessionMismatches: number = 0;
  private replyDiagnosticsLogged: number = 0;
  private readonly keyframeClock: VideoKeyframeClock;
  private keyframePulse?: VideoKeyframePulse;
  private keyframeGeneration?: number;
  private keyframeAttemptAtMs?: number;

  constructor(keyframeClock: VideoKeyframeClock = videoKeyframeClock()) {
    this.keyframeClock = keyframeClock;
  }

  setListener(listener?: SessionListener): void {
    this.listener = listener;
  }

  setVideoFrameListener(listener?: VideoFrameListener): void {
    this.videoListener = listener;
  }

  setChannel3Handler(handler?: Channel3Handler): void {
    this.channel3Handler = handler;
  }

  sessionId(): number {
    return this.session;
  }

  networkSelection(): DroneWifiSelection | undefined {
    return this.selection;
  }

  nextChannel3Sequence(): number {
    const transport = this.transport;
    if (transport === undefined) {
      throw new Error('Reliable transport is unavailable');
    }
    return (transport.downlinkAcknowledgement() + 8) & 0xffff;
  }

  async connect(profile: AircraftProfileRuntime,
    selection: DroneWifiSelection): Promise<OperationResult<DroneSessionSnapshot>> {
    if (this.phaseValue !== SessionPhase.DISCONNECTED && this.phaseValue !== SessionPhase.FAILED) {
      return failure(ErrorLayer.NETWORK, 'SESSION_ACTIVE', 'A session is already active');
    }
    let connectionGeneration = this.generation;
    const cancelled = (): OperationResult<DroneSessionSnapshot> =>
      failure(ErrorLayer.NETWORK, 'CONNECT_CANCELLED', '连接过程中会话已变化或断开，请重新连接');
    try {
      // A failed session still owns its socket and routing reservation. Release
      // them before replacing the store, otherwise its process-wide lock leaks.
      if (this.phaseValue === SessionPhase.FAILED) {
        this.phaseValue = SessionPhase.CLOSING;
        this.emit();
        const cleanupGeneration = this.generation + 1;
        connectionGeneration = cleanupGeneration;
        await this.cleanup();
        if (this.generation !== cleanupGeneration || this.phaseValue !== SessionPhase.CLOSING) {
          return cancelled();
        }
      }
      this.phaseValue = SessionPhase.SELECTING_NETWORK;
      this.emit();
      this.selection = selection;
      this.profileId = profile.id;
      this.generation++;
      const generation = this.generation;
      connectionGeneration = generation;
      const requireCurrentHandshake = (): void => {
        if (generation !== this.generation || this.phaseValue !== SessionPhase.HANDSHAKING) {
          throw new Error(this.lastError || '连接过程中会话已变化或断开');
        }
      };
      this.routing = new RoutingSequenceStore(profile.directory, profile.registration.routingIdentity);
      this.routing.open();
      this.telemetry = new TelemetryStore();
      this.videoAssembler = new VideoAssembler();
      this.receivedPackets = 0;
      this.handshakeAttemptValue = 0;
      this.lastReceivedAt = undefined;
      this.lastControlReceivedAt = undefined;
      this.lastVideoAt = undefined;
      this.deviceVerified = false;
      this.lastError = '';
      this.session = Math.floor(Math.random() * 0xffff) + 1;
      this.videoSeed = newAlignedSeed(Math.random());
      this.innerSequence = Math.floor(Math.random() * 0x10000);
      this.outerSequence = Math.floor(Math.random() * 0x10000);
      this.stickCounter = Math.floor(Math.random() * 0x1000000);
      this.handshakeMatched = false;
      this.shortPhaseUntil = 0;
      this.channel1HexLogged = 0;
      this.queryReplyHexLogged = 0;
      this.reliableSendHexLogged = 0;
      this.packetParseFailures = 0;
      this.sessionMismatches = 0;
      this.replyDiagnosticsLogged = 0;
      this.phaseValue = SessionPhase.HANDSHAKING;
      this.emit();
      const packetHandler = (packet: Uint8Array, receivedAtMs: number): void => {
        if (generation !== this.generation || profile.id !== this.profileId) return;
        const handshakeWasMatched = this.handshakeMatched;
        this.onPacket(packet, receivedAtMs);
        if (!handshakeWasMatched && this.handshakeMatched) {
          // The initial video/registration burst can arrive before connect()
          // resumes. Preserve its ACK cursor from the very next callback.
          this.transport = new ReliableTransport(this.session, this.videoSeed);
          this.registration = new RegistrationExchange(receivedAtMs, profile.registration);
        }
      };
      const errorHandler = (message: string): void => {
        if (generation === this.generation && profile.id === this.profileId) this.fail(message);
      };
      await this.channel.open(this.selection, packetHandler, errorHandler);
      requireCurrentHandshake();
      const request = buildHandshake(this.session, this.videoSeed);
      for (let attempt = 0; attempt < 60 && !this.handshakeMatched; attempt++) {
        this.handshakeAttemptValue = attempt + 1;
        this.emit();
        await this.channel.send(request);
        requireCurrentHandshake();
        // The aircraft associates its reply with the original UDP return port.
        // Match Python FlightController.connect(): keep one socket for all retries,
        // and start the tick loop as soon as the matching reply arrives.
        const retryDeadline = Date.now() + 550;
        while (Date.now() < retryDeadline && !this.handshakeMatched) {
          await delay(50);
          requireCurrentHandshake();
        }
      }
      if (!this.handshakeMatched) {
        throw new Error('No matching 15-byte aircraft handshake reply');
      }
      this.phaseValue = SessionPhase.REGISTERING;
      this.tickTimer = setInterval(() => {
        if (generation !== this.generation) return;
        this.tick().catch((error: Error) => {
          if (generation === this.generation) this.fail(error.message);
        });
      }, 60);
      this.emit();
      return success(this.snapshot());
    } catch (error) {
      if (connectionGeneration !== this.generation) return cancelled();
      const message = errorMessage(error);
      this.lastError = message;
      this.phaseValue = SessionPhase.CLOSING;
      const cleanupGeneration = this.generation + 1;
      await this.cleanup();
      if (this.generation !== cleanupGeneration) return cancelled();
      this.phaseValue = SessionPhase.DISCONNECTED;
      this.emit();
      return failure(ErrorLayer.NETWORK, 'CONNECT_FAILED', message);
    }
  }

  async initialize(timeoutMs: number = 8000,
    previewReady?: () => boolean): Promise<OperationResult<DroneSessionSnapshot>> {
    if (timeoutMs <= 0 || timeoutMs > 15000 || this.transport === undefined ||
      (this.phaseValue !== SessionPhase.REGISTERING && this.phaseValue !== SessionPhase.READY)) {
      return failure(ErrorLayer.HANDSHAKE_REGISTRATION, 'INVALID_INITIALIZATION',
        'Initialization requires a reliable connected session and a bounded timeout');
    }
    const generation = this.generation;
    const session = this.session;
    const transport = this.transport;
    const current = (): boolean => generation === this.generation && session === this.session &&
      transport === this.transport && this.phaseValue === SessionPhase.REGISTERING;
    const cancelled = (): OperationResult<DroneSessionSnapshot> =>
      failure(ErrorLayer.HANDSHAKE_REGISTRATION, 'INITIALIZATION_CANCELLED',
        '连接准备过程中会话已变化或断开，请重新连接');
    this.phaseValue = SessionPhase.REGISTERING;
    this.deviceVerified = false;
    this.emit();
    const deadline = Date.now() + timeoutMs;
    try {
      // Python connect() blocks for prepare_seconds before the caller may initialize,
      // so the aircraft always sees the full short initial frame phase before queries.
      while (current() && Date.now() < deadline &&
        (this.lastControlReceivedAt === undefined || Date.now() - this.lastControlReceivedAt > 1000 ||
          Date.now() < this.shortPhaseUntil)) {
        await delay(Math.min(50, Math.max(1, deadline - Date.now())));
      }
      if (!current()) return cancelled();
      if (Date.now() < deadline) {
        await this.probeStartupQueries(Math.min(500, Math.max(1, deadline - Date.now())));
      }
      if (!current()) return cancelled();
      while (Date.now() < deadline) {
        if (!current()) return cancelled();
        if (!this.deviceVerified && this.lastControlReceivedAt !== undefined &&
          Date.now() - this.lastControlReceivedAt <= 1000) {
          const remaining = Math.max(1, deadline - Date.now());
          const verified = await this.queryDevice(Math.min(1000, remaining));
          if (!current()) return cancelled();
          this.deviceVerified = verified;
        }
        if (!current()) return cancelled();
        if (Date.now() < deadline && this.startupMissing().length === 0 &&
          (previewReady === undefined || previewReady())) {
          this.phaseValue = SessionPhase.READY;
          this.lastError = '';
          this.emit();
          return success(this.snapshot());
        }
        await delay(Math.min(50, Math.max(1, deadline - Date.now())));
      }
      if (!current()) return cancelled();
      const missing = this.startupMissing();
      if (previewReady !== undefined && !previewReady()) missing.push('实时画面');
      if (missing.length === 0) missing.push('设备就绪确认');
      this.lastError = `连接准备超时：仍在等待${missing.join('、')}`;
      this.emit();
      return failure(ErrorLayer.HANDSHAKE_REGISTRATION, 'INITIALIZATION_TIMEOUT',
        this.lastError);
    } catch (error) {
      if (!current()) return cancelled();
      this.lastError = errorMessage(error);
      this.emit();
      return failure(ErrorLayer.HANDSHAKE_REGISTRATION, 'INITIALIZATION_FAILED', this.lastError);
    }
  }

  async disconnect(): Promise<OperationResult<boolean>> {
    this.phaseValue = SessionPhase.CLOSING;
    this.emit();
    const cleanupGeneration = this.generation + 1;
    await this.cleanup();
    if (this.generation === cleanupGeneration) {
      this.phaseValue = SessionPhase.DISCONNECTED;
      this.emit();
    }
    return success(true);
  }

  snapshot(): DroneSessionSnapshot {
    const now = Date.now();
    return {
      generation: this.generation,
      phase: this.phaseValue,
      sessionHex: this.session === 0 ? '--' : `0x${this.session.toString(16).padStart(4, '0')}`,
      networkInterface: this.selection?.interfaceName ?? '--',
      localAddress: this.selection?.localAddress ?? '--',
      deviceVerified: this.deviceVerified,
      receivedPackets: this.receivedPackets,
      handshakeAttempt: this.handshakeAttemptValue,
      receivedDatagrams: this.channel.receivedCount(),
      sentDatagrams: this.channel.sentCount(),
      lastUdpPeer: this.channel.lastPeer(),
      downlinkAgeMs: this.lastReceivedAt === undefined ? undefined : Math.max(0, now - this.lastReceivedAt),
      controlDownlinkAgeMs: this.lastControlReceivedAt === undefined ? undefined :
        Math.max(0, now - this.lastControlReceivedAt),
      videoAgeMs: this.lastVideoAt === undefined ? undefined : Math.max(0, now - this.lastVideoAt),
      lastError: this.lastError,
      transport: this.transport?.snapshot(),
      registration: this.registration?.snapshot(),
      routing: this.routing?.snapshot(),
      video: this.videoAssembler.snapshot(),
      telemetry: this.telemetry.snapshot(now)
    };
  }

  isActionLinkFresh(): boolean {
    const snapshot = this.snapshot();
    return this.isReliableLinkFresh() &&
      snapshot.videoAgeMs !== undefined && snapshot.videoAgeMs <= 1000;
  }

  clearSubjectObservation(): void { this.telemetry.clearSubject(); }

  isReliableLinkFresh(): boolean {
    const snapshot = this.snapshot();
    return snapshot.phase === SessionPhase.READY && snapshot.deviceVerified &&
      snapshot.controlDownlinkAgeMs !== undefined && snapshot.controlDownlinkAgeMs <= 1000;
  }

  isStartupReady(): boolean {
    return this.phaseValue === SessionPhase.READY && this.startupMissing().length === 0;
  }

  private startupMissing(): string[] {
    const now = Date.now();
    const telemetry = this.telemetry.snapshot(now);
    const missing: string[] = [];
    if (!this.deviceVerified) missing.push('设备身份确认');
    if (this.lastControlReceivedAt === undefined || now - this.lastControlReceivedAt > 1000) {
      missing.push('控制链路');
    }
    if (this.lastVideoAt === undefined || now - this.lastVideoAt > 1000) missing.push('图传数据');
    if (telemetry.flight === undefined || (telemetry.flightAgeMs ?? Infinity) > 1000) missing.push('飞行状态');
    if (telemetry.task === undefined || (telemetry.taskAgeMs ?? Infinity) > 1000) missing.push('任务状态');
    if (telemetry.camera === undefined || (telemetry.cameraAgeMs ?? Infinity) > 1000) missing.push('相机状态');
    return missing;
  }

  async refreshReliableLink(timeoutMs: number = 1200): Promise<boolean> {
    if (this.isReliableLinkFresh()) {
      return true;
    }
    if (this.phaseValue !== SessionPhase.READY || !this.deviceVerified || this.transport === undefined ||
      this.selection === undefined || timeoutMs <= 0 || timeoutMs > 2000) {
      return false;
    }
    try {
      await this.probeStartupQueries(timeoutMs);
    } catch (_) {
      return false;
    }
    return this.isReliableLinkFresh();
  }

  setMovementAxes(axes: StickAxes): void {
    this.axes = axes;
  }

  async centerSticks(): Promise<void> {
    this.axes = axesForMovement('forward');
    this.axes.pitch = 1024;
    await this.sendStick(true);
  }

  async requestFlight(parameter: number, timeoutMs: number = 2000): Promise<Uint8Array | undefined> {
    if (parameter !== 1 && parameter !== 2) {
      throw new Error('Unsupported flight command');
    }
    const inner = this.nextInner();
    const outer = this.nextOuter();
    const frame = buildFlyTunnel(parameter, inner, outer);
    return this.requestReliable(frame, inner, 3, 0x2a, 3, timeoutMs);
  }

  async requestNative(receiver: number, commandSet: number, commandId: number, payload: Uint8Array,
    timeoutMs: number = 2000, token?: CancellationToken): Promise<Uint8Array | undefined> {
    if (token?.isCancelled()) throw new Error('操作已取消，未发送后续指令');
    if (timeoutMs <= 0 || timeoutMs > 3000) {
      throw new Error('Native request timeout is outside bounds');
    }
    const inner = this.nextInner();
    const outer = this.nextOuter();
    return this.requestReliable(buildTunneledRequest(receiver, commandSet, commandId, payload, inner, outer),
      inner, commandSet, commandId, receiver, timeoutMs);
  }

  // Direct 02 -> E9 18/47 video control; it has no task tunnel or DUML ACK waiter.
  async requestVideoKeyframe(reason: 'manual' | 'automatic' = 'manual'): Promise<void> {
    if (reason !== 'manual' && reason !== 'automatic') throw new Error('关键帧请求来源无效');
    if (this.keyframeGeneration !== undefined && this.keyframeGeneration !== this.generation) this.cancelKeyframePulse();
    const transport = this.transport;
    const controlAge = this.lastControlReceivedAt === undefined ? Infinity : Date.now() - this.lastControlReceivedAt;
    if (this.phaseValue !== SessionPhase.READY || !this.deviceVerified || transport === undefined ||
      this.routing === undefined || this.lastError.length > 0 || controlAge < 0 || controlAge > 1000) {
      throw new Error('关键帧请求需要已核验的新鲜可靠连接');
    }
    const now = this.keyframeNow();
    if (this.keyframePulse !== undefined) throw new Error('关键帧请求正在处理中');
    if (this.keyframeAttemptAtMs !== undefined && now - this.keyframeAttemptAtMs < 5000) {
      throw new Error('已请求关键帧，请间隔至少 5 秒');
    }
    const pulse: VideoKeyframePulse = { generation: this.generation, session: this.session,
      transport: transport, channel: this.channel, cancelSends: [], trueDone: false, resetDone: false };
    this.keyframePulse = pulse; this.keyframeGeneration = this.generation; this.keyframeAttemptAtMs = now;
    // Schedule before waiting for the platform send callback. A late callback
    // must not delay deassertion or the existing stick/ACK tick.
    pulse.resetTimer = this.keyframeClock.schedule((): void => {
      pulse.resetTimer = undefined;
      this.resetVideoKeyframe(pulse).catch((error: Error) => {
        if (this.currentKeyframePulse(pulse)) hilog.error(LOG_DOMAIN, LOG_TAG,
          'keyframe reset failed generation=%{public}d error=%{public}s', pulse.generation, error.message);
      });
    }, 120);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'keyframe request reason=%{public}s generation=%{public}d', reason, pulse.generation);
    try { await this.sendVideoKeyframe(pulse, now, true); }
    finally { pulse.trueDone = true; this.releaseKeyframePulse(pulse); }
  }

  private keyframeNow(): number {
    const now = this.keyframeClock.nowMs();
    if (!Number.isSafeInteger(now) || now < 0) throw new Error('关键帧单调时钟无效');
    return now;
  }

  private currentKeyframePulse(pulse: VideoKeyframePulse): boolean {
    // The channel's socket is opened only by connect(), after generation changes.
    // Capture both facade and transport so an old timer cannot use a replacement.
    return this.keyframePulse === pulse && this.phaseValue === SessionPhase.READY &&
      this.generation === pulse.generation && this.session === pulse.session &&
      this.transport === pulse.transport && this.channel === pulse.channel;
  }

  private async resetVideoKeyframe(pulse: VideoKeyframePulse): Promise<void> {
    try {
      if (!this.currentKeyframePulse(pulse)) return;
      // This deasserts an already attempted true. Temporary downlink staleness,
      // a newly rendered image, or a task/decoder change must not suppress it.
      await this.sendVideoKeyframe(pulse, this.keyframeNow(), false);
      if (this.currentKeyframePulse(pulse)) hilog.info(LOG_DOMAIN, LOG_TAG,
        'keyframe reset sent generation=%{public}d', pulse.generation);
    } catch (error) {
      if (this.currentKeyframePulse(pulse)) hilog.error(LOG_DOMAIN, LOG_TAG,
        'keyframe reset unconfirmed generation=%{public}d error=%{public}s', pulse.generation, errorMessage(error));
    } finally { pulse.resetDone = true; this.releaseKeyframePulse(pulse); }
  }

  private sendVideoKeyframe(pulse: VideoKeyframePulse, now: number, enabled: boolean): Promise<void> {
    if (!this.currentKeyframePulse(pulse)) return Promise.reject(new Error('关键帧请求会话已变化'));
    const frame = buildVideoKeyframeRequest(this.nextInner(), now, enabled);
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
      let finished: boolean = false;
      let timer: number | undefined;
      let cancel: () => void = (): void => {};
      const finish = (error?: Error): void => {
        if (finished) return;
        finished = true;
        if (timer !== undefined) this.keyframeClock.cancel(timer);
        pulse.cancelSends = pulse.cancelSends.filter((callback: () => void): boolean => callback !== cancel);
        if (error === undefined) resolve(); else reject(error);
      };
      cancel = (): void => finish(new Error('关键帧请求已取消或会话已变化'));
      pulse.cancelSends.push(cancel);
      timer = this.keyframeClock.schedule((): void => finish(new Error('关键帧发送等待超时')), 500);
      this.sendReliable(frame).then((): void => finish(), (error: Error): void => finish(new Error(errorMessage(error))));
    });
  }

  private releaseKeyframePulse(pulse: VideoKeyframePulse): void {
    if (this.keyframePulse === pulse && pulse.trueDone && pulse.resetDone) this.keyframePulse = undefined;
  }

  private cancelKeyframePulse(): void {
    const pulse = this.keyframePulse;
    this.keyframePulse = undefined; this.keyframeGeneration = undefined; this.keyframeAttemptAtMs = undefined;
    if (pulse === undefined) return;
    if (pulse.resetTimer !== undefined) this.keyframeClock.cancel(pulse.resetTimer);
    pulse.cancelSends.slice().forEach((cancel: () => void): void => cancel());
  }

  private async queryDevice(timeoutMs: number): Promise<boolean> {
    if (this.lastControlReceivedAt === undefined || Date.now() - this.lastControlReceivedAt > 1000) {
      throw new Error('Aircraft downlink is not active');
    }
    const inner = this.nextInner();
    const outer = this.nextOuter();
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'device query inner=0x%{public}d outer=0x%{public}d timeout=%{public}d',
      inner, outer, timeoutMs);
    const reply = await this.requestReliable(buildTunnelCommand(3, 0x34, new Uint8Array(0), inner, outer),
      inner, 3, 0x34, 3, timeoutMs);
    const verified = reply !== undefined && reply.length > 0 && reply[0] === 0;
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'device query result received=%{public}s length=%{public}d verified=%{public}s',
      reply !== undefined ? 'true' : 'false', reply === undefined ? 0 : reply.length,
      verified ? 'true' : 'false');
    return verified;
  }

  private async probeStartupQueries(timeoutMs: number): Promise<void> {
    const first = this.reserveInner(4);
    const frames: Uint8Array[] = [];
    const targets: number[] = [0x0e, 0x1f, 0xa2, 0x00];
    targets.forEach((target: number, index: number) => {
      frames.push(encodeDumlFrame(2, target, (first + index) & 0xffff, 0x40, 0, 1, new Uint8Array(0)));
    });
    const replySequence = (first + 1) & 0xffff;
    await this.requestReliable(concatBytes(...frames), replySequence, 0, 1, 0x1f, timeoutMs);
  }

  private async requestReliable(frame: Uint8Array, sequence: number, commandSet: number, commandId: number,
    sender: number, timeoutMs: number): Promise<Uint8Array | undefined> {
    if (this.transport === undefined) {
      throw new Error('Reliable transport is unavailable');
    }
    if (this.pending.has(sequence)) {
      throw new Error('A command with this sequence is already pending');
    }
    const response = new Promise<Uint8Array | undefined>((resolve: (payload?: Uint8Array) => void) => {
      const timer = setTimeout(() => {
        this.pending.delete(sequence);
        resolve(undefined);
      }, timeoutMs);
      this.pending.set(sequence, {
        commandSet: commandSet,
        commandId: commandId,
        sender: sender,
        resolve: resolve,
        timer: timer
      });
    });
    try {
      // A response or its timeout is authoritative even if the platform's send
      // callback is delayed. Promise.race also consumes a later send rejection.
      return await Promise.race([this.sendReliable(frame).then(() => response), response]);
    } catch (error) {
      const pending = this.pending.get(sequence);
      if (pending !== undefined) {
        clearTimeout(pending.timer);
        this.pending.delete(sequence);
        pending.resolve(undefined);
      }
      throw new Error(errorMessage(error));
    }
  }

  private async sendReliable(frame: Uint8Array): Promise<void> {
    const transport = this.transport;
    if (transport === undefined) {
      throw new Error('Reliable transport is unavailable');
    }
    const routing = this.routing;
    if (routing === undefined) throw new Error('Routing sequence store is unavailable');
    let usedCounter: number = 0;
    const routed = resequenceTunnels(frame, () => {
      usedCounter = routing.next();
      return usedCounter;
    });
    const wire = transport.encode(routed, Date.now());
    if (this.reliableSendHexLogged < 40) {
      this.reliableSendHexLogged++;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'reliable send hex=%{public}s counter=%{public}d',
        toHex(wire), usedCounter);
    }
    await this.channel.send(wire);
  }

  private onPacket(raw: Uint8Array, receivedAtMs: number): void {
    if (this.phaseValue === SessionPhase.HANDSHAKING && isMatchingHandshakeReply(raw, this.session)) {
      if (this.handshakeMatched) return;
      this.handshakeMatched = true;
      // Python prepare_seconds window starts at the handshake match: the tick loop
      // sends the short 01/0a initial frames until this deadline, then full sticks.
      this.shortPhaseUntil = receivedAtMs + INITIAL_STICK_PHASE_MS;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'handshake matched; initial stick phase until +%{public}d ms',
        INITIAL_STICK_PHASE_MS);
      return;
    }
    if (this.phaseValue === SessionPhase.HANDSHAKING && !this.handshakeMatched) return;
    let outer: OuterPacket;
    try {
      outer = parseOuterPacket(raw);
    } catch (_) {
      this.packetParseFailures++;
      if (this.packetParseFailures <= 5) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'packet parse failed length=%{public}d count=%{public}d',
          raw.length, this.packetParseFailures);
      }
      return;
    }
    if (outer.session !== this.session) {
      this.sessionMismatches++;
      if (this.sessionMismatches <= 5) {
        hilog.warn(LOG_DOMAIN, LOG_TAG,
          'packet session mismatch packet=0x%{public}d expected=0x%{public}d channel=%{public}d count=%{public}d',
          outer.session, this.session, outer.channel, this.sessionMismatches);
      }
      return;
    }
    if (outer.channel === 1 && this.replyDiagnosticsLogged < 40) {
      const messages = allDumlMessages(raw);
      for (let index = 0; index < messages.length && this.replyDiagnosticsLogged < 40; index++) {
        try {
          const frame = decodeDumlFrame(messages[index]);
          this.replyDiagnosticsLogged++;
          hilog.info(LOG_DOMAIN, LOG_TAG,
            'channel1 frame outer=0x%{public}d sender=%{public}d receiver=%{public}d flags=0x%{public}d set=0x%{public}d id=0x%{public}d sequence=0x%{public}d payload=%{public}d',
            outer.sequence, frame.sender, frame.receiver, frame.flags, frame.commandSet,
            frame.commandId, frame.sequence, frame.payload.length);
        } catch (_) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'channel1 DUML decode failed outer=0x%{public}d length=%{public}d',
            outer.sequence, raw.length);
          break;
        }
      }
    }
    if (outer.channel === 1) {
      let carriesQueryReply = false;
      const messages = allDumlMessages(raw);
      for (let index = 0; index < messages.length; index++) {
        if (messages[index][9] === 3 && messages[index][10] === 0x34) {
          carriesQueryReply = true;
          break;
        }
      }
      if (this.channel1HexLogged < 24) {
        this.channel1HexLogged++;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'channel1 raw hex=%{public}s', toHex(raw));
      } else if (carriesQueryReply && this.queryReplyHexLogged < 6) {
        this.queryReplyHexLogged++;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'channel1 query-reply raw hex=%{public}s', toHex(raw));
      }
    }
    const transport = this.transport;
    if (transport !== undefined) {
      transport.observe(raw);
    }
    this.receivedPackets++;
    this.lastReceivedAt = receivedAtMs;
    if (outer.channel === 1 && raw.length >= 34) this.lastControlReceivedAt = receivedAtMs;
    if (outer.channel === 2) {
      this.lastVideoAt = receivedAtMs;
      const frame = this.videoAssembler.feed(raw, receivedAtMs);
      const listener = this.videoListener;
      if (frame !== undefined && listener !== undefined) {
        listener(frame);
      }
    }
    if (outer.channel === 3) {
      const handler = this.channel3Handler;
      if (handler !== undefined) {
        handler(raw);
      }
    }
    const messages = allDumlMessages(raw);
    messages.forEach((message: Uint8Array) => {
      this.registration?.observe(message);
      this.telemetry.observe(message, receivedAtMs);
    });
    const pendingEntries = Array.from(this.pending.entries());
    pendingEntries.forEach((entry: [number, PendingCommand]) => {
      const sequence = entry[0];
      const command = entry[1];
      const payload = findCommandReply(raw, this.session, sequence, command.commandSet,
        command.commandId, command.sender);
      if (payload !== undefined) {
        hilog.info(LOG_DOMAIN, LOG_TAG,
          'command reply matched sequence=0x%{public}d set=0x%{public}d id=0x%{public}d sender=%{public}d length=%{public}d',
          sequence, command.commandSet, command.commandId, command.sender, payload.length);
        clearTimeout(command.timer);
        this.pending.delete(sequence);
        command.resolve(payload);
      }
    });
    this.emitThrottled();
  }

  private async tick(): Promise<void> {
    if (this.ticking || this.transport === undefined || this.registration === undefined ||
      (this.phaseValue !== SessionPhase.REGISTERING && this.phaseValue !== SessionPhase.READY)) {
      return;
    }
    const generation = this.generation;
    const current = (): boolean => generation === this.generation &&
      (this.phaseValue === SessionPhase.REGISTERING || this.phaseValue === SessionPhase.READY);
    this.ticking = true;
    try {
      const now = Date.now();
      const registrationFrames = this.registration.poll(now, () => this.nextInner(), () => this.nextOuter());
      for (let index = 0; index < registrationFrames.length; index++) {
        await this.sendReliable(registrationFrames[index]);
        if (!current()) return;
      }
      await this.sendStick(false);
      if (!current()) return;
      await this.channel.send(this.transport.acknowledgement());
      if (!current()) return;
      const retries = this.transport.retries(now);
      for (let index = 0; index < retries.length; index++) {
        await this.channel.send(retries[index]);
        if (!current()) return;
      }
      this.emitThrottled();
    } finally {
      if (generation === this.generation) this.ticking = false;
    }
  }

  private async sendStick(forceNeutral: boolean): Promise<void> {
    const transport = this.transport;
    if (transport === undefined) {
      return;
    }
    let axes = this.axes;
    if (forceNeutral || this.lastReceivedAt === undefined || Date.now() - this.lastReceivedAt > 1000) {
      axes = { roll: 1024, pitch: 1024, throttle: 1024, yaw: 1024 };
      this.axes = axes;
    }
    // Match Python mode='short' during prepare_seconds: right after the handshake the
    // aircraft expects the short initial 01/0a frame; forced neutral bypasses it.
    const inShortPhase = !forceNeutral && Date.now() < this.shortPhaseUntil;
    const payload = inShortPhase ? INITIAL_PAYLOAD :
      buildStickPayload(axes.roll, axes.pitch, axes.throttle, axes.yaw, this.stickCounter);
    const frame = encodeDumlFrame(2, 0xa9, this.nextInner(), 0, 1, 0x0a, payload);
    this.stickCounter = (this.stickCounter + 50) & 0xffffff;
    await this.sendReliable(frame);
  }

  private nextInner(): number {
    const value = this.innerSequence;
    this.innerSequence = (value + 1) & 0xffff;
    return value;
  }

  private reserveInner(count: number): number {
    const value = this.innerSequence;
    this.innerSequence = (value + count) & 0xffff;
    return value;
  }

  private nextOuter(): number {
    const value = this.outerSequence;
    this.outerSequence = (value + 1) & 0xffff;
    return value;
  }

  private fail(message: string): void {
    this.lastError = message;
    this.phaseValue = SessionPhase.FAILED;
    this.emit();
  }

  private emit(): void {
    if (this.emitTimer !== undefined) {
      clearTimeout(this.emitTimer);
      this.emitTimer = undefined;
    }
    this.lastEmitAt = Date.now();
    const listener = this.listener;
    if (listener !== undefined) {
      listener(this.snapshot());
    }
  }

  private emitThrottled(): void {
    const elapsed = Date.now() - this.lastEmitAt;
    if (elapsed >= 250) {
      this.emit();
      return;
    }
    if (this.emitTimer === undefined) {
      this.emitTimer = setTimeout(() => {
        this.emitTimer = undefined;
        this.emit();
      }, 250 - elapsed);
    }
  }

  private async cleanup(): Promise<void> {
    // Invalidate pending callbacks before awaiting any asynchronous resource close.
    this.generation++;
    this.cancelKeyframePulse();
    const generation = this.generation;
    const routing = this.routing;
    this.ticking = false;
    this.telemetry.clearSubject();
    if (this.tickTimer !== undefined) {
      clearInterval(this.tickTimer);
      this.tickTimer = undefined;
    }
    if (this.emitTimer !== undefined) {
      clearTimeout(this.emitTimer);
      this.emitTimer = undefined;
    }
    this.pending.forEach((pending: PendingCommand) => {
      clearTimeout(pending.timer);
      pending.resolve(undefined);
    });
    this.pending.clear();
    await this.channel.close();
    routing?.close();
    if (generation !== this.generation) return;
    this.routing = undefined;
    this.transport = undefined;
    this.registration = undefined;
    this.selection = undefined;
    this.profileId = '';
  }
}

function videoKeyframeClock(): VideoKeyframeClock {
  return new SystemVideoKeyframeClock();
}

class SystemVideoKeyframeClock implements VideoKeyframeClock {
  nowMs(): number { return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false); }
  schedule(callback: () => void, delayMs: number): number { return setTimeout(callback, delayMs); }
  cancel(timer: number): void { clearTimeout(timer); }
}

function delay(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, milliseconds));
}

function errorMessage(error: Object): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}
