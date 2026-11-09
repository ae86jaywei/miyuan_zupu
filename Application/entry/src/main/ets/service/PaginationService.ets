import { PersonNode } from '../model/PersonNode';
import { TreeStyle, generationLabel } from '../model/Enums';
import { EuCanvas, EuLayout, SuCanvas, SuLayout } from './TreeLayout';
import { LayoutProfile, PageSpec } from './PrintLayout';
import { GenealogyService } from './GenealogyService';

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

/** 一页的排版计划（屏幕分页视图与未来 PDF 共用） */
export class PagePlan {
  /** 图册内页码，从 1 开始 */
  index: number = 1;
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
const MAX_PAGE_DEPTH: number = 24;
/** 规划页数/迭代上限：防止环状数据导致死循环 */
const MAX_PAGES: number = 4000;
const MAX_ITER: number = 40000;
/** 容量判定的浮点容差（mm） */
const FIT_EPS: number = 0.2;

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
  }

  /**
   * 取（或重建）某一宗支的分页结果。
   * @param rootUid 宗支根
   * @param style 谱式（EU / SU）
   * @param version 数据版本，用于失效
   * @param profileName standard / compact / large
   */
  book(rootUid: string, style: string, version: number, profileName: string = 'standard'): PrintBook {
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
    this.planBook(book, root, style);
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
    const content: PageContent = this.computeCanvas(page.rootNodes, page.uids, TreeStyle.EU, this.cached.profile);
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
    const content: PageContent = this.computeCanvas(page.rootNodes, page.uids, TreeStyle.SU, this.cached.profile);
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
  private planBook(book: PrintBook, root: PersonNode, style: string): void {
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
    let iter: number = 0;

    while ((queue.length > 0 || cur.uids.size > 0) && iter < MAX_ITER && pages.length < MAX_PAGES) {
      iter = iter + 1;
      if (queue.length === 0) {
        this.commitPending(queue, pending);
        this.flushPage(cur, pages, nodeMap);
        cur = new PagePlan();
        cur.index = pages.length + 1;
        continue;
      }
      const unit: PendingUnit = queue[0];

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

      // 这一支的承接父卡不是本页页根：本页到此为止，下一页再排
      if (cur.uids.size > 1 && unit.carry !== null && unit.carry.uid !== cur.rootNodes[0].uid) {
        this.commitPending(queue, pending);
        this.flushPage(cur, pages, nodeMap);
        cur = new PagePlan();
        cur.index = pages.length + 1;
        continue;
      }

      // 页根本身：直接向下递归填页
      if (cur.uids.has(unit.node.uid)) {
        this.fill(unit.node, cur, style, profile, spec, sizeMap, slots, pending);
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
        const c: PageContent = this.computeCanvas(cur.rootNodes, trial, style, profile);
        if (this.fits(c, spec)) {
          cur.uids = trial;
          queue.shift();
          continue;
        }
      }

      // 整支放不下：本页已有内容或已满，先落页，下一页从同一单元重试
      if (cur.uids.size > 1 || cur.uids.size >= slots) {
        this.commitPending(queue, pending);
        this.flushPage(cur, pages, nodeMap);
        cur = new PagePlan();
        cur.index = pages.length + 1;
        continue;
      }

      // 本页只有页根：深挖这一支，直到装满
      const before: number = cur.uids.size;
      this.fill(unit.node, cur, style, profile, spec, sizeMap, slots, pending);
      if (cur.uids.size === before && !cur.uids.has(unit.node.uid)) {
        // 连根卡都放不进：本页到此为止，下一页重试，不消费这个单元
        this.flushPage(cur, pages, nodeMap);
        cur = new PagePlan();
        cur.index = pages.length + 1;
        continue;
      }
      queue.shift();
    }
    if (cur.uids.size > 0 && pages.length < MAX_PAGES) {
      this.flushPage(cur, pages, nodeMap);
    }
    if (queue.length > 0 || pending.length > 0) {
      book.truncated = true;
    }
    book.pages = pages;
    book.pageCount = pages.length;
    this.buildIndex(book, nodeMap);
  }

  /**
   * 把一棵子树尽量铺进本页：整支能放就放，放不下就放根卡再递归子女。
   * 返回 true 表示这一支已完整落在本页；false 表示有部分被切到后续页。
   */
  private fill(node: PersonNode, cur: PagePlan, style: string, profile: LayoutProfile, spec: PageSpec,
    sizeMap: Map<string, number>, slots: number, pending: PendingUnit[]): void {
    if (!cur.uids.has(node.uid)) {
      const size: number = sizeMap.get(node.uid) !== undefined ? (sizeMap.get(node.uid) as number) : 1;
      if (size <= slots - cur.uids.size) {
        const trial: Set<string> = this.copySet(cur.uids);
        this.collectSubtree(node, trial);
        const c: PageContent = this.computeCanvas(cur.rootNodes, trial, style, profile);
        if (this.fits(c, spec)) {
          cur.uids = trial;
          return;
        }
      }
      // 整支放不下：先把根卡放进来，线由页根/承接父卡连到它
      const set: Set<string> = this.copySet(cur.uids);
      set.add(node.uid);
      const cc: PageContent = this.computeCanvas(cur.rootNodes, set, style, profile);
      if (!this.fits(cc, spec)) {
        return;
      }
      cur.uids = set;
    }

    // 逐层（广度优先）往页里加卡：同一代先铺开，避免顺着单支一路钻到页宽尽头
    let frontier: PersonNode[] = [node];
    let level: number = 0;
    while (frontier.length > 0 && cur.uids.size < slots) {
      level = level + 1;
      if (level > MAX_PAGE_DEPTH) {
        for (let f: number = 0; f < frontier.length; f = f + 1) {
          this.cutChildren(frontier[f], frontier[f].children, 0, cur, pending);
        }
        return;
      }
      const next: PersonNode[] = [];
      let stop: boolean = false;
      for (let f: number = 0; f < frontier.length && !stop; f = f + 1) {
        const parent: PersonNode = frontier[f];
        let start: number = 0;
        for (let i: number = 0; i < parent.children.length; i = i + 1) {
          if (cur.uids.size >= slots) {
            start = i;
            stop = true;
            break;
          }
          const child: PersonNode = parent.children[i];
          if (cur.uids.has(child.uid)) {
            next.push(child);
            continue;
          }
          const set: Set<string> = this.copySet(cur.uids);
          set.add(child.uid);
          const c: PageContent = this.computeCanvas(cur.rootNodes, set, style, profile);
          if (this.fits(c, spec)) {
            cur.uids = set;
            next.push(child);
          } else {
            start = i;
            stop = true;
            break;
          }
        }
        if (stop) {
          this.cutChildren(parent, parent.children, start, cur, pending);
          for (let k: number = f + 1; k < frontier.length; k = k + 1) {
            this.cutChildren(frontier[k], frontier[k].children, 0, cur, pending);
          }
        }
      }
      if (stop) {
        return;
      }
      frontier = next;
    }
  }

  /** 某个父卡还有子女没排进本页：记续见，并把它们排进后续页队列 */
  private cutChildren(parent: PersonNode, children: PersonNode[], start: number, cur: PagePlan,
    pending: PendingUnit[]): void {
    if (start >= children.length) {
      return;
    }
    const cut: PageCut = new PageCut();
    cut.parentUid = parent.uid;
    cut.parentName = parent.person.name;
    cut.relationText = (children.length - start).toString() + ' 支';
    for (let i: number = start; i < children.length; i = i + 1) {
      cut.childUids.push(children[i].uid);
      const rank: string = children[i].person.rank.length > 0 ? children[i].person.rank : '子';
      pending.push(new PendingUnit(children[i], parent, cur.index, rank));
    }
    cur.cuts.push(cut);
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

  /** 落页：算世代范围、奇偶页、页码，然后追加到书里 */
  private flushPage(page: PagePlan, pages: PagePlan[], nodeMap: Map<string, PersonNode>): void {
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
    pages.push(page);
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
        if (home > 0) {
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
  }

  /** 只排一棵子树：用于容量试排 */
  private computeCanvas(roots: PersonNode[], allowed: Set<string>, style: string,
    profile: LayoutProfile): PageContent {
    const content: PageContent = new PageContent();
    if (style === TreeStyle.SU) {
      const c: SuCanvas = SuLayout.compute(roots, profile.cardW, false, profile.showSpouse, allowed, profile.metrics());
      content.su = c;
      content.width = c.width;
      content.height = c.height;
    } else {
      const c: EuCanvas = EuLayout.compute(roots, profile.cardW, profile.cardH, profile.colGap,
        profile.showSpouse, 0, allowed, profile.metrics());
      content.eu = c;
      content.width = c.width;
      content.height = c.height;
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
