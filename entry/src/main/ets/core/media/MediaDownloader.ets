import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { image } from '@kit.ImageKit';
import { socket } from '@kit.NetworkKit';
import { DroneWifiSelection } from '../platform/DroneUdpChannel';
import { CancellationToken } from '../domain/OperationResult';
import { MediaEntry } from './MediaDirectory';
import { hilog } from '@kit.PerformanceAnalysisKit';

const HOST: string = '192.168.2.1';
const MAXIMUM_MEDIA_BYTES: number = 512 * 1024 * 1024;

interface HttpResponse {
  status: number;
  headers: Map<string, string>;
  body: Uint8Array;
}

export function interruptedMediaTransfer(message: string): Error {
  const error = new Error(message); error.name = 'NeoMediaTransferInterrupted'; return error;
}
type BoundMediaRequest = (selection: DroneWifiSelection, target: string, range: string | undefined,
  token?: CancellationToken) => Promise<HttpResponse>;

export interface MediaDownloadResult {
  path: string;
  size: number;
  sha256: string;
  etag: string;
  format: string;
}

export class MediaDownloader {
  private request: BoundMediaRequest;
  constructor(request: BoundMediaRequest = requestBound) { this.request = request; }

  private async readRange(selection: DroneWifiSelection, target: string, range: string | undefined,
    token?: CancellationToken): Promise<HttpResponse> {
    for (let attempt = 1; attempt <= 3; attempt++) {
      checkCancelled(token);
      try { return await this.request(selection, target, range, token); }
      catch (error) {
        checkCancelled(token);
        if (!(error instanceof Error) || error.name !== 'NeoMediaTransferInterrupted' || attempt === 3) {
          throw error instanceof Error ? error : new Error('媒体传输失败');
        }
        hilog.warn(0, 'NeoMedia', '媒体连接中断，重试当前范围 %{public}s 第%{public}d次', range ?? '完整照片', attempt);
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, attempt * 250));
      }
    }
    throw new Error('媒体传输重试已用尽');
  }
  async download(entry: MediaEntry, outputDirectory: string, selection: DroneWifiSelection,
    token?: CancellationToken): Promise<MediaDownloadResult> {
    validateEntry(entry);
    if (entry.kind === 'video' && entry.size === undefined) {
      throw new Error('Media size was not reliably parsed from the live directory');
    }
    const destination = nextAvailableDestination(outputDirectory, entry.name);
    const suffix = entry.kind === 'photo' ? '.jpg' : '.mp4';
    const canonicalPath = entry.path.substring(0, entry.path.length - 4) + suffix;
    const target = `/v2?storage=1&path=${canonicalPath}`;
    const intervals: number[][] = [];
    if (entry.kind === 'video') {
      const videoSize = entry.size as number;
      const step = Math.floor(videoSize / 5);
      for (let index = 0; index < 5; index++) {
        intervals.push([index * step, index < 4 ? (index + 1) * step : videoSize]);
      }
    } else {
      intervals.push([0, entry.size ?? 0]);
    }

    const chunks: Uint8Array[] = [];
    let etag = '';
    for (let index = 0; index < intervals.length; index++) {
      checkCancelled(token);
      const start = intervals[index][0];
      const end = intervals[index][1];
      const range = entry.kind === 'video' ? `bytes=${start}-${end - 1}` : undefined;
      const response = await this.readRange(selection, target, range, token);
      if (response.status !== (entry.kind === 'video' ? 206 : 200)) {
        throw new Error('Unexpected media HTTP status; redirects are not followed');
      }
      const contentLength = response.headers.get('content-length');
      const expectedLength = entry.kind === 'photo' && entry.size === undefined ? response.body.length : end - start;
      if (contentLength !== `${expectedLength}` || response.body.length !== expectedLength) {
        throw new Error('Media Content-Length mismatch');
      }
      if (entry.kind === 'video') {
        if (response.headers.get('content-range') !== `bytes ${start}-${end - 1}/${entry.size}`) {
          throw new Error('Media Content-Range mismatch');
        }
      } else if (response.headers.has('content-range')) {
        throw new Error('Unexpected Content-Range on whole JPEG');
      }
      const currentEtag = response.headers.get('etag') ?? '';
      if (!/^"[^"\r\n]+"$/.test(currentEtag)) {
        throw new Error('Missing or invalid strong media ETag');
      }
      if (etag.length > 0 && currentEtag !== etag) {
        throw new Error('Media ETag changed between ranges');
      }
      etag = currentEtag;
      chunks.push(response.body);
    }
    checkCancelled(token);
    const data = join(chunks);
    if (entry.size !== undefined && data.length !== entry.size) {
      throw new Error('Downloaded original length does not match the live directory');
    }
    const format = await validateMedia(data, entry.kind);
    const sha256 = await nativeSha256Hex(data);
    if (!fileIo.accessSync(outputDirectory)) fileIo.mkdirSync(outputDirectory, true);
    const temporary = `${destination}.part`;
    const file = fileIo.openSync(temporary,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, data.buffer);
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
    checkCancelled(token);
    if (fileIo.accessSync(destination)) {
      fileIo.unlinkSync(temporary);
      throw new Error('Destination appeared during download; refusing to overwrite it');
    }
    fileIo.renameSync(temporary, destination);
    return {
      path: destination,
      size: data.length,
      sha256: sha256,
      etag: etag,
      format: format
    };
  }
}

