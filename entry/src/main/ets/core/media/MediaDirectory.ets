import { bytesEqual, fromHex, readU16LE, readU32LE } from '../protocol/Bytes';
import { validDumlFrames } from '../protocol/DumlCodec';
import { parseOuterPacket } from '../protocol/OuterCodec';

const OBSERVED_REQUEST: Uint8Array = fromHex(
  '4a002110020000000000010000402d000d0100ffffffffffffffff000100000000');

export type MediaKind = 'photo' | 'video';

export interface MediaEntry {
  name: string;
  path: string;
  timestamp: string;
  fileId: number;
  kind: MediaKind;
  size?: number;
}

export function makeDirectoryRequest(sessionId: number): Uint8Array {
  if (!Number.isInteger(sessionId) || sessionId < 1 || sessionId > 0xffff) {
    throw new Error('Invalid album session');
  }
  const result = new Uint8Array(OBSERVED_REQUEST);
  result[4] = sessionId & 0xff;
  result[5] = sessionId >>> 8;
  return result;
}

export class DirectoryStream {
  private readonly outerSession: number;
  private readonly fileSession: number;
  private readonly maximumBytes: number;
  private nextSequence: number;
  private readonly pending: Map<number, Uint8Array> = new Map();
  private buffer: Uint8Array = new Uint8Array(0);
  private readonly frames: Uint8Array[] = [];
  private receivedBytes: number = 0;
  private doneValue: boolean = false;
  private errorValue: string = '';
  private entriesValue: MediaEntry[] = [];

  constructor(outerSession: number, fileSession: number, firstSequence: number,
    maximumBytes: number = 4 * 1024 * 1024) {
    this.outerSession = outerSession;
    this.fileSession = fileSession;
    this.nextSequence = firstSequence;
    this.maximumBytes = maximumBytes;
  }

  feed(raw: Uint8Array): void {
    if (this.doneValue) {
      return;
    }
    try {
      const packet = parseOuterPacket(raw);
      if (packet.session !== this.outerSession || packet.channel !== 3) {
        return;
      }
      if (raw.length <= 20) {
        throw new Error('Empty directory stream packet');
      }
      const delta = (packet.sequence - this.nextSequence) & 0xffff;
      if (delta >= 0x8000) {
        return;
      }
      if ((delta & 7) !== 0 || delta > 8 * 127) {
        throw new Error('Directory stream sequence outside receive window');
      }
      const data = new Uint8Array(raw.slice(20));
      const old = this.pending.get(packet.sequence);
      if (old !== undefined && !bytesEqual(old, data)) {
        throw new Error('Conflicting directory stream duplicate');
      }
      this.pending.set(packet.sequence, data);
      let next = this.pending.get(this.nextSequence);
      while (next !== undefined) {
        this.pending.delete(this.nextSequence);
        this.nextSequence = (this.nextSequence + 8) & 0xffff;
        this.receivedBytes += next.length;
        if (this.receivedBytes > this.maximumBytes) {
          throw new Error('Directory exceeds size bound');
        }
        this.buffer = join([this.buffer, next]);
        this.consume();
        if (this.doneValue) {
          return;
        }
        next = this.pending.get(this.nextSequence);
      }
    } catch (error) {
      this.errorValue = error instanceof Error ? error.message : String(error);
      this.doneValue = true;
    }
  }

  isDone(): boolean {
    return this.doneValue;
  }

  error(): string {
    return this.errorValue;
  }

  entries(): MediaEntry[] {
    return this.entriesValue.slice();
  }

  private consume(): void {
    while (this.buffer.length >= 4) {
      if (this.buffer[0] !== 0x55) {
        throw new Error('Directory stream lacks DUML header');
      }
      const size = this.buffer[1] | ((this.buffer[2] & 3) << 8);
      if (size < 13) {
        throw new Error('Invalid directory DUML length');
      }
      if (this.buffer.length < size) {
        return;
      }
      const frame = new Uint8Array(this.buffer.slice(0, size));
      this.buffer = new Uint8Array(this.buffer.slice(size));
      const validated = validDumlFrames(frame);
      if (validated.length !== 1 || validated[0].length !== frame.length) {
        throw new Error('Directory DUML CRC failed');
      }
      if (frame[4] !== 0xe1 || frame[5] !== 2 || frame[8] !== 0 ||
        frame[9] !== 0 || frame[10] !== 0x27) {
        continue;
      }
      const payload = frame.slice(11, frame.length - 2);
      if (payload.length < 10) {
        throw new Error('Short directory transfer header');
      }
      if (readU16LE(payload, 4) !== this.fileSession) {
        continue;
      }
      this.frames.push(frame);
      if ((readU16LE(payload, 2) >>> 12) === 1) {
        this.entriesValue = parseDirectoryFrames(this.frames, this.fileSession);
        this.doneValue = true;
        return;
      }
    }
  }
}

