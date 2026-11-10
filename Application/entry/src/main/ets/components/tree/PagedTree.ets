import { PersonNode } from '../../model/PersonNode';
import { TreeStyle, generationLabel } from '../../model/Enums';
import { Theme } from '../../theme/Theme';
import { EuBox, EuCanvas, LineSeg, SuBox, SuCanvas } from '../../service/TreeLayout';
import { LayoutProfile, PageSpec } from '../../service/PrintLayout';
import { PagePlan, PaginationService, PrintBook, pageGenText } from '../../service/PaginationService';
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

  private refresh(): void {
    const svc: PaginationService = PaginationService.getInstance();
    const book: PrintBook = svc.book(this.rootUid, this.style, this.layoutVersion, this.profileName);
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
    if (page === null) {
      this.header = '世系图';
      return;
    }
    this.header = pageGenText(page) + (this.branchName.length > 0 ? ' · ' + this.branchName : '');
    this.footer = page.footerText;
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
            this.zoom = Math.max(1, this.zoom - 0.5);
            this.updateScale();
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
            this.zoom = Math.min(3, this.zoom + 0.5);
            this.updateScale();
          })
      }
      .width('100%')
      .height(36)
      .padding({ left: 10, right: 10 })
      .backgroundColor(Theme.paper)

      // 页面：整页可滚动查看；k 已包含用户缩放
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
      .layoutWeight(1)
      .width('100%')
      .scrollable(ScrollDirection.Free)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
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
