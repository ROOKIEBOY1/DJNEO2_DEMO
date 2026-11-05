import { AppRuntime, ConsoleSnapshot } from '../core/domain/AppController';
import { DollyDemoWindow } from '../core/platform/DollyDemoWindow';

class DemoSurfaceController extends XComponentController {
  onSurfaceCreated(surfaceId: string): void { AppRuntime.controller().video.attach(surfaceId); }
  onSurfaceDestroyed(surfaceId: string): void { AppRuntime.controller().video.detach(surfaceId); }
}

@Entry
@Component
struct DollyDemo {
  private controller = AppRuntime.controller();
  private surface = new DemoSurfaceController();
  private timer?: number;
  @State state: ConsoleSnapshot = this.controller.snapshot();
  @State playbackError: boolean = false;

  aboutToAppear(): void {
    this.timer = setInterval(() => { this.state = this.controller.snapshot(); }, 250);
  }

  aboutToDisappear(): void {
    if (this.timer !== undefined) clearInterval(this.timer);
  }

  private close(): void {
    this.controller.closeDollyDemo();
    if (this.controller.snapshot().dollyDemo.stage === 'closed') {
      DollyDemoWindow.close().catch(() => {});
    }
  }

  onBackPress(): boolean { this.close(); return true; }

  build() {
    Column() {
      Row() {
        Text('拍摄对话').fontSize(19).fontWeight(FontWeight.Bold)
        Blank()
        Button('关闭').fontSize(13).enabled(!this.state.busy && this.state.dollyDemo.stage !== 'shooting')
          .onClick(() => this.close())
      }.width('100%').padding(14)
      Scroll() {
        Column({ space: 12 }) {
          Row() {
            Blank()
            Text('帮我拍一条希区柯克运镜').fontSize(15).fontColor(Color.White)
              .backgroundColor('#175CD3').padding(12).borderRadius(14)
          }.width('100%')
          Text('好的').fontSize(15).backgroundColor('#E4E7EC').padding(12).borderRadius(14)
          Stack() {
            XComponent({ id: 'neoDollyVideo', type: XComponentType.SURFACE, controller: this.surface })
              .width('100%').height('100%')
            if (this.state.dollyDemo.stage === 'confirm' && this.state.dollyDemo.candidate !== undefined && this.state.videoPreview.state === 'live' &&
              this.state.videoPreview.stats.lastRenderedAgeMs <= 1000) {
              Column() {
                Text('VLM 选中 · 模拟').fontSize(11).fontColor(Color.White).backgroundColor('#6938EF').padding(3)
              }.width(`${this.state.dollyDemo.candidate.width * 100}%`).height(`${this.state.dollyDemo.candidate.height * 100}%`)
                .position({ x: `${this.state.dollyDemo.candidate.left * 100}%`, y: `${this.state.dollyDemo.candidate.top * 100}%` })
                .border({ width: 2, color: '#B692F6' }).alignItems(HorizontalAlign.Start)
                .hitTestBehavior(HitTestMode.None)
            }
            if (this.state.videoPreview.state !== 'live') {
              Text(this.state.videoPreview.label).fontColor(Color.White).padding(8).backgroundColor('#CC101828')
            }
          }.width('100%').aspectRatio(this.state.videoPreview.stats.width > 0 && this.state.videoPreview.stats.height > 0 ?
            this.state.videoPreview.stats.width / this.state.videoPreview.stats.height : 16 / 9)
            .backgroundColor(Color.Black)
          Text(this.state.dollyDemo.message).fontSize(13).fontColor('#344054').width('100%')
          if (this.state.dollyDemo.stage === 'confirm') {
            Button('请确认画面是否进行拍摄').width('100%').enabled(!this.state.busy &&
              this.state.dollyDemo.candidate !== undefined && this.state.videoPreview.state === 'live')
              .onClick(() => this.controller.confirmDollyDemo())
          }
          if (this.state.dollyDemo.stage === 'recorded') {
            Button('查看效果').width('100%').enabled(!this.state.busy)
              .onClick(() => this.controller.viewDollyDemoVideo())
          }
          if (this.state.dollyDemo.stage === 'playback') {
            Video({ src: this.state.dollyDemo.videoUri }).controls(true).autoPlay(false)
              .width('100%').aspectRatio(16 / 9).onError(() => { this.playbackError = true; })
            if (this.playbackError) Text('录像已下载，本地播放器打开失败。').fontColor('#B42318')
          }
          if (this.state.dollyDemo.stage === 'preflight' || (this.state.flight.takeoffSent && !this.state.flight.landRequested)) {
            Row({ space: 10 }) {
              Button('停止拍摄').onClick(() => this.controller.center())
              Button('降落').onClick(() => this.controller.land())
            }
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(14)
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor('#F8FAFC')
  }
}
