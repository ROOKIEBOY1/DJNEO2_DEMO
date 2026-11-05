import { NativeTaskConfig, NativeTaskService, NativeTaskSnapshot } from './NativeTaskService';
import { DollyFraming, NativeTaskKind } from '../protocol/NativeTaskCodec';
import { VoiceMotion } from './VoiceMotion';
import * as nativeVideo from 'libneovideo.so';
import { VideoPreview, VideoPreviewSnapshot, videoSessionIdentity } from '../media/VideoPreview';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CameraService } from './CameraService';
import { DroneSession, DroneSessionSnapshot } from './DroneSession';
import { FlightCommandService, FlightCommandSnapshot } from './FlightCommandService';
import { MediaRepository } from '../media/MediaRepository';
import { MediaKind } from '../media/MediaDirectory';
import { GallerySaver } from '../platform/GallerySaver';
import { CaptureMedia } from '../media/CaptureMedia';
import { MediaDownloadResult } from '../media/MediaDownloader';
import { CancellationToken, ErrorLayer, failure, OperationResult, success } from './OperationResult';
import { MovementDirection } from '../protocol/StickCodec';
import { VoiceCommand, VoiceCommandAdapter, VoiceCommandSnapshot } from './VoiceCommandAdapter';
import { Context } from '@kit.AbilityKit';
import { LocalSpeechRecognizer } from '../platform/LocalSpeechRecognizer';
import { AircraftProfileStore, AircraftProfileSummary } from '../profile/AircraftProfileStore';
import { NeoWifiLink } from '../platform/NeoWifiLink';
import { SubjectBox } from './SubjectObservation';
import { image } from '@kit.ImageKit';
import { canApplyVlmSelection, closestFrameSubjects, markVlmCandidates, trackedSubjectId, VlmFrame } from '../media/VlmFrame';
import { AgentAction, AgentObservation, AgentOutcome, AgentResponse, DirectFlightAction, parseDirectFlightVoice, agentActionLabel, agentNeedsConfirmation,
  validateAgentAction, validateAgentResponse } from './AgentAction';

export interface ConsoleSnapshot {
  dollyDemo: DollyDemoSnapshot;
  aircraftProfiles: AircraftProfileSummary[];
  selectedAircraftId: string;
  wifiProgress: string;
  session: DroneSessionSnapshot;
  flight: FlightCommandSnapshot;
  circlePrepared: boolean;
  circleStarted: boolean;
  circleObserved: boolean;
  cameraBusy: boolean;
  recordingRequested: boolean;
  voice: VoiceCommandSnapshot;
  nativeTask: NativeTaskSnapshot;
  nativeConfig: NativeTaskConfig;
  calibrationSummary: string;
  defaultMovementSeconds: number;
  busy: boolean;
  lastOperation: string;
  lastErrorLayer: string;
  lastError: string;
  logs: string[];
  videoPreview: VideoPreviewSnapshot;
  agentConfirmation: string;
  agentFeedback: string;
  agentMediaUri: string;
  agentMediaKind: string;
  agentMediaSaving: boolean;
  agentMediaCount: number;
  agentMediaIndex: number;
  subjectScanStatus: string;
}

interface PendingAgentAction { observation: AgentObservation; command: AgentAction; expiresAt: number; }

export interface DollyDemoSnapshot {
  stage: string;
  message: string;
  videoUri: string;
  candidate?: SubjectBox;
}

export type ConsoleListener = (snapshot: ConsoleSnapshot) => void;

export class AppController {
  readonly video: VideoPreview = new VideoPreview(nativeVideo);
  readonly session: DroneSession;
  readonly flight: FlightCommandService;
  readonly nativeTasks: NativeTaskService;
  readonly media: MediaRepository;
  readonly camera: CameraService;
  readonly voice: VoiceCommandAdapter = new VoiceCommandAdapter();
  private readonly speech: LocalSpeechRecognizer;
  private readonly outputDirectory: string;
  private readonly profiles: AircraftProfileStore;
  private readonly wifi: NeoWifiLink = new NeoWifiLink();
  private listener?: ConsoleListener;
  private previewTimer?: number;
  private videoSessionEnabled: boolean = false;
  private hoverScanAttempted: boolean = false;
  private autoScanGeneration: number = -1;
  private autoScanRequestedGeneration: number = -1;
  private autoScanGateLog: string = '';
  private autoScanHoverSince?: number;
  private autoScanFailures: number = 0;
  private autoScanRetryAt: number = 0;
  private autoScanRunning: boolean = false;
  private autoScanMessage: string = '起飞悬停后自动扫描主体';
  private selectedSubjectId?: number;
  private vlmFramePending: boolean = false;
  private agentGeneration: number = 0;
  private agentRequestSequence: number = 0;
  private latestAgentRequestId: string = '';
  private acceptedAgentRequestId: string = '';
  private pendingAgentAction?: PendingAgentAction;
  private agentFeedback: string = '';
  private agentMediaUri: string = '';
  private agentMediaKind: string = '';
  private agentMediaSaving: boolean = false;
  private agentMediaUris: string[] = [];
  private agentMediaIndex: number = 0;
  private readonly gallerySaver: GallerySaver = new GallerySaver();
  private readonly captureMedia: CaptureMedia;
  private demoStage: string = 'closed';
  private demoMessage: string = '';
  private demoVideoUri: string = '';
  private demoCandidate?: SubjectBox;
  private demoSessionId?: number;
  private demoStartAt?: number;
  private demoSawExecution: boolean = false;
  private demoMediaBefore: Set<string> = new Set<string>();
  private busyValue: boolean = false;
  private activeOperations: number = 0;
  private defaultMovementSeconds: number = 0.5;
  private operationToken?: CancellationToken;
  private readonly motion: VoiceMotion = new VoiceMotion();
  private nativeConfig: NativeTaskConfig = { radiusMeters: 2, framing: '半身', zoom: 2, retreat: true };
  private lastOperationValue: string = '等待连接';
  private lastErrorLayerValue: string = '';
  private lastErrorValue: string = '';
  private logsValue: string[] = [];
  private wifiProgressValue: string = '等待选择飞机';

  constructor(filesDirectory: string, context: Context) {
    this.outputDirectory = filesDirectory;
    this.profiles = new AircraftProfileStore(filesDirectory);
    this.session = new DroneSession();
    this.flight = new FlightCommandService(this.session);
    this.media = new MediaRepository(this.session);
    this.camera = new CameraService(this.session, this.media);
    this.captureMedia = new CaptureMedia(this.session, this.media, filesDirectory);
    this.nativeTasks = new NativeTaskService(this.session, this.flight, this.camera);
    try {
      const path = `${filesDirectory}/voice-calibration.json`;
      if (fileIo.accessSync(path)) this.motion.importJson(fileIo.readTextSync(path));
    } catch (error) { this.log(`标定文件未载入：${asError(error).message}`); }
    this.speech = new LocalSpeechRecognizer(context, this.voice);
    this.speech.setStatusListener((message: string) => {
      this.log(message);
      this.emit();
    });
    this.session.setVideoFrameListener((frame: Uint8Array) => this.video.submit(frame));
    this.session.setListener((state: DroneSessionSnapshot) => {
      this.video.setSession(this.videoSessionEnabled ? videoSessionIdentity(state.phase, state.sessionHex) : '');
      this.emit();
      this.pollAutomaticMedia().catch((error: Error) => this.recordException('自动取回原片', error));
    });
    this.voice.setListener((command: VoiceCommand) => {
      this.executeVoice(command).catch((error: Error) => this.recordException('语音命令', error));
    });
    this.voice.setStatusListener(() => this.emit());
    this.voice.setBusyProvider(() => this.busyValue);
    this.voice.setMovementDurationProvider(() => this.defaultMovementSeconds);
  }

  setListener(listener?: ConsoleListener): void {
    if (this.previewTimer !== undefined) { clearInterval(this.previewTimer); this.previewTimer = undefined; }
    this.listener = listener;
    if (listener !== undefined) this.previewTimer = setInterval(() => {
      this.pollAutomaticMedia().catch((error: Error) => this.recordException('自动取回原片', error));
      this.pollAutoSubjectScan().catch((error: Error) => this.recordException('自动扫描', error));
      this.emit();
    }, 250);
    this.emit();
  }

  snapshot(): ConsoleSnapshot {
    if (this.pendingAgentAction !== undefined && Date.now() > this.pendingAgentAction.expiresAt) {
      this.pendingAgentAction = undefined;
      this.agentFeedback = '动作确认已过期，请重新发起';
    }
    const circle = this.nativeTasks.snapshot();
    const camera = this.camera.snapshot();
    const session = this.session.snapshot();
    this.updateDollyDemo(session, circle);
    const subject = session.telemetry.subject;
    const candidate = this.dollyDemoHasTrack(session, this.demoCandidate?.id) ? subject?.overlay[0] :
      subject?.candidateCount === 1 && subject.candidates[0].id === this.demoCandidate?.id ? subject.candidates[0] : undefined;
    return {
      dollyDemo: { stage: this.demoStage, message: this.demoMessage, videoUri: this.demoVideoUri, candidate: candidate },
      aircraftProfiles: this.profiles.list(),
      selectedAircraftId: this.profiles.selectedId(),
      wifiProgress: this.wifiProgressValue,
      session: session,
      flight: this.flight.snapshot(),
      circlePrepared: circle.prepared,
      circleStarted: circle.startedAtMs !== undefined,
      circleObserved: circle.executionObserved,
      cameraBusy: camera.operationActive,
      recordingRequested: camera.recordingRequested,
      voice: this.voice.snapshot(),
      nativeTask: circle,
      nativeConfig: { radiusMeters: this.nativeConfig.radiusMeters, framing: this.nativeConfig.framing,
        zoom: this.nativeConfig.zoom, retreat: this.nativeConfig.retreat },
      calibrationSummary: this.motion.summary(),
      defaultMovementSeconds: this.defaultMovementSeconds,
      busy: this.busyValue,
      lastOperation: this.lastOperationValue,
      lastErrorLayer: this.lastErrorLayerValue,
      lastError: this.lastErrorValue,
      logs: this.logsValue.slice(),
      videoPreview: this.video.snapshot(),
      agentConfirmation: this.pendingAgentAction === undefined ? '' : agentActionLabel(this.pendingAgentAction.command) +
        (!this.pendingAgentAction.observation.context.airborne &&
          ['dolly_zoom', 'circle', 'follow'].includes(this.pendingAgentAction.command.action) ? '（地面启动，飞机可能自动起飞）' : ''),
      agentFeedback: this.agentFeedback, agentMediaUri: this.agentMediaUri, agentMediaKind: this.agentMediaKind,
      agentMediaSaving: this.agentMediaSaving,
      agentMediaCount: this.agentMediaUris.length, agentMediaIndex: this.agentMediaIndex,
      subjectScanStatus: this.autoScanMessage
    };
  }

  selectAircraft(profileId: string): void {
    if (!this.profileChangesAllowed()) return this.rejectProfileChange('活动会话期间不能切换飞机');
    try {
      this.profiles.select(profileId);
      this.log('已选择目标飞机');
    } catch (error) { this.recordException('选择飞机', asError(error)); }
    this.emit();
  }

