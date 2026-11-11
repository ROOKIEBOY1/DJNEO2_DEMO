import { AgentAction, AgentOutcome } from './AgentAction';
import { SubjectSelectionWorkflow, SubjectSelectionPort } from './SubjectSelectionWorkflow';

export interface SubjectTaskSnapshot {
  stage: string;
  message: string;
  entry?: 'ground' | 'hover';
  subjectId?: number;
  plan?: AgentAction;
  active: boolean;
}

export interface SubjectTaskPort {
  isCurrent: () => boolean;
  takeoff: () => Promise<void>;
  waitForCandidates: () => Promise<void>;
  select: (description: string, intent: AgentAction) => Promise<AgentAction>;
  shoot: (command: AgentAction) => Promise<AgentOutcome>;
}

export class SubjectTaskWorkflow {
  private stage: string = 'idle';
  private message: string = '';
  private entry: 'ground' | 'hover' = 'ground';
  private epoch: number = 0;
  private plan?: AgentAction;
  private host?: SubjectTaskPort;
  private selection: SubjectSelectionWorkflow;
  private changed: () => void;

  constructor(changed: () => void, now: () => number = (): number => Date.now()) {
    this.changed = changed;
    this.selection = new SubjectSelectionWorkflow((): void => this.changed(), now);
  }

  snapshot(): SubjectTaskSnapshot {
    const target = this.selection.snapshot();
    if (['scanning', 'selecting', 'confirm', 'plan'].includes(this.stage)) {
      if (['scanning', 'selecting', 'confirm'].includes(target.stage)) {
        this.stage = target.stage; this.message = target.message;
      } else if (['failed', 'cancelled'].includes(target.stage)) {
        this.stage = target.stage; this.message = target.message;
        this.plan = undefined; this.host = undefined;
      }
    }
    return { stage: this.stage, message: this.message, entry: this.entry,
      subjectId: this.plan?.subjectId ?? target.subjectId,
      plan: this.plan === undefined ? undefined : copySubjectCommand(this.plan),
      active: ['taking_off', 'scanning', 'selecting', 'confirm', 'plan', 'starting'].includes(this.stage) };
  }

  async start(description: string, intent: AgentAction, host: SubjectTaskPort,
    entry: 'ground' | 'hover' = 'ground'): Promise<AgentOutcome> {
    if (this.snapshot().active) throw new Error('已有主体任务流程进行中，请先取消或降落');
    if (!['dolly_zoom', 'follow', 'circle', 'photo', 'record_start', 'select_subject'].includes(intent.action)) {
      throw new Error('不是支持的主体任务请求');
    }
    const epoch = ++this.epoch;
    const command = copySubjectCommand(intent);
    this.host = host; this.plan = undefined; this.entry = entry;
    try {
      this.check(epoch, host);
      if (entry === 'ground' && ['dolly_zoom', 'follow', 'circle'].includes(command.action)) {
        this.update('taking_off', '已理解主体任务要求，正在起飞…');
        await host.takeoff(); this.check(epoch, host);
      }
      let selectedCommand: AgentAction = copySubjectCommand(command);
      const selectionPort: SubjectSelectionPort = {
        isCurrent: (): boolean => epoch === this.epoch && host.isCurrent(),
        waitForCandidates: (): Promise<void> => host.waitForCandidates(),
        select: async (text: string): Promise<number> => {
          const selected = await host.select(text, copySubjectCommand(command));
          this.check(epoch, host);
          selectedCommand = this.selectionCommand(command, selected);
          return selectedCommand.subjectId as number;
        }
      };
      this.stage = 'scanning';
      await this.selection.start(description, selectionPort); this.check(epoch, host);
      this.plan = copySubjectCommand(selectedCommand);
      this.update('confirm', command.action === 'dolly_zoom' ?
        '请确认画面中框选的主体，确认后将生成本次飞行方案' : '请确认画面中框选的主体，确认后将执行本次任务');
      return { message: this.message, confirmationRequired: true };
    } catch (error) {
      if (epoch === this.epoch) {
        this.plan = undefined; this.host = undefined;
        this.update('failed', error instanceof Error ? error.message : '主体任务准备失败');
      }
      throw error instanceof Error ? error : new Error('主体任务准备失败');
    }
  }

