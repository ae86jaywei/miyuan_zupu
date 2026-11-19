import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hidebug, hilog } from '@kit.PerformanceAnalysisKit';
import { GenealogyService } from './GenealogyService';
import { PagePlan, PaginationService, PrintBook } from './PaginationService';
import { EuCanvas, SuCanvas, PersonNode } from 'common_base';
import { PageCanvasCodec } from './PageCanvasCodec';
import {
  CACHE_VOLUME_PAGES, CANVAS_WRITE_MAX_PSS_KB, PAGE_DB_NAME, PageCacheKey, PageRef,
  PageCacheSchema
} from './pagecache/PageCacheSchema';
import {
  BranchHasher, PageCacheKeeper, PageCacheReader, PageCacheWriter
} from './pagecache/PageCacheStore';

export { CACHE_VOLUME_PAGES, PageCacheKey, PageRef } from './pagecache/PageCacheSchema';

/**
 * 分页结果持久化缓存（P0）。
 *
 * 目标：
 *  - 导出 PDF 时不再每次重跑整树装箱，直接复用缓存的分页计划；
 *  - 提供 uid →「第几卷第几页」索引，供页脚、跨卷引用、后续详情跳转使用；
 *  - 低功耗预热：只在「小谱 + 当前谱式 + 数据版本稳定」时后台排队，页面离开可取消。
 *
 * 缓存的是 PagePlan（每页放哪些 uid + 页首/页脚元数据），不是卡片坐标；
 * 导出时每页仍按需做 EuLayout/SuLayout（一页几十人，成本远小于整树）。
 *
 * 本轮拆分：建表/缓存键见 pagecache/PageCacheSchema，读写与清理见
 * pagecache/PageCacheStore，本类只保留缓存编排（加载、增量重排、预热）。
 */
/** 预热延迟：数据保存后 6 秒再算，避开用户连续编辑 */
const WARMUP_DELAY_MS: number = 6000;
/** 只给中小族谱做后台预热：大谱整树装箱耗时较长，改为导出时计算 */
const WARMUP_MAX_PEOPLE: number = 5000;
/** 预热内存门槛：超过则不预热，避免和前台页面抢内存 */
const WARMUP_PSS_LIMIT_KB: number = 600 * 1024;

export class PageCacheService {
  private static instance: PageCacheService | null = null;
  private store: relationalStore.RdbStore | null = null;
  private initPromise: Promise<void> | null = null;
  private warmTimer: number = -1;
  private warmToken: number = 0;
  private warmRunning: boolean = false;

  static getInstance(): PageCacheService {
    if (PageCacheService.instance === null) {
      PageCacheService.instance = new PageCacheService();
    }
    return PageCacheService.instance;
  }

  /** 初始化独立缓存库：不碰主库，避免影响编辑事务 */
  init(context: common.Context): Promise<void> {
    if (this.initPromise !== null) {
      return this.initPromise;
    }
    this.initPromise = this.doInit(context);
    return this.initPromise;
  }

  private async doInit(context: common.Context): Promise<void> {
    try {
      const cfg: relationalStore.StoreConfig = {
        name: PAGE_DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, cfg);
      await PageCacheSchema.createTables(store);
      this.store = store;
    } catch (e) {
      hilog.warn(0x0000, 'PageCache', 'init failed: %{public}s', String(e));
      this.store = null;
    }
  }

