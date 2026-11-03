import { fileIo } from '@kit.CoreFileKit';
import { OBSERVED_TRAILER_PREFIX } from '../protocol/CommandCodec';
import { bytesEqual, fromHex, readU32LE, writeU16LE, writeU32LE } from '../protocol/Bytes';
import { reflectedCrc, validDumlFrames } from '../protocol/DumlCodec';

interface RoutingState {
  version: number;
  next_counter: number;
  routing_identity: string;
}

export interface RoutingSequenceSnapshot {
  first: number;
  next: number;
  reservedUntil: number;
  persistent: boolean;
}

export class RoutingSequenceStore {
  private static active: boolean = false;
  private readonly path: string;
  private readonly routingIdentity: string;
  private readonly reservationSize: number;
  private cursor: number = 0;
  private end: number = 0;
  private firstValue: number = 0;
  private openValue: boolean = false;

  constructor(filesDirectory: string, routingIdentity: string, reservationSize: number = 64) {
    if (!Number.isInteger(reservationSize) || reservationSize < 1 || reservationSize > 4096) {
      throw new Error('Invalid routing reservation size');
    }
    if (!/^[0-9a-f]{8}$/.test(routingIdentity)) {
      throw new Error('Invalid routing identity');
    }
    if (!fileIo.accessSync(filesDirectory)) fileIo.mkdirSync(filesDirectory, true);
    this.path = `${filesDirectory}/routing-sequence.json`;
    this.routingIdentity = routingIdentity;
    this.reservationSize = reservationSize;
  }

  importState(jsonText: string): void {
    if (this.openValue || RoutingSequenceStore.active) {
      throw new Error('Cannot import routing state while a control session is active');
    }
    const state = parseState(jsonText, this.routingIdentity);
    this.persist(state.next_counter);
  }

  open(): void {
    if (this.openValue || RoutingSequenceStore.active) {
      throw new Error('Another aircraft control session is already active');
    }
    if (!fileIo.accessSync(this.path)) {
      throw new Error('Import the latest routing sequence state before connecting');
    }
    const state = parseState(fileIo.readTextSync(this.path), this.routingIdentity);
    RoutingSequenceStore.active = true;
    this.openValue = true;
    this.firstValue = state.next_counter;
    try {
      this.reserve(state.next_counter);
    } catch (error) {
      this.close();
      throw new Error(error instanceof Error ? error.message : String(error));
    }
  }

  next(): number {
    if (!this.openValue) {
      throw new Error('Routing sequence store is closed');
    }
    if (this.cursor >= this.end) {
      this.reserve(this.end);
    }
    const value = this.cursor;
    this.cursor++;
    return value;
  }

  snapshot(): RoutingSequenceSnapshot {
    return {
      first: this.firstValue,
      next: this.cursor,
      reservedUntil: this.end,
      persistent: this.openValue
    };
  }

  close(): void {
    if (this.openValue) {
      this.openValue = false;
      RoutingSequenceStore.active = false;
    }
  }

  private reserve(start: number): void {
    validateCounter(start);
    const end = Math.min(start + this.reservationSize, 0x100000000);
    this.persist(end);
    this.cursor = start;
    this.end = end;
  }

  private persist(nextCounter: number): void {
    if (!Number.isInteger(nextCounter) || nextCounter < 1 || nextCounter > 0x100000000) {
      throw new Error('Routing counter exhausted or invalid');
    }
    const temporary = `${this.path}.tmp`;
    const state: RoutingState = {
      version: 1,
      next_counter: nextCounter,
      routing_identity: this.routingIdentity
    };
    const file = fileIo.openSync(temporary,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, JSON.stringify(state));
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
    fileIo.renameSync(temporary, this.path);
  }
}

export function resequenceTunnels(payload: Uint8Array, nextCounter: () => number): Uint8Array {
  const frames = validDumlFrames(payload);
  let totalLength = 0;
  frames.forEach((frame: Uint8Array) => totalLength += frame.length);
  if (totalLength !== payload.length) {
    throw new Error('Routing requires complete validated DUML frames');
  }
  const result = new Uint8Array(payload.length);
  let offset = 0;
  frames.forEach((frame: Uint8Array) => {
    let updated = new Uint8Array(frame);
    if (frame[4] === 0x3b && frame[5] === 0xe9 && frame[9] === 0x51 && frame[10] === 1) {
      if (frame.length < 37 || !bytesEqual(frame.slice(frame.length - 24, frame.length - 19),
        OBSERVED_TRAILER_PREFIX)) {
        throw new Error('Unexpected application routing trailer');
      }
      const counter = nextCounter();
      validateCounter(counter);
      writeU16LE(updated, 6, counter & 0xffff);
      writeU32LE(updated, updated.length - 19, counter);
      writeU16LE(updated, updated.length - 2,
        reflectedCrc(updated.slice(0, updated.length - 2), 0x3692, 0x8408));
    }
    result.set(updated, offset);
    offset += updated.length;
  });
  return result;
}

export function validateRoutingState(jsonText: string, routingIdentity: string): number {
  return parseState(jsonText, routingIdentity).next_counter;
}

function parseState(jsonText: string, routingIdentity: string): RoutingState {
  const parsed = JSON.parse(jsonText) as RoutingState;
  if (parsed.version !== 1 || parsed.routing_identity !== routingIdentity) {
    throw new Error('Routing state identity or version does not match this aircraft profile');
  }
  validateCounter(parsed.next_counter);
  return parsed;
}

function validateCounter(value: number): void {
  if (!Number.isInteger(value) || value < 1 || value > 0xffffffff) {
    throw new Error('Routing counter exhausted or invalid');
  }
}
