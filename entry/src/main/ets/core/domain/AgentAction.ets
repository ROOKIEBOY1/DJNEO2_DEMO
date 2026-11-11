import { VlmFrame, VLM_SELECTION_TIMEOUT_MS } from '../media/VlmFrame';
import { MovementDirection } from '../protocol/StickCodec';
import { DollyFraming } from '../protocol/NativeTaskCodec';
import { MovementStep, validateMovementSteps } from './MovementSequence';

export type AgentActionKind = 'select_subject' | 'cancel_subject' | 'set_dolly' | 'prepare_dolly' | 'dolly_zoom' |
  'circle' | 'follow' | 'photo' | 'record_start' | 'record_stop' | 'download_photo' | 'download_video' |
  'move' | 'move_sequence' | 'stop' | 'takeoff' | 'land' | 'none';

export type DirectFlightAction = 'takeoff' | 'land';

export function parseDirectFlightVoice(text: string): DirectFlightAction | undefined {
  const normalized = text.trim().replace(/[\s，。！,.!]/g, '');
  const match = normalized.match(/^(?:请帮我|请|帮我|请让无人机|让无人机|无人机|飞机|让飞机)?(?:现在|立即|马上|开始)?(起飞|降落)(?:吧|一下)?$/);
  if (match === null) return undefined;
  return match[1] === '起飞' ? 'takeoff' : 'land';
}

export function parseDirectStopVoice(text: string): 'stop' | 'record_stop' | undefined {
  const normalized = text.trim().replace(/[\s，。！,.!]/g, '');
  const match = normalized.match(/^(?:请帮我|请|帮我|请让无人机|让无人机|无人机|飞机|让飞机)?(?:现在|立即|马上|先)?(停止(?:任务|拍摄|运镜|录像|录制)?)(?:吧|一下)?$/);
  if (match === null) return undefined;
  return match[1] === '停止录像' || match[1] === '停止录制' ? 'record_stop' : 'stop';
}

export interface AgentAction {
  action: AgentActionKind;
  subjectId?: number;
  subjectRequired?: boolean;
  framing?: DollyFraming;
  zoom?: number;
  retreat?: boolean;
  recipe?: 'dolly_circle';
  radiusMeters?: number;
  direction?: MovementDirection;
  seconds?: number;
  steps?: MovementStep[];
  message?: string;
}

export interface AgentContext {
  phase: string;
  airborne: boolean;
  flightStateFresh: boolean;
  flightMode?: number;
  tracking: boolean;
  currentSubjectId?: number;
  taskKind: string;
  taskPrepared: boolean;
  taskActive: boolean;
  cameraIdle: boolean;
  recording: boolean;
  radiusMeters: number;
  framing: DollyFraming;
  zoom: number;
  retreat: boolean;
  movementSeconds: number;
}

export interface AgentObservation {
  purpose?: 'shoot_intent' | 'ground_dolly_intent' | 'dolly_subject' | 'subject_selection';
  requestId: string;
  sessionId: number;
  flightGeneration: number;
  controlGeneration: number;
  requestedAtMs: number;
  context: AgentContext;
  frame?: VlmFrame;
}

// Text-only planning can wait longer without extending the lifetime of visual IDs.
export const AGENT_TEXT_TIMEOUT_MS: number = 60000;

export function agentObservationTimeoutMs(observation: AgentObservation): number {
  return observation.frame === undefined ? AGENT_TEXT_TIMEOUT_MS : VLM_SELECTION_TIMEOUT_MS;
}

export interface AgentResponse {
  version: number;
  requestId: string;
  command?: AgentAction;
  error?: string;
}

export interface AgentOutcome {
  message: string;
  confirmationRequired?: boolean;
  subjectId?: number;
}

export function agentNeedsConfirmation(command: AgentAction): boolean {
  return ['dolly_zoom', 'circle', 'follow'].includes(command.action);
}

export function actionNeedsSubjectSelection(command: AgentAction): boolean {
  return ['dolly_zoom', 'follow', 'circle', 'select_subject'].includes(command.action) ||
    (['photo', 'record_start'].includes(command.action) &&
      (command.subjectId !== undefined || command.subjectRequired === true));
}