  /**
   * 读取缓存并恢复成可直接布局的 PrintBook。
   * 数据版本不一致、页数不完整或页根已不存在时返回 null（按 miss 处理）。
   */
  async loadBook(style: string, profile: string, rootUid: string): Promise<PrintBook | null> {
    if (this.store === null) {
      return null;
    }
    const cacheKey: string = PageCacheKey.of(style, profile, rootUid);
    const rev: number = GenealogyService.getInstance().getVersion();
    try {
      const meta = await PageCacheReader.readMeta(this.store, cacheKey);
      if (meta === null) {
        return null;
      }
      if (meta.rev !== rev) {
        // 数据变了：先尝试按房支增量重排，失败再由调用方回退整树重算
        return await this.rebuildIncremental(style, profile, rootUid, cacheKey, rev);
      }
      if (meta.pages <= 0) {
        return null;
      }

      const plans: PagePlan[] | null = await PageCacheReader.readPlans(this.store, cacheKey);
      if (plans === null || plans.length !== meta.pages) {
        return null;
      }
      const indexMap: Map<string, number> =
        await PageCacheReader.readIndexMap(this.store, cacheKey);

      const book: PrintBook = PaginationService.buildBookFromPlans(plans, profile, indexMap);
      // 页根已经找不到（族谱被删改）时视为缓存失效，避免导出空白页
      for (let i: number = 0; i < book.pages.length; i = i + 1) {
        const p: PagePlan = book.pages[i];
        if (p.rootUids.length > 0 && p.rootNodes.length === 0) {
          return null;
        }
      }
      return book;
    } catch (e) {
      hilog.warn(0x0000, 'PageCache', 'load failed: %{public}s', String(e));
      return null;
    }
  }

  /**
   * 写入整本分页缓存。
   * 导出线程不等待：调用方用 scheduleSave 延迟落库，避免影响导出收尾速度。
   */
  async saveBook(book: PrintBook, style: string, profile: string, rootUid: string,
    volumePages: number): Promise<void> {
    if (this.store === null || book.pages.length === 0) {
      return;
    }
    const cacheKey: string = PageCacheKey.of(style, profile, rootUid);
    const rev: number = GenealogyService.getInstance().getVersion();
    const volPages: number = volumePages > 0 ? volumePages : CACHE_VOLUME_PAGES;
    try {
      await PageCacheWriter.saveBook(this.store, cacheKey, rev, book, volPages);
      await PageCacheKeeper.cleanupOldKeys(this.store);
    } catch (e) {
      hilog.warn(0x0000, 'PageCache', 'save failed: %{public}s', String(e));
    }
  }

