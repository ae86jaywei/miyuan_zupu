import { T, uiFontFamily } from 'common_base';
import { SR } from '../service/ServiceRegistry';

import { PersonNode } from 'common_base';
import { Person } from 'common_base';
import { TreeStyle, generationLabel } from 'common_base';
import { EuTree } from '../components/tree/EuTree';
import { SuTree } from '../components/tree/SuTree';
import { PagodaTree } from '../components/tree/PagodaTree';
import { DieRecord } from '../components/tree/DieRecord';
import { DieJiIndex } from '../service/DieJiText';
import { ModernTree } from '../components/tree/ModernTree';
import { PagedTree } from '../components/tree/PagedTree';
import { SearchField } from 'common_ui';
import { EmptyHint } from 'common_ui';
import { Theme, Spacing } from 'common_base';
import { GenealogyService } from '../service/GenealogyService';
import { compactUid } from 'common_base';
import { TreeLayoutCache } from '../service/TreeLayoutCache';
import { PrintBook } from '../service/PaginationService';
import { EuBox, EuCanvas, SuBox, SuCanvas } from 'common_base';
import { ViewportMath } from 'common_base';
import { Breakpoint } from 'common_base';
import { FlatListSource } from 'common_base';
import { TreePerf } from 'common_base';

/** 多宗支时每支标题的固定高度（16 行高 + 8 底部间距），用于精确计算裁剪起点 */
const BRANCH_HEADER_H: number = 24;
/** 手势缩放的上下限，避免缩到不可见或放大过度；下限留给超大族谱全览 */
const MIN_ZOOM: number = 0.05;
const MAX_ZOOM: number = 1.5;
/** 点击聚合气泡后放大到的目标比例 */
const BUBBLE_ZOOM: number = 0.85;
/** 左下角小地图尺寸（vp） */
const MINI_W: number = 84;
const MINI_H: number = 58;

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
  /** 订阅简繁设置：切换后重绘（T() 依赖全局状态，需显式订阅） */
  @StorageProp('gpScript') script: string = 'hans';
  @Prop @Watch('onStyleChanged') style: string = TreeStyle.EU;
  @StorageProp('gpVersion') @Watch('onDataVersionChanged') dataVersion: number = 0;
  /**
   * 分页状态以 AppStorage 为准：页面顶部的谱式导航栏同样按它决定显隐。
   * 之前只靠 @State 本组件自己维护，页面层无法在切换谱式时退出分页，
   * 导航栏就会在其它谱式下一直隐藏。
   */
  @StorageProp('pagedMode') @Watch('onPagedModeStorageChanged') pagedStorage: boolean = false;
  @Prop @Watch('onHighlightChanged') highlightUid: string = '';
  @Prop showPrivate: boolean = true;
  @Prop @Watch('onWindowWidthChanged') windowWidth: number = 360;
  /** 页面已有常驻详情栏（三栏）：点击卡片直接显示详情，不再弹「长按查看」提示 */
  @Prop tapOpensDetail: boolean = false;
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
  /** 画布在应用窗口中的位置：把手指的窗口坐标换算成画布坐标，避免 local 坐标系不确定 */
  private viewGlobalX: number = 0;
  private viewGlobalY: number = 0;
  /** 当前族谱的宗支根 uid 列表 */
  @State rootUids: string[] = [];
  /** uid → 渲染节点索引：面包屑、定位与气泡跳转共用，数据刷新时重建 */
  private nodeIndex: Map<string, PersonNode> = new Map<string, PersonNode>();
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
  /** 分页视图：按 320×220mm 横版纸页排版，一页一屏，跨页不画线 */
  @State pagedMode: boolean = false;
  @State pageNo: number = 1;
  /**
   * 视图语义状态：MAP=全景地图（房支聚簇）、PAGED=分页阅读、FOCUS=聚焦单人。
   * 以 pagedMode 为渲染真相源，viewState 只描述当前交互语义，供导航/面包屑判断。
   */
  @State viewState: string = 'MAP';
  /** 面包屑：当前人物上溯的祖先链（根→当前，最多 4 级） */
  @State trailUids: string[] = [];
  @State trailNames: string[] = [];
  /** 卡片点击选中：与页面高亮解耦，点击只选中、不打开详情 */
  @State selectedUid: string = '';
  /** 选中后的「长按查看详情」操作提示条 */
  @State hintVisible: boolean = false;
  /** 提示条位置：跟随被选中的卡片（不再固定在屏幕底部） */
  @State hintX: number = 0;
  @State hintY: number = 0;
  private hintTimer: number = -1;
  /** 布局计算进行中：先渲染加载态，避免切换谱式那一帧同时做大布局与大渲染 */
  @State layoutBusy: boolean = false;

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
  /** 双指捏合进行中：单指 Pan 必须让位，否则会用 startX + event.offsetX 覆盖锚点算出的 offset */
  private pinching: boolean = false;
  /** 捏合结束后 Pan 恢复的第一帧要用当前 offset 重设基准，避免把捏合期间的累计位移一次性加回来 */
  private panResume: boolean = false;
  /** 捏合点所在宗支索引，以及该点在支内容坐标系中的位置（不随缩放变化） */
  private pinchAnchorIndex: number = 0;
  private pinchAnchorContentX: number = 0;
  private pinchAnchorContentY: number = 0;
  /** 各宗支内容尺寸（未缩放），用于任意缩放比下即时计算边界 */
  private branchW: number[] = [];
  private branchH: number[] = [];
  /** 苏式谱切换后待把始祖居中（等可视区宽度就绪后再执行一次） */
  private pendingCenter: boolean = true;
  /** 延迟布局令牌：连续切换时只让最后一次计算落地 */
  private layoutToken: number = 0;
  /** 延迟布局定时器：组件销毁时清掉，避免回调操作已卸载的页面 */
  private layoutTimer: number = -1;
  /** 上一次可视区尺寸：折叠展开/横竖屏/窗口拖拽后用它判断是否需要重新居中 */
  private lastViewW: number = 0;
  private lastViewH: number = 0;
  private dieSource: FlatListSource<Person> = new FlatListSource<Person>();
  private diePeople: Person[] = [];
  /** 牒记正文关系索引：随列表数据一次重建，卡片逐条复用 */
  private dieIndex: DieJiIndex | null = null;
  private dieScroller: Scroller = new Scroller();
  /** 宗支下拉列表的数据源：只用 LazyForEach 创建可见行，宗支多时打开面板不再一次性建满 */
  private branchSource: FlatListSource<string> = new FlatListSource<string>();

  aboutToAppear(): void {
    this.pagedMode = this.pagedStorage;
    this.syncPagedMode();
    this.refreshData();
    this.pendingCenter = true;
    if (this.isPagedStyle()) {
      this.scheduleLayout();
    } else {
      this.centerOnRootIfReady();
    }
  }

  /**
   * 先把加载态渲染出来，再在下一帧计算布局。
   * 大树切入欧式/苏式时，布局与卡片渲染都发生在同一帧会让主线程长时间无响应；
   * 拆成两帧后，用户先看到“正在切换谱式”，计算完成后再一次性出图。
   */
  private scheduleLayout(): void {
    this.layoutBusy = true;
    const token: number = this.layoutToken + 1;
    this.layoutToken = token;
    if (this.layoutTimer >= 0) {
      clearTimeout(this.layoutTimer);
    }
    this.layoutTimer = setTimeout((): void => {
      this.layoutTimer = -1;
      if (token !== this.layoutToken) {
        return;
      }
      // 分页视图由 PagedTree 自己按页排版，不再先算一遍连续画布，省掉一次全支布局
      if (!this.pagedMode) {
        this.rebuildCanvasSize();
      }
      this.pendingCenter = true;
      this.centerOnRootIfReady();
      this.layoutBusy = false;
    }, 32);
  }

  aboutToDisappear(): void {
    this.layoutToken = this.layoutToken + 1;
    if (this.layoutTimer >= 0) {
      clearTimeout(this.layoutTimer);
      this.layoutTimer = -1;
    }
    if (this.hintTimer >= 0) {
      clearTimeout(this.hintTimer);
      this.hintTimer = -1;
    }
  }

  /** AppStorage 里的分页状态变化（本组件点“分页/连续”，或页面切换谱式时复位） */
  onPagedModeStorageChanged(): void {
    const next: boolean = this.pagedStorage;
    if (next === this.pagedMode) {
      return;
    }
    this.pagedMode = next;
    this.viewState = next ? 'PAGED' : 'MAP';
    if (next) {
      this.pageNo = 1;
      // 分页册要按全谱重排，先出加载态再做计算，避免切换那一帧整页卡住
      this.scheduleLayout();
    } else {
      this.pendingCenter = true;
      this.centerOnRootIfReady();
    }
  }

  private isNarrow(): boolean {
    return this.windowWidth < Breakpoint.SM;
  }

  /** 切换谱式后画布尺寸与布局完全变化，平移偏移必须归零 */
  onStyleChanged(): void {
    this.branchMenuOpen = false;
    this.selectedUid = '';
    this.hintVisible = false;
    this.offsetX = 0;
    this.offsetY = 0;
    if (!this.isPagedStyle()) {
      // 分页只属于欧式/苏式：换到其它谱式必须同步退出，页面导航栏依赖这个状态
      this.exitPagedMode();
    }
    this.pageNo = 1;
    if (this.style === TreeStyle.DIE) {
      this.rebuildDieSource();
    }
    this.pendingCenter = true;
    if (this.isPagedStyle()) {
      this.scheduleLayout();
    } else {
      this.layoutBusy = false;
    }
  }

  private isPagedStyle(): boolean {
    return this.style === TreeStyle.EU || this.style === TreeStyle.SU;
  }

  /**
   * 退出分页并回到连续视图。
   * 以 AppStorage 为唯一出口：页面上的谱式导航栏只在连续视图显示，
   * 仅改组件内部 @State 的话页面拿不到这个变化，导航栏会一直隐藏。
   */
  private exitPagedMode(): void {
    this.pagedMode = false;
    this.pageNo = 1;
    if (AppStorage.get<boolean>('pagedMode') === true) {
      AppStorage.setOrCreate<boolean>('pagedMode', false);
    }
  }

  /** 分页视图只属于欧式/苏式：其它谱式下必须退出分页，否则谱式导航栏会一直不显示 */
  private syncPagedMode(): void {
    if (!this.isPagedStyle()) {
      this.exitPagedMode();
    }
  }

  onHighlightChanged(): void {
    // 页面高亮（搜索/详情联动）优先于本地点选，清掉本地选中避免盖住新目标
    this.selectedUid = '';
    this.hintVisible = false;
    this.rebuildTrail();
    if (this.style === TreeStyle.DIE) {
      this.dieSource.setData(this.diePeople);
    }
  }

  /** 族人数据变化：丢弃旧布局，重建宗支索引与世代索引 */
  onDataVersionChanged(): void {
    SR.treeCache().invalidate();
    SR.pagination().invalidate();
    this.pageNo = 1;
    this.refreshData();
    this.offsetX = 0;
    this.offsetY = 0;
    this.pendingCenter = true;
    if (this.isPagedStyle()) {
      this.scheduleLayout();
    } else {
      this.centerOnRootIfReady();
    }
  }

  /** 断点/窗口宽度变化会改变卡片宽度与密度，画布尺寸与各支起点需重算 */
  onWindowWidthChanged(): void {
    if (this.isPagedStyle()) {
      this.pendingCenter = true;
      this.scheduleLayout();
    } else {
      this.rebuildCanvasSize();
    }
  }

  private refreshData(): void {
    this.syncPagedMode();
    TreePerf.begin('tree_groups');
    const svc: GenealogyService = SR.genealogy();
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
    this.rebuildNodeIndex(roots);
    this.rebuildTrail();
  }

  private rebuildDieSource(): void {
    const people: Person[] = [];
    this.genGroups.forEach((group: Person[]): void => {
      group.forEach((person: Person): void => {
        people.push(person);
      });
    });
    this.diePeople = people;
    this.dieIndex = new DieJiIndex(people);
    this.dieSource.setData(people);
  }

  /** 只在数据/谱式/宽度/缩放变化时调用；手势中可传 false 跳过边界钳制，避免把锚点硬拉回 */
  private rebuildCanvasSize(clamp: boolean = true): void {
    if (this.style !== TreeStyle.EU && this.style !== TreeStyle.SU) {
      return;
    }
    const roots: PersonNode[] = SR.genealogy().getRoots();
    if (roots.length === 0) {
      this.canvasW = 0;
      this.canvasH = 0;
      this.branchW = [];
      this.branchH = [];
      this.branchTops = [];
      return;
    }
    const idx: number = this.clampBranchIndex();
    const headerBlock: number = roots.length > 1 ? BRANCH_HEADER_H + Spacing.S : 0;
    const cache: TreeLayoutCache = SR.treeCache();
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

  /** 重建 uid → 节点索引：面包屑、定位与气泡跳转共用 */
  private rebuildNodeIndex(roots: PersonNode[]): void {
    this.nodeIndex.clear();
    const stack: PersonNode[] = [];
    for (let i: number = 0; i < roots.length; i = i + 1) {
      stack.push(roots[i]);
    }
    while (stack.length > 0) {
      const n: PersonNode = stack.pop() as PersonNode;
      if (this.nodeIndex.has(n.uid)) {
        continue;
      }
      this.nodeIndex.set(n.uid, n);
      for (let k: number = 0; k < n.children.length; k = k + 1) {
        stack.push(n.children[k]);
      }
    }
  }

  /** 面包屑：当前选中/高亮人物上溯到本支根，最多保留 4 级 */
  private rebuildTrail(): void {
    const uid: string = this.selectedUid.length > 0 ? this.selectedUid :
      (this.highlightUid.length > 0 ? this.highlightUid : this.activeRootUid());
    this.rebuildTrailFor(uid);
  }

  private rebuildTrailFor(uid: string): void {
    const chain: PersonNode[] = [];
    let cur: PersonNode | undefined = this.nodeIndex.get(uid);
    let guard: number = 0;
    while (cur !== undefined && guard < 64) {
      chain.unshift(cur);
      const parent: PersonNode | null = cur.father !== null ? cur.father : cur.mother;
      if (parent === null || parent === cur) {
        break;
      }
      cur = this.nodeIndex.get(parent.uid);
      guard = guard + 1;
    }
    if (chain.length > 4) {
      chain.splice(0, chain.length - 4);
    }
    this.trailUids = chain.map((n: PersonNode): string => n.uid);
    this.trailNames = chain.map((n: PersonNode): string =>
      n.person.name.length > 0 ? n.person.name : n.uid);
  }

  /** 当前选中高亮：卡片点选优先于页面高亮 */
  private selectionUid(): string {
    if (this.selectedUid.length > 0) {
      return this.selectedUid;
    }
    return this.effectiveHighlight(this.activeRootUid());
  }

  /** 点击卡片：三栏直接显示详情；二栏/手机只选中并给出长按提示 */
  private selectPerson(uid: string): void {
    if (uid.length === 0) {
      return;
    }
    this.selectedUid = uid;
    this.viewState = 'FOCUS';
    this.rebuildTrailFor(uid);
    if (this.tapOpensDetail) {
      // 三栏：详情栏常驻，不再提示「长按查看详情」
      this.hintVisible = false;
      if (this.hintTimer >= 0) {
        clearTimeout(this.hintTimer);
        this.hintTimer = -1;
      }
      this.onTapPerson(uid);
      return;
    }
    this.showSelectHint(uid);
  }

  /**
   * 分页视图点选卡片：只做选中高亮（金色描边 + 面包屑跟随）；
   * 三栏布局右侧详情栏常驻，点选时同步刷新详情；二栏/手机留给长按打开详情。
   * “长按查看详情”轻提示由 PagedTree 内部贴卡片显示，每次点选都会出现。
   */
  private selectPagedPerson(uid: string): void {
    if (uid.length === 0) {
      return;
    }
    this.selectedUid = uid;
    this.viewState = 'FOCUS';
    this.rebuildTrailFor(uid);
    this.hintVisible = false;
    if (this.hintTimer >= 0) {
      clearTimeout(this.hintTimer);
      this.hintTimer = -1;
    }
    if (this.tapOpensDetail) {
      this.onTapPerson(uid);
    }
  }

  /** 长按卡片：先保持选中，再打开族人详情 */
  private openPersonDetail(uid: string): void {
    if (uid.length === 0) {
      return;
    }
    this.selectedUid = uid;
    this.rebuildTrailFor(uid);
    this.onTapPerson(uid);
  }

  /** 选中后短暂提示：告诉用户长按可看详情（手机上无 hover 时的兜底） */
  private showSelectHint(uid: string): void {
    this.updateHintPos(uid);
    this.hintVisible = true;
    if (this.hintTimer >= 0) {
      clearTimeout(this.hintTimer);
    }
    this.hintTimer = setTimeout((): void => {
      this.hintVisible = false;
      this.hintTimer = -1;
    }, 2600);
  }

  /** 取某卡片在内容坐标系中的 [x, y, w, h]；找不到返回空数组 */
  private layoutBoxOf(uid: string): number[] {
    const target: PersonNode | undefined = this.nodeIndex.get(uid);
    if (target === undefined) {
      return [];
    }
    const roots: PersonNode[] = SR.genealogy().getRoots();
    if (roots.length === 0) {
      return [];
    }
    const rootIdx: number = this.rootUids.indexOf(this.rootUidOf(target));
    const idx: number = rootIdx >= 0 ? rootIdx : this.clampBranchIndex();
    const root: PersonNode | undefined = roots[idx];
    if (root === undefined) {
      return [];
    }
    const cache: TreeLayoutCache = SR.treeCache();
    if (this.style === TreeStyle.SU) {
      const c: SuCanvas = cache.su(root.uid, [root], this.cardWidth(), this.isNarrow(), true);
      for (let i: number = 0; i < c.boxes.length; i = i + 1) {
        const b: SuBox = c.boxes[i];
        if (b.node.uid === uid) {
          return [b.x, b.y, b.w, b.h];
        }
      }
    } else {
      const c: EuCanvas = cache.eu(root.uid, [root], this.cardWidth(),
        this.isNarrow() ? 66 : 78, true, 6);
      for (let i: number = 0; i < c.boxes.length; i = i + 1) {
        const b: EuBox = c.boxes[i];
        if (b.node.uid === uid) {
          return [b.x, b.y, b.w, b.h];
        }
      }
    }
    return [];
  }

  /** 提示条贴到选中卡片下方（放不下就放上方），并夹在可视区内 */
  private updateHintPos(uid: string): void {
    const hintW: number = 228;
    const hintH: number = 30;
    const box: number[] = this.layoutBoxOf(uid);
    if (box.length < 4 || this.viewW <= 0) {
      this.hintX = Math.max(8, (this.viewW - hintW) / 2);
      this.hintY = Math.max(12, this.viewH - 112);
      return;
    }
    const top: number = this.currentContentTop();
    const sx: number = box[0] * this.scaleValue + this.offsetX;
    const sy: number = box[1] * this.scaleValue + this.offsetY + top;
    const sw: number = box[2] * this.scaleValue;
    const sh: number = box[3] * this.scaleValue;
    const maxX: number = Math.max(8, this.viewW - hintW - 8);
    this.hintX = Math.min(Math.max(8, sx + sw / 2 - hintW / 2), maxX);
    let y: number = sy + sh + 6;
    if (y + hintH > this.viewH - 8) {
      y = Math.max(8, sy - hintH - 6);
    }
    this.hintY = y;
  }

  /** 上溯到所在宗支根 uid */
  private rootUidOf(node: PersonNode): string {
    let cur: PersonNode = node;
    let guard: number = 0;
    while (guard < 256) {
      const parent: PersonNode | null = cur.father !== null ? cur.father : cur.mother;
      if (parent === null || parent === cur) {
        break;
      }
      cur = parent;
      guard = guard + 1;
    }
    return cur.uid;
  }

  /** 定位并居中某位族人（面包屑点击） */
  private centerOnUid(uid: string): void {
    const target: PersonNode | undefined = this.nodeIndex.get(uid);
    if (target === undefined || this.viewW <= 0 || this.viewH <= 0) {
      return;
    }
    const rootUid: string = this.rootUidOf(target);
    const rootIdx: number = this.rootUids.indexOf(rootUid);
    if (rootIdx >= 0 && rootIdx !== this.clampBranchIndex()) {
      this.activeBranch = rootIdx;
    }
    const roots: PersonNode[] = SR.genealogy().getRoots();
    if (roots.length === 0) {
      return;
    }
    const root: PersonNode = roots[this.clampBranchIndex()];
    const cache: TreeLayoutCache = SR.treeCache();
    let bx: number = -1;
    let by: number = 0;
    let bw: number = 0;
    let bh: number = 0;
    if (this.style === TreeStyle.SU) {
      const c: SuCanvas = cache.su(root.uid, [root], this.cardWidth(), this.isNarrow(), true);
      for (let i: number = 0; i < c.boxes.length; i = i + 1) {
        if (c.boxes[i].node.uid === uid) {
          bx = c.boxes[i].x;
          by = c.boxes[i].y;
          bw = c.boxes[i].w;
          bh = c.boxes[i].h;
          break;
        }
      }
    } else {
      const c: EuCanvas = cache.eu(root.uid, [root], this.cardWidth(),
        this.isNarrow() ? 66 : 78, true, 6);
      for (let i: number = 0; i < c.boxes.length; i = i + 1) {
        if (c.boxes[i].node.uid === uid) {
          bx = c.boxes[i].x;
          by = c.boxes[i].y;
          bw = c.boxes[i].w;
          bh = c.boxes[i].h;
          break;
        }
      }
    }
    if (bx < 0) {
      return;
    }
    const top: number = this.currentContentTop();
    this.offsetX = this.clampX(this.viewW / 2 - (bx + bw / 2) * this.scaleValue);
    this.offsetY = this.clampY(this.viewH / 2 - (by + bh / 2) * this.scaleValue - top);
    this.viewState = 'FOCUS';
    this.onFocusPerson(uid);
  }

  /**
   * 气泡 → 分页闭环：找到目标房所属宗支，切到分页并定位到该房起页。
   * 点击全览图上的「三房·韦耀定」即走这里。
   */
  private async openBranchPage(uid: string): Promise<void> {
    if (uid.length === 0) {
      return;
    }
    const target: PersonNode | undefined = this.nodeIndex.get(uid);
    if (target === undefined) {
      return;
    }
    const rootUid: string = this.rootUidOf(target);
    const rootIdx: number = this.rootUids.indexOf(rootUid);
    if (rootIdx >= 0) {
      this.activeBranch = rootIdx;
    }
    let page: number = 1;
    try {
      const book: PrintBook = await SR.pagination().book(rootUid, this.style,
        this.dataVersion, 'standard');
      const found: number = book.pageOf(uid);
      if (found > 0) {
        page = found;
      }
    } catch (err) {
      page = 1;
    }
    AppStorage.setOrCreate<boolean>('pagedMode', true);
    this.pagedMode = true;
    this.viewState = 'PAGED';
    this.pageNo = page;
  }

  /** 小地图视口左上角/尺寸（映射到 MINI_W × MINI_H） */
  private miniMapX(): number {
    if (this.canvasW <= 0) {
      return 0;
    }
    const v: number = (-this.offsetX) / this.canvasW * MINI_W;
    return Math.max(0, Math.min(MINI_W - this.miniMapW(), v));
  }

  private miniMapW(): number {
    if (this.canvasW <= 0) {
      return MINI_W;
    }
    return Math.max(8, Math.min(MINI_W, this.viewW / this.canvasW * MINI_W));
  }

  private miniMapY(): number {
    if (this.canvasH <= 0) {
      return 0;
    }
    const v: number = (-this.offsetY - this.currentContentTop()) / this.canvasH * MINI_H;
    return Math.max(0, Math.min(MINI_H - this.miniMapH(), v));
  }

  private miniMapH(): number {
    if (this.canvasH <= 0) {
      return MINI_H;
    }
    return Math.max(8, Math.min(MINI_H, this.viewH / this.canvasH * MINI_H));
  }

  /** 点小地图：把该位置的内容点居中到视口 */
  private onMiniMapTap(x: number, y: number): void {
    if (this.canvasW <= 0 || this.canvasH <= 0 || this.viewW <= 0) {
      return;
    }
    const screenX: number = x / MINI_W * this.canvasW;
    const screenY: number = y / MINI_H * this.canvasH;
    const contentX: number = (screenX - this.offsetX) / this.scaleValue;
    const contentY: number = (screenY - this.offsetY - this.currentContentTop()) / this.scaleValue;
    this.offsetX = this.clampX(this.viewW / 2 - contentX * this.scaleValue);
    this.offsetY = this.clampY(this.viewH / 2 - contentY * this.scaleValue - this.currentContentTop());
  }

  /** 切换宗支：单支渲染，切换后归零平移并重新居中 */
  private switchBranch(i: number): void {
    this.branchMenuOpen = false;
    this.selectedUid = '';
    this.hintVisible = false;
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
    this.pageNo = 1;
    this.scheduleLayout();
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

  /** 当前宗支名（分页页眉用，不带序号与箭头） */
  private currentBranchName(): string {
    const i: number = this.clampBranchIndex();
    return i < this.branchNames.length ? this.branchNames[i] : '';
  }

  /** 当前宗支的后代人数 */
  private currentBranchCount(): number {
    const i: number = this.clampBranchIndex();
    return i < this.branchCounts.length ? this.branchCounts[i] : 0;
  }

  /** 沿父/母/配偶链上溯，找到该族人所属宗支索引 */
  private branchIndexOf(uid: string): number {
    const svc: GenealogyService = SR.genealogy();
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
    if (this.pagedMode) {
      return;
    }
    if (this.style !== TreeStyle.EU && this.style !== TreeStyle.SU) {
      return;
    }
    if (this.viewW <= 0 || this.viewH <= 0 || this.rootUids.length === 0) {
      return;
    }
    const roots: PersonNode[] = SR.genealogy().getRoots();
    if (roots.length === 0) {
      return;
    }
    const idx: number = this.clampBranchIndex();
    const rootUid: string = roots[idx].uid;
    const cache: TreeLayoutCache = SR.treeCache();
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

  /** 按关键词在内存族谱中检索（姓名 / 曾用名 / 唯一ID / 字派），最多返回 40 条 */
  private runSearch(q: string): void {
    this.searchQuery = q;
    const key: string = q.trim();
    if (key.length === 0) {
      this.searchResults = [];
      return;
    }
    const keyUpper: string = key.toUpperCase();
    const people: Person[] = SR.genealogy().getPeople();
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
  private async focusOnUid(uid: string): Promise<void> {
    const svc: GenealogyService = SR.genealogy();
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
      this.getUIContext().getPromptAction().showToast({ message: T('未找到该族人') });
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
      this.getUIContext().getPromptAction().showToast({ message: T('未在谱系中找到该族人') });
      return;
    }
    // 目标不在当前宗支时自动切换
    const bi: number = this.branchIndexOf(uid);
    if (bi >= 0 && bi !== this.activeBranch) {
      this.activeBranch = bi;
      this.offsetX = 0;
      this.offsetY = 0;
      this.pageNo = 1;
    }
    // 分页视图：直接按「人 → 页」索引跳页，页内卡片会高亮
    if (this.pagedMode) {
      const idxP: number = this.clampBranchIndex();
      const book: PrintBook = await SR.pagination()
        .book(roots[idxP].uid, this.style, this.dataVersion, 'standard');
      const p: number = book.pageOf(uid);
      if (p <= 0) {
        this.getUIContext().getPromptAction().showToast({ message: T('该族人不在当前分页范围内') });
        return;
      }
      this.pageNo = p;
      this.onFocusPerson(uid);
      return;
    }
    this.rebuildCanvasSize(false);
    const idx: number = this.clampBranchIndex();
    const cache: TreeLayoutCache = SR.treeCache();
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
      this.getUIContext().getPromptAction().showToast({ message: T('未在谱系中找到该族人（可能不在当前谱式覆盖范围）') });
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
          Text(T(label + ' · ' + this.genCounts[idx].toString() + '人')).fontFamily(uiFontFamily())
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
        Text(T(Math.round(this.scaleValue * 100).toString() + '%')).fontFamily(uiFontFamily())
          .fontSize(10)
          .fontColor(Theme.inkTertiary)
          .backgroundColor(Theme.glass)
          .borderRadius(8)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ bottom: 6 })
      }
      Button(T('查找')).fontFamily(uiFontFamily())
        .fontSize(12)
        .fontColor(Theme.primary)
        .backgroundColor(Theme.glass)
        .border({ width: 1, color: Theme.glassBorder })
        .borderRadius(16)
        .height(34)
        .width(96)
        .padding({ left: 12, right: 12 })
        .margin({ bottom: 6 })
        .onClick((): void => {
          this.searchOpen = !this.searchOpen;
        })
      if (this.style === TreeStyle.EU || this.style === TreeStyle.SU) {
        Button(T(this.pagedMode ? '连续' : '分页')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(this.pagedMode ? Theme.onPrimary : Theme.primary)
          .backgroundColor(this.pagedMode ? Theme.primary : Theme.glass)
          .border({ width: 1, color: Theme.glassBorder })
          .borderRadius(16)
          .height(34)
          .width(96)
          .padding({ left: 12, right: 12 })
          .margin({ bottom: 6 })
          .onClick((): void => {
            // 只写 AppStorage 这一个真相源：@StorageProp 的 @Watch 会回写本地 pagedMode 并居中
            AppStorage.setOrCreate<boolean>('pagedMode', !this.pagedMode);
          })
      }
      if (this.style === TreeStyle.EU || this.style === TreeStyle.SU) {
        Button(T('全览')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(Theme.primary)
          .backgroundColor(Theme.glass)
          .border({ width: 1, color: Theme.glassBorder })
          .borderRadius(16)
          .height(34)
          .width(96)
          .padding({ left: 12, right: 12 })
          .margin({ bottom: 0 })
          .enabled(!this.pagedMode)
          .opacity(this.pagedMode ? 0.4 : 1)
          .onClick((): void => {
            this.resetView();
          })
      }
    }
    .width(96)
    .alignItems(HorizontalAlign.End)
    .margin({ right: 12, bottom: 12 })
  }

  /** 查找面板：输入关键词 → 结果点选即跳转并居中 */
  @Builder
  SearchPanel() {
    Column() {
      Row() {
        Text(T('查找族人')).fontFamily(uiFontFamily())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ink)
          .layoutWeight(1)
        Text(T('关闭')).fontFamily(uiFontFamily())
          .fontSize(13)
          .fontColor(Theme.primary)
          .padding({ left: 8, top: 4, bottom: 4 })
          .onClick((): void => {
            this.searchOpen = false;
          })
      }
      .width('100%')
      SearchField({
        text: this.searchQuery,
        placeholder: '姓名 / 曾用名 / 唯一ID / 字派',
        marginTop: 8,
        onChange: (v: string): void => {
          this.runSearch(v);
        }
      })
      if (this.searchQuery.trim().length === 0) {
        Text(T('输入关键词自动匹配，点击结果即跳到该族人在谱系中的位置')).fontFamily(uiFontFamily())
          .fontSize(11)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 8 })
          .width('100%')
      } else if (this.searchResults.length === 0) {
        Text(T('未找到匹配的族人')).fontFamily(uiFontFamily())
          .fontSize(12)
          .fontColor(Theme.inkTertiary)
          .margin({ top: 10 })
          .width('100%')
      } else {
        List({ space: 2 }) {
          ForEach(this.searchResults, (p: Person) => {
            ListItem() {
              Row() {
                Text(T(p.name)).fontFamily(uiFontFamily())
                  .fontSize(14)
                  .fontColor(Theme.ink)
                Text(T(generationLabel(p.generation) + ' · ' + compactUid(p.uid))).fontFamily(uiFontFamily())
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

  /** 面包屑：本支根 → 当前人物，点击任一级立即居中 */
  @Builder
  BreadcrumbBar() {
    if (this.trailUids.length > 1 && !this.pagedMode) {
      Scroll() {
        Row() {
          ForEach(this.trailUids, (uid: string, i: number) => {
            Row() {
              Text(T(this.trailNames.length > i ? this.trailNames[i] : uid)).fontFamily(uiFontFamily())
                .fontSize(12)
                .fontColor(i === this.trailUids.length - 1 ? Theme.primary : Theme.inkSecondary)
                .fontWeight(i === this.trailUids.length - 1 ? FontWeight.Medium : FontWeight.Normal)
                .maxLines(1)
              if (i < this.trailUids.length - 1) {
                Text(T('›')).fontFamily(uiFontFamily())
                  .fontSize(12)
                  .fontColor(Theme.inkTertiary)
                  .margin({ left: 4, right: 4 })
              }
            }
            .onClick((): void => {
              this.centerOnUid(uid);
            })
          }, (uid: string, i: number) => 'trail_' + uid + '_' + i.toString())
        }
        .padding({ left: 10, right: 10 })
        .height(24)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .backgroundColor(Theme.glass)
      .borderRadius(6)
    }
  }

  /** 左下角小地图：缩略视口 + 点击快速导航（仅在平板及以上显示，避免手机窄屏遮挡画布） */
  @Builder
  MiniMap() {
    if (!this.pagedMode && this.windowWidth >= Breakpoint.SM
      && (this.style === TreeStyle.EU || this.style === TreeStyle.SU)
      && this.canvasW > 0 && this.canvasH > 0) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Theme.card)
        // 宗支缩略条：按各支在画布中的起点/高度等比投影
        ForEach(this.branchTops, (top: number, i: number) => {
          Column()
            .width(MINI_W - 4)
            .height(Math.max(2, (i < this.branchH.length ? this.branchH[i] : 0) * this.scaleValue /
              Math.max(1, this.canvasH) * MINI_H))
            .position({ x: 2, y: 2 + top / Math.max(1, this.canvasH) * MINI_H })
            .backgroundColor('rgba(201,162,39,0.28)')
        }, (top: number, i: number) => 'mm_' + i.toString())
        Column()
          .width(this.miniMapW())
          .height(this.miniMapH())
          .position({ x: this.miniMapX(), y: this.miniMapY() })
          .backgroundColor('rgba(156,47,30,0.16)')
          .border({ width: 1, color: Theme.primary })
      }
      .width(MINI_W)
      .height(MINI_H)
      .borderRadius(6)
      .clip(true)
      .border({ width: 1, color: Theme.glassBorder })
      .position({ x: 12, y: Math.max(12, this.viewH - MINI_H - 12) })
      .onClick((event: ClickEvent): void => {
        this.onMiniMapTap(event.x, event.y);
      })
    }
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
    .backgroundColor(Theme.overlayLight)
  }

  @Builder
  DieList() {
    List({ space: Spacing.M, scroller: this.dieScroller }) {
      LazyForEach(this.dieSource, (person: Person, index: number) => {
        ListItem() {
          Column() {
            if (index === 0 || this.dieSource.getData(index - 1).generation !== person.generation) {
              Row() {
                Text(T(generationLabel(person.generation))).fontFamily(uiFontFamily())
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
              ctx: this.dieIndex,
              index: 0,
              showPrivate: this.showPrivate,
              highlight: person.uid === this.selectionUid(),
              onTapPerson: (uid: string): void => {
                this.onTapPerson(uid);
              }
            })
          }
          .width('100%')
        }
      }, (person: Person) => 'die_' + this.dataVersion.toString() + '_' + person.uid +
        (person.uid === this.selectionUid() ? '_hl' : ''))
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
                Text(T((i === this.clampBranchIndex() ? '✓ ' : '') + this.branchLabel(i))).fontFamily(uiFontFamily())
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
      .shadow({ radius: 14, color: Theme.overlayLight, offsetY: 5 })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        if (this.peopleCount === 0) {
          EmptyHint({ icon: '🌱', title: T('族谱暂无人物'), desc: '点击右下角“＋”创建始祖，开启家族记录' })
        } else if (this.style === TreeStyle.DIE) {
          this.DieList()
        } else if (this.style === TreeStyle.PAGODA) {
          this.GenerationIndex()
          PagodaTree({
            rootUids: this.rootUids,
            layoutVersion: this.dataVersion,
            highlightUid: this.selectionUid(),
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
            highlightUid: this.selectionUid(),
            focusUid: this.focusUid,
            minCardWidth: this.windowWidth >= Breakpoint.MD ? 220 : (this.isNarrow() ? 150 : 180),
            onTapPerson: (uid: string): void => {
              this.onTapPerson(uid);
            }
          })
          .width('100%')
          .layoutWeight(1)
        } else if (this.layoutBusy) {
          this.TreeLoading()
        } else if (this.pagedMode) {
          PagedTree({
            rootUid: this.activeRootUid(),
            style: this.style,
            layoutVersion: this.dataVersion,
            pageIndex: this.pageNo,
            highlightUid: this.selectionUid(),
            profileName: 'standard',
            showTapHint: !this.tapOpensDetail,
            branchName: this.currentBranchName(),
            onPageChange: (n: number): void => {
              this.pageNo = n;
            },
            onTapPerson: (uid: string): void => {
              this.selectPagedPerson(uid);
            },
            onLongPressPerson: (uid: string): void => {
              this.openPersonDetail(uid);
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

      if (this.peopleCount > 0 && !this.layoutBusy) {
        this.ViewTools()
      }
      if (this.searchOpen) {
        this.SearchOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 切换谱式时的占位加载态：先出这一帧，再做同步布局计算 */
  @Builder
  TreeLoading() {
    Column() {
      LoadingProgress().width(36).height(36).color(Theme.primary)
      Text(T('正在切换谱式…')).fontFamily(uiFontFamily())
        .fontSize(12)
        .fontColor(Theme.inkTertiary)
        .margin({ top: Spacing.M })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
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
                        Text(T(this.currentBranchTitle())).fontFamily(uiFontFamily())
                          .fontSize(13)
                          .fontWeight(FontWeight.Medium)
                          .fontColor(Theme.primary)
                        Text(T('后代 ' + this.currentBranchCount().toString() + ' 人')).fontFamily(uiFontFamily())
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
                      // 画布内容按 translate 平移后会盖到标题行上方（欧式画布高度大时尤其明显），
                      // 透明区域会拦截标题行右侧的点击；抬高层级让整行始终优先响应点击
                      .zIndex(2)
                      .onClick((): void => {
                        this.branchMenuOpen = !this.branchMenuOpen;
                      })
                    }
                    if (this.style === TreeStyle.EU) {
                      EuTree({
                        rootUid: this.activeRootUid(),
                        layoutVersion: this.dataVersion,
                        highlightUid: this.selectionUid(),
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
                          this.selectPerson(id);
                        },
                        onOpenDetail: (id: string): void => {
                          this.openPersonDetail(id);
                        },
                        onBubbleTap: (id: string): void => {
                          this.openBranchPage(id).then((): void => {
                          });
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
                        highlightUid: this.selectionUid(),
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
                          this.selectPerson(id);
                        },
                        onOpenDetail: (id: string): void => {
                          this.openPersonDetail(id);
                        },
                        onBubbleTap: (id: string): void => {
                          this.openBranchPage(id).then((): void => {
                          });
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
              const w: number = Number(newArea.width);
              const h: number = Number(newArea.height);
              // 折叠展开/横竖屏/窗口拖拽会让可视区尺寸突变；沿用旧偏移会把内容甩到角落，
              // 尺寸变化超过一屏的 5% 时重新把始祖居中一次
              if (this.lastViewW > 0 && this.lastViewH > 0
                && (Math.abs(w - this.lastViewW) > this.lastViewW * 0.05
                  || Math.abs(h - this.lastViewH) > this.lastViewH * 0.05)) {
                this.pendingCenter = true;
              }
              this.lastViewW = w;
              this.lastViewH = h;
              this.viewW = w;
              this.viewH = h;
              this.viewGlobalX = Number(newArea.globalPosition.x);
              this.viewGlobalY = Number(newArea.globalPosition.y);
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
                    this.pinching = false;
                    this.panResume = true;
                    this.interacting = false;
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
        if (!this.pagedMode && this.trailUids.length > 1) {
          Column() {
            this.BreadcrumbBar()
          }
          .width('100%')
          .position({ x: 0, y: this.rootUids.length > 1 ? BRANCH_HEADER_H + Spacing.S : 0 })
          .zIndex(4)
          .padding({ left: 8, right: 8 })
        }
        if (this.hintVisible && !this.pagedMode) {
          Column() {
            Text(T('已选中 · 长按卡片查看族人详情')).fontFamily(uiFontFamily())
              .fontSize(12)
              .fontColor(Theme.onPrimary)
              .backgroundColor('rgba(0,0,0,0.72)')
              .borderRadius(14)
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          }
          .width(228)
          .alignItems(HorizontalAlign.Center)
          .position({ x: this.hintX, y: this.hintY })
          .zIndex(6)
          .hitTestBehavior(HitTestMode.Transparent)
        }
        this.MiniMap()
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
