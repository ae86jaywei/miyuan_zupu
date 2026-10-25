import { Theme, Spacing } from '../theme/Theme';
import { SettingsView } from '../view/SettingsView';

/**
 * 独立设置页（大屏 / 从顶栏进入时使用）。
 */
@Entry
@Component
struct Settings {
  @StorageProp('windowWidth') windowWidth: number = 360;
  @StorageProp('gpVersion') version: number = 0;

  build() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(22)
          .fontColor(Theme.ink)
          .width(32)
          .height(32)
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.getUIContext().getRouter().back();
          })
        Text('设置')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
      }
      .width('100%')
      .height(34)
      .padding({ left: Spacing.S, right: Spacing.L })
      .backgroundColor(Theme.card)
      .border({ width: { bottom: 0.5 }, color: Theme.line })

      Column() {
        SettingsView({
          windowWidth: this.windowWidth,
          version: this.version
        })
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: Spacing.L, right: Spacing.L, top: 0 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.paper)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // 独立设置页：旋转后同步窗口宽度，断点信息与宽屏布局随之刷新
      const w: number = Number(newValue.width);
      if (w > 0 && Math.abs(w - this.windowWidth) > 1) {
        AppStorage.setOrCreate<number>('windowWidth', w);
      }
    })
  }
}