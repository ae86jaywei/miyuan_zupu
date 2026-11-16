import { Theme, Spacing } from '../theme/Theme';
import { T, uiFontFamily } from '../service/ScriptService';
import { SettingsView } from '../view/SettingsView';
import { BackButton } from '../components/BackButton';

/**
 * 独立设置页（大屏 / 从顶栏进入时使用）。
 */
@Entry
@Component
struct Settings {
  /** 订阅简繁设置：切换后重绘（T() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
  @StorageProp('windowWidth') windowWidth: number = 360;
  @StorageProp('gpVersion') version: number = 0;

  build() {
    Column() {
      Row() {
        BackButton({
          onBack: (): void => {
            this.getUIContext().getRouter().back();
          }
        })
        Text(T('设置')).fontFamily(uiFontFamily())
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
