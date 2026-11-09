import { ConsoleSnapshot } from './AppController';
import { videoResultReady, videoResultPresentation, videoTransferActive, hasMediaTransferFeedback } from './AssistantFlightPresentation';

export interface AssistantProgress { title: string; detail: string; busy: boolean; }

export function assistantProgress(state: ConsoleSnapshot, status: string = ''): AssistantProgress {
  if (state.busy && state.lastOperation === '整理上次拍摄素材') return {
    title: '正在整理上次拍摄素材',
    detail: state.agentFeedback.length > 0 ? `小艺${state.agentFeedback}` :
      '小艺正在核对上次拍摄的录像目录，确认后继续本次拍摄…', busy: true
  };
  const stage = state.groundDolly.stage;
  const closeup = state.closeup;
  if (closeup?.active === true && closeup.stage === 'returning') return transferProgress(state, true);
  if (closeup?.active === true) return {
    title: `飞行任务执行中 · ${closeup.step}/2`,
    detail: closeup.step === 2 ? (closeup.stage === 'circle' ?
      '小艺正在准备同主体2米环绕，两步拍摄全部结束后统一取回录像…' :
      '小艺正在等待同主体2米环绕结束，全部拍摄结束后统一取回录像…') :
      '小艺正在等待滑动变焦结束，随后衔接同主体2米环绕；全部拍摄结束后统一取回录像。', busy: true
  };
  if (closeup?.stage === 'failed' || closeup?.stage === 'cancelled') return {
    title: closeup.stage === 'cancelled' ? '特写组合已取消' : '特写组合未完成',
    detail: `小艺提示：${closeup.message}${state.videoCapturePending && hasMediaTransferFeedback(state) &&
      !closeup.message.includes(state.agentFeedback) ? `；${state.agentFeedback}` : ''}` +
      `${videoResultReady(state) ? `；${videoResultPresentation(state).detail}` : ''}`, busy: false
  };
  if (videoTransferActive(state)) return transferProgress(state, false);
  if (stage === 'taking_off') return { title: '无人机起飞并寻找拍摄主体',
    detail: '小艺正在启动无人机，悬停后将寻找你描述的拍摄主体…', busy: true };
  if (stage === 'scanning') return { title: state.groundDolly.entry === 'hover' ? '正在寻找拍摄主体' : '无人机起飞并寻找拍摄主体',
    detail: '小艺正在获取无人机实时画面，并扫描可拍摄主体…', busy: true };
  if (stage === 'selecting') return { title: '正在寻找拍摄主体',
    detail: '小艺正在分析实时画面，将用高亮框标出目标拍摄主体…', busy: true };
  if (stage === 'confirm') return { title: '请确认拍摄主体',
    detail: '小艺已用渐变高亮框标出目标，确认后将为你生成飞行方案。', busy: false };
  if (stage === 'plan') return { title: '飞行方案已生成',
    detail: state.groundDolly.plan?.recipe === 'dolly_circle' ?
      '小艺已生成滑动变焦与同主体2米环绕的组合方案，点击“一键执行”开始拍摄。' :
      '小艺已根据你确认的主体生成方案，点击“一键执行”开始拍摄。', busy: false };
  if (stage === 'starting') return { title: '正在准备拍摄',
    detail: '小艺正在锁定主体并准备运镜，请稍候…', busy: true };
  if (status.length > 0 && /失败|未完成|已取消|未找到|发生变化|无法|^请|^当前|^没有/.test(status)) {
    return { title: '小艺提示', detail: status, busy: false };
  }
  if (status.includes('正在理解')) return { title: '正在理解拍摄需求', detail: '小艺正在理解你的拍摄需求，请稍候…', busy: true };
  if (videoResultReady(state)) return {
    title: closeup?.stage === 'completed' ? '特写组合已完成' : '飞行任务已执行完成',
    detail: closeup?.stage === 'completed' ? `小艺已取回两步拍摄的全部录像，共${state.agentMediaUris.length}段，可直接播放，或保存至相册。` :
      `小艺已取回本次录像，共${state.agentMediaUris.length}段，可直接播放，或保存至相册。`, busy: false };
  const telemetry = state.session.telemetry;
  if ((telemetry.cameraAgeMs ?? Infinity) <= 1000 && telemetry.camera?.recordingCandidate === true) {
    return { title: state.nativeTask.activeOrUnknown ? '正在拍摄运镜' : '正在录像',
      detail: state.nativeTask.activeOrUnknown && state.nativeTask.executionObserved ?
        '小艺正在控制无人机完成运镜，拍摄结束后将为你取回录像…' : '小艺正在为你录制画面，结束后将取回本次录像…', busy: true };
  }
  if (stage === 'shooting') {
    if (state.nativeTask.activeOrUnknown) return { title: '正在拍摄运镜',
      detail: state.nativeTask.executionObserved ? '小艺正在控制无人机完成运镜，拍摄结束后将为你取回录像…' :
        '小艺已发送拍摄请求，正在等待无人机的执行回报…', busy: true };
    return { title: '正在取回拍摄录像', detail: `小艺正在整理并取回本次录像${transferDetail(state.agentFeedback)}`, busy: true };
  }
  if (stage === 'failed' || stage === 'cancelled') return { title: stage === 'cancelled' ? '本次流程已取消' : '拍摄流程未完成',
    detail: `小艺提示：${state.groundDolly.message}`, busy: false };
  if (state.videoCapturePending) return { title: '正在取回拍摄录像',
    detail: `小艺正在整理并取回本次录像${transferDetail(state.agentFeedback)}`, busy: true };
  return { title: status.length > 0 ? '小艺提示' : '小艺正在获取实时画面',
    detail: status.length > 0 ? status : '小艺正在获取无人机实时画面，请稍候…', busy: false };
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
