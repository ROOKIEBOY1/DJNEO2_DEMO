import { MovementDirection } from '../protocol/StickCodec';

export type VoiceCommandKind = 'takeoff' | 'land' | 'center' | 'circle_prepare' | 'circle_start' |
  'circle_stop' | 'move' | 'photo' | 'record_start' | 'record_stop';

export interface VoiceCommand {
  kind: VoiceCommandKind;
  direction?: MovementDirection;
  durationSeconds?: number;
}

export interface VoiceCommandSnapshot {
  enabled: boolean;
  listening: boolean;
  lastTranscript: string;
  pendingConfirmation: string;
}

export type VoiceCommandListener = (command: VoiceCommand) => void;

// Platform recognition and the text console both terminate here. The parser deliberately
// accepts a small, deterministic vocabulary and never executes a command itself.
export class VoiceCommandAdapter {
  private enabledValue: boolean = false;
  private listeningValue: boolean = false;
  private lastTranscriptValue: string = '';
  private pendingConfirmationValue: string = '';
  private listener?: VoiceCommandListener;

  setListener(listener?: VoiceCommandListener): void {
    this.listener = listener;
  }

  setEnabled(enabled: boolean): void {
    this.enabledValue = enabled;
    if (!enabled) {
      this.listeningValue = false;
      this.pendingConfirmationValue = '';
    }
  }

  setListening(listening: boolean): void {
    this.listeningValue = this.enabledValue && listening;
  }

  snapshot(): VoiceCommandSnapshot {
    return {
      enabled: this.enabledValue,
      listening: this.listeningValue,
      lastTranscript: this.lastTranscriptValue,
      pendingConfirmation: this.pendingConfirmationValue
    };
  }

  acceptTranscript(transcript: string): VoiceCommand | undefined {
    this.lastTranscriptValue = transcript.trim();
    if (!this.enabledValue || this.lastTranscriptValue.length === 0) {
      return undefined;
    }
    const command = parseVoiceCommand(this.lastTranscriptValue);
    if (command === undefined) {
      return undefined;
    }
    if (command.kind === 'takeoff' || command.kind === 'circle_start') {
      this.pendingConfirmationValue = command.kind;
      return undefined;
    }
    const listener = this.listener;
    if (listener !== undefined) {
      listener(command);
    }
    return command;
  }

  confirmPending(): VoiceCommand | undefined {
    if (!this.enabledValue || this.pendingConfirmationValue.length === 0) {
      return undefined;
    }
    const command: VoiceCommand = {
      kind: this.pendingConfirmationValue === 'takeoff' ? 'takeoff' : 'circle_start'
    };
    this.pendingConfirmationValue = '';
    const listener = this.listener;
    if (listener !== undefined) {
      listener(command);
    }
    return command;
  }

  cancelPending(): void {
    this.pendingConfirmationValue = '';
  }
}

export function parseVoiceCommand(raw: string): VoiceCommand | undefined {
  const text = raw.trim().toLowerCase().replace(/\s+/g, '');
  if (text === '起飞') return { kind: 'takeoff' };
  if (text === '降落' || text === '立即降落') return { kind: 'land' };
  if (text === '回中' || text === '停止移动') return { kind: 'center' };
  if (text === '准备环绕') return { kind: 'circle_prepare' };
  if (text === '开始环绕') return { kind: 'circle_start' };
  if (text === '停止环绕') return { kind: 'circle_stop' };
  if (text === '拍照') return { kind: 'photo' };
  if (text === '开始录像') return { kind: 'record_start' };
  if (text === '停止录像') return { kind: 'record_stop' };
  const movement = movementFromText(text);
  if (movement !== undefined) {
    return { kind: 'move', direction: movement, durationSeconds: 0.5 };
  }
  return undefined;
}

function movementFromText(text: string): MovementDirection | undefined {
  if (text === '前进') return 'forward';
  if (text === '后退') return 'backward';
  if (text === '左移') return 'left';
  if (text === '右移') return 'right';
  if (text === '上升') return 'up';
  if (text === '下降') return 'down';
  if (text === '左转') return 'turn_left';
  if (text === '右转') return 'turn_right';
  return undefined;
}
