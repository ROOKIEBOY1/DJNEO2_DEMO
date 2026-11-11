import { Context } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';

export interface SelfReferencePhotoProvider {
  read: () => Promise<string | undefined>;
}

const SOURCE_LIMIT: number = 8 * 1024 * 1024;
const JPEG_LIMIT: number = 750000;
const LONGEST_EDGE: number = 1024;

export class SelfReferencePhotoStore implements SelfReferencePhotoProvider {
  private readonly context: Context;
  private cached?: Promise<string | undefined>;

  constructor(context: Context) { this.context = context; }

  read(): Promise<string | undefined> {
    if (this.cached === undefined) {
      this.cached = this.normalize().catch(() => {
        this.cached = undefined;
        throw new Error('“我”的参考照片不可用，请检查本机参考照片');
      });
    }
    return this.cached;
  }

  private async normalize(): Promise<string> {
    const raw = await this.context.resourceManager.getRawFileContent('demo-self-reference.jpg');
    if (raw.byteLength > SOURCE_LIMIT || !hasJpegMarkers(raw)) throw new Error('参考照片无效或过大');
    const source = image.createImageSource(new Uint8Array(raw).buffer);
    let pixels: image.PixelMap | undefined;
    let packer: image.ImagePacker | undefined;
    try {
      const info = await source.getImageInfo();
      const size = info.size;
      if (!validSize(size)) throw new Error('参考照片尺寸无效');
      const orientation = await source.getImageProperty(image.PropertyKey.ORIENTATION, { defaultValue: 'Top-left' });
      if (!['Top-left', 'Top-right', 'Bottom-right', 'Bottom-left',
        'Left-top', 'Right-top', 'Right-bottom', 'Left-bottom'].includes(orientation)) {
        throw new Error('参考照片方向无效');
      }
      const scale = Math.min(1, LONGEST_EDGE / Math.max(size.width, size.height));
      pixels = await source.createPixelMap({ editable: true,
        desiredSize: { width: Math.max(1, Math.floor(size.width * scale)), height: Math.max(1, Math.floor(size.height * scale)) } });
      // SDK Orientation labels describe the transform of the stored pixels; bake it into the JPEG.
      if (orientation === 'Top-right' || orientation === 'Left-top' || orientation === 'Right-bottom') {
        await pixels.flip(true, false);
      } else if (orientation === 'Bottom-left') {
        await pixels.flip(false, true);
      }
      if (orientation === 'Bottom-right') await pixels.rotate(180);
      else if (orientation === 'Right-top' || orientation === 'Right-bottom') await pixels.rotate(90);
      else if (orientation === 'Left-top' || orientation === 'Left-bottom') await pixels.rotate(270);
      const normalized = (await pixels.getImageInfo()).size;
      if (!validSize(normalized) || Math.max(normalized.width, normalized.height) > LONGEST_EDGE) {
        throw new Error('参考照片缩放失败');
      }
      packer = image.createImagePacker();
      const jpeg = await packer.packToData(pixels, { format: 'image/jpeg', quality: 82, needsPackProperties: false });
      if (jpeg.byteLength > JPEG_LIMIT || !hasJpegMarkers(new Uint8Array(jpeg))) throw new Error('参考照片编码无效或过大');
      return `data:image/jpeg;base64,${new util.Base64Helper().encodeToStringSync(new Uint8Array(jpeg))}`;
    } finally {
      try { await packer?.release(); } catch (_) {}
      try { await pixels?.release(); } catch (_) {}
      try { await source.release(); } catch (_) {}
    }
  }
}

function validSize(size: image.Size): boolean {
  return Number.isInteger(size.width) && Number.isInteger(size.height) && size.width > 0 && size.height > 0;
}

function hasJpegMarkers(bytes: Uint8Array): boolean {
  return bytes.byteLength >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8 &&
    bytes[bytes.byteLength - 2] === 0xff && bytes[bytes.byteLength - 1] === 0xd9;
}
