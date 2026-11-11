import { ConsoleSnapshot } from './AppController';
import { SubjectTaskSnapshot } from './SubjectTaskWorkflow';

export interface FlightPlanPresentation {
  title: string;
  detail: string;
  lines: string[];
}

export interface TaskProgressPresentation {
  visible: boolean;
  title: string;
  lines: string[];
}

export interface VideoResultPresentation { title: string; detail: string; }
export interface ResultMetric { label: string; value: string; mocked: boolean; }

export function subjectTaskSnapshot(state: ConsoleSnapshot): SubjectTaskSnapshot {
  return state.subjectTask ?? state.groundDolly;
}

export function subjectConfirmationLabel(state: ConsoleSnapshot): string {
  return subjectTaskSnapshot(state).plan?.action === 'record_start' ? '确认录像主体' : '确认主体';
}

export function flightPlanPresentation(state: ConsoleSnapshot): FlightPlanPresentation {
  const plan = subjectTaskSnapshot(state).plan;
  if (plan?.recipe === 'dolly_circle') return {
    title: '方案：特写组合镜头',
    detail: '小艺将为你确认的同一个主体先拍滑动变焦，再进行2米环绕；全部拍摄结束后统一取回录像。',
    lines: [
      '第1步：滑动变焦',
      `拍摄景别：${plan.framing ?? '半身'}`,
      `滑动变焦目标倍率：${zoomLabel(plan.zoom ?? 3)}`,
      `渐远拍摄：${plan.retreat === false ? '关闭' : '开启'}`,
      '第2步：同主体2米环绕',
      '接力方式：滑动变焦结束并确认原主体后，启动环绕',
      '录像回传：两步拍摄全部结束后统一取回',
      '拍摄素材：保留两步全部录像',
      '任务结束：悬停'
    ]
  };
  const retreat = plan?.retreat;
  return {
    title: '方案：希区柯克运镜',
    detail: '小艺已锁定你确认的拍摄主体，将通过持续变焦营造背景变化，保留本次拍摄的全部录像。',
    lines: [
      retreat === true ? '运镜组合：后退拍摄 + 持续变焦' :
        retreat === false ? '运镜组合：持续变焦（渐远关闭）' : '运镜组合：待确认',
      `拍摄景别：${plan?.framing ?? '待确认'}`,
      `目标倍率：${zoomLabel(plan?.zoom)}`,
      retreat === true ? '预计画面：保持主体构图 → 渐远拍摄 → 持续变焦' :
        retreat === false ? '预计画面：保持主体构图 → 持续变焦' : '预计画面：待确认',
      '拍摄素材：保留本次全部录像',
      '任务结束：悬停'
    ]
  };
}

export function taskProgressPresentation(state: ConsoleSnapshot): TaskProgressPresentation {
  const task = subjectTaskSnapshot(state);
  const stage = task.stage;
  const action = task.plan?.action;
  const compound = state.closeup?.active === true;
  if (videoTransferActive(state) || !compound && (action === 'photo' || action === 'select_subject' || action === 'record_start')) {
    return { visible: false, title: '飞行任务进度', lines: [] };
  }
  const stepKind = state.closeup?.step === 2 ? 'circle' : 'dolly';
  const preparing = ['taking_off', 'scanning', 'selecting', 'confirm', 'plan'].includes(stage);
  const independent = action === 'follow' || action === 'circle';
  const kindMatches = !independent || state.nativeTask.kind === action;
  const recording = compound && state.nativeTask.kind !== stepKind || !kindMatches ? undefined : freshRecording(state);
  const ownsShooting = stage === 'shooting' && task.plan !== undefined;
  const visible = compound || !preparing && !videoResultReady(state) && (stage === 'starting' || ownsShooting ||
    state.nativeTask.activeOrUnknown || state.videoCapturePending || recording === true);
  const zoom = task.plan?.zoom ?? state.nativeTask.config?.zoom;
  let phase = '等待任务状态';
  if (compound) phase = closeupPhase(state, stepKind, recording);
  else if (stage === 'starting') phase = independent ? `准备${taskName(action)}` : '准备录像与运镜';
  else if (state.nativeTask.activeOrUnknown && kindMatches) phase = state.nativeTask.executionObserved ?
    `正在执行${taskName(state.nativeTask.kind)}` : '等待运镜执行回报';
  else if (recording === true) phase = '正在录制画面';
  else if (stage === 'shooting') phase = '正在整理拍摄素材';
  const lines = [`飞行阶段：${phase}`];
  if (!independent) lines.push(`目标倍率：${zoomLabel(zoom)}`);
  if (action === 'circle' && task.plan?.radiusMeters !== undefined) lines.push(`环绕半径：${task.plan.radiusMeters}米`);
  lines.push(
    `录制状态：${recording === true ? '正在录制' : recording === false ? '已停止录制' : '等待相机状态回报'}`,
    '任务结束：悬停'
  );
  if (compound) lines.unshift(`组合步骤：${state.closeup.step}/2 · ${stepKind === 'circle' ? '同主体2米环绕' : '滑动变焦'}`);
  return { visible: visible, title: '飞行任务进度', lines: lines };
}

