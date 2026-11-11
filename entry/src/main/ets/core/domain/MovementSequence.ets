import { MovementDirection, validateMovementDuration } from '../protocol/StickCodec';

export const MAX_MOVEMENT_STEPS: number = 8;
export const MAX_MOVEMENT_TOTAL_SECONDS: number = 30;

export interface MovementStep {
  direction: MovementDirection;
  seconds: number;
}

export interface MovementSequencePort {
  assertCurrent: () => void;
  move: (step: MovementStep) => Promise<void>;
  onStep: (step: MovementStep, index: number, total: number) => void;
}

export function validateMovementSteps(steps: MovementStep[] | undefined): void {
  if (!Array.isArray(steps) || steps.length < 2 || steps.length > MAX_MOVEMENT_STEPS) {
    throw new Error('连续基础运动需要 2–8 步');
  }
  let total: number = 0;
  for (const step of steps) {
    if (step === null || typeof step !== 'object' || Array.isArray(step) ||
      Object.keys(step).some(key => key !== 'direction' && key !== 'seconds')) {
      throw new Error('连续基础运动的步骤格式无效');
    }
    if (!['forward', 'backward', 'left', 'right', 'up', 'down', 'turn_left', 'turn_right'].includes(step.direction)) {
      throw new Error('连续基础运动只支持八个基础方向');
    }
    if (typeof step.seconds !== 'number' || !Number.isFinite(step.seconds) || step.seconds < 0.1) {
      throw new Error('连续基础运动每步时长需要在 0.1–10 秒内');
    }
    validateMovementDuration(step.seconds);
    total += step.seconds;
  }
  // Permit only floating-point addition noise at the exact 30-second boundary.
  if (total > MAX_MOVEMENT_TOTAL_SECONDS + Number.EPSILON * MAX_MOVEMENT_TOTAL_SECONDS) {
    throw new Error('连续基础运动总时长不能超过 30 秒');
  }
}

export async function runMovementSequence(steps: MovementStep[] | undefined,
  port: MovementSequencePort): Promise<void> {
  // Freeze the complete validated plan before emitting progress or sending a stick value.
  validateMovementSteps(steps);
  const plan: MovementStep[] = (steps as MovementStep[]).map(step => copyStep(step));
  for (let index: number = 0; index < plan.length; index++) {
    port.assertCurrent();
    port.onStep(copyStep(plan[index]), index + 1, plan.length);
    port.assertCurrent();
    // The existing move promise includes its finally/centering operation.
    await port.move(copyStep(plan[index]));
    port.assertCurrent();
  }
}

function copyStep(step: MovementStep): MovementStep {
  return { direction: step.direction, seconds: step.seconds };
}
