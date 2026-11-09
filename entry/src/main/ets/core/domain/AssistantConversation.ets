import { ConsoleSnapshot } from './AppController';

export interface AssistantMessage { id: number; role: string; text: string; }
export interface AssistantChatSnapshot { messages: AssistantMessage[]; }

export class AssistantConversation {
  private messages: AssistantMessage[] = [];
  private sequence: number = 0;
  submit(text: string): void {
    this.messages = this.messages.concat([{ id: ++this.sequence, role: 'user', text: text }]);
  }
  snapshot(): AssistantChatSnapshot { return { messages: this.messages.slice() }; }
}

export function assistantStep(state: ConsoleSnapshot): string {
  if (state.agentMediaKind === 'video' && state.agentMediaUri.length > 0 &&
    !state.videoCapturePending && !state.groundDolly.active) return '本次录像已取回';
  if (state.videoCapturePending && /^(自动取回未完成|正在从飞机取回|正在等待飞机生成|正在等待相机)/.test(state.agentFeedback ?? '')) {
    return state.agentFeedback;
  }
  const demo = state.groundDolly;
  if (demo.stage === 'shooting') {
    return state.nativeTask.activeOrUnknown ? '无人机正在拍摄滑动变焦运镜…' : '正在整理并取回本次录像…';
  }
  return demo.message;
}
