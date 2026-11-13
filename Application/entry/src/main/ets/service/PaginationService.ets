import { PersonNode } from '../model/PersonNode';
import { TreeStyle, generationLabel } from '../model/Enums';
import { EuCanvas, EuLayout, LineSeg, SuCanvas, SuLayout } from './TreeLayout';
import { LayoutProfile, PageSpec } from './PrintLayout';
import { GenealogyService } from './GenealogyService';
import { taskpool } from '@kit.ArkTS';

/**
 * 协作式分页用的跨线程空任务。await 它时，TaskPool 的结果经主线程消息队列回投，
 * 能真正结束当前 EventHandler 任务、让 THREAD_BLOCK 看门狗复位。
 * （单纯 setTimeout 链会被 uv_run 一次性跑完，无法让出主线程，实测仍触发 THREAD_BLOCK_6S）
 */
@Concurrent
function pagedYieldTick(): number {
  return 0;
}

/** 一页的根：从哪一页、哪个人续来；页面顶部据此写「承第 N 页」 */
export class PageRootRef {
  uid: string = '';
  name: string = '';
  /** 来源页（0 表示本支始祖，无来源） */
  fromPage: number = 0;
  /** 来源页上的父辈 uid */
  fromUid: string = '';
  /** 与父辈的关系，如「长子」「次子」 */
  relation: string = '';
}

/** 被切到后页的子女组：父卡留在本页，页脚注明续见页 */
export class PageCut {
  parentUid: string = '';
  parentName: string = '';
  childUids: string[] = [];
  relationText: string = '';
}

/** 页脚软链接：本页未展开的兄弟分支，可直接翻到它的起页 */
export class PageJump {
  uid: string = '';
  name: string = '';
  /** 目标页（1 起，0 表示未排进本书） */
  page: number = 0;
  /** 分支称谓，如「二房·韦承恩」 */
  relation: string = '';
}

/** 一页的排版计划（屏幕分页视图与未来 PDF 共用） */
export class PagePlan {
  /** 图册内页码，从 1 开始 */
  index: number = 1;
  /** 本页所属房支标识（顶级房根 uid；页内混房时为空） */
  branchId: string = '';
  /** 本页最低/最高世代（0 表示未编世） */
  genFrom: number = 0;
  genTo: number = 0;
  /** 本页的根节点（布局入口） */
  rootUids: string[] = [];
  rootNodes: PersonNode[] = [];
  roots: PageRootRef[] = [];
  /** 本页允许出现的全部人物 uid：页内布局只排这个集合，切线不会画出来 */
  uids: Set<string> = new Set<string>();
  /** 被切到后页的子女（仅父卡所在页记录） */
  cuts: PageCut[] = [];
  /** 页首祖先上下文：上溯两代的 uid（由近到远），PDF 与屏幕页首据此画承接卡 */
  contextAncestors: string[] = [];
  contextAncestorNames: string[] = [];
  /** 本页所属房支名称（如「三房」） */
  branchName: string = '';
  /** 页脚兄弟分支软链接：点击可直接翻到该房起页 */
  siblingLinks: PageJump[] = [];
  /** 页脚接续文案 */
  footerText: string = '';
  /** 奇数页为单页（装订口在左），偶数页镜像 */
  recto: boolean = true;
}

/** 整本分页结果 */
export class PrintBook {
  pages: PagePlan[] = [];
  indexByUid: Map<string, number> = new Map<string, number>();
  pageCount: number = 0;
  peopleCount: number = 0;
  spec: PageSpec = PageSpec.landscape();
  profile: LayoutProfile = LayoutProfile.standard();
  /** 规划过程中达到上限被截断（异常数据保护） */
  truncated: boolean = false;

  pageOf(uid: string): number {
    const p: number | undefined = this.indexByUid.get(uid);
    return p === undefined ? 0 : p;
  }

  page(index: number): PagePlan | null {
    if (index < 1 || index > this.pages.length) {
      return null;
    }
    return this.pages[index - 1];
  }
}

/** 页面布局结果：欧式/苏式二选一，避免联合类型在 ArkTS 里反复判型 */
export class PageContent {
  eu: EuCanvas | null = null;
  su: SuCanvas | null = null;
  width: number = 0;
  height: number = 0;
}

/** 待排版单元：一棵子树 + 本页顶部需要重复的承接父卡 */
class PendingUnit {
  node: PersonNode;
  /** 承接父卡：本页顶部重复画一遍，线从它连到本页的子女；null 表示宗支根页 */
  carry: PersonNode | null;
  fromPage: number = 0;
  relation: string = '';

  constructor(node: PersonNode, carry: PersonNode | null, fromPage: number, relation: string) {
    this.node = node;
    this.carry = carry;
    this.fromPage = fromPage;
    this.relation = relation;
  }
}

/** 页面内递归下钻的最大层数：超过就把剩余子女切成续页单元 */
const MAX_PAGE_DEPTH: number = 256;
/**
 * 规划页数/迭代上限：只用于防止环状数据导致死循环，不能当成业务上限。
 * 原先 4000 页 / 4 万次迭代，五万人的谱会直接撞上并被截断（book.truncated），
 * 后半本族人不会出现在 PDF 里；这里按「人数级」放开，正常数据远达不到。
 */
const MAX_PAGES: number = 20000;
const MAX_ITER: number = 400000;
/** 容量判定的浮点容差（mm） */
const FIT_EPS: number = 0.2;
/**
 * 分支点提前切页的最小页人数。
 * 页面已排下至少这么多人、且下一支属于另一房时，优先在新房起点换页，
 * 避免同一页混排多个房支导致「树冠在十几页反复出现」。
 */
const MIN_PEOPLE_PER_PAGE: number = 20;

