import { relationalStore } from '@kit.ArkData';
import { PersonNode } from 'common_base';
import { GenealogyService } from '../GenealogyService';
import { PagePlan, PaginationService, PrintBook } from '../PaginationService';
import { PagePlanRowMapper } from '../PagePlanRowMapper';
import {
  CACHE_KEEP_KEYS, WRITE_BATCH, TABLE_BRANCH, TABLE_CANVAS, TABLE_INDEX, TABLE_META,
  TABLE_PLAN, TABLE_VOLUME
} from './PageCacheSchema';

/** meta 表行 */
class CacheMeta {
  rev: number = -1;
  pages: number = 0;
}

/** 分页缓存读操作：只做查询与行解析，不持有业务状态 */
export class PageCacheReader {
  /** 缓存是否与当前数据版本一致 */
  static async isFresh(store: relationalStore.RdbStore | null, cacheKey: string,
    rev: number): Promise<boolean> {
    if (store === null) {
      return false;
    }
    const rs: relationalStore.ResultSet = await store.querySql(
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

  /** 读取 meta；不存在返回 null */
  static async readMeta(store: relationalStore.RdbStore | null,
    cacheKey: string): Promise<CacheMeta | null> {
    if (store === null) {
      return null;
    }
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT data_rev, pages FROM ${TABLE_META} WHERE cache_key = ?`, [cacheKey]);
    try {
      if (!rs.goToNextRow()) {
        return null;
      }
      const meta: CacheMeta = new CacheMeta();
      meta.rev = rs.getLong(rs.getColumnIndex('data_rev'));
      meta.pages = rs.getLong(rs.getColumnIndex('pages'));
      return meta;
    } finally {
      rs.close();
    }
  }

  /** 读取整本页计划；没有数据返回 null */
  static async readPlans(store: relationalStore.RdbStore | null,
    cacheKey: string): Promise<PagePlan[] | null> {
    if (store === null) {
      return null;
    }
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${TABLE_PLAN} WHERE cache_key = ? ORDER BY global_page`, [cacheKey]);
    const plans: PagePlan[] = [];
    try {
      while (rs.goToNextRow()) {
        plans.push(PagePlanRowMapper.parse(rs));
      }
    } finally {
      rs.close();
    }
    return plans.length > 0 ? plans : null;
  }

  /** uid → 页码 */
  static async readIndexMap(store: relationalStore.RdbStore | null,
    cacheKey: string): Promise<Map<string, number>> {
    const out: Map<string, number> = new Map<string, number>();
    if (store === null) {
      return out;
    }
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT uid, page_no FROM ${TABLE_INDEX} WHERE cache_key = ?`, [cacheKey]);
    try {
      while (rs.goToNextRow()) {
        out.set(rs.getString(rs.getColumnIndex('uid')),
          rs.getLong(rs.getColumnIndex('page_no')));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  /** 上次保存的房支 hash */
  static async readBranchHashes(store: relationalStore.RdbStore | null,
    cacheKey: string): Promise<Map<string, string>> {
    const out: Map<string, string> = new Map<string, string>();
    if (store === null) {
      return out;
    }
    const rs: relationalStore.ResultSet = await store.querySql(
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

  /** 读取人物位置引用（卷/页/全局页/pageRoot） */
  static async readRef(store: relationalStore.RdbStore | null, cacheKey: string,
    uid: string): Promise<relationalStore.ResultSet | null> {
    if (store === null) {
      return null;
    }
    return await store.querySql(
      `SELECT volume, page_no, global_page, page_root_uid FROM ${TABLE_INDEX}
       WHERE cache_key = ? AND uid = ?`, [cacheKey, uid]);
  }

  /** 读取一页布局 JSON；版本不匹配返回 null */
  static async readCanvasJson(store: relationalStore.RdbStore | null, cacheKey: string,
    style: string, pageNo: number, rev: number): Promise<string | null> {
    if (store === null) {
      return null;
    }
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT canvas_json FROM ${TABLE_CANVAS}
       WHERE cache_key = ? AND style = ? AND page_no = ? AND data_rev = ?`,
      [cacheKey, style, pageNo, rev]);
    try {
      if (!rs.goToNextRow()) {
        return null;
      }
      return rs.getString(rs.getColumnIndex('canvas_json'));
    } finally {
      rs.close();
    }
  }
}

