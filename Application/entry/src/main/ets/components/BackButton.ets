import { Theme } from '../theme/Theme';

/**
 * 二级页面统一返回按钮（‹）。
 *
 * 原先 ImportExport / Login / PersonEdit / Settings / SharedView 各自复制
 * 同一段返回按钮实现，抽取后样式与点击行为集中维护，避免各页面漂移。
 * 只负责“返回图标 + 点击回调”，不承载标题与右侧操作，保持与原实现等价。
 */
@Component
export struct BackButton {
  onBack: () => void = (): void => {};

  build() {
    Text('‹')
      .fontSize(22)
      .fontColor(Theme.ink)
      .width(32)
      .height(32)
      .textAlign(TextAlign.Center)
      .onClick((): void => {
        this.onBack();
      })
  }
}