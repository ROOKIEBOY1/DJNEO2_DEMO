import { axesForMovement, MovementDirection, validateMovementDuration } from '../protocol/StickCodec';
import { CancellationToken, ErrorLayer, failure, OperationResult, success } from './OperationResult';
import { DroneSession } from './DroneSession';

export interface FlightCommandSnapshot {
  takeoffSent: boolean;
  takeoffAcknowledged: boolean;
  nativeTaskMayFly: boolean;
  nativeStartedAtMs?: number;
  nativeStopConfirmedAtMs?: number;
  landRequested: boolean;
  landSent: boolean;
  landAcknowledged: boolean;
  movementActive: boolean;
  generation: number;
}

export class FlightCommandService {
  private readonly session: DroneSession;
  private takeoffSentValue: boolean = false;
  private takeoffAcknowledgedValue: boolean = false;
  private nativeTaskMayFlyValue: boolean = false;
  private nativeStartedAtValue?: number;
  private nativeStopConfirmedAtValue?: number;
  private landRequestedValue: boolean = false;
  private landSentValue: boolean = false;
  private landAcknowledgedValue: boolean = false;
  private movementActiveValue: boolean = false;
  private generationValue: number = 1;
  private activeToken: CancellationToken = new CancellationToken(1);
  private cycleEvidenceAtMs: number = 0;

  constructor(session: DroneSession) {
    this.session = session;
  }

  newCancellationToken(): CancellationToken {
    return new CancellationToken(this.generationValue);
  }

  snapshot(): FlightCommandSnapshot {
    return {
      takeoffSent: this.takeoffSentValue,
      takeoffAcknowledged: this.takeoffAcknowledgedValue,
      nativeTaskMayFly: this.nativeTaskMayFlyValue,
      nativeStartedAtMs: this.nativeStartedAtValue,
      nativeStopConfirmedAtMs: this.nativeStopConfirmedAtValue,
      landRequested: this.landRequestedValue,
      landSent: this.landSentValue,
      landAcknowledged: this.landAcknowledgedValue,
      movementActive: this.movementActiveValue,
      generation: this.generationValue
    };
  }

  resetForAircraftSession(): void {
    this.generationValue++;
    this.activeToken.cancel();
    this.activeToken = new CancellationToken(this.generationValue);
    this.takeoffSentValue = false;
    this.takeoffAcknowledgedValue = false;
    this.nativeTaskMayFlyValue = false;
    this.nativeStartedAtValue = undefined;
    this.nativeStopConfirmedAtValue = undefined;
    this.landRequestedValue = false;
    this.landSentValue = false;
    this.landAcknowledgedValue = false;
    this.movementActiveValue = false;
    this.cycleEvidenceAtMs = 0;
  }

  async takeoff(confirmed: boolean, token?: CancellationToken): Promise<OperationResult<string>> {
    if (!confirmed) {
      return failure(ErrorLayer.FLIGHT, 'TAKEOFF_CONFIRMATION_REQUIRED', 'Takeoff requires explicit confirmation');
    }
    if (this.tokenCancelled(token)) {
      return failure(ErrorLayer.TASK, 'OPERATION_CANCELLED', 'Operation was cancelled before send');
    }
    if (!this.session.isActionLinkFresh()) {
      return failure(ErrorLayer.HANDSHAKE_REGISTRATION, 'LINK_NOT_FRESH',
        'Verified device reply, downlink and video must all be fresh');
    }
    if (this.nativeTaskMayFlyValue || this.takeoffSentValue || this.landRequestedValue || this.landSentValue) {
      return failure(ErrorLayer.FLIGHT, 'FLIGHT_CYCLE_LOCKED',
        'This cycle already took off, may be controlled by a native task, or entered landing');
    }
    this.cycleEvidenceAtMs = Date.now();
    this.takeoffSentValue = true;
    try {
      const reply = await this.session.requestFlight(1);
      this.takeoffAcknowledgedValue = isSuccessReply(reply);
      if (!this.takeoffAcknowledgedValue) return failure(ErrorLayer.COMMAND, 'TAKEOFF_UNCONFIRMED',
        `起飞请求未获成功回复（${replyHex(reply)}）；飞机仍可能已起飞，请观察或降落`);
      return success(replyHex(reply));
    } catch (error) {
      return failure(ErrorLayer.COMMAND, 'TAKEOFF_SEND_FAILED', errorMessage(error));
    }
  }

