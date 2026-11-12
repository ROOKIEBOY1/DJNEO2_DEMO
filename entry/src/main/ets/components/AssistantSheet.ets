import { AppRuntime, ConsoleSnapshot } from '../core/domain/AppController';
import { AssistantConversation, AssistantMessage } from '../core/domain/AssistantConversation';
import { AssistantAutoScroll, AssistantScrollContent } from '../core/domain/AssistantAutoScroll';
import { assistantProgress } from '../core/domain/AssistantProgress';
import { flightPlanPresentation, taskProgressPresentation, videoResultReady, videoResultPresentation, flightResultMetrics, ResultMetric, subjectTaskSnapshot, subjectConfirmationLabel } from '../core/domain/AssistantFlightPresentation';
import { PreviewRecordingClock } from '../core/domain/PreviewRecordingClock';
import { SubjectBox } from '../core/domain/SubjectObservation';
import { selectedSubjectFrames } from '../core/domain/SubjectFramePresentation';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { fileUri } from '@kit.CoreFileKit';
import { MOVIE_MUSIC_NAME, MOVIE_MUSIC_DESCRIPTION } from '../core/platform/NativeMovieExport';

class AssistantSurfaceController extends XComponentController {
  onSurfaceCreated(id: string): void { AppRuntime.controller().video.attach(id); }
  onSurfaceDestroyed(id: string): void { AppRuntime.controller().video.detach(id); }
}

interface ResultPlaybackSource { uri: string; epoch: number; }

@Component
export struct AssistantSheet {
  @Link expanded: boolean;
  conversation: AssistantConversation = new AssistantConversation();
  onClose: () => void = (): void => {};
  onSettings: () => void = (): void => {};
  onResizeStart: () => void = (): void => {};
  onResize: (offsetY: number) => void = (_offsetY: number): void => {};
  recordingClock: PreviewRecordingClock = new PreviewRecordingClock();
  private controller = AppRuntime.controller();
  private surface = new AssistantSurfaceController();
  private scroller: Scroller = new Scroller();
  private autoScroll: AssistantAutoScroll = new AssistantAutoScroll();
  private scrollTimer?: number;
  private scrollEpoch: number = 0;
  private appeared: boolean = false;
  private resultPlayer: VideoController = new VideoController();
  private timer?: number;
  private epoch: number = 0;
  @State state: ConsoleSnapshot = this.controller.snapshot();
  @State messages: AssistantMessage[] = [];
  @State listening: boolean = false;
  @State processing: boolean = false;
  @State accepting: boolean = false;
  @State status: string = '';
  @State wave: boolean = false;
  @State progressAngle: number = 0;
  @State recordingTime: string = '00:00';
  @State recordingRunning: boolean = false;
  @State mediaNote: string = '';
  @State savedMediaGroup: string = '';
  @State showMovie: boolean = false;
  @State resultPlaying: boolean = false;
  @State resultHasStarted: boolean = false;
  @State resultFullscreen: boolean = false;
  @State resultPlaybackEpoch: number = 0;
  private seenMovieOutput: string = '';

