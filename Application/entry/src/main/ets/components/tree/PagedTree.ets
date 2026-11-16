import { PersonNode } from '../../model/PersonNode';
import { T } from '../../service/ScriptService';
import { TreeStyle, generationLabel } from '../../model/Enums';
import { Theme } from '../../theme/Theme';
import { EuBox, EuCanvas, LineSeg, SuBox, SuCanvas } from '../../service/TreeLayout';
import { LayoutProfile, PageSpec } from '../../service/PrintLayout';
import { PageJump, PagePlan, PaginationService, PrintBook, pageGenText } from '../../service/PaginationService';
import { DeviceUtil } from '../../util/DeviceUtil';
import { compactUid } from '../../util/StringUtil';

/**
 * 印刷版人物卡：白底细框、无圆角，姓名 + 世次 + 配偶文字。
 * 与屏幕卡分开，避免 TreeMiniCard 的 9fp/圆角/阴影在 22mm 卡上溢出。
 */
@Component
struct PrintCard {
  /** 订阅简繁设置：切换后重绘（T() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
  @Prop name: string = '';
  @Prop detail: string = '';
  @Prop badge: string = '';
  @Prop cardW: number = 80;
  @Prop cardH: number = 38;
  @Prop nameSize: number = 12;
  @Prop detailSize: number = 9;
  @Prop female: boolean = false;
  @Prop highlight: boolean = false;
  onTap: () => void = (): void => {};

  build() {
    Column() {
      Row() {
        Text(this.name)
          .fontSize(this.nameSize)
          .fontColor(this.female ? '#9C4A63' : '#2B2118')
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.badge.length > 0) {
          Text(this.badge)
            .fontSize(this.detailSize)
            .fontColor('#8C2F1E')
            .maxLines(1)
            .flexShrink(0)
            .margin({ left: 1 })
        }
      }
      .width('100%')

      if (this.detail.length > 0) {
        Text(this.detail)
          .fontSize(this.detailSize)
          .fontColor('#5F4F3E')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 1 })
      }
    }
    .width(this.cardW)
    .height(this.cardH)
    .padding({ left: this.cardW * 0.06, right: this.cardW * 0.06, top: this.cardH * 0.08, bottom: 0 })
    .backgroundColor(this.highlight ? '#FFF6E0' : '#FFFFFF')
    .border({
      width: this.highlight ? 1.2 : 0.35,
      color: this.highlight ? '#C9A227' : '#BFB09A'
    })
    .clip(true)
    .alignItems(HorizontalAlign.Start)
    .onClick((): void => {
      this.onTap();
    })
  }
}

/**
 * 分页画布：一次只显示一页，页内所有连线两端都在本页。
 *
 * 尺寸与纸质族谱一致（默认横版 320×220mm），版心、装订口、翻口、天头地脚都按
 * PageSpec 计算；页与页之间不画线，用页眉世代范围、页根「承第 N 页」角标、
 * 页脚「续见第 N 页」接续。
 */
@Component
export struct PagedTree {
  /** 当前页码（1 起）；父组件跳页时改它 */
  @Prop @Watch('onPageChanged') pageIndex: number = 1;
  @Prop @Watch('onPageChanged') rootUid: string = '';
  @Prop @Watch('onPageChanged') layoutVersion: number = 0;
  @Prop @Watch('onPageChanged') style: string = TreeStyle.EU;
  @Prop @Watch('onPageChanged') highlightUid: string = '';
  @Prop @Watch('onPageChanged') profileName: string = 'standard';
  @Prop branchName: string = '';
  @StorageProp('darkMode') @Watch('onDark') darkMode: boolean = false;
  /** 单面 / 双面装订：与导出设置共用同一个 AppStorage 键 */
  @StorageLink('printDuplex') @Watch('onDuplex') printDuplex: boolean = true;
  /** 装订方向：left / right，与导出设置共用 */
  @StorageLink('printBinding') @Watch('onBinding') printBinding: string = 'right';

  onPageChange: (n: number) => void = (n: number): void => {};
  onTapPerson: (uid: string) => void = (uid: string): void => {};