export function parseDirectoryFrames(frames: Uint8Array[], sessionId: number): MediaEntry[] {
  const pieces: Map<number, Uint8Array> = new Map();
  let finalIndex: number | undefined;
  let used = 0;
  frames.forEach((frame: Uint8Array) => {
    const valid = validDumlFrames(frame);
    if (valid.length !== 1 || valid[0].length !== frame.length || frame[4] !== 0xe1 || frame[5] !== 2 ||
      frame[8] !== 0 || frame[9] !== 0 || frame[10] !== 0x27) {
      throw new Error('Unexpected or invalid album response frame');
    }
    const payload = new Uint8Array(frame.slice(11, frame.length - 2));
    if (payload.length < 10 || payload[0] !== 0x4a || payload[1] !== 1) {
      throw new Error('Invalid album response header');
    }
    const lengthFlags = readU16LE(payload, 2);
    if ((lengthFlags & 0xfff) !== payload.length || (lengthFlags >>> 12) > 1 ||
      readU16LE(payload, 4) !== sessionId) {
      throw new Error('Invalid album response length, flags, or session');
    }
    const index = readU32LE(payload, 6);
    if (index > 65535) {
      throw new Error('Unexpected album fragment sequence');
    }
    const previous = pieces.get(index);
    if (previous !== undefined && !bytesEqual(previous, payload)) {
      throw new Error('Conflicting duplicate album fragment');
    }
    if (previous === undefined) {
      pieces.set(index, payload);
      used += payload.length;
      if (used > 2_000_000) {
        throw new Error('Album response exceeds bounded cache');
      }
    }
    if ((lengthFlags >>> 12) === 1) {
      if (finalIndex !== undefined && finalIndex !== index) {
        throw new Error('Conflicting final album fragment');
      }
      finalIndex = index;
    }
  });
  if (finalIndex === undefined || pieces.size !== finalIndex + 1) {
    throw new Error('Incomplete album response');
  }
  const directoryParts: Uint8Array[] = [];
  for (let index = 0; index <= finalIndex; index++) {
    const piece = pieces.get(index);
    if (piece === undefined) {
      throw new Error('Incomplete album response');
    }
    directoryParts.push(piece.slice(10));
  }
  return listEntries(join(directoryParts));
}

export function listEntries(directory: Uint8Array): MediaEntry[] {
  if (directory.length < 8) {
    throw new Error('Truncated album directory');
  }
  const count = readU32LE(directory, 0);
  if (count > 10000) {
    throw new Error('Unreasonable album entry count');
  }
  const entries: MediaEntry[] = [];
  for (let offset = 0; offset + 31 < directory.length; offset++) {
    if (directory[offset] !== 0x0d || directory[offset + 1] !== 0x1d) {
      continue;
    }
    const name = ascii(directory.slice(offset + 2, offset + 31));
    const match = /^DJI_([0-9]{14})_([0-9]{4})_D\.(JPG|MP4)$/.exec(name);
    if (match === null) {
      continue;
    }
    const tag = offset + 31;
    if (directory[tag] !== 0x1a || tag + 6 > directory.length || directory[tag + 5] !== 1) {
      throw new Error('Missing explicit original DCIM path tag');
    }
    const length = readU32LE(directory, tag + 1);
    if (length < 6 || length > 1024 || tag + 1 + length > directory.length) {
      throw new Error('Invalid DCIM path tag length');
    }
    const pathBytes = directory.slice(tag + 6, tag + 1 + length);
    if (pathBytes.length === 0 || pathBytes[pathBytes.length - 1] !== 0) {
      throw new Error('Truncated DCIM path tag');
    }
    const stem = ascii(pathBytes.slice(0, pathBytes.length - 1));
    const extension = match[3];
    const expectedStem = `DCIM/DJI_001/${name.substring(0, name.length - 4)}`;
    if (stem !== expectedStem) {
      throw new Error('Invalid or mismatched original DCIM path');
    }
    const kind: MediaKind = extension === 'JPG' ? 'photo' : 'video';
    const entry: MediaEntry = {
      name: name,
      path: `${stem}.${extension}`,
      timestamp: match[1],
      fileId: Number.parseInt(match[2], 10),
      kind: kind
    };
    const size = observedSize(directory, offset, entry);
    if (size !== undefined) {
      entry.size = size;
    }
    entries.push(entry);
  }
  const unique = new Set(entries.map((entry: MediaEntry) => entry.path));
  if (entries.length !== count || unique.size !== count) {
    throw new Error('Album entry count mismatch or duplicate path');
  }
  entries.sort((left: MediaEntry, right: MediaEntry) => {
    const byTime = right.timestamp.localeCompare(left.timestamp);
    return byTime !== 0 ? byTime : right.fileId - left.fileId;
  });
  return entries;
}

function observedSize(directory: Uint8Array, nameOffset: number, entry: MediaEntry): number | undefined {
  const prefixOffset = nameOffset - (entry.kind === 'photo' ? 126 : 166);
  if (prefixOffset < 8 || prefixOffset + 15 > nameOffset) {
    return undefined;
  }
  if (directory[prefixOffset + 14] !== (entry.kind === 'photo' ? 0 : 3)) {
    return undefined;
  }
  const packed = readU32LE(directory, prefixOffset);
  const year = 1980 + (packed >>> 25);
  const month = (packed >>> 21) & 15;
  const day = (packed >>> 16) & 31;
  const hour = (packed >>> 11) & 31;
  const minute = (packed >>> 5) & 63;
  const second = (packed & 31) * 2;
  const stamp = entry.timestamp;
  const named = Date.UTC(Number.parseInt(stamp.substring(0, 4), 10),
    Number.parseInt(stamp.substring(4, 6), 10) - 1, Number.parseInt(stamp.substring(6, 8), 10),
    Number.parseInt(stamp.substring(8, 10), 10), Number.parseInt(stamp.substring(10, 12), 10),
    Number.parseInt(stamp.substring(12, 14), 10));
  const created = Date.UTC(year, month - 1, day, hour, minute, second);
  const size = readU32LE(directory, prefixOffset + 4);
  return Math.abs(created - named) <= 2000 && size > 0 ? size : undefined;
}

function ascii(value: Uint8Array): string {
  let result = '';
  value.forEach((byte: number) => result += String.fromCharCode(byte));
  return result;
}

function join(parts: Uint8Array[]): Uint8Array {
  let length = 0;
  parts.forEach((part: Uint8Array) => length += part.length);
  const result = new Uint8Array(length);
  let offset = 0;
  parts.forEach((part: Uint8Array) => {
    result.set(part, offset);
    offset += part.length;
  });
  return result;
}
