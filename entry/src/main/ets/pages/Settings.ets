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
          .fontSize(26)
          .fontColor(Theme.ink)
          .width(40)
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
      .height(52)
      .padding({ left: Spacing.S, right: Spacing.L })
      .backgroundColor(Theme.card)
      .border({ width: { bottom: 0.5 }, color: Theme.line })

      Column() {
        SettingsView({
          version: this.version
        })
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: Spacing.L, right: Spacing.L, top: Spacing.M })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.paper)
  }
}