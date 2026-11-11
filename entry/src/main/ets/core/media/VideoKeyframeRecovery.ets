import { VideoPreviewSnapshot } from './VideoPreview';

export type VideoKeyframeRequestReason = 'manual' | 'automatic';
export interface VideoKeyframeRecoveryInput {
  contextId: string;
  connected: boolean;
  videoAgeMs?: number;
  preview: VideoPreviewSnapshot;
}
export interface VideoKeyframeRecoverySnapshot {
  state: string;
  message: string;
  pending: boolean;
  automaticAttempts: number;
  requests: number;
  lastRequestAtMs?: number;
}

interface RecoveryEvidence {
  requestedAtMs: number;
  epoch?: number;
  accepted?: number;
  rendered?: number;
  recovered: boolean;
}
interface PendingKeyframeRequest {
  token: number;
  atMs: number;
  timer: number;
  resolve: () => void;
  reject: (error: Error) => void;
}

export class VideoKeyframeRecovery {
  private readonly send: (reason: VideoKeyframeRequestReason) => Promise<void>;
  private readonly now: () => number;
  private readonly changed?: (snapshot: VideoKeyframeRecoverySnapshot) => void;
  private contextId?: string;
  private lastClockMs?: number;
  private previewStartedAtMs?: number;
  private state: string = 'idle';
  private message: string = '';
  private automaticAttempts: number = 0;
  private requests: number = 0;
  private lastRequestAtMs?: number;
  private cooldownAnchorAtMs?: number;
  private pending?: PendingKeyframeRequest;
  private sequence: number = 0;
  private evidence?: RecoveryEvidence;
  private latestPaused: boolean = false;
  private healthySinceMs?: number;
  private healthyLastRenderedAtMs?: number;
  private healthyLastCount?: number;
  private healthyEpoch?: number;
  private lastPublished: string = '';

  constructor(send: (reason: VideoKeyframeRequestReason) => Promise<void>, now: () => number,
    changed?: (snapshot: VideoKeyframeRecoverySnapshot) => void) {
    this.send = send; this.now = now; this.changed = changed;
  }

  observe(input: VideoKeyframeRecoveryInput): void {
    const at = this.now();
    if (!this.prepare(input, at)) { this.publish(); return; }
    this.expirePending(at);
    this.observeRecovery(input, at);
    this.observeHealth(input, at);
    const stats = input.preview?.stats;
    if (stats?.recoveryPaused === true) {
      this.status('paused', '本地解码恢复已暂停，可点击恢复画面重试');
    } else if (stats?.running === true && freshVideo(input) && !freshRendered(input)) {
      const neverRendered = count(stats.renderedFrames) === 0 || stats.lastRenderedAgeMs < 0;
      const oldOutput = Number.isFinite(stats.lastRenderedAgeMs) && stats.lastRenderedAgeMs > 2000;
      const startupWait = this.previewStartedAtMs !== undefined && at - this.previewStartedAtMs >= 2000;
      if ((neverRendered && startupWait) || oldOutput) {
        if (this.automaticAttempts >= 3 && this.pending === undefined) {
          this.status('exhausted', '已自动请求关键帧 3 次，仍未确认画面恢复，可点击恢复画面重试');
        } else if (this.pending === undefined && this.cooldownElapsed(at)) {
          // The Session owns the pulse/reset. This observation never awaits it
          // and consumes an attempt even if a possibly transmitted send fails.
          this.startRequest('automatic', input, at).catch((_error: Object): void => {});
        }
      }
    }
    this.publish();
  }

  // Controller may validate, synchronously reopen its paused local preview,
  // and then call requestManual with a fresh zero-counter snapshot.
  assertManualRequestAllowed(input: VideoKeyframeRecoveryInput): void { this.validateManual(input); }

  async requestManual(input: VideoKeyframeRecoveryInput): Promise<void> {
    const at = this.validateManual(input);
    await this.startRequest('manual', input, at);
  }

  reset(): void {
    this.cancelPending('恢复请求已因连接重置取消');
    this.contextId = undefined; this.lastClockMs = undefined; this.previewStartedAtMs = undefined;
    this.evidence = undefined; this.automaticAttempts = 0; this.requests = 0; this.lastRequestAtMs = undefined;
    this.cooldownAnchorAtMs = undefined;
    this.latestPaused = false; this.clearHealth(); this.status('idle', ''); this.publish();
  }

  snapshot(): VideoKeyframeRecoverySnapshot {
    return { state: this.state, message: this.message, pending: this.pending !== undefined,
      automaticAttempts: this.automaticAttempts, requests: this.requests, lastRequestAtMs: this.lastRequestAtMs };
  }

