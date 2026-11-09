import { ConsoleSnapshot } from '../domain/AppController';
import { videoResultReady } from '../domain/AssistantFlightPresentation';

export function movieSourceReady(state: ConsoleSnapshot): boolean {
  const sequence = state.closeup;
  return videoResultReady(state) && !state.videoCapturePending &&
    (sequence === undefined || !sequence.active && ['idle', 'completed'].includes(sequence.stage));
}
