import { T, uiFontFamily } from 'common_base';
import { Theme, Spacing } from 'common_base';
import { FieldMeta, editorOptionsOf } from 'common_base';
import { SelectField } from './SelectField';

/**
 * 通用字段表单：由 FIELD_METAS 提供 label/hint/options，页面只负责取值与回写。
 *
 * 仍使用“子组件 + @Prop”而不是 @Builder 按值传参，避免父组件状态变化后
 * 内部 UI 不刷新（SelectField 已踩过该问题）。
 */
@Component
export struct PersonFieldForm {
  /** 订阅简繁设置：切换后重绘（T() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
  @Prop meta: FieldMeta = { key: '', label: '', hint: '', group: '', type: 'text', privacy: false };
  @Prop value: string = '';
  /** 覆盖 FIELD_METAS 的 hint（用于带计数的简介等动态提示） */
  @Prop hint: string = '';
  @Prop required: boolean = false;
  @Prop multiline: boolean = false;
  @Prop maxLength: number = 0;
  @Prop textAreaHeight: number = 140;
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  onValue: (v: string) => void = (v: string): void => {};

  onDark(): void {
    Theme.use(this.darkMode);
  }

  private hintText(): string {
    return this.hint.length > 0 ? this.hint : this.meta.hint;
  }

  private labelText(): string {
    return this.meta.label;
  }

  @Builder
  FieldLabel() {
    Column() {
      Row() {
        Text(T(this.labelText())).fontFamily(uiFontFamily()).fontSize(13).fontColor(Theme.ink)
          .fontWeight(FontWeight.Medium)
        if (this.required) {
          Text(T(' *')).fontFamily(uiFontFamily()).fontSize(13).fontColor(Theme.danger)
        }
      }
      .width('100%')
      if (this.hintText().length > 0) {
        Text(T(this.hintText())).fontFamily(uiFontFamily())
          .fontSize(10.5)
          .fontColor(Theme.inkTertiary)
          .width('100%')
          .margin({ top: 1 })
      }
    }
    .width('100%')
    .margin({ bottom: 4 })
  }

  build() {
    Column() {
      if (editorOptionsOf(this.meta.key).length > 0) {
        SelectField({
          label: this.meta.label,
          hint: this.hintText(),
          required: this.required,
          options: editorOptionsOf(this.meta.key),
          value: this.value,
          onValue: (v: string): void => {
            this.onValue(v);
          }
        })
      } else if (this.multiline) {
        this.FieldLabel()
        TextArea({ text: this.value })
          .fontFamily(uiFontFamily())
          .height(this.textAreaHeight)
          .fontSize(14)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .maxLength(this.maxLength > 0 ? this.maxLength : 100000)
          .onChange((v: string): void => {
            this.onValue(v);
          })
      } else {
        this.FieldLabel()
        TextInput({ text: this.value }).fontFamily(uiFontFamily())
          .height(40)
          .fontSize(14)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .onChange((v: string): void => {
            this.onValue(v);
          })
      }
    }
    .width('100%')
    .margin({ bottom: Spacing.M })
  }
}
