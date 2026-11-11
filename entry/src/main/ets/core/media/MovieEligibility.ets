import { ConsoleSnapshot } from '../domain/AppController';
import { videoResultReady } from '../domain/AssistantFlightPresentation';

export function movieSourceReady(state: ConsoleSnapshot): boolean {
  return movieMediaReady(state) && videoResultReady(state);
}

// Completeness belongs to the returned media group, independently of which
// subject-confirmation card is temporarily shown over that local result.
export function movieMediaReady(state: ConsoleSnapshot): boolean {
  const sequence = state.closeup;
  return state.agentVideoResultReady && state.agentMediaKind === 'video' &&
    state.agentMediaUri.length > 0 && state.agentMediaUris.includes(state.agentMediaUri) && !state.videoCapturePending &&
    (sequence === undefined || !sequence.active && ['idle', 'completed'].includes(sequence.stage));
}
