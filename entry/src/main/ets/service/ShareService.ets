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
  /** 云端族谱ID（0 表示旧版邀请码，不做族谱过滤） */
  bookKey: number = 0;
  valid: boolean = false;
}

/**
 * 族谱分享服务。
 *
 * 无公网域名时采用「文本 + 邀请码」方案：通过系统分享面板把文本发送给接收方，
 * 接收方打开觅源 App 后在「查看分享的族谱」页录入邀请码，按族谱归属只读查询云端数据。
 * 邀请码格式：{familyId}.{ownerUserId}.{bookKey}，三段均不可猜测；
 * 旧版两段邀请码仍可解析，但不做族谱过滤。
 */
export class ShareService {
  /** 生成邀请码：族谱ID.账号标识.族谱序号，分享只覆盖选中的一部族谱 */
  static buildInviteCode(familyId: string, ownerUserId: string, bookKey: number): string {
    if (bookKey > 0) {
      return familyId + '.' + ownerUserId + '.' + bookKey.toString();
    }
    return familyId + '.' + ownerUserId;
  }

  /** 解析用户录入的邀请码 */
  static parseInviteCode(code: string): InviteInfo {
    const info: InviteInfo = new InviteInfo();
    const trimmed: string = code.trim();
    const parts: string[] = trimmed.split('.');
    if (parts.length < 2) {
      return info;
    }
    const family: string = parts[0];
    const owner: string = parts[1];
    if (family.length === 0 || !owner.startsWith('hw-')) {
      return info;
    }
    info.familyId = family;
    info.ownerUserId = owner;
    // 第三段为云端族谱ID，旧版两段邀请码保持兼容（不做族谱过滤）
    if (parts.length >= 3) {
      const bookKey: number = Number.parseInt(parts[2], 10);
      if (!Number.isNaN(bookKey) && bookKey > 0) {
        info.bookKey = bookKey;
      }
    }
    info.valid = true;
    return info;
  }

  /** 拼装分享文本 */
  static buildShareText(title: string, familyId: string, ownerUserId: string,
    bookKey: number): string {
    const code: string = ShareService.buildInviteCode(familyId, ownerUserId, bookKey);
    return '【觅源 · 族谱分享】\n族谱：' + title + '\n邀请码：\n' + code
      + '\n\n查看方式：打开「觅源」App → 设置 → 查看他人的分享，输入邀请码即可只读查看（需登录华为账号）。';
  }

  /** 拉起系统分享面板，发送所选族谱的邀请码文本 */
  static async shareGenealogy(context: common.UIAbilityContext, title: string,
    familyId: string, ownerUserId: string, bookKey: number): Promise<void> {
    const text: string = ShareService.buildShareText(title, familyId, ownerUserId, bookKey);
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
