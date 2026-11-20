import { T, uiFontFamily } from 'common_base';
import { Theme, Spacing } from 'common_base';

/**
 * 下拉选择字段（原生 Select）。
 *
 * 这里必须用“子组件 + @Prop”而不是“@Builder 按值传参”：@Builder 的按值参数
 * 在父组件状态变化后不会刷新内部 UI，会导致“选了值但界面仍是默认值、清除无效”。
 *
 * 说明：
 *  - 整块 40vp 高度都可点击（不再用透明 Select + 覆盖层，避免点击落空）；
 *  - 箭头使用 SDK 默认样式，颜色跟随 fontColor，因此浅色 / 深色模式都能自适应；
 *  - options 为显示文案，keys 与之一一对应时 onValue 回传 keys[index]（如人物唯一ID）。
 */
@Component
export struct SelectField {
  /** 订阅简繁设置：切换后重绘（T() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
  @Prop label: string = '';
  @Prop hint: string = '';
  @Prop required: boolean = false;
  @Prop options: string[] = [];
  @Prop keys: string[] = [];
  @Prop value: string = '';
  @Prop clearable: boolean = false;
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  onValue: (v: string) => void = (v: string): void => {};

  onDark(): void {
    Theme.use(this.darkMode);
  }

  private buildOptions(): SelectOption[] {
    const list: SelectOption[] = [];
    this.options.forEach((o: string): void => {
      list.push({ value: o });
    });
    return list;
  }

  /** 当前值在选项中的下标（无 keys 时用文案反查，有 keys 时用值反查） */
  private selectedIndex(): number {
    const list: string[] = this.keys.length === this.options.length ? this.keys : this.options;
    const i: number = list.indexOf(this.value);
    return i < 0 ? 0 : i;
  }

  /** 按钮文字：优先显示候选文案，值不在候选中时回退显示原值 */
  private displayText(): string {
    if (this.value.length === 0) {
      return this.clearable ? '未选择' : '请选择';
    }
    const i: number = this.selectedIndex();
    if (i < this.options.length && this.valueAt(i) === this.value) {
      return this.options[i];
    }
    return this.value;
  }

  private valueAt(index: number): string {
    return this.keys.length === this.options.length ? this.keys[index] : this.options[index];
  }

  build() {
    Column() {
      Column() {
        Row() {
          Text(T(this.label)).fontFamily(uiFontFamily()).fontSize(13).fontColor(Theme.ink).fontWeight(FontWeight.Medium)
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

      Row() {
        Select(this.buildOptions())
          .selected(this.selectedIndex())
          .value(this.displayText())
          .font({ size: 14, weight: this.value.length > 0 ? FontWeight.Medium : FontWeight.Normal })
          .fontColor(this.value.length > 0 ? Theme.ink : Theme.inkTertiary)
          .optionFont({ size: 14 })
          .optionFontColor(Theme.ink)
          .optionBgColor(Theme.card)
          .selectedOptionFontColor(Theme.highlightAccent)
          .selectedOptionBgColor(Theme.selectedBg)
          .menuBackgroundColor(Theme.card)
          .backgroundColor(Theme.field)
          .borderRadius(8)
          .height(40)
          .layoutWeight(1)
          .optionWidth(OptionWidthMode.FIT_CONTENT)
          .menuAlign(MenuAlignType.START, { dx: 0, dy: 0 })
          .onSelect((index: number): void => {
            if (index >= 0 && index < this.options.length) {
              this.onValue(this.valueAt(index));
            }
          })
        if (this.clearable && this.value.length > 0) {
          Text(T('清除')).fontFamily(uiFontFamily())
            .fontSize(12)
            .fontColor(Theme.inkTertiary)
            .padding({ left: Spacing.M, top: 10, bottom: 10 })
            .onClick((): void => {
              this.onValue('');
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .margin({ bottom: Spacing.M })
  }
}