/**
 * 根据人物生成基础 SVG，用于族谱打印导出（可选）。
 * 注：ArkUI 渲染主要使用原生组件，此处保留给后续"导出图片"扩展。
 */
export class SvgUtil {
  static escape(s: string): string {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
}
