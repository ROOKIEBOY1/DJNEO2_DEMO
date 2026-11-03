import { CancellationToken, ErrorLayer, failure, OperationResult, success } from '../domain/OperationResult';
import { DroneSession } from '../domain/DroneSession';
import { DirectoryStream, makeDirectoryRequest, MediaEntry, MediaKind } from './MediaDirectory';
import { MediaDownloader, MediaDownloadResult } from './MediaDownloader';

export class MediaRepository {
  private readonly session: DroneSession;
  private fileSession: number = 1;
  private busy: boolean = false;
  private cachedEntries: MediaEntry[] = [];
  private readonly downloader: MediaDownloader = new MediaDownloader();

  constructor(session: DroneSession) {
    this.session = session;
  }

  entries(): MediaEntry[] {
    return this.cachedEntries.slice();
  }

  async listMedia(token?: CancellationToken, timeoutMs: number = 6000): Promise<OperationResult<MediaEntry[]>> {
    if (this.busy) {
      return failure(ErrorLayer.TASK, 'MEDIA_BUSY', 'Another media directory request is active');
    }
    if (!this.session.isReliableLinkFresh() && !(await this.session.refreshReliableLink())) {
      return failure(ErrorLayer.NETWORK, 'LINK_NOT_FRESH', 'Media directory requires a fresh verified link');
    }
    if (timeoutMs <= 0 || timeoutMs > 10000) {
      return failure(ErrorLayer.COMMAND, 'MEDIA_TIMEOUT_INVALID', 'Media timeout is outside bounds', false);
    }
    this.busy = true;
    this.fileSession = this.fileSession % 0xffff + 1;
    const stream = new DirectoryStream(this.session.sessionId(), this.fileSession,
      this.session.nextChannel3Sequence());
    this.session.setChannel3Handler((packet: Uint8Array) => stream.feed(packet));
    try {
      if (token?.isCancelled()) {
        return failure(ErrorLayer.TASK, 'MEDIA_CANCELLED', 'Media request was cancelled before send');
      }
      const reply = await this.session.requestNative(1, 0, 0x26, makeDirectoryRequest(this.fileSession),
        Math.min(2000, timeoutMs));
      if (reply !== undefined && !(reply.length === 1 && reply[0] === 0)) {
        return failure(ErrorLayer.COMMAND, 'MEDIA_DIRECTORY_REJECTED', 'Aircraft rejected the directory request');
      }
      const deadline = Date.now() + timeoutMs;
      while (!stream.isDone() && Date.now() < deadline) {
        if (token?.isCancelled()) {
          return failure(ErrorLayer.TASK, 'MEDIA_CANCELLED', 'Media request was cancelled');
        }
        await delay(50);
      }
      if (!stream.isDone()) {
        return failure(ErrorLayer.TRANSPORT, 'MEDIA_DIRECTORY_INCOMPLETE',
          'Media directory data was not completely received');
      }
      if (stream.error().length > 0) {
        return failure(ErrorLayer.TRANSPORT, 'MEDIA_DIRECTORY_INVALID', stream.error());
      }
      this.cachedEntries = stream.entries();
      return success(this.cachedEntries.slice());
    } catch (error) {
      return failure(ErrorLayer.TASK, 'MEDIA_DIRECTORY_FAILED', errorMessage(error));
    } finally {
      this.session.setChannel3Handler(undefined);
      this.busy = false;
    }
  }

  latest(kind: MediaKind): MediaEntry | undefined {
    return this.cachedEntries.find((entry: MediaEntry) => entry.kind === kind);
  }

  async downloadLatest(kind: MediaKind, outputDirectory: string,
    token?: CancellationToken): Promise<OperationResult<MediaDownloadResult>> {
    const listed = await this.listMedia(token);
    if (!listed.ok || listed.data === undefined) {
      return failure(ErrorLayer.TASK, 'MEDIA_LIST_REQUIRED',
        listed.error?.message ?? 'Could not refresh the media directory');
    }
    const entry = listed.data.find((candidate: MediaEntry) => candidate.kind === kind);
    if (entry === undefined) {
      return failure(ErrorLayer.TASK, 'MEDIA_NOT_FOUND', 'No matching original exists in the aircraft directory');
    }
    const selection = this.session.networkSelection();
    if (selection === undefined) {
      return failure(ErrorLayer.NETWORK, 'AIRCRAFT_NETWORK_MISSING', 'Aircraft Wi-Fi selection is unavailable');
    }
    try {
      return success(await this.downloader.download(entry, outputDirectory, selection, token));
    } catch (error) {
      return failure(ErrorLayer.TASK, 'MEDIA_DOWNLOAD_FAILED', errorMessage(error));
    }
  }
}

function delay(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, milliseconds));
}

function errorMessage(error: Object): string {
  return error instanceof Error ? error.message : String(error);
}
