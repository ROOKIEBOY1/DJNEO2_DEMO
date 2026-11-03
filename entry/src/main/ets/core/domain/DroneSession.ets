import { hilog } from '@kit.PerformanceAnalysisKit';
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

export interface DroneSessionSnapshot {
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

  constructor() {}

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
    try {
      this.phaseValue = SessionPhase.SELECTING_NETWORK;
      this.emit();
      this.selection = selection;
      this.profileId = profile.id;
      this.generation++;
      const generation = this.generation;
      this.routing = new RoutingSequenceStore(profile.directory, profile.registration.routingIdentity);
      this.routing.open();
      this.telemetry = new TelemetryStore();
      this.videoAssembler = new VideoAssembler();
      this.receivedPackets = 0;
      this.handshakeAttemptValue = 0;
      this.lastReceivedAt = undefined;
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
        if (generation === this.generation && profile.id === this.profileId) this.onPacket(packet, receivedAtMs);
      };
      const errorHandler = (message: string): void => {
        this.fail(message);
      };
      await this.channel.open(this.selection, packetHandler, errorHandler);
      const request = buildHandshake(this.session, this.videoSeed);
      for (let attempt = 0; attempt < 60 && !this.handshakeMatched; attempt++) {
        this.handshakeAttemptValue = attempt + 1;
        this.emit();
        await this.channel.send(request);
        // The aircraft associates its reply with the original UDP return port.
        // Match Python FlightController.connect(): keep one socket for all retries,
        // and start the tick loop as soon as the matching reply arrives.
        const retryDeadline = Date.now() + 550;
        while (Date.now() < retryDeadline && !this.handshakeMatched) {
          await delay(50);
        }
      }
      if (!this.handshakeMatched) {
        throw new Error('No matching 15-byte aircraft handshake reply');
      }
      this.transport = new ReliableTransport(this.session, this.videoSeed);
      this.registration = new RegistrationExchange(Date.now(), profile.registration);
      this.phaseValue = SessionPhase.REGISTERING;
      this.tickTimer = setInterval(() => {
        this.tick().catch((error: Error) => this.fail(error.message));
      }, 60);
      this.emit();
      return success(this.snapshot());
    } catch (error) {
      const message = errorMessage(error);
      this.lastError = message;
      this.phaseValue = SessionPhase.FAILED;
      await this.cleanup();
      this.phaseValue = SessionPhase.DISCONNECTED;
      this.emit();
      return failure(ErrorLayer.NETWORK, 'CONNECT_FAILED', message);
    }
  }

  async initialize(timeoutMs: number = 8000): Promise<OperationResult<DroneSessionSnapshot>> {
    if (timeoutMs <= 0 || timeoutMs > 15000 || this.transport === undefined) {
      return failure(ErrorLayer.HANDSHAKE_REGISTRATION, 'INVALID_INITIALIZATION',
        'Initialization requires a reliable connected session and a bounded timeout');
    }
    const deadline = Date.now() + timeoutMs;
    try {
      // Python connect() blocks for prepare_seconds before the caller may initialize,
      // so the aircraft always sees the full short initial frame phase before queries.
      while (Date.now() < deadline &&
        (this.lastReceivedAt === undefined || Date.now() - this.lastReceivedAt > 1000 ||
          Date.now() < this.shortPhaseUntil)) {
        await delay(50);
      }
      if (this.lastReceivedAt === undefined || Date.now() - this.lastReceivedAt > 1000) {
        return failure(ErrorLayer.HANDSHAKE_REGISTRATION, 'INITIALIZATION_TIMEOUT',
          'No fresh reliable aircraft downlink arrived after the handshake');
      }
      await this.probeStartupQueries(Math.min(500, timeoutMs));
      while (Date.now() < deadline) {
        if (!this.deviceVerified) {
          const remaining = Math.max(1, deadline - Date.now());
          await this.queryDevice(Math.min(1000, remaining));
        }
        if (this.deviceVerified && this.lastReceivedAt !== undefined && Date.now() - this.lastReceivedAt <= 1000) {
          this.phaseValue = SessionPhase.READY;
          this.emit();
          return success(this.snapshot());
        }
        await delay(100);
      }
      return failure(ErrorLayer.HANDSHAKE_REGISTRATION, 'INITIALIZATION_TIMEOUT',
        'Device reply and fresh reliable downlink were not both observed');
    } catch (error) {
      return failure(ErrorLayer.HANDSHAKE_REGISTRATION, 'INITIALIZATION_FAILED', errorMessage(error));
    }
  }

  async disconnect(): Promise<OperationResult<boolean>> {
    this.phaseValue = SessionPhase.CLOSING;
    this.emit();
    await this.cleanup();
    this.phaseValue = SessionPhase.DISCONNECTED;
    this.emit();
    return success(true);
  }

  snapshot(): DroneSessionSnapshot {
    const now = Date.now();
    return {
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

  isReliableLinkFresh(): boolean {
    const snapshot = this.snapshot();
    return snapshot.phase === SessionPhase.READY && snapshot.deviceVerified &&
      snapshot.downlinkAgeMs !== undefined && snapshot.downlinkAgeMs <= 1000;
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

  private async queryDevice(timeoutMs: number): Promise<void> {
    if (this.lastReceivedAt === undefined || Date.now() - this.lastReceivedAt > 1000) {
      throw new Error('Aircraft downlink is not active');
    }
    const inner = this.nextInner();
    const outer = this.nextOuter();
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'device query inner=0x%{public}d outer=0x%{public}d timeout=%{public}d',
      inner, outer, timeoutMs);
    const reply = await this.requestReliable(buildTunnelCommand(3, 0x34, new Uint8Array(0), inner, outer),
      inner, 3, 0x34, 3, timeoutMs);
    this.deviceVerified = reply !== undefined && reply.length > 0 && reply[0] === 0;
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'device query result received=%{public}s length=%{public}d verified=%{public}s',
      reply !== undefined ? 'true' : 'false', reply === undefined ? 0 : reply.length,
      this.deviceVerified ? 'true' : 'false');
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
      await this.sendReliable(frame);
      return await response;
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
      this.handshakeMatched = true;
      // Python prepare_seconds window starts at the handshake match: the tick loop
      // sends the short 01/0a initial frames until this deadline, then full sticks.
      this.shortPhaseUntil = receivedAtMs + INITIAL_STICK_PHASE_MS;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'handshake matched; initial stick phase until +%{public}d ms',
        INITIAL_STICK_PHASE_MS);
      return;
    }
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
    if (this.ticking || this.transport === undefined || this.registration === undefined) {
      return;
    }
    this.ticking = true;
    try {
      const now = Date.now();
      const registrationFrames = this.registration.poll(now, () => this.nextInner(), () => this.nextOuter());
      for (let index = 0; index < registrationFrames.length; index++) {
        await this.sendReliable(registrationFrames[index]);
      }
      await this.sendStick(false);
      await this.channel.send(this.transport.acknowledgement());
      const retries = this.transport.retries(now);
      for (let index = 0; index < retries.length; index++) {
        await this.channel.send(retries[index]);
      }
      this.emitThrottled();
    } finally {
      this.ticking = false;
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
    this.routing?.close();
    this.routing = undefined;
    this.transport = undefined;
    this.registration = undefined;
    this.selection = undefined;
    this.profileId = '';
    this.generation++;
  }
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
