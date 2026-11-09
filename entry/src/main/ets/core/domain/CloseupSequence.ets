export interface CloseupSequenceSnapshot {
  active: boolean;
  stage: string;
  step: number;
  message: string;
}

export interface CloseupSequencePort {
  isCurrent: () => boolean;
  startDolly: (isCurrent: () => boolean) => Promise<void>;
  finishDolly: (isCurrent: () => boolean) => Promise<void>;
  startCircle: (isCurrent: () => boolean) => Promise<void>;
  finishCircle: (isCurrent: () => boolean) => Promise<void>;
  returnMedia: (isCurrent: () => boolean) => Promise<void>;
}

// Each finish operation verifies its task ended and the camera is idle. Only the
// final return operation retrieves the shared media group, after both movements.
// The supplied gate also lets its asynchronous wait loops stop after cancellation.
export class CloseupSequence {
  private active: boolean = false;
  private running: boolean = false;
  private stage: string = 'idle';
  private step: number = 0;
  private message: string = '';
  private epoch: number = 0;
  private changed: () => void;

  constructor(changed: () => void) { this.changed = changed; }

  snapshot(): CloseupSequenceSnapshot {
    return { active: this.active, stage: this.stage, step: this.step, message: this.message };
  }

  cancel(): void {
    this.epoch++;
    if (!this.active) return;
    this.active = false;
    this.update('cancelled', this.step, '特写组合拍摄已取消，后续步骤不会启动');
  }

  reset(): void {
    this.epoch++; this.active = false;
    // Keep running locked until an outstanding old request settles. Its epoch no
    // longer owns this snapshot, so a late completion cannot restore old state.
    this.update('idle', 0, '');
  }

  async run(port: CloseupSequencePort): Promise<void> {
    // Cancellation invalidates gates immediately; it does not permit a second run to
    // overlap an outstanding request from the previous run before that request settles.
    if (this.running) throw new Error('已有特写组合流程正在执行，请稍候');
    const epoch = ++this.epoch;
    this.running = true; this.active = true; this.step = 0; this.message = '';
    const isCurrent = (): boolean => epoch === this.epoch && this.active && port.isCurrent();
    try {
      this.check(isCurrent);
      this.update('dolly', 1, '小艺正在执行第1步：滑动变焦');
      this.check(isCurrent);
      await port.startDolly(isCurrent);
      this.check(isCurrent);

      this.update('dolly_wait', 1, '小艺正在等待滑动变焦结束并确认相机空闲');
      this.check(isCurrent);
      await port.finishDolly(isCurrent);
      this.check(isCurrent);

      this.update('circle', 2, '小艺正在执行第2步：围绕已确认主体进行2米环绕');
      this.check(isCurrent);
      await port.startCircle(isCurrent);
      this.check(isCurrent);

      this.update('circle_wait', 2, '小艺正在等待环绕结束并确认相机空闲');
      this.check(isCurrent);
      await port.finishCircle(isCurrent);
      this.check(isCurrent);

      this.update('returning', 2, '两步运镜已结束，小艺正在统一取回全部拍摄录像');
      this.check(isCurrent);
      await port.returnMedia(isCurrent);
      this.check(isCurrent);

      this.active = false;
      this.update('completed', 2, '特写组合拍摄已完成，本次全部录像已取回');
    } catch (error) {
      const failure = error instanceof Error ? error : new Error(String(error));
      if (epoch === this.epoch) {
        this.active = false;
        this.update('failed', this.step, failure.message);
      }
      throw failure;
    } finally { this.running = false; }
  }

  private check(isCurrent: () => boolean): void {
    if (!isCurrent()) throw new Error('特写组合拍摄已取消或飞机状态已变化');
  }

  private update(stage: string, step: number, message: string): void {
    this.stage = stage; this.step = step; this.message = message; this.changed();
  }
}
