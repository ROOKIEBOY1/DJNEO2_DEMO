import { DumlFrame } from '../protocol/DumlCodec';

export interface SubjectBox {
  id: number;
  left: number;
  top: number;
  width: number;
  height: number;
}

interface SubjectReport {
  at: number;
  boxes: SubjectBox[];
}

export interface SubjectSnapshot {
  candidateCount?: number;
  detectionAt?: number;
  selectedIdCandidate?: number;
  trackingAt?: number;
  candidates: SubjectBox[];
  overlay: SubjectBox[];
  scanStateRaw?: number;
  scanObservedAt?: number;
  tracking: boolean;
}

// Presentation only: keep all scan candidates intact for model input and control.
export function selectedSubjectOverlay(subject: SubjectSnapshot | undefined, selectedId: number | undefined): SubjectBox[] {
  if (selectedId === undefined || subject?.tracking !== true || subject.selectedIdCandidate !== selectedId) return [];
  return subject.overlay.filter((item: SubjectBox) => item.id === selectedId);
}

function box(id: number, x: number, y: number, width: number, height: number): SubjectBox {
  if (!(x >= 0 && x <= 1 && y >= 0 && y <= 1 && width > 0 && width <= 1 && height > 0 && height <= 1)) {
    throw new Error('Invalid subject coordinates');
  }
  // Match the center/size interpretation inferred from the original captures.
  const left = Math.max(0, x - width / 2);
  const top = Math.max(0, y - height / 2);
  return { id: id, left: left, top: top, width: Math.min(1, x + width / 2) - left,
    height: Math.min(1, y + height / 2) - top };
}

export class SubjectObservation {
  private detection?: SubjectReport;
  private track?: SubjectReport;
  private selectedIdCandidate?: number;
  private scanAt: number = -1;
  private scanState?: number;

  observe(frame: DumlFrame, at: number): void {
    if (frame.sender !== 0x92 || frame.receiver !== 2 || frame.flags !== 0 || frame.commandSet !== 0x0a) return;
    const p = frame.payload;
    const view = new DataView(p.buffer, p.byteOffset, p.byteLength);
    if (frame.commandId === 0xbc) {
      this.detection = undefined;
      // Accept complete 12-byte record tables; this does not establish the device's detection capacity.
      if (p.length < 12 || p[0] !== 2 || p.length !== 12 + 12 * p[11]) return;
      const boxes: SubjectBox[] = [];
      const seenIds: Set<number> = new Set<number>();
      try {
        for (let offset = 12; offset < p.length; offset += 12) {
          const id = view.getUint16(offset, true);
          if (id > 255 || seenIds.has(id)) return;
          seenIds.add(id);
          boxes.push(box(id, view.getUint16(offset + 4, true) / 10000,
            view.getUint16(offset + 6, true) / 10000, view.getUint16(offset + 8, true) / 10000,
            view.getUint16(offset + 10, true) / 10000));
        }
        this.detection = { at: at, boxes: boxes };
        this.selectedIdCandidate = view.getUint16(6, true);
      } catch (_) { return; }
    } else if (frame.commandId === 0x95) {
      this.track = undefined;
      if (p.length === 1 && p[0] === 0) this.track = { at: at, boxes: [] };
      if (p.length !== 20 || p[0] !== 1) return;
      try {
        this.track = { at: at, boxes: [box(p[1], view.getFloat32(3, true), view.getFloat32(7, true),
          view.getFloat32(11, true), view.getFloat32(15, true))] };
      } catch (_) { return; }
    } else if (frame.commandId === 0xbb) {
      this.scanAt = at;
      this.scanState = p.length === 7 && p[0] === 1 ? p[5] : undefined;
    }
  }

  snapshot(now: number): SubjectSnapshot {
    const detection = this.fresh(this.detection, now);
    const track = this.fresh(this.track, now);
    const candidates = detection?.boxes ?? [];
    const tracking = track !== undefined && track.boxes.length > 0 &&
      !(detection !== undefined && candidates.length === 0 && detection.at >= track.at);
    const scanAge = now - this.scanAt;
    return { candidateCount: detection?.boxes.length, candidates: candidates,
      detectionAt: detection?.at, selectedIdCandidate: detection === undefined ? undefined : this.selectedIdCandidate,
      trackingAt: tracking ? track?.at : undefined,
      overlay: tracking && track !== undefined ? track.boxes : candidates, tracking: tracking,
      scanStateRaw: scanAge >= 0 && scanAge <= 1000 ? this.scanState : undefined,
      scanObservedAt: scanAge >= 0 && scanAge <= 1000 && this.scanState !== undefined ? this.scanAt : undefined };
  }

  private fresh(report: SubjectReport | undefined, now: number): SubjectReport | undefined {
    if (report === undefined) return undefined;
    const age = now - report.at;
    return age >= 0 && age <= 1000 ? report : undefined;
  }
}
