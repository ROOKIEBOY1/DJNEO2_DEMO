import { concatBytes, readU16LE, writeU16LE } from './Bytes';

export interface DumlFrame {
  sender: number;
  receiver: number;
  sequence: number;
  flags: number;
  commandSet: number;
  commandId: number;
  payload: Uint8Array;
  raw: Uint8Array;
}

export function reflectedCrc(data: Uint8Array, initial: number, polynomial: number): number {
  let value = initial;
  for (let index = 0; index < data.length; index++) {
    value ^= data[index];
    for (let bit = 0; bit < 8; bit++) {
      value = (value >>> 1) ^ ((value & 1) === 1 ? polynomial : 0);
    }
  }
  return value;
}

export function encodeDumlFrame(sender: number, receiver: number, sequence: number, flags: number,
  commandSet: number, commandId: number, payload: Uint8Array): Uint8Array {
  const length = 13 + payload.length;
  if (length > 1023 || !Number.isInteger(sequence) || sequence < 0 || sequence > 0xffff) {
    throw new Error('Invalid DUML length or sequence');
  }
  const header = new Uint8Array([0x55, length & 0xff, 4 | (length >>> 8), 0,
    sender, receiver, sequence & 0xff, sequence >>> 8, flags, commandSet, commandId]);
  header[3] = reflectedCrc(header.slice(0, 3), 0x77, 0x8c);
  const withoutCrc = concatBytes(header, payload);
  const result = new Uint8Array(length);
  result.set(withoutCrc);
  writeU16LE(result, length - 2, reflectedCrc(withoutCrc, 0x3692, 0x8408));
  return result;
}

export function validDumlFrames(data: Uint8Array): Uint8Array[] {
  const frames: Uint8Array[] = [];
  let offset = 0;
  while (offset + 13 <= data.length) {
    if (data[offset] !== 0x55) {
      offset++;
      continue;
    }
    const size = data[offset + 1] | ((data[offset + 2] & 3) << 8);
    const end = offset + size;
    if (size < 13 || end > data.length) {
      offset++;
      continue;
    }
    const frame = data.slice(offset, end);
    const validHeader = reflectedCrc(frame.slice(0, 3), 0x77, 0x8c) === frame[3];
    const validBody = reflectedCrc(frame.slice(0, frame.length - 2), 0x3692, 0x8408) ===
      readU16LE(frame, frame.length - 2);
    if (!validHeader || !validBody) {
      offset++;
      continue;
    }
    frames.push(new Uint8Array(frame));
    offset = end;
  }
  return frames;
}

export function decodeDumlFrame(raw: Uint8Array): DumlFrame {
  const frames = validDumlFrames(raw);
  if (frames.length !== 1 || frames[0].length !== raw.length) {
    throw new Error('Expected one complete validated DUML frame');
  }
  return {
    sender: raw[4],
    receiver: raw[5],
    sequence: readU16LE(raw, 6),
    flags: raw[8],
    commandSet: raw[9],
    commandId: raw[10],
    payload: new Uint8Array(raw.slice(11, raw.length - 2)),
    raw: new Uint8Array(raw)
  };
}
