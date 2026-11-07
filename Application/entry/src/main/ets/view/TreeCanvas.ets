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
/** 手势缩放的上下限，避免缩到不可见或放大过度；下限留给超大族谱全览 */
const MIN_ZOOM: number = 0.05;
const MAX_ZOOM: number = 1.5;
/** 点击聚合气泡后放大到的目标比例 */
const BUBBLE_ZOOM: number = 0.85;

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
  onTapPerson: (uid: string) => void = (uid: string): void => {};

  /** 实际渲染缩放：双指捏合写入这里 */
  @State scaleValue: number = 1;
  /** 手势进行中：子画布降级渲染，抬手后恢复 */
  @State interacting: boolean = false;
  /** 欧式/苏式画布平移偏移（拖到哪停到哪） */
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  /** 画布内容尺寸（未缩放），由布局缓存计算 */
  @State canvasW: number = 0;
  @State canvasH: number = 0;
  /** 容器可视区尺寸 */
  @State viewW: number = 0;
  @State viewH: number = 0;
  /** 画布在应用窗口中的位置：把手指的窗口坐标换算成画布坐标，避免 local 坐标系不确定 */
  private viewGlobalX: number = 0;
  private viewGlobalY: number = 0;
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
  /** 双指缩放起点快照：同时记录中心，双指整体移动时内容跟随平移 */
  private pinchStartScale: number = 1;
  private pinchStartOffsetX: number = 0;
  private pinchStartOffsetY: number = 0;
  private pinchStartCenterX: number = 0;
  private pinchStartCenterY: number = 0;
  /** 锚点是否已锁定：首帧中心可能为 0，等拿到有效双指中心再开始缩放 */
  private pinchAnchorReady: boolean = false;
  /** 捏合点所在宗支索引，以及该点在支内容坐标系中的位置（不随缩放变化） */
  private pinchAnchorIndex: number = 0;
  private pinchAnchorContentX: number = 0;
  private pinchAnchorContentY: number = 0;
  /** 各宗支内容尺寸（未缩放），用于任意缩放比下即时计算边界 */
  private branchW: number[] = [];
  private branchH: number[] = [];
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

  /** 只在数据/谱式/宽度/缩放变化时调用；手势中可传 false 跳过边界钳制，避免把锚点硬拉回 */
  private rebuildCanvasSize(clamp: boolean = true): void {
    if (this.style !== TreeStyle.EU && this.style !== TreeStyle.SU) {
      return;
    }
    const cache: TreeLayoutCache = TreeLayoutCache.getInstance();
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    const headerBlock: number = roots.length > 1 ? BRANCH_HEADER_H + Spacing.S : 0;
    let w: number = 0;
    let screenCursor: number = 0;
    const tops: number[] = [];
    const ws: number[] = [];
    const hs: number[] = [];
    for (let i: number = 0; i < roots.length; i = i + 1) {
      // tops 记录该支 EuTree/SuTree 在屏幕上的起点（标题之后，已含 zoom）
      tops.push(screenCursor + headerBlock);
      let cw: number = 0;
      let ch: number = 0;
      if (this.style === TreeStyle.SU) {
        const c: SuCanvas = cache.su(roots[i].uid, [roots[i]], this.cardWidth(), this.isNarrow(), true);
        cw = c.width;
        ch = c.height;
      } else {
        const c: EuCanvas = cache.eu(roots[i].uid, [roots[i]], this.cardWidth(),
          this.isNarrow() ? 66 : 78, true, 6);
        cw = c.width;
        ch = c.height;
      }
      ws.push(cw);
      hs.push(ch);
      w = Math.max(w, cw);
      screenCursor = screenCursor + headerBlock + ch * this.scaleValue + Spacing.XXL;
    }
    this.branchW = ws;
    this.branchH = hs;
    this.branchTops = tops;
    // canvasW/canvasH 统一存“屏幕尺寸”（已含 zoom），与多宗支标题/间隔的真实占位一致
    this.canvasW = w * this.scaleValue;
    this.canvasH = screenCursor;
    // 手势过程中不夹边界：锚点计算出的 offset 若被这里的边界钳制覆盖，视觉焦点会被硬拉走
    if (clamp) {
      this.offsetX = this.clampX(this.offsetX);
      this.offsetY = this.clampY(this.offsetY);
    }
  }

  private collectSize(w: number, h: number): void {
    // 只在严格变大时写入，避免拖动时每帧触发父组件重渲染
    const sw: number = w * this.scaleValue;
    const sh: number = h * this.scaleValue;
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
    this.offsetX = this.clampX(this.viewW / 2 - cx * this.scaleValue);
    this.offsetY = 0;
  }

  /** 双指中心：用两指相对应用窗口的 globalX/globalY 减去画布窗口位置，得到确定的画布坐标 */
  private pinchCenterOf(event: GestureEvent): number[] {
    const fingers: FingerInfo[] = event.fingerList;
    if (fingers !== undefined && fingers.length >= 2 &&
      fingers[0].globalX !== undefined && fingers[1].globalX !== undefined) {
      const gx: number = (fingers[0].globalX + fingers[1].globalX) / 2;
      const gy: number = (fingers[0].globalY + fingers[1].globalY) / 2;
      return [gx - this.viewGlobalX, gy - this.viewGlobalY];
    }
    if (event.pinchCenterX > 0 || event.pinchCenterY > 0) {
      return [event.pinchCenterX, event.pinchCenterY];
    }
    return [-1, -1];
  }

  /**
   * 捏合点所在的宗支索引。多宗支堆叠时各支的屏幕起点不同，锚点必须按所在支换算，
   * 否则缩放会把内容带向第一支。
   */
  private anchorIndexAt(centerY: number, offsetY: number, zoom: number): number {
    if (this.branchTops.length === 0) {
      return 0;
    }
    const y: number = centerY - offsetY;
    let nearestIdx: number = 0;
    let nearestDist: number = Number.MAX_VALUE;
    for (let i: number = 0; i < this.branchTops.length; i = i + 1) {
      const top: number = this.branchTops[i];
      const bottom: number = top + (i < this.branchH.length ? this.branchH[i] : 0) * zoom;
      if (y >= top && y <= bottom) {
        return i;
      }
      const dist: number = y < top ? top - y : y - bottom;
      if (dist < nearestDist) {
        nearestDist = dist;
        nearestIdx = i;
      }
    }
    return nearestIdx;
  }

  /**
   * 指定宗支在“目标缩放比”下的屏幕起点（不含平移）。
   * 缩放时前一宗支的高度会变化，所以这个值必须按目标 zoom 重算，不能沿用起点快照。
   */
  private branchTopAt(index: number, zoom: number): number {
    if (this.branchTops.length === 0) {
      return 0;
    }
    const headerBlock: number = this.rootUids.length > 1 ? BRANCH_HEADER_H + Spacing.S : 0;
    let cursor: number = 0;
    for (let i: number = 0; i < index; i = i + 1) {
      const h: number = i < this.branchH.length ? this.branchH[i] : 0;
      cursor = cursor + headerBlock + h * zoom + Spacing.XXL;
    }
    return cursor + headerBlock;
  }

  /** 锁定手指下的内容点：后续所有缩放都以它为中心，避免任何一帧重新取中心造成漂移 */
  private lockAnchor(cx: number, cy: number): void {
    const z: number = this.pinchStartScale > 0 ? this.pinchStartScale : 1;
    const idx: number = this.anchorIndexAt(cy, this.pinchStartOffsetY, z);
    const top: number = this.branchTopAt(idx, z);
    this.pinchAnchorIndex = idx;
    this.pinchAnchorContentX = (cx - this.pinchStartOffsetX) / z;
    this.pinchAnchorContentY = (cy - top - this.pinchStartOffsetY) / z;
    this.pinchAnchorReady = true;
  }

  private clampZoom(v: number): number {
    if (v < MIN_ZOOM) {
      return MIN_ZOOM;
    }
    if (v > MAX_ZOOM) {
      return MAX_ZOOM;
    }
    return v;
  }

  /** 一键全览：按内容尺寸取最合适的缩放，并把整谱居中 */
  private resetView(): void {
    if (this.style !== TreeStyle.EU && this.style !== TreeStyle.SU) {
      return;
    }
    if (this.branchW.length === 0) {
      this.rebuildCanvasSize();
    }
    if (this.viewW <= 0 || this.viewH <= 0 || this.branchW.length === 0) {
      return;
    }
    const header: number = this.rootUids.length > 1 ? BRANCH_HEADER_H + Spacing.S : 0;
    let cw: number = 0;
    for (let i: number = 0; i < this.branchW.length; i = i + 1) {
      cw = Math.max(cw, this.branchW[i]);
    }
    let ch: number = 0;
    for (let i: number = 0; i < this.branchH.length; i = i + 1) {
      ch = ch + header + this.branchH[i] + Spacing.XXL;
    }
    if (cw <= 0 || ch <= 0) {
      return;
    }
    const fit: number = this.clampZoom(Math.min(this.viewW / cw, this.viewH / ch, 1));
    this.scaleValue = fit;
    this.rebuildCanvasSize();
    this.offsetX = this.clampX((this.viewW - cw * fit) / 2);
    this.offsetY = this.clampY((this.viewH - ch * fit) / 2);
  }

  /** 点击聚合气泡：以该内容点为中心放大到可读层级 */
  private zoomInto(contentX: number, contentY: number, contentTop: number): void {
    if (this.scaleValue >= BUBBLE_ZOOM) {
      return;
    }
    this.scaleValue = BUBBLE_ZOOM;
    this.rebuildCanvasSize();
    this.offsetX = this.clampX(this.viewW / 2 - contentX * this.scaleValue);
    this.offsetY = this.clampY(this.viewH / 2 - contentY * this.scaleValue - contentTop);
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

  /** 悬浮工具：当前缩放比例 + 一键全览（迷失时快速回中心） */
  @Builder
  ViewTools() {
    Column() {
      Text(Math.round(this.scaleValue * 100).toString() + '%')
        .fontSize(10)
        .fontColor(Theme.inkTertiary)
        .backgroundColor(Theme.glass)
        .borderRadius(8)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .margin({ bottom: 6 })
      Button('全览')
        .fontSize(12)
        .fontColor(Theme.primary)
        .backgroundColor(Theme.glass)
        .border({ width: 1, color: Theme.glassBorder })
        .borderRadius(16)
        .height(34)
        .padding({ left: 12, right: 12 })
        .onClick((): void => {
          this.resetView();
        })
    }
    .alignItems(HorizontalAlign.End)
    .margin({ right: 12, bottom: 12 })
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
    .contentEndOffset(16)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.None)
  }

  build() {
    Column() {
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
          Stack({ alignContent: Alignment.BottomEnd }) {
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
                        zoom: this.scaleValue,
                        interacting: this.interacting,
                        contentTop: ri < this.branchTops.length ? this.branchTops[ri] : 0,
                        onTapPerson: (id: string): void => {
                          this.onTapPerson(id);
                        },
                        onZoomAt: (cx: number, cy: number, top: number): void => {
                          this.zoomInto(cx, cy, top);
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
                        zoom: this.scaleValue,
                        interacting: this.interacting,
                        contentTop: ri < this.branchTops.length ? this.branchTops[ri] : 0,
                        onTapPerson: (id: string): void => {
                          this.onTapPerson(id);
                        },
                        onZoomAt: (cx: number, cy: number, top: number): void => {
                          this.zoomInto(cx, cy, top);
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
              .padding({ bottom: 16 })
            }
            .scrollable(ScrollDirection.None)
            .onAreaChange((oldArea: Area, newArea: Area): void => {
              this.viewW = Number(newArea.width);
              this.viewH = Number(newArea.height);
              this.viewGlobalX = Number(newArea.globalPosition.x);
              this.viewGlobalY = Number(newArea.globalPosition.y);
              this.offsetX = this.clampX(this.offsetX);
              this.offsetY = this.clampY(this.offsetY);
              this.centerSuIfReady();
            })
            .parallelGesture(
              GestureGroup(GestureMode.Parallel,
                PanGesture({ fingers: 1, distance: 8, direction: PanDirection.All })
                  .onActionStart((event: GestureEvent): void => {
                    this.interacting = true;
                    this.startX = this.offsetX;
                    this.startY = this.offsetY;
                  })
                  .onActionUpdate((event: GestureEvent): void => {
                    this.offsetX = this.clampXFree(this.startX + event.offsetX);
                    this.offsetY = this.clampYFree(this.startY + event.offsetY);
                  })
                  .onActionEnd((event: GestureEvent): void => {
                    this.interacting = false;
                  }),
                PinchGesture({ fingers: 2 })
                  .onActionStart((event: GestureEvent): void => {
                    this.interacting = true;
                    this.pinchStartScale = this.scaleValue;
                    this.pinchStartOffsetX = this.offsetX;
                    this.pinchStartOffsetY = this.offsetY;
                    this.pinchAnchorReady = false;
                    this.pinchAnchorIndex = 0;
                    const c: number[] = this.pinchCenterOf(event);
                    if (c[0] >= 0) {
                      // 首帧就拿到有效中心时直接锁定，避免 update 第一帧再跳一次
                      this.pinchStartCenterX = c[0];
                      this.pinchStartCenterY = c[1];
                      this.lockAnchor(c[0], c[1]);
                    }
                  })
                  .onActionUpdate((event: GestureEvent): void => {
                    const c: number[] = this.pinchCenterOf(event);
                    if (!this.pinchAnchorReady) {
                      // 中心无效时等待下一帧：绝不能用视口中心冒充手指位置，否则必然丢焦点
                      if (c[0] < 0) {
                        return;
                      }
                      this.pinchStartCenterX = c[0];
                      this.pinchStartCenterY = c[1];
                      this.lockAnchor(c[0], c[1]);
                    }
                    const target: number = this.clampZoom(this.pinchStartScale * event.scale);
                    const cx: number = c[0] >= 0 ? c[0] : this.pinchStartCenterX;
                    const cy: number = c[1] >= 0 ? c[1] : this.pinchStartCenterY;
                    // 锚点内容点固定不动：屏幕 = 内容 × zoom + 宗支起点（随 zoom 重算） + offset
                    const top: number = this.branchTopAt(this.pinchAnchorIndex, target);
                    this.offsetX = cx - this.pinchAnchorContentX * target;
                    this.offsetY = cy - top - this.pinchAnchorContentY * target;
                    this.scaleValue = target;
                    // 手势中不夹边界，抬手后再夹，避免锚点被边界钳制硬拉走
                    this.rebuildCanvasSize(false);
                  })
                  .onActionEnd((event: GestureEvent): void => {
                    this.interacting = false;
                    // 抬手也不重新居中：内容小于视口时居中会把卡片从手指处拉走
                    this.rebuildCanvasSize(false);
                  })
                  .onActionCancel((): void => {
                    this.interacting = false;
                    this.rebuildCanvasSize(false);
                  })
              )
            )
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.None)
            .enableScrollInteraction(true)
            .align(Alignment.TopStart)
            .width('100%')
            .height('100%')

            this.ViewTools()
          }
          .width('100%')
          .layoutWeight(1)
        }
      }
    }
    .width('100%')
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

  /** 拖动时的水平边界：内容小于视口时不强制居中，避免一松手就跳回屏幕中间 */
  private clampXFree(v: number): number {
    return ViewportMath.clampScreenOffsetFree(v, this.canvasW, this.viewW, 24);
  }

  private clampYFree(v: number): number {
    return ViewportMath.clampScreenOffsetFree(v, this.canvasH, this.viewH, 24);
  }
}
