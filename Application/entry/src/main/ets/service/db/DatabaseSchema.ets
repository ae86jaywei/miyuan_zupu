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
}
