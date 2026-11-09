import { hilog } from '@kit.PerformanceAnalysisKit';
import { CancellationToken } from '../domain/OperationResult';
import { DroneSession } from '../domain/DroneSession';
import { TelemetrySnapshot } from '../domain/TelemetryStore';
import { MediaEntry, MediaKind } from './MediaDirectory';
import { MediaDownloadResult } from './MediaDownloader';
import { MediaRepository } from './MediaRepository';

interface PendingMedia {
  sessionId: number;
  generation: number;
  kind: MediaKind;
  before: Set<string>;
  requestedAt: number;
  recordingSeen: boolean;
  readyAt?: number;
  attempted: boolean;
  downloaded: Map<string, MediaDownloadResult>;
  knownVideoPaths: Set<string>;
  sequenceId?: number;
  deferredReturn: boolean;
  sequenceReadyAt?: number;
  sealedReadyAt?: number;
  sequenceRecordingSeen: boolean;
}

export class CaptureMedia {
  private photo?: PendingMedia;
  private video?: PendingMedia;
  private generation: number = 0;
  private sequenceCounter: number = 0;
  private preparing: boolean = false;
  private retrieving: boolean = false;
  private readonly session: DroneSession;
  private readonly media: MediaRepository;
  private readonly directory: string;
  private readonly now: () => number;
  private readonly wait: (ms: number) => Promise<void>;
  constructor(session: DroneSession, media: MediaRepository, directory: string,
    now: () => number = () => Date.now(), wait: (ms: number) => Promise<void> = (ms: number) =>
      new Promise<void>((resolve: () => void) => setTimeout(resolve, ms))) {
    this.session = session; this.media = media; this.directory = directory; this.now = now; this.wait = wait;
  }

  reset(): void { this.generation++; this.photo = undefined; this.video = undefined; }
  hasPending(kind: MediaKind): boolean { return this.pending(kind) !== undefined; }
  discard(kind: MediaKind): void {
    if (kind === 'photo') this.photo = undefined;
    else this.video = undefined;
  }

  async begin(kind: MediaKind, token: CancellationToken): Promise<void> {
    await this.prepareCapture(kind, token);
  }

  async beginVideoSequence(token: CancellationToken): Promise<number> {
    const id = ++this.sequenceCounter;
    await this.prepareCapture('video', token, id);
    return id;
  }

  isVideoSequenceCurrent(id: number): boolean { return this.sequencePending(id) !== undefined; }

  canContinueVideoSequence(id: number): boolean {
    const pending = this.sequencePending(id);
    return pending !== undefined && pending.deferredReturn && pending.recordingSeen &&
      pending.sequenceReadyAt !== undefined && !this.preparing && !this.retrieving && this.session.isReliableLinkFresh();
  }

  continueVideoSequence(id: number, token: CancellationToken): void {
    const pending = this.requireVideoSequence(id, token);
    if (!this.canContinueVideoSequence(id)) throw new Error('本步录像尚未封存，不能衔接下一步');
    pending.sealedReadyAt = pending.sequenceReadyAt;
    pending.sequenceReadyAt = undefined; pending.readyAt = undefined;
    pending.recordingSeen = false; pending.attempted = false; pending.requestedAt = this.now();
  }

  finishVideoSequence(id: number, token: CancellationToken): void {
    const pending = this.requireVideoSequence(id, token);
    if (!this.canContinueVideoSequence(id)) throw new Error('本步录像尚未封存，不能结束组合回传');
    pending.deferredReturn = false;
  }

  releaseVideoSequence(id: number, discardUnstarted: boolean = false): void {
    const pending = this.sequencePending(id);
    if (pending === undefined) return;
    if (discardUnstarted && !this.preparing && !this.retrieving && !pending.sequenceRecordingSeen &&
      pending.sequenceReadyAt === undefined && pending.sealedReadyAt === undefined) {
      this.discard('video'); return;
    }
    pending.deferredReturn = false;
    // Reuse the previous step's genuine completion evidence if preparation of the
    // next step failed. Retrieval still waits for current task/camera idle state.
    if (pending.readyAt === undefined && pending.sealedReadyAt !== undefined) pending.readyAt = pending.sealedReadyAt;
  }

