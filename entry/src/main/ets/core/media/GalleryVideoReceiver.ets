export interface GalleryVideoPort {
  authorize: (sources: string[]) => Promise<string[]>;
  copy: (source: string, destination: string) => Promise<void>;
  open: (uri: string) => Promise<void>;
}

// Shares authorization and completed copies between inline saving and gallery handoff.
export class GalleryVideoReceiver {
  private destinations: Map<string, string> = new Map();
  private copied: Set<string> = new Set();
  private busy: boolean = false;
  async accept(originals: string[], port: GalleryVideoPort): Promise<void> {
    await this.receive(originals, port, true);
  }
  async save(originals: string[], port: GalleryVideoPort): Promise<void> {
    await this.receive(originals, port, false);
  }
  private async receive(originals: string[], port: GalleryVideoPort, openGallery: boolean): Promise<void> {
    if (this.busy) throw new Error('正在接收视频，请稍候');
    if (originals.length === 0) throw new Error('本次录像尚未取回');
    this.busy = true;
    try {
      const missing = originals.filter((uri: string) => !this.destinations.has(uri));
      if (missing.length > 0) {
        const created = await port.authorize(missing);
        if (created.length !== missing.length || created.some((uri: string) => uri.length === 0)) {
          throw new Error('已取消保存，录像仍保留在App中');
        }
        missing.forEach((uri: string, index: number) => this.destinations.set(uri, created[index]));
      }
      for (const source of originals) {
        if (this.copied.has(source)) continue;
        await port.copy(source, this.destinations.get(source) as string);
        this.copied.add(source);
      }
      if (openGallery) await port.open(this.destinations.get(originals[0]) as string);
    } finally { this.busy = false; }
  }
}