/**
 * 分页规划与逐页布局。
 *
 * 核心原则：分页是「重排」不是「切片」。
 * 每页只排本页允许出现的人（PagePlan.uids），布局递归遇到集合外的子女即停，
 * 页内每条线的两端都在本页，结构上不可能出现跨页悬空线；跨页只靠页眉/页脚文字接续。
 *
 * 装箱规则：
 *  - 以「房」为单位（一个节点 + 全部子孙），整房装不下就移到下一页，宁留白不切房；
 *  - 只有单房本身超过一页才拆：父卡留本页，子女按长幼依次尝试，放不下的整支去后页，
 *    后页以该子女为页根（PageRootRef 记住来源页与父辈）。
 */
export class PaginationService {
  private static instance: PaginationService | null = null;

  private bookKey: string = '';
  private cached: PrintBook | null = null;
  private euCache: Map<number, EuCanvas> = new Map<number, EuCanvas>();
  private suCache: Map<number, SuCanvas> = new Map<number, SuCanvas>();
  /** 当前树的 uid→节点索引（缓存恢复页计划/画布时复用，数据变化时清空） */
  private static nodeIndexCache: Map<string, PersonNode> | null = null;

  static getInstance(): PaginationService {
    if (PaginationService.instance === null) {
      PaginationService.instance = new PaginationService();
    }
    return PaginationService.instance;
  }

  /** 数据/谱式变化时丢弃整本缓存 */
  invalidate(): void {
    this.bookKey = '';
    this.cached = null;
    this.euCache.clear();
    this.suCache.clear();
    PaginationService.nodeIndexCache = null;
  }

  /** 当前树的 uid→节点索引（O(N) 只建一次；分页缓存恢复、布局缓存恢复共用） */
  static nodeIndexOfCurrentBook(): Map<string, PersonNode> {
    if (PaginationService.nodeIndexCache !== null) {
      return PaginationService.nodeIndexCache;
    }
    const map: Map<string, PersonNode> = new Map<string, PersonNode>();
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    const stack: PersonNode[] = [];
    for (let i: number = 0; i < roots.length; i = i + 1) {
      stack.push(roots[i]);
    }
    while (stack.length > 0) {
      const n: PersonNode = stack.pop() as PersonNode;
      if (map.has(n.uid)) {
        continue;
      }
      map.set(n.uid, n);
      for (let k: number = 0; k < n.children.length; k = k + 1) {
        stack.push(n.children[k]);
      }
    }
    PaginationService.nodeIndexCache = map;
    return map;
  }

  /**
   * 重新编号并重建索引/页脚链接。
   * 用于房支增量重排后拼接：页内内容不变，只把页码、承接页、兄弟链接与页脚文案按新顺序重算。
   */
  static rebuildIndexAndLinks(book: PrintBook): void {
    for (let i: number = 0; i < book.pages.length; i = i + 1) {
      book.pages[i].index = i + 1;
    }
    book.indexByUid.clear();
    const nodes: Map<string, PersonNode> = PaginationService.nodeIndexOfCurrentBook();
    for (let i: number = 0; i < book.pages.length; i = i + 1) {
      const page: PagePlan = book.pages[i];
      page.uids.forEach((uid: string): void => {
        if (!book.indexByUid.has(uid)) {
          book.indexByUid.set(uid, page.index);
        }
        const n: PersonNode | undefined = nodes.get(uid);
        if (n === undefined) {
          return;
        }
        for (let k: number = 0; k < n.spouses.length; k = k + 1) {
          if (!book.indexByUid.has(n.spouses[k].uid)) {
            book.indexByUid.set(n.spouses[k].uid, page.index);
          }
        }
      });
    }
    for (let i: number = 0; i < book.pages.length; i = i + 1) {
      const page: PagePlan = book.pages[i];
      for (let r: number = 0; r < page.roots.length; r = r + 1) {
        const home: number = book.pageOf(page.roots[r].uid);
        if (home > 0) {
          page.roots[r].fromPage = home;
        }
      }
      for (let s: number = 0; s < page.siblingLinks.length; s = s + 1) {
        const target: number = book.pageOf(page.siblingLinks[s].uid);
        if (target > 0) {
          page.siblingLinks[s].page = target;
        }
      }
      const notes: string[] = [];
      for (let c: number = 0; c < page.cuts.length; c = c + 1) {
        const cut: PageCut = page.cuts[c];
        let lo: number = 0;
        let hi: number = 0;
        for (let k: number = 0; k < cut.childUids.length; k = k + 1) {
          const p: number | undefined = book.indexByUid.get(cut.childUids[k]);
          if (p === undefined) {
            continue;
          }
          if (lo === 0 || p < lo) {
            lo = p;
          }
          if (p > hi) {
            hi = p;
          }
        }
        if (lo > 0) {
          const span: string = lo === hi ? lo.toString() : (lo.toString() + '—' + hi.toString());
          notes.push('续见第 ' + span + ' 页（' + cut.parentName + '以下 ' + cut.relationText + '）');
        }
      }
      page.footerText = notes.join('　');
    }
    book.pageCount = book.pages.length;
  }

  /**
   * 采用持久化缓存恢复的分页本：跳过整树装箱，直接进入逐页布局。
   * 导出与缓存预热命中时走这里。
   */
  adoptBook(book: PrintBook): void {
    this.cached = book;
    this.bookKey = 'adopted|' + book.profile.key() + '|' + book.spec.key() + '|' +
      book.pageCount.toString() + '|' + book.peopleCount.toString();
    this.euCache.clear();
    this.suCache.clear();
  }