/** 分页缓存写操作 */
export class PageCacheWriter {
  /** 写入整本分页缓存（meta/plan/index/volume/branch） */
  static async saveBook(store: relationalStore.RdbStore, cacheKey: string, rev: number,
    book: PrintBook, volPages: number): Promise<void> {
    await store.executeSql(`DELETE FROM ${TABLE_META} WHERE cache_key = ?`, [cacheKey]);
    await store.executeSql(`DELETE FROM ${TABLE_PLAN} WHERE cache_key = ?`, [cacheKey]);
    await store.executeSql(`DELETE FROM ${TABLE_INDEX} WHERE cache_key = ?`, [cacheKey]);
    await store.executeSql(`DELETE FROM ${TABLE_VOLUME} WHERE cache_key = ?`, [cacheKey]);
    await store.executeSql(`DELETE FROM ${TABLE_BRANCH} WHERE cache_key = ?`, [cacheKey]);
    // 只清理旧数据版本的布局缓存；同版本的 canvas 在导出过程中写入，不能删
    await store.executeSql(`DELETE FROM ${TABLE_CANVAS} WHERE cache_key = ? AND data_rev != ?`,
      [cacheKey, rev]);

    const meta: relationalStore.ValuesBucket = {
      'cache_key': cacheKey,
      'data_rev': rev,
      'pages': book.pages.length,
      'volumes': Math.max(1, Math.ceil(book.pages.length / volPages)),
      'created_at': Date.now()
    };
    await store.insert(TABLE_META, meta);

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
      planBatch.push(PagePlanRowMapper.toRow(cacheKey, page, globalPage, volume,
        i % volPages + 1, uids));

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
        await store.batchInsert(TABLE_PLAN, planBatch);
        planBatch = [];
      }
      if (indexBatch.length >= WRITE_BATCH) {
        await store.batchInsert(TABLE_INDEX, indexBatch);
        indexBatch = [];
      }
    }
    if (planBatch.length > 0) {
      await store.batchInsert(TABLE_PLAN, planBatch);
    }
    if (indexBatch.length > 0) {
      await store.batchInsert(TABLE_INDEX, indexBatch);
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
      await store.insert(TABLE_VOLUME, vb);
    }

    const branchRows: relationalStore.ValuesBucket[] = [];
    branchStart.forEach((start: number, branchId: string): void => {
      const end: number | undefined = branchEnd.get(branchId);
      const row: relationalStore.ValuesBucket = {
        'cache_key': cacheKey,
        'branch_id': branchId,
        'branch_hash': BranchHasher.hash(branchId),
        'start_page': start,
        'end_page': end === undefined ? start : end
      };
      branchRows.push(row);
    });
    if (branchRows.length > 0) {
      await store.batchInsert(TABLE_BRANCH, branchRows);
    }
  }

  /** 写一页布局缓存（PSS 由调用方判断） */
  static async writeCanvas(store: relationalStore.RdbStore, cacheKey: string, style: string,
    pageNo: number, rev: number, json: string): Promise<void> {
    await store.executeSql(
      `INSERT OR REPLACE INTO ${TABLE_CANVAS}(cache_key, style, page_no, data_rev, canvas_json)
       VALUES(?, ?, ?, ?, ?)`, [cacheKey, style, pageNo, rev, json]);
  }
}

/** 缓存清理 */
export class PageCacheKeeper {
  /** 只保留最近 N 个缓存键，删除其余所有表数据（P2） */
  static async cleanupOldKeys(store: relationalStore.RdbStore | null): Promise<void> {
    if (store === null) {
      return;
    }
    const rs: relationalStore.ResultSet = await store.querySql(
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
      await store.executeSql(`DELETE FROM ${TABLE_META} WHERE cache_key = ?`, [k]);
      await store.executeSql(`DELETE FROM ${TABLE_PLAN} WHERE cache_key = ?`, [k]);
      await store.executeSql(`DELETE FROM ${TABLE_INDEX} WHERE cache_key = ?`, [k]);
      await store.executeSql(`DELETE FROM ${TABLE_VOLUME} WHERE cache_key = ?`, [k]);
      await store.executeSql(`DELETE FROM ${TABLE_BRANCH} WHERE cache_key = ?`, [k]);
      await store.executeSql(`DELETE FROM ${TABLE_CANVAS} WHERE cache_key = ?`, [k]);
    }
  }
}

/** 房支 hash：整房人物、关系、更新时间与排序键的聚合指纹（FNV-1a） */
export class BranchHasher {
  static hash(branchId: string): string {
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
}
