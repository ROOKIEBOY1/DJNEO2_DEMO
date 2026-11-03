import { parseOuterPacket } from '../protocol/OuterCodec';

interface PendingFrame {
  createdAt: number;
  parts: Map<number, Uint8Array>;
}

export interface VideoAssemblerSnapshot {
  pending: number;
  droppedFrames: number;
  invalidPackets: number;
  duplicatePackets: number;
}

export class VideoAssembler {
  private readonly maximumPending: number;
  private readonly maximumAgeMs: number;
  private readonly pending: Map<string, PendingFrame> = new Map();
  private readonly completed: Map<string, number> = new Map();
  private droppedFrames: number = 0;
  private invalidPackets: number = 0;
  private duplicatePackets: number = 0;

  constructor(maximumPending: number = 32, maximumAgeMs: number = 1000) {
    this.maximumPending = maximumPending;
    this.maximumAgeMs = maximumAgeMs;
  }

  feed(raw: Uint8Array, nowMs: number): Uint8Array | undefined {
    let session = 0;
    let frame = 0;
    let count = 0;
    let part = 0;
    try {
      const outer = parseOuterPacket(raw);
      if (outer.channel !== 2 || raw.length <= 20) {
        throw new Error('Not a video packet');
      }
      session = outer.session;
      frame = raw[16];
      count = raw[17] & 0x7f;
      part = ((raw[18] & 0x1f) << 1) | (raw[17] >>> 7);
      if (count < 1 || count > 64 || part >= count) {
        throw new Error('Invalid video fragment');
      }
    } catch (_) {
      this.invalidPackets++;
      return undefined;
    }
    this.expire(nowMs);
    const key = `${session}:${frame}:${count}`;
    if (this.completed.has(key)) {
      this.duplicatePackets++;
      return undefined;
    }
    let pendingFrame = this.pending.get(key);
    if (pendingFrame === undefined) {
      pendingFrame = { createdAt: nowMs, parts: new Map() };
      this.pending.set(key, pendingFrame);
    }
    const data = new Uint8Array(raw.slice(20));
    const previous = pendingFrame.parts.get(part);
    if (previous !== undefined) {
      this.duplicatePackets++;
      if (!sameBytes(previous, data)) {
        this.pending.delete(key);
        this.completed.set(key, nowMs);
        this.droppedFrames++;
      }
      return undefined;
    }
    pendingFrame.parts.set(part, data);
    if (pendingFrame.parts.size === count) {
      this.pending.delete(key);
      this.completed.set(key, nowMs);
      const pieces: Uint8Array[] = [];
      for (let index = 0; index < count; index++) {
        const piece = pendingFrame.parts.get(index);
        if (piece === undefined) {
          this.droppedFrames++;
          return undefined;
        }
        pieces.push(piece);
      }
      this.trimCompleted();
      return join(pieces);
    }
    while (this.pending.size > this.maximumPending) {
      const oldest = this.pending.keys().next().value as string;
      this.pending.delete(oldest);
      this.droppedFrames++;
    }
    return undefined;
  }

  snapshot(): VideoAssemblerSnapshot {
    return {
      pending: this.pending.size,
      droppedFrames: this.droppedFrames,
      invalidPackets: this.invalidPackets,
      duplicatePackets: this.duplicatePackets
    };
  }

  private expire(nowMs: number): void {
    this.pending.forEach((value: PendingFrame, key: string) => {
      if (nowMs - value.createdAt > this.maximumAgeMs) {
        this.pending.delete(key);
        this.droppedFrames++;
      }
    });
    this.completed.forEach((createdAt: number, key: string) => {
      if (nowMs - createdAt > this.maximumAgeMs) {
        this.completed.delete(key);
      }
    });
  }

  private trimCompleted(): void {
    while (this.completed.size > 512) {
      const oldest = this.completed.keys().next().value as string;
      this.completed.delete(oldest);
    }
  }
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index++) {
    if (left[index] !== right[index]) {
      return false;
    }
  }
  return true;
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
