import { AppRuntime, ConsoleSnapshot } from '../core/domain/AppController';
import { MovementDirection } from '../core/protocol/StickCodec';
import { AircraftProfileSummary } from '../core/profile/AircraftProfileStore';
import { DollyFraming } from '../core/protocol/NativeTaskCodec';
import { promptAction, window } from '@kit.ArkUI';
import { SubjectBox } from '../core/domain/SubjectObservation';
import { DollyDemoWindow } from '../core/platform/DollyDemoWindow';
import { AssistantSheet } from '../components/AssistantSheet';
import { AssistantConversation } from '../core/domain/AssistantConversation';
import { PreviewRecordingClock } from '../core/domain/PreviewRecordingClock';

interface HeaderView { title: string; detail: string; }
interface DiagnosticView { label: string; value: string; }

class VideoSurfaceController extends XComponentController {
  private surfaceId: string = '';
  onSurfaceCreated(surfaceId: string): void {
    this.surfaceId = surfaceId;
    if (AppRuntime.controller().snapshot().dollyDemo.stage === 'closed') this.restore();
  }
  onSurfaceDestroyed(surfaceId: string): void {
    if (this.surfaceId === surfaceId) this.surfaceId = '';
    AppRuntime.controller().video.detach(surfaceId);
  }
  restore(): void { if (this.surfaceId.length > 0) AppRuntime.controller().video.attach(this.surfaceId); }
}

@Entry
@Component
struct Index {
  private assistantConversation = new AssistantConversation();
  private previewRecordingClock = new PreviewRecordingClock();
  @State @Watch('assistantVisibilityChanged') showAssistant: boolean = false;
  @State showConsole: boolean = false;
  @State assistantHeight: number = 70;
  private assistantDragHeight: number = 70;
  private pageHeight: number = 800;
  private controller = AppRuntime.controller();
  private videoSurface: VideoSurfaceController = new VideoSurfaceController();
  private desiredScreenOn: boolean = false;
  @State state: ConsoleSnapshot = this.controller.snapshot();
  @State routingJson: string = '';
  @State registrationJson: string = '';
  @State profileName: string = '';
  @State profileSsid: string = '';
  @State profilePassword: string = '';
  @State creatingProfile: boolean = false;
  @State commandText: string = '';
  @State calibrationDirection: MovementDirection = 'forward';
  @State calibrationSeconds: string = '1';
  @State calibrationAmount: string = '';
  @State showCalibration: boolean = false;
  @State showEngineering: boolean = false;
  @State exportingVlmSample: boolean = false;
  @State vlmListeningActive: boolean = false;
  @State vlmSampleStatus: string = '';
  @State cloudKeyInput: string = '';
  @State cloudSettingsBusy: boolean = false;
  @State cloudSettingsNote: string = '';

  private assistantVisibilityChanged(): void {
    this.getUIContext().animateTo({ duration: 380, curve: Curve.Friction }, () => {
      this.assistantHeight = this.showAssistant ? 100 : 70;
    });
  }

  aboutToAppear(): void {
    const profile = this.selectedProfile();
    if (profile !== undefined) this.editProfile(profile);
    this.controller.setListener((snapshot: ConsoleSnapshot) => {
      this.previewRecordingClock.observe(snapshot, Date.now());
      const restore = this.state.dollyDemo.stage !== 'closed' && snapshot.dollyDemo.stage === 'closed';
      if (this.state.agentConfirmation.length > 0 && snapshot.agentConfirmation.length === 0 &&
        snapshot.agentFeedback === '动作确认已过期，请重新发起') this.vlmSampleStatus = snapshot.agentFeedback;
      if (!snapshot.voice.listening && snapshot.agentFeedback.length > 0 &&
        snapshot.agentFeedback !== this.state.agentFeedback) this.vlmSampleStatus = snapshot.agentFeedback;
      this.state = snapshot;
      if (restore) this.videoSurface.restore();
      this.keepVideoScreenOn(snapshot.videoPreview.stats.running);
    });
    this.controller.ensureReadyConnection().catch((error: Error) => { this.vlmSampleStatus = error.message; });
    this.controller.initializeCloudVlm().catch((error: Error) => { this.cloudSettingsNote = error.message; });
  }

  aboutToDisappear(): void {
    this.stopVlmListening();
    this.controller.cancelAgentAction();
    this.controller.video.detach();
    this.keepVideoScreenOn(false);
    this.controller.setListener(undefined);
  }

  private ageText(age?: number): string {
    return age === undefined ? '--' : `${age} ms`;
  }

  private connectionLabel(): string {
    if (this.state.session.phase === 'ready') return '已连接';
    if (this.state.session.phase === 'disconnected' || this.state.session.phase === 'failed') return '未连接 · 点此重试';
    if (this.state.session.phase === 'registering') return '正在初始化';
    return '正在连接';
  }

