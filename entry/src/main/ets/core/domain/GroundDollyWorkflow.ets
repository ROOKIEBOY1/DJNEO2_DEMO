import { AgentAction, AgentOutcome } from './AgentAction';
import { SubjectTaskWorkflow, SubjectTaskSnapshot, SubjectTaskPort } from './SubjectTaskWorkflow';

export interface GroundDollySnapshot extends SubjectTaskSnapshot {}

export interface GroundDollyPort extends SubjectTaskPort {}

// Compatibility for callers whose selection phase still returns a complete dolly action.
export class GroundDollyWorkflow extends SubjectTaskWorkflow {
  async start(description: string, intent: AgentAction, host: GroundDollyPort,
    entry: 'ground' | 'hover' = 'ground'): Promise<AgentOutcome> {
    if (intent.action !== 'dolly_zoom') throw new Error('不是滑动变焦拍摄请求');
    return super.start(description, intent, host, entry);
  }

  protected selectionCommand(intent: AgentAction, selected: AgentAction): AgentAction {
    if (selected.action !== 'dolly_zoom' || selected.subjectId === undefined) {
      throw new Error(selected.message ?? '没有找到明确的拍摄主体，请重新描述');
    }
    const command: AgentAction = { action: 'dolly_zoom', subjectId: selected.subjectId };
    const framing = intent.framing ?? selected.framing;
    const zoom = intent.zoom ?? selected.zoom;
    const retreat = intent.retreat ?? selected.retreat;
    if (framing !== undefined) command.framing = framing;
    if (zoom !== undefined) command.zoom = zoom;
    if (retreat !== undefined) command.retreat = retreat;
    if (intent.recipe !== undefined) command.recipe = intent.recipe;
    return command;
  }
}
