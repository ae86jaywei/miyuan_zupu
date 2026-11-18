import { Breakpoint } from './Constants';

/**
 * 断点与栅格计算（一多响应式布局核心）。
 */
export class ScreenClass {
  static readonly XS: string = 'XS';
  static readonly SM: string = 'SM';
  static readonly MD: string = 'MD';
  static readonly LG: string = 'LG';
  static readonly XL: string = 'XL';
}

export class Layout {
  /** 应用侧边距 */
  static pagePadding(width: number, foldable?: boolean): number {
    if (width >= Breakpoint.XL) {
      return 40;
    }
    if (width >= Breakpoint.LG) {
      return 32;
    }
    if (width >= Breakpoint.MD) {
      return 24;
    }
    if (width >= Breakpoint.SM) {
      return 20;
    }
    return foldable ? 20 : 16;
  }

  /** 内容最大宽度（避免电脑端过宽） */
  static contentMaxWidth(width: number): number {
    if (width >= Breakpoint.XL) {
      return 1440;
    }
    return width;
  }

  /** 是否为双栏（左侧导航 + 内容） */
  static isSplit(width: number): boolean {
    return width >= Breakpoint.MD;
  }

  /** 是否显示底部 Tabbar */
  static isSidebar(width: number): boolean {
    return width >= Breakpoint.LG;
  }

  /** 是否双栏详情（列表 + 详情） */
  static isMasterDetail(width: number): boolean {
    return width >= Breakpoint.LG;
  }

  /** 卡片列数 */
  static gridColumns(width: number, minItem: number): number {
    const usable: number = width - Layout.pagePadding(width) * 2;
    const cols: number = Math.floor(usable / minItem);
    return Math.max(1, cols);
  }

  /** Tab 栏位置 */
  static barPosition(width: number): BarPosition {
    return width >= Breakpoint.MD ? BarPosition.Start : BarPosition.End;
  }

  /** 字号缩放（大屏适当放大，提高可读性） */
  static fontScale(width: number): number {
    if (width >= Breakpoint.LG) {
      return 1.12;
    }
    if (width >= Breakpoint.MD) {
      return 1.06;
    }
    return 1;
  }

  /** 断点名称 */
  static of(width: number): string {
    if (width >= Breakpoint.XL) {
      return ScreenClass.XL;
    }
    if (width >= Breakpoint.LG) {
      return ScreenClass.LG;
    }
    if (width >= Breakpoint.MD) {
      return ScreenClass.MD;
    }
    if (width >= Breakpoint.SM) {
      return ScreenClass.SM;
    }
    return ScreenClass.XS;
  }

  /** 对应设备形态的展示标签 */
  static deviceLabel(width: number): string {
    if (width >= Breakpoint.LG) {
      return '宽屏 / 电脑 / 三折叠展开';
    }
    if (width >= Breakpoint.SM) {
      return '平板 / 折叠展开 / 阔屏';
    }
    return '手机 / 折叠态';
  }
}
