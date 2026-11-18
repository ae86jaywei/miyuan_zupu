/**
 * 印刷卡片专色：屏幕预览（PagedTree）与 PDF 栅格（PdfRasterJob）共用。
 * 原先两处各写一套近似色，容易出现「预览好看、导出偏色」，统一后所见即所得。
 */
export class PrintTheme {
  /** 纸面 */
  static readonly paper: string = '#FFFDF6';
  /** 卷名/标题浅底 */
  static readonly paperAlt: string = '#FBF1D6';
  /** 卡片浅底 */
  static readonly cardBg: string = '#F8F3E7';
  /** 装订区 */
  static readonly bind: string = '#F4EFE3';
  /** 正文墨色 */
  static readonly ink: string = '#2E2A24';
  /** 次级文字 */
  static readonly ink2: string = '#7A6A57';
  /** 谱牒金 */
  static readonly gold: string = '#C9A227';
  /** 朱红（卷名/印章） */
  static readonly red: string = '#B03A2E';
  /** 女性姓名 */
  static readonly female: string = '#A0527A';
  /** 女性浅底 */
  static readonly femaleSoft: string = '#FBF1F5';
  /** 表格线/虚线 */
  static readonly line: string = '#D8CBB2';
  /** 页脚 */
  static readonly foot: string = '#8C2F1E';
  /** 选中/高亮底 */
  static readonly highlight: string = '#FFF6E0';
  /** 纯白 */
  static readonly white: string = '#FFFFFF';
}