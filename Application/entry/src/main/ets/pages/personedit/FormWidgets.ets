import { T, Theme, Spacing, uiFontFamily } from 'common_base';

/** 字段标签：标题 + 可选必填星号 + 说明 */
@Component
export struct FormLabel {
  @Prop text: string = '';
  @Prop required: boolean = false;
  @Prop hint: string = '';

  build() {
    Column() {
      Row() {
        Text(T(this.text)).fontFamily(uiFontFamily()).fontSize(13).fontColor(Theme.ink)
          .fontWeight(FontWeight.Medium)
        if (this.required) {
          Text(T(' *')).fontFamily(uiFontFamily()).fontSize(13).fontColor(Theme.danger)
        }
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
  }
}

/** 数字步进字段（- / 输入框 / +） */
@Component
export struct NumberFieldRow {
  @Prop label: string = '';
  @Prop value: number = 0;
  @Prop hint: string = '';
  @Prop min: number = 0;
  @Prop max: number = 999;
  onChange: (v: number) => void = (v: number): void => {
  };

  build() {
    Column() {
      FormLabel({ text: this.label, required: false, hint: this.hint })
      Row() {
        Button('-')
          .width(36)
          .height(36)
          .fontSize(16)
          .backgroundColor(Theme.field)
          .fontColor(Theme.ink)
          .borderRadius(8)
          .onClick((): void => {
            const v: number = Math.max(this.min, this.value - 1);
            this.onChange(v);
          })
        TextInput({ text: this.value.toString() })
          .fontFamily(uiFontFamily())
          .height(36)
          .fontSize(14)
          .backgroundColor(Theme.field)
          .fontColor(Theme.ink)
          .borderRadius(8)
          .textAlign(TextAlign.Center)
          .width(60)
          .margin({ left: Spacing.S, right: Spacing.S })
          .onChange((v: string): void => {
            const n: number = parseInt(v, 10);
            if (!isNaN(n)) {
              this.onChange(Math.max(this.min, Math.min(this.max, n)));
            }
          })
        Button('+')
          .width(36)
          .height(36)
          .fontSize(16)
          .backgroundColor(Theme.field)
          .fontColor(Theme.ink)
          .borderRadius(8)
          .onClick((): void => {
            const v: number = Math.min(this.max, this.value + 1);
            this.onChange(v);
          })
      }
      .width('100%')
    }
    .width('100%')
    .margin({ bottom: Spacing.M })
  }
}

/** 布尔开关字段 */
@Component
export struct FormToggleRow {
  @Prop label: string = '';
  @Prop value: boolean = false;
  @Prop hint: string = '';
  onChange: (v: boolean) => void = (v: boolean): void => {
  };

  build() {
    Column() {
      FormLabel({ text: this.label, required: false, hint: this.hint })
      Row() {
        Toggle({ type: ToggleType.Switch, isOn: this.value })
          .selectedColor(Theme.primary)
          .onChange((isOn: boolean): void => {
            this.onChange(isOn);
          })
        Text(this.value ? '是' : '否')
          .fontSize(14)
          .fontColor(Theme.ink)
          .margin({ left: Spacing.S })
      }
      .width('100%')
      .height(40)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .margin({ bottom: Spacing.M })
  }
}

/** 表单分节标题 */
@Component
export struct GroupHeaderRow {
  @Prop title: string = '';
  @Prop icon: string = '';

  build() {
    Row() {
      Text(T(this.icon)).fontFamily(uiFontFamily()).fontSize(15)
      Text(T(this.title)).fontFamily(uiFontFamily()).fontSize(15).fontWeight(FontWeight.Medium)
        .fontColor(Theme.primary).margin({ left: 6 })
    }
    .width('100%')
    .padding({ top: Spacing.L, bottom: Spacing.S })
  }
}
