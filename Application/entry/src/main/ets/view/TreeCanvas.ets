import { PersonNode } from '../model/PersonNode';
import { Person } from '../model/Person';
import { TreeStyle, generationLabel } from '../model/Enums';
import { EuTree } from '../components/tree/EuTree';
import { SuTree } from '../components/tree/SuTree';
import { PagodaTree } from '../components/tree/PagodaTree';
import { DieRecord } from '../components/tree/DieRecord';
import { ModernTree } from '../components/tree/ModernTree';
import { EmptyHint } from '../components/EmptyHint';
import { Theme, Spacing } from '../theme/Theme';
import { GenealogyService } from '../service/GenealogyService';
import { TreeLayoutCache } from '../service/TreeLayoutCache';
import { EuCanvas, SuCanvas, suRootCenterX } from '../service/TreeLayout';
import { ViewportMath } from '../service/TreeViewport';
import { Breakpoint } from '../common/Constants';
import { FlatListSource } from '../util/FlatListSource';
import { TreePerf } from '../util/TreePerf';

/** 多宗支时每支标题的固定高度（16 行高 + 8 底部间距），用于精确计算裁剪起点 */
const BRANCH_HEADER_H: number = 24;

/**
 * 谱式画布：按所选谱式渲染整部族谱。
 *
 * 大树性能策略：
 * - 布局由 TreeLayoutCache 按宗支缓存，build 内不再重复 compute；
 * - 欧式/苏式由 EuTree/SuTree 做视口裁剪，只创建可见卡片与连线；
 * - 不再通过 @Prop 接收 PersonNode[]，避免环状深拷贝；
 * - 平移边界由 ViewportMath 按内容尺寸与缩放计算，四角可达。
 */
@Component
export struct TreeCanvas {
  @Prop @Watch('onStyleChanged') style: string = TreeStyle.EU;
  @StorageProp('gpVersion') @Watch('onDataVersionChanged') dataVersion: number = 0;
  @Prop @Watch('onHighlightChanged') highlightUid: string = '';
  @Prop showPrivate: boolean = true;
  @Prop @Watch('onWindowWidthChanged') windowWidth: number = 360;
  @Prop @Watch('onZoomChanged') zoom: number = 1;
  onTapPerson: (uid: string) => void = (uid: string): void => {};

  /** 欧式/苏式画布平移偏移（拖到哪停到哪） */
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  /** 画布内容尺寸（未缩放），由布局缓存计算 */
  @State canvasW: number = 0;
  @State canvasH: number = 0;
  /** 容器可视区尺寸 */
  @State viewW: number = 0;
  @State viewH: number = 0;
  /** 当前族谱的宗支根 uid 列表 */
  @State rootUids: string[] = [];
  @State peopleCount: number = 0;
  /** 世代索引（一次构建，供索引条与牒记/现代谱式复用） */
  @State genLabels: string[] = [];
  @State genCounts: number[] = [];
  @State genGroups: Person[][] = [];
  /** 每个宗支在全部宗支堆叠画布中的屏幕起点（已含 zoom） */
  @State branchTops: number[] = [];

  /** 手势起点 */
  private startX: number = 0;
  private startY: number = 0;
  /** 苏式谱切换后待把始祖居中（等可视区宽度就绪后再执行一次） */
  private pendingCenter: boolean = true;
  private dieSource: FlatListSource<Person> = new FlatListSource<Person>();
  private diePeople: Person[] = [];

  aboutToAppear(): void {
    this.refreshData();
    this.centerSuIfReady();
  }

  private isNarrow(): boolean {
    return this.windowWidth < Breakpoint.SM;
  }

  /** 切换谱式后画布尺寸与布局完全变化，平移偏移必须归零 */
  onStyleChanged(): void {
    this.offsetX = 0;
    this.offsetY = 0;
    if (this.style === TreeStyle.DIE) {
      this.rebuildDieSource();
    }
    this.rebuildCanvasSize();
    this.pendingCenter = true;
    this.centerSuIfReady();
  }

  onHighlightChanged(): void {
    if (this.style === TreeStyle.DIE) {
      this.dieSource.setData(this.diePeople);
    }
  }

