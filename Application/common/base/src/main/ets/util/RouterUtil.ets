import { UIContext } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { AccessParams, EditParams, GenealogyScope } from '../model/Scope';
import { AgreementParams, OnlineDocParams } from '../model/AgreementDoc';

/**
 * 路由封装（基于 UIContext.getRouter，替代已废弃的全局 router）。
 */
export class RouterUtil {
  static editPerson(ui: UIContext, uid: string, mode: string, presetParent: string): void {
    const params: EditParams = { mode: mode, uid: uid, presetParent: presetParent };
    ui.getRouter().pushUrl({ url: 'pages/PersonEdit', params: params })
      .catch((): void => {});
  }

  static settings(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/Settings' })
      .catch((): void => {});
  }

  static importExport(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/ImportExport' })
      .catch((): void => {});
  }

  static login(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/Login' })
      .catch((): void => {});
  }

  static sharedView(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/SharedView' })
      .catch((): void => {});
  }

  static familyHome(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/FamilyHome' })
      .catch((): void => {});
  }

  static familyMembers(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/FamilyMembers' })
      .catch((): void => {});
  }

  static familyDirectory(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/FamilyDirectoryView' })
      .catch((): void => {});
  }

  /** 申请页：familyId 为空表示从「我的申请」进入（不带具体谱） */
  static accessApply(ui: UIContext, familyId: string): void {
    const params: AccessParams = new AccessParams();
    params.familyId = familyId;
    ui.getRouter().pushUrl({ url: 'pages/AccessApply', params: params })
      .catch((): void => {});
  }

  static graveMap(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/GraveMap' })
      .catch((): void => {});
  }

  static changeReview(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/ChangeReview' })
      .catch((): void => {});
  }

  /** 万年历：公历/农历/干支/年号互查 */
  static calendar(ui: UIContext): void {
    ui.getRouter().pushUrl({ url: 'pages/CalendarPage' })
      .catch((): void => {});
  }

  /** 打开协议页：type 为 user（用户协议）或 privacy（隐私政策） */
  static agreement(ui: UIContext, type: string): void {
    const params: AgreementParams = new AgreementParams();
    params.type = type;
    ui.getRouter().pushUrl({ url: 'pages/Agreement', params: params })
      .catch((): void => {});
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
      .catch((): void => {});
  }

  /** 应用内打开在线协议（Web 页），避免跳转系统浏览器 */
  static onlineDoc(ui: UIContext, title: string, url: string): void {
    const params: OnlineDocParams = new OnlineDocParams();
    params.title = title;
    params.url = url;
    ui.getRouter().pushUrl({ url: 'pages/OnlineDoc', params: params })
      .catch((): void => {});
  }

  static back(ui: UIContext): void {
    ui.getRouter().back();
  }
}
