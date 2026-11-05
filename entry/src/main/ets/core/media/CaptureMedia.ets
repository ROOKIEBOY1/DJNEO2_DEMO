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
}

export class CaptureMedia {
  private photo?: PendingMedia;
  private video?: PendingMedia;
  private generation: number = 0;
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
        downloaded: new Map<string, MediaDownloadResult>() };
      if (kind === 'photo') this.photo = pending;
      else this.video = pending;
      hilog.info(0, 'NeoMedia', '拍摄前目录 %{public}s 共 %{public}d 项，最新 %{public}s',
        kind, before.size, listed.data.find(entry => entry.kind === kind)?.name ?? '无');
    } finally { this.preparing = false; }
  }

  markReady(kind: MediaKind): void {
    const pending = this.pending(kind);
    if (pending !== undefined) pending.readyAt = this.now();
  }

  observe(telemetry: TelemetrySnapshot, taskActive: boolean): void {
    const pending = this.video;
    const camera = telemetry.camera;
    if (pending === undefined || pending.readyAt !== undefined || camera === undefined ||
      (telemetry.cameraAgeMs ?? Infinity) > 1000 || camera.observedAtMs < pending.requestedAt) return;
    if (camera.recordingCandidate) pending.recordingSeen = true;
    if (pending.recordingSeen && !camera.recordingCandidate && !taskActive) pending.readyAt = camera.observedAtMs;
  }

  readyKind(): MediaKind | undefined {
    if (this.photo?.readyAt !== undefined && !this.photo.attempted) return 'photo';
    if (this.video?.readyAt !== undefined && !this.video.attempted) return 'video';
    return undefined;
  }

  async retrieveAll(kind: MediaKind, token: CancellationToken,
    report: (message: string) => void): Promise<MediaDownloadResult[]> {
    const pending = this.pending(kind);
    if (pending === undefined || pending.readyAt === undefined) throw new Error('尚未确认本次拍摄结束');
    if (this.retrieving) throw new Error('正在取回其他原片');
    this.assertContext(pending.sessionId, pending.generation, token);
    this.retrieving = true;
    pending.attempted = true;
    const label = kind === 'photo' ? '照片' : '录像';
    const deadline = this.now() + (kind === 'photo' ? 30000 : 60000);
    let previousManifest = '';
    let stableSince: number = this.now();
    try {
      while (this.now() < deadline) {
        this.assertContext(pending.sessionId, pending.generation, token);
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
          this.assertContext(pending.sessionId, pending.generation, token);
          if (listed.ok && listed.data !== undefined) {
            const fresh = listed.data.filter(entry => entry.kind === kind && !pending.before.has(entry.path))
              .sort((left: MediaEntry, right: MediaEntry) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
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
                this.assertContext(pending.sessionId, pending.generation, token);
                const entry = fresh[index];
                const cacheKey = `${entry.path}|${entry.size ?? -1}`;
                let downloaded = pending.downloaded.get(cacheKey);
                report(`正在从飞机取回本次${label}（${index + 1}/${fresh.length}）…`);
                hilog.info(0, 'NeoMedia', '取回分段 %{public}d/%{public}d %{public}s %{public}d 字节',
                  index + 1, fresh.length, entry.name ?? entry.path, entry.size ?? -1);
                if (downloaded === undefined) {
                  const result = await this.media.downloadEntry(entry, this.directory, token);
                  this.assertContext(pending.sessionId, pending.generation, token);
                  if (!result.ok || result.data === undefined) throw new Error(
                    `第${index + 1}/${fresh.length}段取回未完成：${result.error?.message ?? '下载失败'}，可用语音下载重试`);
                  downloaded = result.data;
                  pending.downloaded.set(cacheKey, downloaded);
                }
                results.push(downloaded);
              }
              if (kind === 'video') {
                const finalList = await this.media.listMedia(token);
                this.assertContext(pending.sessionId, pending.generation, token);
                if (!finalList.ok || finalList.data === undefined) throw new Error('录像已下载，最终目录校验未完成，可用语音下载重试');
                const finalEntries = finalList.data.filter(entry => entry.kind === kind && !pending.before.has(entry.path))
                  .sort((left: MediaEntry, right: MediaEntry) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
                const finalManifest = finalEntries.map(entry => `${entry.path}|${entry.size ?? -1}`).join('\n');
                const finalCamera = this.session.snapshot().telemetry;
                if (finalManifest !== manifest || (finalCamera.cameraAgeMs ?? Infinity) > 1000 ||
                  finalCamera.camera?.recordingCandidate !== false) {
                  previousManifest = ''; stableSince = this.now();
                  continue;
                }
              }
              this.discard(kind);
              return results;
            }
          } else { previousManifest = ''; stableSince = this.now(); }
        } else {
          previousManifest = ''; stableSince = this.now();
          report('正在等待相机结束写入并回到空闲状态…');
        }
        await this.wait(1000);
      }
      throw new Error(`飞机尚未提供可完整读取的本次${label}，可用语音下载重试`);
    } finally { this.retrieving = false; }
  }

  private pending(kind: MediaKind): PendingMedia | undefined { return kind === 'photo' ? this.photo : this.video; }
  private assertContext(sessionId: number, generation: number, token: CancellationToken): void {
    if (token.isCancelled() || generation !== this.generation || this.session.sessionId() !== sessionId ||
      !this.session.isReliableLinkFresh()) throw new Error('素材取回已取消或飞机会话发生变化');
  }
}
