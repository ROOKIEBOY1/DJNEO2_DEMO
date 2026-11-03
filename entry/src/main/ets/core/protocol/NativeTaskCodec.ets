import { bytesEqual, concatBytes, fromHex } from './Bytes';
import { CIRCLE_SELECTION_PAYLOAD, CIRCLE_START_PAYLOAD, radiusPayload, RADIUS_HASH_BYTES } from './CircleCodec';
export type NativeTaskKind = 'circle' | 'follow' | 'dolly';
export type DollyFraming = '半身' | '全身' | '远景';
export function nativeSelection(kind: NativeTaskKind): Uint8Array {
  if (kind === 'circle') return new Uint8Array(CIRCLE_SELECTION_PAYLOAD);
  return fromHex(kind === 'follow' ? '878867a30a000000' : '878867a30d000000');
}
export function nativeStart(kind: NativeTaskKind): Uint8Array {
  if (kind === 'circle') return new Uint8Array(CIRCLE_START_PAYLOAD);
  return fromHex(kind === 'follow' ? '010a00' : '010d00');
}
export function dollyParameterWrites(framing: DollyFraming, zoom: number, retreat: boolean): Uint8Array[] {
  if (!['半身', '全身', '远景'].includes(framing) || (zoom !== 2 && zoom !== 3)) throw new Error('景别或倍率无效');
  const value = new Uint8Array(4);
  new DataView(value.buffer).setFloat32(0, zoom, true);
  return [fromHex('1756ad4101'),
    concatBytes(fromHex('ae918fe4'), new Uint8Array([['半身', '全身', '远景'].indexOf(framing) + 1])),
    concatBytes(fromHex('c59f793d'), value),
    concatBytes(fromHex('a602eb59'), new Uint8Array([retreat ? 1 : 0]))];
}
export function validateNativeRequest(kind: NativeTaskKind, receiver: number, set: number,
  id: number, payload: Uint8Array): void {
  if (receiver === 0x92 && set === 0x23 && id === 0x15 && payload.length === 0) return;
  if (receiver === 0x17 && set === 3 && id === 0xf9 && bytesEqual(payload, nativeSelection(kind))) return;
  if (receiver === 0x92 && set === 0x23 && id === 0x13 && bytesEqual(payload, nativeStart(kind))) return;
  if (kind === 'circle' && receiver === 0x92 && set === 3) {
    if (id === 0xf8 && bytesEqual(payload, RADIUS_HASH_BYTES)) return;
    if (id === 0xf9 && payload.length === 8) {
      const radius = new DataView(payload.buffer, payload.byteOffset, payload.byteLength).getFloat32(4, true);
      if (bytesEqual(payload, radiusPayload(radius))) return;
    }
  }
  if (kind === 'dolly' && receiver === 0x92 && set === 3 && id === 0xf9) {
    const frames: DollyFraming[] = ['半身', '全身', '远景'];
    for (let i = 0; i < frames.length; i++) for (let zoom = 2; zoom <= 3; zoom++) {
      if (dollyParameterWrites(frames[i], zoom, false).concat(dollyParameterWrites(frames[i], zoom, true))
        .some((item: Uint8Array) => bytesEqual(item, payload))) return;
    }
  }
  throw new Error('请求不在抓包验证的原生任务范围内');
}
