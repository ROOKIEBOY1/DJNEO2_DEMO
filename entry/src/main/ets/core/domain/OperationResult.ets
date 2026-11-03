export enum ErrorLayer {
  NETWORK = 'network',
  HANDSHAKE_REGISTRATION = 'handshake_registration',
  TRANSPORT = 'transport',
  COMMAND = 'command',
  TASK = 'task',
  FLIGHT = 'flight'
}

export interface DroneError {
  layer: ErrorLayer;
  code: string;
  message: string;
  recoverable: boolean;
}

export interface OperationResult<T> {
  ok: boolean;
  data?: T;
  error?: DroneError;
}

export function success<T>(data: T): OperationResult<T> {
  return { ok: true, data: data };
}

export function failure<T>(layer: ErrorLayer, code: string, message: string,
  recoverable: boolean = true): OperationResult<T> {
  return {
    ok: false,
    error: { layer: layer, code: code, message: message, recoverable: recoverable }
  };
}

export class CancellationToken {
  private cancelled: boolean = false;
  private readonly generationValue: number;

  constructor(generation: number) {
    this.generationValue = generation;
  }

  cancel(): void {
    this.cancelled = true;
  }

  isCancelled(): boolean {
    return this.cancelled;
  }

  generation(): number {
    return this.generationValue;
  }
}
