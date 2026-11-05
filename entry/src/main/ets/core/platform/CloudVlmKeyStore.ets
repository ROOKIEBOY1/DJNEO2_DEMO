import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class CloudVlmKeyStore {
  private queryMap(): asset.AssetMap {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, util.TextEncoder.create().encodeInto('neo2-deepseek-key-v1'));
    return query;
  }
  async save(value: string): Promise<void> {
    const key = value.trim();
    if (!/^sk-[A-Za-z0-9_-]{16,200}$/.test(key)) throw new Error('API Key格式不正确，请填写DeepSeek密钥');
    const attributes = this.queryMap();
    attributes.set(asset.Tag.SECRET, util.TextEncoder.create().encodeInto(key));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try { await asset.add(attributes); }
    catch (error) { throw new Error(`手机安全存储写入失败，请解锁后重试（${(error as BusinessError).code}）`); }
  }
  async read(): Promise<string | undefined> {
    const query = this.queryMap();
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    query.set(asset.Tag.RETURN_LIMIT, 1);
    try {
      const found = await asset.query(query);
      const bytes = found[0]?.get(asset.Tag.SECRET) as Uint8Array | undefined;
      if (bytes === undefined) return undefined;
      return util.TextDecoder.create('utf-8').decodeToString(bytes);
    } catch (error) {
      const code = (error as BusinessError).code;
      if (code === 24000002) return undefined;
      throw new Error(`手机安全存储暂不可读取，请解锁后重试（${code}）`);
    }
  }
  async clear(): Promise<void> {
    try { await asset.remove(this.queryMap()); }
    catch (error) { if ((error as BusinessError).code !== 24000002) throw new Error('手机安全存储清除失败'); }
  }
  async importPrivateFile(path: string): Promise<boolean> {
    if (!fileIo.accessSync(path)) return false;
    try { await this.save(fileIo.readTextSync(path)); return true; }
    finally { fileIo.unlinkSync(path); }
  }
}
