import { TREE_STYLES, TreeStyleMeta } from '../model/Enums';
import { Theme } from '../theme/Theme';
import { Breakpoint } from '../common/Constants';

/**
 * 谱式切换器：五种谱式横向切换，宽屏显示说明文字，窄屏仅显示名称。
 */
@Component
export struct StyleSwitcher {
  @Prop current: string = 'eu';
  @Prop windowWidth: number = 360;
  onSelect: (style: string) => void = (style: string): void => {};

  private showDesc(): boolean {
    return this.windowWidth >= Breakpoint.SM;
  }

  build() {
    Column() {
      Row() {
        ForEach(TREE_STYLES, (meta: TreeStyleMeta) => {
          Column() {
            Text(meta.name)
              .fontSize(this.windowWidth < Breakpoint.SM ? 13 : 14)
              .fontWeight(this.current === meta.key ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(this.current === meta.key ? '#FFFFFF' : Theme.inkSecondary)
            Text(meta.subtitle)
              .fontSize(9.5)
              .fontColor(this.current === meta.key ? '#F3DDB0' : Theme.inkTertiary)
              .margin({ top: 1 })
              .maxLines(1)
          }
          .layoutWeight(1)
          .padding({ top: 8, bottom: 8 })
          .backgroundColor(this.current === meta.key ? Theme.primary : Color.Transparent)
          .borderRadius(10)
          .margin({ left: 2, right: 2 })
          .onClick((): void => {
            this.onSelect(meta.key);
          })
        }, (meta: TreeStyleMeta) => 'style_' + meta.key)
      }
      .width('100%')
      .padding(3)
      .backgroundColor(Theme.card)
      .borderRadius(12)
      .border({ width: 0.5, color: Theme.line })

      if (this.showDesc()) {
        Text(this.currentDesc())
          .fontSize(11.5)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 6 })
          .width('100%')
      }
    }
    .width('100%')
  }

  private currentDesc(): string {
    for (let i: number = 0; i < TREE_STYLES.length; i++) {
      if (TREE_STYLES[i].key === this.current) {
        return TREE_STYLES[i].desc;
      }
    }
    return '';
  }
}
