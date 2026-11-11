export const MOVIE_TEMPLATE_VERSION: string = 'user-bgm-v5';

export type MovieCompositionStage = 'idle' | 'probing' | 'rendering' | 'finalizing' |
  'completed' | 'failed' | 'cancelled';

export interface NativeMovieSnapshot {
  id: number;
  stage: string;
  progress: number;
  durationMs: number;
  error: string;
  outputPath: string;
}

export interface MovieExportPort {
  start(sources: string[], outputPath: string, musicPath: string): number;
  snapshot(id: number): NativeMovieSnapshot;
  cancel(id: number): void;
}

export interface MovieCompositionSnapshot {
  stage: MovieCompositionStage;
  progress: number;
  sourceKey: string;
  sources: string[];
  outputPath: string;
  durationMs: number;
  error: string;
  busy: boolean;
  id: number;
}

// This service owns local media jobs only. File checks and native media work belong to the port.
export class MovieComposer {
  private port: MovieExportPort;
  private sources: string[] = [];
  private sourceKey: string = '';
  private stage: MovieCompositionStage = 'idle';
  private progress: number = 0;
  private outputPath: string = '';
  private durationMs: number = 0;
  private error: string = '';
  private activeId: number = 0;
  private activeKey: string = '';
  private activeOutput: string = '';
  private discardActive: boolean = false;
  private detachedActive: boolean = false;
  private cancelRequested: boolean = false;

  constructor(port: MovieExportPort) {
    this.port = port;
    this.sourceKey = this.keyFor([], '');
  }

  setSources(sources: string[], revision: string = ''): void {
    const selected = this.uniqueSources(sources);
    const key = this.keyFor(selected, revision);
    if (key === this.sourceKey) return;
    this.sources = selected;
    this.sourceKey = key;
    this.resetVisible();
    if (this.activeId > 0) {
      // Even A -> B -> A must discard A's old result. The key alone cannot detect that cycle.
      this.detachedActive = true;
      this.discardActive = true;
      this.requestCancel();
    }
  }

  start(outputPath: string, musicPath: string): void {
    // A cancellation request does not mean the native worker has released its codecs or output file.
    if (this.activeId > 0 || this.stage === 'completed') return;
    const output = outputPath.trim();
    const music = musicPath.trim();
    if (this.sources.length === 0) {
      this.failCurrent('本次录像尚未取回，请等待全部原片回传');
      return;
    }
    if (output.length === 0) {
      this.failCurrent('成片保存路径无效，请重试');
      return;
    }
    if (music.length === 0) {
      this.failCurrent('配乐尚未准备好，请重试');
      return;
    }
    if (this.aliasesSource(output) || this.samePath(output, music)) {
      this.failCurrent('成片路径不能覆盖原片或配乐，请使用新的文件');
      return;
    }
    this.resetVisible();
    try {
      const id = this.port.start(this.sources.slice(), output, music);
      if (!Number.isInteger(id) || id <= 0) {
        this.failCurrent('启动成片失败：媒体导出器未返回有效任务编号');
        return;
      }
      this.activeId = id;
      this.activeKey = this.sourceKey;
      this.activeOutput = output;
      this.discardActive = false;
      this.detachedActive = false;
      this.cancelRequested = false;
      this.stage = 'probing';
    } catch (error) {
      this.failCurrent('启动成片失败：' + String(error));
    }
  }

  poll(): void {
    if (this.activeId === 0) return;
    let native: NativeMovieSnapshot;
    try {
      native = this.port.snapshot(this.activeId);
    } catch (error) {
      this.failActive('读取成片进度失败：' + String(error));
      this.requestCancel();
      return;
    }
    const terminal = !!native && native.id === this.activeId && this.isTerminal(native.stage);
    const invalid = this.validateNative(native);
    if (invalid.length > 0) {
      this.failActive(invalid);
      if (terminal) this.releaseActive();
      else this.requestCancel();
      return;
    }
    if (!this.discardActive && this.activeKey === this.sourceKey) {
      this.progress = Math.max(0, Math.min(1, native.progress));
      this.durationMs = native.durationMs;
      if (native.stage === 'completed') {
        this.stage = 'completed';
        this.progress = 1;
        this.outputPath = native.outputPath;
        this.error = '';
      } else if (native.stage === 'failed') {
        this.failCurrent(native.error.trim().length > 0 ?
          '成片导出失败：' + native.error : '成片导出失败，请重试，原片仍保留');
      } else if (native.stage === 'cancelled') {
        this.stage = 'cancelled';
        this.outputPath = '';
        this.durationMs = 0;
        this.error = '';
      } else {
        this.stage = native.stage as MovieCompositionStage;
      }
    }
    if (terminal) this.releaseActive();
  }

  cancel(): void {
    if (this.activeId === 0) return;
    this.discardActive = true;
    if (!this.detachedActive) {
      this.stage = 'cancelled';
      this.outputPath = '';
      this.durationMs = 0;
      this.error = '';
    }
    this.requestCancel();
  }

