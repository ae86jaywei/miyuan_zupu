import { UIContext } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { AccessParams, EditParams, GenealogyScope } from '../model/Scope';
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

  static login(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/Login' })
      .catch((err: BusinessError): void => {
        console.error('push Login failed: ' + err.message);
      });
  }

  static sharedView(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/SharedView' })
      .catch((err: BusinessError): void => {
        console.error('push SharedView failed: ' + err.message);
      });
  }

  static familyHome(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/FamilyHome' })
      .catch((err: BusinessError): void => {
        console.error('push FamilyHome failed: ' + err.message);
      });
  }

  static familyMembers(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/FamilyMembers' })
      .catch((err: BusinessError): void => {
        console.error('push FamilyMembers failed: ' + err.message);
      });
  }

  static familyDirectory(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/FamilyDirectoryView' })
      .catch((err: BusinessError): void => {
        console.error('push FamilyDirectoryView failed: ' + err.message);
      });
  }

  /** 申请页：familyId 为空表示从「我的申请」进入（不带具体谱） */
  static accessApply(ui: UIContext, familyId: string): void {
    const params: AccessParams = new AccessParams();
    params.familyId = familyId;
    ui.getRouter().pushUrl({ url: 'pages/AccessApply', params: params })
      .catch((err: BusinessError): void => {
        console.error('push AccessApply failed: ' + err.message);
      });
  }

  static graveMap(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/GraveMap' })
      .catch((err: BusinessError): void => {
        console.error('push GraveMap failed: ' + err.message);
      });
  }

  static changeReview(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/ChangeReview' })
      .catch((err: BusinessError): void => {
        console.error('push ChangeReview failed: ' + err.message);
      });
  }

  /**
   * 打开外部地图导航到指定坐标（寻墓场景）。
   * 使用 UIAbilityContext.openLink 调起系统地图；未安装地图应用时会失败。
   */
  static openMap(lng: number, lat: number, label: string): void {
    const context: common.UIAbilityContext | null = GenealogyScope.context();
    if (context === null || context === undefined) {
      return;
    }
    const uri: string = 'geo:' + lat.toString() + ',' + lng.toString() + '?q=' +
      encodeURIComponent(label) + '&z=16';
    const options: Want = { action: 'ohos.want.action.viewData', uri: uri };
    context.openLink(uri, options)
      .catch((err: BusinessError): void => {
        console.error('open geo link failed: ' + err.message);
      });
  }

  static back(ui: UIContext): void {
    ui.getRouter().back();
  }
}
