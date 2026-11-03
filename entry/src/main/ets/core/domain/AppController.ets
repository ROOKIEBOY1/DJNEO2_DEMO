import { CircleTask } from './CircleTask';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CameraService } from './CameraService';
import { DroneSession, DroneSessionSnapshot } from './DroneSession';
import { FlightCommandService, FlightCommandSnapshot } from './FlightCommandService';
import { MediaRepository } from '../media/MediaRepository';
import { MediaKind } from '../media/MediaDirectory';
import { ErrorLayer, failure, OperationResult } from './OperationResult';
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
  busy: boolean;
  lastOperation: string;
  lastErrorLayer: string;
  lastError: string;
  logs: string[];
}

export type ConsoleListener = (snapshot: ConsoleSnapshot) => void;

export class AppController {
  readonly session: DroneSession;
  readonly flight: FlightCommandService;
  readonly circle: CircleTask;
  readonly media: MediaRepository;
  readonly camera: CameraService;
  readonly voice: VoiceCommandAdapter = new VoiceCommandAdapter();
  private readonly speech: LocalSpeechRecognizer;
  private readonly outputDirectory: string;
  private readonly profiles: AircraftProfileStore;
  private readonly wifi: NeoWifiLink = new NeoWifiLink();
  private listener?: ConsoleListener;
  private busyValue: boolean = false;
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
    this.circle = new CircleTask(this.session, this.flight);
    this.media = new MediaRepository(this.session);
    this.camera = new CameraService(this.session, this.media);
    this.speech = new LocalSpeechRecognizer(context, this.voice);
    this.speech.setStatusListener((message: string) => {
      this.log(message);
      this.emit();
    });
    this.session.setListener(() => this.emit());
    this.voice.setListener((command: VoiceCommand) => {
      this.executeVoice(command).catch((error: Error) => this.recordException('语音命令', error));
    });
  }

  setListener(listener?: ConsoleListener): void {
    this.listener = listener;
    this.emit();
  }

  snapshot(): ConsoleSnapshot {
    const circle = this.circle.snapshot();
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
      busy: this.busyValue,
      lastOperation: this.lastOperationValue,
      lastErrorLayer: this.lastErrorLayerValue,
      lastError: this.lastErrorValue,
      logs: this.logsValue.slice()
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
        this.circle.resetForAircraftSession();
        this.camera.resetForAircraftSession();
        this.wifiProgressValue = '检查目标飞机 Wi-Fi';
        this.emit();
        const selection = await this.wifi.join(runtime, (message: string) => {
          this.wifiProgressValue = message;
          this.emit();
        });
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
    await this.run('断开', async () => {
      const result = await this.flight.foregroundOnlySafetyShutdown();
      await this.wifi.leave();
      this.wifiProgressValue = '已断开并清理 Wi-Fi 候选配置';
      return result;
    }, false);
  }
  async takeoffConfirmed(): Promise<void> { await this.run('起飞请求', () => this.flight.takeoff(true)); }
  async land(): Promise<void> { await this.run('降落请求', () => this.flight.land(), false); }
  async center(): Promise<void> { await this.run('摇杆回中', () => this.flight.centerSticks(), false); }
  async move(direction: MovementDirection, seconds: number): Promise<void> {
    await this.run(`移动 ${direction} ${seconds.toFixed(1)}s`, () => this.flight.move(direction, seconds));
  }
  async prepareCircle(): Promise<void> { await this.run('准备 2 米环绕', () => this.circle.prepare(2)); }
  async startCircleConfirmed(): Promise<void> {
    await this.run('启动环绕', async () => {
      const started = await this.circle.start(true);
      if (started.ok) {
        this.circle.waitExecution().then(result => this.recordResult('观察环绕执行', result));
      }
      return started;
    });
  }
  async stopCircle(): Promise<void> { await this.run('停止环绕', () => this.circle.stop(), false); }
  async shoot(): Promise<void> { await this.run('拍照', () => this.camera.shoot()); }
  async startRecording(): Promise<void> { await this.run('开始录像', () => this.camera.startRecording()); }
  async stopRecording(): Promise<void> { await this.run('停止录像', () => this.camera.stopRecording(), false); }
  async listMedia(): Promise<void> { await this.run('刷新媒体目录', () => this.camera.listMedia()); }
  async downloadLatest(kind: MediaKind): Promise<void> {
    await this.run(`下载最新${kind === 'photo' ? '照片' : '视频'}`,
      () => this.camera.downloadLatest(kind, this.outputDirectory));
  }

  setVoiceEnabled(enabled: boolean): void {
    this.voice.setEnabled(enabled);
    if (!enabled) {
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
      await this.speech.stop(true);
    } catch (error) {
      this.recordException('停止本地语音', error instanceof Error ? error : new Error(String(error)));
    }
    this.emit();
  }

  submitTranscript(text: string): void {
    const command = this.voice.acceptTranscript(text);
    if (command === undefined && this.voice.snapshot().pendingConfirmation.length === 0) {
      this.log(`未识别限定命令: ${text}`);
    } else if (this.voice.snapshot().pendingConfirmation.length > 0) {
      this.log('危险语音命令等待页面长按确认');
    }
    this.emit();
  }

  confirmPendingVoice(): void {
    this.voice.confirmPending();
    this.emit();
  }

  async foregroundOnlySafetyShutdown(): Promise<void> {
    try {
      await this.speech.stop(false);
    } catch (error) {
      this.recordException('后台语音清理', error instanceof Error ? error : new Error(String(error)));
    }
    this.voice.setEnabled(false);
    this.log('应用进入后台，执行回中/降落保护并断开');
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
    if (command.kind === 'center') return this.center();
    if (command.kind === 'circle_stop') return this.stopCircle();
    if (command.kind === 'takeoff') return this.takeoffConfirmed();
    if (command.kind === 'circle_prepare') return this.prepareCircle();
    if (command.kind === 'circle_start') return this.startCircleConfirmed();
    if (command.kind === 'photo') return this.shoot();
    if (command.kind === 'record_start') return this.startRecording();
    if (command.kind === 'record_stop') return this.stopRecording();
    if (command.kind === 'move' && command.direction !== undefined) {
      return this.move(command.direction, command.durationSeconds ?? 0.5);
    }
  }

  private async run<T>(name: string, operation: () => Promise<OperationResult<T>>,
    rejectWhenBusy: boolean = true): Promise<void> {
    if (this.busyValue && rejectWhenBusy) {
      this.log(`${name}: 已有操作执行中`);
      this.emit();
      return;
    }
    this.busyValue = true;
    this.lastOperationValue = name;
    this.emit();
    try {
      this.recordResult(name, await operation());
    } catch (error) {
      this.recordException(name, error as Error);
    } finally {
      this.busyValue = false;
      this.emit();
    }
  }

  private recordResult<T>(name: string, result: OperationResult<T>): void {
    if (result.ok) {
      this.lastErrorLayerValue = '';
      this.lastErrorValue = '';
      this.log(`${name}: 完成`);
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
