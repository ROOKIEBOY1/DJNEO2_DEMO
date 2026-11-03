import { fromHex } from './Bytes';
import { encodeDumlFrame } from './DumlCodec';

export const RADIUS_HASH_BYTES: Uint8Array = fromHex('46932703');
export const CIRCLE_START_PAYLOAD: Uint8Array = fromHex('010500');
export const CIRCLE_SELECTION_PAYLOAD: Uint8Array = fromHex('878867a305000000');

export function validateCircleRadius(radiusMeters: number): number {
  if (!Number.isFinite(radiusMeters) || radiusMeters < 2 || radiusMeters > 10) {
    throw new Error('Circle radius must be between 2 and 10 meters');
  }
  return radiusMeters;
}

export function radiusPayload(radiusMeters: number): Uint8Array {
  const result = new Uint8Array(8);
  result.set(RADIUS_HASH_BYTES, 0);
  new DataView(result.buffer).setFloat32(4, validateCircleRadius(radiusMeters), true);
  return result;
}

export function buildRadiusFrame(radiusMeters: number, sequence: number): Uint8Array {
  return encodeDumlFrame(2, 0x92, sequence, 0x40, 3, 0xf9, radiusPayload(radiusMeters));
}

export function buildCircleStartFrame(sequence: number): Uint8Array {
  return encodeDumlFrame(2, 0x92, sequence, 0x40, 0x23, 0x13, CIRCLE_START_PAYLOAD);
}

export function buildCircleStopFrame(sequence: number): Uint8Array {
  return encodeDumlFrame(2, 0x92, sequence, 0x40, 0x23, 0x15, new Uint8Array(0));
}

export function buildCircleSelectionFrame(sequence: number): Uint8Array {
  return encodeDumlFrame(2, 0x17, sequence, 0x40, 3, 0xf9, CIRCLE_SELECTION_PAYLOAD);
}

export function parseRadiusValue(payload: Uint8Array): number {
  if (payload.length < 9 || payload[0] !== 0) {
    throw new Error('Not a successful radius-first parameter reply');
  }
  for (let index = 0; index < RADIUS_HASH_BYTES.length; index++) {
    if (payload[index + 1] !== RADIUS_HASH_BYTES[index]) {
      throw new Error('Not a successful radius-first parameter reply');
    }
  }
  const value = new DataView(payload.buffer, payload.byteOffset, payload.byteLength).getFloat32(5, true);
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error('Invalid radius value');
  }
  return value;
}