  aboutToAppear(): void {
    this.appeared = true;
    this.messages = this.conversation.snapshot().messages;
    this.updateRecordingClock();
    this.updateMovieResult();
    this.timer = setInterval(() => {
      this.state = this.controller.snapshot(); this.wave = !this.wave;
      this.updateRecordingClock();
      this.updateMovieResult();
      if (assistantProgress(this.state, this.status).busy) this.progressAngle += 45;
      this.updateAutoScroll();
    }, 250);
  }
  private updateRecordingClock(): void {
    const clock = this.recordingClock.observe(this.state, Date.now());
    this.recordingTime = clock.label; this.recordingRunning = clock.recording;
  }
  aboutToDisappear(): void {
    this.appeared = false; this.stopAutoScroll();
    if (this.timer !== undefined) clearInterval(this.timer);
    this.timer = undefined; this.epoch++;
    this.stopResultPlayback();
    if (this.processing || this.listening) {
      this.cancelProcessing(); this.controller.stopSubjectDescription().catch(() => {});
    }
  }
  private startAutoScroll(): void {
    if (!this.appeared || !this.expanded) return;
    this.stopAutoScroll();
    this.scrollEpoch = this.autoScroll.start();
    this.updateAutoScroll();
  }
  private stopAutoScroll(): void {
    if (this.scrollTimer !== undefined) clearTimeout(this.scrollTimer);
    this.scrollTimer = undefined; this.autoScroll.stop();
  }
  private updateAutoScroll(delay: number = 32): void {
    if (!this.appeared || !this.expanded) { this.stopAutoScroll(); return; }
    const content: AssistantScrollContent = {
      state: this.state, messages: this.messages, listening: this.listening, processing: this.processing,
      accepting: this.accepting, status: this.status, mediaNote: this.mediaNote,
      showingMovie: this.showingMovie(), savedMediaGroup: this.savedMediaGroup
    };
    if (this.autoScroll.observe(content)) this.queueAutoScroll(delay);
  }
  private scrollAreaChanged(): void {
    this.updateAutoScroll(0);
    this.queueAutoScroll(0);
  }
  private queueAutoScroll(delay: number = 32): void {
    if (!this.expanded || !this.autoScroll.hasPending()) return;
    if (this.scrollTimer !== undefined) return;
    const epoch = this.scrollEpoch;
    // Area callbacks settle size-changing updates; this fallback also handles equal-height button/text changes.
    this.scrollTimer = setTimeout(() => {
      if (epoch !== this.scrollEpoch) return;
      this.scrollTimer = undefined;
      if (!this.expanded) { this.stopAutoScroll(); return; }
      if (this.autoScroll.takePending(epoch)) this.scroller.scrollEdge(Edge.Bottom);
    }, delay);
  }
  private cancelProcessing(): void {
    const state = this.controller.snapshot();
    this.controller.cancelAgentAction();
    if (state.busy || state.nativeTask.activeOrUnknown || state.closeup.active) this.controller.center().catch(() => {});
  }
  private async speak(): Promise<void> {
    this.expanded = true;
    if (this.processing || this.listening) {
      this.epoch++; this.cancelProcessing();
      await this.controller.stopSubjectDescription().catch(() => {});
      this.listening = false; this.processing = false; this.status = '已停止本次请求'; return;
    }
    if (this.accepting) return;
    this.stopResultPlayback(); this.mediaNote = '';
    const epoch = ++this.epoch; this.listening = true; this.status = '正在打开麦克风…';
    try {
      const text = await this.controller.listenForSubjectDescription((): void => { this.status = '请说话，我在听…'; }, false);
      if (epoch !== this.epoch) return;
      this.listening = false; this.processing = true;
      this.conversation.submit(text); this.messages = this.conversation.snapshot().messages;
      this.status = '正在理解你的拍摄需求…';
      const local = await this.controller.executeLocalFlightVoice(text);
      if (epoch !== this.epoch) return;
      if (local !== undefined) { this.status = local.message; return; }
      const outcome = await this.controller.runCloudVoiceRequest(text);
      if (epoch !== this.epoch) return;
      this.status = outcome.message;
    } catch (error) {
      if (epoch === this.epoch) this.status = error instanceof Error ? error.message : '没有听清，请再试一次';
    } finally { if (epoch === this.epoch) { this.listening = false; this.processing = false; } }
  }
  private async confirmSubject(): Promise<void> {
    await this.confirmAction('subject');
  }
  private async executePlan(): Promise<void> {
    if (this.processing || this.listening || this.accepting) return;
    this.conversation.submit('一键执行'); this.messages = this.conversation.snapshot().messages;
    await this.confirmAction('execute');
  }
  private async confirmOtherAction(): Promise<void> {
    await this.confirmAction('agent');
  }
  private async confirmAction(action: string): Promise<void> {
    if (this.processing || this.listening || this.accepting) return;
    const epoch = ++this.epoch; this.processing = true;
    try {
      const pending = action === 'subject' ? this.controller.confirmSubjectTask() : action === 'execute' ?
        this.controller.executeSubjectPlan() : this.controller.confirmAgentAction();
      this.state = this.controller.snapshot();
      const result = await pending;
      if (epoch === this.epoch) this.status = result.message;
    } catch (error) {
      if (epoch === this.epoch) this.status = error instanceof Error ? error.message : '拍摄启动失败';
    } finally { if (epoch === this.epoch) { this.processing = false; this.state = this.controller.snapshot(); } }
  }
  private land(): void {
    this.epoch++; this.processing = false; this.listening = false;
    this.controller.stopSubjectDescription().catch(() => {});
    this.controller.land().catch(() => {}); this.status = '正在请求降落…';
  }
  private closeDialogue(): void {
    this.epoch++; this.stopAutoScroll(); this.stopResultPlayback();
    if (this.processing || this.listening) {
      this.cancelProcessing(); this.controller.stopSubjectDescription().catch(() => {});
      this.processing = false; this.listening = false; this.status = '已停止本次请求';
    }
    this.expanded = false; this.onClose();
  }
  private resultVisible(): boolean {
    return !this.listening && !this.processing && videoResultReady(this.state);
  }
  private updateMovieResult(): void {
    const movie = this.state.movie;
    if (movie.stage === 'completed' && movie.outputPath.length > 0 && movie.outputPath !== this.seenMovieOutput) {
      this.stopResultPlayback(); this.showMovie = true; this.seenMovieOutput = movie.outputPath; this.mediaNote = '';
    }
  }
  private showingMovie(): boolean { return this.showMovie && this.state.movie.stage === 'completed'; }
  private resultUri(): string {
    return this.showingMovie() ? fileUri.getUriFromPath(this.state.movie.outputPath) : this.state.agentMediaUri;
  }
  private mediaGroupKey(): string {
    return this.showingMovie() ? `movie:${this.state.movie.outputPath}` : JSON.stringify(this.state.agentMediaUris);
  }
  private stopResultPlayback(): void {
    this.resultPlaybackEpoch++;
    if (this.resultFullscreen) { try { this.resultPlayer.exitFullscreen(); } catch (_) { } }
    try { this.resultPlayer.stop(); } catch (_) { /* No prepared player yet. */ }
    this.resultPlaying = false; this.resultHasStarted = false; this.resultFullscreen = false;
  }
  private playbackSources(): ResultPlaybackSource[] {
    const source: ResultPlaybackSource = { uri: this.resultUri(), epoch: this.resultPlaybackEpoch };
    return [source];
  }
  private isCurrentPlayback(source: ResultPlaybackSource): boolean {
    return source.epoch === this.resultPlaybackEpoch && source.uri === this.resultUri();
  }
  private toggleResultPlayback(): void {
    try {
      if (this.resultPlaying) this.resultPlayer.pause();
      else this.resultPlayer.start();
    } catch (_) { this.mediaNote = '暂时无法播放，请稍后重试或保存至相册'; }
  }
  private lineLabel(line: string): string {
    const split = line.indexOf('：');
    return split < 0 ? '' : line.slice(0, split + 1);
  }
  private lineValue(line: string): string {
    const split = line.indexOf('：');
    return split < 0 ? line : line.slice(split + 1);
  }
  private subjectFrames(): SubjectBox[] {
    return selectedSubjectFrames(subjectTaskSnapshot(this.state), this.state.selectedSubjectOverlay);
  }
  private selectResult(index: number): void {
    this.stopResultPlayback(); this.showMovie = false; this.mediaNote = ''; this.controller.selectAgentMedia(index);
    this.state = this.controller.snapshot();
  }
  private demoAction(): void {
    promptAction.showToast({ message: '演示入口，暂未接入', duration: 1500 });
  }
  private async saveVideos(): Promise<void> {
    if (this.accepting || this.state.agentMediaSaving || !this.resultVisible()) return;
    const group = this.mediaGroupKey(); this.accepting = true; this.mediaNote = '正在保存至相册…';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (this.showingMovie()) await this.controller.saveMovieToGallery(context);
      else await this.controller.saveVideosToGallery(context);
      this.savedMediaGroup = group; this.mediaNote = '当前视频已保存至相册';
    } catch (error) { this.mediaNote = error instanceof Error ? error.message : '保存失败，原片仍保留，可重试'; }
    finally { this.accepting = false; }
  }
  private async composeMovie(): Promise<void> {
    if (this.accepting || this.state.movie.busy || this.state.moviePreparing) return;
    this.stopResultPlayback(); this.mediaNote = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.controller.composeMovie(context);
      this.state = this.controller.snapshot();
      this.showMovie = true;
    } catch (error) { this.mediaNote = error instanceof Error ? error.message : '成片失败，原片仍保留，可重试'; }
  }
  private switchMoviePreview(): void {
    this.stopResultPlayback(); this.showMovie = !this.showMovie; this.mediaNote = '';
  }
  private movieProgressLabel(): string {
    if (this.state.moviePreparing) return '小艺正在准备配乐…';
    if (this.state.movie.stage === 'probing') return '小艺正在整理拍摄素材…';
    if (this.state.movie.stage === 'rendering') return '小艺正在添加配乐与淡入淡出…';
    if (this.state.movie.stage === 'finalizing') return '小艺正在完成成片导出…';
    if (this.state.movie.stage === 'failed') return `成片未完成：${this.state.movie.error}`;
    if (this.state.movie.busy) return '小艺正在取消制作，请稍候…';
    return '已取消制作，原片仍保留';
  }
  private async retryVideoReturn(): Promise<void> {
    if (this.processing || this.state.busy) return;
    this.stopResultPlayback();
    const epoch = ++this.epoch; this.processing = true; this.status = '正在重试取回本次录像…';
    try {
      await this.controller.retryCapturedVideo();
      if (epoch === this.epoch) this.status = '本次录像已取回';
    } catch (error) {
      if (epoch === this.epoch) this.status = error instanceof Error ? error.message : '录像取回失败，可重试';
    } finally { if (epoch === this.epoch) this.processing = false; }
  }
  private async recoverVideoPreview(): Promise<void> {
    const epoch = this.epoch;
    const session = this.controller.snapshot().session;
    try { await this.controller.recoverVideoPreview(); }
    catch (error) {
      if (!this.appeared || epoch !== this.epoch) return;
      const current = this.controller.snapshot().session;
      if (session.generation !== current.generation || session.sessionHex !== current.sessionHex) return;
      this.status = error instanceof Error ? error.message : '画面恢复请求未完成';
    }
  }

  @Builder
  liveCard() {
    Column({ space: 10 }) {
      Column({ space: 5 }) {
        Row({ space: 7 }) {
          if (subjectTaskSnapshot(this.state).stage === 'plan' || this.resultVisible()) {
            Text('✓').fontSize(19).fontColor('#6C7882').width(19)
          } else {
            Image($r('app.media.assistant_progress_orbit')).width(19).height(19)
              .rotate({ angle: this.progressAngle }).animation({ duration: 240, curve: Curve.Linear })
          }
          Text(assistantProgress(this.state, this.status).title).fontSize(13).fontColor('#6C7882').fontWeight(FontWeight.Medium)
        }.width('100%')
        Text(assistantProgress(this.state, this.status).detail).fontSize(12).fontColor('#8B949C').lineHeight(19).width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
      if (this.state.nativeTask.stopNotice !== undefined) {
        Text(this.state.nativeTask.stopNotice.message).fontSize(13).fontColor('#B54708')
          .lineHeight(20).width('100%').padding(10).backgroundColor('#FFF4E5').borderRadius(10)
      }
      Stack() {
        XComponent({ id: 'neoAssistantVideo', type: XComponentType.SURFACE, controller: this.surface })
          .width('100%').height('100%').hitTestBehavior(HitTestMode.None)
        if (this.state.videoPreview.state === 'live' && this.state.videoPreview.stats.lastRenderedAgeMs <= 1000) {
          ForEach(this.subjectFrames(), (item: SubjectBox) => {
            Image($r('app.media.subject_selection_gradient')).width(`${item.width * 100}%`).height(`${item.height * 100}%`)
              .position({ x: `${item.left * 100}%`, y: `${item.top * 100}%` })
              .objectFit(ImageFit.Fill).hitTestBehavior(HitTestMode.None)
          }, (item: SubjectBox) => `${item.id}:${item.left}:${item.top}:${item.width}:${item.height}`)
        }
        if (this.state.videoPreview.state !== 'live') {
          Text(this.state.videoPreview.label).fontSize(12).fontColor('#E5E7EB').padding(10)
        }
        Text('实时画面').fontSize(10).fontColor(Color.White).padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .backgroundColor('#66000000').borderRadius(9).position({ x: 9, y: 9 })
        Row({ space: 5 }) {
          if (this.recordingRunning) Circle().width(5).height(5).fill('#F97066')
          Image($r('app.media.preview_camera_timer')).width(15).height(15)
          Text(this.recordingTime).fontSize(11).fontFamily('monospace').fontColor(Color.White)
        }.padding({ left: 7, right: 7, top: 4, bottom: 4 }).backgroundColor('#99000000').borderRadius(8)
          .position({ right: 8, bottom: 8 }).hitTestBehavior(HitTestMode.None)
      }.width('100%').aspectRatio(this.state.videoPreview.stats.width > 0 && this.state.videoPreview.stats.height > 0 ?
        this.state.videoPreview.stats.width / this.state.videoPreview.stats.height : 16 / 9)
        .backgroundColor('#17171C').borderRadius(18).clip(true)
        .visibility(this.resultVisible() ? Visibility.None : Visibility.Visible)
      if (!this.resultVisible()) {
        Row({ space: 10 }) {
          Text(this.state.videoKeyframeRecovery?.message ?? '').fontSize(11).fontColor('#8B949C')
            .layoutWeight(1).lineHeight(17)
          Button('恢复画面').fontSize(12).height(30).fontColor('#6559E8').backgroundColor('#EBE8FF')
            .enabled(this.state.connectionReady && this.state.videoKeyframeRecovery?.pending !== true &&
              !this.listening && !this.processing && !this.accepting)
            .onClick(() => this.recoverVideoPreview())
        }.width('100%')
      }
      if (subjectTaskSnapshot(this.state).stage === 'confirm') {
          Button(subjectConfirmationLabel(this.state)).width('100%').height(44).fontSize(15).fontWeight(FontWeight.Medium)
            .backgroundColor('#6559E8').borderRadius(22)
            .enabled(!this.state.busy && !this.listening && !this.processing && !this.accepting &&
              this.subjectFrames().length === 1).onClick(() => this.confirmSubject())
      }
      if (subjectTaskSnapshot(this.state).stage === 'plan') this.flightPlanCard()
      if (taskProgressPresentation(this.state).visible) this.taskProgressCard()
      if (this.state.agentConfirmation.length > 0) {
        Text(this.state.agentConfirmation).fontSize(12).fontColor('#777780').width('100%')
        Button('确认执行').width('100%').height(42).backgroundColor('#6559E8')
          .enabled(!this.state.busy && !this.listening && !this.processing && !this.accepting).onClick(() => this.confirmOtherAction())
      }
      if (this.resultVisible()) this.videoResultCard()
      if (this.state.agentMediaKind === 'photo' && this.state.agentMediaUri.length > 0) {
        Image(this.state.agentMediaUri).width('100%').height(180).objectFit(ImageFit.Contain).borderRadius(12)
      }
      if (this.state.videoCapturePending && this.state.agentFeedback.startsWith('自动取回未完成')) {
        Button('重试取回录像').fontSize(14).width('100%').height(40).backgroundColor('#EBE8FF').fontColor('#6559E8')
          .enabled(!this.state.busy && !this.processing).onClick(() => this.retryVideoReturn())
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  labelledLine(line: string) {
    Text() {
      Span(this.lineLabel(line)).fontWeight(FontWeight.Bold)
      Span(this.lineValue(line)).fontWeight(FontWeight.Regular)
    }.fontSize(13).fontColor('#515860').lineHeight(19).width('100%')
  }

  @Builder
  flightPlanCard() {
    Column({ space: 3 }) {
      Text(flightPlanPresentation(this.state).title).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#292D34').margin({ bottom: 5 })
      if (subjectTaskSnapshot(this.state).plan?.recipe !== 'dolly_circle') {
        Text(flightPlanPresentation(this.state).detail).fontSize(13).fontColor('#626870').lineHeight(19).margin({ bottom: 5 })
      }
      ForEach(flightPlanPresentation(this.state).lines, (line: string) => {
        this.labelledLine(line)
      }, (line: string) => line)
      Button('一键执行').width('100%').height(44).fontSize(16).fontColor(Color.White)
        .linearGradient({ angle: 90, colors: [['#4168F4', 0], ['#6559E8', 1]] }).borderRadius(22).margin({ top: 10 })
        .enabled(!this.state.busy && !this.listening && !this.processing && !this.accepting &&
          this.state.selectedSubjectOverlay.length === 1).onClick(() => this.executePlan())
    }.width('100%').padding(15).backgroundColor('#7FFFFFFF').borderRadius(18).alignItems(HorizontalAlign.Start)
  }

  @Builder
  taskProgressCard() {
    Column({ space: 3 }) {
      Text(taskProgressPresentation(this.state).title).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#292D34').margin({ bottom: 5 })
      ForEach(taskProgressPresentation(this.state).lines, (line: string) => {
        this.labelledLine(line)
      }, (line: string) => line)
      Row({ space: 10 }) {
        Button('立即返航').layoutWeight(1).height(39).fontSize(14).fontColor('#3E7CFC').backgroundColor('#DBFFFFFF')
          .borderRadius(20).onClick(() => this.demoAction())
        Button('手动接管').layoutWeight(1).height(39).fontSize(14).fontColor('#3E7CFC').backgroundColor('#DBFFFFFF')
          .borderRadius(20).onClick(() => this.demoAction())
      }.width('100%').margin({ top: 7 })
    }.width('100%').padding(15).backgroundColor('#7FFFFFFF').borderRadius(18).alignItems(HorizontalAlign.Start)
  }

  @Builder
  movieProgressCard() {
    Column({ space: 9 }) {
      Text(this.movieProgressLabel()).fontSize(13).fontColor('#686570').lineHeight(21).width('100%')
      if (this.state.movie.busy && !['failed', 'cancelled', 'idle'].includes(this.state.movie.stage)) {
        Progress({ value: Math.round(this.state.movie.progress * 100), total: 100, type: ProgressType.Linear })
          .width('100%').color('#CF77B5').backgroundColor('#E7E0E9')
        Text(`${Math.round(this.state.movie.progress * 100)}%`).fontSize(12).fontColor('#8A8090').width('100%')
      }
      if (this.state.movie.busy || this.state.moviePreparing) {
        Button('取消制作').height(32).fontSize(12).fontColor('#786A80').backgroundColor('#EDE7F1')
          .onClick(() => this.controller.cancelMovie())
      }
    }.width('100%').padding(13).backgroundColor('#7FFFFFFF').borderRadius(16).alignItems(HorizontalAlign.Start)
  }

  @Builder
  resultPlayback() {
    Column() {
      ForEach(this.playbackSources(), (source: ResultPlaybackSource) => {
        Stack({ alignContent: Alignment.Center }) {
          Video({ src: source.uri, controller: this.resultPlayer }).width('100%').height('100%')
            .controls(this.resultHasStarted || this.resultFullscreen).autoPlay(false).objectFit(ImageFit.Contain)
            .onStart(() => { if (this.isCurrentPlayback(source)) { this.resultPlaying = true; this.resultHasStarted = true; } })
            .onPause(() => { if (this.isCurrentPlayback(source)) this.resultPlaying = false; })
            .onFinish(() => { if (this.isCurrentPlayback(source)) { this.resultPlaying = false; this.resultHasStarted = false; } })
            .onFullscreenChange((info: FullscreenInfo) => { if (this.isCurrentPlayback(source)) this.resultFullscreen = info.fullscreen; })
            .onError(() => { if (this.isCurrentPlayback(source)) { this.resultPlaying = false; this.mediaNote = '当前播放器无法播放此视频，可保存至相册查看'; } })
          if (!this.resultHasStarted && !this.resultFullscreen) {
            Button({ type: ButtonType.Circle }) {
              Image($r('app.media.result_play')).width(34).height(34).hitTestBehavior(HitTestMode.None)
            }.width(34).height(34).backgroundColor(Color.Transparent).padding(0)
              .accessibilityText('播放视频').onClick(() => this.toggleResultPlayback())
          }
        }.width('100%').aspectRatio(16 / 9).backgroundColor('#17171C').borderRadius(16).clip(true)
      }, (source: ResultPlaybackSource) => `${source.epoch}:${source.uri}`)
    }.width('100%').constraintSize({ maxWidth: 360 })
  }

  @Builder
  videoResultCard() {
    Column({ space: 10 }) {
      Row() { this.resultPlayback() }.width('100%').justifyContent(FlexAlign.Center)
        if (!this.showingMovie() && this.state.agentMediaCount > 1) {
          Row({ space: 8 }) {
            Button('上一段').fontSize(12).height(32).fontColor('#6559E8').backgroundColor('#EBE8FF')
              .enabled(!this.accepting && this.state.agentMediaIndex > 0)
              .onClick(() => this.selectResult(this.state.agentMediaIndex - 1))
            Text(`${this.state.agentMediaIndex + 1} / ${this.state.agentMediaCount}`).fontSize(12).fontColor('#727783')
            Button('下一段').fontSize(12).height(32).fontColor('#6559E8').backgroundColor('#EBE8FF')
              .enabled(!this.accepting && this.state.agentMediaIndex + 1 < this.state.agentMediaCount)
              .onClick(() => this.selectResult(this.state.agentMediaIndex + 1))
          }.width('100%').justifyContent(FlexAlign.Center)
        }
      Column({ space: 3 }) {
        Text(this.showingMovie() ? (subjectTaskSnapshot(this.state).plan?.action === 'record_start' ?
          '成片与录像结果' : '成片与飞行任务结果') : videoResultPresentation(this.state).title)
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor('#292D34').margin({ bottom: 5 })
        ForEach(flightResultMetrics(this.state), (metric: ResultMetric) => {
          Text() {
            Span(metric.label).fontWeight(FontWeight.Bold)
            Span(metric.value).fontWeight(FontWeight.Regular)
          }.fontSize(13).fontColor('#515860').lineHeight(19).width('100%')
        }, (metric: ResultMetric) => metric.label)
        if (this.showingMovie()) {
          Text(`配乐 ${MOVIE_MUSIC_NAME} · ${(this.state.movie.durationMs / 1000).toFixed(1)} 秒`).fontSize(11).fontColor('#7D8190').margin({ top: 4 })
        }
        if (this.state.movie.stage === 'completed') {
          Button(this.showingMovie() ? '查看原片' : '查看成片').height(32).fontSize(12).fontColor('#8C5989')
            .backgroundColor('#F3E5F0').enabled(!this.accepting).onClick(() => this.switchMoviePreview())
        }
      }.width('100%').padding(15).backgroundColor('#7FFFFFFF').borderRadius(18).alignItems(HorizontalAlign.Start)
      if (this.state.moviePreparing || this.state.movie.busy || ['failed', 'cancelled'].includes(this.state.movie.stage)) {
        this.movieProgressCard()
      }
      Row({ space: 10 }) {
        Button(this.state.moviePreparing || this.state.movie.busy ? '正在制作…' :
          this.state.movie.stage === 'completed' ? '查看成片' : this.state.movie.stage === 'failed' ? '重新成片' : '一键成片')
          .layoutWeight(1).height(42).fontSize(15).fontColor('#3E7CFC').backgroundColor('#DBFFFFFF').borderRadius(22)
          .enabled(!this.accepting && !this.state.movie.busy && !this.state.moviePreparing && this.state.movieCanCompose)
          .onClick(() => this.composeMovie())
        Button(this.accepting ? '正在保存…' : this.savedMediaGroup === this.mediaGroupKey() ? '已保存至相册' : '保存至相册')
          .layoutWeight(1).height(42).fontSize(15).fontColor('#3E7CFC').backgroundColor('#DBFFFFFF').borderRadius(22)
          .enabled(!this.accepting && !this.state.agentMediaSaving && !this.state.movieSaving && this.savedMediaGroup !== this.mediaGroupKey())
          .onClick(() => this.saveVideos())
      }.width('100%')
      if (this.state.movie.stage === 'completed') {
        Text(MOVIE_MUSIC_DESCRIPTION)
          .fontSize(10).fontColor('#8A8490').lineHeight(16).width('100%').copyOption(CopyOptions.LocalDevice)
      }
      if (this.mediaNote.length > 0) Text(this.mediaNote).fontSize(12).fontColor('#8B949C').lineHeight(19).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 10 }) {
      if (this.expanded) {
      Column() {
        Row() {
          Column().width(46).height(4).backgroundColor('#B5B8BD').borderRadius(3)
        }.width('100%').height(20).justifyContent(FlexAlign.Center)
          .gesture(PanGesture({ direction: PanDirection.Vertical })
            .onActionStart(() => this.onResizeStart())
            .onActionUpdate((event: GestureEvent) => this.onResize(event.offsetY)))
      Row() {
        Text('小艺').fontSize(19).fontWeight(FontWeight.Medium).fontColor('#202027')
          .gesture(LongPressGesture({ repeat: false, duration: 1200 }).onAction(() => this.onSettings()))
        Text('无人机拍摄').fontSize(11).fontColor('#A0A0A8').margin({ left: 7 }).layoutWeight(1).maxLines(1)
        Button(this.state.connectionRecovering ? '连接准备中' : this.state.connectionReady ?
          (this.state.videoPreview.state === 'live' ? '已连接' : '已连接 · 等待画面') : '连接飞机', { type: ButtonType.Normal }).fontSize(12)
          .fontColor(this.state.connectionReady ? '#48765A' : '#B94860')
          .backgroundColor(this.state.connectionReady ? '#E4F4E8' : '#FFF0F2')
          .height(30).padding({ left: 10, right: 10 }).borderRadius(15)
          .onClick(() => this.controller.ensureReadyConnection())
        Button('降落', { type: ButtonType.Normal }).fontSize(12).fontColor('#B94860').backgroundColor('#FFF0F2')
          .height(30).padding({ left: 10, right: 10 }).borderRadius(15).margin({ left: 10 }).onClick(() => this.land())
        Button('×', { type: ButtonType.Normal }).fontSize(24).fontColor('#8D8D98').backgroundColor(Color.Transparent)
          .height(32).width(32).padding(0).margin({ left: 5 }).onClick(() => this.closeDialogue())
      }.width('100%').padding({ left: 22, right: 16, top: 4, bottom: 14 })
      Scroll(this.scroller) {
        Column({ space: 20 }) {
          ForEach(this.messages, (item: AssistantMessage) => {
            if (item.role === 'user') {
              Row() {
                Blank().width('10%')
                Text(item.text).fontSize(16).fontColor('#26262E').lineHeight(24).padding(14)
                  .backgroundColor('#EAE8F0').borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 20, bottomRight: 5 })
              }.width('100%').justifyContent(FlexAlign.End)
            }
          }, (item: AssistantMessage) => `${item.id}`)
          // Keep one surface outside the changing message list, preserving the decoder across utterances.
          if (this.messages.length > 0 || this.resultVisible()) this.liveCard()
          if (this.messages.length === 0 && this.status.length > 0) Text(this.status).fontSize(11).fontColor('#9696A0').width('100%')
        }.width('100%').padding({ left: 22, right: 22, bottom: 16 }).alignItems(HorizontalAlign.Start)
          .onAreaChange(() => this.scrollAreaChanged())
      }.layoutWeight(1).width('100%').scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto)
        .align(Alignment.TopStart)
        .onAreaChange(() => this.scrollAreaChanged())
        .onAppear(() => this.startAutoScroll())
        .onDisAppear(() => this.stopAutoScroll())
      }.width('100%').layoutWeight(1).padding({ bottom: 8 }).borderRadius(30).clip(true)
        .backgroundColor('#B3F0F1F3').backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
        .border({ width: 0.7, color: '#E8FFFFFF' }).shadow({ radius: 16, color: '#14212D3A', offsetY: 3 })
      }
      Column({ space: 6 }) {
        Stack() {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            Image($r('app.media.voice_input_keyboard')).width(27).height(27).objectFit(ImageFit.Contain)
              .hitTestBehavior(HitTestMode.None)
            Row({ space: 7 }) {
              if (this.listening) {
                Row({ space: 3 }) {
                  ForEach([0, 1, 2, 3, 4], (bar: number) => {
                    Column().width(2).height((bar % 2 === 0) === this.wave ? 17 : 8)
                      .backgroundColor('#7C8890').borderRadius(2).animation({ duration: 240, curve: Curve.EaseInOut })
                  }, (bar: number) => `${bar}`)
                }.height(22).alignItems(VerticalAlign.Center)
              }
              Text(this.listening ? '正在聆听…' : this.processing ? '点击停止' : '点击或按住说话')
                .fontSize(17).fontColor('#69717C').fontWeight(FontWeight.Regular).maxLines(1)
            }.layoutWeight(1).justifyContent(FlexAlign.Center)
            Image($r('app.media.voice_input_camera')).width(27).height(27).objectFit(ImageFit.Contain)
              .hitTestBehavior(HitTestMode.None)
          }.width('100%').padding({ left: 14, right: 14 })
        }.height(54).width('100%').padding(0).borderRadius(30).backgroundColor(Color.Transparent)
          .accessibilityText('语音输入，点击或按住说话')
          .enabled(!this.accepting).onClick(() => this.speak())
          .gesture(LongPressGesture({ repeat: false, duration: 350 }).onAction(() => this.speak()))
        }.height(54).width('100%').borderRadius(30).clip(true).backgroundColor('#CDE5E7EB')
          .backgroundBlurStyle(BlurStyle.COMPONENT_REGULAR)
          .linearGradient({ angle: 110, colors: [['#9EDAE9D9', 0], ['#C6E8ECF5', 0.45], ['#CDDDDCDF', 1]] })
          .border({ width: 0.7, color: '#EFFFFFFF' }).shadow({ radius: 14, color: '#10212D3A', offsetY: 2 })
        if (this.listening) Text('说完后会自动发送').fontSize(10).fontColor('#9DA3AC')
      }.width('100%')
    }.width('100%').height('100%').justifyContent(FlexAlign.End)
      .padding({ left: 16, right: 16, bottom: 12 }).backgroundColor(Color.Transparent)
  }
}
