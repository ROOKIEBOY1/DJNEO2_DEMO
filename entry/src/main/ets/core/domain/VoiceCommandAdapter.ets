import { MovementDirection } from '../protocol/StickCodec';
export type VoiceCommandKind = 'takeoff' | 'takeoff_again' | 'land' | 'center' | 'confirm' | 'pause' | 'status' |
  'circle_prepare' | 'circle_start' | 'circle_stop' | 'circle_radius' | 'follow_prepare' | 'follow_start' |
  'follow_stop' | 'dolly_prepare' | 'dolly_start' | 'dolly_stop' | 'dolly_framing' | 'dolly_zoom' |
  'dolly_retreat' | 'move' | 'photo' | 'record_start' | 'record_stop' | 'media_list' | 'download_photo' | 'download_video';
export type MotionUnit = 'seconds' | 'meters' | 'degrees';
export interface VoiceCommand {
  kind: VoiceCommandKind; direction?: MovementDirection; durationSeconds?: number;
  amount?: number; unit?: MotionUnit; radiusMeters?: number; value?: string; usesDefaultDuration?: boolean;
}
export interface VoiceCommandSnapshot {
  enabled: boolean; listening: boolean; lastTranscript: string; pendingConfirmation: string;
  confirmationRemainingSeconds: number; feedback: string;
}
export type VoiceCommandListener = (command: VoiceCommand) => void;
export class VoiceCommandAdapter {
  private enabledValue: boolean = false;
  private listeningValue: boolean = false;
  private lastTranscriptValue: string = '';
  private pending?: VoiceCommand;
  private deadline: number = 0;
  private expiryTimer?: number;
  private feedback: string = '启用后可使用语音或文本口令';
  private listener?: VoiceCommandListener;
  private statusListener?: () => void;
  private busyProvider?: () => boolean;
  private movementDurationProvider?: () => number;
  private readonly clock: () => number;
  constructor(clock: () => number = () => Date.now()) { this.clock = clock; }
  setListener(listener?: VoiceCommandListener): void { this.listener = listener; }
  setStatusListener(listener: () => void): void { this.statusListener = listener; }
  setBusyProvider(provider: () => boolean): void { this.busyProvider = provider; }
  setMovementDurationProvider(provider: () => number): void { this.movementDurationProvider = provider; }
  setEnabled(enabled: boolean): void {
    this.enabledValue = enabled;
    if (!enabled) { this.listeningValue = false; this.cancelPending(); }
  }
  setListening(listening: boolean): void { this.listeningValue = this.enabledValue && listening; }
  snapshot(): VoiceCommandSnapshot {
    this.expire();
    return { enabled: this.enabledValue, listening: this.listeningValue, lastTranscript: this.lastTranscriptValue,
      pendingConfirmation: this.pending?.kind ?? '',
      confirmationRemainingSeconds: this.pending === undefined ? 0 : Math.ceil((this.deadline - this.clock()) / 1000),
      feedback: this.feedback };
  }
  acceptTranscript(transcript: string): VoiceCommand | undefined {
    this.lastTranscriptValue = transcript.trim();
    if (!this.enabledValue) return undefined;
    this.expire();
    const command = parseVoiceCommand(transcript);
    if (command === undefined) { this.cancelPending(); this.feedback = '未识别明确口令，未执行'; this.changed(); return undefined; }
    if (command.kind === 'move' && command.usesDefaultDuration) {
      const seconds = this.movementDurationProvider?.() ?? 0.5;
      if (!Number.isFinite(seconds) || seconds <= 0 || seconds > 10) {
        this.cancelPending(); this.feedback = '滑块动作时长无效，未执行'; this.changed(); return undefined;
      }
      command.amount = seconds; command.durationSeconds = seconds; command.unit = 'seconds';
    }
    if (this.busyProvider?.() && !['land', 'center', 'circle_stop', 'follow_stop', 'dolly_stop', 'record_stop', 'pause', 'status'].includes(command.kind)) {
      this.cancelPending(); this.feedback = '当前操作未结束，未排队；可说“停止”或“降落”'; this.changed(); return undefined;
    }
    if (command.kind === 'confirm') return this.confirmPending(command.value);
    if (['takeoff', 'takeoff_again', 'circle_start', 'follow_start', 'dolly_start'].includes(command.kind)) {
      this.cancelPending();
      this.pending = command; this.deadline = this.clock() + 10000;
      this.expiryTimer = setTimeout(() => { this.expire(); this.changed(); }, 10000);
      this.feedback = `待确认：${voiceCommandLabel(command)}；请目视确认，10秒内说“确认”或长按确认`;
      this.changed(); return undefined;
    }
    this.cancelPending();
    this.feedback = `口令：${voiceCommandLabel(command)}`;
    if (command.kind === 'pause') this.setEnabled(false);
    this.listener?.(command); this.changed(); return command;
  }
  confirmPending(target?: string): VoiceCommand | undefined {
    this.expire();
    if (!this.enabledValue || this.pending === undefined) {
      this.feedback = '没有有效的待确认口令，请重新发起'; this.changed(); return undefined;
    }
    if (target !== undefined && target !== this.pending.kind && !(target === 'takeoff' && this.pending.kind === 'takeoff_again')) {
      this.feedback = '确认口令与待确认动作不一致，未执行'; this.changed(); return undefined;
    }
    const command = this.pending; this.cancelPending();
    this.feedback = `已确认：${voiceCommandLabel(command)}`;
    this.listener?.(command); this.changed(); return command;
  }
  cancelPending(): void {
    if (this.expiryTimer !== undefined) { clearTimeout(this.expiryTimer); this.expiryTimer = undefined; }
    this.pending = undefined; this.deadline = 0;
  }
  private expire(): void {
    if (this.pending !== undefined && this.clock() >= this.deadline) {
      this.cancelPending(); this.feedback = '待确认口令已过期，请重新发起';
    }
  }
  private changed(): void { this.statusListener?.(); }
}
interface DirectionAlias { direction: MovementDirection; names: string[]; }
const ALIASES: DirectionAlias[] = [
  { direction: 'forward', names: ['向前飞', '往前飞', '前进', '向前', '往前'] },
  { direction: 'backward', names: ['向后飞', '往后飞', '后退', '向后', '往后'] },
  { direction: 'up', names: ['向上飞', '往上飞', '上升', '升高'] },
  { direction: 'down', names: ['向下飞', '往下飞', '下降', '降低'] },
  { direction: 'left', names: ['向左平移', '向左飞', '往左飞', '左移'] },
  { direction: 'right', names: ['向右平移', '向右飞', '往右飞', '右移'] },
  { direction: 'turn_left', names: ['向左转', '往左转', '左转'] },
  { direction: 'turn_right', names: ['向右转', '往右转', '右转'] }
];
interface NamedCommand { names: string[]; kind: VoiceCommandKind; }
const NAMED: NamedCommand[] = [
  { names: ['起飞'], kind: 'takeoff' }, { names: ['再次起飞'], kind: 'takeoff_again' },
  { names: ['降落', '立即降落'], kind: 'land' },
  { names: ['停止', '停下', '停一下', '回中', '悬停', '别动', '不要动', '取消动作', '停止移动'], kind: 'center' },
  { names: ['暂停语音', '关闭语音', '退出'], kind: 'pause' }, { names: ['状态'], kind: 'status' },
  { names: ['环绕', '开始环绕'], kind: 'circle_start' }, { names: ['准备环绕'], kind: 'circle_prepare' },
  { names: ['停止环绕', '结束环绕', '取消环绕'], kind: 'circle_stop' },
  { names: ['跟随', '跟随我', '开始跟随'], kind: 'follow_start' }, { names: ['准备跟随'], kind: 'follow_prepare' },
  { names: ['停止跟随', '结束跟随', '取消跟随'], kind: 'follow_stop' },
  { names: ['滑动变焦', '开始滑动变焦'], kind: 'dolly_start' }, { names: ['准备滑动变焦'], kind: 'dolly_prepare' },
  { names: ['停止滑动变焦', '结束滑动变焦', '取消滑动变焦'], kind: 'dolly_stop' },
  { names: ['拍照', '照相'], kind: 'photo' }, { names: ['录像', '开始录像'], kind: 'record_start' },
  { names: ['停止录像', '结束录像'], kind: 'record_stop' }, { names: ['相册', '媒体列表'], kind: 'media_list' },
  { names: ['下载最新照片', '下载照片'], kind: 'download_photo' },
  { names: ['下载最新录像', '下载最新视频', '下载录像', '下载视频'], kind: 'download_video' }
];
export function parseVoiceNumber(text: string): number {
  if (text === '半') return 0.5;
  if (/^\d+(?:\.\d+)?$/.test(text)) return Number(text);
  const digits = '零一二三四五六七八九';
  const normalized = text.replace(/两/g, '二');
  if (normalized.includes('点')) {
    const parts = normalized.split('点');
    if (parts.length !== 2 || !/^[零一二三四五六七八九]+$/.test(parts[1])) return NaN;
    let fraction = '';
    for (let i = 0; i < parts[1].length; i++) fraction += `${digits.indexOf(parts[1][i])}`;
    return parseVoiceNumber(parts[0]) + Number(`0.${fraction}`);
  }
  if (!/^[零一二三四五六七八九十百]+$/.test(normalized)) return NaN;
  let total = 0; let current = 0;
  for (let i = 0; i < normalized.length; i++) {
    const digit = digits.indexOf(normalized[i]);
    if (digit >= 0) current = digit;
    else { total += (current || 1) * (normalized[i] === '十' ? 10 : 100); current = 0; }
  }
  return total + current;
}
export function parseVoiceCommand(raw: string): VoiceCommand | undefined {
  let text = raw.replace(/[０-９]/g, (value: string) => `${value.charCodeAt(0) - 0xff10}`)
    .replace(/．/g, '.').replace(/\s+/g, '').toLowerCase().replace(/^[。，！!？?]+|[。，！!？?]+$/g, '');
  ['请', '无人机', '帮我'].forEach((prefix: string) => { if (text.startsWith(prefix)) text = text.slice(prefix.length); });
  if (text === '确认') return { kind: 'confirm' };
  const confirms = ['确认起飞', '确认跟随', '确认环绕', '确认滑动变焦', '确认已落地再次起飞'];
  if (confirms.includes(text)) return { kind: 'confirm', value: ['takeoff', 'follow_start', 'circle_start', 'dolly_start', 'takeoff_again'][confirms.indexOf(text)] };
  for (let i = 0; i < NAMED.length; i++) if (NAMED[i].names.includes(text)) return { kind: NAMED[i].kind };
  const framing = text.match(/^(?:设置景别|拍摄景别|景别)?(半身|全身|远景)$/);
  if (framing !== null) return { kind: 'dolly_framing', value: framing[1] };
  const zoom = text.match(/^(?:变焦倍率|倍率|变焦)(2|3|二|两|三)倍?$/);
  if (zoom !== null) return { kind: 'dolly_zoom', value: `${parseVoiceNumber(zoom[1])}` };
  const retreat = text.match(/^(?:变焦前渐远|渐远)(开|开启|关|关闭)$/);
  if (retreat !== null) return { kind: 'dolly_retreat', value: retreat[1].startsWith('开') ? 'on' : 'off' };
  const circle = text.match(/^(环绕|设置环绕半径|环绕半径|设置半径|半径设为|半径)([\d.零一二两三四五六七八九十点半]+)(?:米|m)$/);
  if (circle !== null) {
    const radius = parseVoiceNumber(circle[2]);
    if (!Number.isFinite(radius) || radius < 2 || radius > 10) return undefined;
    return { kind: circle[1] === '环绕' ? 'circle_start' : 'circle_radius', radiusMeters: radius };
  }
  for (let i = 0; i < ALIASES.length; i++) for (let j = 0; j < ALIASES[i].names.length; j++) {
    const alias = ALIASES[i].names[j];
    if (!text.startsWith(alias)) continue;
    const suffix = text.slice(alias.length);
    if (['', '一点', '一下'].includes(suffix)) return { kind: 'move', direction: ALIASES[i].direction, amount: .5, unit: 'seconds', durationSeconds: .5, usesDefaultDuration: true };
    const match = suffix.match(/^([\d.零一二两三四五六七八九十百点半]+)(厘米|cm|米|m|秒|s|度|°)?$/);
    if (match === null) return undefined;
    let amount = parseVoiceNumber(match[1]); const sourceUnit = match[2] ?? '秒';
    const unit: MotionUnit = ['米', 'm', '厘米', 'cm'].includes(sourceUnit) ? 'meters' : ['度', '°'].includes(sourceUnit) ? 'degrees' : 'seconds';
    if (sourceUnit === '厘米' || sourceUnit === 'cm') amount /= 100;
    if (!Number.isFinite(amount) || amount <= 0 || (unit === 'seconds' && amount > 10) ||
      (unit === 'meters' && (amount > 10 || ALIASES[i].direction.startsWith('turn_'))) ||
      (unit === 'degrees' && (amount > 180 || !ALIASES[i].direction.startsWith('turn_')))) return undefined;
    return { kind: 'move', direction: ALIASES[i].direction, amount: amount, unit: unit, durationSeconds: unit === 'seconds' ? amount : undefined };
  }
  return undefined;
}
export function voiceCommandLabel(command: VoiceCommand): string {
  if (command.kind === 'move') return `${command.direction} ${command.amount ?? .5} ${command.unit ?? 'seconds'}`;
  for (let i = 0; i < NAMED.length; i++) if (NAMED[i].kind === command.kind) return NAMED[i].names[0];
  return `${command.kind} ${command.value ?? command.radiusMeters ?? ''}`;
}
