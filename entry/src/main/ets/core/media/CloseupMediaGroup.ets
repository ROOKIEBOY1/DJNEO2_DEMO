// Retains every returned clip for one closeup, including clips arriving after cancellation.
export class CloseupMediaGroup {
  private sessionId?: number;
  private generation?: number;
  private uris: string[] = [];

  begin(sessionId: number, generation: number): void {
    this.sessionId = sessionId; this.generation = generation; this.uris = [];
  }

  clear(): void {
    this.sessionId = undefined; this.generation = undefined; this.uris = [];
  }

  owns(sessionId: number, generation: number): boolean {
    return this.sessionId !== undefined && this.generation !== undefined &&
      this.sessionId === sessionId && this.generation === generation;
  }

  add(uris: string[], sessionId: number, generation: number): string[] {
    const merged = this.owns(sessionId, generation) ? this.uris.slice() : [];
    for (const uri of uris) if (!merged.includes(uri)) merged.push(uri);
    if (this.owns(sessionId, generation)) this.uris = merged;
    return merged.slice();
  }
}