  @State pageNo: number = 1;
  @State pageCount: number = 1;
  @State header: string = '世系图';
  @State footer: string = '';
  @State euBoxes: EuBox[] = [];
  @State suBoxes: SuBox[] = [];
  @State lines: LineSeg[] = [];
  @State k: number = 1;
  @State zoom: number = 1;
  @State viewW: number = 0;
  @State viewH: number = 0;
  /** 正在规划整本分页：五万人的谱要算几十秒，期间必须给出明确反馈 */
  @State planning: boolean = false;
  @State planningPct: number = 0;
  /** 页首承接祖先（上溯两代）与页脚兄弟分支软链接 */
  @State ancestorUids: string[] = [];
  @State ancestorNames: string[] = [];
  @State siblingLinks: PageJump[] = [];

  private book: PrintBook | null = null;
  private page: PagePlan | null = null;
  private spec: PageSpec = PageSpec.landscape();
  private profile: LayoutProfile = LayoutProfile.standard();
  /** 页根 uid -> 来源页：卡片右上角写「承 P11」 */
  private rootPages: Map<string, number> = new Map<string, number>();
  /** 当前书的 key：宗支/谱式/数据版本变化时强制重建 */
  private lastKey: string = '';
  /** 视口平移量（vp）：页面左上角在可视区中的位置，由单指拖动/缩放共同维护 */
  @State panX: number = 0;
  @State panY: number = 0;

  aboutToAppear(): void {
    PageSpec.defaultBinding = this.printBinding;
    PageSpec.defaultDuplex = this.printDuplex;
    this.refresh();
    this.updateScale();
  }

  onDark(): void {
    Theme.use(this.darkMode);
  }

  /** 切换单面/双面：装订侧变了，整本按新几何重建（页分配不变，只重算版心） */
  onDuplex(): void {
    PageSpec.defaultDuplex = this.printDuplex;
    this.lastKey = '';
    this.refresh();
  }

  /** 切换左右装订：镜像版心起点，页分配不变 */
  onBinding(): void {
    PageSpec.defaultBinding = this.printBinding;
    this.lastKey = '';
    this.refresh();
  }

  /** 页码/宗支/数据变化都走这里；同一本书、同一页才跳过 */
  onPageChanged(): void {
    const key: string = this.bookKey();
    if (key === this.lastKey && this.pageNo === this.pageIndex) {
      return;
    }
    this.refresh();
  }

  private bookKey(): string {
    return this.rootUid + '|' + this.style + '|' + this.layoutVersion.toString() + '|' + this.profileName;
  }

  private async refresh(): Promise<void> {
    const svc: PaginationService = PaginationService.getInstance();
    this.planning = true;
    this.planningPct = 0;
    const book: PrintBook = await svc.book(this.rootUid, this.style, this.layoutVersion,
      this.profileName, (pct: number): void => {
        this.planningPct = pct;
      });
    this.planning = false;
    this.book = book;
    this.lastKey = this.bookKey();
    this.profile = book.profile;
    this.spec = book.spec;
    const count: number = Math.max(1, book.pageCount);
    this.pageCount = count;
    let idx: number = this.pageIndex;
    if (idx < 1) {
      idx = 1;
    }
    if (idx > count) {
      idx = count;
    }
    this.pageNo = idx;
    const page: PagePlan | null = book.page(idx);
    this.page = page;
    this.rootPages.clear();
    this.euBoxes = [];
    this.suBoxes = [];
    this.lines = [];
    this.footer = '';
    this.ancestorUids = [];
    this.ancestorNames = [];
    this.siblingLinks = [];
    if (page === null) {
      this.header = '世系图';
      return;
    }
    this.header = pageGenText(page) + (this.branchName.length > 0 ? ' · ' + this.branchName : '');
    this.footer = page.footerText;
    this.ancestorUids = page.contextAncestors;
    this.ancestorNames = page.contextAncestorNames;
    this.siblingLinks = page.siblingLinks;
    for (let i: number = 0; i < page.roots.length; i = i + 1) {
      const from: number = page.roots[i].fromPage;
      if (from > 0 && from < idx) {
        this.rootPages.set(page.roots[i].uid, from);
      }
    }
    if (this.style === TreeStyle.SU) {
      const c: SuCanvas | null = svc.suPage(idx);
      if (c !== null) {
        this.suBoxes = c.boxes;
        this.lines = c.lines;
      }
    } else {
      const c: EuCanvas | null = svc.euPage(idx);
      if (c !== null) {
        this.euBoxes = c.boxes;
        this.lines = c.lines;
      }
    }
    this.updateScale();
    if (this.viewW > 0) {
      this.resetPan();
    }
    console.info('[PGBOX] p=' + idx.toString() + ' boxes=' + this.euBoxes.length.toString() +
      ' su=' + this.suBoxes.length.toString() + ' lines=' + this.lines.length.toString() +
      ' roots=' + page.roots.length.toString());
  }