  private async runVoiceControl(): Promise<void> {
    if (this.exportingVlmSample) return;
    this.exportingVlmSample = true;
    this.vlmListeningActive = true;
    this.vlmSampleStatus = '正在打开麦克风…';
    let selectedId: number | undefined;
    let waitingForFollowUp = false;
    try {
      const generation = this.state.flight.generation;
      while (this.vlmListeningActive && this.state.flight.generation === generation) {
        waitingForFollowUp = selectedId !== undefined;
        const description = await this.controller.listenForSubjectDescription(() => {
          this.vlmSampleStatus = selectedId === undefined ? '请说你想选谁或执行什么动作…' :
            `已选中主体 #${selectedId}，可以继续说「换成另外一个」`;
        }, waitingForFollowUp);
        waitingForFollowUp = false;
        if (!this.vlmListeningActive || this.state.flight.generation !== generation) return;
        const localFlight = await this.controller.executeLocalFlightVoice(description);
        if (localFlight !== undefined) {
          this.vlmSampleStatus = localFlight.message;
          return;
        }
        this.vlmSampleStatus = `已听到「${description}」，正在理解…`;
        const outcome = await this.controller.runCloudVoiceRequest(description);
        selectedId = outcome.subjectId;
        if (this.vlmListeningActive) this.vlmSampleStatus = outcome.message;
        if (outcome.confirmationRequired || selectedId === undefined) return;
      }
    } catch (error) {
      if (this.vlmListeningActive) {
        this.vlmSampleStatus = waitingForFollowUp ? `已选中主体 #${selectedId}，后续聆听已结束` :
          (error instanceof Error ? error.message : '语音控制请求失败，请检查手机上网连接');
      }
    } finally {
      this.vlmListeningActive = false;
      this.exportingVlmSample = false;
    }
  }

  private stopVlmListening(): void {
    if (!this.vlmListeningActive) return;
    this.vlmListeningActive = false;
    this.vlmSampleStatus = '语音控制已停止';
    this.controller.cancelAgentAction();
    this.controller.stopSubjectDescription().catch(() => {});
  }

  private async confirmAgentAction(): Promise<void> {
    this.vlmSampleStatus = '正在执行确认的动作…';
    try {
      const outcome = await this.controller.confirmAgentAction();
      this.vlmSampleStatus = outcome.message;
    } catch (error) {
      this.vlmSampleStatus = error instanceof Error ? error.message : '动作执行失败';
    }
  }

  private async confirmGroundDolly(): Promise<void> {
    try {
      const outcome = await this.controller.confirmGroundDolly();
      this.vlmSampleStatus = outcome.message;
    } catch (error) {
      this.vlmSampleStatus = error instanceof Error ? error.message : '拍摄启动失败';
    }
  }

  private async executeGroundDolly(): Promise<void> {
    try {
      const outcome = await this.controller.executeGroundDolly();
      this.vlmSampleStatus = outcome.message;
    } catch (error) {
      this.vlmSampleStatus = error instanceof Error ? error.message : '拍摄启动失败';
    }
  }

