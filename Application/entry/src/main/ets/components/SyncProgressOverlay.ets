import { Theme } from '../theme/Theme';

/**
 * 云同步进度浮层。
 * 视觉与「导入/导出」页的进度弹窗保持一致：转圈 + 阶段文案 + 线性进度条 + 百分比。
 * 浮层盖住页面并吞掉点击，避免同步过程中切页或重复触发。
 */
@Component
export struct SyncProgressOverlay {
  @Prop text: string = '';
  @Prop percent: number = 0;
  @Prop hint: string = '请停在此页，完成前不要退出或切换';

  build() {
    Column() {
      Column() {
        LoadingProgress().width(34).height(34).color(Theme.primary)
        Text(this.text)
          .fontSize(13)
          .fontColor(Theme.ink)
          .margin({ top: 12 })
          .maxLines(3)
          .textAlign(TextAlign.Center)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Progress({ value: this.percent, total: 100, type: ProgressType.Linear })
          .color(Theme.primary)
          .backgroundColor(Theme.field)
          .width('100%')
          .height(6)
          .margin({ top: 14 })
        Text(this.percent.toString() + '%')
          .fontSize(12)
          .fontColor(Theme.primary)
          .margin({ top: 6 })
        Text(this.hint)
          .fontSize(10.5)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 10 })
      }
      .width('78%')
      .padding({ left: 24, right: 24, top: 24, bottom: 20 })
      .backgroundColor(Theme.card)
      .borderRadius(16)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#99000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.Block)
    .onClick((): void => {
      // 吞掉点击，防止穿透到下层页面
    })
  }
}
