import { SubjectSnapshot } from './SubjectObservation';

export type CloseupSubjectState = 'confirmed' | 'different' | 'unknown';

// Native tasks can clear their display-box channel before reporting completion.
// Missing visual feedback is unknown, never renewed evidence for the old target
// or proof of replacement. Step boundaries independently require fresh same-ID evidence.
export class CloseupSubjectGuard {
  private targetId: number;

  constructor(targetId: number) { this.targetId = targetId; }

  assess(subject: SubjectSnapshot | undefined, now: number): CloseupSubjectState {
    if (!Number.isFinite(now) || now < 0) return 'unknown';
    const trackedId = subject?.tracking === true && subject.overlay.length === 1 ? subject.overlay[0].id : undefined;
    const trackingAt = subject?.trackingAt;
    if (trackedId !== undefined && trackingAt !== undefined && Number.isFinite(trackingAt) &&
      trackingAt >= 0 && now - trackingAt >= 0 && now - trackingAt <= 1000) {
      return trackedId === this.targetId ? 'confirmed' : 'different';
    }
    return 'unknown';
  }
}
