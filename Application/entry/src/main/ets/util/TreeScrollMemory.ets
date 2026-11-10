/**
 * 谱式画布的滚动位置记忆。
 *
 * 五种谱式共用同一块谱系区域，切换谱式时列表组件会被重建：
 * 若新谱式沿用上一个谱式留下的滚动位置，就会直接定位到内容末尾之外的空白处，
 * 看起来像「谱式不显示」。因此在谱式切换器真正切换之前，先作废全部谱式的滚动位置，
 * 让新谱式从顶部开始。
 */
export class TreeScrollMemory {
  /** 各谱式滚动位置使用的 AppStorage 键；键不存在时对应列表本就从顶部开始 */
  private static readonly KEYS: string[] = ['pagodaScroll', 'modernScroll'];

  /** 作废全部谱式的滚动位置 */
  static resetAll(): void {
    for (let i: number = 0; i < TreeScrollMemory.KEYS.length; i = i + 1) {
      // 返回 false 表示键本就不存在，属于正常情况，无需处理
      AppStorage.delete(TreeScrollMemory.KEYS[i]);
    }
  }
}