  async reconcileGroundedVideo(token: CancellationToken,
    report: (message: string) => void): Promise<MediaDownloadResult[]> {
    const pending = this.video;
    if (pending === undefined) return [];
    if (this.preparing || this.retrieving) throw new Error('正在处理拍摄素材，请稍后重试');
    this.assertGroundedVideo(pending, token);
    this.preparing = true;
    const deadline = this.now() + 15000;
    let emptySince: number | undefined;
    try {
      while (this.now() < deadline) {
        this.assertGroundedVideo(pending, token);
        report('正在核对上一轮录像，请保持飞机落地停桨…');
        this.assertGroundedVideo(pending, token);
        const listed = await this.media.listMedia(token, Math.min(6000, Math.max(1, deadline - this.now())));
        const idleAt = this.assertGroundedVideo(pending, token);
        if (!listed.ok || listed.data === undefined) throw new Error(listed.error?.message ?? '核对上一轮录像目录失败');
        const fresh = listed.data.filter(entry => entry.kind === 'video' && !pending.before.has(entry.path));
        this.rememberVideoPaths(pending, fresh);
        if (fresh.length > 0) {
          // A missed recording report cannot erase an original. Retain this ticket's
          // baseline and download cache while the ordinary return verifies every clip.
          this.requireCompleteVideoDirectory(pending, fresh);
          pending.readyAt = idleAt;
          return await this.retrievePending('video', token, report, (): void => {
            this.assertGroundedVideo(pending, token);
          });
        }
        if (emptySince === undefined) emptySince = this.now();
        if (this.now() - emptySince >= 5000) {
          this.assertGroundedVideo(pending, token);
          if (pending.knownVideoPaths.size > 0 || pending.downloaded.size > 0) {
            throw new Error('上一轮已有原片，但飞机目录暂未包含完整原片，请恢复目录后重试取回');
          }
          this.discard('video');
          report('上一轮未生成新录像，已恢复拍摄');
          return [];
        }
        await this.wait(Math.min(1000, Math.max(1, deadline - this.now())));
        this.assertGroundedVideo(pending, token);
      }
      throw new Error('上一轮录像目录尚未稳定，请稍后重试');
    } finally { this.preparing = false; }
  }

  private assertGroundedVideo(pending: PendingMedia, token: CancellationToken): number {
    this.assertContext(pending.sessionId, pending.generation, token);
    if (this.video !== pending) throw new Error('上一轮录像记录已变化，请重新发起');
    if (pending.deferredReturn) throw new Error('组合拍摄尚未结束，不能整理上一轮录像');
    const telemetry = this.session.snapshot().telemetry;
    const flight = telemetry.flight; const camera = telemetry.camera; const task = telemetry.task;
    if (flight === undefined || camera === undefined || task === undefined ||
      telemetry.flightAgeMs === undefined || telemetry.flightAgeMs < 0 || telemetry.flightAgeMs > 1000 ||
      telemetry.cameraAgeMs === undefined || telemetry.cameraAgeMs < 0 || telemetry.cameraAgeMs > 1000 ||
      telemetry.taskAgeMs === undefined || telemetry.taskAgeMs < 0 || telemetry.taskAgeMs > 1000 ||
      !(flight.observedAtMs >= pending.requestedAt) || !(camera.observedAtMs >= pending.requestedAt) ||
      !(task.observedAtMs >= pending.requestedAt) || flight.airborne !== false || flight.motorsOn !== false ||
      camera.recordingCandidate !== false ||
      !([0, 3, 4].includes(task.phaseRaw) || (task.modeRaw === 9 && task.phaseRaw === 5))) {
      throw new Error('整理上一轮录像需要新鲜的落地停桨、任务结束及相机空闲状态');
    }
    return camera.observedAtMs;
  }

  private async prepareCapture(kind: MediaKind, token: CancellationToken, sequenceId?: number): Promise<void> {
    if (this.preparing || this.retrieving) throw new Error('正在处理拍摄素材，请稍后重试');
    if (this.hasPending(kind)) throw new Error('上一份素材尚未取回，请先用语音下载后再拍摄');
    const sessionId = this.session.sessionId();
    const generation = this.generation;
    this.preparing = true;
    try {
      this.assertContext(sessionId, generation, token);
      const listed = await this.media.listMedia(token);
      this.assertContext(sessionId, generation, token);
      if (!listed.ok || listed.data === undefined) throw new Error(listed.error?.message ?? '读取拍摄前目录失败');
      const before = new Set<string>(listed.data.filter(entry => entry.kind === kind).map(entry => entry.path));
      const pending: PendingMedia = { sessionId: sessionId, generation: generation, kind: kind, before: before,
        requestedAt: this.now(), recordingSeen: false, attempted: false,
        downloaded: new Map<string, MediaDownloadResult>(), knownVideoPaths: new Set<string>(), sequenceId: sequenceId,
        deferredReturn: sequenceId !== undefined, sequenceRecordingSeen: false };
      if (kind === 'photo') this.photo = pending;
      else this.video = pending;
      hilog.info(0, 'NeoMedia', '拍摄前目录 %{public}s 共 %{public}d 项，最新 %{public}s',
        kind, before.size, listed.data.find(entry => entry.kind === kind)?.name ?? '无');
    } finally { this.preparing = false; }
  }

