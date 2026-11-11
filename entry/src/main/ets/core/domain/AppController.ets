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
import { common } from '@kit.AbilityKit';
import { GalleryVideoReceiver } from '../media/GalleryVideoReceiver';
import { systemGalleryPort } from '../platform/SystemGallery';
import { CloudVlmKeyStore } from '../platform/CloudVlmKeyStore';
import { CloudVlmClient } from '../platform/CloudVlmClient';
import { SelfReferencePhotoStore } from '../platform/SelfReferencePhotoStore';
import { isSelfSubjectRequest } from './SelfReference';
import { CaptureMedia } from '../media/CaptureMedia';
import { MediaDownloadResult } from '../media/MediaDownloader';
import { CancellationToken, ErrorLayer, failure, OperationResult, success } from './OperationResult';
import { MovementDirection } from '../protocol/StickCodec';
import { VoiceCommand, VoiceCommandAdapter, VoiceCommandSnapshot } from './VoiceCommandAdapter';
import { Context } from '@kit.AbilityKit';
import { LocalSpeechRecognizer } from '../platform/LocalSpeechRecognizer';
import { AircraftProfileStore, AircraftProfileSummary } from '../profile/AircraftProfileStore';
import { NeoWifiLink } from '../platform/NeoWifiLink';
import { SubjectBox, SubjectSnapshot, selectedSubjectOverlay } from './SubjectObservation';
import { SubjectTaskWorkflow, SubjectTaskSnapshot, SubjectTaskPort } from './SubjectTaskWorkflow';
import { normalizeDroneUtterance } from './VoiceUtterance';
import { CloseupSequence, CloseupSequenceSnapshot, CloseupSequencePort } from './CloseupSequence';
import { CloseupMediaGroup } from '../media/CloseupMediaGroup';
import { CloseupSubjectGuard } from './CloseupSubjectGuard';
import { MovementStep, runMovementSequence } from './MovementSequence';
import { MovieComposer, MovieCompositionSnapshot } from '../media/MovieComposer';
import { movieMediaReady, movieSourceReady } from '../media/MovieEligibility';
import { NativeMovieFiles, nativeMoviePort } from '../platform/NativeMovieExport';
import { image } from '@kit.ImageKit';
import { canApplyVlmSelection, FrameSubjectChangedError, matchFrameSubjects, markVlmCandidates,
  trackedSubjectId, VlmFrame } from '../media/VlmFrame';
import { AgentAction, AgentObservation, AgentOutcome, AgentResponse, DirectFlightAction, parseDirectFlightVoice, parseDirectStopVoice, agentActionLabel, agentNeedsConfirmation,
  actionNeedsSubjectSelection, agentObservationTimeoutMs, validateAgentAction, validateAgentResponse } from './AgentAction';

export interface ConsoleSnapshot {
  movie: MovieCompositionSnapshot;
  moviePreparing: boolean;
  movieSaving: boolean;
  movieCanCompose: boolean;
  closeup: CloseupSequenceSnapshot;
  subjectTask: SubjectTaskSnapshot;
  groundDolly: SubjectTaskSnapshot;
  dollyDemo: DollyDemoSnapshot;
  aircraftProfiles: AircraftProfileSummary[];
  selectedAircraftId: string;
  wifiProgress: string;
  connectionReady: boolean;
  connectionFrameReady: boolean;
  connectionRecovering: boolean;
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
  agentMediaUris: string[];
  agentVideoResultReady: boolean;
  videoCapturePending: boolean;
  cloudVlmConfigured: boolean;
  cloudVlmStatus: string;
  subjectScanStatus: string;
  selectedSubjectOverlay: SubjectBox[];
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
  private readonly movieComposer: MovieComposer = new MovieComposer(nativeMoviePort());
  private readonly movieFiles: NativeMovieFiles = new NativeMovieFiles();
  private moviePreparing: boolean = false;
  private moviePreparationEpoch: number = 0;
  private movieSaving: boolean = false;
  private movieSourceIdentity: string = '';
  private movieSourceRevision: string = '';
  private movieCachedKey: string = '';
  private movieCacheAttemptKey: string = '';
  private movieTimer?: number;
  private readonly closeupSequence = new CloseupSequence((): void => this.emit());
  private readonly closeupMedia = new CloseupMediaGroup();
  // Legacy field/API aliases share this single generic owner; no dolly-only selection state remains.
  private readonly groundDolly = new SubjectTaskWorkflow((): void => this.emit());
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
  private previewPollAt: number = 0;
  private videoDiagnosticsAt: number = 0;
  private previewMaxLagMs: number = 0;
  private videoSessionEnabled: boolean = false;
  private connectionRecoveryReason: string = '';
  private readyConnectionSession?: number;
  private connectionAttempt?: Promise<void>;
  private connectionEpoch: number = 0;
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
  private movementSequenceToken?: CancellationToken;
  private agentRequestSequence: number = 0;
  private latestAgentRequestId: string = '';
  private acceptedAgentRequestId: string = '';
  private pendingAgentAction?: PendingAgentAction;
  private agentFeedback: string = '';
  private agentMediaUri: string = '';
  private agentMediaKind: string = '';
  private agentMediaSaving: boolean = false;
  private agentMediaUris: string[] = [];
  private agentVideoResultReady: boolean = false;
  private agentMediaIndex: number = 0;
  private readonly cloudKeys: CloudVlmKeyStore = new CloudVlmKeyStore();
  private readonly cloudVlm: CloudVlmClient;
  private cloudInitialized: boolean = false;
  private cloudInitialization?: Promise<void>;
  private cloudVlmConfigured: boolean = false;
  private cloudVlmStatus: string = '手机直连DeepSeek，等待读取配置';
  private readonly gallerySaver: GallerySaver = new GallerySaver();
  private readonly galleryVideoReceiver: GalleryVideoReceiver = new GalleryVideoReceiver();
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
  private captureRecoveryToken?: CancellationToken;
  private readonly motion: VoiceMotion = new VoiceMotion();
  private nativeConfig: NativeTaskConfig = { radiusMeters: 2, framing: '半身', zoom: 2, retreat: true };
  private lastOperationValue: string = '等待连接';
  private lastErrorLayerValue: string = '';
  private lastErrorValue: string = '';
  private logsValue: string[] = [];
  private wifiProgressValue: string = '等待选择飞机';

  constructor(filesDirectory: string, context: Context) {
    this.outputDirectory = filesDirectory;
    try {
      if (typeof nativeVideo.setDiagnosticDirectory === 'function') {
        const directory = `${filesDirectory}/video-diagnostics`;
        if (!fileIo.accessSync(directory)) fileIo.mkdirSync(directory);
        nativeVideo.setDiagnosticDirectory(directory);
      }
    } catch (error) { this.log(`视频诊断目录未启用：${asError(error).message}`); }
    this.cloudVlm = new CloudVlmClient(this.cloudKeys, new SelfReferencePhotoStore(context));
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
    this.previewPollAt = Date.now();
    if (listener !== undefined) this.previewTimer = setInterval(() => {
      const now = Date.now();
      this.previewMaxLagMs = Math.max(this.previewMaxLagMs, Math.max(0, now - this.previewPollAt - 250));
      this.previewPollAt = now;
      this.pollAutomaticMedia().catch((error: Error) => this.recordException('自动取回原片', error));
      this.pollAutoSubjectScan().catch((error: Error) => this.recordException('自动扫描', error));
      this.logVideoDiagnostics(now);
      this.emit();
    }, 250);
    this.emit();
  }

  private logVideoDiagnostics(now: number): void {
    if (now - this.videoDiagnosticsAt < 5000) return;
    const session = this.session.snapshot();
    if (!['handshaking', 'registering', 'ready'].includes(session.phase)) return;
    const preview = this.video.snapshot();
    const stats = preview.stats;
    if (stats.assembledFrames <= 0 && session.videoAgeMs === undefined) return;
    this.videoDiagnosticsAt = now;
    this.log(`图传诊断：会话=${session.sessionHex}，阶段=${session.phase}，UDP累计=${session.receivedDatagrams}，` +
      `下行/视频年龄=${session.downlinkAgeMs ?? -1}/${session.videoAgeMs ?? -1}ms，` +
      `组帧待收/丢帧/无效/重复=${session.video.pending}/${session.video.droppedFrames}/${session.video.invalidPackets}/${session.video.duplicatePackets}，` +
      `界面延迟峰值=${Math.round(this.previewMaxLagMs)}ms，预览=${preview.state}，` +
      `解码快照=${JSON.stringify(stats)}`);
    this.previewMaxLagMs = 0;
  }

  snapshot(): ConsoleSnapshot {
    this.syncMovieSources();
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
    const result: ConsoleSnapshot = {
      movie: this.movieComposer.snapshot(), moviePreparing: this.moviePreparing, movieSaving: this.movieSaving,
      movieCanCompose: false,
      closeup: this.closeupSequence.snapshot(),
      subjectTask: this.groundDolly.snapshot(),
      groundDolly: this.groundDolly.snapshot(),
      dollyDemo: { stage: this.demoStage, message: this.demoMessage, videoUri: this.demoVideoUri, candidate: candidate },
      aircraftProfiles: this.profiles.list(),
      selectedAircraftId: this.profiles.selectedId(),
      wifiProgress: this.wifiProgressValue,
      connectionReady: this.connectionControlReady(),
      connectionFrameReady: this.previewReady(),
      connectionRecovering: this.connectionAttempt !== undefined,
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
      agentMediaUris: this.agentMediaUris.slice(),
      agentVideoResultReady: this.agentVideoResultReady,
      videoCapturePending: this.captureMedia.hasPending('video'),
      cloudVlmConfigured: this.cloudVlmConfigured, cloudVlmStatus: this.cloudVlmStatus,
      subjectScanStatus: this.autoScanMessage,
      selectedSubjectOverlay: selectedSubjectOverlay(subject, this.selectedSubjectId)
    };
    result.movieCanCompose = movieSourceReady(result);
    return result;
  }

  private syncMovieSources(): void {
    const sources = this.agentVideoResultReady && this.agentMediaKind === 'video' ? this.agentMediaUris : [];
    const identity = JSON.stringify(sources);
    if (identity === this.movieSourceIdentity) { this.restoreCurrentCachedMovie(); return; }
    this.moviePreparationEpoch++;
    this.movieSourceIdentity = identity;
    this.movieSourceRevision = this.movieFiles.revision(sources);
    this.movieComposer.setSources(sources, this.movieSourceRevision);
    this.movieCachedKey = '';
    this.movieCacheAttemptKey = '';
    const movie = this.movieComposer.snapshot();
    this.restoreCurrentCachedMovie();
    if (movie.busy) this.ensureMoviePolling();
  }

