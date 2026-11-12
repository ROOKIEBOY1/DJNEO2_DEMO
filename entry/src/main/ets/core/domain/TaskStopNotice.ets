export interface TaskStopNotice {
  id: string;
  message: string;
  observedAtMs: number;
}

// UI-only delivery. A failed toast must not retry on every telemetry refresh or
// change any operation state. The main page is the single popup owner.
export class TaskStopNoticePresenter {
  private seen: string[] = [];

  present(notice: TaskStopNotice | undefined, display: (message: string) => void): void {
    if (notice === undefined || this.seen.includes(notice.id)) return;
    this.seen.push(notice.id);
    if (this.seen.length > 16) this.seen.shift();
    try { display(notice.message); } catch (_) {}
  }
}
