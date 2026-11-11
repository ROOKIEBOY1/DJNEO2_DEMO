import * as nativeMovie from 'libneovideo.so';
import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { MovieExportPort, NativeMovieSnapshot, MovieCompositionSnapshot, MOVIE_TEMPLATE_VERSION } from '../media/MovieComposer';

export const MOVIE_MUSIC_NAME: string = '自选音轨';
export const MOVIE_MUSIC_DESCRIPTION: string = '配乐来自提供的视频，从片段开头播放，按成片时长截取或循环，并加入淡入淡出。';

export interface MovieCacheRecord {
  version: number;
  sourceKey: string;
  sources: string[];
  revision: string;
  outputPath: string;
  durationMs: number;
  size: number;
}

function localPath(uri: string): string {
  return uri.startsWith('file://') ? new fileUri.FileUri(uri).path : uri;
}

class NativeMovieBackend implements MovieExportPort {
  start(sources: string[], outputPath: string, musicPath: string): number {
    return nativeMovie.startMovieExport(sources.map((uri: string) => localPath(uri)), outputPath, musicPath);
  }
  snapshot(id: number): NativeMovieSnapshot { return nativeMovie.movieExportSnapshot(id); }
  cancel(id: number): void { nativeMovie.cancelMovieExport(id); }
}

export function nativeMoviePort(): MovieExportPort {
  return new NativeMovieBackend();
}

// Only the exporter owns temporary video files. This adapter never removes source footage.
export class NativeMovieFiles {
  revision(sources: string[]): string {
    return sources.map((uri: string): string => {
      try { const info = fileIo.statSync(localPath(uri)); return `${info.size}:${info.mtime}:${info.mtimeNs ?? ''}`; }
      catch (_) { return 'missing'; }
    }).join('|');
  }

  playableUri(path: string): string { return fileUri.getUriFromPath(path); }

  newOutputPath(directory: string): string {
    return `${directory}/neo_movie_${Date.now()}_${Math.floor(Math.random() * 1000000000)}.mp4`;
  }

  async prepareMusic(context: common.UIAbilityContext, directory: string): Promise<string> {
    const destination = `${directory}/movie-bgm-user-v1.mp3`;
    // Versioned source and exact size prevent reusing old music or a partial copy.
    try { if (fileIo.statSync(destination).size === 828908) return destination; } catch (_) { }
    const music = await context.resourceManager.getRawFileContent('movie-bgm-user-v1.mp3');
    if (music.byteLength !== 828908) throw new Error('内置配乐不完整，请更新应用');
    const temporary = `${destination}.part`;
    this.writeBytes(temporary, music);
    fileIo.renameSync(temporary, destination);
    return destination;
  }

  saveCompleted(directory: string, movie: MovieCompositionSnapshot, revision: string): void {
    if (movie.stage !== 'completed' || movie.outputPath.length === 0 || movie.durationMs <= 0) return;
    if (!movie.sourceKey.startsWith(MOVIE_TEMPLATE_VERSION + '|')) return;
    if (!this.validMovie(movie.outputPath, directory)) return;
    const record: MovieCacheRecord = { version: 1, sourceKey: movie.sourceKey, sources: movie.sources.slice(),
      revision: revision, outputPath: movie.outputPath, durationMs: movie.durationMs, size: fileIo.statSync(movie.outputPath).size };
    const json = util.TextEncoder.create().encodeInto(JSON.stringify(record));
    const path = this.cachePath(directory, record.sourceKey);
    this.writeBytes(`${path}.part`, json); fileIo.renameSync(`${path}.part`, path);
    const latest = `${directory}/neo-movie-latest.json`;
    this.writeBytes(`${latest}.part`, json); fileIo.renameSync(`${latest}.part`, latest);
  }

  loadCompleted(directory: string, sourceKey: string): MovieCacheRecord | undefined {
    return this.readRecord(this.cachePath(directory, sourceKey), directory, sourceKey);
  }

  loadLatest(directory: string): MovieCacheRecord | undefined {
    return this.readRecord(`${directory}/neo-movie-latest.json`, directory);
  }

  private readRecord(path: string, directory: string, sourceKey?: string): MovieCacheRecord | undefined {
    try {
      if (fileIo.statSync(path).size > 65536) return undefined;
      const record = JSON.parse(fileIo.readTextSync(path)) as MovieCacheRecord;
      if (record.version !== 1 || typeof record.sourceKey !== 'string' ||
        !record.sourceKey.startsWith(MOVIE_TEMPLATE_VERSION + '|') || !Array.isArray(record.sources) ||
        record.sources.length < 1 || record.sources.length > 8 || !record.sources.every((uri: string) => typeof uri === 'string') ||
        typeof record.outputPath !== 'string' || typeof record.revision !== 'string' ||
        !Number.isFinite(record.durationMs) || record.durationMs <= 0 || !Number.isFinite(record.size) || record.size <= 16 ||
        (sourceKey !== undefined && record.sourceKey !== sourceKey) || this.revision(record.sources) !== record.revision ||
        !this.validMovie(record.outputPath, directory) || fileIo.statSync(record.outputPath).size !== record.size) return undefined;
      return record;
    } catch (_) { return undefined; }
  }

  private validMovie(path: string, directory: string): boolean {
    // Restore only files generated by this exporter in this app's private output directory.
    if (!path.startsWith(`${directory}/neo_movie_`) || path.includes('/../') || path.includes('\\') || !path.endsWith('.mp4')) return false;
    try {
      if (fileIo.statSync(path).size <= 16) return false;
      const input = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const head = new ArrayBuffer(12);
        if (fileIo.readSync(input.fd, head) !== 12) return false;
        const bytes = new Uint8Array(head);
        return bytes[4] === 102 && bytes[5] === 116 && bytes[6] === 121 && bytes[7] === 112;
      } finally { fileIo.closeSync(input); }
    } catch (_) { return false; }
  }

  private writeBytes(path: string, bytes: Uint8Array): void {
    const output = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      let offset = 0;
      while (offset < bytes.byteLength) {
        const wrote = fileIo.writeSync(output.fd, bytes.slice(offset).buffer);
        if (wrote <= 0) throw new Error('保存成片文件失败，存储空间可能不足');
        offset += wrote;
      }
      fileIo.fsyncSync(output.fd);
    } finally { fileIo.closeSync(output); }
  }

  private cachePath(directory: string, key: string): string {
    let hash: number = 2166136261;
    for (let i = 0; i < key.length; i++) hash = Math.imul(hash ^ key.charCodeAt(i), 16777619) >>> 0;
    return `${directory}/neo-movie-cache-${hash.toString(16)}.json`;
  }
}
