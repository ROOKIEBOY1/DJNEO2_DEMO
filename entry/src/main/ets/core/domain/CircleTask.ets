import { bytesEqual, concatBytes, toHex } from '../protocol/Bytes';
import { CIRCLE_SELECTION_PAYLOAD, CIRCLE_START_PAYLOAD, parseRadiusValue, radiusPayload,
  RADIUS_HASH_BYTES, validateCircleRadius } from '../protocol/CircleCodec';
import { CancellationToken, ErrorLayer, failure, OperationResult, success } from './OperationResult';
import { DroneSession } from './DroneSession';
import { FlightCommandService } from './FlightCommandService';

export interface CircleSnapshot {
  prepared: boolean;
  radiusMeters: number;
  startedAtMs?: number;
  startReply?: string;
  stopReply?: string;
  executionObserved: boolean;
}

export class CircleTask {
  private readonly session: DroneSession;
  private readonly flight: FlightCommandService;
  private preparedValue: boolean = false;
  private radiusValue: number = 2;
  private startedAtValue?: number;
  private startReplyValue?: string;
  private stopReplyValue?: string;
  private executionObservedValue: boolean = false;
  private operationActive: boolean = false;

  constructor(session: DroneSession, flight: FlightCommandService) {
    this.session = session;
    this.flight = flight;
  }

  snapshot(): CircleSnapshot {
    return {
      prepared: this.preparedValue,
      radiusMeters: this.radiusValue,
      startedAtMs: this.startedAtValue,
      startReply: this.startReplyValue,
      stopReply: this.stopReplyValue,
      executionObserved: this.executionObservedValue
    };
  }

  resetForAircraftSession(): void {
    this.preparedValue = false;
    this.radiusValue = 2;
    this.startedAtValue = undefined;
    this.startReplyValue = undefined;
    this.stopReplyValue = undefined;
    this.executionObservedValue = false;
    this.operationActive = false;
  }

  async prepare(radiusMeters: number = 2, token?: CancellationToken): Promise<OperationResult<number>> {
    try {
      validateCircleRadius(radiusMeters);
      if (radiusMeters !== 2) {
        return failure(ErrorLayer.TASK, 'EXPERIMENTAL_RADIUS_LOCKED',
          'Only the capture-verified 2 meter circle is enabled in this build', false);
      }
      if (this.operationActive) {
        return failure(ErrorLayer.TASK, 'CIRCLE_BUSY', 'Circle preparation or start is already active');
      }
      if (!this.session.isActionLinkFresh()) {
        return failure(ErrorLayer.NETWORK, 'LINK_NOT_FRESH', 'Circle requires fresh device and video evidence');
      }
      if (token?.isCancelled()) {
        return failure(ErrorLayer.TASK, 'CIRCLE_CANCELLED', 'Circle preparation was cancelled');
      }
      this.operationActive = true;
      this.preparedValue = false;
      await this.flight.centerSticks();
      const selectionReply = await this.session.requestNative(0x17, 3, 0xf9, CIRCLE_SELECTION_PAYLOAD);
      if (!echoMatches(selectionReply, CIRCLE_SELECTION_PAYLOAD)) {
        return failure(ErrorLayer.COMMAND, 'CIRCLE_MODE_ECHO_FAILED', 'Circle mode write did not echo correctly');
      }
      const radius = radiusPayload(radiusMeters);
      const radiusReply = await this.session.requestNative(0x92, 3, 0xf9, radius);
      if (!echoMatches(radiusReply, radius)) {
        return failure(ErrorLayer.COMMAND, 'CIRCLE_RADIUS_ECHO_FAILED', 'Circle radius write did not echo correctly');
      }
      const readReply = await this.session.requestNative(0x92, 3, 0xf8, RADIUS_HASH_BYTES);
      if (readReply === undefined || Math.abs(parseRadiusValue(readReply) - radiusMeters) > 0.00001) {
        return failure(ErrorLayer.COMMAND, 'CIRCLE_RADIUS_READBACK_FAILED',
          'Circle radius readback did not match the requested value');
      }
      if (token?.isCancelled()) {
        return failure(ErrorLayer.TASK, 'CIRCLE_CANCELLED', 'Circle preparation was cancelled before completion');
      }
      this.radiusValue = radiusMeters;
      this.preparedValue = true;
      return success(radiusMeters);
    } catch (error) {
      return failure(ErrorLayer.TASK, 'CIRCLE_PREPARE_FAILED', errorMessage(error));
    } finally {
      this.operationActive = false;
    }
  }

  async start(confirmed: boolean, token?: CancellationToken): Promise<OperationResult<string>> {
    if (!confirmed) {
      return failure(ErrorLayer.FLIGHT, 'CIRCLE_CONFIRMATION_REQUIRED',
        'Circle may take off automatically and requires explicit confirmation', false);
    }
    if (!this.preparedValue || this.operationActive || token?.isCancelled()) {
      return failure(ErrorLayer.TASK, 'CIRCLE_NOT_PREPARED', 'Prepare and read back the radius before starting');
    }
    this.operationActive = true;
    try {
      this.startedAtValue = Date.now();
      this.flight.markNativeTaskMayFly(this.startedAtValue);
      const reply = await this.session.requestNative(0x92, 0x23, 0x13, CIRCLE_START_PAYLOAD);
      this.startReplyValue = reply === undefined ? 'no_reply' : toHex(reply);
      return success(this.startReplyValue);
    } catch (error) {
      return failure(ErrorLayer.COMMAND, 'CIRCLE_START_FAILED', errorMessage(error));
    } finally {
      this.operationActive = false;
    }
  }

  async waitExecution(timeoutMs: number = 12000, token?: CancellationToken): Promise<OperationResult<boolean>> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline && !token?.isCancelled()) {
      const task = this.session.snapshot().telemetry.task;
      if (task !== undefined && this.startedAtValue !== undefined &&
        task.observedAtMs >= this.startedAtValue && task.payloadHex === '0505000100') {
        this.executionObservedValue = true;
        return success(true);
      }
      await delay(100);
    }
    return failure(ErrorLayer.TASK, 'CIRCLE_EXECUTION_NOT_OBSERVED',
      'The start request may have replied, but execution state was not observed');
  }

  async stop(): Promise<OperationResult<string>> {
    await this.flight.centerSticks();
    try {
      const reply = await this.session.requestNative(0x92, 0x23, 0x15, new Uint8Array(0));
      this.stopReplyValue = reply === undefined ? 'no_reply' : toHex(reply);
      if (reply !== undefined && reply.length === 1 && reply[0] === 0) {
        this.flight.markNativeStopConfirmed(Date.now());
      }
      return success(this.stopReplyValue);
    } catch (error) {
      return failure(ErrorLayer.COMMAND, 'CIRCLE_STOP_FAILED', errorMessage(error));
    }
  }
}

function echoMatches(reply: Uint8Array | undefined, payload: Uint8Array): boolean {
  return reply !== undefined && bytesEqual(reply, concatBytes(new Uint8Array([0]), payload));
}

function delay(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, milliseconds));
}

function errorMessage(error: Object): string {
  return error instanceof Error ? error.message : String(error);
}
