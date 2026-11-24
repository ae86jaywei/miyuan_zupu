import { relationalStore } from '@kit.ArkData';
import { DbColumnDef, PERSON_DB_COLUMNS } from 'common_base';

/** 表名：人物 */
export const TABLE_PERSON: string = 'person';
/** 表名：族谱元信息 */
export const TABLE_BOOK: string = 'genealogy';
/** 表名：配偶关系 */
export const TABLE_SPOUSE: string = 'person_spouse';
/** 表名：应用元数据 */
export const TABLE_META: string = 'app_meta';
/** 元数据键：唯一ID 性别前缀互换迁移是否已完成（老库只需执行一次） */
export const META_UID_PREFIX_SWAPPED: string = 'uid_gender_prefix_swapped_v1';
/** 本地墓葬缓存表（由 GraveService 建表，迁移时按需判断是否存在） */
const TABLE_GRAVE: string = 'grave_location';
/** 协作待上传变更表（由 OutboxService 建表，迁移时按需判断是否存在） */
const TABLE_OUTBOX: string = 'outbox';

/** 已删除编号记录（仅迁移黑名单时使用，结构同 GenealogyService 中的 RetiredUid） */
class RetiredUidEntry {
  uid: string = '';
  name: string = '';
  deletedAt: number = 0;
}

/**
 * 数据库结构与旧库迁移。
 * 只负责建表、补列、迁移，不持有业务状态，便于独立测试。
 */
