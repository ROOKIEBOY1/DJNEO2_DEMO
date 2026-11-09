import { AgentAction, AgentOutcome } from './AgentAction';

export interface GroundDollySnapshot {
  stage: string;
  message: string;
  entry?: 'ground' | 'hover';
  subjectId?: number;
  plan?: AgentAction;
  active: boolean;
}

export interface GroundDollyPort {
  isCurrent: () => boolean;
  takeoff: () => Promise<void>;
  waitForCandidates: () => Promise<void>;
  select: (description: string, intent: AgentAction) => Promise<AgentAction>;
  shoot: (command: AgentAction) => Promise<AgentOutcome>;
}

export class GroundDollyWorkflow {
  private stage: string = 'idle';
  private message: string = '';
  private entry: 'ground' | 'hover' = 'ground';
  private epoch: number = 0;
  private pending?: AgentAction;
  private plan?: AgentAction;
  private host?: GroundDollyPort;
  private expiresAt: number = 0;
  private changed: () => void;
  private now: () => number;

  constructor(changed: () => void, now: () => number = (): number => Date.now()) {
    this.changed = changed; this.now = now;
  }
  snapshot(): GroundDollySnapshot {
    if (['confirm', 'plan'].includes(this.stage) && (this.now() > this.expiresAt || this.host?.isCurrent() !== true)) {
      this.pending = undefined; this.plan = undefined; this.host = undefined;
      this.stage = 'failed'; this.message = '主体确认或飞行方案已过期，或飞机状态已变化，请重新发起';
    }
    return { stage: this.stage, message: this.message, entry: this.entry, subjectId: this.plan?.subjectId,
      plan: this.plan === undefined ? undefined : copyDollyPlan(this.plan),
      active: ['taking_off', 'scanning', 'selecting', 'confirm', 'plan', 'starting'].includes(this.stage) };
  }
  cancel(): void {
    const active = this.snapshot().active;
    this.epoch++; this.pending = undefined; this.plan = undefined; this.host = undefined;
    if (active) this.update('cancelled', '拍摄流程已取消，请查看飞机状态');
  }
  private update(stage: string, message: string): void {
    this.stage = stage; this.message = message; this.changed();
  }
  private check(epoch: number, host: GroundDollyPort): void {
    if (epoch !== this.epoch || !host.isCurrent()) throw new Error('拍摄流程已取消或飞机状态已变化');
  }
  async start(description: string, intent: AgentAction, host: GroundDollyPort,
    entry: 'ground' | 'hover' = 'ground'): Promise<AgentOutcome> {
    if (this.snapshot().active) throw new Error('已有拍摄流程进行中，请先取消或降落');
    if (intent.action !== 'dolly_zoom') throw new Error('不是滑动变焦拍摄请求');
    const epoch = ++this.epoch;
    this.host = host; this.pending = undefined; this.plan = undefined; this.entry = entry;
    try {
      this.check(epoch, host);
      if (entry === 'ground') {
        this.update('taking_off', '已理解拍摄要求，正在起飞…');
        await host.takeoff(); this.check(epoch, host);
      }
      this.update('scanning', entry === 'hover' ? '正在复核悬停状态并寻找拍摄主体…' : '正在等待悬停并扫描主体…');
      await host.waitForCandidates(); this.check(epoch, host);
      this.update('selecting', '正在根据你的描述选择拍摄主体…');
      const selected = await host.select(description, intent); this.check(epoch, host);
      if (selected.action !== 'dolly_zoom' || selected.subjectId === undefined) {
        throw new Error(selected.message ?? '没有找到明确的拍摄主体，请重新描述');
      }
      this.pending = copyDollyPlan(selected); this.plan = copyDollyPlan(selected); this.expiresAt = this.now() + 30000;
      this.update('confirm', '请确认粉色框中的主体，确认后将生成本次飞行方案');
      return { message: this.message, confirmationRequired: true };
    } catch (error) {
      if (epoch === this.epoch) {
        this.pending = undefined; this.plan = undefined; this.host = undefined;
        this.update('failed', error instanceof Error ? error.message : '拍摄准备失败');
      }
      throw error instanceof Error ? error : new Error('拍摄准备失败');
    }
  }
  async confirm(): Promise<AgentOutcome> {
    if (this.snapshot().stage !== 'confirm' || this.pending === undefined || this.host === undefined) {
      throw new Error('没有有效的主体确认，请重新发起');
    }
    this.check(this.epoch, this.host);
    this.expiresAt = this.now() + 30000;
    this.update('plan', '小艺已生成本次飞行方案，请点击一键执行开始拍摄');
    return { message: this.message, confirmationRequired: true };
  }
  async execute(): Promise<AgentOutcome> {
    if (this.snapshot().stage !== 'plan' || this.pending === undefined || this.host === undefined) {
      throw new Error('没有有效的飞行方案，请重新确认主体');
    }
    const epoch = this.epoch; const host = this.host; const command = this.pending;
    this.pending = undefined;
    this.update('starting', '正在执行飞行方案，准备录像与滑动变焦…');
    try {
      this.check(epoch, host);
      const result = await host.shoot(command); this.check(epoch, host);
      this.host = undefined;
      this.update('shooting', '已启动拍摄，结束后将自动取回本次录像');
      return result;
    } catch (error) {
      if (epoch === this.epoch) {
        this.plan = undefined; this.host = undefined;
        this.update('failed', error instanceof Error ? error.message : '拍摄启动失败');
      }
      throw error instanceof Error ? error : new Error('拍摄启动失败');
    }
  }
}

function copyDollyPlan(command: AgentAction): AgentAction {
  const plan: AgentAction = { action: 'dolly_zoom' };
  if (command.subjectId !== undefined) plan.subjectId = command.subjectId;
  if (command.framing !== undefined) plan.framing = command.framing;
  if (command.zoom !== undefined) plan.zoom = command.zoom;
  if (command.retreat !== undefined) plan.retreat = command.retreat;
  if (command.recipe !== undefined) plan.recipe = command.recipe;
  return plan;
}