  createAircraft(displayName: string, ssid: string, password: string): void {
    if (!this.profileChangesAllowed()) return this.rejectProfileChange('活动会话期间不能新增飞机');
    try {
      this.profiles.create(displayName, ssid, password);
      this.log('已新增飞机档案；请导入验证后的注册资料和该飞机路由状态');
    } catch (error) { this.recordException('新增飞机', asError(error)); }
    this.emit();
  }

  updateSelectedAircraft(displayName: string, ssid: string, password: string): void {
    if (!this.profileChangesAllowed()) return this.rejectProfileChange('活动会话期间不能编辑飞机');
    try {
      this.profiles.updateCredentials(this.profiles.selectedId(), displayName, ssid, password);
      this.log('飞机凭据已保存到应用私有目录');
    } catch (error) { this.recordException('编辑凭据', asError(error)); }
    this.emit();
  }

  importRoutingState(jsonText: string): boolean {
    if (!this.profileChangesAllowed()) return false;
    try {
      this.profiles.importRoutingState(this.profiles.selectedId(), jsonText);
      this.lastErrorLayerValue = '';
      this.lastErrorValue = '';
      this.log('导入路由状态: 完成');
      this.emit();
      return true;
    } catch (error) {
      this.recordException('导入路由状态', asError(error));
      return false;
    }
  }

  rebuildRoutingState(): void {
    if (!this.profileChangesAllowed()) return this.rejectProfileChange('活动会话期间不能重建路由状态');
    try {
      this.profiles.initializeRoutingState(this.profiles.selectedId());
      this.log('路由状态已从 1 重建；先给飞机断电重启再连接，避免飞机仍记住旧计数');
      this.emit();
    } catch (error) {
      this.recordException('重建路由状态', asError(error));
      this.emit();
    }
  }

  importRegistrationProfile(jsonText: string): boolean {
    if (!this.profileChangesAllowed()) return false;
    try {
      this.profiles.importRegistrationProfile(this.profiles.selectedId(), jsonText);
      this.log('导入注册资料: 完成');
      this.emit();
      return true;
    } catch (error) {
      this.recordException('导入注册资料', asError(error));
      return false;
    }
  }

  removeSelectedAircraft(confirmed: boolean): void {
    if (!confirmed || !this.profileChangesAllowed()) return;
    try {
      this.profiles.remove(this.profiles.selectedId());
      this.log('飞机档案已删除');
    } catch (error) { this.recordException('删除飞机', asError(error)); }
    this.emit();
  }

  async connectSelectedAircraft(): Promise<void> {
    await this.run<DroneSessionSnapshot>('连接', async () => {
      try {
        const selected = this.profiles.selected();
        if (selected === undefined || !selected.configured || !selected.registrationReady) {
          return failure<DroneSessionSnapshot>(ErrorLayer.HANDSHAKE_REGISTRATION,
            'AIRCRAFT_PROFILE_INCOMPLETE', 'Aircraft credentials or registration profile are incomplete', false);
        }
        if (!selected.routingReady) {
          return failure<DroneSessionSnapshot>(ErrorLayer.HANDSHAKE_REGISTRATION,
            'ROUTING_STATE_REQUIRED',
            'Latest routing sequence state is required; import the state for this aircraft before connecting', false);
        }
        const runtime = this.profiles.runtime(this.profiles.selectedId());
        this.flight.resetForAircraftSession();
        this.hoverScanAttempted = false;
        this.selectedSubjectId = undefined;
        this.nativeTasks.resetForAircraftSession();
        this.camera.resetForAircraftSession();
        this.captureMedia.reset();
        this.agentGeneration++;
        this.pendingAgentAction = undefined;
        this.agentMediaUri = '';
        this.agentMediaKind = '';
        this.agentMediaUris = [];
        this.agentMediaIndex = 0;
        this.agentFeedback = '';
        this.wifiProgressValue = '检查目标飞机 Wi-Fi';
        this.emit();
        const selection = await this.wifi.join(runtime, (message: string) => {
          this.wifiProgressValue = message;
          this.emit();
        });
        this.videoSessionEnabled = true;
        const result = await this.session.connect(runtime, selection);
        if (!result.ok) await this.wifi.leave();
        return result;
      } catch (error) {
        await this.wifi.leave();
        return failure<DroneSessionSnapshot>(ErrorLayer.NETWORK, 'AIRCRAFT_CONNECT_FAILED', asError(error).message);
      }
    });
  }
  async connect(): Promise<void> { await this.connectSelectedAircraft(); }
  async initialize(): Promise<void> { await this.run('初始化', () => this.session.initialize()); }

  async ensureReadyConnection(): Promise<void> {
    if (this.busyValue) return;
    const phase = this.session.snapshot().phase;
    if (phase === 'disconnected' || phase === 'failed') await this.connectSelectedAircraft();
    if (!this.busyValue && this.session.snapshot().phase === 'registering') await this.initialize();
  }

  private async pollAutoSubjectScan(): Promise<void> {
    const flight = this.flight.snapshot();
    if (this.autoScanGeneration !== flight.generation) {
      this.autoScanGeneration = flight.generation;
      this.autoScanHoverSince = undefined;
      this.autoScanFailures = 0; this.autoScanRetryAt = 0;
      this.autoScanMessage = '起飞悬停后自动扫描主体';
    }
    if (this.autoScanRunning) return;
    const state = this.session.snapshot();
    const camera = this.camera.snapshot();
    const planning = this.latestAgentRequestId.length > 0 && this.latestAgentRequestId !== this.acceptedAgentRequestId;
    const gate = `扫描条件：轮次=${flight.generation}，本轮请求=${this.autoScanRequestedGeneration === flight.generation}，` +
      `飞行=${state.telemetry.flight?.modeRaw ?? '无'}/${(state.telemetry.flightAgeMs ?? Infinity) <= 1000}，` +
      `任务=${state.telemetry.task?.payloadHex ?? '无'}/${(state.telemetry.taskAgeMs ?? Infinity) <= 1000}，` +
      `扫描位=${state.telemetry.subject?.scanStateRaw ?? '无'}，候选=${state.telemetry.subject?.candidateCount ?? '无'}，` +
      `跟踪=${state.telemetry.subject?.tracking === true}，原生占用=${flight.nativeTaskMayFly === true}，` +
      `忙=${this.busyValue}，模型等待=${planning}，录像请求=${camera.recordingRequested}，` +
      `相机操作=${camera.operationActive}，录制=${state.telemetry.camera?.recordingCandidate}，` +
      `降落=${flight.landRequested === true || flight.landSent === true}`;
    if (gate !== this.autoScanGateLog) { this.autoScanGateLog = gate; this.log(gate); }
    if (state.phase !== 'ready' || ((state.telemetry.flightAgeMs ?? Infinity) <= 1000 &&
      state.telemetry.flight?.airborne === false && state.telemetry.flight.motorsOn === false)) {
      this.autoScanHoverSince = undefined;
      this.autoScanMessage = '起飞悬停后自动扫描主体';
      return;
    }
    if (flight.landRequested || flight.landSent) {
      this.autoScanHoverSince = undefined;
      this.autoScanMessage = '降落中，主体扫描已停止';
      return;
    }
    const subject = state.telemetry.subject;
    if (subject?.tracking) {
      this.autoScanHoverSince = undefined;
      this.autoScanMessage = `正在跟踪主体 #${trackedSubjectId(subject)}`;
      return;
    }
    const cameraIdle = (state.telemetry.cameraAgeMs ?? Infinity) <= 1000 &&
      state.telemetry.camera?.recordingCandidate === false && !camera.recordingRequested;
    if (this.busyValue || planning || this.pendingAgentAction !== undefined || this.demoStage !== 'closed' ||
      camera.operationActive || this.speech.isListeningOnce() || !cameraIdle ||
      !flight.takeoffAcknowledged || !this.isOrdinarySubjectHover(state, flight)) {
      this.autoScanHoverSince = undefined;
      return;
    }
    const task = state.telemetry.task;
    const scanning = subject?.scanStateRaw === 1 || (subject?.scanStateRaw === undefined &&
      this.hoverScanAttempted && subject?.candidateCount !== undefined);
    if (this.autoScanRequestedGeneration === flight.generation && scanning && task?.phaseRaw === 0 && task.modeRaw === 0) {
      this.hoverScanAttempted = true;
      this.autoScanHoverSince = undefined;
      this.autoScanFailures = 0;
      this.autoScanRetryAt = 0;
      this.autoScanMessage = '主体扫描中，说出你想选谁';
      return;
    }
    if (this.autoScanFailures >= 3) return;
    const now = Date.now();
    if (now < this.autoScanRetryAt) return;
    this.autoScanHoverSince = this.autoScanHoverSince ?? now;
    this.autoScanMessage = '悬停已确认，正在准备主体扫描…';
    if (now - this.autoScanHoverSince < 2000) return;
    this.autoScanRunning = true;
    try {
      await this.run<string>('自动主体扫描', async (token: CancellationToken) => {
        const result = await this.requestHoverSubjectScan(token, true);
        if (result.ok) this.autoScanRequestedGeneration = flight.generation;
        this.autoScanMessage = result.ok ? '主体扫描已请求，等待候选回报' :
          result.error?.message ?? '主体扫描未确认';
        this.autoScanFailures++;
        this.autoScanRetryAt = Date.now() + 5000;
        return result;
      });
    } finally {
      this.autoScanRunning = false;
      this.autoScanHoverSince = undefined;
    }
  }

  private isOrdinarySubjectHover(state: DroneSessionSnapshot, flight: FlightCommandSnapshot): boolean {
    const telemetry = state.telemetry;
    const task = telemetry.task;
    return state.phase === 'ready' && state.deviceVerified && (state.downlinkAgeMs ?? Infinity) <= 1000 &&
      (state.videoAgeMs ?? Infinity) <= 1000 && flight.takeoffSent && !flight.nativeTaskMayFly &&
      !flight.movementActive && !flight.landRequested && !flight.landSent && !this.nativeTasks.activeOrUnknown() &&
      (telemetry.flightAgeMs ?? Infinity) <= 1000 && telemetry.flight?.modeRaw === 6 &&
      telemetry.flight.airborne && telemetry.flight.motorsOn && task !== undefined &&
      ((task.phaseRaw === 0 && task.modeRaw === 0) || ([0, 5].includes(task.phaseRaw) && task.modeRaw === 9)) &&
      (telemetry.taskAgeMs ?? Infinity) <= 1000;
  }

  async startHoverSubjectScan(): Promise<void> {
    await this.run<string>('开始主体扫描', (token: CancellationToken) => this.requestHoverSubjectScan(token));
  }

