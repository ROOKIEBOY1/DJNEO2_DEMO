import { window } from '@kit.ArkUI';

export class DollyDemoWindow {
  static stage?: window.WindowStage;
  private static dialog?: window.Window;
  private static opening: boolean = false;

  static async open(): Promise<void> {
    const stage = DollyDemoWindow.stage;
    if (DollyDemoWindow.opening || DollyDemoWindow.dialog !== undefined) return;
    if (stage === undefined) throw new Error('拍摄窗口暂不可用');
    DollyDemoWindow.opening = true;
    try {
      const dialog = await stage.createSubWindow('NeoDollyDemo');
      DollyDemoWindow.dialog = dialog;
      const bounds = stage.getMainWindowSync().getWindowProperties().windowRect;
      const width = Math.floor(bounds.width * 0.94);
      const height = Math.floor(bounds.height * 0.82);
      await dialog.resize(width, height);
      await dialog.moveWindowTo(bounds.left + Math.floor((bounds.width - width) / 2),
        bounds.top + Math.floor((bounds.height - height) / 2));
      await dialog.setUIContent('pages/DollyDemo');
      await dialog.showWindow();
    } catch (error) {
      await DollyDemoWindow.close();
      throw new Error(String(error));
    } finally {
      DollyDemoWindow.opening = false;
    }
  }

  static async close(): Promise<void> {
    const dialog = DollyDemoWindow.dialog;
    if (dialog === undefined) return;
    await dialog.destroyWindow();
    if (DollyDemoWindow.dialog === dialog) DollyDemoWindow.dialog = undefined;
  }
}
