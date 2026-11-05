export interface VideoPreviewStats {
  running: boolean;
  waitingForKey: boolean;
  queued: number;
  queuedBytes: number;
  queueDrops: number;
  assembledFrames: number;
  submittedFrames: number;
  decodedFrames: number;
  renderedFrames: number;
  decodeErrors: number;
  suppressedParameters: number;
  reorderedFrames: number;
  width: number;
  height: number;
  lastAssembledAgeMs: number;
  lastDecodedAgeMs: number;
  lastRenderedAgeMs: number;
  lastError: string;
}

export interface VideoPreviewBackend {
  start(surfaceId: string): void;
  switchSurface?(surfaceId: string): boolean;
  stop(): void;
  submit(bytes: ArrayBuffer): void;
  snapshot(): VideoPreviewStats;
}

export interface VideoPreviewSnapshot {
  state: string;
  label: string;
  stats: VideoPreviewStats;
}

export function videoSessionIdentity(phase: string, sessionHex: string): string {
  return phase === 'handshaking' || phase === 'registering' || phase === 'ready' ? sessionHex : '';
}

function emptyStats(): VideoPreviewStats {
  return { running: false, waitingForKey: true, queued: 0, queuedBytes: 0, queueDrops: 0,
    assembledFrames: 0, submittedFrames: 0, decodedFrames: 0, renderedFrames: 0, decodeErrors: 0,
    suppressedParameters: 0, reorderedFrames: 0, width: 0, height: 0,
    lastAssembledAgeMs: -1, lastDecodedAgeMs: -1, lastRenderedAgeMs: -1, lastError: '' };
}

// No decoding work runs here. A native worker owns all codec and queue state.
export class VideoPreview {
  private surfaceId: string = '';
  private sessionId: string = '';
  private active: boolean = false;
  private error: string = '';
  private readonly backend: VideoPreviewBackend;
  constructor(backend: VideoPreviewBackend) { this.backend = backend; }

  attach(surfaceId: string): void {
    if (surfaceId === this.surfaceId) return;
    if (this.active && this.backend.switchSurface?.(surfaceId) === true) {
      this.surfaceId = surfaceId;
      return;
    }
    this.stop(); this.surfaceId = surfaceId; this.start();
  }

  detach(surfaceId?: string): void {
    if (surfaceId !== undefined && surfaceId !== this.surfaceId) return;
    this.stop(); this.surfaceId = '';
  }

  setSession(identity: string): void {
    if (identity === this.sessionId) return;
    this.stop(); this.sessionId = identity; this.start();
  }

  submit(frame: Uint8Array): void {
    if (!this.active) return;
    try { this.backend.submit(new Uint8Array(frame).buffer as ArrayBuffer); }
    catch (error) { this.error = (error as Error).message; }
  }

  snapshot(): VideoPreviewSnapshot {
    let stats = emptyStats();
    if (this.active) {
      try { stats = this.backend.snapshot(); }
      catch (error) { this.error = (error as Error).message; }
    }
    let state = 'stopped'; let label = '连接飞机后自动预览';
    if (this.error.length > 0) { state = 'error'; label = this.error; }
    else if (this.active) {
      if (stats.lastError.length > 0) { state = 'error'; label = stats.lastError; }
      else if (stats.renderedFrames > 0 && stats.lastRenderedAgeMs >= 0) {
        state = stats.lastRenderedAgeMs > 2000 ? 'stale' : 'live';
        label = state === 'live' ? '实时画面' : '画面已过期';
      } else if (stats.assembledFrames > 0) { state = 'waiting_key'; label = '已收到视频，等待可解码画面'; }
      else { state = 'waiting_stream'; label = '等待视频码流'; }
    }
    return { state: state, label: label, stats: stats };
  }

  private start(): void {
    this.error = '';
    if (this.surfaceId.length === 0 || this.sessionId.length === 0) return;
    try { this.backend.start(this.surfaceId); this.active = true; }
    catch (error) { this.error = (error as Error).message; }
  }

  private stop(): void {
    if (this.active) {
      this.active = false;
      try { this.backend.stop(); } catch (error) { this.error = (error as Error).message; }
    }
    this.error = '';
  }
}
