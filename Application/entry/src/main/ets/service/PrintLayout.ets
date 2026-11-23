import { LayoutMetrics, TreeStyle } from 'common_base';
import { MM_TO_PT } from './pdf/PdfCommon';

/**
 * 纸质族谱的页面规格。
 *
 * 横版 320×220mm（欧式 / 苏式分页）或竖版 A4 210×297mm（牒记文字页）：
 *  - 装订口 gutter、翻口 fold、天头 head、地脚 foot 都在成品内，出血 bleed 在成品外；
 *  - 版心 = 成品减去上述四边；装订侧由 binding 决定：
 *    单面印刷所有页共用同一版心起点，双面印刷正反页左右镜像；
 *  - 1mm = 3.7795vp(96dpi) = 2.8346pt(72dpi) = 11.811px(300dpi)。
 *
 * 屏幕分页视图与 PDF 导出共用这一份规格，避免两边各写一套尺寸。
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
  /** 装订侧安全内缩：卡片不贴装订线，留出翻阅与装订余量 */
  safeInset: number = 6;
  /** 装订方向：left / right（传统右翻，欧式谱右起，装订口在右） */
  binding: string = 'right';
  /**
   * 双面印刷：奇偶页装订口分居纸张两侧。
   * 一张纸正反两面，背面页左右颠倒后装订口会落到另一侧；不交替的话
   * 双面装订后一半页的版心会贴到书脊上（只剩 1mm），文字被订进去。
   */
  duplex: boolean = true;
  /** 全局默认装订方向：导出设置与分页预览共用，由 UI 写入 */
  static defaultBinding: string = 'right';
  /** 全局默认装订方式：导出设置与分页预览共用，由 UI 写入 */
  static defaultDuplex: boolean = true;

  /** 欧式 / 苏式横版分页规格：320×220mm */
  static landscape(): PageSpec {
    const spec: PageSpec = new PageSpec();
    spec.binding = PageSpec.defaultBinding;
    spec.duplex = PageSpec.defaultDuplex;
    return spec;
  }

  /**
   * 牒记式 A4 竖版规格：210×297mm。
   * 沿用装订口 / 翻口 / 天头 / 地脚的四边模型，正文宽高与旧版
   * 「左右各 56pt、上 64pt、下 52pt」基本一致，装订侧单独加宽，
   * 双面印刷时随卷内页序左右镜像。
   */
  static portraitA4(): PageSpec {
    const spec: PageSpec = new PageSpec();
    spec.trimW = 210;
    spec.trimH = 297;
    spec.gutter = 20;
    spec.fold = 15;
    spec.head = 20;
    spec.foot = 20;
    spec.bleed = 3;
    spec.safeInset = 6;
    spec.binding = PageSpec.defaultBinding;
    spec.duplex = PageSpec.defaultDuplex;
    return spec;
  }

  /** 版心宽：成品减去装订口、翻口与装订侧安全内缩 */
  contentWidth(): number {
    return this.trimW - this.gutter - this.fold - this.safeInset;
  }

  /** 版心高：成品减去天头与地脚 */
  contentHeight(): number {
    return this.trimH - this.head - this.foot;
  }

  /**
   * 该页的装订口是否在纸面右侧。
   * 单面印刷时每张纸单独装订，统一按 binding 侧；
   * 双面印刷时背面页左右颠倒，装订口随之换到另一侧，装订后两页才同样贴订口。
   */
  bindOnRight(recto: boolean): boolean {
    if (!this.duplex) {
      return this.binding === 'right';
    }
    return this.binding === 'right' ? recto : !recto;
  }

  /**
   * 版心左边界（mm）。
   * 装订口在右时版心从翻口一侧起排，装订口在左时从装订口内侧起排，
   * 两侧都内缩 safeInset，卡片不压到装订线。
   */
  innerX(recto: boolean): number {
    return this.bindOnRight(recto) ? this.fold + this.safeInset : this.gutter + this.safeInset;
  }

  /** 装订口在纸面上的左边界（mm）：右装订贴成品右边，左装订贴左边 */
  gutterX(recto: boolean): number {
    return this.bindOnRight(recto) ? this.trimW - this.gutter : 0;
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
    return mm * MM_TO_PT;
  }

  /** 毫米 → px（300dpi），印刷位图使用 */
  static mmToPx300(mm: number): number {
    return mm * 11.811023622;
  }

  /**
   * 分页缓存键：只包含影响页分配的尺寸参数。
   * 装订方向与单双面只改版心起点（innerX/gutterX），不影响每页放哪些人，
   * 因此不参与键；切换时命中缓存后把最新 spec 挂回即可立即换几何。
   */
  key(): string {
    return this.trimW.toString() + 'x' + this.trimH.toString() + '|' + this.gutter.toString() +
      '|' + this.fold.toString() + '|' + this.head.toString() + '|' + this.foot.toString() +
      '|' + this.safeInset.toString();
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
  /** 配偶单独成卡（印刷版显示夫妻双卡，配偶随主卡同页，不会跨页） */
  showSpouse: boolean = true;
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
    p.nameFontPt = 9;
    p.detailFontPt = 7;
    return p;
  }

  /** 世代间距：欧式横向隔一列＝一张卡宽，苏式纵向隔一行＝一张卡高 */
  generationGap(style: string): number {
    return style === TreeStyle.SU ? this.cardH : this.cardW;
  }

  /** 兄弟间距：欧式纵向半张卡高，苏式横向半张卡宽 */
  siblingGapOf(style: string): number {
    return style === TreeStyle.SU ? this.cardW / 2 : this.cardH / 2;
  }

  /** 转为布局层参数（按谱式取横向/纵向口径） */
  metrics(style: string): LayoutMetrics {
    const m: LayoutMetrics = new LayoutMetrics();
    m.cardHeight = this.cardH;
    m.siblingGap = this.siblingGapOf(style);
    m.spouseGap = this.spouseGap;
    m.stackGap = this.stackGap;
    m.lineGap = this.lineGap;
    m.busStep = this.busStep;
    m.railGap = this.railGap;
    // colGap 在欧式里是世代列距，在苏式里是兄弟列距，两者口径不同
    m.colGap = style === TreeStyle.SU ? this.siblingGapOf(style) : this.generationGap(style);
    // rowGap 只被苏式用作世代行距
    m.rowGap = this.generationGap(style);
    m.startX = 0;
    m.scale = 1;
    // 纸上相邻两代卡片之间的净空就是世代间距：多妻竖排也不额外撑高该世，
    // 世系横线因此严格落在上代卡底与下代卡顶的正中间（屏幕连续视图保留手指出余量）
    m.minChildGap = 0;
    return m;
  }

  key(): string {
    return this.name + '|' + this.cardW.toString() + 'x' + this.cardH.toString() +
      '|' + this.showSpouse.toString();
  }
}

