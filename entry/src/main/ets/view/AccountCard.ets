import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Spacing } from '../theme/Theme';
import { TS } from '../components/TS';
import { AccountService, LoginOutcome } from '../service/AccountService';
import { CloudSyncService } from '../service/CloudSyncService';
import { BackupResult, CloudUsage, RestoreResult } from '../model/CloudModels';
import { GenealogyService } from '../service/GenealogyService';
import { ShareService } from '../service/ShareService';
import { RouterUtil } from '../util/RouterUtil';

/**
 * 设置页“账号与云同步”卡片：
 * 华为账号登录状态、云端备份/恢复、云端用量、清空云端数据、分享族谱。
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
  @State usageText: string = '';

  aboutToAppear(): void {
    Theme.use(this.darkMode);
    this.refreshUsage();
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
    if (outcome.success) {
      await this.refreshUsage();
    }
  }

  private async doLogout(): Promise<void> {
    this.getUIContext().showAlertDialog({
      title: '退出登录',
      message: '退出后本地族谱仍保留，云端数据不会删除，下次登录可继续恢复。',
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
          this.usageText = '';
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
      await this.refreshUsage();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.progressText = '备份失败：' + (be.message !== undefined ? be.message : '请检查网络与云服务配置');
      this.toast(this.progressText);
    } finally {
      this.busy = false;
    }
  }

  private doRestore(): void {
    if (this.busy) {
      return;
    }
    if (!this.cloudReady) {
      this.toast(this.cloudMsg.length > 0 ? this.cloudMsg : '云服务未就绪');
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '从云端恢复',
      message: '恢复会以云端记录覆盖本地族谱成员数据，媒体图片将按需下载。确定继续吗？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '恢复',
        fontColor: Theme.primary,
        action: async () => {
          await this.runRestore();
        }
      }
    });
  }

  private async runRestore(): Promise<void> {
    this.busy = true;
    this.progressText = '正在读取云端数据…';
    try {
      const result: RestoreResult = await CloudSyncService.getInstance().restoreAll(
        (message: string, done: number, total: number): void => {
          this.progressText = message + ' ' + done.toString() + '/' + total.toString();
        });
      this.progressText = '恢复完成：成员 ' + result.memberCount.toString()
        + ' 位，图片 ' + result.imageDownloaded.toString() + ' 张，视频待点播 '
        + result.videoDeferred.toString() + ' 个';
      this.toast('云端数据已恢复');
      await this.refreshUsage();
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.progressText = '恢复失败：' + (be.message !== undefined ? be.message : '云端暂无数据');
      this.toast(this.progressText);
    } finally {
      this.busy = false;
    }
  }

  private async refreshUsage(): Promise<void> {
    if (!this.cloudReady || !this.loggedIn) {
      this.usageText = '';
      return;
    }
    try {
      const usage: CloudUsage = await CloudSyncService.getInstance().getUsage();
      this.usageText = '云端：成员 ' + usage.memberCount.toString() + ' 位 · 图片 '
        + usage.imageCount.toString() + ' 张 · 视频 ' + usage.videoCount.toString()
        + ' 个 · 占用 ' + this.formatSize(usage.totalBytes);
    } catch (err) {
      this.usageText = '云端用量读取失败';
    }
  }

  private formatSize(bytes: number): string {
    if (bytes <= 0) {
      return '0 MB';
    }
    const mb: number = bytes / (1024 * 1024);
    if (mb >= 1024) {
      return (mb / 1024).toFixed(2) + ' GB';
    }
    return mb.toFixed(1) + ' MB';
  }

  private doPurge(): void {
    if (this.busy) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '清空云端数据',
      message: '将删除当前华为账号在云端的全部族谱、图片、视频与备份文件，且不可恢复。确定继续吗？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.primary,
        action: async () => {
          this.busy = true;
          this.progressText = '正在删除云端数据…';
          try {
            await CloudSyncService.getInstance().purgeCloudData();
            this.progressText = '云端数据已清空';
            this.toast('云端数据已清空');
            await this.refreshUsage();
          } catch (err) {
            const be: BusinessError = err as BusinessError;
            this.progressText = '删除失败：' + (be.message !== undefined ? be.message : '请稍后重试');
          } finally {
            this.busy = false;
          }
        }
      }
    });
  }

  private async doShare(): Promise<void> {
    if (!this.loggedIn) {
      this.toast('请先登录华为账号');
      RouterUtil.login(this.getUIContext());
      return;
    }
    const ctx: common.UIAbilityContext | null = this.hostContext();
    if (ctx === null) {
      return;
    }
    try {
      await ShareService.shareGenealogy(ctx, GenealogyService.getInstance().getBook().title,
        AccountService.getInstance().getFamilyId(), this.userId);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      this.toast('分享未完成：' + (be.message !== undefined ? be.message : '用户取消'));
    }
  }

  build() {
    Column() {
      TS({ title: '账号与云同步', subtitle: '华为账号登录 · 云端备份 · 换机恢复', icon: '☁️' })
      Column() {
        Row() {
          Text(this.loggedIn ? '已登录' : '未登录')
            .fontSize(13)
            .fontColor(this.loggedIn ? Theme.primary : Theme.inkTertiary)
            .backgroundColor(this.loggedIn ? Theme.field : Theme.paperDeep)
            .borderRadius(10)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          Text(this.loggedIn ? '华为账号 ' + AccountService.getInstance().getDisplayId() : '登录后可备份族谱与照片视频')
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
            Button('分享族谱')
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

        Button('查看他人的分享')
          .height(36)
          .width('100%')
          .fontSize(13)
          .backgroundColor(Theme.field)
          .fontColor(Theme.inkSecondary)
          .margin({ top: Spacing.S })
          .onClick((): void => {
            RouterUtil.sharedView(this.getUIContext());
          })

        Text('云服务：' + (this.cloudMsg.length > 0 ? this.cloudMsg : '未初始化'))
          .fontSize(11)
          .fontColor(this.cloudReady ? Theme.gold : Theme.inkTertiary)
          .width('100%')
          .margin({ top: Spacing.S })
          .maxLines(2)

        if (this.loggedIn && this.cloudReady) {
          Row() {
            Button(this.busy ? '处理中…' : '备份到云端')
              .height(36)
              .fontSize(13)
              .backgroundColor(Theme.field)
              .fontColor(Theme.primary)
              .layoutWeight(1)
              .enabled(!this.busy)
              .onClick((): void => {
                this.doBackup();
              })
            Button('从云端恢复')
              .height(36)
              .fontSize(13)
              .backgroundColor(Theme.field)
              .fontColor(Theme.primary)
              .layoutWeight(1)
              .margin({ left: Spacing.S })
              .enabled(!this.busy)
              .onClick((): void => {
                this.doRestore();
              })
            Button('清空云端')
              .height(36)
              .fontSize(13)
              .backgroundColor(Theme.field)
              .fontColor(Theme.inkSecondary)
              .layoutWeight(1)
              .margin({ left: Spacing.S })
              .enabled(!this.busy)
              .onClick((): void => {
                this.doPurge();
              })
          }
          .width('100%')
          .margin({ top: Spacing.M })

          if (this.usageText.length > 0) {
            Text(this.usageText)
              .fontSize(11)
              .fontColor(Theme.inkSecondary)
              .width('100%')
              .margin({ top: Spacing.S })
          }
        }

        if (this.progressText.length > 0) {
          Text(this.progressText)
            .fontSize(11)
            .fontColor(Theme.inkSecondary)
            .width('100%')
            .margin({ top: Spacing.S })
            .maxLines(4)
        }

        Text('云端未配置时：请将 AGC 生成的 agconnect-services.json 放入 AppScope/resources/rawfile，并在 AGC 控制台创建云数据库对象类型 FamilyMember / FamilyMedia 与存储区 zupu。')
          .fontSize(10)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .margin({ top: Spacing.S })
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