  restoreCompleted(sources: string[], revision: string, outputPath: string, durationMs: number): boolean {
    if (this.activeId > 0 || this.sources.length === 0) return false;
    const key = this.keyFor(this.uniqueSources(sources), revision);
    const output = outputPath.trim();
    if (key !== this.sourceKey || output.length === 0 || this.aliasesSource(output) ||
      !Number.isFinite(durationMs) || durationMs <= 0) return false;
    if (this.stage === 'completed') {
      return this.outputPath === output && this.durationMs === durationMs;
    }
    if (this.stage !== 'idle') return false;
    this.stage = 'completed';
    this.progress = 1;
    this.outputPath = output;
    this.durationMs = durationMs;
    this.error = '';
    return true;
  }

  snapshot(): MovieCompositionSnapshot {
    return {
      stage: this.stage,
      progress: this.progress,
      sourceKey: this.sourceKey,
      sources: this.sources.slice(),
      outputPath: this.outputPath,
      durationMs: this.durationMs,
      error: this.error,
      busy: this.activeId > 0,
      id: this.activeId
    };
  }

  private validateNative(native: NativeMovieSnapshot): string {
    if (!native || native.id !== this.activeId) return '成片任务编号不一致，已停止接收结果';
    if (native.stage !== 'probing' && native.stage !== 'rendering' && native.stage !== 'finalizing' &&
      !this.isTerminal(native.stage)) return '成片阶段无效，已停止接收结果';
    if (!Number.isFinite(native.progress)) return '成片进度无效，已停止接收结果';
    if (typeof native.outputPath !== 'string' || native.outputPath.length === 0 ||
      native.outputPath !== this.activeOutput) return '成片输出路径不一致，原片仍保留';
    if (!Number.isFinite(native.durationMs) || native.durationMs < 0 ||
      (native.stage === 'completed' && native.durationMs <= 0)) return '成片时长无效，无法发布作品';
    if (typeof native.error !== 'string') return '成片错误信息无效，已停止接收结果';
    if (native.stage === 'completed' && native.error.trim().length > 0) return '成片仍存在错误，无法发布作品';
    return '';
  }

  private requestCancel(): void {
    if (this.activeId === 0 || this.cancelRequested) return;
    this.cancelRequested = true;
    try {
      this.port.cancel(this.activeId);
    } catch (error) {
      if (!this.detachedActive) {
        const prior = this.error.length > 0 ? this.error + '；' : '';
        this.failCurrent(prior + '取消成片失败，正在等待媒体任务结束：' + String(error));
      }
    }
  }

  private failActive(message: string): void {
    this.discardActive = true;
    if (!this.detachedActive) this.failCurrent(message);
  }

  private failCurrent(message: string): void {
    this.stage = 'failed';
    this.outputPath = '';
    this.durationMs = 0;
    this.error = message;
  }

  private releaseActive(): void {
    this.activeId = 0;
    this.activeKey = '';
    this.activeOutput = '';
    this.discardActive = false;
    this.detachedActive = false;
    this.cancelRequested = false;
  }

  private resetVisible(): void {
    this.stage = 'idle';
    this.progress = 0;
    this.outputPath = '';
    this.durationMs = 0;
    this.error = '';
  }

  private isTerminal(stage: string): boolean {
    return stage === 'completed' || stage === 'failed' || stage === 'cancelled';
  }

  private uniqueSources(sources: string[]): string[] {
    const selected: string[] = [];
    const seen: Set<string> = new Set();
    for (const source of sources) {
      const value = source.trim();
      if (value.length > 0 && !seen.has(value)) {
        seen.add(value);
        selected.push(value);
      }
    }
    return selected;
  }

  private keyFor(sources: string[], revision: string): string {
    return MOVIE_TEMPLATE_VERSION + '|' + JSON.stringify([revision, ...sources]);
  }

  private aliasesSource(outputPath: string): boolean {
    return this.sources.some((source: string) => this.samePath(source, outputPath));
  }

  private samePath(first: string, second: string): boolean {
    return this.canonicalPath(first) === this.canonicalPath(second);
  }

  private canonicalPath(value: string): string {
    let path = value.trim().replace(/\\/g, '/');
    if (path.startsWith('file://')) {
      path = path.substring(7);
      try { path = decodeURIComponent(path); } catch (_) { /* Keep malformed URI text distinct. */ }
    }
    const absolute = path.startsWith('/');
    const parts: string[] = [];
    for (const part of path.split('/')) {
      if (part === '' || part === '.') continue;
      if (part === '..') {
        if (parts.length > 0 && parts[parts.length - 1] !== '..') parts.pop();
        else if (!absolute) parts.push(part);
      } else parts.push(part);
    }
    return (absolute ? '/' : '') + parts.join('/');
  }
}
