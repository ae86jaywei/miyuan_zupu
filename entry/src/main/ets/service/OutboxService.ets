import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = '[Genealogy][Outbox]';
const TABLE_OUTBOX: string = 'outbox';

/**
 * 待上传变更（outbox）。
 *
 * 端侧 RDB 是唯一真相源（方案 §四 原则 1），断网时写操作先落本地并在此排队，
 * 网络恢复后由 FamilySyncService 逐条上传（提交审核 / 直写 / 谱元信息）。
 *
 * 字段：
 *  - op        ADD / UPDATE / DELETE
 *  - scope     'person'（单人）/ 'book'（谱元信息）
 *  - target    uid 或 bookKey
 *  - payload   变更内容 JSON（字段级 diff，见 PatchUtil.buildPersonPatch）
 *  - base_rev  提交时的家族 rev 基线（云侧 baseRev 过期判定用）
 *  - state     PENDING / DONE / FAILED
 */
export class OutboxItem {
  id: number = 0;
  familyId: string = '';
  op: string = '';
  scope: string = 'person';
  target: string = '';
  targetName: string = '';
  payload: string = '';
  baseRev: number = 0;
  createdAt: number = 0;
  state: string = 'PENDING';
  error: string = '';
  retryCount: number = 0;
}

export class OutboxState {
  static readonly PENDING: string = 'PENDING';
  static readonly DONE: string = 'DONE';
  static readonly FAILED: string = 'FAILED';
}

export class OutboxService {
  private static instance: OutboxService | null = null;

  static getInstance(): OutboxService {
    if (OutboxService.instance === null) {
      OutboxService.instance = new OutboxService();
    }
    return OutboxService.instance;
  }

  /** 建表（幂等，在 GenealogyService.init 中调用） */
  async ensureTable(store: relationalStore.RdbStore): Promise<void> {
    await store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_OUTBOX} (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      family_id TEXT NOT NULL,
      op TEXT,
      scope TEXT,
      target TEXT,
      target_name TEXT,
      payload TEXT,
      base_rev INTEGER,
      created_at INTEGER,
      state TEXT DEFAULT 'PENDING',
      error TEXT,
      retry_count INTEGER DEFAULT 0
    )`);
    await store.executeSql(`CREATE INDEX IF NOT EXISTS idx_outbox_family ON ${TABLE_OUTBOX}(family_id, state)`);
  }

  /** 入队一条变更 */
  async enqueue(store: relationalStore.RdbStore, item: OutboxItem): Promise<number> {
    const values: relationalStore.ValuesBucket = {
      'family_id': item.familyId,
      'op': item.op,
      'scope': item.scope,
      'target': item.target,
      'target_name': item.targetName,
      'payload': item.payload,
      'base_rev': item.baseRev,
      'created_at': item.createdAt > 0 ? item.createdAt : Date.now(),
      'state': OutboxState.PENDING,
      'error': '',
      'retry_count': item.retryCount
    };
    const id: number = await store.insert(TABLE_OUTBOX, values);
    hilog.info(0x0000, TAG, 'enqueue %{public}s %{public}s/%{public}s', item.op, item.familyId, item.target);
    return id;
  }

  /** 读取某家族的待上传变更（按创建顺序） */
  async pending(store: relationalStore.RdbStore, familyId: string, limit: number = 200): Promise<OutboxItem[]> {
    return this.query(store,
      `SELECT * FROM ${TABLE_OUTBOX} WHERE family_id = ? AND state = 'PENDING' ORDER BY id ASC LIMIT ${limit}`,
      [familyId]);
  }

  /** 统计待上传条数（首页角标用） */
  async pendingCount(store: relationalStore.RdbStore, familyId: string): Promise<number> {
    if (familyId.length === 0) {
      return 0;
    }
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) AS c FROM ${TABLE_OUTBOX} WHERE family_id = ? AND state = 'PENDING'`, [familyId]);
    let n: number = 0;
    try {
      if (rs.goToFirstRow()) {
        n = rs.getLong(rs.getColumnIndex('c'));
      }
    } finally {
      rs.close();
    }
    return n;
  }

  /** 最近一次错误的可读信息（同步状态提示用） */
  async lastError(store: relationalStore.RdbStore, familyId: string): Promise<string> {
    const list: OutboxItem[] = await this.query(store,
      `SELECT * FROM ${TABLE_OUTBOX} WHERE family_id = ? AND state = 'FAILED' AND error <> '' ORDER BY id DESC LIMIT 1`,
      [familyId]);
    return list.length > 0 ? list[0].error : '';
  }

  /** 标记完成 / 失败 */
  async markDone(store: relationalStore.RdbStore, id: number): Promise<void> {
    await store.executeSql(`UPDATE ${TABLE_OUTBOX} SET state = 'DONE' WHERE id = ?`, [id]);
  }

  async markFailed(store: relationalStore.RdbStore, id: number, error: string, permanent: boolean): Promise<void> {
    if (permanent) {
      await store.executeSql(
        `UPDATE ${TABLE_OUTBOX} SET state = 'FAILED', error = ?, retry_count = retry_count + 1 WHERE id = ?`,
        [error, id]);
    } else {
      await store.executeSql(
        `UPDATE ${TABLE_OUTBOX} SET error = ?, retry_count = retry_count + 1 WHERE id = ?`,
        [error, id]);
    }
  }

  /** 失败项重新入队（用户点「重试」时） */
  async retryFailed(store: relationalStore.RdbStore, familyId: string): Promise<void> {
    await store.executeSql(
      `UPDATE ${TABLE_OUTBOX} SET state = 'PENDING', error = '', retry_count = 0 WHERE family_id = ? AND state = 'FAILED'`,
      [familyId]);
  }

  /** 清理已完成的旧记录（保留最近 200 条便于排查） */
  async compact(store: relationalStore.RdbStore, familyId: string): Promise<void> {
    await store.executeSql(`DELETE FROM ${TABLE_OUTBOX} WHERE family_id = ? AND state = 'DONE' AND id NOT IN
      (SELECT id FROM ${TABLE_OUTBOX} WHERE family_id = ? AND state = 'DONE' ORDER BY id DESC LIMIT 200)`,
      [familyId, familyId]);
  }

  private async query(store: relationalStore.RdbStore, sql: string,
    args: relationalStore.ValueType[]): Promise<OutboxItem[]> {
    const list: OutboxItem[] = [];
    const rs: relationalStore.ResultSet = await store.querySql(sql, args);
    try {
      while (rs.goToNextRow()) {
        const item: OutboxItem = new OutboxItem();
        item.id = rs.getLong(rs.getColumnIndex('id'));
        item.familyId = readText(rs, 'family_id');
        item.op = readText(rs, 'op');
        item.scope = readText(rs, 'scope');
        item.target = readText(rs, 'target');
        item.targetName = readText(rs, 'target_name');
        item.payload = readText(rs, 'payload');
        item.baseRev = rs.getLong(rs.getColumnIndex('base_rev'));
        item.createdAt = rs.getLong(rs.getColumnIndex('created_at'));
        item.state = readText(rs, 'state');
        item.error = readText(rs, 'error');
        item.retryCount = rs.getLong(rs.getColumnIndex('retry_count'));
        list.push(item);
      }
    } finally {
      rs.close();
    }
    return list;
  }
}

function readText(rs: relationalStore.ResultSet, column: string): string {
  const idx: number = rs.getColumnIndex(column);
  if (idx < 0) {
    return '';
  }
  const v: string = rs.getString(idx);
  return v === null || v === undefined ? '' : v;
}