  /**
   * 从持久化 PagePlan 重建 PrintBook。
   * 只恢复页计划、页根与人物索引；每页的卡片坐标仍由 euPage/suPage 按需计算。
   * 返回的 PrintBook 可直接 adoptBook 后用于导出。
   */
  static buildBookFromPlans(plans: PagePlan[], profileName: string,
    indexByUid: Map<string, number>): PrintBook {
    const book: PrintBook = new PrintBook();
    book.spec = PageSpec.landscape();
    book.profile = PaginationService.profileOf(profileName);
    book.pages = plans;
    book.pageCount = plans.length;
    // 一次性建 uid→节点索引，避免每页重复遍历整棵树
    const nodeIndex: Map<string, PersonNode> = new Map<string, PersonNode>();
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    const stack: PersonNode[] = [];
    for (let i: number = 0; i < roots.length; i = i + 1) {
      stack.push(roots[i]);
    }
    while (stack.length > 0) {
      const n: PersonNode = stack.pop() as PersonNode;
      if (nodeIndex.has(n.uid)) {
        continue;
      }
      nodeIndex.set(n.uid, n);
      for (let k: number = 0; k < n.children.length; k = k + 1) {
        stack.push(n.children[k]);
      }
    }
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < plans.length; i = i + 1) {
      const p: PagePlan = plans[i];
      p.index = i + 1;
      p.rootNodes = [];
      for (let r: number = 0; r < p.rootUids.length; r = r + 1) {
        const node: PersonNode | undefined = nodeIndex.get(p.rootUids[r]);
        if (node !== undefined) {
          p.rootNodes.push(node);
        }
      }
      p.uids.forEach((uid: string): void => {
        seen.add(uid);
      });
    }
    book.peopleCount = seen.size;
    if (indexByUid.size > 0) {
      book.indexByUid = indexByUid;
    } else {
      for (let i: number = 0; i < plans.length; i = i + 1) {
        const p: PagePlan = plans[i];
        p.uids.forEach((uid: string): void => {
          if (!book.indexByUid.has(uid)) {
            book.indexByUid.set(uid, p.index);
          }
        });
      }
    }
    return book;
  }

  /**
   * 取（或重建）某一宗支的分页结果。
   * @param rootUid 宗支根
   * @param style 谱式（EU / SU）
   * @param version 数据版本，用于失效
   * @param profileName standard / compact / large
   */
  async book(rootUid: string, style: string, version: number, profileName: string = 'standard',
    onProgress?: (pct: number) => void): Promise<PrintBook> {
    const spec: PageSpec = PageSpec.landscape();
    const profile: LayoutProfile = PaginationService.profileOf(profileName);
    const key: string = rootUid + '|' + style + '|' + version.toString() + '|' + profile.key() + '|' + spec.key();
    if (this.cached !== null && this.bookKey === key) {
      return this.cached;
    }
    this.euCache.clear();
    this.suCache.clear();
    const book: PrintBook = new PrintBook();
    book.spec = spec;
    book.profile = profile;
    const root: PersonNode | null = PaginationService.findNode(rootUid);
    if (root === null) {
      this.cached = book;
      this.bookKey = key;
      return book;
    }
    await this.planBook(book, root, style, onProgress);
    this.cached = book;
    this.bookKey = key;
    return book;
  }

  /** 取某页的欧式布局（按页缓存，翻页不重复计算） */
  euPage(index: number): EuCanvas | null {
    if (this.cached === null) {
      return null;
    }
    const hit: EuCanvas | undefined = this.euCache.get(index);
    if (hit !== undefined) {
      return hit;
    }
    const page: PagePlan | null = this.cached.page(index);
    if (page === null) {
      return null;
    }
    const content: PageContent = this.computeCanvas(page.rootNodes, page.uids, TreeStyle.EU, this.cached.profile, this.cached.spec);
    if (content.eu === null) {
      return null;
    }
    this.euCache.set(index, content.eu);
    return content.eu;
  }

  /** 取某页的苏式布局 */
  suPage(index: number): SuCanvas | null {
    if (this.cached === null) {
      return null;
    }
    const hit: SuCanvas | undefined = this.suCache.get(index);
    if (hit !== undefined) {
      return hit;
    }
    const page: PagePlan | null = this.cached.page(index);
    if (page === null) {
      return null;
    }
    const content: PageContent = this.computeCanvas(page.rootNodes, page.uids, TreeStyle.SU, this.cached.profile, this.cached.spec);
    if (content.su === null) {
      return null;
    }
    this.suCache.set(index, content.su);
    return content.su;
  }

  /** 页面能否装进版心（canvas 的宽高已含列距/边距） */
  fits(content: PageContent, spec: PageSpec): boolean {
    return content.width <= spec.contentWidth() + FIT_EPS &&
      content.height <= spec.contentHeight() + FIT_EPS;
  }

  private static profileOf(name: string): LayoutProfile {
    if (name === 'compact') {
      return LayoutProfile.compact();
    }
    if (name === 'large') {
      return LayoutProfile.large();
    }
    return LayoutProfile.standard();
  }

  private static findNode(uid: string): PersonNode | null {
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    for (let i: number = 0; i < roots.length; i = i + 1) {
      const hit: PersonNode | null = PaginationService.findInTree(roots[i], uid);
      if (hit !== null) {
        return hit;
      }
    }
    return null;
  }

  private static findInTree(root: PersonNode, uid: string): PersonNode | null {
    const stack: PersonNode[] = [root];
    const seen: Set<string> = new Set<string>();
    while (stack.length > 0) {
      const n: PersonNode = stack[stack.length - 1];
      stack.pop();
      if (seen.has(n.uid)) {
        continue;
      }
      seen.add(n.uid);
      if (n.uid === uid) {
        return n;
      }
      for (let i: number = 0; i < n.children.length; i = i + 1) {
        stack.push(n.children[i]);
      }
    }
    return null;
  }

  /**
   * 规划整本：每页都是一个闭合的世系片段。
   *
   * 页顶的承接父卡从上一页重复过来（同一张卡可以出现在多页），
   * 所以父→子的线永远落在同一页，不会出现悬空线。
   *
   * 装箱时按「页面容量」深挖：整支装得下就整支放；装不下就把这一支的根卡放下，
   * 再递归尝试它的子女，直到本页装满或这一支排完，没排完的部分带承接父卡去下一页。
   */
  /** 协作式让出主线程：分页每若干步 await 一次跨线程任务，避免长时间阻塞触发 THREAD_BLOCK 看门狗 */
  private static async yieldToEventLoop(): Promise<void> {
    try {
      await taskpool.execute(pagedYieldTick);
    } catch (err) {
      // TaskPool 不可用时回退到定时器（至少尽力让出一帧）
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(() => {
          resolve();
        }, 0);
      });
    }
  }

  private async planBook(book: PrintBook, root: PersonNode, style: string,
    onProgress?: (pct: number) => void): Promise<void> {
    // 本方法从 aboutToAppear 一路同步进来：先让出一帧再开工，
    // 否则首屏渲染会和建索引/建树统计一起卡在同一帧
    await PaginationService.yieldToEventLoop();
    const spec: PageSpec = book.spec;
    const profile: LayoutProfile = book.profile;
    const nodeMap: Map<string, PersonNode> = new Map<string, PersonNode>();
    this.indexSubtree(root, nodeMap);
    book.peopleCount = nodeMap.size;
    const sizeMap: Map<string, number> = this.buildSizeMap(root);
    const slots: number = this.slotCapacity(style, spec, profile);

    const pages: PagePlan[] = [];
    let cur: PagePlan = new PagePlan();
    cur.index = 1;
    const queue: PendingUnit[] = [new PendingUnit(root, null, 0, '始祖')];
    const pending: PendingUnit[] = [];
    /** 已排进续页队列的 uid：跨页去重，防止同一人被切成多个续页单元 */
    const queued: Set<string> = new Set<string>();
    let iter: number = 0;
    /** 已落页人数：进度按「已排人数 / 全支人数」算，比按迭代次数百分比准确 */
    let placed: number = 0;

    while ((queue.length > 0 || cur.uids.size > 0) && iter < MAX_ITER && pages.length < MAX_PAGES) {
      iter = iter + 1;
      // 每 8 步让出一次主线程（跨线程 await，能真正结束当前 EventHandler 任务），
      // 单步内含批量二分布局，间隔太大仍可能逼近 6s 看门狗阈值
      if (iter % 8 === 0) {
        if (onProgress !== undefined) {
          const total: number = Math.max(1, book.peopleCount);
          onProgress(Math.min(99, Math.floor(placed * 100 / total)));
        }
        await PaginationService.yieldToEventLoop();
      }
      if (queue.length === 0) {
        this.commitPending(queue, pending);
        placed = placed + this.flushPage(cur, pages, nodeMap);
        cur = new PagePlan();
        cur.index = pages.length + 1;
        continue;
      }
      const unit: PendingUnit = queue[0];

      // 横向并排：本页已排人，下一个房支整房能作为独立片段放进剩余宽度时直接并排。
      // 欧式布局的页高由叶子数决定，一页只放一个房会让横向 11 列大部分空着；
      // 多房并排可把每页人数从 12 提到 40+，页数与卷数随之大幅下降。
      if (!cur.uids.has(unit.node.uid) && unit.carry === null && cur.uids.size > 0 &&
        unit.node.isBranchPoint && unit.node.branchRootUid === unit.node.uid) {
        const trial: Set<string> = this.copySet(cur.uids);
        this.collectSubtree(unit.node, trial);
        const roots2: PersonNode[] = [];
        for (let i: number = 0; i < cur.rootNodes.length; i = i + 1) {
          roots2.push(cur.rootNodes[i]);
        }
        roots2.push(unit.node);
        const sideBySide: PageContent = this.computeCanvas(roots2, trial, style, profile, spec);
        if (this.fits(sideBySide, spec)) {
          cur.rootNodes.push(unit.node);
          cur.rootUids.push(unit.node.uid);
          const ref: PageRootRef = new PageRootRef();
          ref.uid = unit.node.uid;
          ref.name = unit.node.person.name;
          ref.fromPage = 0;
          ref.relation = '并排';
          cur.roots.push(ref);
          cur.uids = trial;
          queue.shift();
          continue;
        }
      }

      // 分支点优先换页：本页已排够人、下一支属于另一房且正好是房支起点时，
      // 先落页再从新房起页开始排，避免同一房支的树冠在后续多页重复出现
      if (this.shouldCutBeforeBranchPoint(unit, cur, nodeMap)) {
        this.commitPending(queue, pending);
        placed = placed + this.flushPage(cur, pages, nodeMap);
        cur = new PagePlan();
        cur.index = pages.length + 1;
        continue;
      }

      // 空页：页根 = 承接父卡（宗支根页则用本支始祖）
      if (cur.uids.size === 0) {
        cur.index = pages.length + 1;
        const pageRoot: PersonNode = unit.carry !== null ? unit.carry : unit.node;
        cur.rootNodes = [pageRoot];
        cur.rootUids = [pageRoot.uid];
        const ref: PageRootRef = new PageRootRef();
        ref.uid = pageRoot.uid;
        ref.name = pageRoot.person.name;
        ref.fromPage = 0;
        ref.relation = unit.carry !== null ? '承前页' : '始祖';
        cur.roots = [ref];
        cur.uids.add(pageRoot.uid);
        if (unit.carry === null) {
          queue.shift();
        }
      }

      // 这一支的承接父卡不在本页：把它作为新的独立片段放进本页；
      // 连「父卡 + 这一支的根卡」都放不下时，才落页换新页。
      const carry: PersonNode | null = unit.carry;
      if (carry !== null && !cur.uids.has(carry.uid)) {
        const set: Set<string> = this.copySet(cur.uids);
        set.add(carry.uid);
        set.add(unit.node.uid);
        const roots2: PersonNode[] = [];
        for (let i: number = 0; i < cur.rootNodes.length; i = i + 1) {
          roots2.push(cur.rootNodes[i]);
        }
        roots2.push(carry);
        const c: PageContent = this.computeCanvas(roots2, set, style, profile, spec);
        if (!this.fits(c, spec)) {
          this.commitPending(queue, pending);
          placed = placed + this.flushPage(cur, pages, nodeMap);
          cur = new PagePlan();
          cur.index = pages.length + 1;
          continue;
        }
        cur.rootNodes.push(carry);
        cur.rootUids.push(carry.uid);
        const ref: PageRootRef = new PageRootRef();
        ref.uid = carry.uid;
        ref.name = carry.person.name;
        ref.fromPage = 0;
        ref.relation = '承前页';
        cur.roots.push(ref);
        cur.uids = set;
      }

      // 页根/承接父卡已在页内：向下递归填页
      if (cur.uids.has(unit.node.uid)) {
        this.fill(unit.node, cur, style, profile, spec, sizeMap, slots, pending, nodeMap, queued);
        if (queue[0] === unit) {
          queue.shift();
        }
        continue;
      }

      // 整支装得下就整支放
      const size: number = sizeMap.get(unit.node.uid) !== undefined ?
        (sizeMap.get(unit.node.uid) as number) : 1;
      if (size <= slots - cur.uids.size) {
        const trial: Set<string> = this.copySet(cur.uids);
        this.collectSubtree(unit.node, trial);
        const c: PageContent = this.computeCanvas(cur.rootNodes, trial, style, profile, spec);
        if (this.fits(c, spec)) {
          cur.uids = trial;
          queue.shift();
          continue;
        }
      }

      // 整支放不下：把这一支的根卡先放进本页，再逐层填；连根卡都放不进才换页
      const before: number = cur.uids.size;
      this.fill(unit.node, cur, style, profile, spec, sizeMap, slots, pending, nodeMap, queued);
      if (cur.uids.size > before) {
        queue.shift();
        continue;
      }
      this.commitPending(queue, pending);
      placed = placed + this.flushPage(cur, pages, nodeMap);
      cur = new PagePlan();
      cur.index = pages.length + 1;
    }
    if (cur.uids.size > 0 && pages.length < MAX_PAGES) {
      placed = placed + this.flushPage(cur, pages, nodeMap);
    }
    if (queue.length > 0 || pending.length > 0) {
      book.truncated = true;
    }
    book.pages = pages;
    book.pageCount = pages.length;
    this.buildIndex(book, nodeMap);
    let totalUids: number = 0;
    for (let pi: number = 0; pi < pages.length; pi = pi + 1) {
      totalUids = totalUids + pages[pi].uids.size;
    }
    console.info('[PGPLAN] pages=' + pages.length.toString() + ' uids=' + totalUids.toString() +
      ' avg=' + (pages.length > 0 ? Math.round(totalUids / pages.length).toString() : '0') +
      ' trunc=' + (book.truncated ? '1' : '0') + ' p1=' + (pages.length > 0 ? pages[0].uids.size.toString() : '0') +
      ' roots=' + (pages.length > 0 ? pages[0].rootNodes.length.toString() : '0'));
  }

  /**
   * 把一棵子树尽量铺进本页：整支能放就放，放不下就放根卡再递归子女。
   * 返回 true 表示这一支已完整落在本页；false 表示有部分被切到后续页。
   */
  private fill(node: PersonNode, cur: PagePlan, style: string, profile: LayoutProfile, spec: PageSpec,
    sizeMap: Map<string, number>, slots: number, pending: PendingUnit[],
    nodeMap: Map<string, PersonNode>, queued: Set<string>): void {
    if (!cur.uids.has(node.uid)) {
      const size: number = sizeMap.get(node.uid) !== undefined ? (sizeMap.get(node.uid) as number) : 1;
      if (size <= slots - cur.uids.size) {
        const trial: Set<string> = this.copySet(cur.uids);
        this.collectSubtree(node, trial);
        const c: PageContent = this.computeCanvas(cur.rootNodes, trial, style, profile, spec);
        if (this.fits(c, spec)) {
          cur.uids = trial;
          return;
        }
      }
      // 整支放不下：先把根卡放进来，线由页根/承接父卡连到它
      const set: Set<string> = this.copySet(cur.uids);
      set.add(node.uid);
      const cc: PageContent = this.computeCanvas(cur.rootNodes, set, style, profile, spec);
      if (!this.fits(cc, spec)) {
        return;
      }
      cur.uids = set;
    }

    // 1) 深度优先收集候选：先沿长子钻到底，再回头铺次子。
    //    必须深度优先——广度优先会让整代兄弟先变成"最宽一排/一堆叶子"，
    //    欧式的页高、苏式的页宽立刻被占满，后面的世代再也放不进来。
    const limit: number = Math.max(1, slots - cur.uids.size);
    const order: PersonNode[] = [];
    const seen: Set<string> = new Set<string>();
    const walkStack: PersonNode[] = [node];
    const idxStack: number[] = [0];
    while (walkStack.length > 0 && order.length < limit) {
      const top: number = walkStack.length - 1;
      const parent: PersonNode = walkStack[top];
      const ci: number = idxStack[top];
      if (ci >= parent.children.length) {
        walkStack.pop();
        idxStack.pop();
        continue;
      }
      idxStack[top] = ci + 1;
      const child: PersonNode = parent.children[ci];
      if (seen.has(child.uid)) {
        continue;
      }
      seen.add(child.uid);
      if (!cur.uids.has(child.uid)) {
        order.push(child);
      }
      if (walkStack.length < MAX_PAGE_DEPTH) {
        walkStack.push(child);
        idxStack.push(0);
      }
    }

    // 2) 指数回退式批量试探：一次先试加一批，装不下就把批量减半重试。
    //
    // 不能用二分：布局能否装下对「前 k 个人」并不单调——深度优先的前若干个
    // 往往是一条链，先被列宽/页高卡住；而随后的兄弟落在同一列，几乎不增占位。
    // 二分会把这类「前面失败、后面反而装得下」的人整批丢掉，页数不降反升。
    // 也不能逐个试：五万人的谱是「人数 × 页内人数」次整页布局，主线程必超 6s。
    if (order.length > 0) {
      let i: number = 0;
      let step: number = 16;
      while (i < order.length) {
        const take: number = Math.min(step, order.length - i);
        const trial: Set<string> = this.copySet(cur.uids);
        for (let k: number = 0; k < take; k = k + 1) {
          trial.add(order[i + k].uid);
        }
        const c: PageContent = this.computeCanvas(cur.rootNodes, trial, style, profile, spec);
        if (this.fits(c, spec)) {
          cur.uids = trial;
          i = i + take;
          step = 16;
        } else if (take === 1) {
          if (cur.index <= 2) {
            console.info('[PGFITFAIL] p=' + cur.index.toString() +
              ' n=' + cur.uids.size.toString() + ' w=' + c.width.toFixed(1) +
              ' h=' + c.height.toFixed(1) +
              ' limitW=' + spec.contentWidth().toString() +
              ' limitH=' + spec.contentHeight().toString());
          }
          break;
        } else {
          // 这一批装不下：缩小批量再试，逐个找到真正的边界
          step = Math.max(1, Math.floor(take / 2));
        }
      }
    }

    // 3) 本页内每个人「落在页外的子女」统一记为续页，避免跨页悬空
    this.cutUncovered(cur, nodeMap, pending, queued);
  }

  /** 本页已排下的节点，其不在本页的子女全部切成续页单元 */
  private cutUncovered(cur: PagePlan, nodeMap: Map<string, PersonNode>, pending: PendingUnit[],
    queued: Set<string>): void {
    const parents: PersonNode[] = [];
    cur.uids.forEach((uid: string): void => {
      const n: PersonNode | undefined = nodeMap.get(uid);
      if (n !== undefined) {
        parents.push(n);
      }
    });
    for (let i: number = 0; i < parents.length; i = i + 1) {
      const p: PersonNode = parents[i];
      let first: number = -1;
      for (let k: number = 0; k < p.children.length; k = k + 1) {
        if (!cur.uids.has(p.children[k].uid)) {
          first = k;
          break;
        }
      }
      if (first >= 0) {
        this.cutChildren(p, p.children, first, cur, pending, queued);
      }
    }
  }

  /** 某个父卡还有子女没排进本页：记续见，并把它们排进后续页队列 */
  private cutChildren(parent: PersonNode, children: PersonNode[], start: number, cur: PagePlan,
    pending: PendingUnit[], queued: Set<string>): void {
    if (start >= children.length) {
      return;
    }
    const cut: PageCut = new PageCut();
    cut.parentUid = parent.uid;
    cut.parentName = parent.person.name;
    cut.relationText = (children.length - start).toString() + ' 支';
    for (let i: number = start; i < children.length; i = i + 1) {
      const child: PersonNode = children[i];
      // 已经在续页队列里的人不再重复入队：fill 每次都会扫全页的未覆盖子女，
      // 不去重会把同一批人切成多份，队列爆炸且同一人排进多页
      if (queued.has(child.uid)) {
        continue;
      }
      queued.add(child.uid);
      cut.childUids.push(child.uid);
      const rank: string = child.person.rank.length > 0 ? child.person.rank : '子';
      pending.push(new PendingUnit(child, parent, cur.index, rank));
    }
    if (cut.childUids.length > 0) {
      cur.cuts.push(cut);
    }
  }

  /** 本页切下来的续页单元插到队首，保证按房支、长幼顺序接着排 */
  private commitPending(queue: PendingUnit[], pending: PendingUnit[]): void {
    for (let i: number = pending.length - 1; i >= 0; i = i - 1) {
      queue.unshift(pending[i]);
    }
    pending.splice(0, pending.length);
  }

  /** 子树人数（后序汇总）：用于快速否定明显装不下的整支 */
  private buildSizeMap(root: PersonNode): Map<string, number> {
    const sizes: Map<string, number> = new Map<string, number>();
    const order: PersonNode[] = [];
    const seen: Set<string> = new Set<string>();
    const stack: PersonNode[] = [root];
    while (stack.length > 0) {
      const n: PersonNode = stack[stack.length - 1];
      stack.pop();
      if (seen.has(n.uid)) {
        continue;
      }
      seen.add(n.uid);
      order.push(n);
      for (let i: number = 0; i < n.children.length; i = i + 1) {
        stack.push(n.children[i]);
      }
    }
    for (let i: number = order.length - 1; i >= 0; i = i - 1) {
      const n: PersonNode = order[i];
      let s: number = 1;
      for (let k: number = 0; k < n.children.length; k = k + 1) {
        const cs: number | undefined = sizes.get(n.children[k].uid);
        s = s + (cs !== undefined ? cs : 1);
      }
      sizes.set(n.uid, s);
    }
    return sizes;
  }

  /** 每页卡片槽位上限；真正排版还会因树形留白，这里只用于快速否定 */
  private slotCapacity(style: string, spec: PageSpec, profile: LayoutProfile): number {
    const cols: number = Math.max(1, Math.floor(spec.contentWidth() / (profile.cardW + profile.colGap)));
    const rowH: number = style === TreeStyle.SU ?
      profile.cardH + profile.rowGap : profile.cardH + profile.siblingGap;
    const rows: number = Math.max(1, Math.floor(spec.contentHeight() / rowH));
    return cols * rows;
  }

  /** 落页：算世代范围、奇偶页、页码，然后追加到书里；返回本页人数（进度用） */
  private flushPage(page: PagePlan, pages: PagePlan[], nodeMap: Map<string, PersonNode>): number {
    let lo: number = -1;
    let hi: number = -1;
    page.uids.forEach((uid: string): void => {
      const n: PersonNode | undefined = nodeMap.get(uid);
      if (n === undefined) {
        return;
      }
      const g: number = n.person.generation;
      if (g <= 0) {
        return;
      }
      if (lo < 0 || g < lo) {
        lo = g;
      }
      if (g > hi) {
        hi = g;
      }
    });
    page.genFrom = lo;
    page.genTo = hi;
    page.recto = (page.index % 2) === 1;
    // 碎片页自检：整页只有承接卡/页根一两张卡时记一条，便于定位容量判定异常
    if (page.uids.size <= 2) {
      console.info('[PGTHIN] p=' + page.index.toString() + ' uids=' + page.uids.size.toString() +
        ' roots=' + page.rootNodes.length.toString() +
        ' cuts=' + page.cuts.length.toString());
    }
    pages.push(page);
    return page.uids.size;
  }

  /** 全量索引：人物→首次出现页；配偶 uid 也指到同一页（配偶以卡片文字出现） */
  private buildIndex(book: PrintBook, nodeMap: Map<string, PersonNode>): void {
    for (let i: number = 0; i < book.pages.length; i = i + 1) {
      const page: PagePlan = book.pages[i];
      page.uids.forEach((uid: string): void => {
        if (!book.indexByUid.has(uid)) {
          book.indexByUid.set(uid, page.index);
        }
        const n: PersonNode | undefined = nodeMap.get(uid);
        if (n === undefined) {
          return;
        }
        for (let k: number = 0; k < n.spouses.length; k = k + 1) {
          if (!book.indexByUid.has(n.spouses[k].uid)) {
            book.indexByUid.set(n.spouses[k].uid, page.index);
          }
        }
      });
    }
    // 承接父卡的「承第 N 页」
    for (let i: number = 0; i < book.pages.length; i = i + 1) {
      const page: PagePlan = book.pages[i];
      for (let r: number = 0; r < page.roots.length; r = r + 1) {
        const home: number = book.pageOf(page.roots[r].uid);
        // 承接父卡：取它首次出现页；同页下方新片段已显式记过来源页，不再覆盖
        if (home > 0 && page.roots[r].fromPage <= 0) {
          page.roots[r].fromPage = home;
        }
      }
    }
    // 页脚接续：父卡所在页写明后页页码
    for (let i: number = 0; i < book.pages.length; i = i + 1) {
      const page: PagePlan = book.pages[i];
      const notes: string[] = [];
      for (let c: number = 0; c < page.cuts.length; c = c + 1) {
        const cut: PageCut = page.cuts[c];
        let lo: number = 0;
        let hi: number = 0;
        for (let k: number = 0; k < cut.childUids.length; k = k + 1) {
          const p: number | undefined = book.indexByUid.get(cut.childUids[k]);
          if (p === undefined) {
            continue;
          }
          if (lo === 0 || p < lo) {
            lo = p;
          }
          if (p > hi) {
            hi = p;
          }
        }
        if (lo > 0) {
          const span: string = lo === hi ? lo.toString() : (lo.toString() + '—' + hi.toString());
          notes.push('续见第 ' + span + ' 页（' + cut.parentName + '以下 ' + cut.relationText + '）');
        }
      }
      page.footerText = notes.join('　');
    }
    this.decoratePages(book, nodeMap);
  }

  /**
   * 分支点优先换页判定。
   *
   * 只在新房支的起点（branchRootUid === 自身）且本页已混入其他房时触发；
   * 同一房支内部即使再出现分支点也不切页，避免把一房拆得过碎。
   */
  private shouldCutBeforeBranchPoint(unit: PendingUnit, cur: PagePlan,
    nodeMap: Map<string, PersonNode>): boolean {
    const node: PersonNode = unit.node;
    if (cur.uids.size < MIN_PEOPLE_PER_PAGE) {
      return false;
    }
    if (!node.isBranchPoint || node.branchRootUid !== node.uid) {
      return false;
    }
    if (cur.uids.has(node.uid)) {
      return false;
    }
    let otherBranch: boolean = false;
    cur.uids.forEach((uid: string): void => {
      if (otherBranch) {
        return;
      }
      const n: PersonNode | undefined = nodeMap.get(uid);
      if (n !== undefined && n.branchId !== node.branchId) {
        otherBranch = true;
      }
    });
    return otherBranch;
  }

  /**
   * 给每页补房支与承接信息：
   *  - branchName：页内首个节点的房名；
   *  - contextAncestors：页根上溯两代父辈（屏幕页首卡片、PDF 页首共用）；
   *  - siblingLinks：若页根就是房支起点，把父辈名下其他房的起页做成页脚软链接。
   */
  private decoratePages(book: PrintBook, nodeMap: Map<string, PersonNode>): void {
    for (let i: number = 0; i < book.pages.length; i = i + 1) {
      const page: PagePlan = book.pages[i];
      let first: PersonNode | null = null;
      page.uids.forEach((uid: string): void => {
        if (first !== null) {
          return;
        }
        const n: PersonNode | undefined = nodeMap.get(uid);
        if (n !== undefined) {
          first = n;
        }
      });
      if (first === null && page.rootNodes.length > 0) {
        first = page.rootNodes[0];
      }
      if (first === null) {
        continue;
      }
      page.branchName = first.branchName;
      // 房支归属：页内全部节点同属一房时才记 branchId；混房页置空，增量重排时回退全量
      const firstNode: PersonNode = first;
      page.branchId = firstNode.branchId;
      let mixedBranch: boolean = false;
      page.uids.forEach((uid: string): void => {
        if (mixedBranch) {
          return;
        }
        const n: PersonNode | undefined = nodeMap.get(uid);
        if (n !== undefined && n.branchId !== firstNode.branchId) {
          mixedBranch = true;
        }
      });
      if (mixedBranch) {
        page.branchId = '';
      }

      let cur: PersonNode = first;
      for (let k: number = 0; k < 2; k = k + 1) {
        const parent: PersonNode | null = cur.father !== null ? cur.father : cur.mother;
        if (parent === null || parent === cur) {
          break;
        }
        page.contextAncestors.push(parent.uid);
        page.contextAncestorNames.push(parent.person.name.length > 0 ? parent.person.name : parent.uid);
        cur = parent;
      }

      const anchor: PersonNode = page.rootNodes.length > 0 ? page.rootNodes[0] : first;
      if (anchor.branchRootUid !== anchor.uid || anchor.branchParentUid.length === 0) {
        continue;
      }
      const parentNode: PersonNode | undefined = nodeMap.get(anchor.branchParentUid);
      if (parentNode === undefined) {
        continue;
      }
      for (let c: number = 0; c < parentNode.children.length; c = c + 1) {
        const sibling: PersonNode = parentNode.children[c];
        if (sibling.uid === anchor.uid || sibling.branchRootUid !== sibling.uid) {
          continue;
        }
        const target: number = book.pageOf(sibling.uid);
        if (target <= 0) {
          continue;
        }
        const jump: PageJump = new PageJump();
        jump.uid = sibling.uid;
        jump.name = sibling.person.name.length > 0 ? sibling.person.name : sibling.uid;
        jump.page = target;
        jump.relation = sibling.branchName + '·' + jump.name;
        page.siblingLinks.push(jump);
        if (page.siblingLinks.length >= 4) {
          break;
        }
      }
    }
  }

  /** 只排本页的树：多个页根按「货架」横向拼接，把右侧空白用起来 */
  private computeCanvas(roots: PersonNode[], allowed: Set<string>, style: string,
    profile: LayoutProfile, spec: PageSpec): PageContent {
    const content: PageContent = new PageContent();
    if (style === TreeStyle.SU) {
      const c: SuCanvas = SuLayout.compute(roots, profile.cardW, false, profile.showSpouse, allowed, profile.metrics());
      content.su = c;
      content.width = c.width;
      content.height = c.height;
    } else if (roots.length <= 1) {
      const c: EuCanvas = EuLayout.compute(roots, profile.cardW, profile.cardH, profile.colGap,
        profile.showSpouse, 0, allowed, profile.metrics());
      content.eu = c;
      content.width = c.width;
      content.height = c.height;
    } else {
      // 多个互不相连的闭合片段：先各自布局，再按货架（先右后下）拼进同一版心。
      // 单页只有一个页根时，右侧会留下大量空白，正是「几个人一页」的主因。
      const merged: EuCanvas = new EuCanvas();
      const limitW: number = spec.contentWidth();
      const limitH: number = spec.contentHeight();
      const gap: number = 4;
      let cursorX: number = 0;
      let cursorY: number = 0;
      let shelfH: number = 0;
      let usedW: number = 0;
      let usedH: number = 0;
      let first: boolean = true;
      for (let i: number = 0; i < roots.length; i = i + 1) {
        const c: EuCanvas = EuLayout.compute([roots[i]], profile.cardW, profile.cardH, profile.colGap,
          profile.showSpouse, 0, allowed, profile.metrics());
        if (c.boxes.length === 0) {
          continue;
        }
        if (cursorX > 0 && cursorX + c.width > limitW + FIT_EPS) {
          cursorX = 0;
          cursorY = cursorY + shelfH + gap;
          shelfH = 0;
        }
        // 超出底部：保留这一片段，但版面高度会被 fits 判为超高，由装箱端换页
        for (let b: number = 0; b < c.boxes.length; b = b + 1) {
          const box = c.boxes[b];
          box.x = box.x + cursorX;
          box.y = box.y + cursorY;
          box.centerY = box.centerY + cursorY;
          merged.boxes.push(box);
          if (first) {
            merged.rootBox = box;
            first = false;
          }
        }
        for (let l: number = 0; l < c.lines.length; l = l + 1) {
          const seg: LineSeg = new LineSeg();
          seg.x1 = c.lines[l].x1 + cursorX;
          seg.y1 = c.lines[l].y1 + cursorY;
          seg.x2 = c.lines[l].x2 + cursorX;
          seg.y2 = c.lines[l].y2 + cursorY;
          seg.red = c.lines[l].red;
          seg.id = merged.lines.length;
          merged.lines.push(seg);
        }
        if (cursorX + c.width > usedW) {
          usedW = cursorX + c.width;
        }
        if (cursorY + c.height > usedH) {
          usedH = cursorY + c.height;
        }
        cursorX = cursorX + c.width + gap;
        if (c.height > shelfH) {
          shelfH = c.height;
        }
      }
      merged.width = usedW;
      merged.height = usedH;
      content.eu = merged;
      content.width = usedW;
      content.height = usedH;
    }
    return content;
  }

  private collectSubtree(node: PersonNode, into: Set<string>): void {
    const stack: PersonNode[] = [node];
    while (stack.length > 0) {
      const n: PersonNode = stack[stack.length - 1];
      stack.pop();
      if (into.has(n.uid)) {
        continue;
      }
      into.add(n.uid);
      for (let i: number = 0; i < n.children.length; i = i + 1) {
        stack.push(n.children[i]);
      }
    }
  }

  private indexSubtree(node: PersonNode, map: Map<string, PersonNode>): void {
    const stack: PersonNode[] = [node];
    while (stack.length > 0) {
      const n: PersonNode = stack[stack.length - 1];
      stack.pop();
      if (map.has(n.uid)) {
        continue;
      }
      map.set(n.uid, n);
      for (let i: number = 0; i < n.children.length; i = i + 1) {
        stack.push(n.children[i]);
      }
    }
  }

  private copySet(src: Set<string>): Set<string> {
    const out: Set<string> = new Set<string>();
    src.forEach((uid: string): void => {
      out.add(uid);
    });
    return out;
  }
}

/**
 * 页眉文案：世系图 · 第X世—第Y世
 */
export function pageGenText(page: PagePlan): string {
  if (page.genFrom <= 0) {
    return '世系图';
  }
  if (page.genFrom === page.genTo) {
    return '世系图 · ' + generationLabel(page.genFrom);
  }
  return '世系图 · ' + generationLabel(page.genFrom) + '—' + generationLabel(page.genTo);
}
