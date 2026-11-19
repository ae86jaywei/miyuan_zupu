import { T, Theme, Spacing, uiFontFamily } from 'common_base';

/** 纪年（年号）选择弹窗：全宽滚动列表，条目完整显示不截断 */
@Component
export struct EraPickerPanel {
  @Prop options: string[] = [];
  @Prop selected: number = 0;
  onSelect: (index: number) => void = (index: number): void => {
  };
  onClose: () => void = (): void => {
  };

  build() {
    Column() {
      Row() {
        Text(T('选择纪年（年号）')).fontFamily(uiFontFamily())
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
        Text(T('关闭')).fontFamily(uiFontFamily())
          .fontSize(14)
          .fontColor(Theme.primary)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick((): void => {
            this.onClose();
          })
      }
      .width('100%')
      .height(48)
      .padding({ left: Spacing.L, right: Spacing.L })
      .border({ width: { bottom: 0.5 }, color: Theme.line })

      List() {
        ForEach(this.options, (label: string, idx: number) => {
          ListItem() {
            Row() {
              Text(T(label)).fontFamily(uiFontFamily())
                .fontSize(14)
                .fontColor(idx === this.selected ? Theme.primary : Theme.ink)
                .fontWeight(idx === this.selected ? FontWeight.Medium : FontWeight.Normal)
                .layoutWeight(1)
              if (idx === this.selected) {
                Text('✓').fontFamily(uiFontFamily())
                  .fontSize(15)
                  .fontColor(Theme.primary)
              }
            }
            .width('100%')
            .padding({ left: Spacing.L, right: Spacing.L, top: 13, bottom: 13 })
            .backgroundColor(idx === this.selected ? Theme.highlightBg : Color.Transparent)
          }
          .onClick((): void => {
            this.onSelect(idx);
            this.onClose();
          })
        }, (label: string, idx: number) => 'era_' + idx.toString())
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .divider({ strokeWidth: 0.5, color: Theme.line })
    }
    .width('100%')
    .height('68%')
    .backgroundColor(Theme.card)
    .borderRadius({ topLeft: 20, topRight: 20 })
  }
}
