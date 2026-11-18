import { T, uiFontFamily } from '../../service/ScriptService';
import { Theme, Spacing } from '../../theme/Theme';

/**
 * 搜索输入框：统一各页的 38vp 高度、输入框底色、圆角与动作按钮样式。
 * actionText 为空时只显示输入框（即时搜索）；有值时在右侧显示动作按钮。
 */
@Component
export struct SearchField {
  @Prop text: string = '';
  @Prop placeholder: string = '';
  @Prop fontSize: number = 14;
  @Prop actionText: string = '';
  @Prop actionEnabled: boolean = true;
  @Prop marginTop: number = 0;
  @Prop marginBottom: number = 0;
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  onChange: (v: string) => void = (v: string): void => {};
  onSubmit: () => void = (): void => {};
  onAction: () => void = (): void => {};

  onDark(): void {
    Theme.use(this.darkMode);
  }

  build() {
    Row() {
      TextInput({ text: this.text, placeholder: T(this.placeholder) }).fontFamily(uiFontFamily())
        .height(38)
        .fontSize(this.fontSize)
        .layoutWeight(1)
        .backgroundColor(Theme.field)
        .borderRadius(10)
        .onChange((v: string): void => {
          this.onChange(v);
        })
        .onSubmit(() => {
          this.onSubmit();
        })
      if (this.actionText.length > 0) {
        Button(T(this.actionText)).fontFamily(uiFontFamily())
          .fontSize(13)
          .height(38)
          .margin({ left: Spacing.S })
          .backgroundColor(Theme.primary)
          .fontColor('#FFFFFF')
          .enabled(this.actionEnabled)
          .onClick((): void => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .margin({ top: this.marginTop, bottom: this.marginBottom })
  }
}