async function requestBound(selection: DroneWifiSelection, target: string, range: string | undefined,
  token?: CancellationToken): Promise<HttpResponse> {
  const tcp = socket.constructTCPSocketInstance();
  let headerBytes = new Uint8Array(0);
  const bodyChunks: Uint8Array[] = [];
  let bodyBytes = 0;
  let completed = false;
  let expectedTotal: number | undefined;
  let parsedHeader: ParsedHeader | undefined;
  let resolveResponse: (response: HttpResponse) => void = () => {};
  let rejectResponse: (error: Error) => void = () => {};
  const responsePromise = new Promise<HttpResponse>((resolve: (response: HttpResponse) => void,
    reject: (error: Error) => void) => {
    resolveResponse = resolve;
    rejectResponse = reject;
  });
  let timer: number | undefined;
  const clearIdleTimeout = (): void => {
    if (timer !== undefined) {
      clearTimeout(timer);
      timer = undefined;
    }
  };
  const armIdleTimeout = (): void => {
    clearIdleTimeout();
    timer = setTimeout(() => finishError(interruptedMediaTransfer('Media HTTP request timed out after 5 seconds without data')), 5000);
  };
  const finishError = (error: Error): void => {
    if (!completed) {
      completed = true;
      clearIdleTimeout();
      rejectResponse(error);
    }
  };
  armIdleTimeout();

  tcp.on('message', (info: socket.SocketMessageInfo) => {
    if (completed) {
      return;
    }
    armIdleTimeout();
    let incoming = new Uint8Array(info.message);
    try {
      if (parsedHeader === undefined) {
        headerBytes = join([headerBytes, incoming]);
        const boundary = findHeaderBoundary(headerBytes);
        if (boundary >= 0) {
          parsedHeader = parseHeader(headerBytes.slice(0, boundary));
          const lengthText = parsedHeader.headers.get('content-length');
          if (lengthText === undefined || !/^[0-9]+$/.test(lengthText)) {
            throw new Error('HTTP response has no valid Content-Length');
          }
          const length = Number.parseInt(lengthText, 10);
          if (length > MAXIMUM_MEDIA_BYTES) {
            throw new Error('HTTP body exceeds media limit');
          }
          expectedTotal = length;
          incoming = new Uint8Array(headerBytes.slice(boundary + 4));
          headerBytes = new Uint8Array(0);
        } else if (headerBytes.length > 64 * 1024) {
          throw new Error('HTTP response header exceeds size limit');
        } else {
          return;
        }
      }
      if (expectedTotal !== undefined && parsedHeader !== undefined) {
        if (incoming.length > 0) {
          bodyChunks.push(incoming);
          bodyBytes += incoming.length;
        }
        if (bodyBytes > expectedTotal) {
          throw new Error('HTTP response exceeded declared Content-Length');
        }
        if (bodyBytes === expectedTotal) {
          completed = true;
          clearIdleTimeout();
          resolveResponse({
            status: parsedHeader.status,
            headers: parsedHeader.headers,
            body: join(bodyChunks)
          });
        }
      }
    } catch (error) {
      finishError(error instanceof Error ? error : new Error(String(error)));
    }
  });
  tcp.on('error', (error: Error) => finishError(interruptedMediaTransfer(error.message)));
  tcp.on('close', () => {
    if (!completed) {
      finishError(interruptedMediaTransfer('TCP connection closed before the complete media response arrived'));
    }
  });
  try {
    checkCancelled(token);
    const local: socket.NetAddress = { address: selection.localAddress, family: 1, port: 0 };
    await tcp.bind(local);
    await selection.handle.bindSocket(tcp);
    await tcp.connect({ address: { address: HOST, family: 1, port: 80 }, timeout: 5000 });
    let request = `GET ${target} HTTP/1.1\r\nHost: ${HOST}\r\nAccept: */*\r\n` +
      'Content-Type: text/plain\r\nConnection: close\r\n';
    if (range !== undefined) {
      request += `Range: ${range}\r\n`;
    }
    request += '\r\n';
    await tcp.send({ data: request, encoding: 'UTF-8' });
    return await responsePromise;
  } finally {
    clearIdleTimeout();
    tcp.off('message');
    tcp.off('error');
    tcp.off('close');
    try {
      await tcp.close();
    } catch (_) {
    }
  }
}

interface ParsedHeader {
  status: number;
  headers: Map<string, string>;
}

