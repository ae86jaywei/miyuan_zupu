import { relationalStore } from '@kit.ArkData';
import { GenealogyService } from '../GenealogyService';

/** 缓存库文件与表名 */
export const PAGE_DB_NAME: string = 'page_cache.db';
export const TABLE_META: string = 'page_cache_meta';
export const TABLE_PLAN: string = 'page_cache_plan';
export const TABLE_INDEX: string = 'page_cache_index';
export const TABLE_VOLUME: string = 'page_cache_volume';
export const TABLE_BRANCH: string = 'page_cache_branch';
export const TABLE_CANVAS: string = 'page_cache_canvas';

/** 缓存结构版本：排序规则、分页算法、纸张规格变化时必须 +1（6 = 子女续页按父卡聚合、承接页改指上一页） */
export const CACHE_VERSION: number = 6;
/** 写入缓存的批量大小 */
export const WRITE_BATCH: number = 50;
/** 导出缓存默认分卷页数（与 PagedPdfExportService 保持一致） */
export const CACHE_VOLUME_PAGES: number = 30;
/** 只保留最近 N 个族谱/谱式缓存，避免缓存库无限增长 */
export const CACHE_KEEP_KEYS: number = 3;
/** 布局缓存写入内存门槛：PSS 超限时只读不写，避免导出峰值叠加 */
export const CANVAS_WRITE_MAX_PSS_KB: number = 700 * 1024;

/** 人物位置引用：第几卷、第几页、全局页 */
export class PageRef {
  volume: number = 1;
  pageNo: number = 1;
  globalPage: number = 1;
  pageRootUid: string = '';
  branchName: string = '';
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

/** 缓存库建表：结构变化时同步调整 CACHE_VERSION */
export class PageCacheSchema {
  static async createTables(store: relationalStore.RdbStore): Promise<void> {
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
  }
}
