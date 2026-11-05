import { Context } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { MediaKind } from '../media/MediaDirectory';

export class GallerySaver {
  // Invoked directly after a successful system SaveButton click.
  async save(context: Context, uri: string, kind: MediaKind): Promise<void> {
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    try {
      const change = kind === 'photo' ?
        photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(context, uri) :
        photoAccessHelper.MediaAssetChangeRequest.createVideoAssetRequest(context, uri);
      await helper.applyChanges(change);
    } finally {
      await helper.release().catch(() => {});
    }
  }
}
