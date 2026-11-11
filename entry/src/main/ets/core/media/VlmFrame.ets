import { SubjectBox, SubjectSnapshot } from '../domain/SubjectObservation';

export interface VlmFrame {
  jpeg: ArrayBuffer;
  width: number;
  height: number;
  sessionId: number;
  capturedAtMs: number;
  candidatesObservedAtMs: number;
  candidates: SubjectBox[];
  currentSubjectId?: number;
}

export function trackedSubjectId(subject?: SubjectSnapshot): number | undefined {
  return subject?.tracking && subject.overlay.length === 1 ? subject.overlay[0].id : undefined;
}

// Mark the drone's candidate IDs directly on the image given to the model.
export function markVlmCandidates(rgba: ArrayBuffer, width: number, height: number, candidates: SubjectBox[]): void {
  if (width < 1 || height < 1 || rgba.byteLength !== width * height * 4) throw new Error('候选标记画面尺寸无效');
  const pixels = new Uint8Array(rgba);
  const digits: number[] = [31599, 11415, 29671, 29647, 23497, 31183, 31215, 29257, 31727, 31695];
  const paint = (x: number, y: number, red: number, green: number, blue: number): void => {
    if (x < 0 || x >= width || y < 0 || y >= height) return;
    const offset = (y * width + x) * 4;
    pixels[offset] = red; pixels[offset + 1] = green; pixels[offset + 2] = blue; pixels[offset + 3] = 255;
  };
  for (const candidate of candidates) {
    const left = Math.max(0, Math.min(width - 1, Math.round(candidate.left * width)));
    const top = Math.max(0, Math.min(height - 1, Math.round(candidate.top * height)));
    const right = Math.max(left, Math.min(width - 1, Math.round((candidate.left + candidate.width) * width)));
    const bottom = Math.max(top, Math.min(height - 1, Math.round((candidate.top + candidate.height) * height)));
    for (let x = left; x <= right; x++) {
      paint(x, top, 0, 255, 100); paint(x, bottom, 0, 255, 100);
    }
    for (let y = top; y <= bottom; y++) {
      paint(left, y, 0, 255, 100); paint(right, y, 0, 255, 100);
    }
    const text = `${candidate.id}`;
    const labelWidth = text.length * 12 + 6;
    const labelX = Math.max(0, Math.min(left, width - labelWidth));
    const labelY = Math.max(0, top - 21);
    for (let y = 0; y < 21; y++) for (let x = 0; x < labelWidth; x++) paint(labelX + x, labelY + y, 0, 0, 0);
    for (let index = 0; index < text.length; index++) {
      const bits = digits[Number(text[index])];
      for (let row = 0; row < 5; row++) for (let col = 0; col < 3; col++) {
        if (((bits >> (14 - row * 3 - col)) & 1) === 0) continue;
        for (let dy = 0; dy < 3; dy++) for (let dx = 0; dx < 3; dx++) {
          paint(labelX + 3 + index * 12 + col * 3 + dx, labelY + 3 + row * 3 + dy, 255, 255, 255);
        }
      }
    }
  }
}

export const VLM_SELECTION_TIMEOUT_MS = 20000;

export function canApplyVlmSelection(frame: VlmFrame, id: number, sessionId: number,
  flightGeneration: number, currentGeneration: number, now: number): boolean {
  const age = now - frame.capturedAtMs;
  return frame.sessionId === sessionId && flightGeneration === currentGeneration &&
    age >= 0 && age <= VLM_SELECTION_TIMEOUT_MS && frame.candidates.some(candidate => candidate.id === id);
}

export function closestFrameSubjects(capturedAtMs: number, before?: SubjectSnapshot,
  after?: SubjectSnapshot): SubjectSnapshot | undefined {
  let selected: SubjectSnapshot | undefined;
  let smallest = 200;
  const reports: (SubjectSnapshot | undefined)[] = [before, after];
  for (let index = 0; index < reports.length; index++) {
    const report = reports[index];
    if (report === undefined || report.detectionAt === undefined) continue;
    const distance = Math.abs(report.detectionAt - capturedAtMs);
    if (distance <= smallest) { smallest = distance; selected = report; }
  }
  return selected;
}
