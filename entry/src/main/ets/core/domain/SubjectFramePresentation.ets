import { SubjectBox } from './SubjectObservation';

// Preview geometry only. Never use this box for candidate selection or flight control.
export function subjectFramePresentation(box: SubjectBox): SubjectBox | undefined {
  if (!Number.isFinite(box.id) || !Number.isFinite(box.left) || !Number.isFinite(box.top) ||
    !Number.isFinite(box.width) || !Number.isFinite(box.height) || box.width <= 0 || box.height <= 0 ||
    box.left >= 1 || box.top >= 1 || box.left + box.width <= 0 || box.top + box.height <= 0) {
    return undefined;
  }
  const width = Math.min(box.width * 0.9, 0.8);
  const height = Math.min(box.height * 0.9, 0.8);
  // Keep the observed center unless the frame needs to move inside the preview's safe inset.
  const left = Math.min(Math.max(box.left + box.width / 2 - width / 2, 0.08), 0.92 - width);
  const top = Math.min(Math.max(box.top + box.height / 2 - height / 2, 0.08), 0.92 - height);
  return { id: box.id, left: left, top: top, width: width, height: height };
}

export function showSubjectFrame(stage: string, confirmed: boolean): boolean {
  return !confirmed && (stage === 'selecting' || stage === 'confirm');
}
