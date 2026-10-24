import { UIContext } from '@kit.ArkUI';
import { EditParams } from '../model/Scope';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 路由封装（基于 UIContext.getRouter，替代已废弃的全局 router）。
 */
export class RouterUtil {
  static editPerson(ui: UIContext, uid: string, mode: string, presetParent: string): void {
    const params: EditParams = { mode: mode, uid: uid, presetParent: presetParent };
    ui.getRouter().pushUrl({ url: 'pages/PersonEdit', params: params })
      .catch((err: BusinessError): void => {
        console.error('push PersonEdit failed: ' + err.message);
      });
  }

  static settings(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/Settings' })
      .catch((err: BusinessError): void => {
        console.error('push Settings failed: ' + err.message);
      });
  }

  static importExport(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/ImportExport' })
      .catch((err: BusinessError): void => {
        console.error('push ImportExport failed: ' + err.message);
      });
  }

  static back(ui: UIContext): void {
    ui.getRouter().back();
  }
}
