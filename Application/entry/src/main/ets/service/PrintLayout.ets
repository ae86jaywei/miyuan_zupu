import { LayoutMetrics } from './TreeLayout';

/**
 * 纸质族谱的页面规格。
 *
 * 成品 320×220mm（横版，与 220×320 的纸同尺寸，只是横放）：
 *  - 装订口 gutter、翻口 fold、天头 head、地脚 foot 都在成品内，出血 bleed 在成品外；
 *  - 版心 = 成品减去上述四边，奇偶页镜像只改版心起点，不改布局；
 *  - 1mm = 3.7795vp(96dpi) = 2.8346pt(72dpi) = 11.811px(300dpi)。
 *
 * 屏幕分页视图与将来的 PDF 导出共用这一份规格，避免两边各写一套尺寸。
 */
export class PageSpec {
  /** 成品宽（横版，长边） */
  trimW: number = 320;
  /** 成品高（横版，短边） */
  trimH: number = 220;
  /** 装订口宽 */
  gutter: number = 20;
  /** 翻口宽 */
  fold: number = 15;
  /** 天头高 */
  head: number = 20;
  /** 地脚高 */
  foot: number = 20;
  /** 出血（成品外，不占版心） */
  bleed: number = 3;
  /** 装订方向：left / right（传统右翻） */
  binding: string = 'left';

  static landscape(): PageSpec {
    return new PageSpec();
  }

  /** 版心宽：成品减去装订口与翻口 */
  contentWidth(): number {
    return this.trimW - this.gutter - this.fold;
  }

  /** 版心高：成品减去天头与地脚 */
  contentHeight(): number {
    return this.trimH - this.head - this.foot;
  }

  /**
   * 版心左边界（mm）。
   * 单页（recto=true）装订口在左；双面印刷的偶数页（verso）镜像到右侧，
   * 保证装订后两页版心到装订线的距离一致。
   */
  innerX(recto: boolean): number {
    if (this.binding === 'right') {
      return recto ? this.fold : this.gutter;
    }
    return recto ? this.gutter : this.fold;
  }

  /** 版心上边界（mm） */
  innerY(): number {
    return this.head;
  }

  /** 毫米 → vp（96dpi），屏幕渲染统一用 vp 作为页面单位 */
  static mmToVp(mm: number): number {
    return mm * 3.7795275591;
  }

  /** 毫米 → pt（72dpi），未来 PDF 导出使用 */
  static mmToPt(mm: number): number {
    return mm * 2.8346456693;
  }

  /** 毫米 → px（300dpi），印刷位图使用 */
  static mmToPx300(mm: number): number {
    return mm * 11.811023622;
  }

  key(): string {
    return this.trimW.toString() + 'x' + this.trimH.toString() + '|' + this.gutter.toString() +
      '|' + this.fold.toString() + '|' + this.head.toString() + '|' + this.foot.toString() +
      '|' + this.binding;
  }
}

/**
 * 卡片与连线的印刷尺寸档位（全部为毫米）。
 *
 * 屏幕版的 44/62/74 是 vp（手指点击尺寸），直接套到 220mm 纸面会让一张卡比整页还大，
 * 所以印刷版必须单独给一套毫米参数。
 */
export class LayoutProfile {
  name: string = '标准';
  /** 主卡宽 */
  cardW: number = 22;
  /** 主卡高 */
  cardH: number = 10;
  /** 世代列间距（欧式） */
  colGap: number = 3;
  /** 世代行距（苏式） */
  rowGap: number = 4;
  /** 同层兄弟间距（欧式） */
  siblingGap: number = 2;
  /** 夫妻卡间距 */
  spouseGap: number = 3;
  /** 多妻竖排间距 */
  stackGap: number = 2;
  /** 连线离卡框的留白 */
  lineGap: number = 2;
  /** 苏式多房母线层距 */
  busStep: number = 2.5;
  /** 苏式多房竖线轨道错开 */
  railGap: number = 2;
  /** 印刷版配偶并入卡片文字，不单独占位（同时消除夫妻跨页） */
  showSpouse: boolean = false;
  /** 姓名字号（pt） */
  nameFontPt: number = 7;
  /** 次要信息字号（pt） */
  detailFontPt: number = 5.5;
  /** 连线宽（mm） */
  lineWidth: number = 0.25;

  /** 紧凑档：人多时优先压页数 */
  static compact(): LayoutProfile {
    const p: LayoutProfile = new LayoutProfile();
    p.name = '紧凑';
    p.cardW = 16;
    p.cardH = 8;
    p.colGap = 3;
    p.rowGap = 3;
    p.siblingGap = 1.5;
    p.nameFontPt = 6;
    p.detailFontPt = 5;
    return p;
  }

  /** 标准档：推荐 */
  static standard(): LayoutProfile {
    return new LayoutProfile();
  }

  /** 大字档：人少、给长辈看 */
  static large(): LayoutProfile {
    const p: LayoutProfile = new LayoutProfile();
    p.name = '大字';
    p.cardW = 28;
    p.cardH = 12;
    p.colGap = 4;
    p.rowGap = 5;
    p.siblingGap = 2.5;
    p.nameFontPt = 9;
    p.detailFontPt = 7;
    return p;
  }

  /** 转为布局层参数 */
  metrics(): LayoutMetrics {
    const m: LayoutMetrics = new LayoutMetrics();
    m.cardHeight = this.cardH;
    m.siblingGap = this.siblingGap;
    m.spouseGap = this.spouseGap;
    m.stackGap = this.stackGap;
    m.lineGap = this.lineGap;
    m.busStep = this.busStep;
    m.railGap = this.railGap;
    m.colGap = this.colGap;
    m.rowGap = this.rowGap;
    m.startX = 0;
    m.scale = 1;
    return m;
  }

  key(): string {
    return this.name + '|' + this.cardW.toString() + 'x' + this.cardH.toString() +
      '|' + this.colGap.toString() + '|' + this.rowGap.toString() + '|' + this.siblingGap.toString() +
      '|' + this.showSpouse.toString();
  }
}