  markReady(kind: MediaKind): void {
    const pending = this.pending(kind);
    if (pending !== undefined && !pending.deferredReturn) pending.readyAt = this.now();
  }

  observe(telemetry: TelemetrySnapshot, taskActive: boolean): void {
    const pending = this.video;
    const camera = telemetry.camera;
    if (pending === undefined || pending.readyAt !== undefined || camera === undefined ||
      (telemetry.cameraAgeMs ?? Infinity) > 1000 || camera.observedAtMs < pending.requestedAt) return;
    if (camera.recordingCandidate) {
      pending.recordingSeen = true;
      if (pending.sequenceId !== undefined) pending.sequenceRecordingSeen = true;
    }
    if (pending.recordingSeen && !camera.recordingCandidate && !taskActive) {
      pending.readyAt = camera.observedAtMs;
      if (pending.sequenceId !== undefined) pending.sequenceReadyAt = camera.observedAtMs;
    }
  }

  readyKind(): MediaKind | undefined {
    if (this.photo?.readyAt !== undefined && !this.photo.attempted) return 'photo';
    if (this.video?.readyAt !== undefined && !this.video.attempted && !this.video.deferredReturn) return 'video';
    return undefined;
  }

  async retrieveAll(kind: MediaKind, token: CancellationToken,
    report: (message: string) => void): Promise<MediaDownloadResult[]> {
    if (this.preparing) throw new Error('正在处理拍摄素材，请稍后重试');
    return this.retrievePending(kind, token, report);
  }