  /** 页面适配窗口：k = 每毫米多少 vp（含用户缩放）；横竖屏切换也要按屏幕宽度重新收口 */
  private updateScale(): void {
    if (this.viewW <= 0 || this.viewH <= 0) {
      return;
    }
    // viewW 可能来自比屏幕更宽的滚动内容，横屏时会把整页撑出右边屏幕；
    // 这里用物理屏幕宽度再夹一次，保证 100% 时整页始终落在屏幕内。
    const screenW: number = DeviceUtil.screenWidthVp();
    const baseW: number = screenW > 0 ? Math.min(this.viewW, screenW) : this.viewW;
    const availW: number = Math.max(80, baseW - 16);
    const availH: number = Math.max(80, this.viewH - 40);
    const fit: number = Math.min(availW / this.spec.trimW, availH / this.spec.trimH) * 0.96;
    this.k = Math.max(0.2, fit) * this.zoom;
    console.info('[PGSIZE] viewW=' + this.viewW.toFixed(1) + ' viewH=' + this.viewH.toFixed(1) +
      ' screenW=' + screenW.toFixed(1) + ' k=' + this.k.toFixed(2));
  }

  private goto(n: number): void {
    let idx: number = n;
    if (idx < 1) {
      idx = 1;
    }
    if (idx > this.pageCount) {
      idx = this.pageCount;
    }
    if (idx === this.pageNo) {
      return;
    }
    this.pageNo = idx;
    this.refresh();
    this.onPageChange(idx);
  }

  // ─── 视口：自己管平移/缩放，锚点精确可控（不依赖 Scroll 内部行为） ───
  private panReady: boolean = false;
  private pinchZoomStart: number = 1;
  /** 起始锚点在页面内容坐标（mm）中的位置 */
  private pinchAnchorCx: number = 0;
  private pinchAnchorCy: number = 0;
  private panStartX: number = 0;
  private panStartY: number = 0;
  private barStartX: number = 0;
  private barStartY: number = 0;

  /** 分页区可视高度（扣除顶部 36vp 翻页栏） */
  private pageViewH(): number {
    return Math.max(60, this.viewH - 36);
  }

  /** 页面在视口坐标中的宽/高（已含缩放） */
  private pageW(): number {
    return this.mm(this.spec.trimW);
  }

  private pageH(): number {
    return this.mm(this.spec.trimH);
  }

  /** 夹住平移：内容小于视口时居中，大于视口时不许拖出空边 */
  private clampPan(): void {
    const pw: number = this.pageW();
    const ph: number = this.pageH();
    const vw: number = this.viewW;
    const vh: number = this.pageViewH();
    if (pw <= vw) {
      this.panX = (vw - pw) / 2;
    } else {
      this.panX = Math.min(0, Math.max(vw - pw, this.panX));
    }
    if (ph <= vh) {
      this.panY = Math.max(0, (vh - ph) / 2);
    } else {
      this.panY = Math.min(0, Math.max(vh - ph, this.panY));
    }
  }

  /** 100% 时整页水平居中、顶部对齐 */
  private resetPan(): void {
    this.panX = (this.viewW - this.pageW()) / 2;
    this.panY = 0;
    this.clampPan();
  }

  /** 以视口坐标 (focusX, focusY) 为锚点缩放到 target */
  private zoomAt(target: number, focusX: number, focusY: number): void {
    const t: number = Math.min(3, Math.max(1, target));
    if (Math.abs(t - this.zoom) < 0.001 || this.k <= 0) {
      return;
    }
    const cx: number = (focusX - this.panX) / this.k;
    const cy: number = (focusY - this.panY) / this.k;
    this.zoom = t;
    this.updateScale();
    if (t <= 1.001) {
      this.resetPan();
      return;
    }
    this.panX = focusX - cx * this.k;
    this.panY = focusY - cy * this.k;
    this.clampPan();
  }