  private async savePreviewToGallery(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) throw new Error('当前页面尚未就绪，请重试');
      this.vlmSampleStatus = '正在保存到图库…';
      await this.controller.saveAgentMedia(context);
      this.vlmSampleStatus = '已保存到图库';
    } catch (error) {
      this.vlmSampleStatus = `保存图库失败，预览已保留：${error instanceof Error ? error.message : '请重试'}`;
    }
  }

  private async updateCloudSettings(action: string): Promise<void> {
    if (this.cloudSettingsBusy) return;
    this.cloudSettingsBusy = true; this.cloudSettingsNote = '';
    try {
      if (action === 'save') {
        await this.controller.saveCloudVlmKey(this.cloudKeyInput); this.cloudKeyInput = '';
      } else if (action === 'clear') {
        await this.controller.clearCloudVlmKey(); this.cloudKeyInput = '';
      } else await this.controller.testCloudVlmConnection();
      this.cloudSettingsNote = this.controller.snapshot().cloudVlmStatus;
    } catch (error) { this.cloudSettingsNote = error instanceof Error ? error.message : '云端配置操作失败'; }
    finally { this.cloudSettingsBusy = false; }
  }

  private subjectSummary(): string {
    const subject = this.state.session.telemetry.subject;
    if (subject === undefined || subject.candidateCount === undefined) return '暂无有效候选数据';
    if (subject.candidateCount === 0) return '未检测到候选主体';
    return `候选 ${subject.candidateCount} 个 · 编号 ${subject.candidates.map((item: SubjectBox) => item.id).join('、')}`;
  }

  private keepVideoScreenOn(enabled: boolean): void {
    if (enabled === this.desiredScreenOn) return;
    this.desiredScreenOn = enabled;
    window.getLastWindow(getContext(this)).then((mainWindow: window.Window) => {
      if (this.desiredScreenOn === enabled) return mainWindow.setWindowKeepScreenOn(enabled);
      return;
    }).catch(() => {});
  }

  private move(direction: MovementDirection): void {
    this.controller.move(direction, this.state.defaultMovementSeconds);
  }

  private selectedProfile(): AircraftProfileSummary | undefined {
    return this.state.aircraftProfiles.find((profile: AircraftProfileSummary) =>
      profile.id === this.state.selectedAircraftId);
  }

  private editProfile(profile: AircraftProfileSummary): void {
    this.creatingProfile = false;
    this.profileName = profile.displayName;
    this.profileSsid = profile.ssid;
    this.profilePassword = '';
  }

  @Builder
  SectionHeader($$: HeaderView) {
    Row() {
      Text($$.title).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#17202A')
      Blank()
      Text($$.detail).fontSize(12).fontColor('#667085').maxLines(1)
    }.width('100%').margin({ top: 16, bottom: 8 })
  }

  @Builder
  Diagnostic($$: DiagnosticView) {
    Column() {
      Text($$.label).fontSize(11).fontColor('#667085')
      Text($$.value).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1D2939').margin({ top: 2 })
    }.width('100%').height(54).alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center)
      .padding({ left: 10 }).backgroundColor('#F9FAFB').borderRadius(4)
  }

  @Builder
  controlConsole() {
    Column() {
      Row() {
        Column() {
          Text('NEO 2 CONTROL').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#101828')
            .gesture(LongPressGesture({ repeat: false, duration: 1000 }).onAction(() => {
              this.showEngineering = !this.showEngineering;
              if (!this.showEngineering) { this.showConsole = false; this.showAssistant = true; }
            }))
          Text(this.showEngineering ? '设置 · 长按标题返回' : '长按标题进入设置').fontSize(12).fontColor('#667085')
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Text(this.connectionLabel()).fontSize(12).fontColor('#344054')
          .backgroundColor('#F2F4F7').padding(7).borderRadius(4)
          .onClick(() => this.controller.ensureReadyConnection())
      }.width('100%').height(58).padding({ left: 16, right: 16 })
        .border({ width: { bottom: 1 }, color: '#E4E7EC' })

      Scroll() {
        Column() {
          if (this.showEngineering) {
            this.SectionHeader({ title: '云端语音', detail: this.state.cloudVlmConfigured ? '手机直连 · 已配置' : '待配置' })
            Text(this.state.cloudVlmStatus).fontSize(12).fontColor('#344054').width('100%')
            TextInput({ text: this.cloudKeyInput, placeholder: 'DeepSeek API Key（仅保存到手机）' })
              .type(InputType.Password).width('100%').margin({ top: 8 })
              .enabled(!this.cloudSettingsBusy && !this.state.busy)
              .onChange((value: string) => this.cloudKeyInput = value)
            Row({ space: 8 }) {
              Button('保存密钥').fontSize(13).layoutWeight(1)
                .enabled(!this.cloudSettingsBusy && !this.state.busy && this.cloudKeyInput.length > 0)
                .onClick(() => this.updateCloudSettings('save'))
              Button('测试连接').fontSize(13).layoutWeight(1)
                .enabled(!this.cloudSettingsBusy && !this.state.busy)
                .onClick(() => this.updateCloudSettings('test'))
              Button('清除密钥').fontSize(13).layoutWeight(1)
                .enabled(!this.cloudSettingsBusy && !this.state.busy && this.state.cloudVlmConfigured)
                .onClick(() => this.updateCloudSettings('clear'))
            }.width('100%').margin({ top: 8 })
            if (this.cloudSettingsNote.length > 0) Text(this.cloudSettingsNote).fontSize(12).fontColor('#344054').width('100%')
            this.SectionHeader({ title: '目标飞机', detail: this.state.wifiProgress })
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.state.aircraftProfiles, (profile: AircraftProfileSummary) => {
                Button(`${profile.displayName}\n${profile.ssid}`)
                  .buttonStyle(profile.id === this.state.selectedAircraftId ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
                  .margin({ right: 8, bottom: 8 }).onClick(() => {
                    this.controller.selectAircraft(profile.id);
                    this.editProfile(profile);
                  })
              }, (profile: AircraftProfileSummary) => profile.id)
            }.width('100%')
            if (this.selectedProfile() !== undefined) {
              Text(`当前目标：${this.selectedProfile()?.displayName} · ${this.selectedProfile()?.ssid}`)
                .width('100%').fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1D2939')
              Text(`凭据 ${this.selectedProfile()?.configured ? '已配置' : '未配置'} · 注册 ${this.selectedProfile()?.registrationReady ? '就绪' : '未就绪'} · 路由 ${this.selectedProfile()?.routingReady ? '就绪' : '未导入'}`)
                .width('100%').fontSize(12).fontColor('#667085').margin({ top: 4, bottom: 8 })
            }
            Row({ space: 8 }) {
              TextInput({ text: this.profileName, placeholder: '档案名称' }).layoutWeight(1)
                .onChange((value: string) => this.profileName = value)
              TextInput({ text: this.profileSsid, placeholder: '飞机 SSID' }).layoutWeight(1)
                .onChange((value: string) => this.profileSsid = value)
            }.width('100%')
            TextInput({ text: this.profilePassword, placeholder: 'Wi-Fi 密码（保存后不再显示）' })
              .type(InputType.Password).width('100%').margin({ top: 8 })
              .onChange((value: string) => this.profilePassword = value)
            Row({ space: 8 }) {
              Button('新增飞机').layoutWeight(1).buttonStyle(ButtonStyleMode.NORMAL).onClick(() => {
                this.creatingProfile = true;
                this.profileName = '';
                this.profileSsid = '';
                this.profilePassword = '';
              })
              Button(this.creatingProfile ? '创建档案' : '保存凭据').layoutWeight(1).onClick(() => {
                if (this.creatingProfile) this.controller.createAircraft(this.profileName, this.profileSsid, this.profilePassword)
                else this.controller.updateSelectedAircraft(this.profileName, this.profileSsid, this.profilePassword)
                this.profilePassword = '';
                this.creatingProfile = false;
              })
              Button('长按删除').layoutWeight(1).backgroundColor('#B42318')
                .gesture(LongPressGesture({ repeat: false, duration: 1500 })
                  .onAction(() => this.controller.removeSelectedAircraft(true)))
            }.width('100%').margin({ top: 8 })

            this.SectionHeader({ title: '连接与注册', detail: `${this.state.session.localAddress} · ${this.state.session.sessionHex}` })
            Row({ space: 8 }) {
              Button('连接').enabled(this.selectedProfile()?.configured === true &&
                this.selectedProfile()?.registrationReady === true &&
                this.state.session.phase === 'disconnected').onClick(() => this.controller.connectSelectedAircraft())
              Button('初始化').enabled(this.state.session.phase === 'registering').onClick(() => this.controller.initialize())
              Button('断开').buttonStyle(ButtonStyleMode.NORMAL).onClick(() => this.controller.disconnect())
            }.width('100%')
            Grid() {
              GridItem() { this.Diagnostic({ label: '下行年龄', value: this.ageText(this.state.session.downlinkAgeMs) }) }
              GridItem() { this.Diagnostic({ label: '视频年龄', value: this.ageText(this.state.session.videoAgeMs) }) }
              GridItem() { this.Diagnostic({ label: '设备验证', value: this.state.session.deviceVerified ? '通过' : '未通过' }) }
              GridItem() { this.Diagnostic({ label: '可靠窗口', value: `${this.state.session.transport?.pending ?? 0}/32` }) }
              GridItem() { this.Diagnostic({ label: '接收包', value: `${this.state.session.receivedPackets}` }) }
              GridItem() { this.Diagnostic({ label: '路由计数', value: `${this.state.session.routing?.next ?? '--'}` }) }
              GridItem() { this.Diagnostic({ label: '握手尝试', value: `${this.state.session.handshakeAttempt}/60` }) }
              GridItem() { this.Diagnostic({ label: 'UDP 接收/发送', value: `${this.state.session.receivedDatagrams}/${this.state.session.sentDatagrams}` }) }
            }.columnsTemplate('1fr 1fr').columnsGap(8).rowsGap(8).width('100%').margin({ top: 10 })
            Text(`UDP 来源：${this.state.session.lastUdpPeer}`).width('100%').fontSize(11)
              .fontColor('#667085').margin({ top: 6 })
            TextArea({ text: this.routingJson, placeholder: '粘贴最新 routing-state JSON；不会生成低位默认状态' })
              .height(76).width('100%').fontSize(12).margin({ top: 10 })
              .onChange((value: string) => this.routingJson = value)
            Row({ space: 8 }) {
              Button('校验并导入路由状态').layoutWeight(1).buttonStyle(ButtonStyleMode.NORMAL)
                .enabled(this.routingJson.trim().length > 0 && this.state.session.phase === 'disconnected')
                .onClick(() => this.controller.importRoutingState(this.routingJson))
              Button('断电重建路由').layoutWeight(1).buttonStyle(ButtonStyleMode.NORMAL)
                .enabled(this.state.session.phase === 'disconnected' && this.selectedProfile()?.routingReady !== true)
                .gesture(LongPressGesture({ repeat: false, duration: 1500 })
                  .onAction(() => this.controller.rebuildRoutingState()))
            }.width('100%')
            TextArea({ text: this.registrationJson, placeholder: '新飞机：粘贴验证后的 registration-profile JSON' })
              .height(76).width('100%').fontSize(12).margin({ top: 8 })
              .onChange((value: string) => this.registrationJson = value)
            Button('校验并导入注册资料').width('100%').buttonStyle(ButtonStyleMode.NORMAL)
              .enabled(this.registrationJson.trim().length > 0 && this.state.session.phase === 'disconnected')
              .onClick(() => this.controller.importRegistrationProfile(this.registrationJson))

            this.SectionHeader({ title: '安全飞控', detail: `${this.state.defaultMovementSeconds.toFixed(1)} 秒/次（按钮/语音）` })
            Row({ space: 8 }) {
              Button('长按起飞 1.5s').layoutWeight(1).backgroundColor('#B54708')
                .gesture(LongPressGesture({ repeat: false, duration: 1500 }).onAction(() => this.controller.takeoffConfirmed()))
              Button('降落').layoutWeight(1).backgroundColor('#B42318').onClick(() => this.controller.land())
            }.width('100%')
            Row({ space: 8 }) {
              Text('0.5').fontSize(12).fontColor('#667085')
              Slider({ value: this.state.defaultMovementSeconds, min: 0.5, max: 10, step: 0.5 }).layoutWeight(1)
                .onChange((value: number) => this.controller.setMovementSeconds(value))
              Text('10.0').fontSize(12).fontColor('#667085')
            }.width('100%').height(44)
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                Button('↶').layoutWeight(1).onClick(() => this.move('turn_left'))
                Button('↑').layoutWeight(1).onClick(() => this.move('forward'))
                Button('↷').layoutWeight(1).onClick(() => this.move('turn_right'))
              }
              Row({ space: 8 }) {
                Button('←').layoutWeight(1).onClick(() => this.move('left'))
                Button('回中').layoutWeight(1).backgroundColor('#344054').onClick(() => this.controller.center())
                Button('→').layoutWeight(1).onClick(() => this.move('right'))
              }
              Row({ space: 8 }) {
                Button('上升').layoutWeight(1).onClick(() => this.move('up'))
                Button('↓').layoutWeight(1).onClick(() => this.move('backward'))
                Button('下降').layoutWeight(1).onClick(() => this.move('down'))
              }
            }.width('100%')
            Text(`起飞请求:${this.state.flight.takeoffSent ? '是' : '否'} · ACK:${this.state.flight.takeoffAcknowledged ? '是' : '否'} · 空中遥测:${this.state.session.telemetry.flight?.airborne === true ? '是' : '否'}`)
              .width('100%').fontSize(12).fontColor('#475467').margin({ top: 8 })

            this.SectionHeader({ title: '原生任务', detail: this.state.nativeTask.executionObserved ? '已观察执行' : '尚未观察执行' })
            Text(`当前任务：${this.state.nativeTask.kind} · 启动回复：${this.state.nativeTask.startReply || '--'} · 停止回复：${this.state.nativeTask.stopReply || '--'}`)
              .fontSize(12).fontColor('#475467').width('100%')
            Text(`环绕半径：${this.state.nativeConfig.radiusMeters}米（2–10米）`).width('100%').fontSize(14).margin({ top: 8 })
            Slider({ value: this.state.nativeConfig.radiusMeters, min: 2, max: 10, step: 1 })
              .onChange((value: number) => this.controller.setTaskSettings(value, this.state.nativeConfig.framing,
                this.state.nativeConfig.zoom, this.state.nativeConfig.retreat)).width('100%')
            Row({ space: 8 }) {
              Button('准备/读回').layoutWeight(1).onClick(() => this.controller.prepareCircle())
              Button('长按环绕').layoutWeight(1).backgroundColor('#B54708')
                .gesture(LongPressGesture({ repeat: false, duration: 1500 }).onAction(() => this.controller.startCircleConfirmed()))
              Button('停止').layoutWeight(1).backgroundColor('#B42318').onClick(() => this.controller.stopCircle())
            }.width('100%')
            Row({ space: 8 }) {
              Button('准备跟随').layoutWeight(1).onClick(() => this.controller.prepareNative('follow'))
              Button('长按跟随').layoutWeight(1).backgroundColor('#B54708')
                .gesture(LongPressGesture({ repeat: false, duration: 1500 }).onAction(() => this.controller.startNativeConfirmed('follow')))
            }.width('100%').margin({ top: 8 })
            Text('滑动变焦：在地面准备。可在地面长按启动，或普通起飞后选中主体，通过拍摄对话确认空中启动。')
              .width('100%').fontSize(12).fontColor('#667085').margin({ top: 8 })
            Row({ space: 8 }) {
              ForEach(['半身', '全身', '远景'], (framing: string) => {
                Button(framing).layoutWeight(1)
                  .buttonStyle(this.state.nativeConfig.framing === framing ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
                  .onClick(() => this.controller.setTaskSettings(this.state.nativeConfig.radiusMeters,
                    framing as DollyFraming, this.state.nativeConfig.zoom, this.state.nativeConfig.retreat))
              })
            }.width('100%')
            Row({ space: 8 }) {
              Button(`倍率 1–${this.state.nativeConfig.zoom}倍`).layoutWeight(1).onClick(() => this.controller.setTaskSettings(
                this.state.nativeConfig.radiusMeters, this.state.nativeConfig.framing,
                this.state.nativeConfig.zoom === 2 ? 3 : 2, this.state.nativeConfig.retreat))
              Button(this.state.nativeConfig.retreat ? '渐远：开' : '渐远：关').layoutWeight(1).onClick(() => this.controller.setTaskSettings(
                this.state.nativeConfig.radiusMeters, this.state.nativeConfig.framing,
                this.state.nativeConfig.zoom, !this.state.nativeConfig.retreat))
            }.width('100%').margin({ top: 8 })
            Row({ space: 8 }) {
              Button('准备变焦').layoutWeight(1).onClick(() => this.controller.prepareNative('dolly'))
              Button('长按变焦').layoutWeight(1).backgroundColor('#B54708')
                .gesture(LongPressGesture({ repeat: false, duration: 1500 }).onAction(() => this.controller.startNativeConfirmed('dolly')))
            }.width('100%').margin({ top: 8 })

            Button('拍摄希区柯克运镜').width('100%').margin({ top: 14 })
              .enabled(!this.state.busy && this.state.session.phase === 'ready')
              .onClick(() => {
                this.controller.openDollyDemo();
                DollyDemoWindow.open().then(() => this.controller.takeoffForDollyDemo()).catch(() => {
                  this.controller.closeDollyDemo();
                  promptAction.showToast({ message: '无法打开拍摄窗口' });
                });
              })
            Text('点击后飞机将准备并起飞，悬停后再确认构图。').fontSize(12).fontColor('#667085')
          }
          Text(this.selectedProfile()?.displayName ?? '尚未配置飞机').fontSize(16).fontWeight(FontWeight.Medium)
            .width('100%').margin({ top: 12 })
          if (this.state.lastError.length > 0) {
            Text(this.state.lastError).fontSize(12).fontColor('#B42318').width('100%').margin({ top: 6 })
          }
          this.SectionHeader({ title: '实时视频', detail: this.state.videoPreview.label })
          Stack() {
            XComponent({ id: 'neoVideo', type: XComponentType.SURFACE, controller: this.videoSurface })
              .width('100%').height('100%')
            if (this.state.dollyDemo.stage === 'closed' && this.state.videoPreview.state === 'live' &&
              this.state.videoPreview.stats.lastRenderedAgeMs <= 1000) {
              ForEach(this.state.selectedSubjectOverlay, (item: SubjectBox) => {
                Column()
                .width(`${item.width * 100}%`).height(`${item.height * 100}%`)
                .position({ x: `${item.left * 100}%`, y: `${item.top * 100}%` })
                .border({ width: 2, color: '#F472B6' }).borderRadius(5)
                .alignItems(HorizontalAlign.Start)
                .hitTestBehavior(HitTestMode.None)
              }, (item: SubjectBox) => `${item.id}:${item.left}:${item.top}:${item.width}:${item.height}`)
            }
            if (this.state.videoPreview.state !== 'live') {
              Text(this.state.videoPreview.label).fontSize(14).fontColor(Color.White)
                .padding(12).backgroundColor('#CC101828').borderRadius(6)
            }
          }.width('100%')
            .aspectRatio(this.state.videoPreview.stats.width > 0 && this.state.videoPreview.stats.height > 0 ?
              this.state.videoPreview.stats.width / this.state.videoPreview.stats.height : 16 / 9)
            .backgroundColor(Color.Black)
          Column() {
            Text(this.state.subjectScanStatus).fontSize(13).fontColor('#344054')
            Text(this.subjectSummary()).fontSize(12).fontColor('#667085')
            if (this.vlmSampleStatus.length > 0) Text(this.vlmSampleStatus).fontSize(12).fontColor('#344054')
            if (this.state.groundDolly.message.length > 0) {
              Text(this.state.groundDolly.message).fontSize(13).fontColor('#9D174D')
            }
            if (this.state.groundDolly.stage === 'confirm') {
              Row({ space: 8 }) {
                Button('确认拍摄主体').fontSize(13).enabled(!this.state.busy && this.state.selectedSubjectOverlay.length === 1)
                  .onClick(() => this.confirmGroundDolly())
              }
            }
            if (this.state.groundDolly.stage === 'plan') {
              Button('一键执行').fontSize(13).enabled(!this.state.busy && this.state.selectedSubjectOverlay.length === 1)
                .onClick(() => this.executeGroundDolly())
            }
            if (this.state.agentConfirmation.length > 0) {
              Text(`待确认 · ${this.state.agentConfirmation}`).fontSize(13).fontColor('#B54708')
              Row({ space: 8 }) {
                Button('确认执行').fontSize(12).enabled(!this.state.busy)
                  .onClick(() => this.confirmAgentAction())
                Button('取消').fontSize(12).onClick(() => {
                  this.controller.cancelAgentAction();
                  this.vlmSampleStatus = '动作已取消';
                })
              }
            }
            if (this.state.agentMediaUri.length > 0) {
              Text(this.state.agentMediaKind === 'photo' ? '飞机照片' : '飞机录像').fontSize(13)
              if (this.state.agentMediaCount > 1) {
                Row({ space: 10 }) {
                  Button('上一段').fontSize(12)
                    .enabled(!this.state.agentMediaSaving && this.state.agentMediaIndex > 0)
                    .onClick(() => this.controller.selectAgentMedia(this.state.agentMediaIndex - 1))
                  Text(`第 ${this.state.agentMediaIndex + 1} / ${this.state.agentMediaCount} 段`).fontSize(13)
                  Button('下一段').fontSize(12)
                    .enabled(!this.state.agentMediaSaving && this.state.agentMediaIndex + 1 < this.state.agentMediaCount)
                    .onClick(() => this.controller.selectAgentMedia(this.state.agentMediaIndex + 1))
                }
                Text('本次拍摄有多段录像，可分别查看和保存。').fontSize(12).fontColor('#667085')
              }
              if (this.state.agentMediaKind === 'photo') {
                Image(this.state.agentMediaUri).width('100%').height(220).objectFit(ImageFit.Contain)
              } else {
                Video({ src: this.state.agentMediaUri }).width('100%').height(220)
                  .controls(true).autoPlay(false).onError(() => {
                    this.vlmSampleStatus = '原片已下载，当前播放器无法播放此视频';
                  })
              }
              SaveButton({ text: SaveDescription.SAVE_TO_GALLERY })
                .enabled(!this.state.agentMediaSaving)
                .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) => {
                  if (result === SaveButtonOnClickResult.SUCCESS) this.savePreviewToGallery();
                  else this.vlmSampleStatus = '尚未获得图库保存授权，预览已保留';
                })
              if (this.state.agentMediaSaving) Text('正在保存到图库…').fontSize(12).fontColor('#667085')
            }
            if (this.state.session.telemetry.subject?.tracking) {
              Text('已收到跟踪框回报').fontSize(12).fontColor('#344054')
            }
            if (this.showEngineering) {
              Row({ space: 8 }) {
                Button('开始主体扫描').fontSize(12)
                  .enabled(!this.state.busy && this.state.session.phase === 'ready' && this.state.flight.takeoffSent)
                  .onClick(() => this.controller.startHoverSubjectScan())
              }.margin({ top: 6 })
              Row({ space: 8 }) {
                ForEach(this.state.session.telemetry.subject?.candidates ?? [], (item: SubjectBox) => {
                  Button(`选择 #${item.id}`).fontSize(12)
                    .enabled(!this.state.busy && this.state.session.phase === 'ready' && item.id <= 255)
                    .onClick(() => this.controller.selectSubject(item.id))
                }, (item: SubjectBox) => `${item.id}`)
                Button('取消主体').fontSize(12)
                  .enabled(!this.state.busy && this.state.session.phase === 'ready')
                  .onClick(() => this.controller.selectSubject())
              }.margin({ top: 6 })
              if (this.state.lastOperation.includes('主体') && this.state.lastError.length > 0) {
                Text(this.state.lastError).fontSize(12).fontColor('#B42318').margin({ top: 4 })
              }
              Text(`组帧 ${this.state.videoPreview.stats.assembledFrames} · 解码 ${this.state.videoPreview.stats.decodedFrames} · 送显 ${this.state.videoPreview.stats.renderedFrames}`)
                .fontSize(12).fontColor('#344054')
              Text(`积压 ${this.state.videoPreview.stats.queued} · 丢弃 ${this.state.videoPreview.stats.queueDrops} · 解码异常 ${this.state.videoPreview.stats.decodeErrors} · 画面年龄 ${this.ageText(this.state.videoPreview.stats.lastRenderedAgeMs < 0 ? undefined : this.state.videoPreview.stats.lastRenderedAgeMs)}`)
                .fontSize(12).fontColor('#667085').margin({ top: 4 })
              Text(`待组帧 ${this.state.session.video.pending} · 丢帧 ${this.state.session.video.droppedFrames} · 坏包 ${this.state.session.video.invalidPackets}`)
                .fontSize(12).fontColor('#667085').margin({ top: 6 })
            }
          }.width('100%').padding(8).backgroundColor('#F2F4F7').borderRadius(4)

          if (this.showEngineering) {
            this.SectionHeader({ title: '相机与媒体', detail: this.state.recordingRequested ? '录像请求已发送' : '相机待机' })
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
              Button('拍照').width('32%').onClick(() => this.controller.shoot())
              Button('开始录像').width('32%').onClick(() => this.controller.startRecording())
              Button('停止录像').width('32%').onClick(() => this.controller.stopRecording())
              Button('刷新目录').width('32%').margin({ top: 8 }).onClick(() => this.controller.listMedia())
              Button('下载照片').width('32%').margin({ top: 8 }).onClick(() => this.controller.downloadLatest('photo'))
              Button('下载视频').width('32%').margin({ top: 8 }).onClick(() => this.controller.downloadLatest('video'))
            }.width('100%')

            this.SectionHeader({ title: '离线中文语音', detail: this.state.voice.listening ? '连续聆听中' : this.state.voice.enabled ? '已启用' : '已禁用' })
            Row() {
              Text('启用语音/文本动作入口').fontSize(14).fontColor('#344054')
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.state.voice.enabled })
                .onChange((enabled: boolean) => this.controller.setVoiceEnabled(enabled))
            }.width('100%').height(44)
            Row({ space: 8 }) {
              Button('连续聆听').layoutWeight(1).enabled(this.state.voice.enabled && !this.state.voice.listening)
                .onClick(() => this.controller.startListening())
              Button('停止聆听').layoutWeight(1).enabled(this.state.voice.listening)
                .buttonStyle(ButtonStyleMode.NORMAL).onClick(() => this.controller.stopListening())
            }.width('100%').margin({ bottom: 8 })
            Text(`最近识别：${this.state.voice.lastTranscript || '暂无'}`).width('100%').fontSize(14).fontColor('#1D2939')
            Text(this.state.voice.feedback).width('100%').fontSize(13).fontColor('#B54708').margin({ top: 6, bottom: 8 })
            Text('例如：前进两秒、左转一点、停止、降落、环绕五米、跟随我、滑动变焦、拍照、相册、下载最新录像。启动任务先说口令，再在10秒内说“确认”。')
              .width('100%').fontSize(12).fontColor('#667085').margin({ bottom: 8 })
            Row({ space: 8 }) {
              TextInput({ text: this.commandText, placeholder: '例如：前进、降落、拍照' }).layoutWeight(1)
                .onChange((value: string) => this.commandText = value)
              Button('执行').enabled(this.state.voice.enabled && this.commandText.trim().length > 0)
                .onClick(() => this.controller.submitTranscript(this.commandText))
            }.width('100%')
            if (this.state.voice.pendingConfirmation.length > 0) {
              Row({ space: 8 }) {
                Text(`待确认 ${this.state.voice.confirmationRemainingSeconds}秒；请目视确认飞机状态`)
                  .fontColor('#B54708').layoutWeight(1)
                Button('长按确认').backgroundColor('#B54708')
                  .gesture(LongPressGesture({ repeat: false, duration: 1500 }).onAction(() => this.controller.confirmPendingVoice()))
              }.width('100%').margin({ top: 8 })
            }
            Button(this.showCalibration ? '收起实测标定' : '距离/角度实测标定').buttonStyle(ButtonStyleMode.NORMAL)
              .onClick(() => this.showCalibration = !this.showCalibration).margin({ top: 8 })
            if (this.showCalibration) {
              Text(this.state.calibrationSummary).width('100%').fontSize(12).fontColor('#667085')
              Text('手动测量同一方向的实际位移（米）或转角（度），输入实际动作秒数。保存只记录标定，不会发送飞行动作。')
                .width('100%').fontSize(12).fontColor('#667085')
              Select([{ value: '前进' }, { value: '后退' }, { value: '上升' }, { value: '下降' },
                { value: '左移' }, { value: '右移' }, { value: '左转' }, { value: '右转' }]).selected(0).value('前进')
                .onSelect((index: number) => {
                  const directions: MovementDirection[] = ['forward', 'backward', 'up', 'down', 'left', 'right', 'turn_left', 'turn_right'];
                  this.calibrationDirection = directions[index];
                })
              Row({ space: 8 }) {
                TextInput({ text: this.calibrationSeconds, placeholder: '实际动作秒数' }).type(InputType.NUMBER_DECIMAL).layoutWeight(1)
                  .onChange((value: string) => this.calibrationSeconds = value)
                TextInput({ text: this.calibrationAmount, placeholder: this.calibrationDirection.startsWith('turn_') ? '实测角度（度）' : '实测位移（米）' })
                  .type(InputType.NUMBER_DECIMAL).layoutWeight(1).onChange((value: string) => this.calibrationAmount = value)
              }.width('100%').margin({ top: 8 })
              Button('保存实测标定').onClick(() => this.controller.recordCalibration(this.calibrationDirection,
                Number(this.calibrationSeconds), Number(this.calibrationAmount))).margin({ top: 8 })
            }

            this.SectionHeader({ title: '运行日志', detail: this.state.busy ? '执行中' : this.state.lastOperation })
            if (this.state.lastError.length > 0) {
              Text(`${this.state.lastErrorLayer}: ${this.state.lastError}`).width('100%').fontSize(13)
                .fontColor('#B42318').backgroundColor('#FEF3F2').padding(10).borderRadius(4).margin({ bottom: 8 })
            }
            Column({ space: 6 }) {
              ForEach(this.state.logs, (line: string) => {
                Text(line).width('100%').fontSize(11).fontColor('#475467').maxLines(2)
              }, (line: string, index: number) => `${index}:${line}`)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }
          Blank().height(32)
        }.width('100%').padding({ left: 16, right: 16 })
      }.layoutWeight(1).scrollBar(BarState.Auto)
      Row({ space: 10 }) {
        Button('起飞').layoutWeight(1).height(52).backgroundColor('#B54708')
          .enabled(!this.state.busy && this.state.session.phase === 'ready' &&
            (this.state.session.telemetry.flightAgeMs ?? 10000) <= 1000 &&
            this.state.session.telemetry.flight?.airborne === false &&
            this.state.session.telemetry.flight.motorsOn === false)
          .gesture(LongPressGesture({ repeat: false, duration: 1500 }).onAction(() => this.controller.takeoffConfirmed()))
        Button('降落').layoutWeight(1).height(52).backgroundColor('#B42318')
          .enabled(this.state.session.phase === 'ready' || this.state.flight.takeoffSent || this.state.flight.nativeTaskMayFly)
          .onClick(() => {
            this.stopVlmListening();
            this.controller.land();
          })
        Button(this.vlmListeningActive ? (this.state.busy ? '停止动作' : '停止聆听') : '语音控制')
          .layoutWeight(1).height(52)
          .enabled(this.vlmListeningActive || (!this.exportingVlmSample && this.state.session.phase === 'ready'))
          .onClick(() => {
            if (this.vlmListeningActive) {
              if (this.state.busy) this.controller.center();
              this.stopVlmListening();
            } else this.showAssistant = true;
          })
      }.width('100%').padding(12).backgroundColor('#F9FAFB')
      Text('长按起飞 1.5 秒 · 也可点语音说“起飞”或“降落”').fontSize(11).fontColor('#667085').margin({ bottom: 8 })
    }.width('100%').height('100%').backgroundColor('#FFFFFF')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (!this.showConsole) {
        // Keep receiving codec parameters before the first voice message creates the visible chat surface.
        XComponent({ id: 'neoVideoWarmup', type: XComponentType.SURFACE, controller: this.videoSurface })
          .width('100%').height('100%').opacity(0).hitTestBehavior(HitTestMode.None)
      }
      Image($r('app.media.demo_desktop_background')).width('100%').height('100%').objectFit(ImageFit.Cover)
      if (this.showConsole) this.controlConsole()
      else this.assistantContent()
    }.width('100%').height('100%')
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const height = Number(newArea.height);
        if (height > 0) this.pageHeight = height;
      })
  }

  @Builder
  assistantContent() {
    AssistantSheet({ expanded: $showAssistant, conversation: this.assistantConversation, recordingClock: this.previewRecordingClock, onClose: () => {
      this.showAssistant = false; this.videoSurface.restore();
    },
      onSettings: () => { this.showConsole = true; this.showEngineering = true; this.showAssistant = false; },
      onResizeStart: () => { this.assistantDragHeight = this.assistantHeight; },
      onResize: (offsetY: number) => {
        this.assistantHeight = Math.max(45, Math.min(100, this.assistantDragHeight - offsetY / this.pageHeight * 100));
      } })
      .width('100%').height(`${this.assistantHeight}%`)
  }
}
