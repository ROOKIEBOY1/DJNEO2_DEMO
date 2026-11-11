import { AgentObservation } from './AgentAction';

// This only routes a reference; the model still classifies the requested action.
export function isSelfSubjectRequest(description: string): boolean {
  const text = description.replace(/\s/g, '');
  if (/(?:不要|别|不用|不必|不想)(?:再)?(?:拍|跟随|跟着|围着|锁定|切换到)我|我(?:和|与|以及|还有)/.test(text)) return false;
  const beneficiary = text.match(/(?:给|为)我拍(?:摄)?(.*)/);
  if (beneficiary !== null) {
    // Unknown target wording stays with ordinary selection, including names or mixed targets.
    return /^(?:(?:一|二|三|两|[0-9]+)?[个张段次倍]|一下|照(?:片)?|相片|视频|镜头|运镜|组合|特写|半身|全身|远景|近景|希区柯克|滑动变焦|人像|吧|[，。！？,.!?])*$/.test(beneficiary[1]);
  }
  return /(?:拍|跟随|跟着|围着|锁定|切换到)我(?!的|们|朋友|同事|家人|附近|(?:身|旁|前|后|左|右|对)(?:边|侧|面|前|后|旁))/.test(text);
}

export function needsSelfReference(observation: AgentObservation, description: string): boolean {
  return observation.purpose === 'subject_selection' && observation.frame !== undefined &&
    isSelfSubjectRequest(description);
}
