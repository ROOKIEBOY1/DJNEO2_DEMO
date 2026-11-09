import { common, wantConstant } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { GalleryVideoPort } from '../media/GalleryVideoReceiver';

export function systemGalleryPort(context: common.UIAbilityContext): GalleryVideoPort {
  return {
    authorize: async (sources: string[]): Promise<string[]> => {
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      try {
        const configs: photoAccessHelper.PhotoCreationConfig[] = sources.map((_uri: string): photoAccessHelper.PhotoCreationConfig => {
          return { fileNameExtension: 'mp4', photoType: photoAccessHelper.PhotoType.VIDEO };
        });
        return await helper.showAssetsCreationDialog(sources, configs);
      } finally { await helper.release().catch(() => {}); }
    },
    copy: async (source: string, destination: string): Promise<void> => {
      const input = await fileIo.open(source, fileIo.OpenMode.READ_ONLY);
      try {
        const output = await fileIo.open(destination, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        try { await fileIo.copyFile(input.fd, output.fd); }
        finally { await fileIo.close(output); }
      } finally { await fileIo.close(input); }
    },
    open: async (uri: string): Promise<void> => {
      try {
        await context.startAbility({ action: 'ohos.want.action.viewData',
          bundleName: 'com.huawei.hmos.photos', abilityName: 'com.huawei.hmos.photos.MainAbility',
          uri: uri, type: 'video/mp4', flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION });
      } catch (_) { throw new Error('录像已保存到图库，打开播放页失败，可重试或到图库查看'); }
    }
  };
}
