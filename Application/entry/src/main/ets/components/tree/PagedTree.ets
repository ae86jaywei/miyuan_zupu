import { PersonNode } from '../../model/PersonNode';
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
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.refresh();
    this.updateScale();
  }

  onDark(): void {
    Theme.use(this.darkMode);
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

  // ─── 双指缩放：锚点固定在手指中心，放大后仍盯着同一点 ─────────────
  private pinchZoomStart: number = 1;
  /** 起始锚点在页面内容坐标（mm）中的位置 */
  private pinchAnchorCx: number = 0;
  private pinchAnchorCy: number = 0;

  /** 滚动内容宽度（与 build 里 Column 的 width 保持一致） */
  private contentW(): number {
    return Math.max(this.mm(this.spec.trimW),
      Math.min(this.viewW, DeviceUtil.screenWidthVp()));
  }

  /** 滚动内容高度（与 build 里 Column 的 height 保持一致） */
  private contentH(): number {
    return Math.max(this.viewH - 38, this.mm(this.spec.trimH));
  }

  /** 页面在滚动内容中的左内边距（Column 居中对齐） */
  private contentPadX(): number {
    return Math.max(0, (this.contentW() - this.mm(this.spec.trimW)) / 2);
  }

  /** 缩放前的可视滚动偏移 */
  private scrollX(): number {
    return this.scroller.currentOffset().xOffset;
  }

  private scrollY(): number {
    return this.scroller.currentOffset().yOffset;
  }

  /** 以 (focusX, focusY) 为锚点缩放到 target（视口坐标） */
  private zoomAt(target: number, focusX: number, focusY: number): void {
    const t: number = Math.min(3, Math.max(1, target));
    if (Math.abs(t - this.zoom) < 0.001 || this.k <= 0) {
      return;
    }
    // 锚点内容坐标（mm）：旧 k 下由「滚动偏移 + 手指位置 - 页边留白」反算
    const cx: number = (this.scrollX() + focusX - this.contentPadX()) / this.k;
    const cy: number = (this.scrollY() + focusY - 2) / this.k;
    this.zoom = t;
    this.updateScale();
    const sx: number = Math.max(0, cx * this.k + this.contentPadX() - focusX);
    const sy: number = Math.max(0, cy * this.k + 2 - focusY);
    // 布局尺寸要等这一帧刷新后再滚，否则会被旧的 maxOffset 夹住
    setTimeout((): void => {
      this.scroller.scrollTo({ xOffset: sx, yOffset: sy, animation: false });
    }, 0);
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
      return this.spec.gutter;
    }
    return this.spec.innerX(this.page.recto);
  }

  /** 当前页是否为单页（装订口在左） */
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
            Text('承')
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
      .width(this.mm(this.spec.trimW - this.innerX() - 10))
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

      // 装订口：单页在左，双页镜像到右
      Column()
        .width(this.mm(this.spec.gutter))
        .height('100%')
        .backgroundColor('#F4EFE3')
        .position({
          x: 0,
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
          .width(this.mm(this.spec.trimW - this.innerX() - 10))
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
    .backgroundColor('#FFFDF6')
    .clip(true)
    .parallelGesture(
      PanGesture({ fingers: 1, distance: 24, direction: PanDirection.Horizontal })
        .onActionEnd((event: GestureEvent): void => {
          // 横滑翻页：左滑看下一页，右滑回上一页（像翻纸质谱）
          if (event.offsetX < -60) {
            this.goto(this.pageNo + 1);
          } else if (event.offsetX > 60) {
            this.goto(this.pageNo - 1);
          }
        })
    )
  }

  /** 版心左边界（屏幕坐标） */
  private contentX(): number {
    if (this.page === null) {
      return this.mm(this.spec.gutter);
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
        Button('上一页')
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
        Button('下一页')
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
        Button('－')
          .fontSize(13)
          .height(30)
          .width(34)
          .fontColor(Theme.inkSecondary)
          .backgroundColor(Theme.card)
          .borderRadius(14)
          .onClick((): void => {
            this.zoomAt(this.zoom - 0.5, this.viewW / 2, (this.viewH - 36) / 2);
          })
        Text(Math.round(this.zoom * 100).toString() + '%')
          .fontSize(10)
          .fontColor(Theme.inkTertiary)
          .margin({ left: 5, right: 5 })
        Button('＋')
          .fontSize(13)
          .height(30)
          .width(34)
          .fontColor(Theme.inkSecondary)
          .backgroundColor(Theme.card)
          .borderRadius(14)
          .onClick((): void => {
            this.zoomAt(this.zoom + 0.5, this.viewW / 2, (this.viewH - 36) / 2);
          })
      }
      .width('100%')
      .height(36)
      .padding({ left: 10, right: 10 })
      .backgroundColor(Theme.paper)

      // 页面：整页可滚动查看；k 已包含用户缩放
      Stack() {
        Scroll(this.scroller) {
          Column() {
            this.PageSheet()
          }
          .width(Math.max(this.mm(this.spec.trimW), Math.min(this.viewW, DeviceUtil.screenWidthVp())))
          .height(Math.max(this.viewH - 38, this.mm(this.spec.trimH)))
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.Start)
          .padding({ top: 2, bottom: 4 })
        }
        .width('100%')
        .height('100%')
        .scrollable(ScrollDirection.Free)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)

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
      }
      // 双指缩放：与连续视图一致，以两指中心为锚点，放大后同一点仍在指下
      .parallelGesture(
        PinchGesture({ fingers: 2 })
          .onActionStart((event: GestureEvent): void => {
            this.pinchZoomStart = this.zoom;
            if (this.k <= 0) {
              return;
            }
            const cx: number = event.pinchCenterX ?? 0;
            const cy: number = event.pinchCenterY ?? 0;
            this.pinchAnchorCx = (this.scrollX() + cx - this.contentPadX()) / this.k;
            this.pinchAnchorCy = (this.scrollY() + cy - 2) / this.k;
          })
          .onActionUpdate((event: GestureEvent): void => {
            const target: number = Math.min(3, Math.max(1, this.pinchZoomStart * event.scale));
            if (Math.abs(target - this.zoom) < 0.002) {
              return;
            }
            this.zoom = target;
            this.updateScale();
            const cx: number = event.pinchCenterX ?? 0;
            const cy: number = event.pinchCenterY ?? 0;
            const sx: number = Math.max(0,
              this.pinchAnchorCx * this.k + this.contentPadX() - cx);
            const sy: number = Math.max(0,
              this.pinchAnchorCy * this.k + 2 - cy);
            setTimeout((): void => {
              this.scroller.scrollTo({ xOffset: sx, yOffset: sy, animation: false });
            }, 0);
          })
      )
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      this.viewW = Number(newArea.width);
      this.viewH = Number(newArea.height);
      this.updateScale();
    })
  }
}
