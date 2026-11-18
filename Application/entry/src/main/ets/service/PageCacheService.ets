import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hidebug, hilog } from '@kit.PerformanceAnalysisKit';
import { GenealogyService } from './GenealogyService';
import { PagePlan, PageCut, PageJump, PageRootRef, PaginationService, PrintBook } from './PaginationService';
import { EuCanvas, EuBox, LineSeg, SuCanvas, SuBox } from './TreeLayout';
import { PersonNode } from 'common_base';

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
 */
const DB_NAME: string = 'page_cache.db';
const TABLE_META: string = 'page_cache_meta';
const TABLE_PLAN: string = 'page_cache_plan';
const TABLE_INDEX: string = 'page_cache_index';
const TABLE_VOLUME: string = 'page_cache_volume';
const TABLE_BRANCH: string = 'page_cache_branch';
const TABLE_CANVAS: string = 'page_cache_canvas';

/** 缓存结构版本：排序规则、分页算法、纸张规格变化时必须 +1（3 = 欧式右起版面 + 装订口在右） */
const CACHE_VERSION: number = 3;
/** 预热延迟：数据保存后 6 秒再算，避开用户连续编辑 */
const WARMUP_DELAY_MS: number = 6000;
/** 只给中小族谱做后台预热：大谱整树装箱耗时较长，改为导出时计算 */
const WARMUP_MAX_PEOPLE: number = 5000;
/** 预热内存门槛：超过则不预热，避免和前台页面抢内存 */
const WARMUP_PSS_LIMIT_KB: number = 600 * 1024;
/** 写入缓存的批量大小 */
const WRITE_BATCH: number = 50;
/** 导出缓存默认分卷页数（与 PagedPdfExportService 保持一致） */
export const CACHE_VOLUME_PAGES: number = 30;
/** 只保留最近 N 个族谱/谱式缓存，避免缓存库无限增长 */
const CACHE_KEEP_KEYS: number = 3;
/** 布局缓存写入内存门槛：PSS 超限时只读不写，避免导出峰值叠加 */
const CANVAS_WRITE_MAX_PSS_KB: number = 700 * 1024;

/** 人物位置引用：第几卷、第几页、全局页 */
export class PageRef {
  volume: number = 1;
  pageNo: number = 1;
  globalPage: number = 1;
  pageRootUid: string = '';
  branchName: string = '';
}

/** 布局缓存中的一张卡片（只存 uid 与几何，恢复时再挂回 PersonNode） */
class CanvasBoxRec {
  uid: string = '';
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;
  centerY: number = 0;
}

/** 一页布局的磁盘格式（欧式/苏式共用，按 style 区分） */
class CanvasRec {
  width: number = 0;
  height: number = 0;
  rootUid: string = '';
  boxes: CanvasBoxRec[] = [];
  lines: LineSeg[] = [];
}