  async move(direction: MovementDirection, seconds: number = 0.5,
    token?: CancellationToken): Promise<OperationResult<boolean>> {
    try {
      validateMovementDuration(seconds);
    } catch (error) {
      return failure(ErrorLayer.COMMAND, 'INVALID_MOVEMENT_DURATION', errorMessage(error), false);
    }
    if (this.movementActiveValue) {
      return failure(ErrorLayer.TASK, 'MOVEMENT_BUSY', 'Another directional movement is active');
    }
    if (this.landRequestedValue || this.landSentValue) {
      return failure(ErrorLayer.FLIGHT, 'LANDING_LOCK', 'Directional movement is locked after landing starts');
    }
    if (this.nativeTaskMayFlyValue ? !this.nativeManualControlReady() : !this.takeoffAcknowledgedValue) {
      return failure(ErrorLayer.FLIGHT, 'NOT_AIRBORNE_VERIFIED',
        'Movement requires a takeoff acknowledgement or verified post-circle hover handoff');
    }
    if (!this.session.isActionLinkFresh()) {
      return failure(ErrorLayer.NETWORK, 'LINK_NOT_FRESH', 'Aircraft downlink stopped or became stale');
    }
    if (this.tokenCancelled(token)) {
      return failure(ErrorLayer.TASK, 'OPERATION_CANCELLED', 'Operation was cancelled before send');
    }
    this.movementActiveValue = true;
    const serviceToken = this.activeToken;
    this.session.setMovementAxes(axesForMovement(direction));
    const deadline = Date.now() + seconds * 1000;
    try {
      while (Date.now() < deadline) {
        if (this.landRequestedValue || serviceToken.isCancelled() ||
          (token !== undefined && token.isCancelled()) ||
          (token !== undefined && token.generation() !== this.generationValue)) {
          return failure(ErrorLayer.TASK, 'MOVEMENT_CANCELLED', 'Movement was cancelled and sticks were centered');
        }
        if (!this.session.isActionLinkFresh()) {
          return failure(ErrorLayer.NETWORK, 'MOVEMENT_LINK_LOST',
            'Aircraft downlink stopped during movement');
        }
        await delay(Math.min(50, Math.max(1, deadline - Date.now())));
      }
      return success(true);
    } finally {
      this.movementActiveValue = false;
      await this.session.centerSticks();
    }
  }

  async centerSticks(): Promise<OperationResult<boolean>> {
    this.activeToken.cancel();
    this.activeToken = new CancellationToken(this.generationValue);
    try {
      await this.session.centerSticks();
      return success(true);
    } catch (error) {
      return failure(ErrorLayer.COMMAND, 'CENTER_FAILED', errorMessage(error));
    }
  }

  async land(): Promise<OperationResult<string>> {
    this.landRequestedValue = true;
    this.activeToken.cancel();
    try {
      await this.session.centerSticks();
    } catch (_) {
      // Landing must still be attempted when centering cannot be confirmed.
    }
    try {
      this.landSentValue = true;
      const reply = await this.session.requestFlight(2);
      this.landAcknowledgedValue = isSuccessReply(reply);
      if (!this.landAcknowledgedValue) return failure(ErrorLayer.COMMAND, 'LAND_UNCONFIRMED',
        `降落请求未获成功回复（${replyHex(reply)}）；尚未确认落地`);
      return success(replyHex(reply));
    } catch (error) {
      return failure(ErrorLayer.COMMAND, 'LAND_SEND_FAILED', errorMessage(error));
    }
  }

  prepareGroundedCycle(confirmedGrounded: boolean): OperationResult<boolean> {
    if (this.movementActiveValue || !this.session.isActionLinkFresh()) {
      return failure(ErrorLayer.FLIGHT, 'GROUND_RESET_NOT_READY', '动作尚未结束或链路不新鲜，不能重建飞行状态');
    }
    if (!confirmedGrounded) {
      return failure(ErrorLayer.FLIGHT, 'GROUND_CONFIRMATION_REQUIRED',
        'The operator must visually confirm that the aircraft is grounded', false);
    }
    const telemetry = this.session.snapshot().telemetry;
    const flight = telemetry.flight;
    if (flight === undefined || telemetry.flightAgeMs === undefined || telemetry.flightAgeMs > 1000 ||
      flight.observedAtMs < this.cycleEvidenceAtMs || flight.motorsOn || flight.airborne) {
      return failure(ErrorLayer.FLIGHT, 'GROUND_TELEMETRY_REQUIRED',
        'Fresh post-cycle motors-off and grounded telemetry has not been observed');
    }
    if (this.nativeTaskMayFlyValue) {
      const task = telemetry.task;
      const inactive = task !== undefined && task.observedAtMs >= this.cycleEvidenceAtMs &&
        ['0000000100', '0000000101', '0000000102', '0300000100'].includes(task.payloadHex);
      if (!inactive) {
        return failure(ErrorLayer.TASK, 'NATIVE_TASK_NOT_INACTIVE',
          'The prior native task has not been observed inactive');
      }
    }
    this.generationValue++;
    this.activeToken.cancel();
    this.activeToken = new CancellationToken(this.generationValue);
    this.takeoffSentValue = false;
    this.takeoffAcknowledgedValue = false;
    this.nativeTaskMayFlyValue = false;
    this.nativeStartedAtValue = undefined;
    this.nativeStopConfirmedAtValue = undefined;
    this.landRequestedValue = false;
    this.landSentValue = false;
    this.landAcknowledgedValue = false;
    this.cycleEvidenceAtMs = Date.now();
    return success(true);
  }

