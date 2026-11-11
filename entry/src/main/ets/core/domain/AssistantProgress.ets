import { ConsoleSnapshot } from './AppController';
import { videoResultReady, videoResultPresentation, videoTransferActive, hasMediaTransferFeedback, subjectTaskSnapshot, subjectConfirmationLabel } from './AssistantFlightPresentation';

export interface AssistantProgress { title: string; detail: string; busy: boolean; }

export function assistantProgress(state: ConsoleSnapshot, status: string = ''): AssistantProgress {
  if (state.busy && state.lastOperation === '执行连续基础运动') {
    return { title: '正在执行连续基础运动', detail: state.agentFeedback, busy: true };
  }
  if (state.busy && /^(前进|后退|左移|右移|上升|下降|左转|右转) \d+(\.\d+)? 秒$/.test(state.lastOperation ?? '')) {
    return { title: '正在执行基础移动', detail: state.agentFeedback, busy: true };
  }
  if (state.busy && state.lastOperation === '整理上次拍摄素材') return {
    title: '正在整理上次拍摄素材',
    detail: state.agentFeedback.length > 0 ? `小艺${state.agentFeedback}` :
      '小艺正在核对上次拍摄的录像目录，确认后继续本次拍摄…', busy: true
  };
  if (status.length > 0 && (status === state.lastError ||
    /^(当前操作正在执行，未排队起飞|请先完成飞机连接与初始化|尚无新鲜飞行状态|飞机尚未处于落地停桨状态)/.test(status))) {
    return { title: '小艺提示', detail: status, busy: false };
  }
  const task = subjectTaskSnapshot(state);
  const stage = task.stage;
  const action = task.plan?.action;
  const currentSubjectPrompt = ['taking_off', 'scanning', 'selecting', 'confirm', 'plan'].includes(stage) ||
    ['follow', 'circle', 'photo', 'record_start', 'select_subject'].includes(action ?? '') && ['starting', 'shooting', 'completed'].includes(stage);
  const closeup = state.closeup;
  if (closeup?.active === true && closeup.stage === 'returning') return transferProgress(state, true);
  if (closeup?.active === true && closeup.stage === 'circle' &&
    state.agentFeedback === '小艺正在恢复实时画面，确认原主体后继续环绕') return {
    title: '正在恢复实时画面', detail: state.agentFeedback, busy: true
  };
  if (closeup?.active === true) return {
    title: `飞行任务执行中 · ${closeup.step}/2`,
    detail: closeup.step === 2 ? (closeup.stage === 'circle' ?
      '小艺正在准备同主体2米环绕，两步拍摄全部结束后统一取回录像…' :
      '小艺正在等待同主体2米环绕结束，全部拍摄结束后统一取回录像…') :
      '小艺正在等待滑动变焦结束，随后衔接同主体2米环绕；全部拍摄结束后统一取回录像。', busy: true
  };
  if (!task.active && status === state.agentFeedback &&
    /^已完成(前进|后退|左移|右移|上升|下降|左转|右转) \d+(\.\d+)? 秒并回中$/.test(status)) {
    return { title: '基础移动已完成', detail: `小艺${status}`, busy: false };
  }
  if (!task.active && status === state.agentFeedback &&
    (status === '飞机已确认起飞请求' || status === '飞机已确认降落请求')) {
    return { title: '小艺提示', detail: status, busy: false };
  }
  if (!currentSubjectPrompt && (closeup?.stage === 'failed' || closeup?.stage === 'cancelled')) return {
    title: closeup.stage === 'cancelled' ? '特写组合已取消' : '特写组合未完成',
    detail: `小艺提示：${closeup.message}${state.videoCapturePending && hasMediaTransferFeedback(state) &&
      !closeup.message.includes(state.agentFeedback) ? `；${state.agentFeedback}` : ''}` +
      `${videoResultReady(state) ? `；${videoResultPresentation(state).detail}` : ''}`, busy: false
  };
  if (videoTransferActive(state)) return transferProgress(state, false);
  if (stage === 'taking_off') return { title: '无人机起飞并寻找主体',
    detail: '小艺正在启动无人机，悬停后将寻找你描述的主体…', busy: true };
  if (stage === 'scanning') return { title: task.entry === 'hover' ? '正在寻找主体' : '无人机起飞并寻找主体',
    detail: '小艺正在获取无人机实时画面，并扫描可选主体…', busy: true };
  if (stage === 'selecting') return { title: '正在寻找主体',
    detail: '小艺正在分析实时画面，将用高亮框标出目标主体…', busy: true };
  if (stage === 'confirm') return { title: `请${subjectConfirmationLabel(state)}`,
    detail: `小艺已用渐变高亮框标出目标，确认后将${confirmationNext(action)}。`, busy: false };
  if (stage === 'plan') return { title: '飞行方案已生成',
    detail: task.plan?.recipe === 'dolly_circle' ?
      '小艺已生成滑动变焦与同主体2米环绕的组合方案，点击“一键执行”开始拍摄。' :
      '小艺已根据你确认的主体生成方案，点击“一键执行”开始拍摄。', busy: false };
  if (stage === 'starting') {
    if (action === 'select_subject') return { title: '正在确认主体',
      detail: '小艺正在复核实时画面并选定你确认的主体，请稍候…', busy: true };
    if (action === 'photo') return { title: '正在准备主体拍照',
      detail: '小艺正在复核实时画面并准备为你确认的主体拍照，请稍候…', busy: true };
    if (action === 'record_start') return { title: '正在准备录像',
      detail: '小艺正在复核实时画面并准备为你确认的主体录像，请稍候…', busy: true };
    const name = action === 'follow' ? '跟随拍摄' : action === 'circle' ? '主体环绕拍摄' : '拍摄';
    return { title: `正在准备${name}`,
      detail: `小艺正在锁定主体并准备${action === 'follow' || action === 'circle' ? name : '运镜'}，请稍候…`, busy: true };
  }
  if (stage === 'completed' && (action === 'photo' || action === 'select_subject')) return {
    title: action === 'photo' ? '主体拍照已完成' : '主体已确认',
    detail: `小艺提示：${task.message || (action === 'photo' ? '照片已取回，可在下方查看。' : '已选定你确认的主体。')}`, busy: false };
  if (status.length > 0 && /失败|未完成|已取消|未找到|发生变化|无法|^请|^当前|^没有/.test(status)) {
    return { title: '小艺提示', detail: status, busy: false };
  }
  if (status.includes('正在理解')) return { title: '正在理解拍摄需求', detail: '小艺正在理解你的拍摄需求，请稍候…', busy: true };
  if (videoResultReady(state)) return {
    title: action === 'record_start' ? '录像已完成' : closeup?.stage === 'completed' ? '特写组合已完成' : '飞行任务已执行完成',
    detail: action !== 'record_start' && closeup?.stage === 'completed' ? `小艺已取回两步拍摄的全部录像，共${state.agentMediaUris.length}段，可直接播放，或保存至相册。` :
      `小艺已取回本次录像，共${state.agentMediaUris.length}段，可直接播放，或保存至相册。`, busy: false };
  const telemetry = state.session.telemetry;
  if (stage === 'shooting' && action === 'record_start') {
    if ((telemetry.cameraAgeMs ?? Infinity) <= 1000 && telemetry.camera?.recordingCandidate === true) return {
      title: '正在录像', detail: '小艺正在为你确认的主体录像，停止录像后将取回本次素材…', busy: true };
    return { title: '正在等待录像状态', detail: '小艺已发送主体录像请求，正在等待新鲜相机状态回报…', busy: true };
  }
  if (stage === 'shooting' && (action === 'follow' || action === 'circle') && state.nativeTask.activeOrUnknown) return {
    title: action === 'follow' ? '正在跟随拍摄' : '正在主体环绕拍摄',
    detail: state.nativeTask.executionObserved ?
      `小艺正在控制无人机${action === 'follow' ? '跟随' : '环绕'}你确认的主体，拍摄结束后将为你取回录像…` :
      '小艺已发送拍摄请求，正在等待无人机的执行回报…', busy: true };
  if ((telemetry.cameraAgeMs ?? Infinity) <= 1000 && telemetry.camera?.recordingCandidate === true) {
    return { title: state.nativeTask.activeOrUnknown ? '正在拍摄运镜' : '正在录像',
      detail: state.nativeTask.activeOrUnknown && state.nativeTask.executionObserved ?
        '小艺正在控制无人机完成运镜，拍摄结束后将为你取回录像…' : '小艺正在为你录制画面，结束后将取回本次录像…', busy: true };
  }
  if (stage === 'shooting' && (task.plan !== undefined || state.nativeTask.activeOrUnknown || state.videoCapturePending)) {
    if (state.nativeTask.activeOrUnknown) return { title: '正在拍摄运镜',
      detail: state.nativeTask.executionObserved ? '小艺正在控制无人机完成运镜，拍摄结束后将为你取回录像…' :
        '小艺已发送拍摄请求，正在等待无人机的执行回报…', busy: true };
    return { title: '正在取回拍摄录像', detail: `小艺正在整理并取回本次录像${transferDetail(state.agentFeedback)}`, busy: true };
  }
  if (stage === 'failed' || stage === 'cancelled') return { title: stage === 'cancelled' ? '本次流程已取消' : '拍摄流程未完成',
    detail: `小艺提示：${task.message}`, busy: false };
  if (state.videoCapturePending) return { title: '正在取回拍摄录像',
    detail: `小艺正在整理并取回本次录像${transferDetail(state.agentFeedback)}`, busy: true };
  return { title: status.length > 0 ? '小艺提示' : '小艺正在获取实时画面',
    detail: status.length > 0 ? status : '小艺正在获取无人机实时画面，请稍候…', busy: false };
}

function confirmationNext(action?: string): string {
  if (action === 'follow') return '开始跟随拍摄';
  if (action === 'circle') return '开始主体环绕拍摄';
  if (action === 'photo') return '拍摄该主体';
  if (action === 'record_start') return '开始为该主体录像';
  if (action === 'select_subject') return '选定该主体';
  return '为你生成飞行方案';
}

function transferProgress(state: ConsoleSnapshot, compound: boolean): AssistantProgress {
  if (state.agentFeedback.startsWith('自动取回未完成')) return {
    title: '录像回传未完成',
    detail: `小艺暂未取回完整录像：${state.agentFeedback.replace(/^自动取回未完成[：:]?/, '')}`, busy: false
  };
  return {
    title: compound ? '正在统一取回录像' : '正在取回拍摄录像',
    detail: `${compound ? '小艺已完成两步运镜，正在统一取回全部拍摄素材' : '小艺正在整理并取回本次录像'}` +
      transferDetail(state.agentFeedback), busy: true
  };
}

function transferDetail(feedback: string): string {
  if (feedback.startsWith('正在从飞机取回') || feedback.startsWith('正在等待')) return `，${feedback.replace(/^正在/, '')}`;
  return '…';
}