export class DatabaseSchema {
  /** 建表并补齐旧库缺失的列（幂等） */
  static async createTables(store: relationalStore.RdbStore): Promise<void> {
    await store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_PERSON} (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL DEFAULT 0,
      uid TEXT NOT NULL,
      generation INTEGER,
      name TEXT,
      courtesy_name TEXT,
      art_name TEXT,
      alias TEXT,
      gender TEXT,
      generation_char TEXT,
      life_status TEXT,
      child_status TEXT,
      child_mark TEXT,
      child_mark_target TEXT,
      child_mark_source TEXT,
      child_mark_seq INTEGER,
      childless INTEGER,
      birth_date TEXT,
      birth_calendar TEXT,
      death_date TEXT,
      death_calendar TEXT,
      birth_place TEXT,
      residence TEXT,
      father_id TEXT,
      father_name TEXT,
      father_life_status TEXT,
      mother_id TEXT,
      mother_name TEXT,
      mother_life_status TEXT,
      spouse_id TEXT,
      marriage_status TEXT,
      spouse_family TEXT,
      rank TEXT,
      adoption TEXT,
      education TEXT,
      occupation TEXT,
      biography TEXT,
      grave_info TEXT,
      grave_lng REAL,
      grave_lat REAL,
      grave_altitude REAL,
      phone TEXT,
      wechat TEXT,
      avatar TEXT,
      videos TEXT,
      photos TEXT,
      created_at INTEGER,
      updated_at INTEGER
    )`);
    // 独立配偶关系表：支持一夫多妻（元配/继室/妾），按 ord 排序
    // 多族谱下以 (book_id, uid, spouse_uid) 为主键，避免不同族谱同名人物互相覆盖
    await store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_SPOUSE} (
      book_id INTEGER NOT NULL DEFAULT 0,
      uid TEXT NOT NULL,
      spouse_uid TEXT NOT NULL,
      relation TEXT,
      level TEXT,
      ord INTEGER,
      PRIMARY KEY (book_id, uid, spouse_uid)
    )`);
    // 兼容旧库：字段清单统一由 FieldRegistry 维护，新增字段只改注册表即可自动补列
    for (let i: number = 0; i < PERSON_DB_COLUMNS.length; i = i + 1) {
      const col: DbColumnDef = PERSON_DB_COLUMNS[i];
      await DatabaseSchema.ensureColumn(store, TABLE_PERSON, col.column, col.type);
    }
    await DatabaseSchema.ensureColumn(store, TABLE_SPOUSE, 'level', 'TEXT');
    // 同步回放按 book_id + uid 逐条定位族人。没有索引时每条 SQL 都是全表扫描，
    // 数万人的协作谱会退化成 O(n²)（实测 6 万人同步约 10 分钟）。
    await store.executeSql(`CREATE INDEX IF NOT EXISTS idx_person_book_uid ON ${TABLE_PERSON}(book_id, uid)`);
    await store.executeSql(`CREATE INDEX IF NOT EXISTS idx_spouse_book_uid ON ${TABLE_SPOUSE}(book_id, uid)`);
    await store.executeSql(`CREATE INDEX IF NOT EXISTS idx_spouse_book_spouse ON ${TABLE_SPOUSE}(book_id, spouse_uid)`);
    await store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_BOOK} (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT,
      surname TEXT,
      hall_name TEXT,
      junwang TEXT,
      ancestor_name TEXT,
      generation_poem TEXT,
      preface TEXT,
      family_rules TEXT,
      editing_notes TEXT,
      cover_color TEXT,
      cover_pattern TEXT,
      created_at INTEGER,
      updated_at INTEGER
    )`);
    // 兼容旧库：族谱分支字段（分支谱记录母族谱与分支出自何人）
    await DatabaseSchema.ensureColumn(store, TABLE_BOOK, 'parent_book_id', 'INTEGER');
    await DatabaseSchema.ensureColumn(store, TABLE_BOOK, 'branch_root_uid', 'TEXT');
    // 分支谱上承元数据：母谱书名、母谱世代、上承人 uid/姓名
    await DatabaseSchema.ensureColumn(store, TABLE_BOOK, 'parent_book_title', 'TEXT');
    await DatabaseSchema.ensureColumn(store, TABLE_BOOK, 'parent_generation', 'INTEGER');
    await DatabaseSchema.ensureColumn(store, TABLE_BOOK, 'parent_uid', 'TEXT');
    await DatabaseSchema.ensureColumn(store, TABLE_BOOK, 'parent_name', 'TEXT');
    // 协作谱域（方案 §五.0 路线 A：1 部谱 = 1 个 familyId）
    await DatabaseSchema.ensureColumn(store, TABLE_BOOK, 'family_id', 'TEXT');
    await DatabaseSchema.ensureColumn(store, TABLE_BOOK, 'sync_mode', 'TEXT');
    await DatabaseSchema.ensureColumn(store, TABLE_BOOK, 'cloud_rev', 'INTEGER DEFAULT 0');
    await DatabaseSchema.ensureColumn(store, TABLE_BOOK, 'family_role', 'TEXT');
    // 应用元数据表：记录首次初始化标记，避免用户删除族谱后重启时重新写入演示数据
    await store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_META} (
      key TEXT PRIMARY KEY,
      value TEXT
    )`);
  }

  /** 表是否存在指定列 */
  static async hasColumn(store: relationalStore.RdbStore, table: string, column: string): Promise<boolean> {
    const rs: relationalStore.ResultSet = await store.querySql(`PRAGMA table_info(${table})`);
    let exists: boolean = false;
    try {
      const nameIndex: number = rs.getColumnIndex('name');
      while (rs.goToNextRow()) {
        if (rs.getString(nameIndex) === column) {
          exists = true;
          break;
        }
      }
    } finally {
      rs.close();
    }
    return exists;
  }

  /** 缺列时补列 */
  static async ensureColumn(store: relationalStore.RdbStore, table: string, column: string, type: string): Promise<void> {
    const exists: boolean = await DatabaseSchema.hasColumn(store, table, column);
    if (!exists) {
      await store.executeSql(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`);
    }
  }

  /**
   * 旧库迁移：配偶关系表原主键为 (uid, spouse_uid)，多族谱下会互相覆盖。
   * 缺少 book_id 时重建为 (book_id, uid, spouse_uid) 复合主键，旧数据归入当前族谱。
   */
  static async migrateSpouseBookColumn(store: relationalStore.RdbStore, currentBookId: number): Promise<void> {
    const exists: boolean = await DatabaseSchema.hasColumn(store, TABLE_SPOUSE, 'book_id');
    if (exists) {
      return;
    }
    await store.executeSql(`CREATE TABLE IF NOT EXISTS person_spouse_v2 (
      book_id INTEGER NOT NULL DEFAULT 0,
      uid TEXT NOT NULL,
      spouse_uid TEXT NOT NULL,
      relation TEXT,
      level TEXT,
      ord INTEGER,
      PRIMARY KEY (book_id, uid, spouse_uid)
    )`);
    await store.executeSql(`INSERT OR IGNORE INTO person_spouse_v2(book_id, uid, spouse_uid, relation, level, ord)
      SELECT ?, uid, spouse_uid, relation, level, ord FROM ${TABLE_SPOUSE}`, [currentBookId]);
    await store.executeSql(`DROP TABLE ${TABLE_SPOUSE}`);
    await store.executeSql(`ALTER TABLE person_spouse_v2 RENAME TO ${TABLE_SPOUSE}`);
  }

  /**
   * 旧库迁移：唯一ID 前缀由「女 M / 男 F」改为「男 M / 女 F」。
   * 互换 person.uid 并同步全部引用字段（父母、配偶、分支、墓葬缓存、已删除编号黑名单），
   * 待上传队列里的旧补丁仍带着旧 ID，直接清空避免回写云端。
   * 全表 UPDATE 只执行一次，用 app_meta 标记避免每次启动重复扫描。
   */
  static async migrateGenderUidPrefix(store: relationalStore.RdbStore): Promise<void> {
    if ((await DatabaseSchema.readMeta(store, META_UID_PREFIX_SWAPPED)) === '1') {
      return;
    }
    store.beginTransaction();
    try {
      // 1) 人员 uid：男 F→M、女 M→F。
      //    分两阶段先落到临时小写前缀，避免同一批互换时新值与尚未处理的行重名。
      await store.executeSql(`UPDATE ${TABLE_PERSON} SET uid =
        CASE WHEN SUBSTR(uid,1,1) = 'F' THEN 'm' ELSE 'f' END || SUBSTR(uid,2)
        WHERE LENGTH(uid) > 1 AND SUBSTR(uid,2,1) GLOB '[0-9]'
          AND ((gender = '男' AND SUBSTR(uid,1,1) = 'F') OR (gender = '女' AND SUBSTR(uid,1,1) = 'M'))`);
      await store.executeSql(`UPDATE ${TABLE_PERSON} SET uid =
        CASE WHEN SUBSTR(uid,1,1) = 'm' THEN 'M' ELSE 'F' END || SUBSTR(uid,2)
        WHERE LENGTH(uid) > 1 AND SUBSTR(uid,2,1) GLOB '[0-9]'
          AND ((gender = '男' AND SUBSTR(uid,1,1) = 'm') OR (gender = '女' AND SUBSTR(uid,1,1) = 'f'))`);
      // 2) 人员内部引用
      await DatabaseSchema.swapUidColumn(store, TABLE_PERSON, 'father_id');
      await DatabaseSchema.swapUidColumn(store, TABLE_PERSON, 'mother_id');
      await DatabaseSchema.swapUidColumn(store, TABLE_PERSON, 'spouse_id');
      // 3) 配偶关系表：两列同时交换，避免复合主键在中间态冲突
      await DatabaseSchema.swapSpouseRows(store);
      // 4) 族谱元信息里的分支引用
      await DatabaseSchema.swapUidColumn(store, TABLE_BOOK, 'branch_root_uid');
      await DatabaseSchema.swapUidColumn(store, TABLE_BOOK, 'parent_uid');
      // 5) 本地墓葬缓存
      if (await DatabaseSchema.tableExists(store, TABLE_GRAVE)) {
        await DatabaseSchema.swapUidColumn(store, TABLE_GRAVE, 'uid');
      }
      // 6) 已删除编号黑名单（JSON 数组）
      await DatabaseSchema.swapRetiredUids(store);
      // 7) 待上传队列：旧补丁的 target/payload 都是旧 ID，清空避免把旧编号写回云端
      if (await DatabaseSchema.tableExists(store, TABLE_OUTBOX)) {
        await store.executeSql(`DELETE FROM ${TABLE_OUTBOX}`);
      }
      await store.executeSql(`INSERT OR REPLACE INTO ${TABLE_META}(key, value) VALUES(?, '1')`,
        [META_UID_PREFIX_SWAPPED]);
      store.commit();
    } catch (e) {
      store.rollBack();
      throw new Error('唯一ID前缀迁移失败：' + (e as Error).message);
    }
  }

  /** 单列 uid 引用互换（两阶段，只处理「F/M + 数字」的标准编号） */
  private static async swapUidColumn(store: relationalStore.RdbStore, table: string, column: string): Promise<void> {
    await store.executeSql(`UPDATE ${table} SET ${column} =
      CASE WHEN SUBSTR(${column},1,1) = 'F' THEN 'm' ELSE 'f' END || SUBSTR(${column},2)
      WHERE ${column} IS NOT NULL AND LENGTH(${column}) > 1 AND SUBSTR(${column},2,1) GLOB '[0-9]'
        AND SUBSTR(${column},1,1) IN ('F','M')`);
    await store.executeSql(`UPDATE ${table} SET ${column} =
      CASE WHEN SUBSTR(${column},1,1) = 'm' THEN 'M' ELSE 'F' END || SUBSTR(${column},2)
      WHERE ${column} IS NOT NULL AND LENGTH(${column}) > 1 AND SUBSTR(${column},2,1) GLOB '[0-9]'
        AND SUBSTR(${column},1,1) IN ('m','f')`);
  }

  /** 配偶关系表两列互换（两阶段，避免 (book_id, uid, spouse_uid) 主键中间态冲突） */
  private static async swapSpouseRows(store: relationalStore.RdbStore): Promise<void> {
    // 两列各自独立判断，避免一行 spouse_uid 非标准时把 uid 也漏掉，造成引用悬空
    await store.executeSql(`UPDATE ${TABLE_SPOUSE} SET
      uid = CASE WHEN SUBSTR(uid,1,1) = 'F' THEN 'm' || SUBSTR(uid,2)
                 WHEN SUBSTR(uid,1,1) = 'M' THEN 'f' || SUBSTR(uid,2) ELSE uid END,
      spouse_uid = CASE WHEN SUBSTR(spouse_uid,1,1) = 'F' THEN 'm' || SUBSTR(spouse_uid,2)
                        WHEN SUBSTR(spouse_uid,1,1) = 'M' THEN 'f' || SUBSTR(spouse_uid,2) ELSE spouse_uid END
      WHERE (LENGTH(uid) > 1 AND SUBSTR(uid,2,1) GLOB '[0-9]' AND SUBSTR(uid,1,1) IN ('F','M'))
         OR (LENGTH(spouse_uid) > 1 AND SUBSTR(spouse_uid,2,1) GLOB '[0-9]' AND SUBSTR(spouse_uid,1,1) IN ('F','M'))`);
    await store.executeSql(`UPDATE ${TABLE_SPOUSE} SET
      uid = CASE WHEN SUBSTR(uid,1,1) = 'm' THEN 'M' || SUBSTR(uid,2)
                 WHEN SUBSTR(uid,1,1) = 'f' THEN 'F' || SUBSTR(uid,2) ELSE uid END,
      spouse_uid = CASE WHEN SUBSTR(spouse_uid,1,1) = 'm' THEN 'M' || SUBSTR(spouse_uid,2)
                        WHEN SUBSTR(spouse_uid,1,1) = 'f' THEN 'F' || SUBSTR(spouse_uid,2) ELSE spouse_uid END
      WHERE (LENGTH(uid) > 1 AND SUBSTR(uid,2,1) GLOB '[0-9]' AND SUBSTR(uid,1,1) IN ('m','f'))
         OR (LENGTH(spouse_uid) > 1 AND SUBSTR(spouse_uid,2,1) GLOB '[0-9]' AND SUBSTR(spouse_uid,1,1) IN ('m','f'))`);
  }

  /** 已删除编号黑名单：逐部族谱把 JSON 里的 uid 前缀互换 */
  private static async swapRetiredUids(store: relationalStore.RdbStore): Promise<void> {
    const keys: string[] = [];
    const values: string[] = [];
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT key, value FROM ${TABLE_META} WHERE key LIKE 'retired_uids_%'`);
    try {
      const keyIndex: number = rs.getColumnIndex('key');
      const valueIndex: number = rs.getColumnIndex('value');
      while (rs.goToNextRow()) {
        keys.push(rs.getString(keyIndex));
        const v: string = rs.getString(valueIndex);
        values.push(v === null ? '' : v);
      }
    } finally {
      rs.close();
    }
    for (let i: number = 0; i < keys.length; i++) {
      let list: RetiredUidEntry[] = [];
      try {
        list = JSON.parse(values[i]) as RetiredUidEntry[];
      } catch (err) {
        continue;
      }
      if (list === null || list === undefined) {
        continue;
      }
      let changed: boolean = false;
      for (let j: number = 0; j < list.length; j++) {
        const uid: string = list[j].uid === undefined ? '' : list[j].uid;
        const swapped: string = DatabaseSchema.swappedUid(uid);
        if (swapped !== uid) {
          list[j].uid = swapped;
          changed = true;
        }
      }
      if (changed) {
        await store.executeSql(`UPDATE ${TABLE_META} SET value = ? WHERE key = ?`,
          [JSON.stringify(list), keys[i]]);
      }
    }
  }

  /** 单个标准编号的前缀互换（F↔M），非标准编号原样返回 */
  private static swappedUid(uid: string): string {
    if (uid.length < 2 || !/^[0-9]+$/.test(uid.substring(1))) {
      return uid;
    }
    const head: string = uid.substring(0, 1);
    if (head === 'F') {
      return 'M' + uid.substring(1);
    }
    if (head === 'M') {
      return 'F' + uid.substring(1);
    }
    return uid;
  }

  /** 读取 app_meta */
  private static async readMeta(store: relationalStore.RdbStore, key: string): Promise<string> {
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT value FROM ${TABLE_META} WHERE key = ?`, [key]);
    let value: string = '';
    try {
      if (rs.goToFirstRow()) {
        const v: string = rs.getString(rs.getColumnIndex('value'));
        value = v === null ? '' : v;
      }
    } finally {
      rs.close();
    }
    return value;
  }

  /** 表是否存在（部分表按需创建，迁移前需判断） */
  private static async tableExists(store: relationalStore.RdbStore, table: string): Promise<boolean> {
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, [table]);
    let exists: boolean = false;
    try {
      exists = rs.goToFirstRow();
    } finally {
      rs.close();
    }
    return exists;
  }
}