  /**
   * 房支增量重排（P1）：
   *  - 页全部单房、且房支集合与上次一致时，逐房比较 hash；
   *  - 未变房支直接复用旧页，只重排变化房支；
   *  - 拼接后统一重编号、重建人物索引与页脚/兄弟链接。
   * 任何条件不满足（混房页、房支增删）返回 null，由调用方回退整树重排。
   */
  private async rebuildIncremental(style: string, profile: string, rootUid: string,
    cacheKey: string, rev: number): Promise<PrintBook | null> {
    if (this.store === null) {
      return null;
    }
    const roots: PersonNode[] = GenealogyService.getInstance().getRoots();
    if (roots.length !== 1 || roots[0].uid !== rootUid) {
      return null;
    }
    const oldPlans: PagePlan[] | null = await PageCacheReader.readPlans(this.store, cacheKey);
    if (oldPlans === null) {
      return null;
    }
    const hashes: Map<string, string> =
      await PageCacheReader.readBranchHashes(this.store, cacheKey);
    if (hashes.size === 0) {
      return null;
    }
    // 旧页必须全部归属单一房支；混房页无法安全复用
    const oldByBranch: Map<string, PagePlan[]> = new Map<string, PagePlan[]>();
    const order: string[] = [];
    for (let i: number = 0; i < oldPlans.length; i = i + 1) {
      const p: PagePlan = oldPlans[i];
      if (p.branchId.length === 0) {
        return null;
      }
      let arr: PagePlan[] | undefined = oldByBranch.get(p.branchId);
      if (arr === undefined) {
        arr = [];
        oldByBranch.set(p.branchId, arr);
        order.push(p.branchId);
      }
      arr.push(p);
    }
    // 当前房支集合必须与旧缓存一致；新增/删除房支回退全量
    const nodes: Map<string, PersonNode> = PaginationService.nodeIndexOfCurrentBook();
    const current: Set<string> = new Set<string>();
    nodes.forEach((n: PersonNode): void => {
      if (n.branchId.length > 0) {
        current.add(n.branchId);
      }
    });
    if (current.size !== order.length) {
      return null;
    }
    for (let i: number = 0; i < order.length; i = i + 1) {
      if (!current.has(order[i])) {
        return null;
      }
      // 本支页（branchId = 宗支根）调用 book(root) 会重排整棵树，无法安全复用，直接回退全量
      if (order[i] === rootUid) {
        return null;
      }
    }

    const outPages: PagePlan[] = [];
    let changed: boolean = false;
    for (let i: number = 0; i < order.length; i = i + 1) {
      const branchId: string = order[i];
      const oldHash: string | undefined = hashes.get(branchId);
      const newHash: string = BranchHasher.hash(branchId);
      if (oldHash !== undefined && oldHash === newHash) {
        const arr: PagePlan[] | undefined = oldByBranch.get(branchId);
        if (arr === undefined) {
          return null;
        }
        for (let k: number = 0; k < arr.length; k = k + 1) {
          outPages.push(arr[k]);
        }
        continue;
      }
      const branchRoot: PersonNode | undefined = nodes.get(branchId);
      if (branchRoot === undefined) {
        return null;
      }
      const b: PrintBook = await PaginationService.getInstance().book(branchId, style, rev, profile);
      if (b.pages.length === 0) {
        return null;
      }
      for (let k: number = 0; k < b.pages.length; k = k + 1) {
        outPages.push(b.pages[k]);
      }
      changed = true;
    }
    if (outPages.length === 0) {
      return null;
    }
    const book: PrintBook = PaginationService.buildBookFromPlans(outPages, profile,
      new Map<string, number>());
    PaginationService.rebuildIndexAndLinks(book);
    // 即使没有任何房支变化，也要刷新 meta 的数据版本，避免下次又走全量
    await this.saveBook(book, style, profile, rootUid, CACHE_VOLUME_PAGES);
    if (!changed) {
      return book;
    }
    return book;
  }

  /** 导出完成后延迟写缓存：不占用导出收尾时间 */
  scheduleSave(book: PrintBook, style: string, profile: string, rootUid: string,
    volumePages: number): void {
    if (this.store === null) {
      return;
    }
    const rev: number = GenealogyService.getInstance().getVersion();
    setTimeout((): void => {
      if (GenealogyService.getInstance().getVersion() !== rev) {
        return;
      }
      this.saveBook(book, style, profile, rootUid, volumePages).catch((): void => {
      });
    }, 1500);
  }

  /** 查询某人所在卷/页（没有缓存时返回 null） */
  async lookup(uid: string): Promise<PageRef | null> {
    if (this.store === null) {
      return null;
    }
    const roots = GenealogyService.getInstance().getRoots();
    if (roots.length === 0) {
      return null;
    }
    const style: string = AppStorage.get<string>('gpStyle') ?? 'eu';
    const cacheKey: string = PageCacheKey.of(style, 'standard', roots[0].uid);
    try {
      const rs = await PageCacheReader.readRef(this.store, cacheKey, uid);
      if (rs === null) {
        return null;
      }
      try {
        if (!rs.goToNextRow()) {
          return null;
        }
        const ref: PageRef = new PageRef();
        ref.volume = rs.getLong(rs.getColumnIndex('volume'));
        ref.pageNo = rs.getLong(rs.getColumnIndex('page_no'));
        ref.globalPage = rs.getLong(rs.getColumnIndex('global_page'));
        ref.pageRootUid = rs.getString(rs.getColumnIndex('page_root_uid'));
        return ref;
      } finally {
        rs.close();
      }
    } catch (_e) {
      return null;
    }
  }