  async confirm(): Promise<AgentOutcome> {
    if (this.snapshot().stage !== 'confirm' || this.plan === undefined || this.host === undefined) {
      throw new Error('没有有效的主体确认，请重新发起');
    }
    this.check(this.epoch, this.host);
    this.selection.confirm();
    if (this.plan.action === 'dolly_zoom') {
      this.update('plan', '小艺已生成本次飞行方案，请点击一键执行开始拍摄');
      return { message: this.message, confirmationRequired: true };
    }
    return this.executeAction();
  }

  async execute(): Promise<AgentOutcome> {
    if (this.snapshot().stage !== 'plan' || this.plan === undefined || this.host === undefined) {
      throw new Error('没有有效的飞行方案，请重新确认主体');
    }
    return this.executeAction();
  }

  cancel(): void {
    const active = this.snapshot().active;
    this.epoch++; this.plan = undefined; this.host = undefined; this.selection.cancel();
    if (active) this.update('cancelled', '主体任务流程已取消，请查看飞机状态');
    else if (['shooting', 'completed'].includes(this.stage)) this.update('idle', '');
  }

  retireInactive(): boolean {
    if (this.snapshot().active) return false;
    this.epoch++; this.plan = undefined; this.host = undefined; this.selection.retireInactive();
    this.update('idle', '');
    return true;
  }

  // Compatibility hooks do not own any selection or confirmation state.
  protected selectionCommand(intent: AgentAction, selected: AgentAction): AgentAction {
    if (selected.action !== 'select_subject' || selected.subjectId === undefined) {
      throw new Error(selected.message ?? '没有找到明确的主体，请重新描述');
    }
    const command = copySubjectCommand(intent); command.subjectId = selected.subjectId;
    return command;
  }

  private async executeAction(): Promise<AgentOutcome> {
    const epoch = this.epoch; const host = this.host; const plan = this.plan;
    if (host === undefined || plan === undefined) throw new Error('没有有效的主体确认，请重新发起');
    const subjectId = this.selection.consume();
    const command = copySubjectCommand(plan); command.subjectId = subjectId;
    this.update('starting', command.action === 'dolly_zoom' ?
      '正在执行飞行方案，准备录像与滑动变焦…' : '主体已确认，正在执行本次任务…');
    try {
      this.check(epoch, host);
      const result = await host.shoot(command); this.check(epoch, host);
      this.host = undefined;
      this.update(['photo', 'select_subject'].includes(command.action) ? 'completed' : 'shooting', result.message);
      return result;
    } catch (error) {
      if (epoch === this.epoch) {
        this.plan = undefined; this.host = undefined;
        this.update('failed', error instanceof Error ? error.message : '主体任务启动失败');
      }
      throw error instanceof Error ? error : new Error('主体任务启动失败');
    }
  }

  private check(epoch: number, host: SubjectTaskPort): void {
    if (epoch !== this.epoch || !host.isCurrent()) throw new Error('主体任务流程已取消或飞机状态已变化');
  }

  private update(stage: string, message: string): void {
    this.stage = stage; this.message = message; this.changed();
  }
}

function copySubjectCommand(command: AgentAction): AgentAction {
  const copy: AgentAction = { action: command.action };
  if (command.subjectId !== undefined) copy.subjectId = command.subjectId;
  if (command.action === 'dolly_zoom') {
    if (command.framing !== undefined) copy.framing = command.framing;
    if (command.zoom !== undefined) copy.zoom = command.zoom;
    if (command.retreat !== undefined) copy.retreat = command.retreat;
    if (command.recipe !== undefined) copy.recipe = command.recipe;
  }
  if (command.action === 'circle' && command.radiusMeters !== undefined) copy.radiusMeters = command.radiusMeters;
  return copy;
}
