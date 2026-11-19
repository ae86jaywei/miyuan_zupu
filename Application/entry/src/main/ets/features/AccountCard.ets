import { T, uiFontFamily, ScriptService } from 'common_base';
import { SR } from '../service/ServiceRegistry';

import { Theme, Spacing } from 'common_base';
import { TS } from 'common_ui';
import { AccountService } from '../service/AccountService';
import { RouterUtil } from 'common_base';

/**
 * 设置页“账号与云同步”卡片：
 * 华为账号登录状态与云服务状态。
 * 家族协作、分享邀请的入口统一收敛到下面的「家族协作」分组。
 */
@Component
export struct AccountCard {
  /** 订阅简繁设置：切换后重绘（this.tr() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
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

  /** 本卡片简繁文案：显式读取 this.script 建立刷新依赖，切换文字后即时更新 */
  private tr(text: string): string {
    return this.script === ScriptService.HANT ? ScriptService.getInstance().toTraditional(text)
      : ScriptService.getInstance().toSimplified(text);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: this.tr(message), duration: 2500 });
  }

  private async doLogout(): Promise<void> {
    this.getUIContext().showAlertDialog({
      title: this.tr('退出登录'),
      message: this.tr('退出后本地族谱仍保留，云端数据不会删除，可随时重新登录。'),
      primaryButton: {
        value: this.tr('取消'),
        action: () => {
        }
      },
      secondaryButton: {
        value: this.tr('退出'),
        fontColor: Theme.primary,
        action: async () => {
          await SR.account().logout();
          this.toast('已退出登录');
        }
      }
    });
  }

  build() {
    Column() {
      TS({ title: this.tr('账号与云同步'), subtitle: '华为账号登录 · 云服务状态', icon: '☁️' })
      Column() {
        Row() {
          Text(this.tr(this.loggedIn ? '已登录' : '未登录')).fontFamily(uiFontFamily())
            .fontSize(13)
            .fontColor(this.loggedIn ? Theme.primary : Theme.inkTertiary)
            .backgroundColor(this.loggedIn ? Theme.field : Theme.paperDeep)
            .borderRadius(10)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          Text(this.tr(this.loggedIn ? '华为账号 ' + SR.account().getDisplayId() : '登录后可加入家族协作、共享族谱')).fontFamily(uiFontFamily())
            .fontSize(13)
            .fontColor(Theme.ink)
            .layoutWeight(1)
            .margin({ left: Spacing.S })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')

        Text(this.tr('UnionID 映射账号：' + (this.userId.length > 0 ? this.userId : '未登录'))).fontFamily(uiFontFamily())
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row() {
          if (!this.loggedIn) {
            Button(this.tr('华为账号登录')).fontFamily(uiFontFamily())
              .height(38)
              .fontSize(14)
              .backgroundColor(Theme.primary)
              .fontColor(Theme.onPrimary)
              .layoutWeight(1)
              .enabled(!this.busy)
              .onClick((): void => {
                RouterUtil.login(this.getUIContext());
              })
          } else {
            Button(this.tr('退出登录')).fontFamily(uiFontFamily())
              .height(38)
              .fontSize(14)
              .backgroundColor(Theme.field)
              .fontColor(Theme.inkSecondary)
              .layoutWeight(1)
              .enabled(!this.busy)
              .onClick((): void => {
                this.doLogout();
              })
          }
        }
        .width('100%')
        .margin({ top: Spacing.M })

        Text(this.tr('云服务：' + (this.cloudMsg.length > 0 ? this.cloudMsg : '未初始化'))).fontFamily(uiFontFamily())
          .fontSize(11)
          .fontColor(this.cloudReady ? Theme.gold : Theme.inkTertiary)
          .width('100%')
          .margin({ top: Spacing.S })
          .maxLines(2)

        if (this.progressText.length > 0) {
          Text(this.tr(this.progressText)).fontFamily(uiFontFamily())
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