  /** 族人数据变化：丢弃旧布局，重建宗支索引与世代索引 */
  onDataVersionChanged(): void {
    TreeLayoutCache.getInstance().invalidate();
    this.refreshData();
    this.offsetX = 0;
    this.offsetY = 0;
    this.pendingCenter = true;
    this.centerSuIfReady();
  }

  /** 缩放变化后可用可视范围随之改变：先重算各支屏幕起点，再把平移偏移夹回边界 */
  onZoomChanged(): void {
    this.rebuildCanvasSize();
  }

  /** 断点/窗口宽度变化会改变卡片宽度与密度，画布尺寸与各支起点需重算 */
  onWindowWidthChanged(): void {
    this.rebuildCanvasSize();
  }

  private refreshData(): void {
    TreePerf.begin('tree_groups');
    const svc: GenealogyService = GenealogyService.getInstance();
    const roots: PersonNode[] = svc.getRoots();
    this.rootUids = roots.map((r: PersonNode): string => r.uid);
    this.peopleCount = svc.getPeople().length;
    const map: Map<number, Person[]> = svc.groupByGeneration();
    const gens: number[] = Array.from(map.keys()).sort((a: number, b: number): number => a - b);
    this.genLabels = gens.map((g: number): string => generationLabel(g));
    this.genCounts = gens.map((g: number): number => (map.get(g) as Person[]).length);
    this.genGroups = gens.map((g: number): Person[] => map.get(g) as Person[]);
    if (this.style === TreeStyle.DIE) {
      this.rebuildDieSource();
    }
    TreePerf.end('tree_groups', 'people=' + this.peopleCount.toString() +
      ' generations=' + gens.length.toString());
    this.rebuildCanvasSize();
  }

  private rebuildDieSource(): void {
    const people: Person[] = [];
    this.genGroups.forEach((group: Person[]): void => {
      group.forEach((person: Person): void => {
        people.push(person);
      });
    });
    this.diePeople = people;
    this.dieSource.setData(people);
  }

  /** 只在数据/谱式/宽度变化时调用，不要在手势回调里调用 */
  private rebuildCanvasSize(): void {
    if (this.style !== TreeStyle.EU && this.style !== TreeStyle.SU) {
      return;
    }
    const cache: TreeLayoutCache = TreeLayoutCache.getInstance();
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    const headerBlock: number = roots.length > 1 ? BRANCH_HEADER_H + Spacing.S : 0;
    let w: number = 0;
    let screenCursor: number = 0;
    const tops: number[] = [];
    for (let i: number = 0; i < roots.length; i = i + 1) {
      // tops 记录该支 EuTree/SuTree 在屏幕上的起点（标题之后，已含 zoom）
      tops.push(screenCursor + headerBlock);
      if (this.style === TreeStyle.SU) {
        const c: SuCanvas = cache.su(roots[i].uid, [roots[i]], this.cardWidth(), this.isNarrow(), true);
        w = Math.max(w, c.width);
        screenCursor = screenCursor + headerBlock + c.height * this.zoom + Spacing.XXL;
      } else {
        const c: EuCanvas = cache.eu(roots[i].uid, [roots[i]], this.cardWidth(),
          this.isNarrow() ? 66 : 78, true, 6);
        w = Math.max(w, c.width);
        screenCursor = screenCursor + headerBlock + c.height * this.zoom + Spacing.XXL;
      }
    }
    this.branchTops = tops;
    // canvasW/canvasH 统一存“屏幕尺寸”（已含 zoom），与多宗支标题/间隔的真实占位一致
    this.canvasW = w * this.zoom;
    this.canvasH = screenCursor;
    this.offsetX = this.clampX(this.offsetX);
    this.offsetY = this.clampY(this.offsetY);
  }

  private collectSize(w: number, h: number): void {
    // 只在严格变大时写入，避免拖动时每帧触发父组件重渲染
    const sw: number = w * this.zoom;
    const sh: number = h * this.zoom;
    if (sw > this.canvasW) {
      this.canvasW = sw;
    }
    if (sh > this.canvasH) {
      this.canvasH = sh;
    }
  }

  private rootName(uid: string): string {
    const p: Person | null = GenealogyService.getInstance().getPerson(uid);
    return p === null ? '' : p.name;
  }

