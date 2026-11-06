import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Spacing } from '../theme/Theme';
import { TS } from '../components/TS';
import { AccountService, LoginOutcome } from '../service/AccountService';
import { CloudSyncService } from '../service/CloudSyncService';
import { BackupResult } from '../model/CloudModels';
import { GenealogyService } from '../service/GenealogyService';
import { ShareService } from '../service/ShareService';
import { RouterUtil } from '../util/RouterUtil';
import { FamilyService } from '../service/FamilyService';
import { FamilySummary } from '../model/FamilyDomain';
import { Genealogy } from '../model/Genealogy';

/**
 * 设置页“账号与云同步”卡片：
 * 华为账号登录状态、家族协作入口、分享族谱。
 */
@Component
export struct AccountCard {
  @StorageProp('darkMode') darkMode: boolean = false;
  @StorageProp('gpLogin') loggedIn: boolean = false;
  @StorageProp('gpUserId') userId: string = '';
  @StorageProp('gpCloudReady') cloudReady: boolean = false;
  @StorageProp('gpCloudMsg') cloudMsg: string = '';

  @State busy: boolean = false;
  @State progressText: string = '';

  aboutToAppear(): void {
    Theme.use(this.darkMode);
  }

  private hostContext(): common.UIAbilityContext | null {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === null) {
      return null;
    }
    return ctx as common.UIAbilityContext;
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2500 });
  }

  private async doLogin(): Promise<void> {
    if (this.busy) {
      return;
    }
    const ctx: common.UIAbilityContext | null = this.hostContext();
    if (ctx === null) {
      return;
    }
    await AccountService.getInstance().init(ctx);
    this.busy = true;
    this.progressText = '正在登录华为账号…';
    const outcome: LoginOutcome = await AccountService.getInstance().login();
    this.busy = false;
    this.progressText = '';
    this.toast(outcome.message);
  }

  private async doLogout(): Promise<void> {
    this.getUIContext().showAlertDialog({
      title: '退出登录',
      message: '退出后本地族谱仍保留，云端数据不会删除，可随时重新登录。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: Theme.primary,
        action: async () => {
          await AccountService.getInstance().logout();
          this.toast('已退出登录');
        }
      }
    });
  }

  private async doBackup(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (!this.cloudReady) {
      this.toast(this.cloudMsg.length > 0 ? this.cloudMsg : '云服务未就绪');
      return;
    }
    // 备份不会改动本机数据，但若发现ID与亲属关系错位，先提醒用户核对
    const report = GenealogyService.getInstance().checkIntegrity();
    if (report.hasError()) {
      this.getUIContext().showAlertDialog({
        title: '数据一致性提示',
        message: report.summary() + '\n\n' + report.detail(5) +
          '\n\n备份只是上传，不会修改本机数据；但建议先核对相关人员编号与亲属关系。',
        primaryButton: {
          value: '先处理',
          action: () => {
          }
        },
        secondaryButton: {
          value: '仍然备份',
          fontColor: Theme.primary,
          action: async () => {
            await this.runBackup();
          }
        }
      });
      return;
    }
    await this.runBackup();
  }

  private async runBackup(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.progressText = '准备上传…';
    try {
      const result: BackupResult = await CloudSyncService.getInstance().backupAll(
        (message: string, done: number, total: number): void => {
          this.progressText = message + ' ' + done.toString() + '/' + total.toString();
        });
      let text: string = '备份完成：成员 ' + result.memberCount.toString()
        + ' 位，媒体 ' + result.mediaUploaded.toString() + ' 个';
      if (result.mediaSkipped > 0) {
        text += '，跳过 ' + result.mediaSkipped.toString() + ' 个';
      }
      if (result.warnings.length > 0) {
        text += '\n' + result.warnings[0];
      }
      this.progressText = text;
      this.toast('云端备份完成');
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.progressText = '备份失败：' + (be.message !== undefined ? be.message : '请检查网络与云服务配置');
      this.toast(this.progressText);
    } finally {
      this.busy = false;
    }
  }

  private async doShare(): Promise<void> {
    if (!this.loggedIn) {
      this.toast('请先登录华为账号');
      RouterUtil.login(this.getUIContext());
      return;
    }
    const svc: GenealogyService = GenealogyService.getInstance();
    const bookKey: number = svc.getCurrentBookId();
    if (bookKey <= 0) {
      this.toast('请先在「谱系」中创建族谱后再分享');
      return;
    }
    const ctx: common.UIAbilityContext | null = this.hostContext();
    if (ctx === null) {
      return;
    }
    // 已接入云家族：直接分享加入码，不依赖旧的云端备份通道
    const book: Genealogy = GenealogyService.getInstance().getBook();
    if (book.familyId.length > 0) {
      await this.openShare(ctx, bookKey);
      return;
    }
    // 旧只读分享内容读取自云端：先检测当前族谱是否已备份
    let cloudCount: number = 0;
    let queryFailed: boolean = false;
    try {
      cloudCount = await CloudSyncService.getInstance().countBookMembers(this.userId, bookKey);
    } catch (err) {
      queryFailed = true;
    }
    if (!queryFailed && cloudCount === 0) {
      this.getUIContext().showAlertDialog({
        title: '当前族谱尚未备份',
        message: '分享内容读取自云端，当前族谱还没有备份，接收方将看不到任何族人。是否先备份再分享？',
        primaryButton: {
          value: '取消',
          action: () => {
          }
        },
        secondaryButton: {
          value: '先备份并分享',
          fontColor: Theme.primary,
          action: async () => {
            await this.backupThenShare(ctx, bookKey);
          }
        }
      });
      return;
    }
    await this.openShare(ctx, bookKey);
  }

  /** 先备份当前族谱，确认云端已有数据后再分享 */
  private async backupThenShare(ctx: common.UIAbilityContext, bookKey: number): Promise<void> {
    await this.doBackup();
    let count: number = 0;
    try {
      count = await CloudSyncService.getInstance().countBookMembers(this.userId, bookKey);
    } catch (err) {
      count = 0;
    }
    if (count === 0) {
      this.toast('备份未完成，暂无法分享');
      return;
    }
    await this.openShare(ctx, bookKey);
  }

  /**
   * 拉起系统分享面板（方案 §十三 门槛②）。
   *
   * 新口径：已接入云家族时分享**加入码**（接收方加入后即获得 Membership）；
   * 未接入时仍走旧的"邀请码只读查看"，并明确其依赖老权限、将被下线。
   */
  private async openShare(ctx: common.UIAbilityContext, bookKey: number): Promise<void> {
    const book: Genealogy = GenealogyService.getInstance().getBook();
    try {
      if (book.familyId.length > 0) {
        const code: string = await this.resolveInviteCode(book.familyId);
        if (code.length === 0) {
          this.toast('暂时取不到加入码，请到「我的家族 → 成员与访问申请」里查看');
          return;
        }
        await ShareService.shareJoinInvite(ctx, book.title, code);
        return;
      }
      await ShareService.shareGenealogy(ctx, book.title,
        AccountService.getInstance().getFamilyId(), this.userId, bookKey);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.toast('分享未完成：' + (be.message !== undefined ? be.message : '用户取消'));
    }
  }

  /** 取当前家族的加入码（仅谱主可读，成员管理页也有） */
  private async resolveInviteCode(familyId: string): Promise<string> {
    if (!FamilyService.getInstance().isOwnerCurrent()) {
      return '';
    }
    try {
      const list: FamilySummary[] = await FamilyService.getInstance().listMine();
      for (let i: number = 0; i < list.length; i++) {
        if (list[i].familyId === familyId && list[i].inviteCode.length > 0) {
          return list[i].inviteCode;
        }
      }
    } catch (err) {
      return '';
    }
    return '';
  }

  build() {
    Column() {
      TS({ title: '账号与云同步', subtitle: '华为账号登录 · 家族协作 · 分享邀请', icon: '☁️' })
      Column() {
        Row() {
          Text(this.loggedIn ? '已登录' : '未登录')
            .fontSize(13)
            .fontColor(this.loggedIn ? Theme.primary : Theme.inkTertiary)
            .backgroundColor(this.loggedIn ? Theme.field : Theme.paperDeep)
            .borderRadius(10)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          Text(this.loggedIn ? '华为账号 ' + AccountService.getInstance().getDisplayId() : '登录后可加入家族协作、共享族谱')
            .fontSize(13)
            .fontColor(Theme.ink)
            .layoutWeight(1)
            .margin({ left: Spacing.S })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')

        Text('UnionID 映射账号：' + (this.userId.length > 0 ? this.userId : '未登录'))
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row() {
          if (!this.loggedIn) {
            Button('华为账号登录')
              .height(38)
              .fontSize(14)
              .backgroundColor(Theme.primary)
              .fontColor('#FFFFFF')
              .layoutWeight(1)
              .enabled(!this.busy)
              .onClick((): void => {
                RouterUtil.login(this.getUIContext());
              })
          } else {
            Button('退出登录')
              .height(38)
              .fontSize(14)
              .backgroundColor(Theme.field)
              .fontColor(Theme.inkSecondary)
              .layoutWeight(1)
              .enabled(!this.busy)
              .onClick((): void => {
                this.doLogout();
              })
            Button('分享 / 邀请加入')
              .height(38)
              .fontSize(14)
              .backgroundColor(Theme.primary)
              .fontColor('#FFFFFF')
              .layoutWeight(1)
              .margin({ left: Spacing.S })
              .enabled(!this.busy)
              .onClick((): void => {
                this.doShare();
              })
          }
        }
        .width('100%')
        .margin({ top: Spacing.M })

        Row() {
          Button('我的家族')
            .height(36)
            .fontSize(13)
            .layoutWeight(1)
            .backgroundColor(Theme.field)
            .fontColor(Theme.primary)
            .onClick((): void => {
              RouterUtil.familyHome(this.getUIContext());
            })
          Button('族谱黄页')
            .height(36)
            .fontSize(13)
            .layoutWeight(1)
            .margin({ left: Spacing.S })
            .backgroundColor(Theme.field)
            .fontColor(Theme.primary)
            .onClick((): void => {
              RouterUtil.familyDirectory(this.getUIContext());
            })
        }
        .width('100%')
        .margin({ top: Spacing.S })

        Text('云服务：' + (this.cloudMsg.length > 0 ? this.cloudMsg : '未初始化'))
          .fontSize(11)
          .fontColor(this.cloudReady ? Theme.gold : Theme.inkTertiary)
          .width('100%')
          .margin({ top: Spacing.S })
          .maxLines(2)

        if (this.progressText.length > 0) {
          Text(this.progressText)
            .fontSize(11)
            .fontColor(Theme.inkSecondary)
            .width('100%')
            .margin({ top: Spacing.S })
            .maxLines(4)
        }
      }
      .width('100%')
      .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
      .backgroundColor(Theme.card)
      .borderRadius(16)
      .border({ width: 0.5, color: Theme.line })
      .margin({ bottom: Spacing.M })
      .clip(true)
    }
    .width('100%')
  }
}
