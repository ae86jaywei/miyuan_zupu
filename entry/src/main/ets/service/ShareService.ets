import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = '[Genealogy][Share]';

/** 邀请码解析结果 */
export class InviteInfo {
  familyId: string = '';
  ownerUserId: string = '';
  valid: boolean = false;
}

/**
 * 族谱分享服务。
 *
 * 无公网域名时采用「文本 + 邀请码」方案：通过系统分享面板把文本发送给接收方，
 * 接收方打开觅源 App 后在「查看分享的族谱」页录入邀请码，按族谱归属只读查询云端数据。
 * 邀请码格式：{familyId}.{ownerUserId}，两段均不可猜测。
 */
export class ShareService {
  /** 生成邀请码 */
  static buildInviteCode(familyId: string, ownerUserId: string): string {
    return familyId + '.' + ownerUserId;
  }

  /** 解析用户录入的邀请码 */
  static parseInviteCode(code: string): InviteInfo {
    const info: InviteInfo = new InviteInfo();
    const trimmed: string = code.trim();
    const dot: number = trimmed.indexOf('.');
    if (dot <= 0 || dot >= trimmed.length - 1) {
      return info;
    }
    const owner: string = trimmed.substring(dot + 1);
    if (!owner.startsWith('hw-')) {
      return info;
    }
    info.familyId = trimmed.substring(0, dot);
    info.ownerUserId = owner;
    info.valid = true;
    return info;
  }

  /** 拼装分享文本 */
  static buildShareText(title: string, familyId: string, ownerUserId: string): string {
    const code: string = ShareService.buildInviteCode(familyId, ownerUserId);
    return '【觅源 · 族谱分享】\n族谱：' + title + '\n邀请码：\n' + code
      + '\n\n查看方式：打开「觅源」App → 设置 → 查看他人的分享，输入邀请码即可只读查看（需登录华为账号）。';
  }

  /** 拉起系统分享面板，发送族谱邀请码文本 */
  static async shareGenealogy(context: common.UIAbilityContext, title: string,
    familyId: string, ownerUserId: string): Promise<void> {
    const text: string = ShareService.buildShareText(title, familyId, ownerUserId);
    const sharedData: systemShare.SharedData = new systemShare.SharedData({
      utd: uniformTypeDescriptor.UniformDataType.PLAIN_TEXT,
      content: text,
      title: '觅源族谱分享：' + title,
      description: '接收方在应用内输入邀请码即可只读查看'
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(sharedData);
    await controller.show(context, {
      selectionMode: systemShare.SelectionMode.SINGLE,
      previewMode: systemShare.SharePreviewMode.DEFAULT
    });
  }

  /** 分享导出文件（PDF / GEDCOM / JSON 等） */
  static async shareFile(context: common.UIAbilityContext, fileUri: string,
    title: string, utd: string): Promise<void> {
    const sharedData: systemShare.SharedData = new systemShare.SharedData({
      utd: utd,
      uri: fileUri,
      title: title
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(sharedData);
    await controller.show(context, {
      selectionMode: systemShare.SelectionMode.SINGLE,
      previewMode: systemShare.SharePreviewMode.DETAIL
    });
  }

  static logError(err: BusinessError): void {
    hilog.error(0x0000, TAG, 'share failed code=%{public}d msg=%{public}s', err.code, err.message);
  }
}