  /** 垂直滚动条滑块高度；内容未超出返回 0 */
  private vBarH(): number {
    const ph: number = this.pageH();
    const vh: number = this.pageViewH();
    if (ph <= vh + 0.5) {
      return 0;
    }
    return Math.max(28, vh * vh / ph);
  }

  private vBarY(): number {
    const th: number = this.vBarH();
    const vh: number = this.pageViewH();
    const max: number = this.pageH() - vh;
    if (max <= 0 || th <= 0) {
      return 2;
    }
    return Math.min(Math.max(0, vh - th), (-this.panY / max) * (vh - th));
  }

  /** 水平滚动条滑块宽度；内容未超出返回 0 */
  private hBarW(): number {
    const pw: number = this.pageW();
    if (pw <= this.viewW + 0.5) {
      return 0;
    }
    return Math.max(30, this.viewW * this.viewW / pw);
  }

  private hBarX(): number {
    const tw: number = this.hBarW();
    const max: number = this.pageW() - this.viewW;
    if (max <= 0 || tw <= 0) {
      return 2;
    }
    return Math.min(Math.max(0, this.viewW - tw), (-this.panX / max) * (this.viewW - tw));
  }

  /** pt -> 当前屏幕 vp */
  private pt(ptSize: number): number {
    return ptSize * 0.3527778 * this.k;
  }

  private mm(v: number): number {
    return v * this.k;
  }

  private lineThickness(): number {
    return Math.max(0.4, this.profile.lineWidth * this.k);
  }

  /** 页根角标：承第 N 页；普通卡片返回空串 */
  private badgeOf(uid: string): string {
    const from: number | undefined = this.rootPages.get(uid);
    return from === undefined ? '' : ('承P' + from.toString());
  }

  /** 当前页版心左边界（mm） */
  private innerX(): number {
    if (this.page === null) {
      return this.spec.innerX(true);
    }
    return this.spec.innerX(this.page.recto);
  }

  /** 当前页是否为单页（奇数页） */
  private isRecto(): boolean {
    return this.page !== null && this.page.recto;
  }

  /** 卡片次要文字：世次 + ID + 配偶名（配偶已单独成卡时不再重复整段配偶信息） */
  private detailOf(node: PersonNode): string {
    let text: string = generationLabel(node.person.generation);
    if (node.uid.length > 0) {
      text = text + ' · ' + compactUid(node.uid);
    }
    const sp: string = node.spouseText();
    if (sp.length > 0 && !this.profile.showSpouse) {
      text = text + '｜' + sp;
    }
    return text;
  }

  /** 跳到某人所在页（页首祖先卡/页脚软链接使用） */
  private gotoUid(uid: string): void {
    if (this.book === null || uid.length === 0) {
      return;
    }
    const p: number = this.book.pageOf(uid);
    if (p > 0) {
      this.goto(p);
    }
  }

