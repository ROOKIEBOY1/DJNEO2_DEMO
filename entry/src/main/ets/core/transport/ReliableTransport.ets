import { concatBytes, readU16LE, toHex, writeU16LE } from '../protocol/Bytes';
import { buildOuterHeader, parseOuterPacket } from '../protocol/OuterCodec';

interface PendingPacket {
  raw: Uint8Array;
  firstSentAt: number;
  lastSentAt: number;
  attempts: number;
}

export interface ReliableTransportSnapshot {
  sent: number;
  acknowledged: number;
  pending: number;
  retransmitted: number;
  peerAcknowledgement: string;
  downlinkAcknowledgement: string;
}

export function sequenceReached(cursor: number, sequence: number): boolean {
  return ((cursor - sequence) & 0xffff) < 0x8000;
}

export class ReliableTransport {
  private readonly session: number;
  private readonly base: number;
  private readonly retryIntervalMs: number;
  private readonly lifetimeMs: number;
  private previous: number;
  private nextSequence: number;
  private counter: number = 1;
  private videoCursor: number;
  private downlinkCursor: number;
  private peerAcknowledgement: number;
  private sentCount: number = 0;
  private acknowledgedCount: number = 0;
  private retransmittedCount: number = 0;
  private readonly pending: Map<number, PendingPacket> = new Map();
  private readonly downlinkSeen: Set<number> = new Set();

  constructor(session: number, base: number, retryIntervalMs: number = 150, lifetimeMs: number = 1000) {
    if (!Number.isInteger(session) || session < 1 || session > 0xffff ||
      !Number.isInteger(base) || base < 0 || base > 0xffff || (base & 7) !== 0) {
      throw new Error('Invalid session or aligned transport base');
    }
    this.session = session;
    this.base = base;
    this.previous = base;
    this.nextSequence = (base + 8) & 0xffff;
    this.videoCursor = base;
    this.downlinkCursor = base;
    this.peerAcknowledgement = base;
    this.retryIntervalMs = retryIntervalMs;
    this.lifetimeMs = lifetimeMs;
  }

  encode(duml: Uint8Array, nowMs: number): Uint8Array {
    if (duml.length === 0 || duml.length + 20 > 1472) {
      throw new Error('Reliable payload outside observed MTU');
    }
    if (this.pending.size >= 32) {
      throw new Error('Reliable send window is full');
    }
    const sequence = this.nextSequence;
    const header = buildOuterHeader(this.session, 5, 20 + duml.length, sequence);
    writeU16LE(header, 8, this.previous);
    writeU16LE(header, 10, sequence);
    const routing = new Uint8Array([this.counter, 1, 0, 0]);
    const raw = concatBytes(header, routing, duml);
    this.pending.set(sequence, {
      raw: new Uint8Array(raw), firstSentAt: nowMs, lastSentAt: nowMs, attempts: 1
    });
    this.previous = sequence;
    this.nextSequence = (sequence + 8) & 0xffff;
    this.counter = (this.counter + 1) & 0xff;
    this.sentCount++;
    return raw;
  }

  observe(raw: Uint8Array): void {
    const outer = parseOuterPacket(raw);
    if (outer.session !== this.session) {
      return;
    }
    if (outer.channel === 2 && sequenceReached(outer.sequence, this.videoCursor)) {
      this.videoCursor = outer.sequence;
      return;
    }
    if (outer.channel === 3) {
      const delta = (outer.sequence - this.downlinkCursor) & 0xffff;
      if (delta > 0 && delta <= 8 * 128 && (delta & 7) === 0) {
        this.downlinkSeen.add(outer.sequence);
        let next = (this.downlinkCursor + 8) & 0xffff;
        while (this.downlinkSeen.has(next)) {
          this.downlinkCursor = next;
          this.downlinkSeen.delete(next);
          next = (this.downlinkCursor + 8) & 0xffff;
        }
      }
      return;
    }
    if (outer.channel === 1 && raw.length >= 34) {
      const cursor = readU16LE(raw, 24);
      if (((cursor - this.base) & 7) === 0 && sequenceReached(cursor, this.peerAcknowledgement) &&
        sequenceReached(this.previous, cursor)) {
        this.peerAcknowledgement = cursor;
        const sequences = Array.from(this.pending.keys());
        for (let index = 0; index < sequences.length; index++) {
          const sequence = sequences[index];
          if (!sequenceReached(cursor, sequence)) {
            break;
          }
          this.pending.delete(sequence);
          this.acknowledgedCount++;
        }
      }
    }
  }

  acknowledgement(): Uint8Array {
    const header = buildOuterHeader(this.session, 4, 34);
    writeU16LE(header, 8, this.videoCursor);
    writeU16LE(header, 10, this.videoCursor);
    const body = new Uint8Array(18);
    writeU16LE(body, 0, this.downlinkCursor);
    writeU16LE(body, 2, this.downlinkCursor);
    writeU16LE(body, 8, this.previous);
    writeU16LE(body, 10, this.previous);
    return concatBytes(header, body);
  }

  retries(nowMs: number): Uint8Array[] {
    const result: Uint8Array[] = [];
    this.pending.forEach((pending: PendingPacket, sequence: number) => {
      if (nowMs - pending.firstSentAt >= this.lifetimeMs) {
        throw new Error(`Aircraft did not acknowledge transport sequence 0x${toHex(new Uint8Array([
          sequence >>> 8, sequence & 0xff]))}`);
      }
      if (nowMs - pending.lastSentAt >= this.retryIntervalMs && result.length < 8) {
        pending.lastSentAt = nowMs;
        pending.attempts++;
        this.retransmittedCount++;
        result.push(new Uint8Array(pending.raw));
      }
    });
    return result;
  }

  snapshot(): ReliableTransportSnapshot {
    return {
      sent: this.sentCount,
      acknowledged: this.acknowledgedCount,
      pending: this.pending.size,
      retransmitted: this.retransmittedCount,
      peerAcknowledgement: `0x${this.peerAcknowledgement.toString(16).padStart(4, '0')}`,
      downlinkAcknowledgement: `0x${this.downlinkCursor.toString(16).padStart(4, '0')}`
    };
  }

  videoAcknowledgement(): number {
    return this.videoCursor;
  }

  downlinkAcknowledgement(): number {
    return this.downlinkCursor;
  }
}
