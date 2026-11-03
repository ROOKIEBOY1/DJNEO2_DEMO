import { concatBytes, fromHex, readU16LE, writeU16LE } from './Bytes';
import { decodeDumlFrame, encodeDumlFrame, validDumlFrames } from './DumlCodec';
import { OuterPacket, parseOuterPacket } from './OuterCodec';

export const OBSERVED_TRAILER_PREFIX: Uint8Array = fromHex('8e338dbb02');
export const TRAILER_SUFFIX: Uint8Array = fromHex('0000ffffffff018200000000000000');

export function buildTunnelCommand(commandSet: number, commandId: number, payload: Uint8Array,
  innerSequence: number, outerSequence: number, trailerPrefix: Uint8Array = OBSERVED_TRAILER_PREFIX): Uint8Array {
  return buildTunneledRequest(3, commandSet, commandId, payload, innerSequence, outerSequence, trailerPrefix);
}

export function buildTunneledRequest(receiver: number, commandSet: number, commandId: number,
  payload: Uint8Array, innerSequence: number, outerSequence: number,
  trailerPrefix: Uint8Array = OBSERVED_TRAILER_PREFIX): Uint8Array {
  if (!isU16(innerSequence) || !isU16(outerSequence) || trailerPrefix.length !== 5) {
    throw new Error('Invalid sequence or routing trailer prefix');
  }
  const inner = encodeDumlFrame(2, receiver, innerSequence, 0x40, commandSet, commandId, payload);
  const outerSequenceBytes = new Uint8Array(2);
  writeU16LE(outerSequenceBytes, 0, outerSequence);
  const trailer = concatBytes(trailerPrefix, outerSequenceBytes, TRAILER_SUFFIX);
  return encodeDumlFrame(0x3b, 0xe9, outerSequence, 0, 0x51, 1, concatBytes(inner, trailer));
}

export function buildFlyTunnel(parameter: number, innerSequence: number, outerSequence: number,
  trailerPrefix: Uint8Array = OBSERVED_TRAILER_PREFIX): Uint8Array {
  if (!Number.isInteger(parameter) || parameter < 0 || parameter > 0xff) {
    throw new Error('Invalid flight command parameter');
  }
  return buildTunnelCommand(3, 0x2a, new Uint8Array([parameter]), innerSequence, outerSequence, trailerPrefix);
}

export function wrapChannel4Command(session: number, videoSeed: number, videoAcknowledgement: number,
  videoWord: number, frame: Uint8Array): Uint8Array {
  [session, videoSeed, videoAcknowledgement, videoWord].forEach((value: number, index: number) => {
    if (!isU16(value) || (index === 0 && value === 0)) {
      throw new Error('Invalid session, sequence or video field');
    }
  });
  const bodyPrefix = new Uint8Array(18);
  writeU16LE(bodyPrefix, 0, videoWord);
  writeU16LE(bodyPrefix, 2, videoWord);
  writeU16LE(bodyPrefix, 8, videoSeed);
  writeU16LE(bodyPrefix, 10, videoSeed);
  writeU16LE(bodyPrefix, 16, frame.length);
  const body = concatBytes(bodyPrefix, frame);
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

export function buildFlyPacket(session: number, videoSeed: number, videoAcknowledgement: number,
  videoWord: number, outerSequence: number, innerSequence: number, parameter: number): Uint8Array {
  if (parameter !== 1 && parameter !== 2) {
    throw new Error('Only captured takeoff and landing parameters are supported');
  }
  return wrapChannel4Command(session, videoSeed, videoAcknowledgement, videoWord,
    buildFlyTunnel(parameter, innerSequence, outerSequence));
}

export function findCommandReply(raw: Uint8Array, session: number, innerSequence: number,
  commandSet: number, commandId: number, sender: number = 3): Uint8Array | undefined {
  let outer: OuterPacket;
  try {
    outer = parseOuterPacket(raw);
  } catch (_) {
    return undefined;
  }
  if (outer.session !== session || outer.channel !== 1 || raw.length < 34) {
    return undefined;
  }
  const tunnels = validDumlFrames(raw.slice(34));
  for (let tunnelIndex = 0; tunnelIndex < tunnels.length; tunnelIndex++) {
    const tunnel = tunnels[tunnelIndex];
    let frames: Uint8Array[] = [tunnel];
    if (tunnel[4] === 0x27 && tunnel[5] === 0xee && tunnel[9] === 0x51 && tunnel[10] === 1) {
      frames = validDumlFrames(tunnel.slice(11, tunnel.length - 2));
    }
    for (let frameIndex = 0; frameIndex < frames.length; frameIndex++) {
      const frame = decodeDumlFrame(frames[frameIndex]);
      if (frame.sender === sender && frame.receiver === 2 && (frame.flags & 0x80) !== 0 &&
        frame.commandSet === commandSet && frame.commandId === commandId && frame.sequence === innerSequence) {
        return frame.payload;
      }
    }
  }
  return undefined;
}

export function allDumlMessages(raw: Uint8Array): Uint8Array[] {
  if (raw.length < 20 || (raw[6] !== 1 && raw[6] !== 4 && raw[6] !== 5)) {
    return [];
  }
  const offset = raw[6] === 5 ? 20 : 34;
  const result: Uint8Array[] = [];
  validDumlFrames(raw.slice(offset)).forEach((frame: Uint8Array) => {
    if (((frame[4] === 0x3b && frame[5] === 0xe9) || (frame[4] === 0x27 && frame[5] === 0xee)) &&
      frame[9] === 0x51 && frame[10] === 1) {
      result.push(...validDumlFrames(frame.slice(11, frame.length - 2)));
    } else {
      result.push(frame);
    }
  });
  return result;
}

function isU16(value: number): boolean {
  return Number.isInteger(value) && value >= 0 && value <= 0xffff;
}