  /**
   * 页首承接祖先卡：上溯两代，虚线连接到本页页根。
   * 解决「翻页后不知道这一页从谁续来」的断裂感。
   */
  @Builder
  AncestorCards() {
    if (this.ancestorUids.length > 0) {
      Row({ space: this.mm(2) }) {
        ForEach(this.ancestorUids, (uid: string, i: number) => {
          Column() {
            Text(T('承'))
              .fontSize(this.pt(5.5))
              .fontColor('#9A8A74')
            Text(this.ancestorNames.length > i ? this.ancestorNames[i] : uid)
              .fontSize(this.pt(7))
              .fontColor('#5F4F3E')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width(this.mm(30))
          .height(this.mm(9))
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#F8F3E7')
          .border({ width: 0.3, color: '#D8CBB2', style: BorderStyle.Dashed })
          .onClick((): void => {
            this.gotoUid(uid);
          })
        }, (uid: string, i: number) => 'anc_' + this.pageNo.toString() + '_' + uid + '_' + i.toString())
      }
      .position({ x: this.mm(this.innerX()), y: this.mm(9) })
    }
  }

  /** 页脚兄弟分支软链接：本页只展开一房时，其余房一键直达 */
  @Builder
  BranchLinks() {
    if (this.siblingLinks.length > 0) {
      Row({ space: this.mm(3) }) {
        ForEach(this.siblingLinks, (link: PageJump, i: number) => {
          Text('旁支 ' + link.relation + ' → 第' + link.page.toString() + '页')
            .fontSize(this.pt(6.5))
            .fontColor('#8C2F1E')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick((): void => {
              this.goto(link.page);
            })
        }, (link: PageJump) => 'sib_' + this.pageNo.toString() + '_' + link.uid)
      }
      .width(this.mm(this.spec.contentWidth() - 10))
      .position({ x: this.mm(this.innerX()), y: this.mm(this.spec.trimH - 19) })
    }
  }

  @Builder
  PageSheet() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 纸张
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#FFFDF6')
        .border({ width: 0.5, color: '#D8CBB2' })

      // 装订口：按 PageSpec.binding 贴装订侧，双面印刷时奇偶页镜像
      Column()
        .width(this.mm(this.spec.gutter))
        .height('100%')
        .backgroundColor('#F4EFE3')
        .position({
          x: this.mm(this.spec.gutterX(this.isRecto())),
          y: 0
        })

      // 页首承接祖先卡
      this.AncestorCards()

      // 页眉：谱名/支系 + 世代范围
      Text(this.header)
        .fontSize(this.pt(8))
        .fontColor('#7A6A57')
        .maxLines(1)
        .position({
          x: this.mm(this.innerX()),
          y: this.mm(6)
        })

      // 连线
      ForEach(this.lines, (seg: LineSeg) => {
        if (Math.abs(seg.y2 - seg.y1) <= 0.5) {
          Row()
            .width(Math.max(1, Math.abs(seg.x2 - seg.x1) * this.k))
            .height(this.lineThickness())
            .backgroundColor(seg.red ? '#B03A2E' : '#C9A227')
            .position({
              x: this.contentX() + Math.min(seg.x1, seg.x2) * this.k,
              y: this.contentY() + seg.y1 * this.k - this.lineThickness() / 2
            })
        } else {
          Column()
            .width(this.lineThickness())
            .height(Math.max(1, Math.abs(seg.y2 - seg.y1) * this.k))
            .backgroundColor(seg.red ? '#B03A2E' : '#C9A227')
            .position({
              x: this.contentX() + seg.x1 * this.k - this.lineThickness() / 2,
              y: this.contentY() + Math.min(seg.y1, seg.y2) * this.k
            })
        }
      }, (seg: LineSeg) => 'ln_' + this.pageNo.toString() + '_' + seg.id.toString())

      // 欧式卡片
      if (this.style !== TreeStyle.SU) {
        ForEach(this.euBoxes, (b: EuBox, idx: number) => {
          PrintCard({
            name: b.node.person.name.length > 0 ? b.node.person.name : b.node.uid,
            detail: this.detailOf(b.node),
            badge: this.badgeOf(b.node.uid),
            cardW: this.mm(this.profile.cardW),
            cardH: this.mm(this.profile.cardH),
            nameSize: this.pt(this.profile.nameFontPt),
            detailSize: this.pt(this.profile.detailFontPt),
            female: b.node.person.gender === '女',
            highlight: b.node.uid === this.highlightUid,
            onTap: (): void => {
              this.onTapPerson(b.node.uid);
            }
          })
            .position({
              x: this.contentX() + b.x * this.k,
              y: this.contentY() + b.y * this.k
            })
        }, (b: EuBox, idx: number) => 'eu_' + this.pageNo.toString() + '_' + idx.toString() + '_' + b.node.uid)
      } else {
        // 苏式卡片
        ForEach(this.suBoxes, (b: SuBox, idx: number) => {
          PrintCard({
            name: b.node.person.name.length > 0 ? b.node.person.name : b.node.uid,
            detail: this.detailOf(b.node),
            badge: this.badgeOf(b.node.uid),
            cardW: this.mm(this.profile.cardW),
            cardH: this.mm(this.profile.cardH),
            nameSize: this.pt(this.profile.nameFontPt),
            detailSize: this.pt(this.profile.detailFontPt),
            female: b.node.person.gender === '女',
            highlight: b.node.uid === this.highlightUid,
            onTap: (): void => {
              this.onTapPerson(b.node.uid);
            }
          })
            .position({
              x: this.contentX() + b.x * this.k,
              y: this.contentY() + b.y * this.k
            })
        }, (b: SuBox, idx: number) => 'su_' + this.pageNo.toString() + '_' + idx.toString() + '_' + b.node.uid)
      }

      // 页脚软链接：兄弟分支直达
      this.BranchLinks()

      // 页脚接续 + 页码（分两行：接续距底 12mm，页码距底 6mm）
      if (this.footer.length > 0) {
        Text(this.footer)
          .fontSize(this.pt(6.5))
          .fontColor('#8C2F1E')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(this.mm(this.spec.contentWidth() - 10))
          .position({
            x: this.mm(this.innerX()),
            y: this.mm(this.spec.trimH - 12)
          })
      }
      Text('第 ' + this.pageNo.toString() + ' 页 / 共 ' + this.pageCount.toString() + ' 页')
        .fontSize(this.pt(8))
        .fontColor('#5E5041')
        .fontWeight(FontWeight.Medium)
        .textAlign(TextAlign.Center)
        .width(this.mm(this.spec.trimW))
        .position({ x: 0, y: this.mm(this.spec.trimH - 6) })
    }
    .width(this.mm(this.spec.trimW))
    .height(this.mm(this.spec.trimH))
    .position({ x: this.panX, y: this.panY })
    .backgroundColor('#FFFDF6')
    .clip(true)
  }

