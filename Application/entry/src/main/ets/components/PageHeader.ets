import { T, uiFontFamily } from '../service/ScriptService';
import { Theme, Spacing } from 'common_base';
import { BackButton } from './BackButton';

/**
 * 页面顶栏：返回 + 标题 + 可选右侧状态。
 * 统一各页手写的 Row + BackButton + Text，避免高度、底色、分割线不一致。
 * 需要多个操作按钮的页面（如人员编辑的删除/保存）可继续自定义顶栏。
 */
@Component
export struct PageHeader {
  @Prop title: string = '';
  @Prop trailingText: string = '';
  @Prop loading: boolean = false;
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  onBack: () => void = (): void => {};

  onDark(): void {
    Theme.use(this.darkMode);
  }

  build() {
    Row() {
      BackButton({
        onBack: (): void => {
          this.onBack();
        }
      })
      Text(T(this.title)).fontFamily(uiFontFamily())
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.ink)
        .layoutWeight(1)
      if (this.loading) {
        LoadingProgress().width(20).height(20).color(Theme.primary)
      }
      if (this.trailingText.length > 0) {
        Text(T(this.trailingText)).fontFamily(uiFontFamily())
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
      }
    }
    .width('100%')
    .height(34)
    .padding({ left: Spacing.S, right: Spacing.L })
    .backgroundColor(Theme.card)
    .border({ width: { bottom: 0.5 }, color: Theme.line })
  }
}