  markNativeTaskMayFly(startedAtMs: number): void {
    this.nativeTaskMayFlyValue = true;
    this.nativeStartedAtValue = startedAtMs;
    this.nativeStopConfirmedAtValue = undefined;
    this.cycleEvidenceAtMs = Math.max(this.cycleEvidenceAtMs, startedAtMs);
  }

  markNativeStopConfirmed(confirmedAtMs: number): void {
    this.nativeStopConfirmedAtValue = confirmedAtMs;
  }

  releaseNativeTaskAfterHover(completionObservedAtMs?: number): OperationResult<boolean> {
    if (!this.nativeTaskMayFlyValue) return success(true);
    const telemetry = this.session.snapshot().telemetry;
    const flight = telemetry.flight; const task = telemetry.task; const camera = telemetry.camera;
    const startedAt = this.nativeStartedAtValue;
    const manualAfterCompletion = startedAt !== undefined && completionObservedAtMs !== undefined &&
      completionObservedAtMs >= startedAt && task !== undefined && flight !== undefined && camera !== undefined &&
      task.modeRaw === 9 && [0, 5].includes(task.phaseRaw) && task.observedAtMs >= completionObservedAtMs &&
      flight.observedAtMs >= completionObservedAtMs && camera.observedAtMs >= completionObservedAtMs;
    if (startedAt === undefined || !this.takeoffSentValue || !this.takeoffAcknowledgedValue ||
      this.landRequestedValue || this.landSentValue || this.movementActiveValue || !this.session.isActionLinkFresh() ||
      (telemetry.flightAgeMs ?? Infinity) > 1000 || (telemetry.taskAgeMs ?? Infinity) > 1000 ||
      (telemetry.cameraAgeMs ?? Infinity) > 1000 || flight === undefined || task === undefined || camera === undefined ||
      flight.observedAtMs < startedAt || task.observedAtMs < startedAt || camera.observedAtMs < startedAt ||
      flight.modeRaw !== 6 || !flight.airborne || !flight.motorsOn || camera.recordingCandidate !== false ||
      (!['0000000100', '0000000101', '0000000102', '0300000100', '0400000100'].includes(task.payloadHex) &&
        !manualAfterCompletion)) {
      return failure(ErrorLayer.TASK, 'NATIVE_HOVER_HANDOFF_REQUIRED', '请等待上一任务结束、相机空闲并恢复普通悬停后再拍摄');
    }
    this.nativeTaskMayFlyValue = false;
    this.nativeStartedAtValue = undefined; this.nativeStopConfirmedAtValue = undefined;
    return success(true);
  }

  async foregroundOnlySafetyShutdown(): Promise<OperationResult<boolean>> {
    this.activeToken.cancel();
    await this.centerSticks();
    if (this.takeoffSentValue || this.nativeTaskMayFlyValue) {
      await this.land();
    }
    await this.session.disconnect();
    return success(true);
  }

  private nativeManualControlReady(): boolean {
    if (!this.nativeTaskMayFlyValue || this.nativeStartedAtValue === undefined ||
      this.nativeStopConfirmedAtValue === undefined ||
      this.nativeStopConfirmedAtValue < this.nativeStartedAtValue) {
      return false;
    }
    const telemetry = this.session.snapshot().telemetry;
    const flight = telemetry.flight;
    const task = telemetry.task;
    return flight !== undefined && telemetry.flightAgeMs !== undefined && telemetry.flightAgeMs <= 1000 &&
      flight.observedAtMs >= this.nativeStopConfirmedAtValue && flight.motorsOn && flight.airborne &&
      flight.modeRaw === 6 && task !== undefined && telemetry.taskAgeMs !== undefined && telemetry.taskAgeMs <= 1000 &&
      task.observedAtMs >= this.nativeStopConfirmedAtValue &&
      (task.payloadHex === '0000000101' || task.payloadHex === '0000000102');
  }

  private tokenCancelled(token?: CancellationToken): boolean {
    return token !== undefined && (token.isCancelled() || token.generation() !== this.generationValue);
  }
}

function isSuccessReply(reply?: Uint8Array): boolean {
  return reply !== undefined && reply.length === 1 && reply[0] === 0;
}

function replyHex(reply?: Uint8Array): string {
  if (reply === undefined) {
    return 'no_reply';
  }
  let result = '';
  reply.forEach((value: number) => result += value.toString(16).padStart(2, '0'));
  return result;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, milliseconds));
}

function errorMessage(error: Object): string {
  return error instanceof Error ? error.message : String(error);
}
