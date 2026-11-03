import { MovementDirection } from '../protocol/StickCodec';
import { VoiceCommand } from './VoiceCommandAdapter';
export interface CalibrationSample { direction: MovementDirection; seconds: number; amount: number; }
export class VoiceMotion {
  private samples: CalibrationSample[] = [];
  record(direction: MovementDirection, seconds: number, amount: number): void {
    if (!['forward', 'backward', 'up', 'down', 'left', 'right', 'turn_left', 'turn_right'].includes(direction) ||
      !Number.isFinite(seconds) || seconds <= 0 || seconds > 10 || !Number.isFinite(amount) || amount <= 0) {
      throw new Error('请填写有效方向、0–10秒动作时间和实测位移/角度');
    }
    const same = this.samples.filter((sample: CalibrationSample) => sample.direction === direction).slice(-4);
    this.samples = this.samples.filter((sample: CalibrationSample) => sample.direction !== direction);
    this.samples.push(...same, { direction: direction, seconds: seconds, amount: amount });
  }
  exportJson(): string { return JSON.stringify(this.samples); }
  importJson(text: string): void {
    const samples = JSON.parse(text) as CalibrationSample[];
    if (!Array.isArray(samples) || samples.length > 40) throw new Error('标定文件无效');
    const checked = new VoiceMotion();
    samples.forEach((sample: CalibrationSample) => checked.record(sample.direction, sample.seconds, sample.amount));
    this.samples = checked.samples;
  }
  summary(): string {
    const directions: string[] = [];
    this.samples.forEach((sample: CalibrationSample) => { if (!directions.includes(sample.direction)) directions.push(sample.direction); });
    return directions.length === 0 ? '尚无实测标定；请使用秒数或“一点”' : `已标定：${directions.join('、')}`;
  }
  plan(command: VoiceCommand): number[] {
    const amount = command.amount ?? command.durationSeconds ?? 0.5;
    const unit = command.unit ?? 'seconds';
    if (!Number.isFinite(amount) || amount <= 0 || command.direction === undefined) throw new Error('移动参数无效');
    if (unit === 'seconds') {
      if (amount > 10) throw new Error('单次动作最长10秒');
      return [amount];
    }
    const turning = command.direction.startsWith('turn_');
    if ((unit === 'meters' && (turning || amount > 10)) || (unit === 'degrees' && (!turning || amount > 180))) throw new Error('移动单位或范围无效');
    const rates = this.samples.filter((sample: CalibrationSample) => sample.direction === command.direction)
      .map((sample: CalibrationSample) => sample.amount / sample.seconds).sort((a: number, b: number) => a - b);
    if (rates.length === 0) throw new Error('此方向没有实测标定，请先用秒数或“一点”');
    const middle = Math.floor(rates.length / 2);
    const rate = rates.length % 2 === 1 ? rates[middle] : (rates[middle - 1] + rates[middle]) / 2;
    let seconds = amount / rate;
    if (!Number.isFinite(seconds) || seconds > 20) throw new Error('预计动作超过20秒，请缩短距离');
    const segments: number[] = [];
    while (seconds > 0.00000001) { segments.push(Math.min(10, seconds)); seconds -= segments[segments.length - 1]; }
    return segments;
  }
}