  private rootDescendants(uid: string): number {
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    for (let i: number = 0; i < roots.length; i = i + 1) {
      if (roots[i].uid === uid) {
        return roots[i].descendants;
      }
    }
    return 0;
  }

  private cardWidth(): number {
    let base: number = 104;
    if (this.windowWidth >= Breakpoint.LG) {
      base = 136;
    } else if (this.windowWidth >= Breakpoint.MD) {
      base = 124;
    } else if (this.windowWidth >= Breakpoint.SM) {
      base = 112;
    }
    return base;
  }

  /**
   * 苏式谱的始祖居中于子孙，画布宽度远大于屏幕，默认停在 x=0 时始祖会落在屏幕外，
   * 看起来像“空白”。可视区宽度就绪后把始祖横移到屏幕中间。
   */
  private centerSuIfReady(): void {
    if (!this.pendingCenter || this.style !== TreeStyle.SU) {
      return;
    }
    if (this.viewW <= 0 || this.rootUids.length === 0) {
      return;
    }
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    if (roots.length === 0) {
      return;
    }
    this.pendingCenter = false;
    const cx: number = suRootCenterX([roots[0]], this.cardWidth(), this.isNarrow());
    // 屏幕坐标 = 内容坐标 × zoom + offset，因此居中的偏移要乘 zoom
    this.offsetX = this.clampX(this.viewW / 2 - cx * this.zoom);
    this.offsetY = 0;
  }

  /** 渲染上下方向谱式的世系索引 */
  @Builder
  GenerationIndex() {
    Scroll() {
      Row() {
        ForEach(this.genLabels, (label: string, idx: number) => {
          Text(label + ' · ' + this.genCounts[idx].toString() + '人')
            .fontSize(11)
            .fontColor(Theme.primary)
            .backgroundColor(Theme.highlightBg)
            .borderRadius(10)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .margin({ right: 6 })
        }, (label: string, idx: number) => 'idx_' + label + idx.toString())
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ bottom: Spacing.M })
  }

  @Builder
  StyleHint() {
    if (this.style !== TreeStyle.DIE) {
      Row() {
        Text('📐 双指缩放 · 拖动平移 · 点击人物查看详情')
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
      }
      .width('100%')
      .padding({ bottom: Spacing.S })
    }
  }