  /** 写一页布局缓存（P3）：PSS 过高时跳过写入，避免与导出峰值叠加 */
  async saveCanvas(style: string, profile: string, rootUid: string, pageNo: number,
    canvas: EuCanvas | SuCanvas): Promise<void> {
    if (this.store === null) {
      return;
    }
    let pss: number = -1;
    try {
      pss = Number(hidebug.getPss());
    } catch (_e) {
      pss = -1;
    }
    if (pss > CANVAS_WRITE_MAX_PSS_KB) {
      return;
    }
    const cacheKey: string = PageCacheKey.of(style, profile, rootUid);
    const rev: number = GenealogyService.getInstance().getVersion();
    try {
      const json: string = PageCanvasCodec.encode(canvas, style);
      await PageCacheWriter.writeCanvas(this.store, cacheKey, style, pageNo, rev, json);
    } catch (e) {
      hilog.warn(0x0000, 'PageCache', 'save canvas failed: %{public}s', String(e));
    }
  }

  /** 读一页布局缓存；数据版本不一致或节点已删时返回 null，调用方回退实时布局 */
  async loadCanvas(style: string, profile: string, rootUid: string,
    pageNo: number): Promise<EuCanvas | SuCanvas | null> {
    if (this.store === null) {
      return null;
    }
    const cacheKey: string = PageCacheKey.of(style, profile, rootUid);
    const rev: number = GenealogyService.getInstance().getVersion();
    try {
      const json: string | null =
        await PageCacheReader.readCanvasJson(this.store, cacheKey, style, pageNo, rev);
      if (json === null) {
        return null;
      }
      return PageCanvasCodec.decode(json, style);
    } catch (_e) {
      return null;
    }
  }

  /**
   * 低功耗预热：延迟 6 秒、只对单宗支中小谱、内存充足时执行；
   * 页面隐藏/数据变化时 cancel，已排队任务的结果会被 token 丢弃。
   */
  scheduleWarmup(): void {
    if (this.store === null || this.warmRunning) {
      return;
    }
    if (this.warmTimer >= 0) {
      clearTimeout(this.warmTimer);
    }
    this.warmTimer = setTimeout((): void => {
      this.warmTimer = -1;
      this.warmupOnce().catch((): void => {
      });
    }, WARMUP_DELAY_MS);
  }

  cancelWarmup(): void {
    this.warmToken = this.warmToken + 1;
    if (this.warmTimer >= 0) {
      clearTimeout(this.warmTimer);
      this.warmTimer = -1;
    }
  }

  private async warmupOnce(): Promise<void> {
    const svc: GenealogyService = GenealogyService.getInstance();
    if (!svc.isReady() || this.store === null) {
      return;
    }
    const roots = svc.getRoots();
    if (roots.length !== 1) {
      return;
    }
    const style: string = AppStorage.get<string>('gpStyle') ?? 'eu';
    if (style !== 'eu' && style !== 'su') {
      return;
    }
    const count: number = AppStorage.get<number>('gpPeopleCount') ?? 0;
    if (count <= 0 || count > WARMUP_MAX_PEOPLE) {
      return;
    }
    let pss: number = -1;
    try {
      pss = Number(hidebug.getPss());
    } catch (_e) {
      pss = -1;
    }
    if (pss > WARMUP_PSS_LIMIT_KB) {
      return;
    }
    const rev: number = svc.getVersion();
    const cacheKey: string = PageCacheKey.of(style, 'standard', roots[0].uid);
    if (await PageCacheReader.isFresh(this.store, cacheKey, rev)) {
      return;
    }
    const token: number = this.warmToken + 1;
    this.warmToken = token;
    this.warmRunning = true;
    try {
      const book: PrintBook = await PaginationService.getInstance().book(
        roots[0].uid, style, rev, 'standard');
      if (token !== this.warmToken || svc.getVersion() !== rev) {
        return;
      }
      await this.saveBook(book, style, 'standard', roots[0].uid, CACHE_VOLUME_PAGES);
    } catch (e) {
      hilog.warn(0x0000, 'PageCache', 'warmup failed: %{public}s', String(e));
    } finally {
      this.warmRunning = false;
    }
  }
}