export function videoTransferActive(state: ConsoleSnapshot): boolean {
  // A deferred closeup group stays in its shooting step until both tasks finish.
  if (state.closeup?.active === true) return state.closeup.stage === 'returning';
  if (!state.videoCapturePending) return false;
  // Retrieval reports are newer evidence than generic workflow/native-task flags.
  if (hasMediaTransferFeedback(state)) return true;
  if (subjectTaskSnapshot(state).plan?.action === 'record_start' && state.recordingRequested) return false;
  if (['taking_off', 'scanning', 'selecting', 'confirm', 'plan', 'starting'].includes(subjectTaskSnapshot(state).stage)) return false;
  return freshRecording(state) !== true && !state.nativeTask.activeOrUnknown;
}

export function hasMediaTransferFeedback(state: ConsoleSnapshot): boolean {
  return /^(自动取回未完成|正在从飞机取回|正在等待飞机生成|正在等待相机)/.test(state.agentFeedback);
}

export function videoResultReady(state: ConsoleSnapshot): boolean {
  const task = subjectTaskSnapshot(state);
  const stage = task.stage;
  const blocked = ['taking_off', 'scanning', 'selecting', 'confirm', 'plan', 'starting'].includes(stage);
  // A completed local group remains playable when aircraft telemetry later expires or disconnects.
  // The controller retires this fact before starting another capture or ground workflow.
  const partial = partialCloseup(state);
  return state.agentVideoResultReady && state.closeup?.active !== true && !blocked && !task.active &&
    (!state.videoCapturePending || partial) &&
    (state.agentConfirmation ?? '').length === 0 &&
    state.agentMediaKind === 'video' && state.agentMediaUri.length > 0 &&
    (state.agentMediaUris ?? []).includes(state.agentMediaUri);
}

export function videoResultPresentation(state: ConsoleSnapshot): VideoResultPresentation {
  if (partialCloseup(state)) return {
    title: '部分拍摄素材',
    detail: `特写组合${state.closeup.stage === 'cancelled' ? '已取消' : '未完成'}，已保留${state.agentMediaUris.length}段录像，可播放或保存至相册。`
  };
  if (subjectTaskSnapshot(state).plan?.action === 'record_start') return {
    title: '录像结果', detail: '本次主体录像已取回，可在对话中播放或保存至相册。'
  };
  return { title: '飞行任务结果', detail: state.closeup?.stage === 'completed' ?
    '小艺已取回本次特写组合的全部录像，可在对话中播放或保存至相册。' :
    '本次原片已取回，可在对话中播放或保存至相册。' };
}

export function flightResultMetrics(state: ConsoleSnapshot): ResultMetric[] {
  if (subjectTaskSnapshot(state).plan?.action === 'record_start') return [];
  // Current telemetry exposes flight flags but no battery, flight clock or odometry.
  // Keep demo values explicit; recording duration is not a flight duration source.
  return [
    { label: '设备状态：', value: deviceState(state), mocked: false },
    { label: '剩余电量：', value: '80%', mocked: true },
    { label: '实际飞行时长：', value: '40秒', mocked: true },
    { label: '实际飞行距离：', value: '10米', mocked: true }
  ];
}

function deviceState(state: ConsoleSnapshot): string {
  const phase = state.session.phase;
  if (phase === 'disconnected') return '未连接';
  if (phase === 'failed') return '连接异常';
  if (phase === 'closing') return '正在断开';
  if (phase === 'selecting_network' || phase === 'handshaking' || phase === 'registering') return '连接中';
  if (phase !== 'ready') return '状态待更新';
  const telemetry = state.session.telemetry;
  const flight = telemetry.flight;
  if ((telemetry.flightAgeMs ?? Infinity) <= 1000 && flight !== undefined) {
    if (flight.airborne === true) return '飞行中';
    if (flight.motorsOn === true) return '电机运行中';
    if (flight.airborne === false && flight.motorsOn === false) return '已着陆';
  }
  return '已连接，飞行状态待更新';
}

function partialCloseup(state: ConsoleSnapshot): boolean {
  return state.closeup?.stage === 'failed' || state.closeup?.stage === 'cancelled';
}

function closeupPhase(state: ConsoleSnapshot, stepKind: string, recording?: boolean): string {
  const kindMatches = state.nativeTask.kind === stepKind;
  if (kindMatches && state.nativeTask.activeOrUnknown) return state.nativeTask.executionObserved ?
    `正在执行${taskName(stepKind)}` : '等待本步运镜执行回报';
  if (recording === true) return '正在录制本步画面';
  if (state.closeup.stage === 'dolly' || state.closeup.stage === 'circle') {
    return stepKind === 'circle' ? '正在准备同主体2米环绕' : '正在准备滑动变焦';
  }
  return stepKind === 'circle' ? '等待环绕结束及相机空闲' : '等待滑动变焦结束及相机空闲';
}

function freshRecording(state: ConsoleSnapshot): boolean | undefined {
  const telemetry = state.session.telemetry;
  const camera = telemetry.camera;
  if (camera === undefined || (telemetry.cameraAgeMs ?? Infinity) > 1000) return undefined;
  const start = state.nativeTask.startedAtMs;
  if (start !== undefined && (camera.observedAtMs === undefined || camera.observedAtMs < start)) return undefined;
  return camera.recordingCandidate;
}

function zoomLabel(zoom?: number): string {
  return zoom === 2 || zoom === 3 ? `${zoom}倍` : '待确认';
}

function taskName(kind: string): string {
  if (kind === 'dolly') return '希区柯克运镜';
  if (kind === 'circle') return '环绕运镜';
  if (kind === 'follow') return '跟随拍摄';
  return '飞行任务';
}
