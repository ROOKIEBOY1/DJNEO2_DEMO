import { ConsoleSnapshot } from './AppController';
import { AssistantMessage } from './AssistantConversation';
import { subjectTaskSnapshot, videoResultReady } from './AssistantFlightPresentation';

export interface AssistantScrollContent {
  state: ConsoleSnapshot;
  messages: AssistantMessage[];
  listening: boolean;
  processing: boolean;
  accepting: boolean;
  status: string;
  mediaNote: string;
  showingMovie: boolean;
  savedMediaGroup: string;
}

export class AssistantAutoScroll {
  private active: boolean = false;
  private epoch: number = 0;
  private key?: string;
  private pending: boolean = false;

  start(): number {
    this.active = true; this.key = undefined; this.pending = false;
    return ++this.epoch;
  }
  stop(): void {
    this.active = false; this.pending = false; this.key = undefined; this.epoch++;
  }
  observe(content: AssistantScrollContent): boolean {
    if (!this.active) return false;
    const key = scrollContentKey(content);
    if (key === this.key) return false;
    this.key = key; this.pending = true;
    return true;
  }
  hasPending(): boolean { return this.active && this.pending; }
  takePending(epoch: number): boolean {
    if (epoch !== this.epoch || !this.hasPending()) return false;
    this.pending = false;
    return true;
  }
}

function scrollContentKey(content: AssistantScrollContent): string {
  const state = content.state;
  const resultVisible = !content.listening && !content.processing && videoResultReady(state);
  const parts: string[] = [JSON.stringify(content.messages), replyKey(content.status)];
  if (content.messages.length === 0 && !resultVisible) return JSON.stringify(parts);
  const task = subjectTaskSnapshot(state);
  parts.push(task.stage, state.closeup.stage, `${state.closeup.step}`, state.agentConfirmation, state.lastError,
    `${state.videoCapturePending}`, `${resultVisible}`);
  // Transfer counters change at the telemetry cadence; only new feedback or a failure is a new reply.
  parts.push(replyKey(state.agentFeedback));
  if (task.stage === 'confirm' || task.stage === 'plan') parts.push(JSON.stringify(task.plan));
  if (task.stage === 'failed' || task.stage === 'cancelled') parts.push(task.message);
  if (state.closeup.stage === 'failed' || state.closeup.stage === 'cancelled') parts.push(state.closeup.message);
  if (state.agentMediaKind === 'photo') parts.push(state.agentMediaUri);
  if (resultVisible) {
    parts.push(JSON.stringify(state.agentMediaUris), state.movie.stage, state.movie.outputPath,
      `${state.movie.busy}`, `${state.moviePreparing}`, `${state.movieCanCompose}`,
      `${content.showingMovie}`, `${content.accepting}`, content.savedMediaGroup, content.mediaNote);
    if (state.movie.stage === 'failed') parts.push(state.movie.error);
  }
  // Deliberately omit recording clocks, movie/download percentages, playback state and telemetry.
  return JSON.stringify(parts);
}

function replyKey(text: string): string {
  if (/失败|未完成|错误|无法|取消|重试/.test(text)) return text;
  return /\d+(\.\d+)?\s*%|^(正在从飞机取回|正在等待飞机生成|正在等待相机)/.test(text) ?
    text.replace(/\d+(\.\d+)?/g, '#') : text;
}
