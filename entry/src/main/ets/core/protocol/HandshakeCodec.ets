import { bytesEqual, concatBytes, fromHex, writeU16LE } from './Bytes';
import { parseOuterPacket } from './OuterCodec';

export const DRONE_IP: string = '192.168.2.1';
export const DRONE_PORT: number = 9003;
export const HANDSHAKE_BODY: Uint8Array = fromHex(
  '140000640000019001c005140000640014006400c00514000064000101040102');
export const SHORT_REPLY_BODY: Uint8Array = fromHex('010f000505401f');

export function buildHandshake(session: number, acknowledgementWord: number): Uint8Array {
  validateU16(session, true);
  validateU16(acknowledgementWord, false);
  const header = new Uint8Array(16);
  writeU16LE(header, 0, 0x8000 | 48);
  writeU16LE(header, 2, session);
  writeU16LE(header, 8, acknowledgementWord);
  header.set(fromHex('64006400c005'), 10);
  for (let index = 0; index < 7; index++) {
    header[7] ^= header[index];
  }
  return concatBytes(header, HANDSHAKE_BODY);
}

export function buildIdlePacket(session: number, videoSeed: number): Uint8Array {
  validateU16(session, true);
  validateU16(videoSeed, false);
  const header = new Uint8Array(16);
  writeU16LE(header, 0, 0x8000 | 34);
  writeU16LE(header, 2, session);
  header[6] = 4;
  writeU16LE(header, 8, videoSeed);
  writeU16LE(header, 10, videoSeed);
  for (let index = 0; index < 7; index++) {
    header[7] ^= header[index];
  }
  const tail = new Uint8Array(18);
  writeU16LE(tail, 0, videoSeed);
  writeU16LE(tail, 2, videoSeed);
  writeU16LE(tail, 8, videoSeed);
  writeU16LE(tail, 10, videoSeed);
  return concatBytes(header, tail);
}

export function isMatchingHandshakeReply(raw: Uint8Array, session: number): boolean {
  try {
    const packet = parseOuterPacket(raw);
    return packet.session === session && packet.channel === 0 && packet.headerLength === 8 &&
      bytesEqual(packet.body, SHORT_REPLY_BODY);
  } catch (_) {
    return false;
  }
}

export function newAlignedSeed(randomValue: number): number {
  if (!Number.isFinite(randomValue) || randomValue < 0 || randomValue >= 1) {
    throw new Error('Random value must be in [0, 1)');
  }
  return (Math.floor(randomValue * 8191) + 1) * 8;
}

function validateU16(value: number, nonZero: boolean): void {
  if (!Number.isInteger(value) || value < (nonZero ? 1 : 0) || value > 0xffff) {
    throw new Error('Session or header word outside u16 range');
  }
}