/** 缓存键 */
export class PageCacheKey {
  static of(style: string, profile: string, rootUid: string): string {
    const book = GenealogyService.getInstance().getBook();
    const bookId: number = book === null ? 0 : book.key;
    return bookId.toString() + '|' + style + '|' + profile + '|' + rootUid + '|' +
      CACHE_VERSION.toString();
  }
}

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
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, cfg);
      await store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_META} (
        cache_key TEXT PRIMARY KEY,
        data_rev INTEGER NOT NULL DEFAULT 0,
        pages INTEGER NOT NULL DEFAULT 0,
        volumes INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT 0
      )`);
      await store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_PLAN} (
        cache_key TEXT NOT NULL,
        global_page INTEGER NOT NULL,
        volume INTEGER NOT NULL DEFAULT 1,
        page_no INTEGER NOT NULL DEFAULT 1,
        branch_id TEXT,
        page_root_uid TEXT,
        gen_from INTEGER NOT NULL DEFAULT 0,
        gen_to INTEGER NOT NULL DEFAULT 0,
        root_uids TEXT,
        uids TEXT,
        roots_json TEXT,
        cuts_json TEXT,
        context_uids TEXT,
        context_names TEXT,
        sibling_json TEXT,
        footer_text TEXT,
        branch_name TEXT,
        recto INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY(cache_key, global_page)
      )`);
      await store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_INDEX} (
        cache_key TEXT NOT NULL,
        uid TEXT NOT NULL,
        volume INTEGER NOT NULL DEFAULT 1,
        page_no INTEGER NOT NULL DEFAULT 1,
        global_page INTEGER NOT NULL DEFAULT 1,
        page_root_uid TEXT,
        PRIMARY KEY(cache_key, uid)
      )`);
      await store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_VOLUME} (
        cache_key TEXT NOT NULL,
        volume INTEGER NOT NULL,
        title TEXT,
        start_page INTEGER NOT NULL DEFAULT 1,
        end_page INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY(cache_key, volume)
      )`);
      await store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_BRANCH} (
        cache_key TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        branch_hash TEXT,
        start_page INTEGER NOT NULL DEFAULT 1,
        end_page INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY(cache_key, branch_id)
      )`);
      await store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_CANVAS} (
        cache_key TEXT NOT NULL,
        style TEXT NOT NULL,
        page_no INTEGER NOT NULL,
        data_rev INTEGER NOT NULL DEFAULT 0,
        canvas_json TEXT,
        PRIMARY KEY(cache_key, style, page_no)
      )`);
      this.store = store;
    } catch (e) {
      hilog.warn(0x0000, 'PageCache', 'init failed: %{public}s', String(e));
      this.store = null;
    }
  }

  /** 缓存是否与当前数据版本一致 */
  private async isFresh(cacheKey: string, rev: number): Promise<boolean> {
    if (this.store === null) {
      return false;
    }
    const rs: relationalStore.ResultSet = await this.store.querySql(
      `SELECT data_rev FROM ${TABLE_META} WHERE cache_key = ?`, [cacheKey]);
    try {
      if (!rs.goToNextRow()) {
        return false;
      }
      return rs.getLong(rs.getColumnIndex('data_rev')) === rev;
    } finally {
      rs.close();
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
      const meta: relationalStore.ResultSet = await this.store.querySql(
        `SELECT data_rev, pages FROM ${TABLE_META} WHERE cache_key = ?`, [cacheKey]);
      let pages: number = 0;
      let metaRev: number = -1;
      try {
        if (!meta.goToNextRow()) {
          return null;
        }
        metaRev = meta.getLong(meta.getColumnIndex('data_rev'));
        pages = meta.getLong(meta.getColumnIndex('pages'));
      } finally {
        meta.close();
      }
      if (metaRev !== rev) {
        // 数据变了：先尝试按房支增量重排，失败再由调用方回退整树重算
        return await this.rebuildIncremental(style, profile, rootUid, cacheKey, rev);
      }
      if (pages <= 0) {
        return null;
      }

      const rs: relationalStore.ResultSet = await this.store.querySql(
        `SELECT * FROM ${TABLE_PLAN} WHERE cache_key = ? ORDER BY global_page`, [cacheKey]);
      const plans: PagePlan[] = [];
      try {
        while (rs.goToNextRow()) {
          const p: PagePlan = new PagePlan();
          p.index = rs.getLong(rs.getColumnIndex('page_no'));
          p.branchId = rs.getString(rs.getColumnIndex('branch_id'));
          p.genFrom = rs.getLong(rs.getColumnIndex('gen_from'));
          p.genTo = rs.getLong(rs.getColumnIndex('gen_to'));
          p.rootUids = PageCacheService.parseStringArray(rs.getString(rs.getColumnIndex('root_uids')));
          p.uids = PageCacheService.parseUidSet(rs.getString(rs.getColumnIndex('uids')));
          p.roots = JSON.parse(rs.getString(rs.getColumnIndex('roots_json'))) as PageRootRef[];
          p.cuts = JSON.parse(rs.getString(rs.getColumnIndex('cuts_json'))) as PageCut[];
          p.contextAncestors = PageCacheService.parseStringArray(
            rs.getString(rs.getColumnIndex('context_uids')));
          p.contextAncestorNames = PageCacheService.parseStringArray(
            rs.getString(rs.getColumnIndex('context_names')));
          p.siblingLinks = JSON.parse(rs.getString(rs.getColumnIndex('sibling_json'))) as PageJump[];
          p.footerText = rs.getString(rs.getColumnIndex('footer_text'));
          p.branchName = rs.getString(rs.getColumnIndex('branch_name'));
          p.recto = rs.getLong(rs.getColumnIndex('recto')) === 1;
          plans.push(p);
        }
      } finally {
        rs.close();
      }
      if (plans.length !== pages) {
        return null;
      }

      const indexMap: Map<string, number> = new Map<string, number>();
      const idxRs: relationalStore.ResultSet = await this.store.querySql(
        `SELECT uid, page_no FROM ${TABLE_INDEX} WHERE cache_key = ?`, [cacheKey]);
      try {
        while (idxRs.goToNextRow()) {
          indexMap.set(idxRs.getString(idxRs.getColumnIndex('uid')),
            idxRs.getLong(idxRs.getColumnIndex('page_no')));
        }
      } finally {
        idxRs.close();
      }

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
      await this.store.executeSql(`DELETE FROM ${TABLE_META} WHERE cache_key = ?`, [cacheKey]);
      await this.store.executeSql(`DELETE FROM ${TABLE_PLAN} WHERE cache_key = ?`, [cacheKey]);
      await this.store.executeSql(`DELETE FROM ${TABLE_INDEX} WHERE cache_key = ?`, [cacheKey]);
      await this.store.executeSql(`DELETE FROM ${TABLE_VOLUME} WHERE cache_key = ?`, [cacheKey]);
      await this.store.executeSql(`DELETE FROM ${TABLE_BRANCH} WHERE cache_key = ?`, [cacheKey]);
      // 只清理旧数据版本的布局缓存；同版本的 canvas 在导出过程中写入，不能删
      await this.store.executeSql(`DELETE FROM ${TABLE_CANVAS} WHERE cache_key = ? AND data_rev != ?`,
        [cacheKey, rev]);

      const meta: relationalStore.ValuesBucket = {
        'cache_key': cacheKey,
        'data_rev': rev,
        'pages': book.pages.length,
        'volumes': Math.max(1, Math.ceil(book.pages.length / volPages)),
        'created_at': Date.now()
      };
      await this.store.insert(TABLE_META, meta);

      let planBatch: relationalStore.ValuesBucket[] = [];
      let indexBatch: relationalStore.ValuesBucket[] = [];
      const seenUid: Set<string> = new Set<string>();
      const branchStart: Map<string, number> = new Map<string, number>();
      const branchEnd: Map<string, number> = new Map<string, number>();
      for (let i: number = 0; i < book.pages.length; i = i + 1) {
        const page: PagePlan = book.pages[i];
        const globalPage: number = i + 1;
        const volume: number = Math.floor(i / volPages) + 1;
        const rootUid0: string = page.rootUids.length > 0 ? page.rootUids[0] : '';
        const uids: string[] = [];
        page.uids.forEach((uid: string): void => {
          uids.push(uid);
        });
        const planRow: relationalStore.ValuesBucket = {
          'cache_key': cacheKey,
          'global_page': globalPage,
          'volume': volume,
          'page_no': i % volPages + 1,
          'branch_id': page.branchId,
          'page_root_uid': rootUid0,
          'gen_from': page.genFrom,
          'gen_to': page.genTo,
          'root_uids': JSON.stringify(page.rootUids),
          'uids': JSON.stringify(uids),
          'roots_json': JSON.stringify(page.roots),
          'cuts_json': JSON.stringify(page.cuts),
          'context_uids': JSON.stringify(page.contextAncestors),
          'context_names': JSON.stringify(page.contextAncestorNames),
          'sibling_json': JSON.stringify(page.siblingLinks),
          'footer_text': page.footerText,
          'branch_name': page.branchName,
          'recto': page.recto ? 1 : 0
        };
        planBatch.push(planRow);

        if (page.branchId.length > 0) {
          if (!branchStart.has(page.branchId)) {
            branchStart.set(page.branchId, globalPage);
          }
          branchEnd.set(page.branchId, globalPage);
        }

        for (let k: number = 0; k < uids.length; k = k + 1) {
          const uid: string = uids[k];
          if (seenUid.has(uid)) {
            continue;
          }
          seenUid.add(uid);
          const row: relationalStore.ValuesBucket = {
            'cache_key': cacheKey,
            'uid': uid,
            'volume': volume,
            'page_no': i % volPages + 1,
            'global_page': globalPage,
            'page_root_uid': rootUid0
          };
          indexBatch.push(row);
          const person = GenealogyService.getInstance().getPerson(uid);
          if (person !== null) {
            for (let s: number = 0; s < person.spouses.length; s = s + 1) {
              const spUid: string = person.spouses[s].uid;
              if (spUid.length === 0 || seenUid.has(spUid)) {
                continue;
              }
              seenUid.add(spUid);
              const spRow: relationalStore.ValuesBucket = {
                'cache_key': cacheKey,
                'uid': spUid,
                'volume': volume,
                'page_no': i % volPages + 1,
                'global_page': globalPage,
                'page_root_uid': rootUid0
              };
              indexBatch.push(spRow);
            }
          }
        }
        if (planBatch.length >= WRITE_BATCH) {
          await this.store.batchInsert(TABLE_PLAN, planBatch);
          planBatch = [];
        }
        if (indexBatch.length >= WRITE_BATCH) {
          await this.store.batchInsert(TABLE_INDEX, indexBatch);
          indexBatch = [];
        }
      }
      if (planBatch.length > 0) {
        await this.store.batchInsert(TABLE_PLAN, planBatch);
      }
      if (indexBatch.length > 0) {
        await this.store.batchInsert(TABLE_INDEX, indexBatch);
      }

      const volumes: number = Math.max(1, Math.ceil(book.pages.length / volPages));
      for (let v: number = 1; v <= volumes; v = v + 1) {
        const start: number = (v - 1) * volPages + 1;
        const end: number = Math.min(book.pages.length, v * volPages);
        const firstPage: PagePlan = book.pages[start - 1];
        const title: string = '第' + v.toString() + '卷' +
          (firstPage.branchName.length > 0 ? '（' + firstPage.branchName + '）' : '');
        const vb: relationalStore.ValuesBucket = {
          'cache_key': cacheKey,
          'volume': v,
          'title': title,
          'start_page': start,
          'end_page': end
        };
        await this.store.insert(TABLE_VOLUME, vb);
      }

      const branchRows: relationalStore.ValuesBucket[] = [];
      branchStart.forEach((start: number, branchId: string): void => {
        const end: number | undefined = branchEnd.get(branchId);
        const row: relationalStore.ValuesBucket = {
          'cache_key': cacheKey,
          'branch_id': branchId,
          'branch_hash': this.hashBranch(branchId),
          'start_page': start,
          'end_page': end === undefined ? start : end
        };
        branchRows.push(row);
      });
      if (branchRows.length > 0) {
        await this.store.batchInsert(TABLE_BRANCH, branchRows);
      }
      await this.cleanupOldKeys();
    } catch (e) {
      hilog.warn(0x0000, 'PageCache', 'save failed: %{public}s', String(e));
    }
  }

  /** 房支 hash：整房人物、关系、更新时间与排序键的聚合指纹（FNV-1a） */
  private hashBranch(branchId: string): string {
    const nodes: Map<string, PersonNode> = PaginationService.nodeIndexOfCurrentBook();
    const root: PersonNode | undefined = nodes.get(branchId);
    if (root === undefined) {
      return '';
    }
    const parts: string[] = [];
    const stack: PersonNode[] = [root];
    const seen: Set<string> = new Set<string>();
    while (stack.length > 0) {
      const n: PersonNode = stack.pop() as PersonNode;
      if (seen.has(n.uid)) {
        continue;
      }
      seen.add(n.uid);
      parts.push(n.uid + '|' + n.person.updatedAt.toString() + '|' + n.person.name + '|' +
        n.person.gender + '|' + n.person.generation.toString() + '|' + n.person.fatherId + '|' +
        n.person.motherId + '|' + n.person.lifeStatus);
      for (let s: number = 0; s < n.spouses.length; s = s + 1) {
        const sp: PersonNode = n.spouses[s];
        parts.push('s|' + sp.uid + '|' + sp.person.name + '|' + sp.person.updatedAt.toString());
      }
      for (let k: number = 0; k < n.children.length; k = k + 1) {
        stack.push(n.children[k]);
      }
    }
    parts.sort();
    const text: string = parts.join(';');
    let h: number = 2166136261;
    for (let i: number = 0; i < text.length; i = i + 1) {
      h = h ^ text.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(16);
  }

  /** 读取整本页计划（增量重排用） */
  private async readPlans(cacheKey: string): Promise<PagePlan[] | null> {
    if (this.store === null) {
      return null;
    }
    const rs: relationalStore.ResultSet = await this.store.querySql(
      `SELECT * FROM ${TABLE_PLAN} WHERE cache_key = ? ORDER BY global_page`, [cacheKey]);
    const plans: PagePlan[] = [];
    try {
      while (rs.goToNextRow()) {
        const p: PagePlan = new PagePlan();
        p.index = rs.getLong(rs.getColumnIndex('page_no'));
        p.branchId = rs.getString(rs.getColumnIndex('branch_id'));
        p.genFrom = rs.getLong(rs.getColumnIndex('gen_from'));
        p.genTo = rs.getLong(rs.getColumnIndex('gen_to'));
        p.rootUids = PageCacheService.parseStringArray(rs.getString(rs.getColumnIndex('root_uids')));
        p.uids = PageCacheService.parseUidSet(rs.getString(rs.getColumnIndex('uids')));
        p.roots = JSON.parse(rs.getString(rs.getColumnIndex('roots_json'))) as PageRootRef[];
        p.cuts = JSON.parse(rs.getString(rs.getColumnIndex('cuts_json'))) as PageCut[];
        p.contextAncestors = PageCacheService.parseStringArray(
          rs.getString(rs.getColumnIndex('context_uids')));
        p.contextAncestorNames = PageCacheService.parseStringArray(
          rs.getString(rs.getColumnIndex('context_names')));
        p.siblingLinks = JSON.parse(rs.getString(rs.getColumnIndex('sibling_json'))) as PageJump[];
        p.footerText = rs.getString(rs.getColumnIndex('footer_text'));
        p.branchName = rs.getString(rs.getColumnIndex('branch_name'));
        p.recto = rs.getLong(rs.getColumnIndex('recto')) === 1;
        plans.push(p);
      }
    } finally {
      rs.close();
    }
    return plans.length > 0 ? plans : null;
  }

  /** 读取上次保存的房支 hash */
  private async readBranchHashes(cacheKey: string): Promise<Map<string, string>> {
    const out: Map<string, string> = new Map<string, string>();
    if (this.store === null) {
      return out;
    }
    const rs: relationalStore.ResultSet = await this.store.querySql(
      `SELECT branch_id, branch_hash FROM ${TABLE_BRANCH} WHERE cache_key = ?`, [cacheKey]);
    try {
      while (rs.goToNextRow()) {
        out.set(rs.getString(rs.getColumnIndex('branch_id')),
          rs.getString(rs.getColumnIndex('branch_hash')));
      }
    } finally {
      rs.close();
    }
    return out;
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
    const oldPlans: PagePlan[] | null = await this.readPlans(cacheKey);
    if (oldPlans === null) {
      return null;
    }
    const hashes: Map<string, string> = await this.readBranchHashes(cacheKey);
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
      const newHash: string = this.hashBranch(branchId);
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

  /** 只保留最近 N 个缓存键，删除其余所有表数据（P2） */
  private async cleanupOldKeys(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const rs: relationalStore.ResultSet = await this.store.querySql(
      `SELECT cache_key FROM ${TABLE_META} ORDER BY created_at DESC`);
    const keys: string[] = [];
    try {
      while (rs.goToNextRow()) {
        keys.push(rs.getString(rs.getColumnIndex('cache_key')));
      }
    } finally {
      rs.close();
    }
    for (let i: number = CACHE_KEEP_KEYS; i < keys.length; i = i + 1) {
      const k: string = keys[i];
      await this.store.executeSql(`DELETE FROM ${TABLE_META} WHERE cache_key = ?`, [k]);
      await this.store.executeSql(`DELETE FROM ${TABLE_PLAN} WHERE cache_key = ?`, [k]);
      await this.store.executeSql(`DELETE FROM ${TABLE_INDEX} WHERE cache_key = ?`, [k]);
      await this.store.executeSql(`DELETE FROM ${TABLE_VOLUME} WHERE cache_key = ?`, [k]);
      await this.store.executeSql(`DELETE FROM ${TABLE_BRANCH} WHERE cache_key = ?`, [k]);
      await this.store.executeSql(`DELETE FROM ${TABLE_CANVAS} WHERE cache_key = ?`, [k]);
    }
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
      const rs: relationalStore.ResultSet = await this.store.querySql(
        `SELECT volume, page_no, global_page, page_root_uid FROM ${TABLE_INDEX}
         WHERE cache_key = ? AND uid = ?`, [cacheKey, uid]);
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

  /**
   * 低功耗预热：延迟 6 秒、只对单宗支中小谱、内存充足时执行；
   * 页面隐藏/数据变化时 cancel，已排队任务的结果会被 token 丢弃。
   */
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
      const json: string = PageCacheService.canvasToJson(canvas, style);
      await this.store.executeSql(
        `INSERT OR REPLACE INTO ${TABLE_CANVAS}(cache_key, style, page_no, data_rev, canvas_json)
         VALUES(?, ?, ?, ?, ?)`, [cacheKey, style, pageNo, rev, json]);
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
      const rs: relationalStore.ResultSet = await this.store.querySql(
        `SELECT canvas_json FROM ${TABLE_CANVAS}
         WHERE cache_key = ? AND style = ? AND page_no = ? AND data_rev = ?`,
        [cacheKey, style, pageNo, rev]);
      try {
        if (!rs.goToNextRow()) {
          return null;
        }
        return PageCacheService.canvasFromJson(rs.getString(rs.getColumnIndex('canvas_json')), style);
      } finally {
        rs.close();
      }
    } catch (_e) {
      return null;
    }
  }

  private static canvasToJson(canvas: EuCanvas | SuCanvas, style: string): string {
    const rec: CanvasRec = new CanvasRec();
    rec.width = canvas.width;
    rec.height = canvas.height;
    rec.rootUid = canvas.rootBox === null ? '' : canvas.rootBox.node.uid;
    if (style === 'su') {
      const su: SuCanvas = canvas as SuCanvas;
      for (let i: number = 0; i < su.boxes.length; i = i + 1) {
        const b: SuBox = su.boxes[i];
        const br: CanvasBoxRec = new CanvasBoxRec();
        br.uid = b.node.uid;
        br.x = b.x;
        br.y = b.y;
        br.w = b.w;
        br.h = b.h;
        rec.boxes.push(br);
      }
    } else {
      const eu: EuCanvas = canvas as EuCanvas;
      for (let i: number = 0; i < eu.boxes.length; i = i + 1) {
        const b: EuBox = eu.boxes[i];
        const br: CanvasBoxRec = new CanvasBoxRec();
        br.uid = b.node.uid;
        br.x = b.x;
        br.y = b.y;
        br.w = b.w;
        br.h = b.h;
        br.centerY = b.centerY;
        rec.boxes.push(br);
      }
    }
    rec.lines = canvas.lines;
    return JSON.stringify(rec);
  }

  private static canvasFromJson(json: string, style: string): EuCanvas | SuCanvas | null {
    const rec: CanvasRec = JSON.parse(json) as CanvasRec;
    const nodes: Map<string, PersonNode> = PaginationService.nodeIndexOfCurrentBook();
    if (style === 'su') {
      const su: SuCanvas = new SuCanvas();
      su.width = rec.width;
      su.height = rec.height;
      for (let i: number = 0; i < rec.boxes.length; i = i + 1) {
        const br: CanvasBoxRec = rec.boxes[i];
        const node: PersonNode | undefined = nodes.get(br.uid);
        if (node === undefined) {
          return null;
        }
        const b: SuBox = new SuBox();
        b.node = node;
        b.x = br.x;
        b.y = br.y;
        b.w = br.w;
        b.h = br.h;
        su.boxes.push(b);
        if (rec.rootUid.length > 0 && rec.rootUid === br.uid) {
          su.rootBox = b;
        }
      }
      su.lines = rec.lines;
      return su;
    }
    const eu: EuCanvas = new EuCanvas();
    eu.width = rec.width;
    eu.height = rec.height;
    for (let i: number = 0; i < rec.boxes.length; i = i + 1) {
      const br: CanvasBoxRec = rec.boxes[i];
      const node: PersonNode | undefined = nodes.get(br.uid);
      if (node === undefined) {
        return null;
      }
      const b: EuBox = new EuBox();
      b.node = node;
      b.x = br.x;
      b.y = br.y;
      b.w = br.w;
      b.h = br.h;
      b.centerY = br.centerY;
      eu.boxes.push(b);
      if (rec.rootUid.length > 0 && rec.rootUid === br.uid) {
        eu.rootBox = b;
      }
    }
    eu.lines = rec.lines;
    return eu;
  }

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
    if (await this.isFresh(cacheKey, rev)) {
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

  private static parseStringArray(text: string): string[] {
    if (text.length === 0) {
      return [];
    }
    return JSON.parse(text) as string[];
  }

  private static parseUidSet(text: string): Set<string> {
    const out: Set<string> = new Set<string>();
    if (text.length === 0) {
      return out;
    }
    const arr: string[] = JSON.parse(text) as string[];
    for (let i: number = 0; i < arr.length; i = i + 1) {
      out.add(arr[i]);
    }
    return out;
  }
}