  private restoreCurrentCachedMovie(): void {
    const movie = this.movieComposer.snapshot();
    if (movie.sources.length === 0 || movie.busy || movie.stage !== 'idle' || this.movieCacheAttemptKey === movie.sourceKey) return;
    this.movieCacheAttemptKey = movie.sourceKey;
    const cache = this.movieFiles.loadCompleted(this.outputDirectory, movie.sourceKey);
    if (cache !== undefined && this.movieComposer.restoreCompleted(movie.sources, this.movieSourceRevision, cache.outputPath, cache.durationMs)) {
      this.movieCachedKey = cache.sourceKey;
    }
  }

  async composeMovie(context: common.UIAbilityContext): Promise<void> {
    if (this.moviePreparing) return;
    this.syncMovieSources();
    const before = this.movieComposer.snapshot();
    if (before.busy || before.stage === 'completed') return;
    if (!movieSourceReady(this.snapshot())) throw new Error('请等待本次拍摄完整完成、全部录像取回后再一键成片');
    this.moviePreparing = true;
    const epoch = ++this.moviePreparationEpoch;
    this.emit();
    try {
      const music = await this.movieFiles.prepareMusic(context, this.outputDirectory);
      if (epoch !== this.moviePreparationEpoch) return;
      this.syncMovieSources();
      if (this.movieComposer.snapshot().sourceKey !== before.sourceKey || !movieMediaReady(this.snapshot())) {
        throw new Error('本次素材已变更，请对当前拍摄结果重新一键成片');
      }
      this.movieComposer.start(this.movieFiles.newOutputPath(this.outputDirectory), music);
      this.log('小艺开始本地一键成片，使用自选音轨；保留全部原片');
      this.ensureMoviePolling();
    } finally { this.moviePreparing = false; this.emit(); }
  }

  cancelMovie(): void {
    this.moviePreparationEpoch++;
    this.movieComposer.cancel();
    this.emit();
  }

  private ensureMoviePolling(): void {
    if (this.movieTimer !== undefined) return;
    this.movieTimer = setInterval(() => {
      this.syncMovieSources();
      this.movieComposer.poll();
      this.syncMovieSources();
      const movie = this.movieComposer.snapshot();
      if (movie.stage === 'completed' && movie.sourceKey !== this.movieCachedKey) {
        try {
          this.movieFiles.saveCompleted(this.outputDirectory, movie, this.movieSourceRevision);
          this.movieCachedKey = movie.sourceKey;
          this.log(`本地成片已生成，${(movie.durationMs / 1000).toFixed(1)}秒，使用自选音轨`);
        } catch (error) { this.log(`成片已生成，缓存清单未保存：${asError(error).message}`); }
      }
      if (!movie.busy) {
        clearInterval(this.movieTimer); this.movieTimer = undefined;
        if (movie.stage === 'failed') this.log(`本地成片失败：${movie.error}`);
      }
      this.emit();
    }, 250);
  }