export function validateAgentAction(command: AgentAction, observation: AgentObservation): void {
  if (command === null || typeof command !== 'object' || Array.isArray(command)) throw new Error('动作格式无效');
  if (observation.purpose === 'subject_selection' && command.action !== 'select_subject' && command.action !== 'none') {
    throw new Error('选人阶段只能返回明确的主体选择或说明');
  }
  let fields: string[] = [];
  switch (command.action) {
    case 'select_subject': case 'photo': case 'record_start': fields = ['subjectId', 'subjectRequired']; break;
    case 'follow': fields = ['subjectId']; break;
    case 'set_dolly': fields = ['framing', 'zoom', 'retreat']; break;
    case 'dolly_zoom': fields = ['subjectId', 'framing', 'zoom', 'retreat', 'recipe']; break;
    case 'prepare_dolly': fields = ['framing', 'zoom', 'retreat']; break;
    case 'circle': fields = ['radiusMeters', 'subjectId']; break;
    case 'move': fields = ['direction', 'seconds']; break;
    case 'move_sequence': fields = ['steps']; break;
    case 'none': fields = ['message']; break;
    case 'cancel_subject': case 'record_stop':
    case 'download_photo': case 'download_video': case 'stop': case 'takeoff': case 'land': break;
    default: throw new Error('不支持的动作');
  }
  if (Object.keys(command).some(key => key !== 'action' && !fields.includes(key))) throw new Error('动作包含无效参数');
  if (command.action === 'move_sequence') validateMovementSteps(command.steps);
  if (command.subjectRequired !== undefined && typeof command.subjectRequired !== 'boolean') throw new Error('主体选择参数无效');
  if (observation.purpose === 'subject_selection' && command.subjectRequired !== undefined) {
    throw new Error('选人阶段不能修改已确认的动作或参数');
  }
  const initialIntent = observation.purpose === 'ground_dolly_intent' || observation.purpose === 'shoot_intent';
  const deferredSubject = initialIntent && command.subjectRequired === true;
  if (command.subjectId === undefined && !deferredSubject &&
    (command.action === 'select_subject' || command.subjectRequired === true)) throw new Error('选人缺少编号');
  if (command.subjectId !== undefined && (!Number.isInteger(command.subjectId) || command.subjectId < 0 ||
    command.subjectId > 255 || observation.frame === undefined ||
    !observation.frame.candidates.some(candidate => candidate.id === command.subjectId))) {
    throw new Error('目标编号不属于本次画面候选');
  }
  if (command.framing !== undefined && !['半身', '全身', '远景'].includes(command.framing)) throw new Error('景别无效');
  if (command.zoom !== undefined && command.zoom !== 2 && command.zoom !== 3) throw new Error('倍率仅支持 2 或 3');
  if (command.retreat !== undefined && typeof command.retreat !== 'boolean') throw new Error('渐远参数无效');
  if (command.recipe !== undefined && command.recipe !== 'dolly_circle') throw new Error('不支持的拍摄组合');
  if (command.radiusMeters !== undefined && (typeof command.radiusMeters !== 'number' ||
    !Number.isFinite(command.radiusMeters) || command.radiusMeters < 2 || command.radiusMeters > 10)) {
    throw new Error('环绕半径需要在 2–10 米内');
  }
  if (command.action === 'move' && !['forward', 'backward', 'left', 'right', 'up', 'down',
    'turn_left', 'turn_right'].includes(command.direction ?? '')) throw new Error('移动方向无效');
  if (command.action === 'move' && command.seconds === undefined) {
    throw new Error('模型未给出有效移动时长，请重新说明移动幅度或秒数');
  }
  if (command.seconds !== undefined && (typeof command.seconds !== 'number' || !Number.isFinite(command.seconds) ||
    command.seconds < 0.1 || command.seconds > 10)) throw new Error('单次移动时长需要在 0.1–10 秒内');
  if (command.message !== undefined && (typeof command.message !== 'string' || command.message.length > 160)) {
    throw new Error('动作说明无效');
  }
  if (command.action === 'set_dolly' && command.framing === undefined && command.zoom === undefined &&
    command.retreat === undefined) throw new Error('没有提供变焦参数');
}

export function validateAgentResponse(response: AgentResponse, observation: AgentObservation,
  sessionId: number, generation: number, now: number): void {
  const age = now - observation.requestedAtMs;
  if (response === null || typeof response !== 'object' || response.version !== 2 ||
    response.requestId !== observation.requestId || sessionId !== observation.sessionId ||
    generation !== observation.flightGeneration || age < 0 || age > agentObservationTimeoutMs(observation)) {
    throw new Error('动作响应已过期或飞机会话发生变化');
  }
  if (response.error !== undefined) throw new Error('云端识别失败，请重试');
  if (response.command === undefined) throw new Error('未收到有效动作');
  validateAgentAction(response.command, observation);
}

export function agentActionLabel(command: AgentAction): string {
  switch (command.action) {
    case 'select_subject': return command.subjectId === undefined ? '选择主体' : `选择主体 #${command.subjectId}`;
    case 'cancel_subject': return '取消主体锁定';
    case 'set_dolly': return '设置滑动变焦参数';
    case 'prepare_dolly': return '地面准备滑动变焦';
    case 'dolly_zoom': return command.recipe === 'dolly_circle' ?
      `启动特写组合 · 滑动变焦→同主体2米环绕${command.subjectId === undefined ? '' : ` · 主体 #${command.subjectId}`}` :
      `启动希区柯克 · ${command.framing} · ${command.zoom} 倍${command.subjectId === undefined ? '' : ` · 主体 #${command.subjectId}`}`;
    case 'circle': return `启动环绕 · 半径 ${command.radiusMeters ?? 2} 米${command.subjectId === undefined ? '' : ` · 主体 #${command.subjectId}`}`;
    case 'follow': return `启动独立跟随${command.subjectId === undefined ? '' : ` · 主体 #${command.subjectId}`}`;
    case 'photo': return '拍照';
    case 'record_start': return '开始录像';
    case 'record_stop': return '停止录像';
    case 'download_photo': return '下载最新照片';
    case 'download_video': return '下载最新录像';
    case 'move': {
      const directions: MovementDirection[] = ['forward', 'backward', 'left', 'right', 'up', 'down', 'turn_left', 'turn_right'];
      return `${['前进', '后退', '左移', '右移', '上升', '下降', '左转', '右转'][directions.indexOf(command.direction as MovementDirection)]} ${command.seconds} 秒`;
    }
    case 'move_sequence': return '执行连续基础运动';
    case 'stop': return '停止任务并回中';
    case 'takeoff': return '起飞';
    case 'land': return '降落';
    case 'none': return command.message ?? '未识别到明确动作';
  }
}