  private async requestHoverSubjectScan(token: CancellationToken, restart: boolean = false): Promise<OperationResult<string>> {
      if (this.hoverScanAttempted && !restart) {
        return failure<string>(ErrorLayer.TASK, 'SUBJECT_SCAN_ALREADY_ATTEMPTED', '本次连接已发送过扫描请求，请查看候选列表');
      }
      const deadline = Date.now() + 2000;
      let manualTask = false;
      while (true) {
        if (token.isCancelled()) {
          return failure<string>(ErrorLayer.TASK, 'SUBJECT_CANCELLED', '主体扫描已取消');
        }
        const state = this.session.snapshot();
        const flight = this.flight.snapshot();
        const telemetry = state.telemetry;
        if (!this.isOrdinarySubjectHover(state, flight)) {
          return failure<string>(ErrorLayer.TASK, 'SUBJECT_HOVER_REQUIRED', '请普通起飞并保持悬停，确认视频和飞行状态持续更新');
        }
        const count = telemetry.subject?.candidateCount;
        manualTask = telemetry.task !== undefined && [0, 5].includes(telemetry.task.phaseRaw) && telemetry.task.modeRaw === 9;
        if (!manualTask && count === undefined) return failure<string>(ErrorLayer.TASK, 'SUBJECT_SCAN_BASELINE', '尚未收到有效候选状态');
        if (!manualTask && (count ?? 0) > 0 && !restart) return success('飞机已回传候选，请查看实时视频下方的列表');
        if (Date.now() >= deadline) break;
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
      }
      this.hoverScanAttempted = true;
      if (manualTask || restart) {
        const requested = Date.now();
        const sessionId = this.session.sessionId();
        const stopped = await this.session.requestNative(0x92, 0x23, 0x15, new Uint8Array(0), 1000, token);
        if (token.isCancelled() || stopped === undefined || stopped.length !== 1 || stopped[0] !== 0) {
          return failure<string>(ErrorLayer.TASK, 'SUBJECT_STOP_UNCONFIRMED', '飞机未确认进入可选人状态');
        }
        const scanDeadline = Date.now() + 4000;
        while (!token.isCancelled() && this.session.sessionId() === sessionId && Date.now() < scanDeadline) {
          const state = this.session.snapshot();
          const task = state.telemetry.task;
          const subject = state.telemetry.subject;
          if (this.isOrdinarySubjectHover(state, this.flight.snapshot()) && task?.phaseRaw === 0 && task.modeRaw === 0 &&
            task.observedAtMs >= requested && subject?.scanStateRaw === 1 && (subject.scanObservedAt ?? -1) >= requested) {
            return success('候选扫描已开启，点候选编号选中主体');
          }
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
        }
        return failure<string>(ErrorLayer.TASK, 'SUBJECT_SCAN_UNCONFIRMED', '未收到任务空闲和扫描开启回报，暂不能选人');
      }
      const reply = await this.session.requestNative(0x92, 0x0a, 0xba, new Uint8Array([1, 3, 0]), 1000, token);
      if (token.isCancelled()) return failure<string>(ErrorLayer.TASK, 'SUBJECT_CANCELLED', '主体扫描已取消');
      if (reply === undefined || reply.length !== 1 || reply[0] !== 0) {
        return failure<string>(ErrorLayer.TASK, 'SUBJECT_SCAN_UNCONFIRMED', '飞机未确认扫描请求，请查看后续候选回传');
      }
      return success('飞机已确认扫描请求，是否识别到主体以候选回传为准');
  }

  async selectSubject(targetId?: number): Promise<void> {
    await this.run<string>(targetId === undefined ? '取消主体' : `选择主体 #${targetId}`,
      (token: CancellationToken) => this.requestSubjectSelection(token, targetId));
  }

  async selectVlmSubject(frame: VlmFrame, id: number, generation: number): Promise<void> {
    let selectionError = '已有操作执行中，请稍后重试';
    await this.run<string>(`视觉选择主体 #${id}`, async (token: CancellationToken) => {
      const state = this.session.snapshot();
      const flight = this.flight.snapshot();
      if (!canApplyVlmSelection(frame, id, this.session.sessionId(), generation, flight.generation, Date.now()) ||
        !this.isOrdinarySubjectHover(state, flight) ||
        (state.telemetry.subject?.scanStateRaw !== 1 && !state.telemetry.subject?.tracking) ||
        trackedSubjectId(state.telemetry.subject) !== frame.currentSubjectId) {
        selectionError = '锁定状态已变化或样本已过期，请重新说一次';
        return failure<string>(ErrorLayer.TASK, 'VLM_STALE', selectionError);
      }
      const result = await this.requestSubjectSelection(token, id);
      selectionError = result.ok ? '' : result.error?.message ?? '未确认主体选择';
      return result;
    });
    if (selectionError.length > 0) throw new Error(selectionError);
  }