  private prepare(input: VideoKeyframeRecoveryInput, at: number): boolean {
    if (input.contextId !== this.contextId) {
      this.cancelPending('恢复请求已因飞机会话变化取消');
      this.contextId = input.contextId; this.lastClockMs = undefined; this.previewStartedAtMs = undefined;
      this.evidence = undefined; this.automaticAttempts = 0; this.requests = 0; this.lastRequestAtMs = undefined;
      this.cooldownAnchorAtMs = undefined;
      this.clearHealth(); this.status('idle', '');
    }
    if (!Number.isFinite(at) || at < 0 || (this.lastClockMs !== undefined && at < this.lastClockMs)) {
      this.clearHealth(); this.status('unavailable', '恢复计时状态异常，未请求关键帧'); return false;
    }
    this.lastClockMs = at;
    if (!input.contextId || !input.connected) {
      this.cancelPending('恢复请求已因控制连接不可用取消');
      this.evidence = undefined; this.clearHealth();
      this.status('unavailable', '恢复画面需要已核验的新鲜控制连接'); return false;
    }
    if (this.state === 'unavailable') this.status('idle', '');
    const stats = input.preview?.stats;
    this.latestPaused = stats?.recoveryPaused === true;
    // Native surface replacement clears renderedAt without clearing cumulative
    // output counts. Treat this as a new no-output wait, not as a live frame or
    // an immediate failure inherited from the old surface's lifetime.
    if (stats?.running === true && (count(stats.renderedFrames) === 0 || stats.lastRenderedAgeMs < 0)) {
      if (this.previewStartedAtMs === undefined) this.previewStartedAtMs = at;
    } else this.previewStartedAtMs = undefined;
    return true;
  }

  private validateManual(input: VideoKeyframeRecoveryInput): number {
    const at = this.now();
    if (!this.prepare(input, at)) { this.publish(); throw new Error(this.message); }
    this.expirePending(at);
    if (!freshVideo(input)) {
      this.status('unavailable', '图传数据不新鲜，暂不请求关键帧'); this.publish(); throw new Error(this.message);
    }
    if (this.pending !== undefined) {
      this.status('requesting', '关键帧恢复请求正在处理中，请稍后重试'); this.publish(); throw new Error(this.message);
    }
    if (!this.cooldownElapsed(at)) {
      this.status('waiting', '关键帧请求仍在冷却，请在请求结束后间隔至少 5 秒再试'); this.publish(); throw new Error(this.message);
    }
    return at;
  }

  private startRequest(reason: VideoKeyframeRequestReason, input: VideoKeyframeRecoveryInput, at: number): Promise<void> {
    this.lastRequestAtMs = at; this.requests++;
    this.cooldownAnchorAtMs = at;
    if (reason === 'automatic') this.automaticAttempts++;
    const stats = input.preview?.stats;
    this.evidence = { requestedAtMs: at, epoch: stats?.decoderEpoch,
      accepted: count(stats?.acceptedRandomAccessFrames), rendered: count(stats?.renderedFrames), recovered: false };
    const token = ++this.sequence;
    const result = new Promise<void>((resolve: () => void, reject: (error: Error) => void) => {
      const timer = setTimeout((): void => this.failRequest(token, new Error('关键帧请求等待超时，发送状态未确认')), 1500);
      this.pending = { token: token, atMs: at, timer: timer, resolve: resolve, reject: reject };
    });
    this.status('requesting', '正在请求关键帧，等待图传恢复'); this.publish();
    // A synchronous lifecycle/UI callback may invalidate this attempt before
    // send begins. Its independently owned Session pulse has not started yet.
    if (this.pending?.token !== token) return result;
    try {
      this.send(reason).then((): void => this.finishRequest(token),
        (error: Object): void => this.failRequest(token, error));
    } catch (error) { this.failRequest(token, error); }
    return result;
  }

  private finishRequest(token: number): void {
    const pending = this.pending;
    if (pending?.token !== token) return;
    this.advanceCooldownAnchor();
    clearTimeout(pending.timer); this.pending = undefined;
    if (this.evidence?.recovered !== true) {
      this.status(this.latestPaused ? 'paused' : 'requested', this.latestPaused ?
        '关键帧请求已发送，本地解码仍暂停，可点击恢复画面重试' : '已请求关键帧，等待新的实时画面');
    }
    pending.resolve(); this.publish();
  }

  private failRequest(token: number, error: Object): void {
    const pending = this.pending;
    if (pending?.token !== token) return;
    this.advanceCooldownAnchor();
    clearTimeout(pending.timer); this.pending = undefined;
    const detail = error instanceof Error ? error.message : String(error);
    const message = detail.includes('超时') ? detail.slice(0, 192) : `关键帧请求未确认：${detail.slice(0, 160)}`;
    if (this.evidence?.recovered === true) this.status('recovered', `已观察到画面恢复；${message}`);
    else this.status('failed', message);
    pending.reject(new Error(message)); this.publish();
  }

  private cancelPending(reason: string): void {
    const pending = this.pending;
    if (pending === undefined) return;
    this.advanceCooldownAnchor();
    clearTimeout(pending.timer); this.pending = undefined;
    pending.reject(new Error(reason));
  }