function parseHeader(bytes: Uint8Array): ParsedHeader {
  const lines = ascii(bytes).split('\r\n');
  const statusMatch = /^HTTP\/1\.[01] ([0-9]{3}) /.exec(lines[0]);
  if (statusMatch === null) {
    throw new Error('Invalid HTTP status line');
  }
  const headers: Map<string, string> = new Map();
  for (let index = 1; index < lines.length; index++) {
    const separator = lines[index].indexOf(':');
    if (separator <= 0) {
      throw new Error('Invalid HTTP header');
    }
    const key = lines[index].substring(0, separator).toLowerCase();
    const value = lines[index].substring(separator + 1).trim();
    if (headers.has(key)) {
      throw new Error('Duplicate HTTP response header');
    }
    headers.set(key, value);
  }
  if (headers.has('transfer-encoding') || (headers.get('content-encoding') ?? 'identity') !== 'identity') {
    throw new Error('Encoded or chunked media response is unsupported');
  }
  return { status: Number.parseInt(statusMatch[1], 10), headers: headers };
}

function validateEntry(entry: MediaEntry): void {
  if (!/^DJI_[0-9]{14}_[0-9]{4}_D\.(JPG|MP4)$/.test(entry.name) ||
    entry.path !== `DCIM/DJI_001/${entry.name}` ||
    (entry.size !== undefined && (!Number.isInteger(entry.size) || entry.size < 1 ||
      entry.size > MAXIMUM_MEDIA_BYTES || (entry.kind === 'video' && entry.size < 5)))) {
    throw new Error('Invalid live media directory entry');
  }
}

function nextAvailableDestination(outputDirectory: string, name: string): string {
  const direct = `${outputDirectory}/${name}`;
  if (!fileIo.accessSync(direct)) {
    return direct;
  }
  const separator = name.lastIndexOf('.');
  const stem = separator > 0 ? name.substring(0, separator) : name;
  const suffix = separator > 0 ? name.substring(separator) : '';
  for (let index = 1; index <= 9999; index++) {
    const candidate = `${outputDirectory}/${stem}_${index}${suffix}`;
    if (!fileIo.accessSync(candidate)) {
      return candidate;
    }
  }
  throw new Error('No available destination name for the downloaded media');
}

async function validateMedia(data: Uint8Array, kind: string): Promise<string> {
  if (kind === 'photo') {
    let endMarker = false;
    for (let index = data.length - 2; index >= 2; index--) {
      if (data[index] === 0xff && data[index + 1] === 0xd9) {
        endMarker = true;
        break;
      }
    }
    if (data.length < 4 || data[0] !== 0xff || data[1] !== 0xd8 || !endMarker) {
      throw new Error('Invalid or truncated JPEG markers');
    }
    const source = image.createImageSource(new Uint8Array(data).buffer);
    try {
      const info = await source.getImageInfo();
      if (info.size.width < 1 || info.size.height < 1) {
        throw new Error('Image Kit returned invalid JPEG dimensions');
      }
    } catch (error) {
      throw new Error(`Image Kit rejected downloaded JPEG: ${errorMessage(error)}`);
    } finally {
      await source.release();
    }
    return 'JPEG';
  }
  let offset = 0;
  const types: Set<string> = new Set();
  while (offset < data.length) {
    if (offset + 8 > data.length) {
      throw new Error('Truncated MP4 box header');
    }
    let size = readBigU32(data, offset);
    const type = ascii(data.slice(offset + 4, offset + 8));
    let header = 8;
    if (size === 1) {
      if (offset + 16 > data.length) {
        throw new Error('Truncated MP4 extended size');
      }
      const high = readBigU32(data, offset + 8);
      const low = readBigU32(data, offset + 12);
      size = high * 0x100000000 + low;
      header = 16;
    } else if (size === 0) {
      size = data.length - offset;
    }
    if (!Number.isSafeInteger(size) || size < header || offset + size > data.length) {
      throw new Error('Truncated or invalid MP4 box');
    }
    types.add(type);
    offset += size;
  }
  if (!types.has('ftyp') || !types.has('moov') || !types.has('mdat')) {
    throw new Error('MP4 is missing ftyp, moov, or mdat');
  }
  return 'MP4';
}

async function nativeSha256Hex(data: Uint8Array): Promise<string> {
  const digest = cryptoFramework.createMd('SHA256');
  await digest.update({ data: data });
  const result = await digest.digest();
  let hex = '';
  result.data.forEach((value: number) => hex += value.toString(16).padStart(2, '0'));
  return hex;
}

function findHeaderBoundary(data: Uint8Array): number {
  for (let index = 0; index + 3 < data.length; index++) {
    if (data[index] === 13 && data[index + 1] === 10 && data[index + 2] === 13 && data[index + 3] === 10) {
      return index;
    }
  }
  return -1;
}

function readBigU32(data: Uint8Array, offset: number): number {
  return data[offset] * 0x1000000 + data[offset + 1] * 0x10000 + data[offset + 2] * 0x100 + data[offset + 3];
}

function checkCancelled(token?: CancellationToken): void {
  if (token?.isCancelled()) {
    throw new Error('Media download was cancelled');
  }
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

function errorMessage(error: Object): string {
  return error instanceof Error ? error.message : String(error);
}