  /** 版心左边界（屏幕坐标） */
  private contentX(): number {
    if (this.page === null) {
      return this.mm(this.spec.innerX(true));
    }
    return this.mm(this.spec.innerX(this.page.recto));
  }

  /** 版心上边界（屏幕坐标） */
  private contentY(): number {
    return this.mm(this.spec.innerY());
  }

  build() {
    Column() {
      // 页导航
      Row() {
        Button(T('上一页'))
          .fontSize(11)
          .height(30)
          .fontColor(Theme.primary)
          .backgroundColor(Theme.card)
          .border({ width: 1, color: Theme.glassBorder })
          .borderRadius(14)
          .enabled(this.pageNo > 1)
          .onClick((): void => {
            this.goto(this.pageNo - 1);
          })
        Text(this.pageNo.toString() + ' / ' + this.pageCount.toString())
          .fontSize(12)
          .fontColor(Theme.ink)
          .margin({ left: 10, right: 10 })
        Button(T('下一页'))
          .fontSize(11)
          .height(30)
          .fontColor(Theme.primary)
          .backgroundColor(Theme.card)
          .border({ width: 1, color: Theme.glassBorder })
          .borderRadius(14)
          .enabled(this.pageNo < this.pageCount)
          .onClick((): void => {
            this.goto(this.pageNo + 1);
          })
        Blank()
        Text('－')
          .fontSize(16)
          .height(30)
          .width(34)
          .textAlign(TextAlign.Center)
          .fontColor(Theme.inkSecondary)
          .backgroundColor(Theme.card)
          .borderRadius(14)
          .onClick((): void => {
            this.zoomAt(this.zoom - 0.5, this.viewW / 2, this.pageViewH() / 2);
          })
        Text(Math.round(this.zoom * 100).toString() + '%')
          .fontSize(10)
          .fontColor(Theme.inkTertiary)
          .margin({ left: 5, right: 5 })
        Text('＋')
          .fontSize(16)
          .height(30)
          .width(34)
          .textAlign(TextAlign.Center)
          .fontColor(Theme.inkSecondary)
          .backgroundColor(Theme.card)
          .borderRadius(14)
          .onClick((): void => {
            this.zoomAt(this.zoom + 0.5, this.viewW / 2, this.pageViewH() / 2);
          })
      }
      .width('100%')
      .height(36)
      .padding({ left: 10, right: 10 })
      .backgroundColor(Theme.paper)

      // 页面：自管视口（平移 + 缩放），双指锚点与滚动条都可控
      Stack({ alignContent: Alignment.TopStart }) {
        this.PageSheet()

        // 整本分页规划期间遮住空白页，并显示真实进度
        if (this.planning) {
          Column() {
            LoadingProgress()
              .width(34)
              .height(34)
              .color(Theme.primary)
            Text(this.planningPct > 0 ? ('正在排版 ' + this.planningPct.toString() + '%') : '正在排版…')
              .fontSize(12)
              .fontColor(Theme.inkSecondary)
              .margin({ top: 10 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor('rgba(255,253,246,0.88)')
        }

        // 垂直滚动条：放大后内容高于视口时出现，可直接拖动
        if (this.vBarH() > 0) {
          Column() {
            Column()
              .width(3)
              .height(this.vBarH())
              .backgroundColor('rgba(0,0,0,0.30)')
              .borderRadius(2)
          }
          .width(10)
          .height(this.vBarH())
          .justifyContent(FlexAlign.Center)
          .position({ x: this.viewW - 12, y: this.vBarY() })
          .gesture(
            PanGesture({ fingers: 1 })
              .onActionStart((): void => {
                this.barStartY = this.panY;
              })
              .onActionUpdate((event: GestureEvent): void => {
                const range: number = this.pageViewH() - this.vBarH();
                const contentRange: number = this.pageH() - this.pageViewH();
                if (range <= 0 || contentRange <= 0) {
                  return;
                }
                this.panY = this.barStartY - (event.offsetY / range) * contentRange;
                this.clampPan();
              })
          )
        }

        // 水平滚动条：放大后内容宽于视口时出现
        if (this.hBarW() > 0) {
          Row() {
            Row()
              .width(this.hBarW())
              .height(3)
              .backgroundColor('rgba(0,0,0,0.30)')
              .borderRadius(2)
          }
          .width(this.hBarW())
          .height(10)
          .alignItems(VerticalAlign.Center)
          .position({ x: this.hBarX(), y: this.pageViewH() - 12 })
          .gesture(
            PanGesture({ fingers: 1 })
              .onActionStart((): void => {
                this.barStartX = this.panX;
              })
              .onActionUpdate((event: GestureEvent): void => {
                const range: number = this.viewW - this.hBarW();
                const contentRange: number = this.pageW() - this.viewW;
                if (range <= 0 || contentRange <= 0) {
                  return;
                }
                this.panX = this.barStartX - (event.offsetX / range) * contentRange;
                this.clampPan();
              })
          )
        }
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      .gesture(
        GestureGroup(GestureMode.Parallel,
          // 双指缩放：锚点固定在两指中心，放大后同一点仍在指下
          PinchGesture({ fingers: 2 })
            .onActionStart((event: GestureEvent): void => {
              this.pinchZoomStart = this.zoom;
              if (this.k <= 0) {
                return;
              }
              const cx: number = event.pinchCenterX ?? 0;
              const cy: number = event.pinchCenterY ?? 0;
              this.pinchAnchorCx = (cx - this.panX) / this.k;
              this.pinchAnchorCy = (cy - this.panY) / this.k;
            })
            .onActionUpdate((event: GestureEvent): void => {
              const target: number = Math.min(3, Math.max(1, this.pinchZoomStart * event.scale));
              if (Math.abs(target - this.zoom) < 0.002 || this.k <= 0) {
                return;
              }
              const cx: number = event.pinchCenterX ?? 0;
              const cy: number = event.pinchCenterY ?? 0;
              this.zoom = target;
              this.updateScale();
              this.panX = cx - this.pinchAnchorCx * this.k;
              this.panY = cy - this.pinchAnchorCy * this.k;
              this.clampPan();
            }),
          // 单指拖动：放大后平移查看；100% 时整页可见，横滑翻页
          PanGesture({ fingers: 1, distance: 8 })
            .onActionStart((): void => {
              this.panStartX = this.panX;
              this.panStartY = this.panY;
            })
            .onActionUpdate((event: GestureEvent): void => {
              if (this.zoom <= 1.001) {
                return;
              }
              this.panX = this.panStartX + event.offsetX;
              this.panY = this.panStartY + event.offsetY;
              this.clampPan();
            })
            .onActionEnd((event: GestureEvent): void => {
              if (this.zoom > 1.001) {
                return;
              }
              // 横滑翻页：左滑看下一页，右滑回上一页（像翻纸质谱）
              if (event.offsetX < -60) {
                this.goto(this.pageNo + 1);
              } else if (event.offsetX > 60) {
                this.goto(this.pageNo - 1);
              }
            })
        )
      )
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      this.viewW = Number(newArea.width);
      this.viewH = Number(newArea.height);
      this.updateScale();
      if (!this.panReady) {
        this.panReady = true;
        this.resetPan();
      } else {
        this.clampPan();
      }
    })
  }
}