  async saveMovieToGallery(context: common.UIAbilityContext): Promise<void> {
    if (this.movieSaving || this.agentMediaSaving) throw new Error('正在保存素材，请稍候');
    const movie = this.movieComposer.snapshot();
    if (movie.stage !== 'completed' || movie.outputPath.length === 0 || movie.durationMs <= 0) throw new Error('成片尚未制作完成');
    const uri = this.movieFiles.playableUri(movie.outputPath);
    this.movieSaving = true; this.emit();
    try {
      await this.galleryVideoReceiver.save([uri], systemGalleryPort(context));
      this.log('成片已保存至相册，保留原片和对话内预览');
    } finally { this.movieSaving = false; this.emit(); }
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
    const epoch = this.connectionEpoch;
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
        const localMovie = this.movieComposer?.snapshot();
        const keepLocalResult = localMovie !== undefined &&
          (localMovie.stage !== 'idle' || localMovie.busy || this.moviePreparing) && movieSourceReady(this.snapshot());
        this.flight.resetForAircraftSession();
        this.hoverScanAttempted = false;
        this.selectedSubjectId = undefined;
        this.nativeTasks.resetForAircraftSession();
        this.camera.resetForAircraftSession();
        this.captureMedia.reset();
        this.agentGeneration++;
        this.pendingAgentAction = undefined;
        if (!keepLocalResult) {
          this.agentMediaUri = '';
          this.agentMediaKind = '';
          this.agentMediaUris = [];
          this.agentVideoResultReady = false;
          this.agentMediaIndex = 0;
        }
        this.retireCloseup();
        this.groundDolly?.retireInactive();
        this.agentFeedback = keepLocalResult ? '已保留本地拍摄结果，可继续播放、成片或保存至相册' : '';
        this.wifiProgressValue = '检查目标飞机 Wi-Fi';
        this.emit();
        const selection = await this.wifi.join(runtime, (message: string) => {
          this.wifiProgressValue = message;
          this.emit();
        });
        if (epoch !== this.connectionEpoch) {
          await this.wifi.leave();
          return failure<DroneSessionSnapshot>(ErrorLayer.NETWORK, 'CONNECTION_CANCELLED', '连接已取消');
        }
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
  async initialize(): Promise<void> {
    await this.run('初始化', async () => {
      const sessionId = this.session.sessionId();
      // The aircraft can provide its first decodable keyframe only after the
      // control connection is usable. Visual actions check previewReady separately.
      const result = await this.session.initialize(15000);
      if (this.session.sessionId() === sessionId) {
        this.connectionRecoveryReason = result.ok ? '' : result.error?.message ?? '连接初始化未完成';
        if (result.ok) this.readyConnectionSession = sessionId;
      }
      return result;
    });
  }

  private previewReady(): boolean {
    const preview = this.video.snapshot();
    const stats = preview.stats;
    return preview.state === 'live' && stats.running && !stats.waitingForKey && !stats.recoveryPaused &&
      stats.lastRenderedAgeMs >= 0 && stats.lastRenderedAgeMs <= 1000;
  }

  private connectionHealthy(): boolean {
    return this.connectionControlReady() && this.previewReady();
  }

  private connectionControlReady(): boolean {
    return !this.connectionRecoveryReason && this.session.isStartupReady?.() === true;
  }

  private canRetryInitialRegistration(state: DroneSessionSnapshot): boolean {
    const telemetry = state.telemetry;
    if (!['registering', 'failed'].includes(state.phase) || state.deviceVerified !== false ||
      this.readyConnectionSession === this.session.sessionId() ||
      telemetry.flight !== undefined || telemetry.task !== undefined || telemetry.camera !== undefined) return false;
    const flight = this.flight.snapshot();
    const camera = this.camera.snapshot();
    const task = this.nativeTasks.snapshot();
    // Missing telemetry is never proof of landing. This narrowly permits a new
    // handshake before this session has ever established control or issued an action.
    return flight.takeoffSent === false && flight.takeoffAcknowledged === false && flight.nativeTaskMayFly === false &&
      flight.movementActive === false && flight.landRequested === false && flight.landSent === false &&
      flight.landAcknowledged === false && flight.nativeStartedAtMs === undefined &&
      camera.operationActive === false && camera.recordingRequested === false &&
      task.busy === false && task.prepared === false && task.startedAtMs === undefined &&
      this.nativeTasks.activeOrUnknown() === false;
  }

  async ensureReadyConnection(): Promise<void> {
    if (this.connectionAttempt !== undefined) return this.connectionAttempt;
    if (this.busyValue) return;
    const attempt = this.establishReadyConnection();
    this.connectionAttempt = attempt;
    this.emit();
    try { await attempt; }
    finally {
      if (this.connectionAttempt === attempt) this.connectionAttempt = undefined;
      this.emit();
    }
  }

  private async establishReadyConnection(): Promise<void> {
    const epoch = this.connectionEpoch;
    const state = this.session.snapshot();
    const phase = state.phase;
    const failedExistingSession = phase === 'failed' &&
      (state.transport !== undefined || state.deviceVerified || state.telemetry.flight !== undefined);
    if (phase === 'ready' || failedExistingSession) {
      if (phase === 'ready' && this.connectionHealthy()) return;
      await this.recoverGroundedConnection(epoch);
      return;
    }
    if (phase === 'disconnected' || phase === 'failed') await this.connectSelectedAircraft();
    if (epoch !== this.connectionEpoch) return;
    if (!this.busyValue && this.session.snapshot().phase === 'registering') {
      await this.initialize();
      if (epoch === this.connectionEpoch && !this.connectionHealthy() && !this.busyValue &&
        this.session.snapshot().phase === 'registering') {
        await this.recoverGroundedConnection(epoch);
      }
    }
  }

  private async recoverGroundedConnection(epoch: number): Promise<void> {
    const state = this.session.snapshot();
    const telemetry = state.telemetry;
    const camera = this.camera.snapshot();
    const groundedIdle = (telemetry.flightAgeMs ?? Infinity) <= 1000 &&
      telemetry.flight?.airborne === false && telemetry.flight.motorsOn === false &&
      (telemetry.cameraAgeMs ?? Infinity) <= 1000 && telemetry.camera?.recordingCandidate === false &&
      !camera.recordingRequested && !camera.operationActive && !this.flight.snapshot().movementActive &&
      !this.nativeTasks.activeOrUnknown();
    if (this.busyValue || (!groundedIdle && !this.canRetryInitialRegistration(state))) {
      this.agentFeedback = '连接尚未就绪；请确认落地停桨、录像和任务结束后，再点击连接飞机恢复';
      this.log(this.agentFeedback); this.emit(); return;
    }
    this.log(`${groundedIdle ? '地面重建连接' : '初始注册未完成，重新握手'}：` +
      `${this.connectionRecoveryReason || '图传或飞行、任务、相机状态未就绪'}`);
    this.cancelOperations();
    this.videoSessionEnabled = false;
    this.video.setSession('');
    // No flight, task or camera command is replayed. A new handshake resets both
    // the aircraft stream session and our decoder's retained configuration.
    await this.session.disconnect();
    if (epoch !== this.connectionEpoch) return;
    await this.connectSelectedAircraft();
    if (epoch !== this.connectionEpoch) return;
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
      `降落=${flight.landRequested === true || flight.landSent === true}，` +
      `起飞请求/确认=${flight.takeoffSent}/${flight.takeoffAcknowledged}，` +
      `空中/电机=${state.telemetry.flight?.airborne ?? '未知'}/${state.telemetry.flight?.motorsOn ?? '未知'}，` +
      `连接/身份=${state.phase}/${state.deviceVerified}，` +
      `链路/图传新鲜=${(state.downlinkAgeMs ?? Infinity) <= 1000}/${(state.videoAgeMs ?? Infinity) <= 1000}，` +
      `聆听=${this.speech.isListeningOnce()}，扫描失败次数=${this.autoScanFailures}`;
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
    this.connectionEpoch++;
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
    this.connectionEpoch++;
    const task = this.nativeTasks.snapshot();
    this.cancelOperations();
    await this.run('降落请求', async () => {
      if (task.busy || task.prepared || task.activeOrUnknown) this.recordResult('停止原生任务', await this.nativeTasks.stop());
      return this.flight.land();
    }, false);
  }
  async center(): Promise<void> {
    this.connectionEpoch++;
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
    await this.run(`准备${this.taskLabel(kind)}`, (token: CancellationToken) => this.prepareNativeTask(kind, token));
  }
  private async prepareNativeTask(kind: NativeTaskKind, token: CancellationToken,
    fromHover: boolean = false): Promise<OperationResult<boolean>> {
    const sessionId = this.session.sessionId();
    const result = fromHover ? await this.nativeTasks.prepareHover(kind, this.nativeConfig, token) :
      await this.nativeTasks.prepare(kind, this.nativeConfig, token);
    if (!result.ok && result.error?.code === 'NATIVE_PREPARE_FAILED' && !token.isCancelled() &&
      this.session.sessionId() === sessionId) {
      this.connectionRecoveryReason = result.error.message;
      this.log(`任务参数准备失败，落地停桨后可点击连接飞机重建会话：${result.error.message}`);
    }
    return result;
  }
  async startNativeConfirmed(kind: NativeTaskKind): Promise<void> {
    await this.run(`启动${this.taskLabel(kind)}`, async (token: CancellationToken) => {
      const task = this.nativeTasks.snapshot();
      if (!task.prepared || task.kind !== kind) {
        const prepared = await this.prepareNativeTask(kind, token);
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
    this.agentVideoResultReady = false;
    if (this.closeupSequence?.snapshot().active !== true) this.retireCloseup();
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
    this.agentVideoResultReady = false;
    if (this.closeupSequence?.snapshot().active !== true) this.retireCloseup();
    await this.captureMedia.begin('video', token);
    const result = await this.camera.startRecording(token);
    if (!result.ok && !this.camera.snapshot().recordingRequested) this.captureMedia.discard('video');
    return result;
  }

  private async startNativeWithCapture(token: CancellationToken, selectedTarget?: number,
    videoSequence?: number): Promise<OperationResult<string>> {
    if (videoSequence !== undefined) {
      const sequence = this.closeupSequence.snapshot();
      const kind = this.nativeTasks.snapshot().kind;
      if (!sequence.active || !['dolly', 'circle'].includes(sequence.stage) || kind !== sequence.stage ||
        !this.captureMedia.isVideoSequenceCurrent(videoSequence)) {
        throw new Error('组合录像阶段或序列已失效，未启动任务');
      }
    }
    this.agentVideoResultReady = false;
    if (this.closeupSequence?.snapshot().active !== true) this.retireCloseup();
    if (videoSequence === undefined) await this.captureMedia.begin('video', token);
    else {
      if (this.captureMedia.canContinueVideoSequence(videoSequence)) this.captureMedia.continueVideoSequence(videoSequence, token);
    }
    const previousStart = this.nativeTasks.snapshot().startedAtMs;
    const preparing = this.nativeTasks.snapshot();
    const before = this.session.snapshot().telemetry;
    this.log(`原生任务启动准备：任务=${preparing.kind}，目标=${selectedTarget ?? '无'}，` +
      `配置=${JSON.stringify(preparing.config)}，飞行模式=${before.flight?.modeRaw ?? '无'}，` +
      `任务状态=${before.task?.payloadHex ?? '无'}，相机模式=${before.camera?.modeRaw ?? '无'}，` +
      `校时=${before.camera?.timeSynchronized ?? '无'}，录像状态=${before.camera?.recordStateRaw ?? '无'}`);
    const result = await this.nativeTasks.start(true, token, selectedTarget);
    const started = this.nativeTasks.snapshot();
    this.log(`原生任务启动结果：任务=${started.kind}，成功=${result.ok}，` +
      `startReply=${started.startReply ?? '无'}，启动时间=${started.startedAtMs ?? '无'}，` +
      `之前启动时间=${previousStart ?? '无'}，原因=${result.error?.message ?? '无'}`);
    if (!result.ok && this.nativeTasks.snapshot().startedAtMs === previousStart && videoSequence === undefined) {
      this.captureMedia.discard('video');
    }
    return result;
  }

  private presentAgentMedia(kind: MediaKind, downloaded: MediaDownloadResult): void {
    this.presentAgentMediaGroup(kind, [downloaded]);
  }

  private presentAgentMediaGroup(kind: MediaKind, downloaded: MediaDownloadResult[]): void {
    const received = downloaded.map(item => fileUri.getUriFromPath(item.path));
    this.agentMediaUris = kind === 'video' ? this.closeupMedia.add(received,
      this.session.sessionId(), this.flight.snapshot().generation) : received;
    this.agentMediaIndex = 0;
    this.agentMediaUri = this.agentMediaUris[0];
    this.agentMediaKind = kind;
    this.agentVideoResultReady = kind === 'video';
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

  async captureAgentObservation(waitForScan: boolean = true, lockedSubjectId?: number,
    allowMissingFrame: boolean = false): Promise<AgentObservation> {
    const sessionId = this.session.sessionId();
    const generation = this.flight.snapshot().generation;
    const controlGeneration = this.agentGeneration;
    this.pendingAgentAction = undefined;
    if (waitForScan) await this.waitForAutomaticSubjectScan();
    let frame: VlmFrame | undefined;
    if (this.video.snapshot().state === 'live') {
      try { frame = await this.captureVlmFrame(lockedSubjectId); }
      catch (error) {
        this.log(`动作请求未附图像：${asError(error).message}`);
        if (error instanceof FrameSubjectChangedError) throw error;
        if (lockedSubjectId !== undefined && !allowMissingFrame) {
          throw new Error(`未能复核已确认主体：${asError(error).message}；未启动运镜`);
        }
      }
    }
    if (lockedSubjectId !== undefined && frame === undefined && !allowMissingFrame) {
      throw new Error('实时画面尚未就绪，未能复核已确认主体；未启动运镜');
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

  private async waitForAutomaticSubjectScan(checkCurrent?: () => void): Promise<void> {
    const deadline = Date.now() + 9000;
    while (Date.now() < deadline) {
      checkCurrent?.();
      const state = this.session.snapshot();
      const subject = state.telemetry.subject;
      if (!this.isOrdinarySubjectHover(state, this.flight.snapshot()) || subject?.tracking ||
        state.telemetry.camera?.recordingCandidate !== false || this.camera.snapshot().recordingRequested ||
        (this.autoScanRequestedGeneration === this.flight.snapshot().generation &&
          subject?.scanStateRaw === 1 && state.telemetry.task?.modeRaw === 0)) return;
      if (this.busyValue && !this.autoScanRunning) throw new Error('当前操作未结束，请稍后重试');
      await this.pollAutoSubjectScan();
      checkCurrent?.();
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
    validateAgentAction(command, observation);
    if (actionNeedsSubjectSelection(command)) {
      return this.beginSubjectTask(agentActionLabel(command), command, observation);
    }
    if (agentNeedsConfirmation(command)) {
      if (this.busyValue) throw new Error('当前操作未结束，请稍后重试');
      this.pendingAgentAction = { observation: observation, command: command,
        expiresAt: Math.min(Date.now() + 10000, observation.requestedAtMs + agentObservationTimeoutMs(observation)) };
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
    this.movementSequenceToken?.cancel();
    this.captureRecoveryToken?.cancel();
    this.nativeTasks?.cancel();
    this.closeupSequence?.cancel();
    this.groundDolly?.cancel();
    this.pendingAgentAction = undefined;
    this.agentGeneration++;
    this.cloudVlm?.cancelPending();
    this.acceptedAgentRequestId = this.latestAgentRequestId;
    this.agentFeedback = '语音动作已取消';
    this.emit();
  }

  finishAgentObservation(requestId: string): void {
    if (requestId === this.latestAgentRequestId) this.acceptedAgentRequestId = requestId;
  }

  async acceptVideosInSystemGallery(context: common.UIAbilityContext): Promise<void> {
    if (this.agentMediaSaving) throw new Error('正在保存素材，请稍候');
    if (this.agentMediaKind !== 'video' || this.agentMediaUris.length === 0) throw new Error('本次录像尚未取回');
    const originals = this.agentMediaUris.slice();
    this.agentMediaSaving = true; this.emit();
    try {
      // User explicitly requested immediate gallery handoff, without a grounded-state gate.
      await this.galleryVideoReceiver.accept(originals, systemGalleryPort(context));
    } finally { this.agentMediaSaving = false; this.emit(); }
  }

  async saveVideosToGallery(context: common.UIAbilityContext): Promise<void> {
    if (this.agentMediaSaving) throw new Error('正在保存素材，请稍候');
    if (this.agentMediaKind !== 'video' || this.agentMediaUris.length === 0) throw new Error('本次录像尚未取回');
    const originals = this.agentMediaUris.slice();
    this.agentMediaSaving = true; this.emit();
    try {
      await this.galleryVideoReceiver.save(originals, systemGalleryPort(context));
      this.log(`本次 ${originals.length} 段录像已保存至相册，保留对话内预览`);
    } finally { this.agentMediaSaving = false; this.emit(); }
  }

  async retryCapturedVideo(): Promise<void> {
    if (this.busyValue) throw new Error('正在执行其他操作，请稍候');
    if (!this.captureMedia.hasPending('video')) throw new Error('没有待重试的本次录像');
    await this.run('重试取回本次录像', async (token: CancellationToken) => {
      try { return success(await this.downloadForPreview('video', token)); }
      catch (error) {
        this.agentFeedback = `自动取回未完成：${asError(error).message}`;
        return failure<string>(ErrorLayer.TASK, 'MEDIA_RETURN_PENDING', this.agentFeedback);
      }
    });
    if (this.lastErrorValue.length > 0) throw new Error(this.lastErrorValue);
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

  private async performAgentAction(observation: AgentObservation, command: AgentAction,
    videoSequence?: number): Promise<AgentOutcome> {
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
    if (command.action === 'move_sequence') this.retireInactiveFlightPresentation();
    await this.run<string>(agentActionLabel(command), async (token: CancellationToken) => {
      try {
        this.ensureAgentObservation(observation, command);
        outcome = await this.requestAgentExecution(observation, command, token, videoSequence);
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
    const stop = parseDirectStopVoice(text);
    if (stop !== undefined) {
      if (stop === 'stop') await this.center();
      else await this.stopRecording();
      if (this.lastErrorValue.length > 0) throw new Error(this.lastErrorValue);
      const message = stop === 'stop' ? '停止请求已处理，请核对飞机状态' : this.agentFeedback;
      this.agentFeedback = message; this.emit();
      return { message: message };
    }
    const action = parseDirectFlightVoice(text);
    if (action !== undefined) this.retireInactiveFlightPresentation();
    return action === undefined ? undefined : this.performVoiceFlightAction(action);
  }

  private retireInactiveFlightPresentation(): void {
    const camera = this.camera?.snapshot();
    if (this.busyValue || this.groundDolly?.snapshot().active === true ||
      this.closeupSequence?.snapshot().active === true || this.captureMedia?.hasPending('video') === true ||
      this.nativeTasks.activeOrUnknown() || camera?.operationActive === true || camera?.recordingRequested === true) return;
    // Retire only the old workflow card. Local clips remain the movie job's sources.
    this.groundDolly?.retireInactive();
  }

  async initializeCloudVlm(): Promise<void> {
    if (this.cloudInitialized) return;
    if (this.cloudInitialization === undefined) this.cloudInitialization = this.loadCloudVlm();
    try { await this.cloudInitialization; } finally { this.cloudInitialization = undefined; }
  }

  private async loadCloudVlm(): Promise<void> {
    try {
      await this.cloudKeys.importPrivateFile(`${this.outputDirectory}/cloud-key-import.txt`);
      this.cloudVlmConfigured = (await this.cloudKeys.read()) !== undefined;
      this.cloudVlmStatus = this.cloudVlmConfigured ? '手机直连DeepSeek，密钥已配置' : '尚未配置云端密钥，请长按标题打开设置';
      this.cloudInitialized = true;
    } catch (error) {
      this.cloudVlmStatus = asError(error).message;
      throw asError(error);
    } finally { this.emit(); }
  }

  async saveCloudVlmKey(key: string): Promise<void> {
    this.cancelAgentAction();
    await this.cloudKeys.save(key);
    this.cloudInitialized = true; this.cloudVlmConfigured = true;
    this.cloudVlmStatus = '密钥已保存到手机安全存储'; this.emit();
  }

  async clearCloudVlmKey(): Promise<void> {
    this.cancelAgentAction();
    await this.cloudKeys.clear();
    this.cloudInitialized = true; this.cloudVlmConfigured = false;
    this.cloudVlmStatus = '云端密钥已清除'; this.emit();
  }

  async testCloudVlmConnection(): Promise<void> {
    await this.initializeCloudVlm();
    this.cloudVlmStatus = '正在测试手机到DeepSeek的连接…'; this.emit();
    try {
      const started = Date.now(); await this.cloudVlm.testConnection();
      this.cloudVlmConfigured = true;
      this.cloudVlmStatus = `手机直连正常，耗时${Date.now() - started}毫秒`;
      this.log(this.cloudVlmStatus);
    } catch (error) { this.cloudVlmStatus = asError(error).message; throw asError(error); }
    finally { this.emit(); }
  }

  async runCloudVoiceRequest(description: string): Promise<AgentOutcome> {
    if (this.closeupSequence?.snapshot().active !== true) this.retireCloseup();
    const normalized = normalizeDroneUtterance(description);
    if (normalized !== description) this.log('已纠正语音中的希区柯克同音词，保留原始用户消息');
    description = normalized;
    // Intent classification can use an already available image, but must not wait
    // for subject scanning. Only an authorized shoot enters subject preparation.
    const observation = await this.captureAgentObservation(false);
    try {
      const telemetry = this.session.snapshot().telemetry;
      const grounded = observation.context.flightStateFresh && !observation.context.airborne &&
        telemetry.flight?.motorsOn === false;
      if (grounded) {
        observation.purpose = 'ground_dolly_intent';
        observation.frame = undefined;
      } else observation.purpose = 'shoot_intent';
      this.log(`云端意图阶段=${observation.purpose ?? '普通动作'}，地面停桨=${grounded}，` +
        `空中=${observation.context.airborne}，飞行状态新鲜=${observation.context.flightStateFresh}，候选=${observation.frame?.candidates.length ?? 0}`);
      const response = await this.requestCloudAgentAction(observation, description);
      if (isSelfSubjectRequest(description) && response.command !== undefined &&
        ['photo', 'record_start'].includes(response.command.action)) {
        // An explicit self target must use reference selection even if the model omits the subject flag.
        response.command.subjectRequired = true;
      }
      const pendingSubject = this.groundDolly.snapshot();
      const replacingSubject = response.command?.action === 'select_subject' &&
        ['confirm', 'plan'].includes(pendingSubject.stage);
      if (pendingSubject.active && !replacingSubject &&
        !['stop', 'land', 'record_stop', 'none'].includes(response.command?.action ?? '')) {
        throw new Error('拍摄流程进行中，请确认主体，或取消、降落后重试');
      }
      if (response.command !== undefined && actionNeedsSubjectSelection(response.command)) {
        this.ensureAgentObservation(observation, response.command);
        if (this.closeupSequence?.snapshot().active === true) throw new Error('飞行任务正在执行，请等待结束或先停止任务');
        this.finishAgentObservation(observation.requestId);
        return await this.beginSubjectTask(description, response.command, observation);
      }
      return await this.acceptAgentResponse(observation, response);
    } finally { this.finishAgentObservation(observation.requestId); }
  }

  private async beginSubjectTask(description: string, command: AgentAction,
    observation: AgentObservation): Promise<AgentOutcome> {
    const pending = this.groundDolly.snapshot();
    if (pending.active) {
      if (command.action !== 'select_subject' || !['confirm', 'plan'].includes(pending.stage) || pending.plan === undefined) {
        throw new Error('主体任务流程进行中，请确认主体，或停止、降落后重试');
      }
      command = this.retargetSubjectTask(pending.plan, command);
      this.groundDolly.cancel();
    }
    if (this.closeupSequence?.snapshot().active === true) throw new Error('飞行任务正在执行，请等待结束或先停止任务');
    const state = this.session.snapshot();
    const grounded = observation.context.flightStateFresh && !observation.context.airborne &&
      state.telemetry.flight?.motorsOn === false;
    if (grounded && ['photo', 'record_start', 'select_subject'].includes(command.action)) {
      throw new Error('指定主体需要悬停扫描，请先起飞，再描述要选择的主体；本次未发送起飞请求');
    }
    this.ensureAgentObservation(observation, command);
    if (grounded) await this.recoverPreviousGroundedVideo(observation);
    if (observation.requestId !== this.latestAgentRequestId) {
      throw new Error('本次主体任务请求已被新请求替代，未开始任务');
    }
    this.ensureAgentObservation(observation, command);
    const intent: AgentAction = { action: command.action };
    if (command.action === 'dolly_zoom') {
      intent.framing = command.framing ?? (command.recipe === 'dolly_circle' ? '半身' : observation.context.framing);
      intent.zoom = command.zoom ?? (command.recipe === 'dolly_circle' ? 3 : observation.context.zoom);
      intent.retreat = command.retreat ?? (command.recipe === 'dolly_circle' ? true : observation.context.retreat);
      if (command.recipe !== undefined) intent.recipe = command.recipe;
    }
    if (command.action === 'circle') intent.radiusMeters = command.radiusMeters ?? observation.context.radiusMeters;
    return this.startGroundDolly(description, intent, observation, grounded ? 'ground' : 'hover',
      grounded ? undefined : command);
  }

  private retargetSubjectTask(original: AgentAction, selection: AgentAction): AgentAction {
    const command: AgentAction = { action: original.action };
    if (selection.subjectId !== undefined) command.subjectId = selection.subjectId;
    else if (['photo', 'record_start', 'select_subject'].includes(original.action)) command.subjectRequired = true;
    if (original.action === 'dolly_zoom') {
      if (original.framing !== undefined) command.framing = original.framing;
      if (original.zoom !== undefined) command.zoom = original.zoom;
      if (original.retreat !== undefined) command.retreat = original.retreat;
      if (original.recipe !== undefined) command.recipe = original.recipe;
    }
    if (original.action === 'circle' && original.radiusMeters !== undefined) command.radiusMeters = original.radiusMeters;
    return command;
  }

  private async recoverPreviousGroundedVideo(observation: AgentObservation): Promise<void> {
    if (!this.captureMedia.hasPending('video')) return;
    let recovered = false;
    let recoveryError = '上次拍摄素材正在处理中，请稍后重试';
    const check = (): void => {
      if (this.session.sessionId() !== observation.sessionId || this.agentGeneration !== observation.controlGeneration ||
        this.flight.snapshot().generation !== observation.flightGeneration ||
        this.session.snapshot().phase !== 'ready' || !this.session.isReliableLinkFresh()) {
        throw new Error('整理上次素材已取消或飞机状态已变化');
      }
    };
    await this.run<string>('整理上次拍摄素材', async (token: CancellationToken) => {
      this.captureRecoveryToken = token;
      try {
        check();
        this.agentFeedback = '正在核对上次拍摄的录像目录…';
        this.emit();
        const originals = await this.captureMedia.reconcileGroundedVideo(token, (message: string): void => {
          this.agentFeedback = message;
          this.emit();
        });
        check();
        if (originals.length > 0) this.presentAgentMediaGroup('video', originals);
        const message = originals.length > 0 ? `已保留上次拍摄的${originals.length}段原片，继续本次拍摄` :
          '上次目录确认未生成新录像，已关闭空素材记录，继续本次拍摄';
        recovered = true;
        return success(message);
      } catch (error) {
        recoveryError = asError(error).message;
        return failure<string>(ErrorLayer.TASK, 'PREVIOUS_CAPTURE_RECOVERY_FAILED', recoveryError);
      } finally {
        if (this.captureRecoveryToken === token) this.captureRecoveryToken = undefined;
      }
    });
    if (!recovered) throw new Error(recoveryError);
  }

  private ensureDollyHoverReady(allowCompleted: boolean = false): void {
    const state = this.session.snapshot();
    const telemetry = state.telemetry;
    const flight = this.flight.snapshot();
    const camera = this.camera.snapshot();
    if (this.busyValue || this.nativeTasks.snapshot().busy || camera.operationActive) {
      throw new Error('当前操作尚未结束，请稍后再拍摄');
    }
    if (state.phase !== 'ready' || !state.deviceVerified || !this.session.isReliableLinkFresh() ||
      (state.downlinkAgeMs ?? Infinity) > 1000 || (state.videoAgeMs ?? Infinity) > 1000 ||
      this.video.snapshot().state !== 'live') throw new Error('实时画面或飞机连接尚未就绪，请稍后再拍摄');
    if (!flight.takeoffSent || !flight.takeoffAcknowledged || flight.movementActive || flight.landRequested || flight.landSent ||
      (telemetry.flightAgeMs ?? Infinity) > 1000 || telemetry.flight?.airborne !== true ||
      telemetry.flight.motorsOn !== true || ![6, 26].includes(telemetry.flight.modeRaw)) {
      throw new Error('尚未确认本轮稳定悬停，未开始主体任务');
    }
    if ((telemetry.cameraAgeMs ?? Infinity) > 1000 || telemetry.camera?.recordingCandidate !== false || camera.recordingRequested) {
      throw new Error('相机仍在录制或状态不明确，请等待相机空闲后再拍摄');
    }
    if (this.nativeTasks.activeOrUnknown()) throw new Error('原生任务仍在执行或状态不明确，请等待结束或先停止任务');
    const completed = allowCompleted && flight.nativeTaskMayFly && this.nativeTasks.canCompleteForHover().ok;
    const task = telemetry.task;
    if ((telemetry.taskAgeMs ?? Infinity) > 1000 || task === undefined ||
      (!completed && !((task.phaseRaw === 0 && task.modeRaw === 0) ||
        (telemetry.flight.modeRaw === 6 && [0, 5].includes(task.phaseRaw) && task.modeRaw === 9))) ||
      (flight.nativeTaskMayFly && !completed)) {
      throw new Error('飞行任务尚未恢复悬停就绪，请等待任务结束后重试');
    }
    if (telemetry.flight.modeRaw === 26) {
      const age = Date.now() - (telemetry.subject?.trackingAt ?? 0);
      if (trackedSubjectId(telemetry.subject) === undefined || age < 0 || age > 500) {
        throw new Error('当前主体跟踪尚未稳定，请等待新画面后重试');
      }
    }
  }

  private async startGroundDolly(description: string, intent: AgentAction, ground: AgentObservation,
    entry: 'ground' | 'hover' = 'ground', inferred?: AgentAction): Promise<AgentOutcome> {
    if (entry === 'hover') {
      this.ensureDollyHoverReady(true);
      if (this.captureMedia.hasPending('video')) throw new Error('上一轮录像仍在处理中，请等待取回后再拍摄');
      const observedTarget = ground.frame === undefined ? ground.context.currentSubjectId : ground.frame.currentSubjectId;
      if (trackedSubjectId(this.session.snapshot().telemetry.subject) !== observedTarget) {
        throw new Error('当前锁定已变化，请重新说一次拍摄要求');
      }
      if (this.flight.snapshot().nativeTaskMayFly) {
        let released = false;
        await this.run<string>('准备悬停组合拍摄', async (token: CancellationToken) => {
          try {
            await this.handoffCompletedNativeTask(ground, token); released = true;
            return success('已归还上一轮悬停控制');
          } catch (error) { return failure<string>(ErrorLayer.TASK, 'HOVER_HANDOFF_FAILED',
            `上一轮尚未恢复悬停就绪：${asError(error).message}`); }
        });
        if (!released) throw new Error(this.lastErrorValue || '上一轮悬停控制尚未归还，请稍后重试');
        this.ensureDollyHoverReady();
      }
      if (ground.requestId !== this.latestAgentRequestId) throw new Error('本次拍摄请求已被新请求替代，未开始拍摄');
      this.ensureAgentObservation(ground, inferred ?? intent);
    }
    if (['dolly_zoom', 'follow', 'circle', 'record_start'].includes(intent.action)) this.retireCloseup();
    this.log(`拍摄准备入口=${entry === 'hover' ? '空中悬停' : '地面起飞'}，` +
      `方案=${intent.recipe ?? intent.action}，视觉目标=${inferred?.subjectId ?? '待选'}`);
    if (['dolly_zoom', 'follow', 'circle', 'record_start'].includes(intent.action)) this.agentVideoResultReady = false;
    const sessionId = ground.sessionId;
    const controlGeneration = ground.controlGeneration;
    let flightGeneration = ground.flightGeneration;
    let tookOff = entry === 'hover';
    const isCurrent = (): boolean => {
      const flight = this.flight.snapshot();
      return this.session.sessionId() === sessionId && this.agentGeneration === controlGeneration &&
        flight.generation === flightGeneration && this.session.snapshot().phase === 'ready' &&
        this.session.isReliableLinkFresh() && (!tookOff || (!flight.landRequested && !flight.landSent));
    };
    const check = (): void => { if (!isCurrent()) throw new Error('拍摄流程已取消或飞机状态已变化'); };
    const port: SubjectTaskPort = {
      isCurrent: isCurrent,
      takeoff: async (): Promise<void> => {
        check();
        await this.performVoiceFlightAction('takeoff');
        // takeoffConfirmed may allocate a new flight generation after an earlier landing.
        if (this.session.sessionId() !== sessionId || this.agentGeneration !== controlGeneration) {
          throw new Error('起飞期间拍摄流程已取消');
        }
        flightGeneration = this.flight.snapshot().generation; tookOff = true;
        check();
      },
      waitForCandidates: async (): Promise<void> => {
        const deadline = Date.now() + 30000;
        const checkScanning = (): void => {
          check();
          if (Date.now() >= deadline) throw new Error('悬停扫描未找到候选主体，未开始拍摄；请调整站位后重试或降落');
        };
        while (Date.now() < deadline) {
          checkScanning();
          // Scan preparation may clear an early takeoff candidate. Inspect only
          // the fresh state after that barrier, as captureAgentObservation does.
          await this.waitForAutomaticSubjectScan(checkScanning);
          checkScanning();
          const state = this.session.snapshot();
          const subject = state.telemetry.subject;
          if (entry === 'hover') this.ensureDollyHoverReady();
          const trackingAge = Date.now() - (subject?.trackingAt ?? 0);
          const trackedHover = entry === 'hover' && state.telemetry.flight?.modeRaw === 26 &&
            trackedSubjectId(subject) !== undefined && trackingAge >= 0 && trackingAge <= 500;
          const detectionAge = Date.now() - (subject?.detectionAt ?? 0);
          if (!this.busyValue && (this.isOrdinarySubjectHover(state, this.flight.snapshot()) || trackedHover) &&
            state.telemetry.task?.phaseRaw === 0 && state.telemetry.task.modeRaw === 0 &&
            subject !== undefined && subject.candidates.length > 0 &&
            detectionAge >= 0 && detectionAge <= 500 && this.video.snapshot().state === 'live') return;
          await this.pollAutoSubjectScan();
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
        }
        throw new Error('悬停扫描未找到候选主体，未开始拍摄；请调整站位后重试或降落');
      },
      select: async (text: string, settings: AgentAction): Promise<AgentAction> => {
        check();
        const observation = await this.captureAgentObservation();
        try {
          check();
          this.log(`视觉选人样本：画面=${observation.frame === undefined ? '无' : '有'}，` +
            `候选=${observation.frame?.candidates.length ?? 0}，入口=${entry}`);
          if (observation.frame === undefined || observation.frame.candidates.length === 0) {
            throw new Error('没有可用的主体画面，未开始拍摄');
          }
          let selected: AgentAction;
          if (entry === 'hover' && inferred?.subjectId !== undefined && !isSelfSubjectRequest(text)) {
            // The first airborne inference already saw an image. Recheck its lifetime
            // and candidate against the fresh frame instead of asking the model twice.
            this.ensureAgentObservation(ground, inferred);
            selected = { action: 'select_subject', subjectId: inferred.subjectId };
            this.log(`复用本次云端选人结果并核对新画面：主体 #${inferred.subjectId}`);
          } else {
            observation.purpose = 'subject_selection';
            const response = await this.requestCloudAgentAction(observation, text);
            selected = response.command as AgentAction;
          }
          check();
          if (entry === 'hover') this.ensureDollyHoverReady();
          this.ensureAgentObservation(observation, selected);
          if (selected.action !== 'select_subject' || selected.subjectId === undefined) return selected;
          const subject = this.session.snapshot().telemetry.subject;
          if (entry !== 'hover' || observation.frame.currentSubjectId !== selected.subjectId ||
            trackedSubjectId(subject) !== selected.subjectId) {
            await this.performAgentAction(observation, { action: 'select_subject', subjectId: selected.subjectId });
          } else {
            this.selectedSubjectId = selected.subjectId;
            this.log(`主体 #${selected.subjectId} 仍稳定锁定，免重复发送选人指令`);
          }
          check();
          return { action: 'select_subject', subjectId: selected.subjectId };
        } finally { this.finishAgentObservation(observation.requestId); }
      },
      shoot: async (command: AgentAction): Promise<AgentOutcome> => {
        check();
        const beforePreview = this.video.snapshot();
        const observation = await this.captureAgentObservation(true, command.subjectId);
        try {
          check();
          const afterPreview = this.video.snapshot();
          if (afterPreview.state !== 'live' || afterPreview.stats?.waitingForKey === true ||
            afterPreview.stats?.decoderEpoch !== beforePreview.stats?.decoderEpoch) {
            throw new Error('实时画面在主体确认后发生变化，请重新确认主体');
          }
          if (entry === 'hover') this.ensureDollyHoverReady();
          const subject = this.session.snapshot().telemetry.subject;
          const trackingAge = Date.now() - (subject?.trackingAt ?? 0);
          if (observation.frame?.currentSubjectId !== command.subjectId || trackedSubjectId(subject) !== command.subjectId ||
            trackingAge < 0 || trackingAge > 500) {
            throw new Error('已确认的主体跟踪发生变化，请重新选人后拍摄');
          }
          // Execute only after the user confirmed the subject and then accepted the flight plan, using a fresh observation.
          return command.recipe === 'dolly_circle' ? await this.runCloseupSequence(observation, command) :
            await this.performAgentAction(observation, command);
        } finally { this.finishAgentObservation(observation.requestId); }
      }
    };
    try { return await this.groundDolly.start(description, intent, port, entry); }
    catch (error) {
      this.log(`拍摄准备失败：${asError(error).message}`);
      throw asError(error);
    }
  }

  async confirmSubjectTask(): Promise<AgentOutcome> {
    try { return await this.groundDolly.confirm(); }
    catch (error) {
      this.agentFeedback = asError(error).message;
      this.log(`主体任务确认失败：${this.agentFeedback}`); this.emit(); throw asError(error);
    }
  }
  async executeSubjectPlan(): Promise<AgentOutcome> {
    try { return await this.groundDolly.execute(); }
    catch (error) {
      this.agentFeedback = asError(error).message;
      this.log(`主体任务执行失败：${this.agentFeedback}`); this.emit(); throw asError(error);
    }
  }
  async confirmGroundDolly(): Promise<AgentOutcome> { return this.confirmSubjectTask(); }
  async executeGroundDolly(): Promise<AgentOutcome> { return this.executeSubjectPlan(); }

  private async runCloseupSequence(first: AgentObservation, command: AgentAction): Promise<AgentOutcome> {
    const target = command.subjectId;
    if (target === undefined) throw new Error('特写组合需要先确认拍摄主体');
    const previousStart = this.nativeTasks.snapshot().startedAtMs;
    const captureToken = new CancellationToken(first.flightGeneration);
    let videoSequence: number | undefined;
    let startAttempted: boolean = false;
    let returned: string[] = [];
    const isCurrent = (): boolean => {
      const flight = this.flight.snapshot();
      return this.session.sessionId() === first.sessionId && this.agentGeneration === first.controlGeneration &&
        flight.generation === first.flightGeneration && !flight.landRequested && !flight.landSent &&
        this.session.snapshot().phase === 'ready' && this.session.isReliableLinkFresh();
    };
    const requireTarget = (observation: AgentObservation, gate: () => boolean): void => {
      const subject = this.session.snapshot().telemetry.subject;
      const age = Date.now() - (subject?.trackingAt ?? 0);
      if (!gate()) throw new Error('特写组合拍摄已取消或飞机状态已变化');
      if (observation.frame?.currentSubjectId !== target || trackedSubjectId(subject) !== target || age < 0 || age > 500) {
        throw new Error('原拍摄主体跟踪已丢失或变化，未启动后续运镜');
      }
    };
    const port: CloseupSequencePort = {
      isCurrent: isCurrent,
      startDolly: async (gate: () => boolean): Promise<void> => {
        requireTarget(first, gate); this.agentVideoResultReady = false;
        try {
          videoSequence = await this.captureMedia.beginVideoSequence(captureToken);
          requireTarget(first, gate);
          this.closeupMedia.begin(first.sessionId, first.flightGeneration);
          startAttempted = true;
          await this.performAgentAction(first, { action: 'dolly_zoom', subjectId: target,
            framing: command.framing, zoom: command.zoom, retreat: command.retreat }, videoSequence);
        } finally { this.finishAgentObservation(first.requestId); }
      },
      finishDolly: async (gate: () => boolean): Promise<void> => {
        await this.waitForCloseupStep(gate, target, videoSequence as number);
      },
      startCircle: async (gate: () => boolean): Promise<void> => {
        if (!gate()) throw new Error('特写组合拍摄已取消或飞机状态已变化');
        const fresh = await this.waitForCloseupTarget(gate, target);
        try {
          requireTarget(fresh, gate); this.agentVideoResultReady = false;
          await this.performAgentAction(fresh, { action: 'circle', subjectId: target, radiusMeters: 2 }, videoSequence);
        } finally { this.finishAgentObservation(fresh.requestId); }
      },
      finishCircle: async (gate: () => boolean): Promise<void> => {
        await this.waitForCloseupStep(gate, target, videoSequence as number);
      },
      returnMedia: async (gate: () => boolean): Promise<void> => {
        if (!gate()) throw new Error('特写组合拍摄已取消或飞机状态已变化');
        this.captureMedia.finishVideoSequence(videoSequence as number, captureToken);
        returned = await this.waitForCloseupMedia(gate);
      }
    };
    try {
      await this.closeupSequence.run(port);
      this.presentCloseupVideos(returned, true);
      return { message: '特写组合拍摄已完成：滑动变焦与同主体2米环绕，本次全部录像已取回' };
    } catch (error) {
      this.log(`特写组合中断：${error instanceof Error ? error.message : '未知原因'}`);
      throw error instanceof Error ? error : new Error('特写组合拍摄未完成');
    } finally {
      captureToken.cancel();
      if (videoSequence !== undefined) this.captureMedia.releaseVideoSequence(videoSequence,
        !startAttempted || (isCurrent() && this.nativeTasks.snapshot().startedAtMs === previousStart));
    }
  }

  private async waitForCloseupStep(isCurrent: () => boolean, target: number, videoSequence: number): Promise<void> {
    const deadline = Date.now() + 180000;
    const targetGuard = new CloseupSubjectGuard(target);
    let lastTargetState: string = '';
    let terminalIdleSinceMs: number | undefined;
    while (Date.now() < deadline) {
      if (!isCurrent()) throw new Error('特写组合拍摄已取消或飞机状态已变化');
      // Observe completion while the terminal task report is still fresh; this also
      // preserves the existing handoff evidence if the camera later enters manual mode.
      const completed = this.nativeTasks.canCompleteForHover();
      const native = this.nativeTasks.snapshot();
      if ((native.executionSeen || native.executionObserved) && native.activeOrUnknown) {
        const telemetry = this.session.snapshot().telemetry;
        const subject = telemetry.subject;
        const now = Date.now();
        const targetState = targetGuard.assess(subject, now);
        if (targetState !== lastTargetState) {
          lastTargetState = targetState;
          const label = targetState === 'unknown' ? '组合运行期跟踪框未知，仅等待原生结束' :
            targetState === 'different' ? '组合主体保护触发：明确不同ID' : '组合运行期跟踪框已确认';
          this.log(`${label}：任务=${native.kind}/${telemetry.task?.payloadHex ?? '无'}，任务年龄=${telemetry.taskAgeMs ?? -1}ms，` +
            `目标=${target}，当前跟踪=${trackedSubjectId(subject) ?? '无'}，跟踪时间=${subject?.trackingAt ?? '无'}，` +
            `跟踪年龄=${subject?.trackingAt === undefined ? -1 : now - subject.trackingAt}ms，` +
            `飞行模式=${telemetry.flight?.modeRaw ?? '无'}，飞行年龄=${telemetry.flightAgeMs ?? -1}ms，` +
            `录像=${telemetry.camera?.recordingCandidate ?? '无'}/${telemetry.camera?.recordStateRaw ?? '无'}，` +
            `相机年龄=${telemetry.cameraAgeMs ?? -1}ms，执行已观察=${native.executionSeen}，当前执行=${native.executionObserved}`);
        }
        if (targetState === 'different') {
          const stopped = await this.nativeTasks.stop();
          this.log(`组合主体保护停止回复：${stopped.ok ? '已确认' : stopped.error?.message ?? '未确认'}`);
          throw new Error(stopped.ok ? '原主体跟踪已明确变化，已请求停止当前运镜，后续步骤未启动' :
            '原主体跟踪已明确变化，停止尚未确认，请观察飞机并降落');
        }
      }
      if (completed.ok && !native.executionSeen) throw new Error('未观察到本步运镜实际执行，后续运镜未启动');
      if (completed.ok && native.recordingSeen === false && !native.activeOrUnknown &&
        !native.executionObserved && !this.busyValue) {
        const telemetry = this.session.snapshot().telemetry;
        const flight = telemetry.flight;
        const camera = telemetry.camera;
        const startedAt = native.startedAtMs;
        const now = Date.now();
        const cameraIdle = startedAt !== undefined && camera !== undefined &&
          (telemetry.cameraAgeMs ?? Infinity) >= 0 && (telemetry.cameraAgeMs ?? Infinity) <= 1000 &&
          camera.observedAtMs >= startedAt && camera.observedAtMs <= now &&
          camera.recordingCandidate === false && camera.recordStateRaw === 0;
        // A completed airborne task can exit without ever recording. Require a
        // continuous grace period of fresh positive idle evidence, resetting it
        // on stale/unknown state or any resumed execution/recording.
        if (cameraIdle) {
          if (terminalIdleSinceMs === undefined) terminalIdleSinceMs = now;
        } else terminalIdleSinceMs = undefined;
        const grounded = startedAt !== undefined && (telemetry.flightAgeMs ?? Infinity) <= 1000 &&
          (telemetry.cameraAgeMs ?? Infinity) <= 1000 && flight !== undefined && camera !== undefined &&
          flight.observedAtMs >= startedAt && camera.observedAtMs >= startedAt &&
          flight.airborne === false && flight.motorsOn === false && camera.recordingCandidate === false;
        if (grounded || (terminalIdleSinceMs !== undefined && now - terminalIdleSinceMs >= 2000)) {
          this.log(`组合本步结束但未观察到录像：任务=${native.kind}/${telemetry.task?.payloadHex ?? '无'}，` +
            `startReply=${native.startReply}，启动时间=${startedAt}，任务年龄=${telemetry.taskAgeMs ?? -1}ms，` +
            `执行已观察=${native.executionSeen}，当前执行=${native.executionObserved}，活动或未知=${native.activeOrUnknown}，` +
            `录像已观察=${native.recordingSeen}，连续空闲=${terminalIdleSinceMs === undefined ? 0 : now - terminalIdleSinceMs}ms，` +
            `相机模式=${camera?.modeRaw ?? '无'}，录像=${camera?.recordingCandidate ?? '无'}，录像状态=${camera?.recordStateRaw ?? '无'}，` +
            `相机年龄=${telemetry.cameraAgeMs ?? -1}ms，相机时间=${camera?.observedAtMs ?? '无'}，` +
            `飞行模式=${flight?.modeRaw ?? '无'}，空中/电机=${flight?.airborne ?? '无'}/${flight?.motorsOn ?? '无'}，` +
            `飞行年龄=${telemetry.flightAgeMs ?? -1}ms，目标=${target}，当前跟踪=${trackedSubjectId(telemetry.subject) ?? '无'}，` +
            `跟踪时间=${telemetry.subject?.trackingAt ?? '无'}，配置=${JSON.stringify(native.config)}；保留未核对素材票据`);
          throw new Error('本次运镜已结束，未观察到录像；后续运镜未启动，上次素材仍待核对');
        }
      } else terminalIdleSinceMs = undefined;
      if (completed.ok && !this.busyValue && this.captureMedia.canContinueVideoSequence(videoSequence)) {
        this.log(`组合本步已结束并封存录像：${native.kind}，序列=${videoSequence}；尚未下载`);
        return;
      }
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
    }
    // Cancellation/landing owns its existing stop/landing operation. Do not race
    // it with a new request merely because its deadline coincides with this wait.
    if (!isCurrent()) throw new Error('特写组合拍摄已取消或飞机状态已变化');
    if (this.nativeTasks.snapshot().activeOrUnknown) {
      this.log('组合本步等待超时，正在请求停止仍活动或未确认结束的原生任务');
      const stopped = await this.nativeTasks.stop();
      this.log(`组合超时停止回复：${stopped.ok ? '已确认' : stopped.error?.message ?? '未确认'}`);
      throw new Error(stopped.ok ? '等待本步任务结束或录像封存超时，已请求停止当前运镜，后续运镜未启动' :
        '等待本步任务结束或录像封存超时，停止尚未确认，请观察飞机并降落');
    }
    throw new Error('等待本步任务结束或录像封存超时，后续运镜未启动');
  }

  private async waitForCloseupMedia(isCurrent: () => boolean): Promise<string[]> {
    const deadline = Date.now() + 180000;
    while (Date.now() < deadline) {
      if (!isCurrent()) throw new Error('特写组合拍摄已取消或飞机状态已变化');
      if (this.agentFeedback.startsWith('自动取回未完成')) throw new Error(this.agentFeedback);
      if (!this.busyValue && !this.captureMedia.hasPending('video') && this.agentVideoResultReady &&
        this.agentMediaKind === 'video' && this.agentMediaUris.length > 0) return this.agentMediaUris.slice();
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
    }
    throw new Error('特写组合已拍摄，统一取回录像超时，可重试取回本次录像');
  }

  private async waitForCloseupTarget(isCurrent: () => boolean, target: number): Promise<AgentObservation> {
    const startedAt = Date.now();
    let deadline = startedAt + 8000;
    let recoveringPicture = false;
    const freshStream = (preview: VideoPreviewSnapshot): boolean => preview.stats.running &&
      !preview.stats.recoveryPaused && preview.stats.lastAssembledAgeMs >= 0 &&
      preview.stats.lastAssembledAgeMs <= 1000;
    const sameHover = (state: DroneSessionSnapshot): boolean => {
      const telemetry = state.telemetry; const subject = telemetry.subject;
      const age = Date.now() - (subject?.trackingAt ?? 0);
      return trackedSubjectId(subject) === target && age >= 0 && age <= 500 &&
        (telemetry.flightAgeMs ?? Infinity) <= 1000 && telemetry.flight?.modeRaw === 26 &&
        telemetry.flight.airborne === true && telemetry.flight.motorsOn === true;
    };
    this.log(`组合交接：等待原主体 #${target} 恢复新鲜跟踪，不下载录像`);
    while (Date.now() < deadline) {
      if (!isCurrent()) throw new Error('特写组合拍摄已取消或飞机状态已变化');
      const state = this.session.snapshot();
      const telemetry = state.telemetry;
      const subject = telemetry.subject;
      const tracked = trackedSubjectId(subject);
      const age = Date.now() - (subject?.trackingAt ?? 0);
      if (tracked !== undefined && age >= 0 && age <= 1000 && tracked !== target) {
        this.log(`组合交接拒绝：目标=${target}，当前跟踪=${tracked}，跟踪年龄=${age}ms`);
        throw new Error('原主体跟踪已明确变为其他人，未启动环绕');
      }
      const sameTargetHover = sameHover(state);
      const preview = this.video.snapshot();
      const recoveringDecoder = state.phase === 'ready' && freshStream(preview) &&
        preview.stats.lastResetReason === 'decode-stall';
      if (sameTargetHover && recoveringDecoder && preview.stats.waitingForKey && !recoveringPicture) {
        // A decoder-local reset may need the next aircraft IRAP. Remain in the
        // same verified hover; this extends no movement authorization or frame TTL.
        recoveringPicture = true; deadline = startedAt + 30000;
        this.agentFeedback = '小艺正在恢复实时画面，确认原主体后继续环绕';
        this.log('组合交接：同主体悬停和图传仍新鲜，限时等待解码关键帧恢复');
        this.emit();
      }
      if (recoveringPicture && (!sameTargetHover || !freshStream(preview) ||
        (preview.state !== 'live' && !recoveringDecoder))) {
        throw new Error('恢复实时画面期间原主体、悬停或图传状态已失效，未启动环绕');
      }
      if (sameTargetHover && (!recoveringPicture || preview.state === 'live')) {
        // This handoff already owns a bounded same-target recovery loop. A
        // temporary readback gap may retry; an explicit target change may not.
        const fresh = await this.captureAgentObservation(true, target, true);
        let accepted = false;
        try {
          if (!isCurrent() || Date.now() >= deadline) throw new Error('组合交接已取消或等待主体恢复超时');
          const frameId = fresh.frame?.currentSubjectId;
          const afterState = this.session.snapshot();
          const after = afterState.telemetry.subject;
          const afterId = trackedSubjectId(after); const afterAge = Date.now() - (after?.trackingAt ?? 0);
          if ((frameId !== undefined && frameId !== target) ||
            (afterId !== undefined && afterAge >= 0 && afterAge <= 1000 && afterId !== target)) {
            this.log(`组合交接拒绝：目标=${target}，画面=${frameId ?? '无'}，跟踪=${afterId ?? '无'}`);
            throw new Error('原主体跟踪或当前画面已明确变为其他人，未启动环绕');
          }
          const afterPreview = this.video.snapshot();
          if (!sameHover(afterState) ||
            ((recoveringPicture || fresh.frame !== undefined) && !freshStream(afterPreview))) {
            throw new Error('取帧期间原主体、悬停或图传状态已失效，未启动环绕');
          }
          const sameDecoder = afterPreview.state === 'live' && !afterPreview.stats.waitingForKey &&
            afterPreview.stats.decoderEpoch === preview.stats.decoderEpoch;
          if (frameId === target && afterId === target && afterAge >= 0 && afterAge <= 500 && sameDecoder) {
            accepted = true; this.log(`组合交接：新画面与跟踪均确认原主体 #${target}`); return fresh;
          }
          if (!sameDecoder) {
            this.agentFeedback = '小艺正在恢复实时画面，确认原主体后继续环绕'; this.emit();
            this.log('组合交接：取帧期间解码器已重置或尚未恢复，丢弃本张画面并重新取帧');
          }
          this.log(`组合交接暂未匹配：目标=${target}，画面=${frameId ?? '无'}，跟踪=${afterId ?? '无'}，将重新取帧`);
        } finally { if (!accepted) this.finishAgentObservation(fresh.requestId); }
      }
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 100));
    }
    const last = this.session.snapshot().telemetry;
    this.log(`组合交接超时：目标=${target}，飞行模式=${last.flight?.modeRaw ?? '无'}，` +
      `跟踪=${trackedSubjectId(last.subject) ?? '无'}，跟踪时间=${last.subject?.trackingAt ?? '无'}`);
    if (recoveringPicture) throw new Error('实时画面恢复超时，未启动环绕，已拍摄录像将保留');
    throw new Error('运镜结束后未恢复原主体的新鲜画面与跟踪，未启动环绕');
  }

  private presentCloseupVideos(uris: string[], complete: boolean): void {
    this.agentMediaUris = this.closeupMedia.add(uris, this.session.sessionId(), this.flight.snapshot().generation);
    this.agentMediaIndex = 0;
    this.agentMediaUri = this.agentMediaUris[0] ?? ''; this.agentMediaKind = 'video';
    this.agentVideoResultReady = this.agentMediaUris.length > 0;
    this.agentFeedback = complete ? `特写组合全部录像已取回，共${this.agentMediaUris.length}段` :
      `特写组合未完成，已保留${this.agentMediaUris.length}段录像`;
    this.emit();
  }

  private retireCloseup(): void {
    this.closeupSequence?.reset(); this.closeupMedia?.clear();
  }

  async requestCloudAgentAction(observation: AgentObservation, description: string): Promise<AgentResponse> {
    await this.initializeCloudVlm();
    const isCurrent = (): boolean => observation.controlGeneration === this.agentGeneration &&
      observation.sessionId === this.session.sessionId() && observation.flightGeneration === this.flight.snapshot().generation &&
      observation.requestId === this.latestAgentRequestId && this.session.snapshot().phase === 'ready';
    const started = Date.now();
    const response = await this.cloudVlm.request(observation, description, isCurrent);
    if (!isCurrent()) throw new Error('云端请求已取消或飞机会话发生变化');
    this.cloudVlmStatus = `手机直连DeepSeek · ${Date.now() - started}毫秒`; this.emit();
    return response;
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
    token: CancellationToken, videoSequence?: number): Promise<AgentOutcome> {
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
        if (command.recipe !== undefined) throw new Error('组合拍摄需要先确认主体和飞行方案后执行');
        return this.startAgentDolly(observation, command, token, videoSequence);
      case 'follow':
        return this.startAgentSubjectTask('follow', observation, command, token);
      case 'prepare_dolly':
        this.applyAgentDollySettings(command);
        agentResult(await this.prepareNativeTask('dolly', token));
        return { message: '本轮滑动变焦已在地面准备，可以普通起飞后选人拍摄' };
      case 'circle': {
        if (command.subjectId !== undefined) return this.startAgentSubjectTask('circle', observation, command, token, videoSequence);
        if (this.nativeTasks.activeOrUnknown()) throw new Error('请先停止当前原生任务');
        const radius = command.radiusMeters ?? this.nativeConfig.radiusMeters;
        this.nativeConfig = { radiusMeters: radius, framing: this.nativeConfig.framing,
          zoom: this.nativeConfig.zoom, retreat: this.nativeConfig.retreat };
        if (this.session.snapshot().telemetry.flight?.airborne) {
          await this.handoffCompletedNativeTask(observation, token);
          await this.releaseHoverTaskTarget(observation, token);
          agentResult(await this.prepareNativeTask('circle', token, true));
        } else agentResult(await this.prepareNativeTask('circle', token));
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
        this.log(`执行语音基础运动：方向=${command.direction}，时长=${command.seconds}s；直接执行`);
        this.agentFeedback = `小艺正在执行${agentActionLabel(command)}…`; this.emit();
        agentResult(await this.flight.move(command.direction as MovementDirection, command.seconds as number, token));
        return { message: `已完成${agentActionLabel(command)}并回中` };
      case 'move_sequence':
        return this.executeMovementSequence(observation, command, token);
      default: throw new Error('没有可执行的动作');
    }
  }

  private movementSequenceBlockReason(observation: AgentObservation, token: CancellationToken): string {
    const flight = this.flight.snapshot();
    if (token.isCancelled() || token.generation() !== flight.generation ||
      flight.generation !== observation.flightGeneration || this.agentGeneration !== observation.controlGeneration ||
      this.session.sessionId() !== observation.sessionId || flight.landRequested || flight.landSent) {
      return '连续基础运动已取消或飞机状态已变化，后续步骤未执行';
    }
    if (!this.session.isActionLinkFresh()) return '飞机连接或图传已不新鲜，连续基础运动已停止';
    const telemetry = this.session.snapshot().telemetry;
    if (!flight.takeoffAcknowledged || (telemetry.flightAgeMs ?? Infinity) > 1000 ||
      telemetry.flight?.airborne !== true || telemetry.flight.motorsOn !== true || telemetry.flight.modeRaw !== 6) {
      return '连续基础运动需要本轮已确认的普通空中悬停，请先起飞或停止跟踪任务';
    }
    if (flight.nativeTaskMayFly || this.nativeTasks.activeOrUnknown() || this.groundDolly.snapshot().active ||
      this.closeupSequence.snapshot().active) {
      return '请先结束当前主体或运镜任务，再执行连续基础运动';
    }
    return '';
  }

  private async executeMovementSequence(observation: AgentObservation, command: AgentAction,
    token: CancellationToken): Promise<AgentOutcome> {
    this.movementSequenceToken = token;
    const assertCurrent = (): void => {
      const reason = this.movementSequenceBlockReason(observation, token);
      if (reason.length > 0) throw new Error(reason);
    };
    try {
      await runMovementSequence(command.steps, {
        assertCurrent: assertCurrent,
        onStep: (step: MovementStep, index: number, total: number): void => {
          this.agentFeedback = `小艺正在执行第 ${index}/${total} 步：${agentActionLabel({ action: 'move',
            direction: step.direction, seconds: step.seconds })}`;
          this.log(this.agentFeedback); this.emit();
        },
        move: async (step: MovementStep): Promise<void> => {
          agentResult(await this.flight.move(step.direction, step.seconds, token,
            (): boolean => this.movementSequenceBlockReason(observation, token).length === 0));
        }
      });
      return { message: `已按顺序完成 ${command.steps?.length ?? 0} 步基础运动，摇杆已回中` };
    } catch (error) {
      this.agentFeedback = `连续基础运动已中止：${asError(error as Error).message}；后续步骤未执行`;
      this.emit();
      throw error as Error;
    } finally {
      if (this.movementSequenceToken === token) this.movementSequenceToken = undefined;
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
    token: CancellationToken, videoSequence?: number): Promise<AgentOutcome> {
    return this.startAgentSubjectTask('dolly', observation, command, token, videoSequence);
  }

  private async handoffCompletedNativeTask(observation: AgentObservation, token: CancellationToken,
    videoSequence?: number): Promise<void> {
    if (!this.flight.snapshot().nativeTaskMayFly) return;
    this.ensureAgentPhotoSession(observation, token);
    if (this.captureMedia.hasPending('video') && (videoSequence === undefined ||
      !this.captureMedia.canContinueVideoSequence(videoSequence))) {
      throw new Error('请先取回上一轮录像，再开始下一次拍摄');
    }
    agentResult(this.nativeTasks.canCompleteForHover());
    const observedTarget = observation.frame === undefined ? observation.context.currentSubjectId : observation.frame.currentSubjectId;
    if (trackedSubjectId(this.session.snapshot().telemetry.subject) !== observedTarget) {
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

  private async waitAgentTaskTargetReady(target: number, observation: AgentObservation,
    token: CancellationToken): Promise<void> {
    const deadline = Date.now() + 2000;
    let lastState: string = '';
    while (Date.now() < deadline) {
      this.ensureAgentPhotoSession(observation, token);
      const flight = this.flight.snapshot();
      if (!flight.takeoffSent || !flight.takeoffAcknowledged || flight.nativeTaskMayFly || flight.movementActive ||
        flight.landRequested || flight.landSent || this.nativeTasks.activeOrUnknown()) {
        throw new Error('起飞轮次或任务控制状态已变化，未启动运镜');
      }
      const telemetry = this.session.snapshot().telemetry;
      const subject = telemetry.subject;
      const tracked = trackedSubjectId(subject);
      const age = Date.now() - (subject?.trackingAt ?? 0);
      if (tracked !== undefined && age >= 0 && age <= 1000 && tracked !== target) {
        throw new Error('主体跟踪已变化，未启动运镜');
      }
      const task = telemetry.task;
      const taskFresh = (telemetry.taskAgeMs ?? Infinity) <= 1000;
      if (taskFresh && task !== undefined && (task.phaseRaw !== 0 || task.modeRaw !== 0)) {
        throw new Error('主体选择后任务状态已变化，未启动运镜');
      }
      if ((telemetry.flightAgeMs ?? Infinity) <= 1000 && telemetry.flight?.modeRaw === 26 &&
        telemetry.flight.airborne && telemetry.flight.motorsOn && taskFresh && task?.phaseRaw === 0 && task.modeRaw === 0 &&
        tracked === target && age >= 0 && age <= 500 && (telemetry.cameraAgeMs ?? Infinity) <= 1000 &&
        telemetry.camera?.recordingCandidate === false) {
        this.log(`运镜启动状态已同步：主体 #${target}，跟踪模式26，任务空闲`);
        return;
      }
      const status = `目标=${target}，跟踪=${tracked ?? '无'}，飞行模式=${telemetry.flight?.modeRaw ?? '无'}，` +
        `任务=${task?.payloadHex ?? '无'}，飞行年龄=${telemetry.flightAgeMs ?? '无'}，相机年龄=${telemetry.cameraAgeMs ?? '无'}`;
      if (status !== lastState) { this.log(`等待运镜启动状态同步：${status}`); lastState = status; }
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 50));
    }
    this.ensureAgentPhotoSession(observation, token);
    throw new Error('已选中主体，但飞机跟踪和任务状态尚未同步就绪，未启动运镜');
  }

  private async startAgentSubjectTask(kind: NativeTaskKind, observation: AgentObservation, command: AgentAction,
    token: CancellationToken, videoSequence?: number): Promise<AgentOutcome> {
    if (this.nativeTasks.activeOrUnknown()) throw new Error('请先停止当前原生任务');
    const state = this.session.snapshot().telemetry;
    if (kind === 'circle') this.nativeConfig = { radiusMeters: command.radiusMeters ?? 2,
      framing: this.nativeConfig.framing, zoom: this.nativeConfig.zoom, retreat: this.nativeConfig.retreat };
    if ((state.flightAgeMs ?? Infinity) > 1000 || state.flight === undefined) throw new Error('飞行遥测尚未就绪');
    if (!state.flight.airborne && !state.flight.motorsOn) {
      if (command.subjectId !== undefined) throw new Error('请先起飞扫描主体，再指定拍摄目标');
      if (kind === 'dolly') this.applyAgentDollySettings(command);
      agentResult(await this.prepareNativeTask(kind, token));
      return { message: agentResult(await this.startNativeWithCapture(token, undefined, videoSequence)) };
    }
    const candidates = observation.frame?.candidates;
    const target = command.subjectId ?? observation.frame?.currentSubjectId ??
      (candidates?.length === 1 ? candidates[0].id : undefined);
    if (target === undefined) throw new Error('请先指定或锁定拍摄主体');
    if (trackedSubjectId(state.subject) !== observation.frame?.currentSubjectId) throw new Error('锁定状态已变化，请重新发起');
    await this.handoffCompletedNativeTask(observation, token, videoSequence);
    if (kind === 'dolly') this.applyAgentDollySettings(command, true);
    await this.releaseHoverTaskTarget(observation, token);
    this.agentFeedback = `正在悬停准备${this.taskLabel(kind)}…`; this.emit();
    this.log(`悬停准备${this.taskLabel(kind)}，目标 #${target}，${this.nativeConfig.framing}/${this.nativeConfig.zoom}倍`);
    agentResult(await this.prepareNativeTask(kind, token, true));
    this.ensureAgentPhotoSession(observation, token);
    const task = this.session.snapshot().telemetry.task;
    if (task?.modeRaw === 9 && [0, 5].includes(task.phaseRaw)) {
      agentResult(await this.requestHoverSubjectScan(token, true));
    }
    this.agentFeedback = `正在锁定主体 #${target}，确认后启动${this.taskLabel(kind)}…`; this.emit();
    agentResult(await this.requestSubjectSelection(token, target));
    await this.waitAgentTaskTargetReady(target, observation, token);
    return { message: agentResult(await this.startNativeWithCapture(token, target, videoSequence)) };
  }

  async captureVlmFrame(lockedSubjectId?: number): Promise<VlmFrame> {
    if (this.vlmFramePending) throw new Error('已有图传取帧请求正在处理');
    if (this.video.snapshot().state !== 'live') throw new Error('实时图传尚未就绪');
    const sessionId = this.session.sessionId();
    const flightGeneration = this.flight.snapshot().generation;
    const controlGeneration = this.agentGeneration;
    const decoderEpoch = this.video.snapshot().stats?.decoderEpoch;
    const reports: SubjectSnapshot[] = [];
    const check = (): void => {
      if (this.session.sessionId() !== sessionId || this.flight.snapshot().generation !== flightGeneration ||
        this.agentGeneration !== controlGeneration || !this.session.isReliableLinkFresh()) {
        throw new Error('取帧期间飞机会话或控制状态已变化');
      }
      const preview = this.video.snapshot();
      if (preview.state !== 'live' || preview.stats?.waitingForKey === true ||
        preview.stats?.decoderEpoch !== decoderEpoch) throw new Error('取帧期间实时画面或解码会话已变化');
      const subject = this.session.snapshot().telemetry.subject;
      if (subject !== undefined) {
        const trackingId = trackedSubjectId(subject);
        const selectedId = subject.selectedIdCandidate;
        const selectedChanged = selectedId !== undefined && selectedId >= 0 && selectedId <= 255 &&
          selectedId !== lockedSubjectId;
        if (lockedSubjectId !== undefined &&
          ((trackingId !== undefined && trackingId !== lockedSubjectId) || selectedChanged)) {
          throw new FrameSubjectChangedError();
        }
        reports.push(subject);
        if (reports.length > 48) reports.shift();
      }
    };
    check();
    this.vlmFramePending = true;
    let ticket: number = 0;
    let result: VlmFrame | undefined;
    try {
      ticket = nativeVideo.requestFrame();
      if (ticket === 0) throw new Error('图传解码器尚未就绪');
      const deadline = Date.now() + 600;
      while (Date.now() < deadline && this.session.sessionId() === sessionId && this.session.isReliableLinkFresh()) {
        check();
        const frame = nativeVideo.takeFrame(ticket);
        if (frame === undefined) {
          await new Promise<void>((resolve: () => void) => setTimeout(resolve, 16));
          continue;
        }
        check();
        if (frame.rgba.byteLength === 0) throw new Error('设备未提供可读取的解码帧');
        const frameAge = Date.now() - frame.capturedAtMs;
        if (frameAge < 0 || frameAge > 600) throw new Error('取到的实时画面已过期，请重新取帧');
        const report = matchFrameSubjects(frame.capturedAtMs, reports, lockedSubjectId);
        if (report === undefined) {
          const latest = reports[reports.length - 1];
          this.log(`主体画面匹配失败：帧时间=${frame.capturedAtMs}，目标=${lockedSubjectId ?? '候选扫描'}，` +
            `候选/跟踪时间=${latest?.detectionAt ?? -1}/${latest?.trackingAt ?? -1}，采样报告=${reports.length}`);
          throw new Error(lockedSubjectId === undefined ? '已取得画面，但没有时间匹配的候选回报' :
            '已取得画面，但没有时间匹配的已确认主体跟踪回报');
        }
        markVlmCandidates(frame.rgba, frame.width, frame.height, report.candidates);
        const pixels = await image.createPixelMap(frame.rgba, { size: { width: frame.width, height: frame.height },
          srcPixelFormat: image.PixelMapFormat.RGBA_8888, pixelFormat: image.PixelMapFormat.RGBA_8888 });
        try {
          const packer = image.createImagePacker();
          try {
            const jpeg = await packer.packToData(pixels, { format: 'image/jpeg', quality: 85 });
            check();
            result = { jpeg: jpeg, width: frame.width, height: frame.height, sessionId: sessionId,
              capturedAtMs: frame.capturedAtMs, candidatesObservedAtMs: report.observedAtMs, candidates: report.candidates,
              currentSubjectId: report.currentSubjectId };
          } finally { await packer.release(); }
        } finally { await pixels.release(); }
        break;
      }
    } finally {
      if (ticket > 0) {
        try { nativeVideo.cancelFrame?.(ticket); }
        catch (error) { this.log(`图传取帧票据清理失败：${asError(error).message}`); }
      }
      this.vlmFramePending = false;
    }
    if (result === undefined) throw new Error('实时图传取帧超时或会话已断开');
    // Both asynchronous image releases and ticket cleanup may complete after
    // control or subject state changes. Validate only the fully cleaned result.
    check();
    const age = Date.now() - result.capturedAtMs;
    if (age < 0 || age > 600) throw new Error('取到的实时画面已过期，请重新取帧');
    this.log(`主体画面匹配：来源=${lockedSubjectId === undefined ? 'candidates' : 'tracking'}，` +
      `目标=${result.currentSubjectId ?? '候选扫描'}，帧/回报时间=${result.capturedAtMs}/${result.candidatesObservedAtMs}`);
    return result;
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
        const prepared = await this.prepareNativeTask('dolly', token);
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
    this.closeupSequence?.cancel();
    this.groundDolly?.cancel();
    this.pendingAgentAction = undefined;
    this.agentGeneration++;
    this.cloudVlm?.cancelPending();
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
    this.connectionEpoch++;
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
    if ((this.busyValue || (this.connectionAttempt !== undefined && !['连接', '初始化'].includes(name))) && rejectWhenBusy) {
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
