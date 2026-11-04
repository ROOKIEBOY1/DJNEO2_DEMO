import { NativeTaskConfig, NativeTaskService, NativeTaskSnapshot } from './NativeTaskService';
import { DollyFraming, NativeTaskKind } from '../protocol/NativeTaskCodec';
import { VoiceMotion } from './VoiceMotion';
import * as nativeVideo from 'libneovideo.so';
import { VideoPreview, VideoPreviewSnapshot, videoSessionIdentity } from '../media/VideoPreview';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CameraService } from './CameraService';
import { DroneSession, DroneSessionSnapshot } from './DroneSession';
import { FlightCommandService, FlightCommandSnapshot } from './FlightCommandService';
import { MediaRepository } from '../media/MediaRepository';
import { MediaKind } from '../media/MediaDirectory';
import { CancellationToken, ErrorLayer, failure, OperationResult, success } from './OperationResult';
import { MovementDirection } from '../protocol/StickCodec';
import { VoiceCommand, VoiceCommandAdapter, VoiceCommandSnapshot } from './VoiceCommandAdapter';
import { Context } from '@kit.AbilityKit';
import { LocalSpeechRecognizer } from '../platform/LocalSpeechRecognizer';
import { AircraftProfileStore, AircraftProfileSummary } from '../profile/AircraftProfileStore';
import { NeoWifiLink } from '../platform/NeoWifiLink';

export interface ConsoleSnapshot {
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
    if (listener !== undefined) this.previewTimer = setInterval(() => this.emit(), 250);
    this.emit();
  }

  snapshot(): ConsoleSnapshot {
    const circle = this.nativeTasks.snapshot();
    const camera = this.camera.snapshot();
    return {
      aircraftProfiles: this.profiles.list(),
      selectedAircraftId: this.profiles.selectedId(),
      wifiProgress: this.wifiProgressValue,
      session: this.session.snapshot(),
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
      videoPreview: this.video.snapshot()
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
        this.nativeTasks.resetForAircraftSession();
        this.camera.resetForAircraftSession();
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
  async disconnect(): Promise<void> {
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
      return this.nativeTasks.start(true, token);
    });
  }
  setTaskSettings(radius: number, framing: DollyFraming, zoom: number, retreat: boolean): void {
    if (this.busyValue || this.nativeTasks.activeOrUnknown()) { this.log('先停止当前操作，再修改任务参数'); this.emit(); return; }
    if (!Number.isFinite(radius) || radius < 2 || radius > 10 || !['半身', '全身', '远景'].includes(framing) || (zoom !== 2 && zoom !== 3)) return;
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
    await this.run('拍照', (token: CancellationToken) => {
      if (this.nativeTasks.activeOrUnknown()) return Promise.resolve(failure<string>(ErrorLayer.TASK, 'NATIVE_CONTEXT_ACTIVE', '先停止原生任务，再切换拍照上下文'));
      this.nativeTasks.cancel(); this.voice.cancelPending();
      return this.camera.shoot(token);
    });
  }
  async startRecording(): Promise<void> { await this.run('开始录像', (token: CancellationToken) => this.camera.startRecording(token)); }
  async stopRecording(): Promise<void> {
    this.cancelOperations(); await this.run('停止录像', () => this.camera.stopRecording(), false);
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
      const result = await this.camera.downloadLatest(kind, this.outputDirectory, token);
      if (result.ok && result.data !== undefined) this.log(`原片已保存：${result.data.path}`);
      return result;
    });
  }
  private cancelOperations(): void {
    this.operationToken?.cancel(); this.nativeTasks.cancel(); this.voice.cancelPending();
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