  private async requestSubjectSelection(token: CancellationToken, targetId?: number): Promise<OperationResult<string>> {
      const state = this.session.snapshot();
      const telemetry = state.telemetry;
      const subject = telemetry.subject;
      const flight = this.flight.snapshot();
      if (targetId !== undefined && telemetry.task !== undefined &&
        [0, 5].includes(telemetry.task.phaseRaw) && telemetry.task.modeRaw === 9) {
        return failure<string>(ErrorLayer.TASK, 'SUBJECT_SCAN_REQUIRED', '请先点开始主体扫描，等飞机进入可选人状态后再选择');
      }
      const idle = telemetry.task?.phaseRaw === 0 && (telemetry.taskAgeMs ?? Infinity) <= 1000;
      const demoSelection = this.demoStage === 'starting' && targetId !== undefined && targetId === this.demoCandidate?.id;
      const hover = (this.hoverScanAttempted || demoSelection) && this.isOrdinarySubjectHover(state, flight) &&
        (targetId !== undefined || subject?.tracking === true);
      if (!this.session.isReliableLinkFresh() || flight.landRequested || flight.landSent || flight.movementActive ||
        this.nativeTasks.activeOrUnknown() || (!idle && !hover)) {
        return failure<string>(ErrorLayer.TASK, 'SUBJECT_CONTEXT', '需要新鲜连接，且任务空闲或已开启普通悬停扫描');
      }
      const requested = Date.now();
      if (targetId !== undefined && (!Number.isInteger(targetId) || targetId < 0 || targetId > 255 ||
        subject === undefined || subject.detectionAt === undefined || requested - subject.detectionAt > 500 ||
        !subject.candidates.some(candidate => candidate.id === targetId))) {
        return failure<string>(ErrorLayer.TASK, 'SUBJECT_STALE', '候选已过期或编号不受支持，请等候新的候选框');
      }
      const payload = targetId === undefined ? new Uint8Array([1, 3, 0]) : new Uint8Array([1, 5, targetId]);
      this.selectedSubjectId = undefined;
      const reply = await this.session.requestNative(0x92, 0x0a, 0xba, payload, 1000, token);
      if (token.isCancelled()) return failure<string>(ErrorLayer.TASK, 'SUBJECT_CANCELLED', '主体操作已取消');
      if (reply === undefined || reply.length !== 1 || reply[0] !== 0) {
        return failure<string>(ErrorLayer.TASK, 'SUBJECT_UNCONFIRMED', '飞机未确认主体操作');
      }
      if (targetId === undefined) return success('飞机已确认取消请求');
      const deadline = Date.now() + 2000;
      while (!token.isCancelled() && this.session.isReliableLinkFresh() && Date.now() < deadline) {
        const latest = this.session.snapshot().telemetry.subject;
        if (latest !== undefined && (latest.detectionAt ?? -1) >= requested &&
          (latest.trackingAt ?? -1) >= requested && latest.selectedIdCandidate === targetId &&
          latest.overlay.length === 1 && latest.overlay[0].id === targetId) {
          this.selectedSubjectId = targetId;
          return success('已收到匹配编号的跟踪框，请核对实际主体。飞行跟随需单独启动');
        }
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 50));
      }
      if (token.isCancelled()) return failure<string>(ErrorLayer.TASK, 'SUBJECT_CANCELLED', '主体操作已取消');
      return failure<string>(ErrorLayer.TASK, 'SUBJECT_TRACK_UNCONFIRMED', '飞机已确认选择请求，但尚未回传匹配编号的跟踪框');
  }
  async disconnect(): Promise<void> {
    this.captureMedia.reset();
    this.videoSessionEnabled = false;
    this.video.setSession('');
    this.cancelOperations();
    await this.run('断开', async () => {
      if (this.nativeTasks.activeOrUnknown()) this.recordResult('停止原生任务', await this.nativeTasks.stop());
      const result = await this.flight.foregroundOnlySafetyShutdown();
      await this.wifi.leave();
      this.wifiProgressValue = '已断开并清理 Wi-Fi 候选配置';
      return result;
    }, false);
  }
  async takeoffConfirmed(): Promise<void> {
    if (this.busyValue) { this.log('当前操作未结束，未排队起飞'); this.emit(); return; }
    const current = this.flight.snapshot();
    if (current.takeoffSent || current.nativeTaskMayFly || current.landRequested) {
      const reset = this.flight.prepareGroundedCycle(true);
      if (!reset.ok) { this.recordResult('准备重飞', reset); return; }
      this.nativeTasks.resetAfterGroundedCycle();
      this.camera.resetAfterGroundedCycle();
      this.hoverScanAttempted = false;
      this.selectedSubjectId = undefined;
      this.session.clearSubjectObservation();
    }
    // The cycle reset is synchronous; run now allocates a token for the new generation.
    await this.run('起飞请求', (token: CancellationToken) => this.flight.takeoff(true, token));
  }
  async land(): Promise<void> {
    const task = this.nativeTasks.snapshot();
    this.cancelOperations();
    await this.run('降落请求', async () => {
      if (task.busy || task.prepared || task.activeOrUnknown) this.recordResult('停止原生任务', await this.nativeTasks.stop());
      return this.flight.land();
    }, false);
  }
  async center(): Promise<void> {
    const task = this.nativeTasks.snapshot(); this.cancelOperations();
    await this.run('停止/回中', async () => {
      if (task.busy || task.prepared || task.activeOrUnknown) return this.nativeTasks.stop();
      const result = await this.flight.centerSticks();
      return result.ok ? success('已回中') : failure<string>(ErrorLayer.COMMAND, 'CENTER_FAILED', result.error?.message ?? '回中失败');
    }, false);
  }
  async move(direction: MovementDirection, seconds: number): Promise<void> {
    await this.run(`移动 ${direction} ${seconds.toFixed(1)}s`, (token: CancellationToken) => this.flight.move(direction, seconds, token));
  }
  setMovementSeconds(seconds: number): void {
    if (!Number.isFinite(seconds) || seconds < 0.5 || seconds > 10) return;
    this.defaultMovementSeconds = seconds; this.emit();
  }
  async prepareCircle(): Promise<void> { await this.prepareNative('circle'); }
  async startCircleConfirmed(): Promise<void> { await this.startNativeConfirmed('circle'); }
  async stopCircle(): Promise<void> { await this.center(); }
  async prepareNative(kind: NativeTaskKind): Promise<void> {
    await this.run(`准备${this.taskLabel(kind)}`, (token: CancellationToken) => this.nativeTasks.prepare(kind, this.nativeConfig, token));
  }
  async startNativeConfirmed(kind: NativeTaskKind): Promise<void> {
    await this.run(`启动${this.taskLabel(kind)}`, async (token: CancellationToken) => {
      const task = this.nativeTasks.snapshot();
      if (!task.prepared || task.kind !== kind) {
        const prepared = await this.nativeTasks.prepare(kind, this.nativeConfig, token);
        if (!prepared.ok) return failure<string>(ErrorLayer.TASK, 'NATIVE_PREPARE_REQUIRED', prepared.error?.message ?? '任务准备失败');
      }
      return this.startNativeWithCapture(token);
    });
  }
  setTaskSettings(radius: number, framing: DollyFraming, zoom: number, retreat: boolean): void {
    if (this.busyValue || this.nativeTasks.activeOrUnknown()) { this.log('先停止当前操作，再修改任务参数'); this.emit(); return; }
    if (!Number.isFinite(radius) || radius < 2 || radius > 10 || !['半身', '全身', '远景'].includes(framing) || (zoom !== 2 && zoom !== 3)) return;
    this.pendingAgentAction = undefined;
    this.voice.cancelPending(); this.nativeTasks.cancel();
    this.nativeConfig = { radiusMeters: radius, framing: framing, zoom: zoom, retreat: retreat };
    this.log(`任务参数：环绕${radius}米 / ${framing} / 1–${zoom}倍 / 渐远${retreat ? '开' : '关'}`); this.emit();
  }
  recordCalibration(direction: MovementDirection, seconds: number, amount: number): void {
    if (this.busyValue || this.nativeTasks.activeOrUnknown()) return;
    try {
      this.motion.record(direction, seconds, amount);
      const path = `${this.outputDirectory}/voice-calibration.json`;
      const file = fileIo.openSync(`${path}.tmp`, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(file.fd, this.motion.exportJson()); fileIo.fsyncSync(file.fd); }
      finally { fileIo.closeSync(file); }
      fileIo.renameSync(`${path}.tmp`, path);
      this.log('实测标定已保存；米数/角度动作按标定估算');
    } catch (error) { this.recordException('保存标定', asError(error)); }
    this.emit();
  }
  async shoot(): Promise<void> {
    await this.run('拍照', async (token: CancellationToken) => {
      if (this.nativeTasks.activeOrUnknown()) return failure<string>(ErrorLayer.TASK, 'NATIVE_CONTEXT_ACTIVE', '先停止原生任务，再切换拍照上下文');
      this.nativeTasks.cancel(); this.voice.cancelPending();
      return this.shootAndRetrieve(token);
    });
  }
  async startRecording(): Promise<void> { await this.run('开始录像', (token: CancellationToken) => this.beginRecording(token)); }
  async stopRecording(): Promise<void> {
    this.cancelOperations();
    await this.run('停止录像', async (token: CancellationToken) => {
      this.operationToken = token;
      this.agentFeedback = '正在停止录像…';
      const stopped = await this.camera.stopRecording();
      if (!stopped.ok || !this.captureMedia.hasPending('video')) {
        this.agentFeedback = stopped.ok ? '飞机已确认停止录像请求' : stopped.error?.message ?? '停止录像未获确认';
        return stopped;
      }
      this.captureMedia.markReady('video');
      try { return success(await this.retrieveCapture('video', token)); }
      catch (error) { return failure<string>(ErrorLayer.TASK, 'VIDEO_RETURN_PENDING', `停止请求已确认，取回录像未完成：${asError(error).message}`); }
    }, false);
  }
  async listMedia(): Promise<void> {
    await this.run('刷新媒体目录', async (token: CancellationToken) => {
      const result = await this.camera.listMedia(token);
      if (result.ok && result.data !== undefined) this.log(`相册${result.data.length}项：${result.data.slice(0, 5).map(item => item.name).join('、')}`);
      return result;
    });
  }
  async downloadLatest(kind: MediaKind): Promise<void> {
    await this.run(`下载最新${kind === 'photo' ? '照片' : '视频'}`, async (token: CancellationToken) => {
      return success(await this.downloadForPreview(kind, token));
    });
  }

  private async shootAndRetrieve(token: CancellationToken): Promise<OperationResult<string>> {
    await this.captureMedia.begin('photo', token);
    const shot = await this.camera.shoot(token);
    if (!shot.ok) {
      if (shot.error?.code !== 'CAMERA_CAPTURE_UNCONFIRMED') {
        this.captureMedia.discard('photo');
      }
      return shot;
    }
    this.log('飞机已确认拍照请求，正在取回本次照片');
    this.captureMedia.markReady('photo');
    try { return success(await this.retrieveCapture('photo', token)); }
    catch (error) {
      return failure<string>(ErrorLayer.TASK, 'PHOTO_RETURN_PENDING',
        `拍照请求已确认，取回照片未完成：${asError(error).message}`);
    }
  }

  private async beginRecording(token: CancellationToken): Promise<OperationResult<string>> {
    await this.captureMedia.begin('video', token);
    const result = await this.camera.startRecording(token);
    if (!result.ok && !this.camera.snapshot().recordingRequested) this.captureMedia.discard('video');
    return result;
  }

  private async startNativeWithCapture(token: CancellationToken, selectedTarget?: number): Promise<OperationResult<string>> {
    await this.captureMedia.begin('video', token);
    const previousStart = this.nativeTasks.snapshot().startedAtMs;
    const result = await this.nativeTasks.start(true, token, selectedTarget);
    if (!result.ok && this.nativeTasks.snapshot().startedAtMs === previousStart) this.captureMedia.discard('video');
    return result;
  }

  private presentAgentMedia(kind: MediaKind, downloaded: MediaDownloadResult): void {
    this.presentAgentMediaGroup(kind, [downloaded]);
  }

  private presentAgentMediaGroup(kind: MediaKind, downloaded: MediaDownloadResult[]): void {
    this.agentMediaUris = downloaded.map(item => fileUri.getUriFromPath(item.path));
    this.agentMediaIndex = 0;
    this.agentMediaUri = this.agentMediaUris[0];
    this.agentMediaKind = kind;
    this.agentFeedback = `本次${kind === 'photo' ? '照片' : '录像'}已取回${downloaded.length > 1 ? `，共${downloaded.length}段` : ''}`;
    downloaded.forEach((item: MediaDownloadResult, index: number) =>
      this.log(`本次素材 ${index + 1}/${downloaded.length} 已取回：${item.path}，${item.size} 字节`));
    if (kind === 'video' && this.demoSessionId === this.session.sessionId() && this.demoSawExecution &&
      ['shooting', 'recorded', 'downloading'].includes(this.demoStage)) {
      this.demoVideoUri = this.agentMediaUri;
      this.demoStage = 'playback';
      this.demoMessage = this.agentFeedback;
    }
    this.emit();
  }

  private async retrieveCapture(kind: MediaKind, token: CancellationToken): Promise<string> {
    const downloaded = await this.captureMedia.retrieveAll(kind, token, (message: string) => {
      this.agentFeedback = message;
      this.emit();
    });
    this.presentAgentMediaGroup(kind, downloaded);
    return `本次${kind === 'photo' ? '照片' : '录像'}已取回${downloaded.length > 1 ? `，共${downloaded.length}段` : ''}`;
  }

  selectAgentMedia(index: number): void {
    if (this.agentMediaSaving || !Number.isInteger(index) || index < 0 || index >= this.agentMediaUris.length) return;
    this.agentMediaIndex = index;
    this.agentMediaUri = this.agentMediaUris[index];
    if (this.demoStage === 'playback' && this.agentMediaKind === 'video') this.demoVideoUri = this.agentMediaUri;
    this.emit();
  }

  private async downloadForPreview(kind: MediaKind, token: CancellationToken): Promise<string> {
    const telemetry = this.session.snapshot().telemetry;
    if (this.nativeTasks.activeOrUnknown() || (telemetry.cameraAgeMs ?? Infinity) > 1000 ||
      telemetry.camera?.recordingCandidate !== false) throw new Error('请等待拍摄任务结束、相机空闲后再取回素材');
    if (this.captureMedia.hasPending(kind)) {
      this.captureMedia.markReady(kind);
      return this.retrieveCapture(kind, token);
    }
    const sessionId = this.session.sessionId();
    const downloaded = await this.camera.downloadLatest(kind, this.outputDirectory, token);
    if (!downloaded.ok || downloaded.data === undefined) throw new Error(downloaded.error?.message ?? '下载失败');
    if (token.isCancelled() || sessionId !== this.session.sessionId()) throw new Error('素材取回已取消或飞机会话发生变化');
    this.presentAgentMedia(kind, downloaded.data);
    return `最新${kind === 'photo' ? '照片' : '录像'}已取回`;
  }

  private async pollAutomaticMedia(): Promise<void> {
    if (!this.videoSessionEnabled || this.session.snapshot().phase !== 'ready') return;
    const progress = this.nativeTasks.observeProgress();
    if (progress !== undefined) this.log(progress);
    const taskActive = this.nativeTasks.activeOrUnknown();
    const telemetry = this.session.snapshot().telemetry;
    this.camera.observeTelemetry(telemetry);
    this.captureMedia.observe(telemetry, taskActive);
    const kind = this.captureMedia.readyKind();
    const flight = this.flight.snapshot();
    if ((flight.landRequested || flight.landSent) && ((telemetry.flightAgeMs ?? Infinity) > 1000 ||
      telemetry.flight?.airborne !== false || telemetry.flight?.motorsOn !== false)) return;
    const planning = this.latestAgentRequestId.length > 0 && this.latestAgentRequestId !== this.acceptedAgentRequestId;
    if (kind === undefined || this.busyValue || taskActive || planning || this.pendingAgentAction !== undefined ||
      this.vlmFramePending || this.speech.isListeningOnce() || this.camera.snapshot().operationActive) return;
    await this.run('自动取回本次素材', async (token: CancellationToken) => {
      try { return success(await this.retrieveCapture(kind, token)); }
      catch (error) {
        this.agentFeedback = `自动取回未完成：${asError(error).message}`;
        return failure<string>(ErrorLayer.TASK, 'MEDIA_RETURN_PENDING', this.agentFeedback);
      }
    });
  }

  openDollyDemo(): void {
    if (this.demoStage === 'closed') {
      this.demoStage = 'opening';
      this.demoMessage = '正在检查起飞条件…';
      this.demoVideoUri = '';
      this.demoCandidate = undefined;
    }
    this.emit();
  }

  async captureAgentObservation(): Promise<AgentObservation> {
    const sessionId = this.session.sessionId();
    const generation = this.flight.snapshot().generation;
    const controlGeneration = this.agentGeneration;
    this.pendingAgentAction = undefined;
    await this.waitForAutomaticSubjectScan();
    let frame: VlmFrame | undefined;
    if (this.video.snapshot().state === 'live') {
      try { frame = await this.captureVlmFrame(); }
      catch (error) { this.log(`动作请求未附图像：${asError(error).message}`); }
    }
    if (sessionId !== this.session.sessionId() || generation !== this.flight.snapshot().generation ||
      controlGeneration !== this.agentGeneration || !this.session.isReliableLinkFresh()) {
      throw new Error('飞机连接或控制状态已变化');
    }
    const state = this.session.snapshot();
    const native = this.nativeTasks.snapshot();
    const telemetry = state.telemetry;
    const requestedAtMs = Date.now();
    this.pendingAgentAction = undefined;
    this.agentFeedback = '';
    this.latestAgentRequestId = `${sessionId}-${generation}-${requestedAtMs}-${++this.agentRequestSequence}`;
    return {
      requestId: this.latestAgentRequestId,
      sessionId: sessionId, flightGeneration: generation, controlGeneration: controlGeneration,
      requestedAtMs: requestedAtMs, frame: frame,
      context: {
        phase: state.phase, airborne: telemetry.flight?.airborne ?? false,
        flightStateFresh: (telemetry.flightAgeMs ?? Infinity) <= 1000,
        flightMode: telemetry.flight?.modeRaw, tracking: telemetry.subject?.tracking ?? false,
        currentSubjectId: trackedSubjectId(telemetry.subject), taskKind: native.kind,
        taskPrepared: native.prepared, taskActive: native.activeOrUnknown,
        cameraIdle: (telemetry.cameraAgeMs ?? Infinity) <= 1000 && telemetry.camera?.recordingCandidate === false,
        recording: telemetry.camera?.recordingCandidate ?? this.camera.snapshot().recordingRequested,
        radiusMeters: this.nativeConfig.radiusMeters, framing: this.nativeConfig.framing,
        zoom: this.nativeConfig.zoom, retreat: this.nativeConfig.retreat, movementSeconds: this.defaultMovementSeconds
      }
    };
  }

  private async waitForAutomaticSubjectScan(): Promise<void> {
    const deadline = Date.now() + 9000;
    while (Date.now() < deadline) {
      const state = this.session.snapshot();
      const subject = state.telemetry.subject;
      if (!this.isOrdinarySubjectHover(state, this.flight.snapshot()) || subject?.tracking ||
        state.telemetry.camera?.recordingCandidate !== false || this.camera.snapshot().recordingRequested ||
        (this.autoScanRequestedGeneration === this.flight.snapshot().generation &&
          subject?.scanStateRaw === 1 && state.telemetry.task?.modeRaw === 0)) return;
      if (this.busyValue && !this.autoScanRunning) throw new Error('当前操作未结束，请稍后重试');
      await this.pollAutoSubjectScan();
      if (this.autoScanFailures >= 3) return;
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
    }
  }

  private ensureAgentObservation(observation: AgentObservation, command: AgentAction): void {
    validateAgentResponse({ version: 2, requestId: observation.requestId, command: command }, observation,
      this.session.sessionId(), this.flight.snapshot().generation, Date.now());
    if (observation.controlGeneration !== this.agentGeneration || !this.session.isReliableLinkFresh()) {
      throw new Error('动作已取消或飞机连接已变化');
    }
  }

  async acceptAgentResponse(observation: AgentObservation, response: AgentResponse): Promise<AgentOutcome> {
    validateAgentResponse(response, observation, this.session.sessionId(), this.flight.snapshot().generation, Date.now());
    if (observation.requestId !== this.latestAgentRequestId || observation.requestId === this.acceptedAgentRequestId) {
      throw new Error('该动作已处理或已被新请求替代');
    }
    this.acceptedAgentRequestId = observation.requestId;
    const command = response.command as AgentAction;
    this.ensureAgentObservation(observation, command);
    if (command.action === 'move' && command.seconds === undefined) command.seconds = observation.context.movementSeconds;
    if (command.action === 'dolly_zoom') {
      command.framing = command.framing ?? observation.context.framing;
      command.zoom = command.zoom ?? observation.context.zoom;
      command.retreat = command.retreat ?? observation.context.retreat;
    }
    if (command.action === 'circle') command.radiusMeters = command.radiusMeters ?? observation.context.radiusMeters;
    validateAgentAction(command, observation);
    if (agentNeedsConfirmation(command)) {
      if (this.busyValue) throw new Error('当前操作未结束，请稍后重试');
      this.pendingAgentAction = { observation: observation, command: command,
        expiresAt: Math.min(Date.now() + 10000, observation.requestedAtMs + 20000) };
      this.agentFeedback = `请确认执行「${agentActionLabel(command)}」`;
      this.emit();
      return { message: this.agentFeedback, confirmationRequired: true };
    }
    return this.performAgentAction(observation, command);
  }

  async confirmAgentAction(): Promise<AgentOutcome> {
    const pending = this.pendingAgentAction;
    this.pendingAgentAction = undefined;
    this.emit();
    if (pending === undefined || Date.now() > pending.expiresAt) throw new Error('没有有效的待确认动作');
    return this.performAgentAction(pending.observation, pending.command);
  }

  cancelAgentAction(): void {
    this.pendingAgentAction = undefined;
    this.agentGeneration++;
    this.acceptedAgentRequestId = this.latestAgentRequestId;
    this.agentFeedback = '语音动作已取消';
    this.emit();
  }

  finishAgentObservation(requestId: string): void {
    if (requestId === this.latestAgentRequestId) this.acceptedAgentRequestId = requestId;
  }

  async saveAgentMedia(context: Context): Promise<void> {
    if (this.agentMediaSaving) throw new Error('正在保存到图库，请稍候');
    const uri = this.agentMediaUri;
    const kind = this.agentMediaKind;
    const group = this.agentMediaUris;
    if (uri.length === 0 || (kind !== 'photo' && kind !== 'video')) throw new Error('没有可以保存的原片');
    this.agentMediaSaving = true;
    this.emit();
    try {
      await this.gallerySaver.save(context, uri, kind as MediaKind);
      if (this.agentMediaUris === group && group.includes(uri)) {
        this.agentMediaUris = group.filter(item => item !== uri);
        this.agentMediaIndex = Math.max(0, Math.min(this.agentMediaIndex, this.agentMediaUris.length - 1));
        this.agentMediaUri = this.agentMediaUris[this.agentMediaIndex] ?? '';
        if (this.agentMediaUris.length === 0) this.agentMediaKind = '';
      } else if (this.agentMediaUri === uri && this.agentMediaUris.length === 0) {
        this.agentMediaUri = '';
        this.agentMediaKind = '';
      }
      this.agentFeedback = '已保存到图库';
      this.log('原片已保存到系统图库');
    } finally {
      this.agentMediaSaving = false;
      this.emit();
    }
  }

  private async performAgentAction(observation: AgentObservation, command: AgentAction): Promise<AgentOutcome> {
    this.ensureAgentObservation(observation, command);
    if (command.action === 'none') return { message: command.message ?? '请说一个明确的动作' };
    if (command.action === 'takeoff' || command.action === 'land') return this.performVoiceFlightAction(command.action);
    if (command.action === 'stop' || command.action === 'record_stop') {
      if (command.action === 'stop') await this.center();
      else await this.stopRecording();
      if (this.lastErrorValue.length > 0) throw new Error(this.lastErrorValue);
      return { message: command.action === 'stop' ? '停止请求已处理，请核对飞机状态' :
        this.agentFeedback };
    }
    let outcome: AgentOutcome | undefined;
    let executionError = '已有操作正在执行';
    await this.run<string>(agentActionLabel(command), async (token: CancellationToken) => {
      try {
        this.ensureAgentObservation(observation, command);
        outcome = await this.requestAgentExecution(observation, command, token);
        return success(outcome.message);
      } catch (error) {
        executionError = asError(error).message;
        return failure<string>(ErrorLayer.TASK, 'AGENT_ACTION_FAILED', executionError);
      }
    });
    if (outcome === undefined) throw new Error(executionError);
    this.agentFeedback = outcome.message;
    this.emit();
    return outcome;
  }

  async executeLocalFlightVoice(text: string): Promise<AgentOutcome | undefined> {
    const action = parseDirectFlightVoice(text);
    return action === undefined ? undefined : this.performVoiceFlightAction(action);
  }

  private async performVoiceFlightAction(action: DirectFlightAction): Promise<AgentOutcome> {
    if (action === 'takeoff') {
      if (this.busyValue) throw new Error('当前操作正在执行，未排队起飞');
      const state = this.session.snapshot();
      const telemetry = state.telemetry;
      if (state.phase !== 'ready') throw new Error('请先完成飞机连接与初始化');
      if ((telemetry.flightAgeMs ?? Infinity) > 1000 || telemetry.flight === undefined) {
        throw new Error('尚无新鲜飞行状态，未发送起飞请求');
      }
      if (telemetry.flight.airborne !== false || telemetry.flight.motorsOn !== false) {
        throw new Error('飞机尚未处于落地停桨状态，未重复发送起飞请求');
      }
      await this.takeoffConfirmed();
    } else await this.land();
    if (this.lastErrorValue.length > 0) throw new Error(this.lastErrorValue);
    const message = action === 'takeoff' ? '飞机已确认起飞请求' : '飞机已确认降落请求';
    this.agentFeedback = message; this.emit();
    return { message: message };
  }

  private async requestAgentExecution(observation: AgentObservation, command: AgentAction,
    token: CancellationToken): Promise<AgentOutcome> {
    switch (command.action) {
      case 'select_subject': {
        const frame = observation.frame as VlmFrame;
        if (trackedSubjectId(this.session.snapshot().telemetry.subject) !== frame.currentSubjectId) {
          throw new Error('当前锁定已变化，请重新说一次');
        }
        agentResult(await this.requestSubjectSelection(token, command.subjectId));
        return { message: `已选中主体 #${command.subjectId}`, subjectId: command.subjectId };
      }
      case 'cancel_subject':
        agentResult(await this.requestSubjectSelection(token));
        return { message: '飞机已确认取消主体请求' };
      case 'set_dolly':
        this.applyAgentDollySettings(command);
        return { message: `已设置 ${this.nativeConfig.framing} / ${this.nativeConfig.zoom} 倍 / 渐远${this.nativeConfig.retreat ? '开' : '关'}` };
      case 'dolly_zoom':
        return this.startAgentDolly(observation, command, token);
      case 'follow':
        return this.startAgentSubjectTask('follow', observation, command, token);
      case 'prepare_dolly':
        this.applyAgentDollySettings(command);
        agentResult(await this.nativeTasks.prepare('dolly', this.nativeConfig, token));
        return { message: '本轮滑动变焦已在地面准备，可以普通起飞后选人拍摄' };
      case 'circle': {
        if (this.nativeTasks.activeOrUnknown()) throw new Error('请先停止当前原生任务');
        const radius = command.radiusMeters ?? this.nativeConfig.radiusMeters;
        this.nativeConfig = { radiusMeters: radius, framing: this.nativeConfig.framing,
          zoom: this.nativeConfig.zoom, retreat: this.nativeConfig.retreat };
        if (this.session.snapshot().telemetry.flight?.airborne) {
          await this.handoffCompletedNativeTask(observation, token);
          await this.releaseHoverTaskTarget(observation, token);
          agentResult(await this.nativeTasks.prepareHover('circle', this.nativeConfig, token));
        } else agentResult(await this.nativeTasks.prepare('circle', this.nativeConfig, token));
        return { message: agentResult(await this.startNativeWithCapture(token)) };
      }
      case 'photo': {
        if (this.nativeTasks.activeOrUnknown()) throw new Error('请先停止原生任务，再拍照');
        if (command.subjectId !== undefined) {
          this.ensureAgentPhotoSession(observation, token);
          const frame = observation.frame as VlmFrame;
          const subject = this.session.snapshot().telemetry.subject;
          if (trackedSubjectId(subject) !== frame.currentSubjectId) throw new Error('当前锁定已变化，请重新发起拍照');
          this.agentFeedback = `正在确认主体 #${command.subjectId} 的跟踪框…`; this.emit();
          if (trackedSubjectId(subject) !== command.subjectId) {
            agentResult(await this.requestSubjectSelection(token, command.subjectId));
          }
          await this.waitAgentPhotoTarget(command.subjectId, observation, token);
        }
        if (trackedSubjectId(this.session.snapshot().telemetry.subject) !== undefined) {
          this.agentFeedback = '目标已确认，正在结束跟踪并切回普通悬停…'; this.emit();
          agentResult(await this.requestSubjectSelection(token));
          await this.waitAgentPhotoHover(observation, token);
        }
        this.nativeTasks.cancel();
        this.voice.cancelPending();
        this.agentFeedback = '正在切换拍照模式并拍摄…'; this.emit();
        const message = agentResult(await this.shootAndRetrieve(token));
        return { message: message };
      }
      case 'record_start':
        return { message: agentResult(await this.beginRecording(token)) };
      case 'download_photo': case 'download_video': {
        const kind: MediaKind = command.action === 'download_photo' ? 'photo' : 'video';
        const telemetry = this.session.snapshot().telemetry;
        if (this.nativeTasks.activeOrUnknown() || (telemetry.cameraAgeMs ?? Infinity) > 1000 ||
          telemetry.camera?.recordingCandidate !== false) throw new Error('请等待拍摄结束和新鲜的相机空闲状态，再下载原片');
        return { message: await this.downloadForPreview(kind, token) };
      }
      case 'move':
        if (this.nativeTasks.activeOrUnknown()) throw new Error('请先停止当前原生任务');
        agentResult(await this.flight.move(command.direction as MovementDirection, command.seconds as number, token));
        return { message: `已完成${agentActionLabel(command)}并回中` };
      default: throw new Error('没有可执行的动作');
    }
  }

  private ensureAgentPhotoSession(observation: AgentObservation, token: CancellationToken): void {
    if (token.isCancelled() || this.session.sessionId() !== observation.sessionId ||
      this.flight.snapshot().generation !== observation.flightGeneration ||
      observation.controlGeneration !== this.agentGeneration || !this.session.isReliableLinkFresh()) {
      throw new Error('拍摄已取消或飞机会话发生变化');
    }
  }

  private async waitAgentPhotoTarget(target: number, observation: AgentObservation,
    token: CancellationToken): Promise<void> {
    const deadline = Date.now() + 4000;
    let stableSince: number | undefined;
    while (Date.now() < deadline) {
      this.ensureAgentPhotoSession(observation, token);
      const subject = this.session.snapshot().telemetry.subject;
      const now = Date.now();
      if (subject?.selectedIdCandidate === target && trackedSubjectId(subject) === target &&
        now - (subject.trackingAt ?? 0) <= 500 && now - (subject.detectionAt ?? 0) <= 500) {
        stableSince = stableSince ?? now;
        if (now - stableSince >= 500) return;
      } else {
        stableSince = undefined;
      }
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 50));
    }
    throw new Error('目标未持续锁定，未发送拍照请求');
  }

  private async waitAgentPhotoHover(observation: AgentObservation, token: CancellationToken): Promise<void> {
    const deadline = Date.now() + 4000;
    while (Date.now() < deadline) {
      this.ensureAgentPhotoSession(observation, token);
      const telemetry = this.session.snapshot().telemetry;
      const task = telemetry.task;
      const manualTask = task !== undefined &&
        ((task.phaseRaw === 0 && task.modeRaw === 0) || ([0, 5].includes(task.phaseRaw) && task.modeRaw === 9));
      if ((telemetry.flightAgeMs ?? Infinity) <= 1000 && telemetry.flight?.modeRaw === 6 &&
        telemetry.flight.airborne && telemetry.flight.motorsOn && (telemetry.taskAgeMs ?? Infinity) <= 1000 &&
        manualTask && telemetry.subject?.tracking !== true) return;
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 50));
    }
    throw new Error('结束跟踪后未确认普通悬停，未发送拍照请求');
  }

  private applyAgentDollySettings(command: AgentAction, allowHover: boolean = false): void {
    if (this.nativeTasks.activeOrUnknown()) throw new Error('请先停止当前原生任务');
    const config: NativeTaskConfig = { radiusMeters: this.nativeConfig.radiusMeters,
      framing: command.framing ?? this.nativeConfig.framing, zoom: command.zoom ?? this.nativeConfig.zoom,
      retreat: command.retreat ?? this.nativeConfig.retreat };
    const changed = config.framing !== this.nativeConfig.framing || config.zoom !== this.nativeConfig.zoom ||
      config.retreat !== this.nativeConfig.retreat;
    if (changed) {
      const telemetry = this.session.snapshot().telemetry;
      const flight = this.flight.snapshot();
      const hover = allowHover && flight.takeoffAcknowledged && !flight.nativeTaskMayFly && !flight.movementActive &&
        !flight.landRequested && !flight.landSent && telemetry.flight?.airborne === true &&
        telemetry.flight.motorsOn && [6, 26].includes(telemetry.flight.modeRaw);
      if ((telemetry.flightAgeMs ?? Infinity) > 1000 || (!hover && (telemetry.flight?.airborne || telemetry.flight?.motorsOn))) {
        throw new Error('修改滑动变焦参数需要落地停桨后重新准备');
      }
      this.nativeTasks.cancel();
      this.nativeConfig = config;
    }
  }

  private async startAgentDolly(observation: AgentObservation, command: AgentAction,
    token: CancellationToken): Promise<AgentOutcome> {
    return this.startAgentSubjectTask('dolly', observation, command, token);
  }

  private async handoffCompletedNativeTask(observation: AgentObservation, token: CancellationToken): Promise<void> {
    if (!this.flight.snapshot().nativeTaskMayFly) return;
    this.ensureAgentPhotoSession(observation, token);
    if (this.captureMedia.hasPending('video')) throw new Error('请先取回上一轮录像，再开始下一次拍摄');
    agentResult(this.nativeTasks.canCompleteForHover());
    if (trackedSubjectId(this.session.snapshot().telemetry.subject) !== observation.frame?.currentSubjectId) {
      throw new Error('上一轮锁定状态已变化，请重新发起拍摄');
    }
    await this.releaseHoverTaskTarget(observation, token);
    this.ensureAgentPhotoSession(observation, token);
    agentResult(this.nativeTasks.completeForHover());
    this.log('上一轮任务已结束，已归还普通悬停控制，可准备下一次拍摄');
  }

  private async releaseHoverTaskTarget(observation: AgentObservation, token: CancellationToken): Promise<void> {
    this.ensureAgentPhotoSession(observation, token);
    if (trackedSubjectId(this.session.snapshot().telemetry.subject) !== undefined) {
      this.agentFeedback = '正在退出主体跟踪，准备悬停任务…'; this.emit();
      agentResult(await this.requestSubjectSelection(token));
      await this.waitAgentPhotoHover(observation, token);
    }
    this.ensureAgentPhotoSession(observation, token);
  }

  private async startAgentSubjectTask(kind: NativeTaskKind, observation: AgentObservation, command: AgentAction,
    token: CancellationToken): Promise<AgentOutcome> {
    if (this.nativeTasks.activeOrUnknown()) throw new Error('请先停止当前原生任务');
    const state = this.session.snapshot().telemetry;
    if ((state.flightAgeMs ?? Infinity) > 1000 || state.flight === undefined) throw new Error('飞行遥测尚未就绪');
    if (!state.flight.airborne && !state.flight.motorsOn) {
      if (command.subjectId !== undefined) throw new Error('请先起飞扫描主体，再指定拍摄目标');
      if (kind === 'dolly') this.applyAgentDollySettings(command);
      agentResult(await this.nativeTasks.prepare(kind, this.nativeConfig, token));
      return { message: agentResult(await this.startNativeWithCapture(token)) };
    }
    const candidates = observation.frame?.candidates;
    const target = command.subjectId ?? observation.frame?.currentSubjectId ??
      (candidates?.length === 1 ? candidates[0].id : undefined);
    if (target === undefined) throw new Error('请先指定或锁定拍摄主体');
    if (trackedSubjectId(state.subject) !== observation.frame?.currentSubjectId) throw new Error('锁定状态已变化，请重新发起');
    await this.handoffCompletedNativeTask(observation, token);
    if (kind === 'dolly') this.applyAgentDollySettings(command, true);
    await this.releaseHoverTaskTarget(observation, token);
    this.agentFeedback = `正在悬停准备${this.taskLabel(kind)}…`; this.emit();
    this.log(`悬停准备${this.taskLabel(kind)}，目标 #${target}，${this.nativeConfig.framing}/${this.nativeConfig.zoom}倍`);
    agentResult(await this.nativeTasks.prepareHover(kind, this.nativeConfig, token));
    this.ensureAgentPhotoSession(observation, token);
    const task = this.session.snapshot().telemetry.task;
    if (task?.modeRaw === 9 && [0, 5].includes(task.phaseRaw)) {
      agentResult(await this.requestHoverSubjectScan(token, true));
    }
    this.agentFeedback = `正在锁定主体 #${target}，确认后启动${this.taskLabel(kind)}…`; this.emit();
    agentResult(await this.requestSubjectSelection(token, target));
    return { message: agentResult(await this.startNativeWithCapture(token, target)) };
  }

  async captureVlmFrame(): Promise<VlmFrame> {
    if (this.vlmFramePending) throw new Error('已有图传取帧请求正在处理');
    if (this.video.snapshot().state !== 'live') throw new Error('实时图传尚未就绪');
    const sessionId = this.session.sessionId();
    const before = this.session.snapshot().telemetry.subject;
    this.vlmFramePending = true;
    try {
      const ticket = nativeVideo.requestFrame();
      if (ticket === 0) throw new Error('图传解码器尚未就绪');
      const deadline = Date.now() + 600;
      while (Date.now() < deadline && this.session.sessionId() === sessionId && this.session.isReliableLinkFresh()) {
        const frame = nativeVideo.takeFrame(ticket);
        if (frame === undefined) {
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 16));
          continue;
        }
        if (frame.rgba.byteLength === 0) throw new Error('设备未提供可读取的解码帧');
        const report = closestFrameSubjects(frame.capturedAtMs, before, this.session.snapshot().telemetry.subject);
        if (report === undefined || report.detectionAt === undefined) throw new Error('没有时间匹配的候选回报');
        markVlmCandidates(frame.rgba, frame.width, frame.height, report.candidates);
        const pixels = await image.createPixelMap(frame.rgba, { size: { width: frame.width, height: frame.height },
          srcPixelFormat: image.PixelMapFormat.RGBA_8888, pixelFormat: image.PixelMapFormat.RGBA_8888 });
        try {
          const packer = image.createImagePacker();
          try {
            const jpeg = await packer.packToData(pixels, { format: 'image/jpeg', quality: 85 });
            if (this.session.sessionId() !== sessionId || !this.session.isReliableLinkFresh()) throw new Error('取帧期间飞机会话已变化');
            return { jpeg: jpeg, width: frame.width, height: frame.height, sessionId: sessionId,
              capturedAtMs: frame.capturedAtMs, candidatesObservedAtMs: report.detectionAt, candidates: report.candidates,
              currentSubjectId: trackedSubjectId(report) };
          } finally { await packer.release(); }
        } finally { await pixels.release(); }
      }
      throw new Error('实时图传取帧超时或会话已断开');
    } finally { this.vlmFramePending = false; }
  }

  async takeoffForDollyDemo(): Promise<void> {
    if (this.demoStage !== 'opening') return;
    if (this.busyValue) { this.failDollyTakeoff('请等待当前操作完成。'); this.emit(); return; }
    await this.run<string>('运镜预览起飞', async (token: CancellationToken) => {
      this.demoStage = 'preflight';
      this.demoSessionId = this.session.sessionId();
      const initial = this.session.snapshot().telemetry;
      const flight = this.flight.snapshot();
      if (!this.session.isActionLinkFresh() || initial.flight === undefined ||
        (initial.flightAgeMs ?? Infinity) > 1000 || initial.flight.airborne || initial.flight.motorsOn ||
        flight.takeoffSent || flight.nativeTaskMayFly || flight.landRequested || flight.landSent) {
        return this.failDollyTakeoff('需要已初始化的连接和新鲜的落地停桨状态。');
      }
      this.demoMessage = '正在准备变焦、录像模式和媒体目录…';
      this.emit();
      try {
        const prepared = await this.nativeTasks.prepare('dolly', this.nativeConfig, token);
        if (!prepared.ok || !this.dollyPreflightCurrent(token)) {
          return this.failDollyTakeoff(prepared.error?.message ?? '准备已取消');
        }
        const before = await this.media.listMedia(token);
        if (!before.ok || before.data === undefined || !this.dollyPreflightCurrent(token)) {
          return this.failDollyTakeoff(before.error?.message ?? '媒体目录未确认，未起飞');
        }
        this.demoMediaBefore = new Set<string>(before.data.map(entry => entry.path));
        const ground = this.session.snapshot().telemetry;
        const video = this.video.snapshot();
        if (ground.flight === undefined || (ground.flightAgeMs ?? Infinity) > 1000 ||
          ground.flight.airborne || ground.flight.motorsOn) return this.failDollyTakeoff('飞行状态已变化，未发送起飞');
        if (video.state !== 'live' || video.stats.lastRenderedAgeMs > 1000) {
          return this.failDollyTakeoff('弹窗图传尚未出画面，未发送起飞。');
        }
        this.demoMessage = '正在起飞，等待飞机进入悬停…';
        this.emit();
        const launched = await this.flight.takeoff(true, token);
        if (!launched.ok || !this.dollyPreflightCurrent(token)) {
          return this.failDollyTakeoff(launched.error?.message ?? '起飞流程已中断，请查看飞机状态');
        }
        const deadline = Date.now() + 15000;
        let hoverSince: number | undefined;
        let hoverConfirmed = false;
        while (this.dollyPreflightCurrent(token) && Date.now() < deadline) {
          const state = this.session.snapshot();
          const task = state.telemetry.task;
          if (this.isOrdinarySubjectHover(state, this.flight.snapshot()) && task?.phaseRaw === 5 && task.modeRaw === 9) {
            const now = Date.now();
            hoverSince = hoverSince ?? now;
            if (now - hoverSince >= 2000) { hoverConfirmed = true; break; }
          } else {
            hoverSince = undefined;
          }
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
        }
        if (!this.dollyPreflightCurrent(token)) return this.failDollyTakeoff('预览流程已中断');
        if (!hoverConfirmed) return this.failDollyTakeoff('未确认普通悬停状态，请查看飞机状态或降落。');
        this.demoMessage = '正在等待飞机进入候选扫描…';
        this.emit();
        if (!this.dollyPreflightCurrent(token)) return this.failDollyTakeoff('预览流程已中断');
        const stopSentAt = Date.now();
        // Match the original hover trial. Sending through NativeTaskService.stop would discard ground preparation.
        const stopped = await this.session.requestNative(0x92, 0x23, 0x15, new Uint8Array(0), 1000, token);
        if (!this.dollyPreflightCurrent(token) || stopped === undefined || stopped.length !== 1 || stopped[0] !== 0) {
          return this.failDollyTakeoff('悬停停止对照未获确认，请查看飞机状态或降落。');
        }
        this.log('运镜预览：飞机已确认停止对照，等待任务空闲和扫描回报');
        const previewDeadline = Date.now() + 15000;
        while (this.dollyPreflightCurrent(token) && Date.now() < previewDeadline) {
          const state = this.session.snapshot();
          const preview = this.video.snapshot();
          const subject = state.telemetry.subject;
          const task = state.telemetry.task;
          if (this.isOrdinarySubjectHover(state, this.flight.snapshot()) && subject?.candidateCount === 1 &&
            task?.phaseRaw === 0 && task.modeRaw === 0 && task.observedAtMs >= stopSentAt &&
            subject.scanStateRaw === 1 && (subject.scanObservedAt ?? -1) >= stopSentAt &&
            (subject.detectionAt ?? -1) >= stopSentAt &&
            subject.candidates[0].id <= 255 &&
            preview.state === 'live' && preview.stats.lastRenderedAgeMs <= 1000) {
            this.demoCandidate = subject.candidates[0];
            this.demoStage = 'confirm';
            this.demoMessage = '飞机已悬停，请确认画面后开始运镜。';
            return success(this.demoMessage);
          }
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
        }
        return this.failDollyTakeoff('未同时收到任务空闲、扫描开启和唯一候选回报，请检查现场或降落。');
      } catch (error) {
        return this.failDollyTakeoff(asError(error as Error).message);
      }
    });
  }

  private dollyPreflightCurrent(token: CancellationToken): boolean {
    return !token.isCancelled() && this.demoStage === 'preflight' && this.session.sessionId() === this.demoSessionId;
  }

  private failDollyTakeoff(message: string): OperationResult<string> {
    this.demoStage = 'failed';
    this.demoMessage = message;
    return failure<string>(ErrorLayer.TASK, 'DEMO_PREFLIGHT_FAILED', message);
  }

  private dollyDemoHasTrack(state: DroneSessionSnapshot, target?: number): boolean {
    const telemetry = state.telemetry;
    const subject = telemetry.subject;
    return target !== undefined && (telemetry.flightAgeMs ?? Infinity) <= 1000 &&
      telemetry.flight?.modeRaw === 26 && telemetry.flight.airborne && telemetry.flight.motorsOn &&
      (telemetry.taskAgeMs ?? Infinity) <= 1000 && telemetry.task?.phaseRaw === 0 && telemetry.task.modeRaw === 0 &&
      subject?.tracking === true && subject.overlay.length === 1 && subject.overlay[0].id === target;
  }

  closeDollyDemo(): void {
    if (this.busyValue || this.demoStage === 'starting' || this.demoStage === 'shooting') return;
    this.demoStage = 'closed';
    this.emit();
  }

  async confirmDollyDemo(): Promise<void> {
    if (this.demoStage !== 'confirm' || this.busyValue) return;
    await this.run<string>('拍摄希区柯克运镜', async (token: CancellationToken) => {
      const state = this.session.snapshot();
      const target = this.demoCandidate?.id;
      const task = this.nativeTasks.snapshot();
      const preview = this.video.snapshot();
      const flight = this.flight.snapshot();
      const tracking = this.dollyDemoHasTrack(state, target);
      const scanning = this.isOrdinarySubjectHover(state, flight) && state.telemetry.task?.phaseRaw === 0 &&
        state.telemetry.task.modeRaw === 0 && state.telemetry.subject?.scanStateRaw === 1 &&
        state.telemetry.subject.candidateCount === 1 && state.telemetry.subject.candidates[0].id === target;
      if (target === undefined || this.session.sessionId() !== this.demoSessionId ||
        !this.session.isActionLinkFresh() || !flight.takeoffSent || flight.nativeTaskMayFly || flight.movementActive ||
        flight.landRequested || flight.landSent || this.nativeTasks.activeOrUnknown() || (!scanning && !tracking) ||
        preview.state !== 'live' || preview.stats.lastRenderedAgeMs > 1000) {
        this.demoMessage = '需要实时画面和本轮悬停状态才能确认拍摄。';
        this.log(`运镜确认：模式 ${state.telemetry.flight?.modeRaw ?? '无'}，任务 ${state.telemetry.task?.payloadHex ?? '无'}，` +
          `扫描 ${state.telemetry.subject?.scanStateRaw ?? '无'}，目标 ${target ?? '无'}，` +
          `跟踪 ${tracking ? '匹配' : '未匹配'}，图传 ${preview.state}`);
        return failure<string>(ErrorLayer.TASK, 'DEMO_NOT_READY', this.demoMessage);
      }
      if (task.kind !== 'dolly' || !task.prepared) {
        this.demoMessage = '本轮变焦准备已失效，请降落后再试。';
        return failure<string>(ErrorLayer.TASK, 'DEMO_AIRBORNE_NOT_READY', this.demoMessage);
      }
      this.demoStage = 'starting';
      this.demoMessage = '正在确认飞机跟踪画面中的主体…';
      this.demoSawExecution = false;
      this.demoStartAt = undefined;
      this.emit();
      try {
        const selection = tracking ? success('复用飞机当前跟踪') : await this.requestSubjectSelection(token, target);
        if (this.demoStage !== 'starting') return selection;
        if (!selection.ok || (!tracking && this.selectedSubjectId !== target) || token.isCancelled()) {
          this.demoStage = 'failed';
          this.demoMessage = selection.error?.message ?? '飞机未回传匹配的跟踪框，未启动运镜。';
          const current = this.session.snapshot().telemetry;
          this.log(`运镜选人 #${target}：回报编号 ${current.subject?.selectedIdCandidate ?? '无'}，` +
            `跟踪框 ${current.subject?.tracking ? current.subject.overlay.map(box => box.id).join(',') : '无'}，` +
            `飞行模式 ${current.flight?.modeRaw ?? '无'}，任务 ${current.task?.payloadHex ?? '无'}`);
          return failure<string>(ErrorLayer.TASK, 'DEMO_TARGET_UNCONFIRMED', this.demoMessage);
        }
        this.demoMessage = '正在切换滑动变焦模式，等待飞机状态确认…';
        this.emit();
        const result = await this.startNativeWithCapture(token, target);
        if (this.demoStage !== 'starting') return result;
        const started = this.nativeTasks.snapshot().startedAtMs;
        this.demoStartAt = started !== task.startedAtMs ? started : undefined;
        this.demoStage = this.demoStartAt === undefined ? 'confirm' : 'shooting';
        this.demoMessage = result.ok ? '等待飞机回报开始拍摄…' : result.error?.message ?? '启动状态未确认';
        return result;
      } catch (error) {
        this.demoStage = 'failed';
        this.demoMessage = asError(error as Error).message;
        return failure<string>(ErrorLayer.TASK, 'DEMO_START_FAILED', this.demoMessage);
      }
    });
  }

  private updateDollyDemo(session: DroneSessionSnapshot, task: NativeTaskSnapshot): void {
    if (this.demoStage !== 'shooting' || this.demoStartAt === undefined) return;
    if (session.phase !== 'ready' || this.session.sessionId() !== this.demoSessionId || task.startedAtMs !== this.demoStartAt) {
      this.demoStage = 'failed';
      this.demoMessage = '飞机会话已变化，无法确认本次拍摄结果。';
      return;
    }
    if (task.executionObserved) {
      this.demoSawExecution = true;
      this.demoMessage = '正在拍摄…';
    }
    const telemetry = session.telemetry;
    const native = telemetry.task;
    const camera = telemetry.camera;
    if (this.demoSawExecution && native !== undefined && native.observedAtMs > this.demoStartAt &&
      (telemetry.taskAgeMs ?? Infinity) <= 1000 && ['0000000101', '0000000102'].includes(native.payloadHex) &&
      camera !== undefined && (telemetry.cameraAgeMs ?? Infinity) <= 1000 && !camera.recordingCandidate) {
      this.demoStage = 'recorded';
      this.demoMessage = '飞机已结束拍摄，可以查看本次录像。';
    } else if (Date.now() - this.demoStartAt > 120000) {
      this.demoStage = 'failed';
      this.demoMessage = '未确认拍摄结束，请查看飞机状态。';
    }
  }

  async viewDollyDemoVideo(): Promise<void> {
    if (this.demoStage !== 'recorded' || this.busyValue) return;
    await this.run<string>('查看本次拍摄', async (token: CancellationToken) => {
      this.demoStage = 'downloading';
      this.demoMessage = '正在查找本次录像…';
      this.emit();
      try {
        if (this.captureMedia.hasPending('video')) {
          this.captureMedia.markReady('video');
          return success(await this.retrieveCapture('video', token));
        }
        for (let attempt = 0; attempt < 3 && !token.isCancelled(); attempt++) {
          if (this.session.sessionId() !== this.demoSessionId || !this.session.isReliableLinkFresh()) break;
          const listed = await this.media.listMedia(token);
          if (token.isCancelled() || this.session.sessionId() !== this.demoSessionId) break;
          const entry = listed.data?.find(candidate => candidate.kind === 'video' && !this.demoMediaBefore.has(candidate.path));
          if (entry !== undefined) {
            const telemetry = this.session.snapshot().telemetry;
            if ((telemetry.cameraAgeMs ?? Infinity) > 1000 || telemetry.camera?.recordingCandidate !== false) {
              this.demoStage = 'recorded';
              this.demoMessage = '请等待飞机相机结束录像后再下载。';
              return failure<string>(ErrorLayer.TASK, 'DEMO_CAMERA_NOT_IDLE', this.demoMessage);
            }
            this.demoMessage = '正在从飞机下载原片…';
            this.emit();
            const result = await this.media.downloadEntry(entry, this.outputDirectory, token);
            if (!token.isCancelled() && result.ok && result.data !== undefined) {
              this.demoVideoUri = fileUri.getUriFromPath(result.data.path);
              this.demoStage = 'playback';
              this.demoMessage = '本次录像已下载';
              return success(this.demoMessage);
            }
            this.demoMessage = result.error?.message ?? '下载已取消';
            this.demoStage = 'recorded';
            return failure<string>(ErrorLayer.TASK, 'DEMO_DOWNLOAD_FAILED', this.demoMessage);
          }
          if (!listed.ok) break;
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 800));
        }
        this.demoMessage = '尚未取得本次新增录像，可重新点击查看视频。';
      } catch (error) {
        this.demoMessage = asError(error as Error).message;
      }
      this.demoStage = 'recorded';
      return failure<string>(ErrorLayer.TASK, 'DEMO_VIDEO_UNAVAILABLE', this.demoMessage);
    });
  }

  private cancelOperations(): void {
    this.pendingAgentAction = undefined;
    this.agentGeneration++;
    this.operationToken?.cancel(); this.nativeTasks.cancel(); this.voice.cancelPending();
    if (this.demoStage === 'preflight' || this.demoStage === 'confirm' || this.demoStage === 'starting' || this.demoStage === 'shooting') {
      this.demoStage = 'failed';
      this.demoMessage = '拍摄流程已中断，请查看飞机状态。';
    }
  }
  private taskLabel(kind: NativeTaskKind): string { return kind === 'circle' ? '环绕' : kind === 'follow' ? '跟随' : '滑动变焦'; }

  setVoiceEnabled(enabled: boolean): void {
    this.voice.setEnabled(enabled);
    if (!enabled) {
      this.cancelOperations();
      this.flight.centerSticks().catch((error: Error) => this.recordException('语音关闭回中', error));
      this.speech.stop(false).catch((error: Error) => this.recordException('关闭本地语音', error));
    }
    this.log(enabled ? '本地语音命令已启用' : '本地语音命令已禁用');
    this.emit();
  }

  async startListening(): Promise<void> {
    if (!this.voice.snapshot().enabled) {
      this.log('请先启用语音命令');
      this.emit();
      return;
    }
    try {
      await this.speech.start();
    } catch (error) {
      this.recordException('启动本地语音', error instanceof Error ? error : new Error(String(error)));
    }
    this.emit();
  }

  listenForSubjectDescription(ready: () => void, followUp: boolean): Promise<string> {
    return this.speech.listenOnce(ready, followUp);
  }

  async stopSubjectDescription(): Promise<void> { await this.speech.cancelOnce(); }

  async stopListening(): Promise<void> {
    try {
      await this.speech.stop(false);
    } catch (error) {
      this.recordException('停止本地语音', error instanceof Error ? error : new Error(String(error)));
    }
    this.emit();
  }

  submitTranscript(text: string): void {
    this.voice.acceptTranscript(text);
    this.log(this.voice.snapshot().feedback); this.emit();
  }

  confirmPendingVoice(): void {
    this.voice.confirmPending();
    this.emit();
  }

  async foregroundOnlySafetyShutdown(): Promise<void> {
    this.captureMedia.reset();
    this.videoSessionEnabled = false;
    this.video.setSession('');
    const task = this.nativeTasks.snapshot(); this.cancelOperations();
    try {
      await this.speech.stop(false);
    } catch (error) {
      this.recordException('后台语音清理', error instanceof Error ? error : new Error(String(error)));
    }
    this.voice.setEnabled(false);
    this.log('应用进入后台，执行回中/降落保护并断开');
    if (task.busy || task.prepared || task.activeOrUnknown) this.recordResult('停止原生任务', await this.nativeTasks.stop());
    await this.flight.foregroundOnlySafetyShutdown();
    await this.wifi.leave();
    this.wifiProgressValue = '后台安全断开完成';
    this.emit();
  }

  private profileChangesAllowed(): boolean {
    return !this.busyValue && this.session.snapshot().phase === 'disconnected';
  }

  private rejectProfileChange(message: string): void {
    this.lastErrorLayerValue = 'task';
    this.lastErrorValue = message;
    this.log(message);
    this.emit();
  }

  private async executeVoice(command: VoiceCommand): Promise<void> {
    if (command.kind === 'land') return this.land();
    if (['center', 'circle_stop', 'follow_stop', 'dolly_stop'].includes(command.kind)) return this.center();
    if (command.kind === 'pause') { this.setVoiceEnabled(false); return this.center(); }
    if (command.kind === 'status') { this.log(`连接${this.session.snapshot().phase}；${this.nativeTasks.snapshot().kind}执行${this.nativeTasks.snapshot().executionObserved ? '已观察' : '未观察'}`); this.emit(); return; }
    if (command.kind === 'takeoff' || command.kind === 'takeoff_again') return this.takeoffConfirmed();
    if (command.kind === 'circle_prepare') return this.prepareNative('circle');
    if (command.kind === 'follow_prepare') return this.prepareNative('follow');
    if (command.kind === 'dolly_prepare') return this.prepareNative('dolly');
    if (command.kind === 'circle_start') {
      if (command.radiusMeters !== undefined) {
        if (this.busyValue || this.nativeTasks.activeOrUnknown()) { this.log('先停止当前任务'); this.emit(); return; }
        this.setTaskSettings(command.radiusMeters, this.nativeConfig.framing, this.nativeConfig.zoom, this.nativeConfig.retreat);
      }
      return this.startNativeConfirmed('circle');
    }
    if (command.kind === 'follow_start') return this.startNativeConfirmed('follow');
    if (command.kind === 'dolly_start') return this.startNativeConfirmed('dolly');
    if (command.kind === 'circle_radius' || command.kind === 'dolly_framing' || command.kind === 'dolly_zoom' || command.kind === 'dolly_retreat') {
      this.setTaskSettings(command.kind === 'circle_radius' ? command.radiusMeters ?? 2 : this.nativeConfig.radiusMeters,
        command.kind === 'dolly_framing' ? command.value as DollyFraming : this.nativeConfig.framing,
        command.kind === 'dolly_zoom' ? Number(command.value) : this.nativeConfig.zoom,
        command.kind === 'dolly_retreat' ? command.value === 'on' : this.nativeConfig.retreat); return;
    }
    if (command.kind === 'photo') return this.shoot();
    if (command.kind === 'record_start') return this.startRecording();
    if (command.kind === 'record_stop') return this.stopRecording();
    if (command.kind === 'media_list') return this.listMedia();
    if (command.kind === 'download_photo') return this.downloadLatest('photo');
    if (command.kind === 'download_video') return this.downloadLatest('video');
    if (command.kind === 'move' && command.direction !== undefined) {
      const segments = this.motion.plan(command); const direction = command.direction;
      await this.run(`移动 ${direction} ${segments.reduce((sum: number, value: number) => sum + value, 0).toFixed(1)}s`, async (token: CancellationToken) => {
        for (let i = 0; i < segments.length; i++) {
          if (token.isCancelled()) return failure<boolean>(ErrorLayer.TASK, 'VOICE_MOVE_CANCELLED', '移动已取消');
          const result = await this.flight.move(direction, segments[i], token);
          if (!result.ok) return result;
        }
        return success(true);
      });
    }
  }

  private async run<T>(name: string, operation: (token: CancellationToken) => Promise<OperationResult<T>>,
    rejectWhenBusy: boolean = true): Promise<void> {
    if (this.busyValue && rejectWhenBusy) {
      this.log(`${name}: 已有操作执行中`);
      this.emit();
      return;
    }
    this.pendingAgentAction = undefined;
    const token = this.flight.newCancellationToken();
    if (rejectWhenBusy) this.operationToken = token;
    this.activeOperations++; this.busyValue = true;
    this.lastOperationValue = name;
    this.emit();
    try {
      this.recordResult(name, await operation(token));
    } catch (error) {
      this.recordException(name, error as Error);
    } finally {
      if (this.operationToken === token) this.operationToken = undefined;
      this.activeOperations--; this.busyValue = this.activeOperations > 0;
      this.emit();
    }
  }

  private recordResult<T>(name: string, result: OperationResult<T>): void {
    if (result.ok) {
      this.lastErrorLayerValue = '';
      this.lastErrorValue = '';
      this.log(`${name}: ${typeof result.data === 'string' ? result.data : '完成'}`);
    } else {
      this.lastErrorLayerValue = result.error?.layer ?? 'unknown';
      this.lastErrorValue = result.error?.message ?? '未知错误';
      this.log(`${name}: ${this.lastErrorLayerValue}/${result.error?.code ?? 'UNKNOWN'} ${this.lastErrorValue}`);
    }
    this.emit();
  }

  private recordException(name: string, error: Error): void {
    this.lastErrorLayerValue = 'internal';
    this.lastErrorValue = error.message;
    this.log(`${name}: ${error.message}`);
    this.emit();
  }

  private log(message: string): void {
    const stamp = new Date().toLocaleTimeString();
    this.logsValue.unshift(`${stamp}  ${message}`);
    if (this.logsValue.length > 80) this.logsValue.pop();
    hilog.info(0x0000, 'NeoApp', '%{public}s', message);
  }

  private emit(): void {
    const listener = this.listener;
    if (listener !== undefined) listener(this.snapshot());
  }
}

function agentResult<T>(result: OperationResult<T>): T {
  if (!result.ok || result.data === undefined) throw new Error(result.error?.message ?? '操作未确认完成');
  return result.data;
}

function asError(error: Object): Error {
  return error instanceof Error ? error : new Error(String(error));
}

export class AppRuntime {
  private static controllerValue?: AppController;

  static initialize(filesDirectory: string, context: Context): AppController {
    if (AppRuntime.controllerValue === undefined) {
      AppRuntime.controllerValue = new AppController(filesDirectory, context);
    }
    return AppRuntime.controllerValue;
  }

  static controller(): AppController {
    if (AppRuntime.controllerValue === undefined) {
      throw new Error('App runtime has not been initialized');
    }
    return AppRuntime.controllerValue;
  }
}
