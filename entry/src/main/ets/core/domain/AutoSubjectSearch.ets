export const MAX_TURNS: number = 8;
export const TURN_SECONDS: number = 2;
export const TIMEOUT_MS: number = 120000;

export interface SubjectSearchResult {
  status: 'found' | 'not_found' | 'ambiguous';
  subjectId?: number;
  message?: string;
}

export interface AutoSubjectSearchPort {
  isCurrent: () => boolean;
  inspect: (deadlineMs: number) => Promise<SubjectSearchResult>;
  turn: (seconds: number, deadlineMs: number) => Promise<void>;
  settle: (deadlineMs: number) => Promise<void>;
}

export interface AutoSubjectSearchSnapshot {
  stage: string;
  message: string;
  turns: number;
  active: boolean;
}

// Ports own flight cancellation, centering, fresh frames and bounded I/O.
// This orchestrator only orders those operations and fences late results.
export class AutoSubjectSearch {
  private stage: string = 'idle';
  private message: string = '';
  private turns: number = 0;
  private active: boolean = false;
  private epoch: number = 0;
  private changed: () => void;
  private now: () => number;

  constructor(changed: () => void, now: () => number = (): number => Date.now()) {
    this.changed = changed;
    this.now = now;
  }

  snapshot(): AutoSubjectSearchSnapshot {
    return { stage: this.stage, message: this.message, turns: this.turns, active: this.active };
  }

  cancel(): void {
    this.epoch++;
    if (this.active) {
      this.active = false;
      this.update('cancelled', '自动寻找主体已取消');
    }
  }

  async find(port: AutoSubjectSearchPort): Promise<number> {
    if (this.active) throw new Error('已有主体搜索进行中，请先取消');
    const epoch = ++this.epoch;
    const deadlineMs = this.now() + TIMEOUT_MS;
    this.active = true;
    this.turns = 0;
    let rechecked: boolean = false;
    try {
      while (true) {
        this.check(epoch, port, deadlineMs);
        this.update('settling', '正在回中停稳，准备观察主体…');
        this.check(epoch, port, deadlineMs);
        await port.settle(deadlineMs);
        this.check(epoch, port, deadlineMs);
        this.update('inspecting', rechecked ? '正在同方向复核主体，请稍候…' : '正在根据描述寻找主体…');
        this.check(epoch, port, deadlineMs);
        const result = await port.inspect(deadlineMs);
        this.check(epoch, port, deadlineMs);
        this.validate(result);
        if (result.status === 'found' && result.subjectId !== undefined) {
          this.active = false;
          this.update('found', '已找到主体，等待框选确认');
          // A progress observer may synchronously cancel or replace this run.
          this.check(epoch, port, deadlineMs);
          return result.subjectId;
        }
        if (result.status === 'ambiguous') {
          if (rechecked) throw new Error(`${result.message ? result.message + '；' : ''}仍无法明确区分主体，请补充衣着、位置等描述`);
          rechecked = true;
          continue;
        }
        if (this.turns >= MAX_TURNS) throw new Error('已完成8段转向，仍未找到主体，请调整位置或补充描述');
        this.update('turning', '当前方向未找到主体，正在原地转向2秒…');
        this.check(epoch, port, deadlineMs);
        if (this.now() + TURN_SECONDS * 1000 >= deadlineMs) {
          throw new Error('自动寻找主体剩余时间不足，已超时停止');
        }
        await port.turn(TURN_SECONDS, deadlineMs);
        this.check(epoch, port, deadlineMs);
        this.turns++;
        rechecked = false;
      }
    } catch (error) {
      if (epoch === this.epoch) {
        this.active = false;
        this.update('failed', error instanceof Error ? error.message : '自动寻找主体失败');
      }
      throw error instanceof Error ? error : new Error('自动寻找主体失败');
    }
  }

  private check(epoch: number, port: AutoSubjectSearchPort, deadlineMs: number): void {
    if (epoch !== this.epoch) throw new Error('自动寻找主体已取消');
    if (!port.isCurrent()) throw new Error('飞机或任务状态已变化，自动寻找主体已停止');
    if (this.now() >= deadlineMs) throw new Error('自动寻找主体已超时，请重新发起');
  }

  private validate(result: SubjectSearchResult): void {
    if (!result || typeof result !== 'object' ||
      !['found', 'not_found', 'ambiguous'].includes(result.status) ||
      (result.message !== undefined && typeof result.message !== 'string')) {
      throw new Error('主体识别结果无效，已停止自动搜索');
    }
    if (result.status === 'found') {
      if (result.subjectId === undefined || !Number.isInteger(result.subjectId) ||
        result.subjectId < 0 || result.subjectId > 255) {
        throw new Error('主体编号无效，已停止自动搜索');
      }
    } else if (result.subjectId !== undefined) {
      throw new Error('主体识别结果矛盾，已停止自动搜索');
    }
  }

  private update(stage: string, message: string): void {
    this.stage = stage;
    this.message = message;
    this.changed();
  }
}
