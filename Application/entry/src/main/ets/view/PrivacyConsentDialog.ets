import { Theme, Spacing } from '../theme/Theme';
import { APP_NAME, CONTACT_EMAIL, OPERATOR_NAME } from '../model/AgreementDoc';

/**
 * 首次启动隐私同意弹窗。
 *
 * 合规要求：
 * 1. 未同意前不得初始化族谱数据、不得登录账号；
 * 2. 必须提供「不同意」选项且不得默认勾选同意；
 * 3. 可点击查看《用户协议》《隐私政策》全文。
 */
@CustomDialog
export struct PrivacyConsentDialog {
  controller?: CustomDialogController;
  onAgree: () => void = (): void => {};
  onReject: () => void = (): void => {};
  onOpenDoc: (type: string) => void = (type: string): void => {};

  build() {
    Column() {
      Text('欢迎使用' + APP_NAME)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.ink)
        .width('100%')
      Text('个人信息保护提示')
        .fontSize(12.5)
        .fontColor(Theme.inkTertiary)
        .width('100%')
        .margin({ top: 4 })

      Scroll() {
        Column() {
          Text('我们深知个人信息对你的重要性。为向你提供族谱记录、谱系展示与家族协作服务，' +
            '我们会在你主动使用时处理以下信息：')
            .fontSize(12.5)
            .fontColor(Theme.inkSecondary)
            .lineHeight(19)
            .width('100%')
          Text('· 华为账号标识（UnionID），用于登录与账号隔离；\n' +
            '· 你录入或导入的族人信息（姓名、生卒、亲属关系、联系方式等）；\n' +
            '· 你主动上传的头像、家族相片与视频；\n' +
            '· 你主动标注祖墓位置时读取的经纬度与海拔；\n' +
            '· 必要的运行日志，用于排查故障。')
            .fontSize(12)
            .fontColor(Theme.inkSecondary)
            .lineHeight(19)
            .width('100%')
            .margin({ top: 8 })
          Text('族谱数据优先保存在本机；仅当你接入云家族并主动同步时，数据才会加密上传至华为云服务。' +
            '未经你同意，我们不会初始化或上传任何数据，也不会将你的信息用于广告推送或出售。')
            .fontSize(12)
            .fontColor(Theme.inkSecondary)
            .lineHeight(19)
            .width('100%')
            .margin({ top: 8 })
          Text('运营者：' + OPERATOR_NAME + '　联系邮箱：' + CONTACT_EMAIL)
            .fontSize(11)
            .fontColor(Theme.inkTertiary)
            .lineHeight(17)
            .width('100%')
            .margin({ top: 8 })
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: 230 })
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: Spacing.M })

      Row() {
        Text('我已阅读并同意')
          .fontSize(12)
          .fontColor(Theme.inkSecondary)
        Text('《用户协议》')
          .fontSize(12)
          .fontColor(Theme.primary)
          .onClick((): void => {
            this.onOpenDoc('user');
          })
        Text('和')
          .fontSize(12)
          .fontColor(Theme.inkSecondary)
        Text('《隐私政策》')
          .fontSize(12)
          .fontColor(Theme.primary)
          .onClick((): void => {
            this.onOpenDoc('privacy');
          })
      }
      .width('100%')
      .margin({ top: Spacing.M })

      Button('同意并继续')
        .width('100%')
        .height(42)
        .fontSize(15)
        .fontColor('#FFFFFF')
        .backgroundColor(Theme.primary)
        .borderRadius(10)
        .margin({ top: Spacing.S })
        .onClick((): void => {
          this.controller?.close();
          this.onAgree();
        })

      Button('不同意并退出')
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontColor(Theme.inkSecondary)
        .backgroundColor(Theme.field)
        .borderRadius(10)
        .margin({ top: Spacing.S })
        .onClick((): void => {
          this.controller?.close();
          this.onReject();
        })
    }
    .width('100%')
    .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.L, bottom: Spacing.L })
  }
}