/**
 * 分页容量口径（屏幕分页、PDF 导出共用）。
 *
 * 以前这些阈值散落在 PaginationService 里，导出侧若另外按格数估算就会与屏幕差一截；
 * 统一放到这里后，任何「一页能放多少人 / 多少世」的判断都从同一处来。
 * 注意：slotCapacity 只是「标的卡位」上限，真实排版还会因树形留白少排，
 * 只用于快速否定明显装不下的整支，不作为最终版心判定。
 */
export class PageCapacity {
  /** 分支点提前切页的最小页人数 */
  static readonly MIN_PEOPLE_PER_PAGE: number = 20;
  /** 欧式「五世一表」软上限：页根起算最多画几世 */
  static readonly EU_MAX_GENERATIONS: number = 5;
  /** 五世换页的最小页人数，低于此值宁可放宽世代上限 */
  static readonly EU_GEN_CUT_MIN_PEOPLE: number = 12;
  /** 稀疏页判定：本页人数 / 标称卡位低于该比例时尝试并入上一页 */
  static readonly SPARSE_PAGE_FILL: number = 0.2;

  /** 每页卡片槽位上限（横排数 × 竖排数） */
  static slotCapacity(style: string, spec: PageSpec, profile: LayoutProfile): number {
    const genGap: number = profile.generationGap(style);
    const sibGap: number = profile.siblingGapOf(style);
    const colPitch: number = profile.cardW + (style === TreeStyle.SU ? sibGap : genGap);
    const rowPitch: number = profile.cardH + (style === TreeStyle.SU ? genGap : sibGap);
    const cols: number = Math.max(1, Math.floor(spec.contentWidth() / colPitch));
    const rows: number = Math.max(1, Math.floor(spec.contentHeight() / rowPitch));
    return cols * rows;
  }
}
