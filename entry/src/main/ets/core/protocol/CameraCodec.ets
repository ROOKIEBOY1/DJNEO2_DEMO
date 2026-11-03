import { bytesEqual, fromHex } from './Bytes';

export const PHOTO_MODE: Uint8Array = fromHex('003700010100');
export const VIDEO_MODE: Uint8Array = fromHex('003700020000');
export const PHOTO_CONTEXT_PAYLOAD: Uint8Array = fromHex('878867a309000000');

export function buildCameraTime(nowMs: number = Date.now()): Uint8Array {
  const chinaTime = new Date(nowMs + 8 * 60 * 60 * 1000);
  const result = new Uint8Array(9);
  const view = new DataView(result.buffer);
  view.setUint16(0, chinaTime.getUTCFullYear(), true);
  result[2] = chinaTime.getUTCMonth() + 1;
  result[3] = chinaTime.getUTCDate();
  result[4] = chinaTime.getUTCHours();
  result[5] = chinaTime.getUTCMinutes();
  result[6] = chinaTime.getUTCSeconds();
  view.setInt16(7, 480, true);
  return result;
}

export function validateCameraRequest(commandId: number, payload: Uint8Array): void {
  if (commandId === 0x54) {
    if (payload.length !== 9) {
      throw new Error('Camera clock payload length mismatch');
    }
    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    const year = view.getUint16(0, true);
    const month = payload[2];
    const day = payload[3];
    const hour = payload[4];
    const minute = payload[5];
    const second = payload[6];
    const offset = view.getInt16(7, true);
    if (year < 2000 || year > 2099 || month < 1 || month > 12 || day < 1 || day > 31 ||
      hour > 23 || minute > 59 || second > 59 || offset < -720 || offset > 840) {
      throw new Error('Camera date or timezone is outside bounds');
    }
    return;
  }
  const valid = (commandId === 1 && bytesEqual(payload, new Uint8Array([1]))) ||
    (commandId === 2 && (bytesEqual(payload, new Uint8Array([0])) ||
      bytesEqual(payload, new Uint8Array([1])))) ||
    (commandId === 0xff && (bytesEqual(payload, PHOTO_MODE) || bytesEqual(payload, VIDEO_MODE)));
  if (!valid) {
    throw new Error('Camera request was not observed in the owned captures');
  }
}
