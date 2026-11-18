/**
 * 全局常量：设备形态断点、枚举值、字段长度约束。
 */

/** HarmonyOS 响应式一多断点（单位 vp） */
export class Breakpoint {
  static readonly XS: number = 320;
  static readonly SM: number = 600;
  static readonly MD: number = 840;
  static readonly LG: number = 1200;
  static readonly XL: number = 1600;
}

/** 设备形态标识（用于不同折叠形态的布局微调） */
export enum DeviceForm {
  PHONE = 'phone',
  DUAL_FOLD_FOLDED = 'dual_fold_folded',
  DUAL_FOLD_UNFOLDED = 'dual_fold_unfolded',
  TRIPLE_FOLD_FOLDED = 'triple_fold_folded',
  TRIPLE_FOLD_UNFOLDED = 'triple_fold_unfolded',
  WIDE_FOLD_FOLDED = 'wide_fold_folded',
  WIDE_FOLD_UNFOLDED = 'wide_fold_unfolded',
  TABLET = 'tablet',
  PC = 'pc'
}

export class ExportOptions {
  static readonly FULL: string = 'full';
  static readonly PUBLIC: string = 'public';
  static readonly CSV: string = 'csv';
  static readonly MARKDOWN: string = 'markdown';
}
