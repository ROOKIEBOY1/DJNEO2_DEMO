import { readU16LE } from './Bytes';

export interface OuterPacket {
  session: number;
  channel: number;
  headerLength: number;
  body: Uint8Array;
  sequence: number;
}

export function parseOuterPacket(packet: Uint8Array): OuterPacket {
  if (packet.length < 8) {
    throw new Error('Outer packet shorter than the common header');
  }
  const length = readU16LE(packet, 0);
  if ((length & 0x8000) === 0 || (length & 0x7fff) !== packet.length) {
    throw new Error('Outer packet length mismatch');
  }
  let checksum = 0;
  for (let index = 0; index < 7; index++) {
    checksum ^= packet[index];
  }
  if (checksum !== packet[7]) {
    throw new Error('Outer packet XOR mismatch');
  }
  const headerLength = packet.length >= 16 ? 16 : 8;
  return {
    session: readU16LE(packet, 2),
    channel: packet[6],
    headerLength: headerLength,
    body: new Uint8Array(packet.slice(headerLength)),
    sequence: readU16LE(packet, 4)
  };
}

export function buildOuterHeader(session: number, channel: number, length: number,
  sequence: number = 0): Uint8Array {
  if (session < 1 || session > 0xffff || length < 8 || length > 0x7fff) {
    throw new Error('Invalid outer header fields');
  }
  const result = new Uint8Array(16);
  result[0] = (0x8000 | length) & 0xff;
  result[1] = (0x8000 | length) >>> 8;
  result[2] = session & 0xff;
  result[3] = session >>> 8;
  result[4] = sequence & 0xff;
  result[5] = sequence >>> 8;
  result[6] = channel;
  for (let index = 0; index < 7; index++) {
    result[7] ^= result[index];
  }
  return result;
}
