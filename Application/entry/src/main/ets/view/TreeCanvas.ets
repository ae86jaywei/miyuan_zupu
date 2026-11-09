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
import { EuBox, EuCanvas, SuBox, SuCanvas } from '../service/TreeLayout';
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
  /** 查找定位：只把该族人设为高亮，不打开人员卡片 */
  onFocusPerson: (uid: string) => void = (uid: string): void => {};

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
  /** 当前族谱的宗支根 uid 列表 */
  @State rootUids: string[] = [];
  @State peopleCount: number = 0;
  /** 世代索引（一次构建，供索引条与牒记/现代谱式复用） */
  @State genLabels: string[] = [];
  @State genCounts: number[] = [];
  @State genGroups: Person[][] = [];
  /** 每个宗支在全部宗支堆叠画布中的屏幕起点（已含 zoom） */
  @State branchTops: number[] = [];
  /** 当前显示的宗支索引：一次只渲染一个宗支，避免多支堆叠导致越界不渲染 */
  @State activeBranch: number = 0;
  /** 宗支下拉面板开关（页面内浮层，不走系统弹窗，打开更快） */
  @State branchMenuOpen: boolean = false;
  /** 宗支名称与后代人数：数据刷新时一次算好，避免每次 build 重复遍历 */
  @State branchNames: string[] = [];
  @State branchCounts: number[] = [];
  /** 查找定位请求：传给 Pagoda/Modern 等列表型谱式，由其滚动到目标人员 */
  @State focusUid: string = '';
  /** 人员查找：悬浮按钮打开的搜索面板 */
  @State searchOpen: boolean = false;
  @State searchQuery: string = '';
  @State searchResults: Person[] = [];

  /** 手势起点 */
  private startX: number = 0;
  private startY: number = 0;
  /** 双指缩放起点快照；缩放期间内容跟随双指中心实时平移 */
  private pinchStartScale: number = 1;
  private pinchStartOffsetX: number = 0;
  private pinchStartOffsetY: number = 0;
  /** 锚点是否已锁定：首帧中心可能为 0，等拿到有效双指中心再开始缩放 */
  private pinchAnchorReady: boolean = false;
  /** 双指捏合进行中：单指 Pan 必须让位，否则会用 startX + event.offsetX 覆盖锚点算出的 offset */
  private pinching: boolean = false;
  /** 捏合结束后 Pan 恢复的第一帧要用当前 offset 重设基准，避免把捏合期间的累计位移一次性加回来 */
  private panResume: boolean = false;
  /** 捏合点所在宗支索引，以及该点在支内容坐标系中的位置（不随缩放变化） */
  private pinchAnchorIndex: number = 0;
  private pinchAnchorContentX: number = 0;
  private pinchAnchorContentY: number = 0;
  /** 锁锚防抖：fingerInfos 连续两帧中心稳定后再锁，避免 start 帧中心未稳定就锁死 */
  private pinchCenterPrevX: number = 0;
  private pinchCenterPrevY: number = 0;
  private pinchCenterWait: number = 0;
  /** 最后一帧有效中心与目标缩放：end 帧用它补算，避免“最后一帧 offset 配上一帧 scale” */
  private pinchLastCenterX: number = 0;
  private pinchLastCenterY: number = 0;
  private pinchLastCenterValid: boolean = false;
  private pinchLastTarget: number = 1;
  /** 各宗支内容尺寸（未缩放），用于任意缩放比下即时计算边界 */
  private branchW: number[] = [];
  private branchH: number[] = [];
  /** 苏式谱切换后待把始祖居中（等可视区宽度就绪后再执行一次） */
  private pendingCenter: boolean = true;
  private dieSource: FlatListSource<Person> = new FlatListSource<Person>();
  private diePeople: Person[] = [];
  private dieScroller: Scroller = new Scroller();
  /** 宗支下拉列表的数据源：只用 LazyForEach 创建可见行，宗支多时打开面板不再一次性建满 */
  private branchSource: FlatListSource<string> = new FlatListSource<string>();

  aboutToAppear(): void {
    this.refreshData();
    this.centerOnRootIfReady();
  }

  private isNarrow(): boolean {
    return this.windowWidth < Breakpoint.SM;
  }

  /** 切换谱式后画布尺寸与布局完全变化，平移偏移必须归零 */
  onStyleChanged(): void {
    this.branchMenuOpen = false;
    this.offsetX = 0;
    this.offsetY = 0;
    if (this.style === TreeStyle.DIE) {
      this.rebuildDieSource();
    }
    this.rebuildCanvasSize();
    this.pendingCenter = true;
    this.centerOnRootIfReady();
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
    this.centerOnRootIfReady();
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
    this.branchNames = roots.map((r: PersonNode): string => r.person.name.length > 0 ? r.person.name : r.uid);
    this.branchCounts = roots.map((r: PersonNode): number => r.descendants);
    this.branchSource.setData(this.rootUids);
    if (this.activeBranch >= this.rootUids.length) {
      this.activeBranch = 0;
    }
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
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    if (roots.length === 0) {
      this.canvasW = 0;
      this.canvasH = 0;
      this.branchW = [];
      this.branchH = [];
      this.branchTops = [];
      return;
    }
    const idx: number = this.clampBranchIndex();
    const headerBlock: number = this.branchHeaderBlock();
    const cache: TreeLayoutCache = TreeLayoutCache.getInstance();
    let cw: number = 0;
    let ch: number = 0;
    if (this.style === TreeStyle.SU) {
      const c: SuCanvas = cache.su(roots[idx].uid, [roots[idx]], this.cardWidth(), this.isNarrow(), true);
      cw = c.width;
      ch = c.height;
    } else {
      const c: EuCanvas = cache.eu(roots[idx].uid, [roots[idx]], this.cardWidth(),
        this.isNarrow() ? 66 : 78, true, 6);
      cw = c.width;
      ch = c.height;
    }
    // 只显示当前宗支：画布即该支尺寸，起点在标题之后（含 zoom）
    this.branchW = [cw];
    this.branchH = [ch];
    this.branchTops = [headerBlock];
    this.canvasW = cw * this.scaleValue;
    this.canvasH = headerBlock + ch * this.scaleValue + Spacing.XXL;
    // 手势过程中不夹边界：锚点计算出的 offset 若被这里的边界钳制覆盖，视觉焦点会被硬拉走
    if (clamp) {
      this.offsetX = this.clampX(this.offsetX);
      this.offsetY = this.clampY(this.offsetY);
    }
  }

  private clampBranchIndex(): number {
    if (this.rootUids.length === 0) {
      return 0;
    }
    return Math.min(Math.max(this.activeBranch, 0), this.rootUids.length - 1);
  }

  /** 当前显示的宗支根 uid（单支渲染，直接传给 EuTree/SuTree） */
  private activeRootUid(): string {
    if (this.rootUids.length === 0) {
      return '';
    }
    return this.rootUids[this.clampBranchIndex()];
  }

  /** 当前宗支的内容起点：单支渲染时只有一支，固定取第 0 项 */
  private currentContentTop(): number {
    return this.branchTops.length > 0 ? this.branchTops[0] : 0;
  }

  /** 切换宗支：单支渲染，切换后归零平移并重新居中 */
  private switchBranch(i: number): void {
    this.branchMenuOpen = false;
    if (this.rootUids.length <= 1) {
      return;
    }
    const idx: number = Math.min(Math.max(i, 0), this.rootUids.length - 1);
    if (idx === this.activeBranch) {
      return;
    }
    this.activeBranch = idx;
    this.offsetX = 0;
    this.offsetY = 0;
    this.rebuildCanvasSize(false);
    this.pendingCenter = true;
    this.centerOnRootIfReady();
  }

  /** 宗支下拉菜单：点击标题行弹出，选中的宗支会成为当前显示的唯一宗支 */
  private branchLabel(i: number): string {
    const name: string = i < this.branchNames.length ? this.branchNames[i] : '';
    const count: number = i < this.branchCounts.length ? this.branchCounts[i] : 0;
    return '宗支 ' + (i + 1).toString() + '：' + name + '（' + count.toString() + '人）';
  }

  /** 当前宗支的标题文案 */
  private currentBranchTitle(): string {
    const i: number = this.clampBranchIndex();
    const name: string = i < this.branchNames.length ? this.branchNames[i] : '';
    return '宗支 ' + (i + 1).toString() + '：' + name + ' ▾';
  }

  /** 当前宗支的后代人数 */
  private currentBranchCount(): number {
    const i: number = this.clampBranchIndex();
    return i < this.branchCounts.length ? this.branchCounts[i] : 0;
  }

  /** 沿父/母/配偶链上溯，找到该族人所属宗支索引 */
  private branchIndexOf(uid: string): number {
    const svc: GenealogyService = GenealogyService.getInstance();
    const roots: PersonNode[] = svc.getRoots();
    const seen: Set<string> = new Set<string>();
    let cur: Person | null = svc.getPerson(uid);
    while (cur !== null && !seen.has(cur.uid)) {
      seen.add(cur.uid);
      for (let i: number = 0; i < roots.length; i = i + 1) {
        if (roots[i].uid === cur.uid) {
          return i;
        }
      }
      let nextId: string = cur.fatherId;
      if (nextId.length === 0) {
        nextId = cur.motherId;
      }
      if (nextId.length === 0) {
        nextId = cur.spouseId;
      }
      cur = nextId.length > 0 ? svc.getPerson(nextId) : null;
    }
    return -1;
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
   * 初始视角：把当前宗支的始祖（第一世）卡片居中。
   * 首次进入欧式/苏式、切换谱式、切换宗支时都生效；可视区尺寸就绪后执行一次。
   */
  private centerOnRootIfReady(): void {
    if (!this.pendingCenter) {
      return;
    }
    if (this.style !== TreeStyle.EU && this.style !== TreeStyle.SU) {
      return;
    }
    if (this.viewW <= 0 || this.viewH <= 0 || this.rootUids.length === 0) {
      return;
    }
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    if (roots.length === 0) {
      return;
    }
    const idx: number = this.clampBranchIndex();
    const rootUid: string = roots[idx].uid;
    const cache: TreeLayoutCache = TreeLayoutCache.getInstance();
    let bx: number = -1;
    let by: number = 0;
    let bw: number = 0;
    let bh: number = 0;
    if (this.style === TreeStyle.SU) {
      const c: SuCanvas = cache.su(rootUid, [roots[idx]], this.cardWidth(), this.isNarrow(), true);
      // [PERF] 布局阶段已记录始祖主卡，居中无需再线性扫描数万个 boxes
      const rb: SuBox | null = c.rootBox;
      if (rb !== null) {
        bx = rb.x;
        by = rb.y;
        bw = rb.w;
        bh = rb.h;
      }
    } else {
      const c: EuCanvas = cache.eu(rootUid, [roots[idx]], this.cardWidth(),
        this.isNarrow() ? 66 : 78, true, 6);
      const rb: EuBox | null = c.rootBox;
      if (rb !== null) {
        bx = rb.x;
        by = rb.y;
        bw = rb.w;
        bh = rb.h;
      }
    }
    this.pendingCenter = false;
    if (bx < 0) {
      return;
    }
    const top: number = this.branchTops.length > 0 ? this.branchTops[0] : 0;
    // 屏幕坐标 = 内容坐标 × zoom + 宗支起点 + offset
    this.offsetX = this.clampX(this.viewW / 2 - (bx + bw / 2) * this.scaleValue);
    this.offsetY = this.clampY(this.viewH / 2 - (by + bh / 2) * this.scaleValue - top);
  }

  /** 未选中族人时默认高亮当前宗支的始祖，作为进入欧式/苏式的初始焦点 */
  private effectiveHighlight(rootUid: string): string {
    return this.highlightUid.length > 0 ? this.highlightUid : rootUid;
  }

  /**
   * 双指中心：手势绑定在画布视口上，优先用 fingerInfos 的 localX/localY（相对视口，不含 Scroll/外层变换）。
   * fingerList 中未参与当前手势的手指位置可能为 undefined，不能直接取 [0]/[1]；
   * 有效触点不足时退回 pinchCenterX/Y，它们同样相对手势绑定组件，0 也是合法坐标。
   * 返回空数组表示本帧没有可用的双指中心。
   */
  private pinchCenterOf(event: GestureEvent): number[] {
    const infos: FingerInfo[] = event.fingerInfos;
    if (infos !== undefined && infos.length === 2 &&
      infos[0] !== undefined && infos[1] !== undefined) {
      return [(infos[0].localX + infos[1].localX) / 2,
        (infos[0].localY + infos[1].localY) / 2];
    }
    const fingers: FingerInfo[] = event.fingerList;
    if (fingers !== undefined && fingers.length >= 2) {
      return [event.pinchCenterX, event.pinchCenterY];
    }
    return [];
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

  /** 宗支标题块高度：渲染与锚点换算共用同一份，避免两处各写一个数字产生固定偏差 */
  private branchHeaderBlock(): number {
    return this.rootUids.length > 1 ? BRANCH_HEADER_H + Spacing.S : 0;
  }

  /**
   * 指定宗支在“目标缩放比”下的屏幕起点（不含平移）。
   * 缩放时前一宗支的高度会变化，所以这个值必须按目标 zoom 重算，不能沿用起点快照。
   */
  private branchTopAt(index: number, zoom: number): number {
    if (this.branchTops.length === 0) {
      return 0;
    }
    const headerBlock: number = this.branchHeaderBlock();
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

  /**
   * 锁锚防抖：连续两帧中心位移小于 2vp 才认为中心稳定；慢速移动时最多等 3 帧强制锁定，
   * 避免 onActionStart 那一帧取到未稳定中心后把误差锁进 anchorContent。
   */
  private tryLockAnchor(c: number[]): boolean {
    if (this.pinchAnchorReady) {
      return true;
    }
    if (c.length !== 2) {
      return false;
    }
    if (this.pinchCenterWait > 0) {
      const dx: number = Math.abs(c[0] - this.pinchCenterPrevX);
      const dy: number = Math.abs(c[1] - this.pinchCenterPrevY);
      if (dx + dy <= 2) {
        this.lockAnchor(c[0], c[1]);
        return true;
      }
    }
    this.pinchCenterPrevX = c[0];
    this.pinchCenterPrevY = c[1];
    this.pinchCenterWait = this.pinchCenterWait + 1;
    if (this.pinchCenterWait >= 3) {
      this.lockAnchor(c[0], c[1]);
      return true;
    }
    return false;
  }

  /** 用当前中心与目标缩放解锚点方程：锚点内容点的屏幕位置恒等于双指中心 */
  private applyPinch(c: number[], target: number): void {
    const cx: number = c.length === 2 ? c[0] : this.pinchLastCenterX;
    const cy: number = c.length === 2 ? c[1] : this.pinchLastCenterY;
    const top: number = this.branchTopAt(this.pinchAnchorIndex, target);
    this.offsetX = cx - this.pinchAnchorContentX * target;
    this.offsetY = cy - top - this.pinchAnchorContentY * target;
    this.scaleValue = target;
    this.pinchLastTarget = target;
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

  /** 按关键词在内存族谱中检索（姓名 / 曾用名 / 唯一ID / 字派），最多返回 40 条 */
  private runSearch(q: string): void {
    this.searchQuery = q;
    const key: string = q.trim();
    if (key.length === 0) {
      this.searchResults = [];
      return;
    }
    const keyUpper: string = key.toUpperCase();
    const people: Person[] = GenealogyService.getInstance().getPeople();
    const out: Person[] = [];
    for (let i: number = 0; i < people.length; i = i + 1) {
      const p: Person = people[i];
      if (p.name.includes(key) || p.alias.includes(key) || p.generationChar.includes(key) ||
        p.uid.toUpperCase().includes(keyUpper)) {
        out.push(p);
        if (out.length >= 40) {
          break;
        }
      }
    }
    this.searchResults = out;
  }

  /**
   * 跳转到指定族人：在所属宗支缓存布局里找到夫妻卡，把该卡居中。
   * 布局全部来自 TreeLayoutCache（渲染时已算好），只做线性查找，不会在大谱上重算整树。
   */
  private focusOnUid(uid: string): void {
    const svc: GenealogyService = GenealogyService.getInstance();
    const target: string = uid.toUpperCase();
    // 牒记式：按世代排序列表，直接滚动到目标条目
    if (this.style === TreeStyle.DIE) {
      if (this.diePeople.length === 0) {
        this.rebuildDieSource();
      }
      for (let i: number = 0; i < this.diePeople.length; i = i + 1) {
        if (this.diePeople[i].uid.toUpperCase() === target) {
          this.onFocusPerson(uid);
          this.dieScroller.scrollToIndex(i, true, ScrollAlign.CENTER);
          return;
        }
      }
      this.getUIContext().getPromptAction().showToast({ message: '未找到该族人' });
      return;
    }
    // 宝塔式/现代谱式：组件内部按行/列表滚动定位
    if (this.style === TreeStyle.PAGODA || this.style === TreeStyle.MODERN) {
      this.onFocusPerson(uid);
      this.focusUid = uid;
      return;
    }
    const roots: PersonNode[] = svc.getRoots();
    if (roots.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '未在谱系中找到该族人' });
      return;
    }
    // 目标不在当前宗支时自动切换
    const bi: number = this.branchIndexOf(uid);
    if (bi >= 0 && bi !== this.activeBranch) {
      this.activeBranch = bi;
      this.offsetX = 0;
      this.offsetY = 0;
    }
    this.rebuildCanvasSize(false);
    const idx: number = this.clampBranchIndex();
    const cache: TreeLayoutCache = TreeLayoutCache.getInstance();
    let bx: number = 0;
    let by: number = 0;
    let bw: number = 0;
    let bh: number = 0;
    let hit: boolean = false;
    if (this.style === TreeStyle.SU) {
      const c: SuCanvas = cache.su(roots[idx].uid, [roots[idx]], this.cardWidth(), this.isNarrow(), true);
      for (let k: number = 0; k < c.boxes.length; k = k + 1) {
        if (this.coupleContains(c.boxes[k].node, target)) {
          bx = c.boxes[k].x;
          by = c.boxes[k].y;
          bw = c.boxes[k].w;
          bh = c.boxes[k].h;
          hit = true;
          break;
        }
      }
    } else {
      const c: EuCanvas = cache.eu(roots[idx].uid, [roots[idx]], this.cardWidth(),
        this.isNarrow() ? 66 : 78, true, 6);
      for (let k: number = 0; k < c.boxes.length; k = k + 1) {
        if (this.coupleContains(c.boxes[k].node, target)) {
          bx = c.boxes[k].x;
          by = c.boxes[k].y;
          bw = c.boxes[k].w;
          bh = c.boxes[k].h;
          hit = true;
          break;
        }
      }
    }
    if (!hit) {
      this.getUIContext().getPromptAction().showToast({ message: '未在谱系中找到该族人（可能不在当前谱式覆盖范围）' });
      return;
    }
    this.scaleValue = Math.max(this.scaleValue, BUBBLE_ZOOM);
    this.rebuildCanvasSize(false);
    const top: number = this.branchTops.length > 0 ? this.branchTops[0] : 0;
    this.offsetX = this.clampX(this.viewW / 2 - (bx + bw / 2) * this.scaleValue);
    this.offsetY = this.clampY(this.viewH / 2 - (by + bh / 2) * this.scaleValue - top);
    this.onFocusPerson(uid);
  }

  /** 夫妻卡里包含该族人（主卡本人或其任一配偶）即视为命中 */
  private coupleContains(node: PersonNode, target: string): boolean {
    if (node.uid.toUpperCase() === target) {
      return true;
    }
    for (let k: number = 0; k < node.spouses.length; k = k + 1) {
      if (node.spouses[k].uid.toUpperCase() === target) {
        return true;
      }
    }
    return false;
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

  /** 悬浮工具：当前缩放比例 + 查找族人 + 一键全览（迷失时快速回中心） */
  @Builder
  ViewTools() {
    Column() {
      if (this.style === TreeStyle.EU || this.style === TreeStyle.SU) {
        Text(Math.round(this.scaleValue * 100).toString() + '%')
          .fontSize(10)
          .fontColor(Theme.inkTertiary)
          .backgroundColor(Theme.glass)
          .borderRadius(8)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ bottom: 6 })
      }
      Button('查找')
        .fontSize(12)
        .fontColor(Theme.primary)
        .backgroundColor(Theme.glass)
        .border({ width: 1, color: Theme.glassBorder })
        .borderRadius(16)
        .height(34)
        .padding({ left: 12, right: 12 })
        .margin({ bottom: 6 })
        .onClick((): void => {
          this.searchOpen = !this.searchOpen;
        })
      if (this.style === TreeStyle.EU || this.style === TreeStyle.SU) {
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
    }
    .alignItems(HorizontalAlign.End)
    .margin({ right: 12, bottom: 12 })
  }

  /** 查找面板：输入关键词 → 结果点选即跳转并居中 */
  @Builder
  SearchPanel() {
    Column() {
      Row() {
        Text('查找族人')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
        Text('关闭')
          .fontSize(13)
          .fontColor(Theme.primary)
          .padding({ left: 8, top: 4, bottom: 4 })
          .onClick((): void => {
            this.searchOpen = false;
          })
      }
      .width('100%')
      TextInput({ text: this.searchQuery, placeholder: '姓名 / 曾用名 / 唯一ID / 字派' })
        .height(38)
        .fontSize(14)
        .margin({ top: 8 })
        .onChange((v: string): void => {
          this.runSearch(v);
        })
      if (this.searchQuery.trim().length === 0) {
        Text('输入关键词自动匹配，点击结果即跳到该族人在谱系中的位置')
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 8 })
          .width('100%')
      } else if (this.searchResults.length === 0) {
        Text('未找到匹配的族人')
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 10 })
          .width('100%')
      } else {
        List({ space: 2 }) {
          ForEach(this.searchResults, (p: Person) => {
            ListItem() {
              Row() {
                Text(p.name)
                  .fontSize(14)
                  .fontColor(Theme.ink)
                Text(generationLabel(p.generation) + ' · ' + p.uid)
                  .fontSize(11)
                  .fontColor(Theme.inkTertiary)
                  .margin({ left: 8 })
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
            }
            .onClick((): void => {
              this.searchOpen = false;
              this.focusOnUid(p.uid);
            })
          }, (p: Person) => 'sr_' + p.uid)
        }
        .height(220)
        .margin({ top: 6 })
        .scrollBar(BarState.Auto)
      }
    }
    .width('88%')
    .padding(12)
    .backgroundColor(Theme.card)
    .borderRadius(14)
    .border({ width: 1, color: Theme.glassBorder })
    .margin({ top: 10 })
  }

  @Builder
  SearchOverlay() {
    Column() {
      this.SearchPanel()
      Blank()
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#33000000')
  }

  @Builder
  DieList() {
    List({ space: Spacing.M, scroller: this.dieScroller }) {
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

  /**
   * 宗支下拉面板：页面内浮层，点击标题行立即出现。
   * 不用系统 bindMenu 弹窗，避免欧式大画布下弹窗创建被布局阻塞而出现明显等待。
   */
  @Builder
  BranchDropdown() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick((): void => {
          this.branchMenuOpen = false;
        })
      Column() {
        List() {
          // [PERF] 宗支多时 ForEach 会一次性创建全部行；改用 LazyForEach 只建可见行
          LazyForEach(this.branchSource, (uid: string, i: number) => {
            ListItem() {
              Row() {
                Text((i === this.clampBranchIndex() ? '✓ ' : '') + this.branchLabel(i))
                  .fontSize(13)
                  .fontColor(i === this.clampBranchIndex() ? Theme.primary : Theme.ink)
                  .fontWeight(i === this.clampBranchIndex() ? FontWeight.Medium : FontWeight.Normal)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .height(40)
              .padding({ left: 12, right: 12 })
              .onClick((): void => {
                this.switchBranch(i);
              })
            }
          }, (uid: string, i: number) => 'bm_' + uid + '_' + i.toString())
        }
        .width('100%')
        .height('100%')
        .divider({ strokeWidth: 0.5, color: Theme.glassBorder })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.None)
      }
      .width('92%')
      .height(Math.min(this.rootUids.length * 40 + 2, 320))
      .margin({ left: 12, top: BRANCH_HEADER_H + Spacing.S + 2 })
      .backgroundColor(Theme.card)
      .borderRadius(10)
      .border({ width: 1, color: Theme.glassBorder })
      .shadow({ radius: 14, color: '#33000000', offsetY: 5 })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        if (this.peopleCount === 0) {
          EmptyHint({ icon: '🌱', title: '族谱暂无人物', desc: '点击右下角“＋”创建始祖，开启家族记录' })
        } else if (this.style === TreeStyle.DIE) {
          this.DieList()
        } else if (this.style === TreeStyle.PAGODA) {
          this.GenerationIndex()
          PagodaTree({
            rootUids: this.rootUids,
            layoutVersion: this.dataVersion,
            highlightUid: this.highlightUid,
            focusUid: this.focusUid,
            compact: this.isNarrow(),
            onTapPerson: (uid: string): void => {
              this.onTapPerson(uid);
            }
          })
          .width('100%')
          .layoutWeight(1)
        } else if (this.style === TreeStyle.MODERN) {
          ModernTree({
            layoutVersion: this.dataVersion,
            windowWidth: this.windowWidth,
            highlightUid: this.highlightUid,
            focusUid: this.focusUid,
            minCardWidth: this.windowWidth >= Breakpoint.MD ? 220 : (this.isNarrow() ? 150 : 180),
            onTapPerson: (uid: string): void => {
              this.onTapPerson(uid);
            }
          })
          .width('100%')
          .layoutWeight(1)
        } else {
          this.CanvasBody()
        }
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)

      if (this.peopleCount > 0) {
        this.ViewTools()
      }
      if (this.searchOpen) {
        this.SearchOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 欧式/苏式画布主体：一次只渲染当前宗支，避免多支堆叠越界导致整屏空白 */
  @Builder
  CanvasBody() {
      Stack({ alignContent: Alignment.TopStart }) {
        Stack({ alignContent: Alignment.TopStart }) {
              Column() {
                // [PERF] 单支直接挂一个 EuTree/SuTree 实例：切换宗支时不再因 ForEach key
                // 变化销毁重建整棵子树，只更新 rootUid，交由组件内部 watch 重新裁剪
                if (this.rootUids.length > 0) {
                  Column() {
                    if (this.rootUids.length > 1) {
                      Row() {
                        Text(this.currentBranchTitle())
                          .fontSize(13)
                          .fontWeight(FontWeight.Medium)
                          .fontColor(Theme.primary)
                        Text('后代 ' + this.currentBranchCount().toString() + ' 人')
                          .fontSize(11)
                          .fontColor(Theme.inkTertiary)
                          .margin({ left: 6 })
                      }
                      .width('100%')
                      .height(BRANCH_HEADER_H)
                      .padding({ left: 10, right: 10 })
                      .margin({ bottom: Spacing.S })
                      .borderRadius(8)
                      .backgroundColor(Theme.card)
                      .onClick((): void => {
                        this.branchMenuOpen = !this.branchMenuOpen;
                      })
                    }
                    if (this.style === TreeStyle.EU) {
                      EuTree({
                        rootUid: this.activeRootUid(),
                        layoutVersion: this.dataVersion,
                        highlightUid: this.effectiveHighlight(this.activeRootUid()),
                        cardWidth: this.cardWidth(),
                        dense: this.isNarrow(),
                        showSpouse: true,
                        offsetX: $offsetX,
                        offsetY: $offsetY,
                        viewWidth: this.viewW,
                        viewHeight: this.viewH,
                        zoom: this.scaleValue,
                        interacting: this.interacting,
                        contentTop: this.currentContentTop(),
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
                        rootUid: this.activeRootUid(),
                        layoutVersion: this.dataVersion,
                        highlightUid: this.effectiveHighlight(this.activeRootUid()),
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
                        contentTop: this.currentContentTop(),
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
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ bottom: 16 })
            }
            .width('100%')
            .height('100%')
            .clip(true)
            .onAreaChange((oldArea: Area, newArea: Area): void => {
              this.viewW = Number(newArea.width);
              this.viewH = Number(newArea.height);
              this.offsetX = this.clampX(this.offsetX);
              this.offsetY = this.clampY(this.offsetY);
              this.centerOnRootIfReady();
            })
            .parallelGesture(
              GestureGroup(GestureMode.Parallel,
                PanGesture({ fingers: 1, distance: 8, direction: PanDirection.All })
                  .onActionStart((event: GestureEvent): void => {
                    // 双指捏合期间单指 Pan 会让位：fingers 是“最少手指数”，两根手指时 Pan 仍会回调
                    if (this.pinching) {
                      return;
                    }
                    this.interacting = true;
                    this.startX = this.offsetX;
                    this.startY = this.offsetY;
                  })
                  .onActionUpdate((event: GestureEvent): void => {
                    if (this.pinching) {
                      return;
                    }
                    if (this.panResume) {
                      // 恢复后的第一帧不产生位移：以当前 offset 为基准，吃掉捏合期间累计的 offsetX/offsetY
                      this.panResume = false;
                      this.startX = this.offsetX - event.offsetX;
                      this.startY = this.offsetY - event.offsetY;
                    }
                    this.offsetX = this.clampXFree(this.startX + event.offsetX);
                    this.offsetY = this.clampYFree(this.startY + event.offsetY);
                  })
                  .onActionEnd((event: GestureEvent): void => {
                    if (this.pinching) {
                      return;
                    }
                    this.interacting = false;
                  }),
                PinchGesture({ fingers: 2 })
                  .onActionStart((event: GestureEvent): void => {
                    this.pinching = true;
                    this.interacting = true;
                    this.pinchStartScale = this.scaleValue;
                    this.pinchStartOffsetX = this.offsetX;
                    this.pinchStartOffsetY = this.offsetY;
                    this.pinchAnchorReady = false;
                    this.pinchAnchorIndex = 0;
                    this.pinchCenterWait = 0;
                    this.pinchLastCenterValid = false;
                    this.pinchLastTarget = this.pinchStartScale;
                    // 先记录 start 帧中心，update 里等中心稳定两帧再锁，避免未稳定中心被锁死
                    const c: number[] = this.pinchCenterOf(event);
                    if (c.length === 2) {
                      this.pinchCenterPrevX = c[0];
                      this.pinchCenterPrevY = c[1];
                      this.pinchCenterWait = 1;
                    }
                  })
                  .onActionUpdate((event: GestureEvent): void => {
                    const c: number[] = this.pinchCenterOf(event);
                    if (!this.tryLockAnchor(c)) {
                      return;
                    }
                    if (c.length === 2) {
                      this.pinchLastCenterX = c[0];
                      this.pinchLastCenterY = c[1];
                      this.pinchLastCenterValid = true;
                    }
                    // 先 clamp 再解方程，保证方程用的 target 与实际渲染的 scale 一致
                    const target: number = this.clampZoom(this.pinchStartScale * event.scale);
                    this.applyPinch(c, target);
                    // 手势中不再 rebuildCanvasSize：它修改 branchTops/canvasW 等状态会触发额外重渲染，
                    // 边界统一在 end/cancel 处理一次
                  })
                  .onActionEnd((event: GestureEvent): void => {
                    this.pinching = false;
                    this.panResume = true;
                    this.interacting = false;
                    // 结束帧补算最后一次锚点：部分设备 end 帧 scale 回落到 1，此时沿用 update 的目标值
                    if (this.pinchAnchorReady && this.pinchLastCenterValid) {
                      // 用最后一次 update 的中心：end 帧手指已抬起，实时中心可能正在分开，不能拿来当锚点
                      const center: number[] = [this.pinchLastCenterX, this.pinchLastCenterY];
                      const fromEvent: number = this.clampZoom(this.pinchStartScale * event.scale);
                      const endTarget: number = Math.abs(event.scale - 1) < 0.0001 &&
                        Math.abs(this.pinchLastTarget - this.pinchStartScale) > 0.0001
                        ? this.pinchLastTarget : fromEvent;
                      this.applyPinch(center, endTarget);
                    }
                    // 抬手也不重新居中：内容小于视口时居中会把卡片从手指处拉走
                    this.rebuildCanvasSize(false);
                  })
                  .onActionCancel((): void => {
                    this.pinching = false;
                    this.panResume = true;
                    this.interacting = false;
                    this.rebuildCanvasSize(false);
                  })
              )
            )
            .align(Alignment.TopStart)
            .width('100%')
            .height('100%')
        if (this.branchMenuOpen && this.rootUids.length > 1) {
          this.BranchDropdown()
        }
      }
      .width('100%')
      .height('100%')
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
