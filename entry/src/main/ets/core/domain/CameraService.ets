import { bytesEqual, concatBytes, toHex } from '../protocol/Bytes';
import { buildCameraTime, PHOTO_CONTEXT_PAYLOAD, PHOTO_MODE, validateCameraRequest,
  VIDEO_MODE } from '../protocol/CameraCodec';
import { MediaEntry } from '../media/MediaDirectory';
import { MediaRepository } from '../media/MediaRepository';
import { MediaDownloadResult } from '../media/MediaDownloader';
import { MediaKind } from '../media/MediaDirectory';
import { CancellationToken, ErrorLayer, failure, OperationResult, success } from './OperationResult';
import { DroneSession } from './DroneSession';

export interface CameraSnapshot {
  operationActive: boolean;
  recordingRequested: boolean;
  recordingAttemptAtMs?: number;
}

export class CameraService {
  private readonly session: DroneSession;
  private readonly media: MediaRepository;
  private operationActive: boolean = false;
  private recordingRequested: boolean = false;
  private recordingAttemptAtMs?: number;

  constructor(session: DroneSession, media: MediaRepository) {
    this.session = session;
    this.media = media;
  }

  snapshot(): CameraSnapshot {
    return {
      operationActive: this.operationActive,
      recordingRequested: this.recordingRequested,
      recordingAttemptAtMs: this.recordingAttemptAtMs
    };
  }

  resetForAircraftSession(): void {
    this.operationActive = false;
    this.recordingRequested = false;
    this.recordingAttemptAtMs = undefined;
  }

  async shoot(token?: CancellationToken): Promise<OperationResult<string>> {
    return this.capture(false, token);
  }

  async startRecording(token?: CancellationToken): Promise<OperationResult<string>> {
    return this.capture(true, token);
  }

  async prepareVideoMode(token?: CancellationToken): Promise<OperationResult<string>> {
    if (this.operationActive) return failure(ErrorLayer.TASK, 'CAMERA_BUSY', '相机正在处理其他操作');
    this.operationActive = true;
    try {
      this.ensureNotCancelled(token); this.ensureFresh(); this.requireIdle();
      if (this.session.snapshot().telemetry.camera?.timeSynchronized !== true) {
        const synced = await this.synchronizeClock(token);
        if (!synced.ok) return synced;
      }
      this.ensureNotCancelled(token); this.requireIdle();
      const sentAt = Date.now();
      const reply = await this.session.requestNative(1, 2, 0xff, VIDEO_MODE, 2000, token);
      if (!successReply(reply)) throw new Error('相机录像模式设置未获成功回复');
      const deadline = Date.now() + 2000;
      while (Date.now() < deadline) {
        this.ensureNotCancelled(token); this.ensureFresh(); this.requireIdle();
        const telemetry = this.session.snapshot().telemetry;
        if (telemetry.camera !== undefined && telemetry.camera.observedAtMs >= sentAt &&
          telemetry.camera.modeRaw === 1 && telemetry.camera.timeSynchronized) return success('录像模式已观察确认');
        await delay(50);
      }
      throw new Error('未观察到新的录像模式状态，未启动任务');
    } catch (error) { return failure(ErrorLayer.TASK, 'VIDEO_MODE_NOT_OBSERVED', errorMessage(error)); }
    finally { this.operationActive = false; }
  }

  async stopRecording(): Promise<OperationResult<string>> {
    try {
      this.ensureFresh();
      const payload = new Uint8Array([0]);
      validateCameraRequest(2, payload);
      const reply = await this.session.requestNative(1, 2, 2, payload);
      if (successReply(reply)) {
        this.recordingRequested = false;
      }
      return success(reply === undefined ? 'no_reply' : toHex(reply));
    } catch (error) {
      return failure(ErrorLayer.COMMAND, 'CAMERA_STOP_FAILED', errorMessage(error));
    }
  }

  async listMedia(token?: CancellationToken): Promise<OperationResult<MediaEntry[]>> {
    return this.media.listMedia(token);
  }

  async downloadLatest(kind: MediaKind, outputDirectory: string,
    token?: CancellationToken): Promise<OperationResult<MediaDownloadResult>> {
    if (kind === 'video') {
      const camera = this.session.snapshot().telemetry.camera;
      if (this.recordingRequested || camera?.recordingCandidate !== false) {
        return failure(ErrorLayer.TASK, 'RECORDING_NOT_STOPPED',
          'Stop recording and observe fresh idle camera state before downloading video');
      }
    }
    return this.media.downloadLatest(kind, outputDirectory, token);
  }

