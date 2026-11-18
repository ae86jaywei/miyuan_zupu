import { T, uiFontFamily } from '../../service/ScriptService';
import { Theme, Spacing } from '../../theme/Theme';

/**
 * 日期输入 + “选择”按钮。
 * 同样使用 @Prop 绑定，日历面板确认后父组件状态变化会立即回填到输入框。
 */
@Component
export struct DateFieldInput {
  @Prop label: string = '';
  @Prop hint: string = '';
  @Prop value: string = '';
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  onChange: (v: string) => void = (v: string): void => {};
  onPick: () => void = (): void => {};

  onDark(): void {
    Theme.use(this.darkMode);
  }

  build() {
    Column() {
      Column() {
        Row() {
          Text(T(this.label)).fontFamily(uiFontFamily()).fontSize(13).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
        }
        .width('100%')
        if (this.hint.length > 0) {
          Text(T(this.hint)).fontFamily(uiFontFamily())
            .fontSize(10.5)
            .fontColor(Theme.inkTertiary)
            .width('100%')
            .margin({ top: 1 })
        }
      }
      .width('100%')
      .margin({ bottom: 4 })

      Row() {
        TextInput({ text: this.value, placeholder: T('点击右侧“选择”，或直接输入') }).fontFamily(uiFontFamily())
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor(Theme.ink)
          .placeholderColor(Theme.inkTertiary)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .onChange((v: string): void => {
            this.onChange(v);
          })
        Text(T('📅 选择')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor('#FFFFFF')
          .backgroundColor(Theme.primary)
          .padding({ left: 10, right: 10, top: 11, bottom: 11 })
          .borderRadius(14)
          .margin({ left: Spacing.S })
          .onClick((): void => {
            this.onPick();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .margin({ bottom: Spacing.M })
  }
}