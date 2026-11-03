export function fromHex(hex: string): Uint8Array {
  const normalized = hex.trim().toLowerCase();
  if (normalized.length % 2 !== 0 || !/^[0-9a-f]*$/.test(normalized)) {
    throw new Error('Invalid hexadecimal string');
  }
  const result = new Uint8Array(normalized.length / 2);
  for (let index = 0; index < result.length; index++) {
    result[index] = Number.parseInt(normalized.substring(index * 2, index * 2 + 2), 16);
  }
  return result;
}

export function toHex(value: Uint8Array): string {
  let result = '';
  for (let index = 0; index < value.length; index++) {
    result += value[index].toString(16).padStart(2, '0');
  }
  return result;
}

export function concatBytes(...parts: Uint8Array[]): Uint8Array {
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

export function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
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

export function readU16LE(value: Uint8Array, offset: number): number {
  requireRange(value, offset, 2);
  return value[offset] | (value[offset + 1] << 8);
}

export function writeU16LE(value: Uint8Array, offset: number, input: number): void {
  requireUnsigned(input, 0xffff, 'u16');
  requireRange(value, offset, 2);
  value[offset] = input & 0xff;
  value[offset + 1] = Math.floor(input / 0x100) & 0xff;
}

export function readU32LE(value: Uint8Array, offset: number): number {
  requireRange(value, offset, 4);
  return value[offset] + value[offset + 1] * 0x100 + value[offset + 2] * 0x10000 +
    value[offset + 3] * 0x1000000;
}

export function writeU32LE(value: Uint8Array, offset: number, input: number): void {
  requireUnsigned(input, 0xffffffff, 'u32');
  requireRange(value, offset, 4);
  value[offset] = input & 0xff;
  value[offset + 1] = Math.floor(input / 0x100) & 0xff;
  value[offset + 2] = Math.floor(input / 0x10000) & 0xff;
  value[offset + 3] = Math.floor(input / 0x1000000) & 0xff;
}

export function sliceBytes(value: Uint8Array, start: number, end?: number): Uint8Array {
  return new Uint8Array(value.slice(start, end));
}

export function requireUnsigned(value: number, maximum: number, label: string): void {
  if (!Number.isInteger(value) || value < 0 || value > maximum) {
    throw new Error(`${label} is outside its unsigned range`);
  }
}

function requireRange(value: Uint8Array, offset: number, length: number): void {
  if (!Number.isInteger(offset) || offset < 0 || offset + length > value.length) {
    throw new Error('Byte range is outside the buffer');
  }
}