  private async retrievePending(kind: MediaKind, token: CancellationToken,
    report: (message: string) => void, validate?: () => void): Promise<MediaDownloadResult[]> {
    const pending = this.pending(kind);
    if (pending?.deferredReturn) throw new Error('组合拍摄期间不取回录像，请等待全部动作结束');
    if (pending === undefined || pending.readyAt === undefined) throw new Error('尚未确认本次拍摄结束');
    if (this.retrieving) throw new Error('正在取回其他原片');
    const check = (): void => {
      this.assertContext(pending.sessionId, pending.generation, token);
      if (this.pending(kind) !== pending) throw new Error('拍摄素材记录已变化，请重新发起');
      validate?.();
    };
    check();
    this.retrieving = true;
    pending.attempted = true;
    const label = kind === 'photo' ? '照片' : '录像';
    const deadline = this.now() + (kind === 'photo' ? 30000 : 60000);
    let previousManifest = '';
    let stableSince: number = this.now();
    try {
      while (this.now() < deadline) {
        check();
        const telemetry = this.session.snapshot().telemetry;
        const camera = telemetry.camera;
        const task = telemetry.task;
        const idleTask = task !== undefined && (telemetry.taskAgeMs ?? Infinity) <= 1000 &&
          (task.phaseRaw === 0 || task.phaseRaw === 3 || task.phaseRaw === 4 ||
            (task.modeRaw === 9 && task.phaseRaw === 5));
        if (camera !== undefined && (telemetry.cameraAgeMs ?? Infinity) <= 1000 &&
          camera.observedAtMs >= pending.readyAt && !camera.recordingCandidate && idleTask) {
          report(`正在等待飞机生成本次${label}…`);
          const listed = await this.media.listMedia(token, Math.min(6000, Math.max(1, deadline - this.now())));
          check();
          if (listed.ok && listed.data !== undefined) {
            const fresh = listed.data.filter(entry => entry.kind === kind && !pending.before.has(entry.path))
              .sort((left: MediaEntry, right: MediaEntry) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
            this.rememberVideoPaths(pending, fresh);
            this.requireCompleteVideoDirectory(pending, fresh);
            hilog.info(0, 'NeoMedia', '拍后目录 %{public}s 共 %{public}d 项，新增 %{public}d 项，最新 %{public}s',
              kind, listed.data.length, fresh.length, fresh[0]?.name ?? '无');
            if (kind === 'photo' && fresh.length > 1) throw new Error('发现多份新增照片，无法唯一确认本次素材');
            if (fresh.length > 8) throw new Error('本次新增录像超过8段，请检查飞机媒体目录');
            const readable = fresh.length > 0 && fresh.every(entry => kind === 'photo' ||
              (entry.size !== undefined && entry.size > 0));
            const manifest = readable ? fresh.map(entry => `${entry.path}|${entry.size ?? -1}`).join('\n') : '';
            if (manifest !== previousManifest) {
              previousManifest = manifest; stableSince = this.now();
            } else if (readable && this.now() - stableSince >= (kind === 'video' ? 5000 : 1000)) {
              const results: MediaDownloadResult[] = [];
              for (let index = 0; index < fresh.length; index++) {
                check();
                const entry = fresh[index];
                const cacheKey = `${entry.path}|${entry.size ?? -1}`;
                let downloaded = pending.downloaded.get(cacheKey);
                report(`正在从飞机取回本次${label}（${index + 1}/${fresh.length}）…`);
                hilog.info(0, 'NeoMedia', '取回分段 %{public}d/%{public}d %{public}s %{public}d 字节',
                  index + 1, fresh.length, entry.name ?? entry.path, entry.size ?? -1);
                if (downloaded === undefined) {
                  const result = await this.media.downloadEntry(entry, this.directory, token);
                  check();
                  if (!result.ok || result.data === undefined) throw new Error(
                    `第${index + 1}/${fresh.length}段取回未完成：${result.error?.message ?? '下载失败'}，可用语音下载重试`);
                  downloaded = result.data;
                  pending.downloaded.set(cacheKey, downloaded);
                }
                results.push(downloaded);
              }
              if (kind === 'video') {
                const finalList = await this.media.listMedia(token);
                check();
                if (!finalList.ok || finalList.data === undefined) throw new Error('录像已下载，最终目录校验未完成，可用语音下载重试');
                const finalEntries = finalList.data.filter(entry => entry.kind === kind && !pending.before.has(entry.path))
                  .sort((left: MediaEntry, right: MediaEntry) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
                this.rememberVideoPaths(pending, finalEntries);
                this.requireCompleteVideoDirectory(pending, finalEntries);
                const finalManifest = finalEntries.map(entry => `${entry.path}|${entry.size ?? -1}`).join('\n');
                const finalCamera = this.session.snapshot().telemetry;
                if (finalManifest !== manifest || (finalCamera.cameraAgeMs ?? Infinity) > 1000 ||
                  finalCamera.camera?.recordingCandidate !== false) {
                  previousManifest = ''; stableSince = this.now();
                  continue;
                }
              }
              check();
              this.discard(kind);
              return results;
            }
          } else { previousManifest = ''; stableSince = this.now(); }
        } else {
          previousManifest = ''; stableSince = this.now();
          report('正在等待相机结束写入并回到空闲状态…');
        }
        await this.wait(1000);
        check();
      }
      throw new Error(`飞机尚未提供可完整读取的本次${label}，可用语音下载重试`);
    } finally { this.retrieving = false; }
  }

  private rememberVideoPaths(pending: PendingMedia, entries: MediaEntry[]): void {
    if (pending.kind !== 'video') return;
    entries.forEach((entry: MediaEntry): void => {
      if (entry.kind === 'video' && entry.size !== undefined && entry.size > 0 && !pending.before.has(entry.path)) {
        pending.knownVideoPaths.add(entry.path);
      }
    });
  }

  private requireCompleteVideoDirectory(pending: PendingMedia, entries: MediaEntry[]): void {
    if (pending.kind !== 'video') return;
    const present = new Set<string>(entries.map(entry => entry.path));
    pending.knownVideoPaths.forEach((path: string): void => {
      if (!present.has(path)) throw new Error('飞机目录暂时缺少上一轮已观察到的原片，请恢复完整目录后重试取回');
    });
  }

  private pending(kind: MediaKind): PendingMedia | undefined { return kind === 'photo' ? this.photo : this.video; }
  private sequencePending(id: number): PendingMedia | undefined {
    if (!Number.isInteger(id) || id <= 0) return undefined;
    const pending = this.video;
    return pending !== undefined && pending.sequenceId === id && pending.generation === this.generation &&
      pending.sessionId === this.session.sessionId() ? pending : undefined;
  }
  private requireVideoSequence(id: number, token: CancellationToken): PendingMedia {
    const pending = this.sequencePending(id);
    if (pending === undefined) throw new Error('组合录像序列已失效或飞机会话变化');
    this.assertContext(pending.sessionId, pending.generation, token);
    return pending;
  }
  private assertContext(sessionId: number, generation: number, token: CancellationToken): void {
    if (token.isCancelled() || generation !== this.generation || this.session.sessionId() !== sessionId ||
      !this.session.isReliableLinkFresh()) throw new Error('素材取回已取消或飞机会话发生变化');
  }
}
