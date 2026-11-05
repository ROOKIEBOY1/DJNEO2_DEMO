import { bytesEqual, concatBytes, toHex } from '../protocol/Bytes';
import { buildCameraTime, PHOTO_CONTEXT_PAYLOAD, PHOTO_MODE, validateCameraRequest,
  VIDEO_MODE } from '../protocol/CameraCodec';
import { MediaEntry } from '../media/MediaDirectory';
import { MediaRepository } from '../media/MediaRepository';
import { MediaDownloadResult } from '../media/MediaDownloader';
import { MediaKind } from '../media/MediaDirectory';
import { CancellationToken, ErrorLayer, failure, OperationResult, success } from './OperationResult';
import { DroneSession } from './DroneSession';
import { TelemetrySnapshot } from './TelemetryStore';
import { hilog } from '@kit.PerformanceAnalysisKit';

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
  private recordingObservedAtMs?: number;
  private recordingIdleSinceMs?: number;

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
    this.recordingObservedAtMs = undefined;
    this.recordingIdleSinceMs = undefined;
  }

  observeTelemetry(telemetry: TelemetrySnapshot): void {
    const camera = telemetry.camera;
    if (!this.recordingRequested || this.recordingAttemptAtMs === undefined) return;
    if (camera === undefined || (telemetry.cameraAgeMs ?? Infinity) > 1000 ||
      camera.observedAtMs < this.recordingAttemptAtMs) {
      this.recordingIdleSinceMs = undefined;
      return;
    }
    if (camera.recordingCandidate) {
      this.recordingObservedAtMs = camera.observedAtMs;
      this.recordingIdleSinceMs = undefined;
    } else if (this.recordingObservedAtMs !== undefined && camera.observedAtMs > this.recordingObservedAtMs) {
      this.recordingIdleSinceMs = this.recordingIdleSinceMs ?? camera.observedAtMs;
      if (!this.operationActive && camera.observedAtMs - this.recordingIdleSinceMs >= 500) {
        this.releaseRecordingLock('已观察到本次录像结束并保持空闲');
      }
    }
  }

  resetAfterGroundedCycle(): void {
    const telemetry = this.session.snapshot().telemetry;
    const camera = telemetry.camera;
    const flight = telemetry.flight;
    if (!this.recordingRequested || this.operationActive || this.recordingAttemptAtMs === undefined ||
      (telemetry.cameraAgeMs ?? Infinity) > 1000 || (telemetry.flightAgeMs ?? Infinity) > 1000 ||
      camera === undefined || flight === undefined || camera.recordingCandidate !== false ||
      flight.airborne !== false || flight.motorsOn !== false || flight.observedAtMs < this.recordingAttemptAtMs ||
      camera.observedAtMs < this.recordingAttemptAtMs + 1500) return;
    this.releaseRecordingLock('重飞前已确认落地停桨及相机空闲');
  }

  private releaseRecordingLock(reason: string): void {
    this.recordingRequested = false;
    this.recordingObservedAtMs = undefined; this.recordingIdleSinceMs = undefined;
    hilog.info(0, 'NeoCamera', '%{public}s，本地录像锁已释放', reason);
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
      await this.waitCameraMode(1, sentAt, token);
      return success('录像模式已观察确认');
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
        return success(toHex(reply as Uint8Array));
      }
      return failure(ErrorLayer.COMMAND, 'CAMERA_STOP_UNCONFIRMED',
        `停止录像未获成功回复：${replyDescription(reply)}`);
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
    let triggerSent = false;
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
        const contextSentAt = Date.now();
        const contextReply = await this.session.requestNative(0x17, 3, 0xf9, PHOTO_CONTEXT_PAYLOAD, 2000, token);
        if (contextReply === undefined || !bytesEqual(contextReply,
          concatBytes(new Uint8Array([0]), PHOTO_CONTEXT_PAYLOAD))) {
          return failure(ErrorLayer.COMMAND, 'PHOTO_CONTEXT_FAILED',
            `Photo context reply was ${replyDescription(contextReply)}; expected 0x00${toHex(PHOTO_CONTEXT_PAYLOAD)}`);
        }
        await this.waitPhotoContext(contextSentAt, token);
      }
      this.requireIdle();
      const mode = recording ? VIDEO_MODE : PHOTO_MODE;
      validateCameraRequest(0xff, mode);
      this.ensureNotCancelled(token);
      const modeSentAt = Date.now();
      const modeReply = await this.session.requestNative(1, 2, 0xff, mode, 2000, token);
      if (!successReply(modeReply)) {
        return failure(ErrorLayer.COMMAND, 'CAMERA_MODE_FAILED',
          `Camera mode reply was ${replyDescription(modeReply)}; capture command was not sent`);
      }
      await this.waitCameraMode(recording ? 1 : 0, modeSentAt, token);
      this.requireIdle();
      this.ensureNotCancelled(token);
      if (recording) {
        this.recordingRequested = true;
        this.recordingAttemptAtMs = Date.now();
        this.recordingObservedAtMs = undefined;
        this.recordingIdleSinceMs = undefined;
      }
      const trigger = new Uint8Array([1]);
      const command = recording ? 2 : 1;
      validateCameraRequest(command, trigger);
      triggerSent = true;
      const reply = await this.session.requestNative(1, 2, command, trigger, 2000, token);
      if (!successReply(reply)) {
        const rejected = reply !== undefined;
        if (recording && rejected) this.recordingRequested = false;
        return failure(ErrorLayer.COMMAND, rejected ? 'CAMERA_CAPTURE_REJECTED' : 'CAMERA_CAPTURE_UNCONFIRMED',
          `拍摄请求未获成功回复（${replyDescription(reply)}），请核对飞机相机状态`);
      }
      return success(recording ? '飞机已确认录像启动请求' : '飞机已确认拍照请求');
    } catch (error) {
      return failure(ErrorLayer.TASK, triggerSent ? 'CAMERA_CAPTURE_UNCONFIRMED' : 'CAMERA_CAPTURE_FAILED', errorMessage(error));
    } finally {
      this.operationActive = false;
    }
  }

  private async waitPhotoContext(sentAt: number, token?: CancellationToken): Promise<void> {
    const deadline = Date.now() + 2500;
    while (Date.now() < deadline) {
      this.ensureNotCancelled(token); this.ensureFresh(); this.requireIdle();
      const telemetry = this.session.snapshot().telemetry;
      const flight = telemetry.flight;
      const settledFlight = (telemetry.flightAgeMs ?? Infinity) <= 1000 && flight !== undefined &&
        ((!flight.airborne && !flight.motorsOn) || (flight.airborne && flight.motorsOn && flight.modeRaw === 6));
      const task = telemetry.task;
      const idleOrPhotoTask = task !== undefined &&
        ((task.phaseRaw === 0 && task.modeRaw === 0) || ([0, 5].includes(task.phaseRaw) && task.modeRaw === 9));
      if (settledFlight && (telemetry.taskAgeMs ?? Infinity) <= 1000 && telemetry.task !== undefined &&
        telemetry.task.observedAtMs >= sentAt && idleOrPhotoTask &&
        telemetry.camera !== undefined && telemetry.camera.observedAtMs >= sentAt) {
        hilog.info(0, 'NeoCamera', '拍照上下文已观察确认，任务 %{public}s', telemetry.task.payloadHex);
        return;
      }
      await delay(50);
    }
    const telemetry = this.session.snapshot().telemetry;
    throw new Error(`尚未观察到拍照上下文就绪，未切换相机模式（飞行 ${telemetry.flight?.modeRaw}，任务 ${telemetry.task?.payloadHex}，相机模式 ${telemetry.camera?.modeRaw}）`);
  }

  private async waitCameraMode(mode: number, sentAt: number, token?: CancellationToken): Promise<void> {
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      this.ensureNotCancelled(token); this.ensureFresh(); this.requireIdle();
      const camera = this.session.snapshot().telemetry.camera;
      if (camera !== undefined && camera.observedAtMs >= sentAt && camera.modeRaw === mode && camera.timeSynchronized) return;
      await delay(50);
    }
    throw new Error('尚未观察到新的相机模式状态，未发送拍摄指令');
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
    const task = telemetry.task;
    const taskFresh = task !== undefined && (telemetry.taskAgeMs ?? Infinity) <= 1000;
    const idleOrManual = taskFresh && task !== undefined &&
      ((task.phaseRaw === 0 && task.modeRaw === 0) || (task.modeRaw === 9 && [0, 5].includes(task.phaseRaw)));
    const manualHover = flight.motorsOn && flight.airborne && flight.modeRaw === 6 && idleOrManual;
    const trackedHover = flight.motorsOn && flight.airborne && flight.modeRaw === 26 &&
      taskFresh && task?.phaseRaw === 0 && task.modeRaw === 0 && telemetry.subject?.tracking === true;
    if (!grounded && !manualHover && !trackedHover) {
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
