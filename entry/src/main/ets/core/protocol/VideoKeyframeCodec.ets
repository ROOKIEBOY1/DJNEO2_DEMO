import { encodeDumlFrame } from './DumlCodec';

export function buildVideoKeyframeRequest(sequence: number, monotonicMs: number, enabled: boolean): Uint8Array {
  if (!Number.isSafeInteger(monotonicMs) || monotonicMs < 0 || typeof enabled !== 'boolean') {
    throw new Error('Invalid keyframe flag or monotonic clock');
  }
  const payload = new Uint8Array(10);
  payload.set([0, 8]);
  const view = new DataView(payload.buffer);
  view.setUint32(2, monotonicMs % 0x100000000, true);
  view.setUint32(6, enabled ? 1 : 0, true);
  return encodeDumlFrame(2, 0xe9, sequence, 0, 0x18, 0x47, payload);
}