  @Builder
  DieList() {
    List({ space: Spacing.M }) {
      LazyForEach(this.dieSource, (person: Person, index: number) => {
        ListItem() {
          Column() {
            if (index === 0 || this.dieSource.getData(index - 1).generation !== person.generation) {
              Row() {
                Text(generationLabel(person.generation))
                  .fontSize(18)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.primary)
                Divider()
                  .layoutWeight(1)
                  .color(Theme.goldLight)
                  .margin({ left: Spacing.M })
              }
              .width('100%')
              .margin({ top: index === 0 ? 0 : Spacing.XL, bottom: Spacing.M })
            }
            DieRecord({
              person: person,
              index: 0,
              showPrivate: this.showPrivate,
              highlight: person.uid === this.highlightUid,
              onTapPerson: (uid: string): void => {
                this.onTapPerson(uid);
              }
            })
          }
          .width('100%')
        }
      }, (person: Person) => 'die_' + this.dataVersion.toString() + '_' + this.highlightUid + '_' + person.uid)
    }
    .width('100%')
    .layoutWeight(1)
    .cachedCount(TreePerf.listCacheCount(this.peopleCount))
    .padding({ bottom: 120 })
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.None)
  }

  build() {
    Column() {
      this.StyleHint()

      if (this.peopleCount === 0) {
        EmptyHint({ icon: '🌱', title: '族谱暂无人物', desc: '点击右下角“＋”创建始祖，开启家族记录' })
      } else {
        if (this.style === TreeStyle.DIE) {
          this.DieList()
        } else if (this.style === TreeStyle.PAGODA) {
          Column() {
            this.GenerationIndex()
            PagodaTree({
              rootUids: this.rootUids,
              layoutVersion: this.dataVersion,
              highlightUid: this.highlightUid,
              compact: this.isNarrow(),
              onTapPerson: (uid: string): void => {
                this.onTapPerson(uid);
              }
            })
            .layoutWeight(1)
          }
          .width('100%')
          .layoutWeight(1)
        } else if (this.style === TreeStyle.MODERN) {
          ModernTree({
            layoutVersion: this.dataVersion,
            windowWidth: this.windowWidth,
            highlightUid: this.highlightUid,
            minCardWidth: this.windowWidth >= Breakpoint.MD ? 220 : (this.isNarrow() ? 150 : 180),
            onTapPerson: (uid: string): void => {
              this.onTapPerson(uid);
            }
          })
          .layoutWeight(1)
        } else {
          Scroll() {
            Column() {
              ForEach(this.rootUids, (uid: string, ri: number) => {
                Column() {
                  if (this.rootUids.length > 1) {
                    Row() {
                      Text('宗支 ' + (ri + 1).toString() + '：' + this.rootName(uid))
                        .fontSize(13)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Theme.primary)
                      Text('后代 ' + this.rootDescendants(uid).toString() + ' 人')
                        .fontSize(11)
                        .fontColor(Theme.inkTertiary)
                        .margin({ left: 6 })
                    }
                    .width('100%')
                    .height(BRANCH_HEADER_H)
                    .margin({ bottom: Spacing.S })
                  }
                  if (this.style === TreeStyle.EU) {
                    EuTree({
                      rootUid: uid,
                      layoutVersion: this.dataVersion,
                      highlightUid: this.highlightUid,
                      cardWidth: this.cardWidth(),
                      dense: this.isNarrow(),
                      showSpouse: true,
                      offsetX: $offsetX,
                      offsetY: $offsetY,
                      viewWidth: this.viewW,
                      viewHeight: this.viewH,
                      zoom: this.zoom,
                      contentTop: ri < this.branchTops.length ? this.branchTops[ri] : 0,
                      onTapPerson: (id: string): void => {
                        this.onTapPerson(id);
                      },
                      onSize: (w: number, h: number): void => {
                        this.collectSize(w, h);
                      }
                    })
                  } else {
                    SuTree({
                      rootUid: uid,
                      layoutVersion: this.dataVersion,
                      highlightUid: this.highlightUid,
                      cardWidth: this.cardWidth(),
                      dense: this.isNarrow(),
                      showGenMark: true,
                      showSpouse: true,
                      offsetX: $offsetX,
                      offsetY: $offsetY,
                      viewWidth: this.viewW,
                      viewHeight: this.viewH,
                      zoom: this.zoom,
                      contentTop: ri < this.branchTops.length ? this.branchTops[ri] : 0,
                      onTapPerson: (id: string): void => {
                        this.onTapPerson(id);
                      },
                      onSize: (w: number, h: number): void => {
                        this.collectSize(w, h);
                      }
                    })
                  }
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .margin({ bottom: Spacing.XXL })
              }, (uid: string) => 'root_' + uid)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ bottom: 120 })
          }
          .scrollable(ScrollDirection.None)
          .onAreaChange((oldArea: Area, newArea: Area): void => {
            this.viewW = Number(newArea.width);
            this.viewH = Number(newArea.height);
            this.offsetX = this.clampX(this.offsetX);
            this.offsetY = this.clampY(this.offsetY);
            this.centerSuIfReady();
          })
          .parallelGesture(
            PanGesture({ fingers: 1, distance: 8, direction: PanDirection.All })
              .onActionStart((event: GestureEvent): void => {
                this.startX = this.offsetX;
                this.startY = this.offsetY;
              })
              .onActionUpdate((event: GestureEvent): void => {
                this.offsetX = this.clampX(this.startX + event.offsetX);
                this.offsetY = this.clampY(this.startY + event.offsetY);
              })
          )
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.None)
          .enableScrollInteraction(true)
          .align(Alignment.TopStart)
          .width('100%')
          .layoutWeight(1)
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 水平平移边界：canvasW 已是屏幕尺寸 */
  private clampX(v: number): number {
    return ViewportMath.clampScreenOffset(v, this.canvasW, this.viewW, 24);
  }

  /** 垂直平移边界：canvasH 已包含各宗支标题与间隔的屏幕高度 */
  private clampY(v: number): number {
    return ViewportMath.clampScreenOffset(v, this.canvasH, this.viewH, 24);
  }
}