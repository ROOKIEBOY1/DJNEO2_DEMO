import { AppRuntime, ConsoleSnapshot } from '../core/domain/AppController';
import { MovementDirection } from '../core/protocol/StickCodec';
import { AircraftProfileSummary } from '../core/profile/AircraftProfileStore';
import { DollyFraming } from '../core/protocol/NativeTaskCodec';

interface HeaderView { title: string; detail: string; }
interface DiagnosticView { label: string; value: string; }

@Entry
@Component
struct Index {
  private controller = AppRuntime.controller();
  @State state: ConsoleSnapshot = this.controller.snapshot();
  @State routingJson: string = '';
  @State registrationJson: string = '';
  @State profileName: string = 'Neo 2 12AD';
  @State profileSsid: string = 'DJI-NEO2-12AD';
  @State profilePassword: string = '';
  @State creatingProfile: boolean = false;
  @State commandText: string = '';
  @State calibrationDirection: MovementDirection = 'forward';
  @State calibrationSeconds: string = '1';
  @State calibrationAmount: string = '';
  @State showCalibration: boolean = false;

  aboutToAppear(): void {
    this.controller.setListener((snapshot: ConsoleSnapshot) => this.state = snapshot);
  }

  aboutToDisappear(): void {
    this.controller.setListener(undefined);
  }

  private ageText(age?: number): string {
    return age === undefined ? '--' : `${age} ms`;
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

  build() {
    Column() {
      Row() {
        Column() {
          Text('NEO 2 CONTROL').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#101828')
          Text('前台工程控制台').fontSize(12).fontColor('#667085')
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Text(this.state.session.phase).fontSize(12).fontColor('#344054')
          .backgroundColor('#F2F4F7').padding(7).borderRadius(4)
      }.width('100%').height(58).padding({ left: 16, right: 16 })
        .border({ width: { bottom: 1 }, color: '#E4E7EC' })

      Scroll() {
        Column() {
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
          Text('滑动变焦：先设置景别、倍率及渐远，再准备/启动；跟随和变焦仅从地面启动，每连接一轮。')
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

          this.SectionHeader({ title: '视频诊断', detail: 'HEVC 预览适配器待真机接入' })
          Column() {
            Text(this.state.session.videoAgeMs === undefined ? '等待视频码流' : '已接收 HEVC 分片码流')
              .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#344054')
            Text(`待组帧 ${this.state.session.video.pending} · 丢帧 ${this.state.session.video.droppedFrames} · 坏包 ${this.state.session.video.invalidPackets}`)
              .fontSize(12).fontColor('#667085').margin({ top: 6 })
          }.width('100%').height(92).justifyContent(FlexAlign.Center).backgroundColor('#F2F4F7').borderRadius(4)

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
          Blank().height(32)
        }.width('100%').padding({ left: 16, right: 16 })
      }.layoutWeight(1).scrollBar(BarState.Auto)
    }.width('100%').height('100%').backgroundColor('#FFFFFF')
  }
}