  private expirePending(at: number): void {
    if (this.pending !== undefined && at - this.pending.atMs >= 1500) {
      this.failRequest(this.pending.token, new Error('关键帧请求等待超时，发送状态未确认'));
    }
  }

  private observeRecovery(input: VideoKeyframeRecoveryInput, at: number): void {
    const evidence = this.evidence;
    const stats = input.preview?.stats;
    if (evidence === undefined || evidence.recovered || stats === undefined || !freshVideo(input) || !freshRendered(input)) return;
    if (evidence.epoch !== undefined && (stats.decoderEpoch === undefined || stats.decoderEpoch < evidence.epoch)) return;
    const accepted = count(stats.acceptedRandomAccessFrames), rendered = count(stats.renderedFrames);
    // Decoder-local epochs may keep cumulative counts. An epoch change alone
    // supplies neither a new IRAP nor a new output. A manual restart is sampled
    // anew by Controller before requestManual, giving an explicit zero baseline.
    if (accepted === undefined || evidence.accepted === undefined || accepted <= evidence.accepted ||
      rendered === undefined || evidence.rendered === undefined || rendered <= evidence.rendered ||
      stats.lastRenderedAgeMs > at - evidence.requestedAtMs) return;
    evidence.recovered = true;
    this.status('recovered', '已观察到新的关键帧和实时画面');
  }

  private observeHealth(input: VideoKeyframeRecoveryInput, at: number): void {
    const stats = input.preview?.stats;
    const rendered = count(stats?.renderedFrames);
    if (!freshVideo(input) || !freshRendered(input) || stats === undefined || rendered === undefined) {
      this.clearHealth(); return;
    }
    const renderedAt = at - stats.lastRenderedAgeMs;
    if (this.healthyLastCount === rendered && this.healthyEpoch === stats.decoderEpoch) {
      if (this.healthyLastRenderedAtMs !== undefined && at - this.healthyLastRenderedAtMs > 1000) this.clearHealth();
      return;
    }
    if (this.healthySinceMs === undefined || this.healthyLastRenderedAtMs === undefined ||
      this.healthyEpoch !== stats.decoderEpoch || this.healthyLastCount === undefined ||
      rendered < this.healthyLastCount || renderedAt < this.healthyLastRenderedAtMs ||
      renderedAt - this.healthyLastRenderedAtMs > 1000) this.healthySinceMs = renderedAt;
    this.healthyLastRenderedAtMs = renderedAt; this.healthyLastCount = rendered; this.healthyEpoch = stats.decoderEpoch;
    if (renderedAt - this.healthySinceMs >= 5000 && this.automaticAttempts > 0) {
      this.automaticAttempts = 0;
      if (this.evidence?.recovered !== true) { this.evidence = undefined; this.status('idle', ''); }
    }
  }

  private clearHealth(): void {
    this.healthySinceMs = undefined; this.healthyLastRenderedAtMs = undefined;
    this.healthyLastCount = undefined; this.healthyEpoch = undefined;
  }
  private advanceCooldownAnchor(): void {
    const at = this.now();
    if (!Number.isFinite(at) || at < 0) return;
    // Status publication or asynchronous sending can happen after the request
    // evidence was sampled. Starting the retry window at current completion is
    // conservative relative to the Session's actual wire-send clock. Callers
    // fence the attempt token first; old outcomes cannot move a new context's
    // anchor. Context replacement/reset explicitly clears this separate clock.
    this.cooldownAnchorAtMs = Math.max(this.cooldownAnchorAtMs ?? at, at);
  }
  private cooldownElapsed(at: number): boolean { return this.cooldownAnchorAtMs === undefined || at - this.cooldownAnchorAtMs >= 5000; }
  private status(state: string, message: string): void { this.state = state; this.message = message; }
  private publish(): void {
    const snapshot = this.snapshot(); const key = JSON.stringify(snapshot);
    if (key === this.lastPublished) return;
    this.lastPublished = key;
    try { this.changed?.(snapshot); } catch (_) { /* UI callbacks never own transport progress. */ }
  }
}

function count(value: number | undefined): number | undefined {
  return value !== undefined && Number.isInteger(value) && value >= 0 ? value : undefined;
}
function freshVideo(input: VideoKeyframeRecoveryInput): boolean {
  const age = input.videoAgeMs;
  return age !== undefined && Number.isFinite(age) && age >= 0 && age <= 1000;
}
function freshRendered(input: VideoKeyframeRecoveryInput): boolean {
  const stats = input.preview?.stats;
  return stats !== undefined && stats.running && !stats.recoveryPaused && !stats.waitingForKey &&
    (count(stats.renderedFrames) ?? 0) > 0 && Number.isFinite(stats.lastRenderedAgeMs) &&
    stats.lastRenderedAgeMs >= 0 && stats.lastRenderedAgeMs <= 1000;
}
