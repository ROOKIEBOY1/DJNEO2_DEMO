import { concatBytes, fromHex, writeU16LE } from './Bytes';
import { encodeDumlFrame } from './DumlCodec';

const NEUTRAL_PAYLOAD: Uint8Array = fromHex('010d0000042000010840000200000655010456080000000000000000');

// The shorter variant the capture sends first after the handshake, before full stick frames.
// Python reference: initial_010a.INITIAL_PAYLOAD (mode='short' phase, prepare_seconds).
export const INITIAL_PAYLOAD: Uint8Array = fromHex('010d00000420000108400002000006550104');

export type MovementDirection = 'forward' | 'backward' | 'up' | 'down' | 'left' | 'right' |
  'turn_left' | 'turn_right';

export interface StickAxes {
  roll: number;
  pitch: number;
  throttle: number;
  yaw: number;
}

export function axesForMovement(direction: MovementDirection): StickAxes {
  const axes: StickAxes = { roll: 1024, pitch: 1024, throttle: 1024, yaw: 1024 };
  switch (direction) {
    case 'forward': axes.pitch = 1359; break;
    case 'backward': axes.pitch = 689; break;
    case 'up': axes.throttle = 1359; break;
    case 'down': axes.throttle = 689; break;
    case 'left': axes.roll = 689; break;
    case 'right': axes.roll = 1359; break;
    case 'turn_left': axes.yaw = 689; break;
    case 'turn_right': axes.yaw = 1359; break;
  }
  return axes;
}

export function buildStickPayload(roll: number, pitch: number, throttle: number, yaw: number,
  counter: number): Uint8Array {
  const channels: number[] = [roll, pitch, throttle, yaw];
  if (channels.some((value: number) => !Number.isInteger(value) || value < 364 || value > 1684)) {
    throw new Error('Channel outside observed range');
  }
  if (!Number.isInteger(counter) || counter < 0 || counter > 0xffffff) {
    throw new Error('Invalid stick counter');
  }
  const payload = new Uint8Array(NEUTRAL_PAYLOAD);
  channels.forEach((value: number, channel: number) => {
    const startBit = 24 + 11 * channel;
    for (let bit = 0; bit < 11; bit++) {
      const absolute = startBit + bit;
      const byteIndex = Math.floor(absolute / 8);
      const bitIndex = absolute % 8;
      const mask = 1 << bitIndex;
      if ((value & (1 << bit)) !== 0) {
        payload[byteIndex] |= mask;
      } else {
        payload[byteIndex] &= ~mask;
      }
    }
  });
  payload[20] = counter & 0xff;
  payload[21] = Math.floor(counter / 0x100) & 0xff;
  payload[22] = Math.floor(counter / 0x10000) & 0xff;
  return payload;
}

export function buildStickPacket(session: number, videoSeed: number, videoAcknowledgement: number,
  sequence: number, counter: number, axes: StickAxes, videoWord?: number): Uint8Array {
  const word = videoWord === undefined ? videoSeed : videoWord;
  [session, videoSeed, videoAcknowledgement, sequence, word].forEach((value: number, index: number) => {
    if (!Number.isInteger(value) || value < (index === 0 ? 1 : 0) || value > 0xffff) {
      throw new Error('Invalid stick packet header field');
    }
  });
  const frame = encodeDumlFrame(2, 0xa9, sequence, 0, 1, 0x0a,
    buildStickPayload(axes.roll, axes.pitch, axes.throttle, axes.yaw, counter));
  const prefix = new Uint8Array(18);
  writeU16LE(prefix, 0, word);
  writeU16LE(prefix, 2, word);
  writeU16LE(prefix, 8, videoSeed);
  writeU16LE(prefix, 10, videoSeed);
  writeU16LE(prefix, 16, frame.length);
  const body = concatBytes(prefix, frame);
  const header = new Uint8Array(16);
  writeU16LE(header, 0, 0x8000 | (16 + body.length));
  writeU16LE(header, 2, session);
  header[6] = 4;
  writeU16LE(header, 8, videoAcknowledgement);
  writeU16LE(header, 10, videoAcknowledgement);
  for (let index = 0; index < 7; index++) {
    header[7] ^= header[index];
  }
  return concatBytes(header, body);
}

export function validateMovementDuration(seconds: number): void {
  if (!Number.isFinite(seconds) || seconds <= 0 || seconds > 10) {
    throw new Error('Movement duration must be greater than 0 and no more than 10 seconds');
  }
}
