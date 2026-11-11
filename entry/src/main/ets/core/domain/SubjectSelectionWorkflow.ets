export interface SubjectSelectionPort {
  isCurrent: () => boolean;
  waitForCandidates: () => Promise<void>;
  select: (description: string) => Promise<number>;
}

export interface SubjectSelectionSnapshot {
  stage: string;
  message: string;
  subjectId?: number;
  active: boolean;
}

// Owns only a visual target's lifetime, independent of the requested action.
export class SubjectSelectionWorkflow {
  private stage: string = 'idle';
  private message: string = '';
  private epoch: number = 0;
  private subjectId?: number;
  private host?: SubjectSelectionPort;
  private expiresAt: number = 0;
  private changed: () => void;
  private now: () => number;

  constructor(changed: () => void, now: () => number = (): number => Date.now()) {
    this.changed = changed; this.now = now;
  }

  snapshot(): SubjectSelectionSnapshot {
    if (['confirm', 'confirmed'].includes(this.stage) &&
      (this.now() >= this.expiresAt || this.host?.isCurrent() !== true)) {
      this.epoch++; this.subjectId = undefined; this.host = undefined;
      this.stage = 'failed'; this.message = '主体确认或飞行方案已过期，或飞机状态已变化，请重新发起';
    }
    return { stage: this.stage, message: this.message, subjectId: this.subjectId,
      active: ['scanning', 'selecting', 'confirm', 'confirmed'].includes(this.stage) };
  }

  async start(description: string, host: SubjectSelectionPort): Promise<void> {
    if (this.snapshot().active) throw new Error('已有主体选择流程进行中，请先取消');
    const epoch = ++this.epoch;
    this.host = host; this.subjectId = undefined;
    try {
      this.check(epoch, host);
      this.update('scanning', '正在复核画面并寻找主体…');
      await host.waitForCandidates(); this.check(epoch, host);
      this.update('selecting', '正在根据你的描述选择主体…');
      const subjectId = await host.select(description); this.check(epoch, host);
      if (!Number.isInteger(subjectId) || subjectId < 0 || subjectId > 255) {
        throw new Error('没有找到明确的主体，请重新描述');
      }
      this.subjectId = subjectId; this.expiresAt = this.now() + 30000;
      this.update('confirm', '请确认画面中框选的主体');
    } catch (error) {
      if (epoch === this.epoch) {
        this.subjectId = undefined; this.host = undefined;
        this.update('failed', error instanceof Error ? error.message : '主体选择失败');
      }
      throw error instanceof Error ? error : new Error('主体选择失败');
    }
  }

  confirm(): number {
    if (this.snapshot().stage !== 'confirm' || this.subjectId === undefined || this.host === undefined) {
      throw new Error('没有有效的主体确认，请重新发起');
    }
    this.check(this.epoch, this.host);
    this.expiresAt = this.now() + 30000;
    this.update('confirmed', '主体已确认');
    return this.subjectId;
  }

  consume(): number {
    if (this.snapshot().stage !== 'confirmed' || this.subjectId === undefined || this.host === undefined) {
      throw new Error('没有有效的主体确认，请重新发起');
    }
    this.check(this.epoch, this.host);
    const subjectId = this.subjectId;
    this.subjectId = undefined; this.host = undefined;
    this.update('completed', '主体确认已使用');
    return subjectId;
  }

  cancel(): void {
    const active = this.snapshot().active;
    this.epoch++; this.subjectId = undefined; this.host = undefined;
    if (active) this.update('cancelled', '主体选择已取消');
  }

  retireInactive(): boolean {
    if (this.snapshot().active) return false;
    this.epoch++; this.subjectId = undefined; this.host = undefined;
    this.update('idle', '');
    return true;
  }

  private check(epoch: number, host: SubjectSelectionPort): void {
    if (epoch !== this.epoch || !host.isCurrent()) throw new Error('主体选择流程已取消或飞机状态已变化');
  }

  private update(stage: string, message: string): void {
    this.stage = stage; this.message = message; this.changed();
  }
}