  private async capture(recording: boolean, token?: CancellationToken): Promise<OperationResult<string>> {
    if (this.operationActive) {
      return failure(ErrorLayer.TASK, 'CAMERA_BUSY', 'Another camera operation is active');
    }
    this.operationActive = true;
    try {
      this.ensureNotCancelled(token);
      this.ensureFresh();
      this.requireIdle();
      const camera = this.session.snapshot().telemetry.camera;
      if (camera?.timeSynchronized !== true) {
        const synchronization = await this.synchronizeClock(token);
        if (!synchronization.ok) {
          return synchronization;
        }
      }
      if (!recording) {
        this.ensurePhotoContextSafe();
        this.ensureNotCancelled(token);
        const contextReply = await this.session.requestNative(0x17, 3, 0xf9, PHOTO_CONTEXT_PAYLOAD, 2000, token);
        if (contextReply === undefined || !bytesEqual(contextReply,
          concatBytes(new Uint8Array([0]), PHOTO_CONTEXT_PAYLOAD))) {
          return failure(ErrorLayer.COMMAND, 'PHOTO_CONTEXT_FAILED',
            `Photo context reply was ${replyDescription(contextReply)}; expected 0x00${toHex(PHOTO_CONTEXT_PAYLOAD)}`);
        }
      }
      this.requireIdle();
      const mode = recording ? VIDEO_MODE : PHOTO_MODE;
      validateCameraRequest(0xff, mode);
      this.ensureNotCancelled(token);
      const modeReply = await this.session.requestNative(1, 2, 0xff, mode, 2000, token);
      if (!successReply(modeReply)) {
        return failure(ErrorLayer.COMMAND, 'CAMERA_MODE_FAILED',
          `Camera mode reply was ${replyDescription(modeReply)}; capture command was not sent`);
      }
      this.requireIdle();
      this.ensureNotCancelled(token);
      if (recording) {
        this.recordingRequested = true;
        this.recordingAttemptAtMs = Date.now();
      }
      const trigger = new Uint8Array([1]);
      const command = recording ? 2 : 1;
      validateCameraRequest(command, trigger);
      const reply = await this.session.requestNative(1, 2, command, trigger, 2000, token);
      return success(reply === undefined ? 'no_reply' : toHex(reply));
    } catch (error) {
      return failure(ErrorLayer.TASK, 'CAMERA_CAPTURE_FAILED', errorMessage(error));
    } finally {
      this.operationActive = false;
    }
  }

  private async synchronizeClock(token?: CancellationToken): Promise<OperationResult<string>> {
    this.ensureNotCancelled(token);
    const sentAt = Date.now();
    const payload = buildCameraTime(sentAt);
    validateCameraRequest(0x54, payload);
    const reply = await this.session.requestNative(1, 2, 0x54, payload, 2000, token);
    if (!successReply(reply)) {
      return failure(ErrorLayer.COMMAND, 'CAMERA_TIME_FAILED', 'Camera clock request was not acknowledged');
    }
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      this.ensureNotCancelled(token);
      const snapshot = this.session.snapshot().telemetry;
      if (snapshot.camera !== undefined && snapshot.cameraAgeMs !== undefined &&
        snapshot.cameraAgeMs <= 1000 && snapshot.camera.observedAtMs >= sentAt &&
        snapshot.camera.timeSynchronized) {
        return success('00');
      }
      await delay(50);
    }
    return failure(ErrorLayer.TASK, 'CAMERA_TIME_NOT_OBSERVED',
      'Clock request replied, but synchronized camera state was not observed');
  }

  private ensureFresh(): void {
    if (!this.session.isReliableLinkFresh()) {
      throw new Error('Camera control requires a fresh verified reliable connection');
    }
  }

  private requireIdle(): void {
    const telemetry = this.session.snapshot().telemetry;
    if (this.recordingRequested || telemetry.camera === undefined || telemetry.cameraAgeMs === undefined ||
      telemetry.cameraAgeMs > 1000 || telemetry.camera.recordingCandidate) {
      throw new Error('Fresh camera idle state is required');
    }
  }

  private ensurePhotoContextSafe(): void {
    const telemetry = this.session.snapshot().telemetry;
    const flight = telemetry.flight;
    if (flight === undefined || telemetry.flightAgeMs === undefined || telemetry.flightAgeMs > 1000) {
      throw new Error('Fresh flight state is required before changing photo context');
    }
    const grounded = !flight.motorsOn && !flight.airborne;
    const manualHover = flight.motorsOn && flight.airborne && flight.modeRaw === 6 &&
      telemetry.task?.modeRaw === 9;
    if (!grounded && !manualHover) {
      throw new Error('Photo context requires grounded state or verified manual hover');
    }
  }

  private ensureNotCancelled(token?: CancellationToken): void {
    if (token?.isCancelled()) {
      throw new Error('Camera operation was cancelled');
    }
  }
}

function successReply(reply?: Uint8Array): boolean {
  return reply !== undefined && reply.length === 1 && reply[0] === 0;
}

function replyDescription(reply?: Uint8Array): string {
  return reply === undefined ? 'timeout (no matching reply)' :
    `0x${toHex(reply)} (${reply.length} byte${reply.length === 1 ? '' : 's'})`;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, milliseconds));
}

function errorMessage(error: Object): string {
  return error instanceof Error ? error.message : String(error);
}
