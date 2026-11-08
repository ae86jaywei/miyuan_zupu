import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Person, SpouseRelation, clonePerson, cloneSpouseRelation, copyPersonInto, createEmptyPerson, spouseRelationLevel } from '../model/Person';
import { Genealogy, createEmptyGenealogy } from '../model/Genealogy';
import { PersonNode } from '../model/PersonNode';
import { GenerationStat, GenealogyStats } from '../model/Stats';
import { IdGenerator } from '../util/IdGenerator';
import { parseYear } from '../util/DateUtil';
import { generationLabel } from '../model/Enums';
import { TreeBuilder } from './TreeBuilder';
import { SeedData } from './SeedData';
import { OutboxService } from './OutboxService';
import { FamilyService } from './FamilyService';
import { IntegrityService } from './IntegrityService';
import { IntegrityReport, IntegrityIssue } from '../model/Integrity';
import { ImportPlan, ImportOptions, ImportPlanner, ImportResult } from './ImportPlanner';
import { RelationGraph, RepairReport } from './RelationGraph';
import { buildPersonPatch } from '../util/PatchUtil';

const TAG: string = '[Genealogy][Service]';
const DB_NAME: string = 'genealogy.db';
const TABLE_PERSON: string = 'person';
const TABLE_BOOK: string = 'genealogy';
const TABLE_SPOUSE: string = 'person_spouse';
const TABLE_META: string = 'app_meta';
/** 元数据：是否已完成首次初始化（用于区分“首次启动”与“用户清空族谱”） */
const META_INITIALIZED: string = 'initialized';
/** 元数据：当前打开的族谱ID（0 表示无族谱） */
const META_CURRENT_BOOK: string = 'current_book_id';
/** 元数据前缀：某部族谱中已被删除、但编号仍需保留不再复用的族人 */
const META_RETIRED_PREFIX: string = 'retired_uids_';
/** 元数据：旧库配偶关系迁移是否已完成（迁移 SQL 是 O(n²)，只能在首次启动跑一次） */
const META_SPOUSE_MIGRATED: string = 'spouse_migrated_v1';
/**
 * 单次查询最多读取的行数。
 * 关系型数据库的 ResultSet 由默认 2MB 的共享内存块承载（行偏移表上限 16384 行），
 * 一次性查询数万行会触发 SharedBlock 分配失败（Alloc/AllocRow 报错）并在主线程反复回填，
 * 因此大表读取必须按主键分批进行。
 */
const QUERY_PAGE_SIZE: number = 1000;

/** 已删除人员的编号记录（用于防止新族人沿用旧编号） */
class RetiredUid {
  uid: string = '';
  name: string = '';
  deletedAt: number = 0;
}

/** 云端恢复时按族谱分组的人物数据 */
export class BookGroup {
  /** 云端族谱元信息（key 为云端族谱ID） */
  book: Genealogy = createEmptyGenealogy();
  /** 该族谱下的人物 */
  people: Person[] = [];
}

/** 从数据库读出的配偶关系行（用于组装双向关系） */
class SpouseEdge {
  uid: string = '';
  spouseUid: string = '';
  relation: string = '';
  level: string = '';
  ord: number = 1;
}

/**
 * 族谱数据服务（单例）。
 * 使用关系型数据库存储，启动时自动建表、写入演示数据。
 *
 * 对外统一以“全量人物数组 + 版本号”的方式发布状态，
 * 页面通过 GenealogyStore 订阅。
 */
export class GenealogyService {
  private static instance: GenealogyService | null = null;

  private store: relationalStore.RdbStore | null = null;
  private people: Person[] = [];
  private book: Genealogy = createEmptyGenealogy();
  /** 全部族谱元信息（支持多族谱管理） */
  private books: Genealogy[] = [];
  /** 当前打开的族谱ID（0 表示无族谱） */
  private currentBookId: number = 0;
  private peopleMap: Map<string, Person> = new Map<string, Person>();
  /** 当前族谱中已删除人员的编号（uid → 原姓名），新增人员时不得复用 */
  private retiredUids: Map<string, string> = new Map<string, string>();
  private roots: PersonNode[] = [];
  /** 编辑前快照（uid → Person），用于生成字段级 diff */
  private beforeSnapshots: Map<string, Person> = new Map<string, Person>();
  private version: number = 0;
  /** 全量统计缓存：概览页 build 内会多次调用 computeStats，8 万人单次需数百毫秒，按版本号复用 */
  private statsCache: GenealogyStats | null = null;
  private statsCacheVersion: number = -1;
  private ready: boolean = false;
  private initPromise: Promise<void> | null = null;

  static getInstance(): GenealogyService {
    if (GenealogyService.instance === null) {
      GenealogyService.instance = new GenealogyService();
    }
    return GenealogyService.instance;
  }

  isReady(): boolean {
    return this.ready;
  }

  getVersion(): number {
    return this.version;
  }

  /** 初始化数据库并加载数据（幂等） */
  init(context: common.Context): Promise<void> {
    if (this.initPromise !== null) {
      return this.initPromise;
    }
    this.initPromise = this.doInit(context);
    return this.initPromise;
  }

  private async doInit(context: common.Context): Promise<void> {
    // 初始化/重新加载期间不对外宣称就绪，避免同步等调用方读到半初始化状态
    this.ready = false;
    try {
      const cfg: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      this.store = await relationalStore.getRdbStore(context, cfg);
      await this.store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_PERSON} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL DEFAULT 0,
        uid TEXT NOT NULL,
        generation INTEGER,
        name TEXT,
        alias TEXT,
        gender TEXT,
        generation_char TEXT,
        life_status TEXT,
        child_status TEXT,
        birth_date TEXT,
        birth_calendar TEXT,
        death_date TEXT,
        death_calendar TEXT,
        birth_place TEXT,
        residence TEXT,
        father_id TEXT,
        mother_id TEXT,
        spouse_id TEXT,
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
      await this.store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_SPOUSE} (
        book_id INTEGER NOT NULL DEFAULT 0,
        uid TEXT NOT NULL,
        spouse_uid TEXT NOT NULL,
        relation TEXT,
        level TEXT,
        ord INTEGER,
        PRIMARY KEY (book_id, uid, spouse_uid)
      )`);
      // 兼容旧库：补充新增列（child_status / level / book_id）
      await this.ensureColumn(TABLE_PERSON, 'child_status', 'TEXT');
      // 协作同步所需列（方案 §七「本地 RDB」行）：
      //   rev        —— 本人物的云端修订号（0 表示尚未上云）
      //   base_rev   —— 最近一次同步到本地时的家族 rev 基线（冲突判定用）
      //   dirty      —— 本地有未上传修改
      //   deleted_at —— 墓碑时间：非 0 表示该人物已被删除（软删，不再物理删除）
      await this.ensureColumn(TABLE_PERSON, 'rev', 'INTEGER DEFAULT 0');
      await this.ensureColumn(TABLE_PERSON, 'base_rev', 'INTEGER DEFAULT 0');
      await this.ensureColumn(TABLE_PERSON, 'dirty', 'INTEGER DEFAULT 0');
      await this.ensureColumn(TABLE_PERSON, 'deleted_at', 'INTEGER DEFAULT 0');
      await this.ensureColumn(TABLE_SPOUSE, 'level', 'TEXT');
      await this.ensureColumn(TABLE_PERSON, 'book_id', 'INTEGER');
      await this.store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_BOOK} (
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
      await this.ensureColumn(TABLE_BOOK, 'parent_book_id', 'INTEGER');
      await this.ensureColumn(TABLE_BOOK, 'branch_root_uid', 'TEXT');
      // 协作谱域（方案 §五.0 路线 A：1 部谱 = 1 个 familyId）
      await this.ensureColumn(TABLE_BOOK, 'family_id', 'TEXT');
      await this.ensureColumn(TABLE_BOOK, 'sync_mode', 'TEXT');
      await this.ensureColumn(TABLE_BOOK, 'cloud_rev', 'INTEGER DEFAULT 0');
      await this.ensureColumn(TABLE_BOOK, 'family_role', 'TEXT');
      // 应用元数据表：记录首次初始化标记，避免用户删除族谱后重启时重新写入演示数据
      await this.store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_META} (
        key TEXT PRIMARY KEY,
        value TEXT
      )`);
      // 协作变更队列（断网可编辑：写操作先落本地并在此排队，方案 §四 原则 1）
      await OutboxService.getInstance().ensureTable(this.store);
      // 注意：ResultSet.rowCount 是“游标当前行号”（初始 -1），并非行数，
      // 必须真正游标读取一次才能拿到 COUNT(*) 的值。
      const count: number = await this.countRows();
      hilog.info(0x0000, TAG, 'existing rows=%{public}d', count);
      const initialized: boolean = (await this.getMeta(META_INITIALIZED)) === '1';
      if (!initialized) {
        // 仅首次初始化时写入演示数据；已有旧库（有族人）时只补标记，不重复写入
        const hasBook: boolean = await this.hasBookRow();
        if (!hasBook) {
          try {
            // 先建族谱元信息，拿到族谱ID后再写入演示族人（带 book_id）
            const rowId: number = await this.store.insert(TABLE_BOOK, this.bookValues(SeedData.defaultBook()));
            this.currentBookId = rowId;
            await this.setMeta(META_CURRENT_BOOK, rowId.toString());
            if (count === 0) {
              await this.insertSeed();
            }
          } catch (e) {
            const se = e as BusinessError;
            hilog.error(0x0000, TAG, 'seed failed %{public}d %{public}s', se.code, se.message);
          }
        }
        await this.setMeta(META_INITIALIZED, '1');
      }
      // 确定当前打开的族谱（用户可能已删除全部族谱）
      await this.ensureCurrentBook();
      // 旧库迁移：配偶关系表补 book_id 并重建复合主键
      await this.migrateSpouseBookColumn();
      // 旧人物的 book_id 归入当前族谱
      if (this.currentBookId > 0) {
        await this.store.executeSql(
          `UPDATE ${TABLE_PERSON} SET book_id = ? WHERE book_id IS NULL OR book_id = 0`,
          [this.currentBookId]);
      }
      await this.setMeta(META_CURRENT_BOOK, this.currentBookId.toString());
      // 旧数据迁移：把 person.spouse_id 单值转换成配偶关系行。
      // 这条 SQL 的 NOT EXISTS 对 4 万行逐行回扫配偶表，是 O(n²)，实测占用 69 秒；
      // 数据已经迁移完就不必每次启动重跑，用元数据标记只执行一次。
      if ((await this.getMeta(META_SPOUSE_MIGRATED)) !== '1') {
        await this.migrateSpouses();
        // 回填配偶关系等级（旧行 level 为空）
        await this.backfillSpouseLevels();
        await this.setMeta(META_SPOUSE_MIGRATED, '1');
      }
      await this.reload();
      this.ready = true;
      hilog.info(0x0000, TAG, 'ready, people=%{public}d', this.people.length);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'init failed %{public}d %{public}s', err.code, err.message);
      this.initPromise = null;
    }
  }

  /** 统计族谱人物条数（正确读取 COUNT(*) 结果） */
  private async countRows(): Promise<number> {
    if (this.store === null) {
      return 0;
    }
    const rs: relationalStore.ResultSet = await this.store.querySql(`SELECT COUNT(*) AS c FROM ${TABLE_PERSON}`);
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

  /** 读取应用元数据 */
  private async getMeta(key: string): Promise<string> {
    if (this.store === null) {
      return '';
    }
    const rs: relationalStore.ResultSet = await this.store.querySql(
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

  /** 写入应用元数据 */
  private async setMeta(key: string, value: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.executeSql(
      `INSERT OR REPLACE INTO ${TABLE_META}(key, value) VALUES(?, ?)`, [key, value]);
  }

  /** 是否存在族谱记录 */
  private async hasBookRow(): Promise<boolean> {
    if (this.store === null) {
      return false;
    }
    const rs: relationalStore.ResultSet = await this.store.querySql(
      `SELECT id FROM ${TABLE_BOOK} LIMIT 1`);
    let exists: boolean = false;
    try {
      exists = rs.goToFirstRow();
    } finally {
      rs.close();
    }
    return exists;
  }

  /** 读取全部族谱ID */
  private async listBookIds(): Promise<number[]> {
    const ids: number[] = [];
    if (this.store === null) {
      return ids;
    }
    const rs: relationalStore.ResultSet = await this.store.querySql(
      `SELECT id FROM ${TABLE_BOOK} ORDER BY id`);
    try {
      while (rs.goToNextRow()) {
        ids.push(rs.getLong(rs.getColumnIndex('id')));
      }
    } finally {
      rs.close();
    }
    return ids;
  }

  /** 根据元数据确定当前族谱；记录失效时回落到第一部族谱 */
  private async ensureCurrentBook(): Promise<void> {
    const ids: number[] = await this.listBookIds();
    if (ids.length === 0) {
      this.currentBookId = 0;
      return;
    }
    const saved: number = Number.parseInt(await this.getMeta(META_CURRENT_BOOK), 10);
    if (saved > 0 && ids.indexOf(saved) >= 0) {
      this.currentBookId = saved;
    } else {
      this.currentBookId = ids[0];
    }
  }

  /** 表是否存在指定列 */
  private async hasColumn(table: string, column: string): Promise<boolean> {
    if (this.store === null) {
      return false;
    }
    const rs: relationalStore.ResultSet = await this.store.querySql(`PRAGMA table_info(${table})`);
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

  /**
   * 旧库迁移：配偶关系表原主键为 (uid, spouse_uid)，多族谱下会互相覆盖。
   * 缺少 book_id 时重建为 (book_id, uid, spouse_uid) 复合主键，旧数据归入当前族谱。
   */
  private async migrateSpouseBookColumn(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const exists: boolean = await this.hasColumn(TABLE_SPOUSE, 'book_id');
    if (exists) {
      return;
    }
    await this.store.executeSql(`CREATE TABLE IF NOT EXISTS person_spouse_v2 (
      book_id INTEGER NOT NULL DEFAULT 0,
      uid TEXT NOT NULL,
      spouse_uid TEXT NOT NULL,
      relation TEXT,
      level TEXT,
      ord INTEGER,
      PRIMARY KEY (book_id, uid, spouse_uid)
    )`);
    await this.store.executeSql(`INSERT OR IGNORE INTO person_spouse_v2(book_id, uid, spouse_uid, relation, level, ord)
      SELECT ?, uid, spouse_uid, relation, level, ord FROM ${TABLE_SPOUSE}`, [this.currentBookId]);
    await this.store.executeSql(`DROP TABLE ${TABLE_SPOUSE}`);
    await this.store.executeSql(`ALTER TABLE person_spouse_v2 RENAME TO ${TABLE_SPOUSE}`);
  }

  // ---------------------------------------------------------------- 查询

  getPeople(): Person[] {
    return this.people;
  }

  /** 返回副本，供编辑页使用 */
  getPeopleCopy(): Person[] {
    return this.people.map((p: Person): Person => clonePerson(p));
  }

  getPerson(uid: string): Person | null {
    const p: Person | undefined = this.peopleMap.get(uid.trim().toUpperCase());
    return p === undefined ? null : p;
  }

  getRoots(): PersonNode[] {
    return this.roots;
  }

  getBook(): Genealogy {
    return this.book;
  }

  /** 当前族谱已删除人员的编号表（uid → 原姓名） */
  getRetiredMap(): Map<string, string> {
    return this.retiredUids;
  }

  /** 查询某编号是否曾用于已删除族人，返回原姓名；未使用过返回空串 */
  retiredNameOf(uid: string): string {
    const name: string | undefined = this.retiredUids.get(uid.trim().toUpperCase());
    return name === undefined ? '' : name;
  }

  /**
   * 生成新编号：跳过当前族人与已删除族人使用过的编号，避免同一ID先后代表两个人，
   * 导致父子/配偶关系指向错误对象。
   */
  nextUid(gender: string, extra?: Set<string>): string {
    const reserved: Set<string> = new Set<string>();
    this.retiredUids.forEach((name: string, uid: string): void => {
      reserved.add(uid);
    });
    if (extra !== undefined) {
      extra.forEach((uid: string): void => {
        reserved.add(uid);
      });
    }
    return IdGenerator.next(this.people, gender, reserved);
  }

  /** 当前族谱的数据一致性体检（重复ID、关系悬空、世代/性别/日期错位、编号复用） */
  checkIntegrity(): IntegrityReport {
    const report: IntegrityReport = IntegrityService.check(this.people, this.book.title);
    report.merge(IntegrityService.reused(this.people, this.retiredUids));
    report.merge(IntegrityService.reusedReferences(this.people, this.retiredUids));
    return report;
  }

  /** 导入合并前的综合体检 */
  checkImport(list: Person[]): IntegrityReport {
    return IntegrityService.incoming(list, this.people, this.retiredUids);
  }

  /** 读取某部族谱的已删除编号表 */
  private async loadRetired(bookId: number): Promise<Map<string, string>> {
    const out: Map<string, string> = new Map<string, string>();
    if (bookId <= 0) {
      return out;
    }
    const text: string = await this.getMeta(META_RETIRED_PREFIX + bookId.toString());
    if (text.length === 0) {
      return out;
    }
    let list: RetiredUid[] = [];
    try {
      list = JSON.parse(text) as RetiredUid[];
    } catch (err) {
      hilog.warn(0x0000, TAG, 'parse retired uid failed');
      return out;
    }
    if (list === null || list === undefined) {
      return out;
    }
    for (let i: number = 0; i < list.length; i++) {
      const uid: string = list[i].uid === undefined ? '' : list[i].uid.trim().toUpperCase();
      if (uid.length > 0 && out.get(uid) === undefined) {
        out.set(uid, list[i].name === undefined ? '' : list[i].name);
      }
    }
    return out;
  }

  /** 记录被删除人员的编号；首次记录后不再覆盖姓名（保留最初使用该编号的族人） */
  private async recordRetired(uid: string, name: string): Promise<void> {
    const u: string = uid.trim().toUpperCase();
    if (this.currentBookId <= 0 || u.length === 0) {
      return;
    }
    const key: string = META_RETIRED_PREFIX + this.currentBookId.toString();
    const text: string = await this.getMeta(key);
    let list: RetiredUid[] = [];
    if (text.length > 0) {
      try {
        list = JSON.parse(text) as RetiredUid[];
      } catch (err) {
        list = [];
      }
    }
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].uid !== undefined && list[i].uid.trim().toUpperCase() === u) {
        return;
      }
    }
    const item: RetiredUid = new RetiredUid();
    item.uid = u;
    item.name = name;
    item.deletedAt = Date.now();
    list.push(item);
    if (list.length > 5000) {
      list = list.slice(list.length - 5000);
    }
    await this.setMeta(key, JSON.stringify(list));
    this.retiredUids.set(u, name);
  }

  /** 清空某部族谱的已删除编号表（恢复备份 / 全量替换后历史不再可信） */
  private async clearRetired(bookId: number): Promise<void> {
    if (bookId <= 0) {
      return;
    }
    await this.setMeta(META_RETIRED_PREFIX + bookId.toString(), '[]');
    this.retiredUids.clear();
  }

  /** 全部族谱（多族谱管理） */
  getBooks(): Genealogy[] {
    return this.books;
  }

  /** 当前打开的族谱ID（0 表示无族谱） */
  getCurrentBookId(): number {
    return this.currentBookId;
  }

  /** 当前是否存在族谱（用户可删除后处于“无族谱”状态） */
  hasBook(): boolean {
    return this.book.key > 0;
  }

  /** 读取指定族谱的全部人物（含配偶关系），用于云端分族谱备份 */
  async getPeopleOf(bookId: number): Promise<Person[]> {
    if (bookId <= 0) {
      return [];
    }
    const list: Person[] = await this.queryPeople(bookId);
    await this.attachSpouses(bookId, list);
    return list;
  }

  /** 模糊搜索：谱名 / 曾用名 / 唯一ID / 辈分字 / 出生地 / 职业 */
  search(keyword: string): Person[] {
    const k: string = keyword.trim().toLowerCase();
    if (k.length === 0) {
      return this.people;
    }
    return this.people.filter((p: Person): boolean => {
      return p.name.toLowerCase().indexOf(k) >= 0
        || p.alias.toLowerCase().indexOf(k) >= 0
        || p.uid.toLowerCase().indexOf(k) >= 0
        || p.generationChar.toLowerCase().indexOf(k) >= 0
        || p.birthPlace.toLowerCase().indexOf(k) >= 0
        || p.residence.toLowerCase().indexOf(k) >= 0
        || p.occupation.toLowerCase().indexOf(k) >= 0;
    });
  }

  /** 子女 */
  childrenOf(uid: string): Person[] {
    const u: string = uid.trim().toUpperCase();
    return this.people.filter((p: Person): boolean => {
      return p.fatherId.trim().toUpperCase() === u || p.motherId.trim().toUpperCase() === u;
    });
  }

  /** 某人与指定配偶共同生育的子女（父母双方均匹配） */
  childrenWithSpouse(uid: string, spouseUid: string): Person[] {
    const a: string = uid.trim().toUpperCase();
    const b: string = spouseUid.trim().toUpperCase();
    if (a.length === 0 || b.length === 0) {
      return [];
    }
    return this.people.filter((p: Person): boolean => {
      const f: string = p.fatherId.trim().toUpperCase();
      const m: string = p.motherId.trim().toUpperCase();
      return (f === a && m === b) || (f === b && m === a);
    });
  }

  /** 兄弟姊妹（不含本人），按排行排序 */
  siblingsOf(uid: string): Person[] {
    const p: Person | null = this.getPerson(uid);
    if (p === null) {
      return [];
    }
    const u: string = p.uid.toUpperCase();
    const f: string = p.fatherId.trim().toUpperCase();
    const m: string = p.motherId.trim().toUpperCase();
    if (f.length === 0 && m.length === 0) {
      return [];
    }
    return this.people.filter((x: Person): boolean => {
      const xu: string = x.uid.toUpperCase();
      if (xu === u) {
        return false;
      }
      const xf: string = x.fatherId.trim().toUpperCase();
      const xm: string = x.motherId.trim().toUpperCase();
      return (f.length > 0 && xf === f) || (m.length > 0 && xm === m);
    });
  }

  /** 当前人物的全部配偶关系（含元配/继室/妾等名分，按顺序排列） */
  spousesOf(uid: string): SpouseRelation[] {
    const p: Person | null = this.getPerson(uid);
    if (p === null) {
      return [];
    }
    return p.spouses.map((r: SpouseRelation): SpouseRelation => cloneSpouseRelation(r));
  }

  /** 主配偶（第一位） */
  spouseOf(uid: string): Person | null {
    const p: Person | null = this.getPerson(uid);
    if (p === null || p.spouses.length === 0) {
      return null;
    }
    return this.getPerson(p.spouses[0].uid);
  }

  /** 配偶展示文案，如：“配 林氏、继室 陈氏、妾 李氏” */
  spouseTextOf(uid: string): string {
    const p: Person | null = this.getPerson(uid);
    if (p === null || p.spouses.length === 0) {
      return '';
    }
    const parts: string[] = [];
    p.spouses.forEach((r: SpouseRelation): void => {
      const sp: Person | null = this.getPerson(r.uid);
      if (sp === null) {
        return;
      }
      const prefix: string = (r.relation === '元配' || r.relation === '未记' || r.relation === '配偶') ?
        '配' : (r.relation.length > 0 ? r.relation : '配');
      parts.push(prefix + ' ' + sp.name);
    });
    return parts.join('、');
  }

  /** 上下三代（含自身），用于详情页关系链 */
  relativesOf(uid: string): Person[] {
    const p: Person | null = this.getPerson(uid);
    const result: Person[] = [];
    if (p === null) {
      return result;
    }
    const f: Person | null = this.getPerson(p.fatherId);
    const m: Person | null = this.getPerson(p.motherId);
    if (f !== null) {
      result.push(f);
    }
    if (m !== null && m.uid !== (f === null ? '' : f.uid)) {
      result.push(m);
    }
    p.spouses.forEach((r: SpouseRelation): void => {
      const s: Person | null = this.getPerson(r.uid);
      if (s !== null) {
        result.push(s);
      }
    });
    this.childrenOf(uid).forEach((c: Person): void => {
      result.push(c);
    });
    this.siblingsOf(uid).forEach((c: Person): void => {
      result.push(c);
    });
    return result;
  }

  /** 按世代分组 */
  groupByGeneration(filterFn?: (p: Person) => boolean): Map<number, Person[]> {
    const map: Map<number, Person[]> = new Map<number, Person[]>();
    this.people.forEach((p: Person): void => {
      if (filterFn !== undefined && !filterFn(p)) {
        return;
      }
      const g: number = p.generation;
      const arr: Person[] | undefined = map.get(g);
      if (arr === undefined) {
        map.set(g, [p]);
      } else {
        arr.push(p);
      }
    });
    return map;
  }

  /** 全部字派（去重） */
  generationChars(): string[] {
    const set: Set<string> = new Set<string>();
    this.people.forEach((p: Person): void => {
      if (p.generationChar.trim().length > 0) {
        set.add(p.generationChar.trim());
      }
    });
    return Array.from(set).sort();
  }

  // ---------------------------------------------------------------- 统计

  computeStats(filterFn?: (p: Person) => boolean): GenealogyStats {
    // 全量统计按版本号缓存：比例页/概览页会在 build 内反复调用，切页重建组件时也要能命中
    if (filterFn === undefined && this.statsCache !== null && this.statsCacheVersion === this.version) {
      return this.statsCache as GenealogyStats;
    }
    const stats: GenealogyStats = new GenealogyStats();
    const filtered: Person[] = filterFn === undefined ? this.people : this.people.filter(filterFn);
    const genMap: Map<number, GenerationStat> = new Map<number, GenerationStat>();
    let lifespanSum: number = 0;
    let lifespanCount: number = 0;
    let male: number = 0;
    let female: number = 0;
    let alive: number = 0;
    let deceased: number = 0;
    let lost: number = 0;
    let maxGen: number = 0;
    let minGen: number = 99;
    let birthdayKnown: number = 0;
    let graveWithGps: number = 0;
    let avatarCount: number = 0;
    const spouseSet: Set<string> = new Set<string>();

    filtered.forEach((p: Person): void => {
      if (p.gender === '女') {
        female = female + 1;
      } else {
        male = male + 1;
      }
      if (p.lifeStatus === '已故') {
        deceased = deceased + 1;
      } else if (p.lifeStatus === '失联') {
        lost = lost + 1;
      } else {
        alive = alive + 1;
      }
      if (p.generation > maxGen) {
        maxGen = p.generation;
      }
      if (p.generation > 0 && p.generation < minGen) {
        minGen = p.generation;
      }
      if (p.birthDate.trim().length > 0) {
        birthdayKnown = birthdayKnown + 1;
      }
      if (p.graveLat !== 0 || p.graveLng !== 0) {
        graveWithGps = graveWithGps + 1;
      }
      if (p.avatar.length > 0) {
        avatarCount = avatarCount + 1;
      }
      p.spouses.forEach((r: SpouseRelation): void => {
        if (r.uid.trim().length > 0) {
          spouseSet.add(r.uid.trim().toUpperCase());
        }
      });
      const by: number = parseYear(p.birthDate);
      const dy: number = parseYear(p.deathDate);
      if (by > 0 && dy > by) {
        lifespanSum = lifespanSum + (dy - by);
        lifespanCount = lifespanCount + 1;
      }
      const g: number = p.generation > 0 ? p.generation : 1;
      let gs: GenerationStat | undefined = genMap.get(g);
      if (gs === undefined) {
        gs = new GenerationStat();
        gs.generation = g;
        gs.label = generationLabel(g);
        genMap.set(g, gs);
      }
      gs.total = gs.total + 1;
      if (p.gender === '女') {
        gs.female = gs.female + 1;
      } else {
        gs.male = gs.male + 1;
      }
      if (p.lifeStatus === '已故') {
        gs.deceased = gs.deceased + 1;
      } else {
        gs.alive = gs.alive + 1;
      }
    });

    stats.total = filtered.length;
    stats.male = male;
    stats.female = female;
    stats.alive = alive;
    stats.deceased = deceased;
    stats.lost = lost;
    stats.maxGeneration = maxGen;
    stats.minGeneration = minGen === 99 ? 1 : minGen;
    stats.spouseCount = spouseSet.size;
    stats.birthdayKnown = birthdayKnown;
    stats.graveWithGps = graveWithGps;
    stats.avatarCount = avatarCount;
    stats.averageLifespan = lifespanCount === 0 ? 0 : Math.round(lifespanSum / lifespanCount);

    const gens: GenerationStat[] = [];
    Array.from(genMap.keys()).sort((a: number, b: number): number => a - b).forEach((g: number): void => {
      const gs: GenerationStat = genMap.get(g) as GenerationStat;
      gs.ratio = stats.total === 0 ? 0 : gs.total / stats.total;
      gens.push(gs);
    });
    stats.generations = gens;
    if (filterFn === undefined) {
      this.statsCache = stats;
      this.statsCacheVersion = this.version;
    }
    return stats;
  }

  // ---------------------------------------------------------------- 写操作

  /** 新增人物，自动补全唯一ID；返回保存后的对象 */
  async addPerson(p: Person): Promise<Person> {
    if (this.currentBookId <= 0) {
      throw new Error('请先在「谱系」中创建族谱');
    }
    const person: Person = clonePerson(p);
    if (person.uid.trim().length === 0) {
      person.uid = this.nextUid(person.gender);
    }
    person.uid = person.uid.trim().toUpperCase();
    person.createdAt = Date.now();
    person.updatedAt = person.createdAt;
    this.normalizeSpouses(person);
    await this.upsertRow(person);
    await this.saveSpouses(person.uid, person.spouses);
    this.applySavedPerson(person, '');
    // 协作：本机先落库（唯一真相源），再按在线/离线走「云函数 / outbox」
    await this.notifyPersonChange('ADD', person, null);
    return person;
  }

  /** 更新人物（按 uid 定位） */
  async updatePerson(p: Person, originalUid: string): Promise<Person> {
    const person: Person = clonePerson(p);
    person.uid = person.uid.trim().toUpperCase();
    person.updatedAt = Date.now();
    this.normalizeSpouses(person);
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_PERSON);
    if (originalUid !== person.uid) {
      predicates.equalTo('uid', originalUid.trim().toUpperCase());
      predicates.and().equalTo('book_id', this.currentBookId);
    } else {
      predicates.equalTo('id', person.key);
    }
    const values: relationalStore.ValuesBucket = this.toValues(person);
    await store.update(values, predicates);
    // 若唯一ID变化，同步更新当前族谱内的引用
    if (originalUid.trim().toUpperCase() !== person.uid) {
      await store.executeSql(`UPDATE ${TABLE_PERSON} SET father_id = ? WHERE book_id = ? AND UPPER(father_id) = ?`,
        [person.uid, this.currentBookId, originalUid.trim().toUpperCase()]);
      await store.executeSql(`UPDATE ${TABLE_PERSON} SET mother_id = ? WHERE book_id = ? AND UPPER(mother_id) = ?`,
        [person.uid, this.currentBookId, originalUid.trim().toUpperCase()]);
      await store.executeSql(`UPDATE ${TABLE_PERSON} SET spouse_id = ? WHERE book_id = ? AND UPPER(spouse_id) = ?`,
        [person.uid, this.currentBookId, originalUid.trim().toUpperCase()]);
      await store.executeSql(`UPDATE ${TABLE_SPOUSE} SET uid = ? WHERE book_id = ? AND UPPER(uid) = ?`,
        [person.uid, this.currentBookId, originalUid.trim().toUpperCase()]);
      await store.executeSql(`UPDATE ${TABLE_SPOUSE} SET spouse_uid = ? WHERE book_id = ? AND UPPER(spouse_uid) = ?`,
        [person.uid, this.currentBookId, originalUid.trim().toUpperCase()]);
    }
    await this.saveSpouses(person.uid, person.spouses);
    this.applySavedPerson(person, originalUid);
    // 协作：同一人物的多次本地修改合并成一条 outbox（diff 相对编辑前快照）
    await this.notifyPersonChange('UPDATE', person, originalUid);
    return person;
  }

  /**
   * 保存后的内存增量刷新。
   *
   * 早先实现是 `await this.reload()`：每次保存都全表回读（5 万族人 + 8 万配偶关系）
   * 并重建整棵谱系树，真机上要数秒，主线程阻塞超过 6 秒会被系统看门狗强杀。
   * 这里按变化性质分两类处理：
   *  - 仅普通字段变化：原地改写 Person 对象（谱系节点持有同一引用），只递增版本号；
   *  - 编号 / 父母 / 配偶关系变化：在内存数组上打补丁，重建索引与谱系树。
   */
  private applySavedPerson(person: Person, originalUid: string): void {
    const prevUid: string = originalUid.trim().toUpperCase();
    const nextUid: string = person.uid.trim().toUpperCase();
    const old: Person | undefined = this.peopleMap.get(prevUid.length > 0 ? prevUid : nextUid);
    const structural: boolean = old === undefined
      || prevUid !== nextUid
      || old.fatherId.trim().toUpperCase() !== person.fatherId.trim().toUpperCase()
      || old.motherId.trim().toUpperCase() !== person.motherId.trim().toUpperCase()
      || this.spouseLinksChanged(old.spouses, person.spouses);
    if (!structural && old !== undefined) {
      // 普通字段：原地改写，谱系节点持有的对象引用不变，无需重建树
      copyPersonInto(old, person);
      this.bump();
      return;
    }
    const oldObj: Person | null = old === undefined ? null : old;
    // 1. 在内存列表中定位并替换（新增时追加）
    let index: number = -1;
    for (let i: number = 0; i < this.people.length; i++) {
      const u: string = this.people[i].uid.trim().toUpperCase();
      if (u === prevUid || u === nextUid) {
        index = i;
        break;
      }
    }
    if (index >= 0) {
      this.people[index] = person;
    } else {
      this.people.push(person);
    }
    // 2. 编号变更：同步其他族人的父母ID / 配偶ID
    if (prevUid.length > 0 && prevUid !== nextUid) {
      for (let i: number = 0; i < this.people.length; i++) {
        const p: Person = this.people[i];
        if (p.uid.trim().toUpperCase() === nextUid) {
          continue;
        }
        if (p.fatherId.trim().toUpperCase() === prevUid) {
          p.fatherId = nextUid;
        }
        if (p.motherId.trim().toUpperCase() === prevUid) {
          p.motherId = nextUid;
        }
        if (p.spouseId.trim().toUpperCase() === prevUid) {
          p.spouseId = nextUid;
        }
        for (let j: number = 0; j < p.spouses.length; j++) {
          if (p.spouses[j].uid.trim().toUpperCase() === prevUid) {
            p.spouses[j].uid = nextUid;
          }
        }
      }
    }
    // 3. 重建索引
    const map: Map<string, Person> = new Map<string, Person>();
    this.people.forEach((p: Person): void => {
      map.set(p.uid.trim().toUpperCase(), p);
    });
    this.peopleMap = map;
    // 4. 同步配偶反向引用（对方向本人的记录）
    this.syncSpouseBackRefs(person, oldObj, prevUid);
    // 5. 重建谱系树并发布新版本
    this.roots = TreeBuilder.build(this.people);
    this.bump();
  }

  /** 配偶关系是否有变化：数量、对象编号或称谓不同都算结构变化 */
  private spouseLinksChanged(a: SpouseRelation[], b: SpouseRelation[]): boolean {
    if (a.length !== b.length) {
      return true;
    }
    for (let i: number = 0; i < a.length; i++) {
      if (a[i].uid.trim().toUpperCase() !== b[i].uid.trim().toUpperCase()
        || a[i].relation !== b[i].relation) {
        return true;
      }
    }
    return false;
  }

  /**
   * 同步配偶的反向引用（仅内存态）：A 的配偶表里写了 B 时，B 的配偶表里也应写上 A。
   * 数据库侧由 saveSpouses 负责，这里避免为了这一处引用再去全表重载。
   */
  private syncSpouseBackRefs(person: Person, old: Person | null, prevUid: string): void {
    const self: string = person.uid.trim().toUpperCase();
    const prev: string = prevUid.trim().toUpperCase();
    // 1. 本次保存后的配偶集合
    const next: Set<string> = new Set<string>();
    person.spouses.forEach((r: SpouseRelation): void => {
      const id: string = r.uid.trim().toUpperCase();
      if (id.length > 0 && id !== self) {
        next.add(id);
      }
    });
    // 2. 处理旧关系：仍保留的改编号，已移除的从对方配偶表里删掉本人
    if (old !== null) {
      old.spouses.forEach((r: SpouseRelation): void => {
        const partnerUid: string = r.uid.trim().toUpperCase();
        if (partnerUid.length === 0 || partnerUid === self) {
          return;
        }
        const partner: Person | undefined = this.peopleMap.get(partnerUid);
        if (partner === undefined) {
          return;
        }
        if (next.has(partnerUid)) {
          if (prev.length > 0 && prev !== self) {
            partner.spouses.forEach((x: SpouseRelation): void => {
              if (x.uid.trim().toUpperCase() === prev) {
                x.uid = self;
              }
            });
            if (partner.spouseId.trim().toUpperCase() === prev) {
              partner.spouseId = self;
            }
          }
          return;
        }
        const kept: SpouseRelation[] = partner.spouses.filter((x: SpouseRelation): boolean => {
          const id: string = x.uid.trim().toUpperCase();
          return id !== prev && id !== self;
        });
        if (kept.length !== partner.spouses.length) {
          kept.forEach((x: SpouseRelation, i: number): void => {
            x.order = i + 1;
          });
          partner.spouses = kept;
          partner.spouseId = kept.length > 0 ? kept[0].uid : '';
        }
      });
    }
    // 3. 新关系：对方配偶表里没有本人时补一条
    person.spouses.forEach((r: SpouseRelation): void => {
      const partnerUid: string = r.uid.trim().toUpperCase();
      if (partnerUid.length === 0 || partnerUid === self) {
        return;
      }
      const partner: Person | undefined = this.peopleMap.get(partnerUid);
      if (partner === undefined) {
        return;
      }
      let found: boolean = false;
      for (let i: number = 0; i < partner.spouses.length; i++) {
        if (partner.spouses[i].uid.trim().toUpperCase() === self) {
          found = true;
          break;
        }
      }
      if (found) {
        return;
      }
      const nr: SpouseRelation = new SpouseRelation();
      nr.uid = self;
      nr.relation = partner.gender === '女' ? '夫' : (r.relation === '夫' ? '元配' : r.relation);
      nr.level = spouseRelationLevel(nr.relation);
      nr.order = partner.spouses.length + 1;
      partner.spouses.push(nr);
      if (partner.spouseId.trim().length === 0) {
        partner.spouseId = self;
      }
    });
  }

  /** 删除人物（其子女自动上提为无父/无母，不删除其他人物） */
  async deletePerson(uid: string): Promise<void> {
    const u: string = uid.trim().toUpperCase();
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const deleted: Person | null = this.getPerson(u);
    const cloud: boolean = this.book.familyId.length > 0;
    if (cloud) {
      // 协作态：墓碑软删（deleted_at 非 0），查询时统一过滤
      await store.executeSql(
        `UPDATE ${TABLE_PERSON} SET deleted_at = ?, updated_at = ?, dirty = 1 WHERE book_id = ? AND UPPER(uid) = ?`,
        [Date.now(), Date.now(), this.currentBookId, u]);
    } else {
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_PERSON);
      predicates.equalTo('uid', u);
      predicates.and().equalTo('book_id', this.currentBookId);
      await store.delete(predicates);
    }
    if (deleted !== null) {
      // 记录该编号已被使用过，后续新增人员不再复用，避免旧关系挂到新族人身上
      await this.recordRetired(u, deleted.name);
    }
    await store.executeSql(`UPDATE ${TABLE_PERSON} SET father_id = '' WHERE book_id = ? AND UPPER(father_id) = ?`,
      [this.currentBookId, u]);
    await store.executeSql(`UPDATE ${TABLE_PERSON} SET mother_id = '' WHERE book_id = ? AND UPPER(mother_id) = ?`,
      [this.currentBookId, u]);
    await store.executeSql(`UPDATE ${TABLE_PERSON} SET spouse_id = '' WHERE book_id = ? AND UPPER(spouse_id) = ?`,
      [this.currentBookId, u]);
    await store.executeSql(
      `DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ? AND (UPPER(uid) = ? OR UPPER(spouse_uid) = ?)`,
      [this.currentBookId, u, u]);
    await this.reload();
    if (cloud && deleted !== null) {
      await this.notifyPersonChange('DELETE', deleted, null);
    }
  }

  /** 批量新增（导入使用），失败信息返回 */
  async importPeople(list: Person[], mergeStrategy: string): Promise<number> {
    if (this.currentBookId <= 0) {
      throw new Error('请先在「谱系」中创建族谱');
    }
    let count: number = 0;
    // 批量导入时 people 只每 50 条刷新一次，需单独记录本批已分配的编号
    const batchUsed: Set<string> = new Set<string>();
    for (let i: number = 0; i < list.length; i++) {
      const p: Person = clonePerson(list[i]);
      p.uid = p.uid.trim().toUpperCase();
      this.normalizeSpouses(p);
      if (p.uid.length === 0) {
        // 导入文件缺少唯一ID时补一个未使用的编号，避免空ID无法建立亲属关系
        p.uid = this.nextUid(p.gender, batchUsed);
        batchUsed.add(p.uid);
      }
      if (this.retiredNameOf(p.uid).length > 0) {
        // 该编号曾用于已删除族人：跳过或改用新编号，避免旧关系被错误挂接
        if (mergeStrategy === 'skip') {
          continue;
        }
        if (mergeStrategy === 'newId') {
          p.uid = this.nextUid(p.gender, batchUsed);
          batchUsed.add(p.uid);
        }
      }
      const exist: Person | undefined = this.peopleMap.get(p.uid);
      if (exist !== undefined) {
        if (mergeStrategy === 'skip') {
          continue;
        }
        if (mergeStrategy === 'replace') {
          p.key = exist.key;
          await this.upsertRow(p);
          await this.saveSpouses(p.uid, p.spouses);
          batchUsed.add(p.uid);
          count++;
          continue;
        }
        if (mergeStrategy === 'newId') {
          p.uid = this.nextUid(p.gender, batchUsed);
          batchUsed.add(p.uid);
        }
      }
      await this.upsertRow(p);
      await this.saveSpouses(p.uid, p.spouses);
      batchUsed.add(p.uid);
      count++;
      // 每 50 条刷新一次，避免内存映射未更新导致 ID 重复
      if (count % 50 === 0) {
        await this.reload();
      }
    }
    await this.reload();
    return count;
  }

  /**
   * 生成导入计划（纯内存，不落库）：身份匹配 + 全局 ID 重映射。
   * strategy 与旧界面保持一致：
   *   auto（智能匹配）/ skip（冲突跳过）/ replace（冲突覆盖）/ newId（冲突另编号）。
   * asNewBook 为 true 时按「另立独立族谱」规划：不与当前谱人物做身份匹配，
   * 也不受当前谱已删除编号限制，避免把另一部族谱的人员并进当前谱导致编号冲突。
   */
  async planImport(list: Person[], strategy: string, asNewBook: boolean = false,
    onProgress?: (done: number, total: number) => void): Promise<ImportPlan> {
    const opt: ImportOptions = new ImportOptions();
    if (strategy === 'skip' || strategy === 'defer') {
      opt.conflictPolicy = 'defer';
    } else if (strategy === 'replace' || strategy === 'merge') {
      opt.conflictPolicy = 'merge';
      opt.localFieldFirst = false;
    } else if (strategy === 'newId' || strategy === 'new') {
      opt.conflictPolicy = 'new';
    } else {
      opt.conflictPolicy = 'auto';
    }
    return ImportPlanner.plan(list, asNewBook ? [] : this.people,
      asNewBook ? new Map<string, string>() : this.retiredUids, opt);
  }

  /**
   * 执行导入计划：
   *   事务内逐条落库 → 关系图修复（悬空清理 + 配偶双向）→ 体检 → 提交；
   *   任何异常都回滚事务，避免留下半成品。
   */
  async applyImportPlan(plan: ImportPlan,
    onProgress?: (done: number, total: number) => void): Promise<ImportResult> {
    if (this.currentBookId <= 0) {
      throw new Error('请先在「谱系」中创建族谱');
    }
    if (this.store === null) {
      throw new Error('数据库未就绪');
    }
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const result: ImportResult = new ImportResult();
    const total: number = plan.people.length;
    /** 事务是否已提交：提交后的错误不再回滚，避免把已落库的族人删掉 */
    let committed: boolean = false;
    // 整段写入放进一个事务：失败由 SQLite 回滚，不再序列化「整谱快照」。
    // 数万人的快照是几十 MB 的 JSON，序列化 + 写单行 TEXT 比导入本身还慢；
    // 事务还省掉了逐条 fsync，实测 3.6 万条从约 9 分钟降到分钟级。
    try {
      store.beginTransaction();
      // 逐条 insert/update 每次都要跨线程做一次 IPC（实测约 90ms/条，数万人要几十分钟）。
      // 改为「先分批删除被覆盖的 uid，再分批 batchInsert」：SQL 从十万条降到百来条。
      // 删除只覆盖本次导入的 uid，导入文件里没有的本机族人不受影响；事务失败会整体回滚。
      const batchSize: number = 500;
      for (let start: number = 0; start < total; start = start + batchSize) {
        const end: number = Math.min(start + batchSize, total);
        const marks: string[] = [];
        const args: relationalStore.ValueType[] = [this.currentBookId];
        for (let j: number = start; j < end; j++) {
          marks.push('?');
          args.push(plan.people[j].uid.trim().toUpperCase());
        }
        const inList: string = marks.join(',');
        await store.executeSql(
          `DELETE FROM ${TABLE_PERSON} WHERE book_id = ? AND UPPER(uid) IN (${inList})`, args);
        await store.executeSql(
          `DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ? AND UPPER(uid) IN (${inList})`, args);
      }
      let personBatch: relationalStore.ValuesBucket[] = [];
      let spouseBatch: relationalStore.ValuesBucket[] = [];
      for (let i: number = 0; i < total; i++) {
        const p: Person = clonePerson(plan.people[i]);
        p.uid = p.uid.trim().toUpperCase();
        this.normalizeSpouses(p);
        const exist: Person | undefined = this.peopleMap.get(p.uid);
        if (exist !== undefined) {
          p.createdAt = exist.createdAt > 0 ? exist.createdAt : p.createdAt;
          p.updatedAt = Date.now();
        }
        personBatch.push(this.toValues(p, this.currentBookId));
        for (let s: number = 0; s < p.spouses.length; s++) {
          const r: SpouseRelation = p.spouses[s];
          const partner: string = r.uid.trim().toUpperCase();
          if (partner.length === 0 || partner === p.uid) {
            continue;
          }
          const rel: string = r.relation.trim().length > 0 ? r.relation.trim() : '未记';
          spouseBatch.push({
            'book_id': this.currentBookId,
            'uid': p.uid,
            'spouse_uid': partner,
            'relation': rel,
            'level': spouseRelationLevel(rel),
            'ord': s + 1
          });
        }
        result.saved = result.saved + 1;
        if (personBatch.length >= batchSize) {
          await store.batchInsert(TABLE_PERSON, personBatch);
          personBatch = [];
        }
        if (spouseBatch.length >= batchSize) {
          await store.batchInsert(TABLE_SPOUSE, spouseBatch);
          spouseBatch = [];
        }
        // 每 200 条回报一次进度（一批几千条也只回刷几次，避免频繁触发界面重建）
        if (onProgress !== undefined && (i % 200 === 199 || i === total - 1)) {
          onProgress(i + 1, total);
        }
      }
      if (personBatch.length > 0) {
        await store.batchInsert(TABLE_PERSON, personBatch);
      }
      if (spouseBatch.length > 0) {
        await store.batchInsert(TABLE_SPOUSE, spouseBatch);
      }
      // 先提交、再重读：ArkTS 的异步 SQL 走独立连接，事务内 SELECT 读不到未提交数据。
      // 旧实现把 reload 放在事务里，首次建谱导入后 this.people 会被重读成空数组 ——
      // 库里其实已有几万人，界面却显示 0 人，用户只能再导入一次才「看得见」。
      store.commit();
      committed = true;
      // 提交后先把导入过程中的大对象全部释放，再重读库：
      // 「另编号」会把整谱翻倍（4 万 → 8 万），若此时仍持有导入文件解析出的
      // 人物、计划克隆副本和旧内存数据，重读 + 重建谱系会直接 OutOfMemoryError
      //（实测堆已用到 447MB，本地堆上限约 474MB）。
      plan.people = [];
      plan.matches = [];
      plan.remaps = [];
      plan.warnings = [];
      plan.errors = [];
      this.people = [];
      this.peopleMap = new Map<string, Person>();
      this.roots = [];
      await this.reload();
      // 关系图修复：断链清理 + 配偶双向补齐（世代默认只统计，不改史料）
      const repaired: RepairReport = RelationGraph.repair(this.people, false);
      for (let i: number = 0; i < repaired.touched.length; i++) {
        const target: Person | undefined = this.peopleMap.get(repaired.touched[i]);
        if (target === undefined) {
          continue;
        }
        await this.upsertRow(target);
        await this.saveSpouses(target.uid, target.spouses);
      }
      if (repaired.touched.length > 0) {
        await this.reload();
      }
      result.danglingCount = repaired.danglingCount;
      result.oneWaySpouseCount = repaired.oneWaySpouseCount;
      result.generationMismatchCount = repaired.generationMismatchCount;
      const report: IntegrityReport = this.checkIntegrity();
      report.issues.forEach((issue: IntegrityIssue): void => {
        if (issue.level === 'error') {
          result.integrityErrors = result.integrityErrors + 1;
        }
      });
      hilog.info(0x0000, TAG, 'import applied, saved=%{public}d', result.saved);
      return result;
    } catch (e) {
      const err = e as BusinessError;
      if (!committed) {
        hilog.error(0x0000, TAG, 'import failed, rolling back: %{public}s', err.message);
        try {
          store.rollBack();
        } catch (rb) {
          hilog.error(0x0000, TAG, 'import rollback failed');
        }
        // 回滚后必须重读库修正内存状态
        await this.reload();
        throw new Error('导入写入失败，已回滚：' + err.message);
      }
      // 已提交：族人已经落库，关系修复阶段出错不能回滚，
      // 否则会把刚导入的整谱删掉；只记录日志并按已写入人数返回。
      hilog.error(0x0000, TAG, 'import repair failed after commit: %{public}s', err.message);
      await this.reload();
      return result;
    }
  }

  /** 全量替换当前族谱的人物（恢复备份） */
  async replaceAll(list: Person[]): Promise<void> {
    if (this.currentBookId <= 0) {
      throw new Error('请先在「谱系」中创建族谱');
    }
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    await store.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [this.currentBookId]);
    await store.executeSql(`DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ?`, [this.currentBookId]);
    // 全量替换后，历史ID与旧关系不再可信，清空复用黑名单避免误报
    await this.clearRetired(this.currentBookId);
    for (let i: number = 0; i < list.length; i++) {
      const p: Person = clonePerson(list[i]);
      p.uid = p.uid.trim().toUpperCase();
      this.normalizeSpouses(p);
      await this.upsertRow(p);
      await this.saveSpouses(p.uid, p.spouses);
    }
    await this.reload();
  }

  async saveBook(book: Genealogy): Promise<void> {
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    book.updatedAt = Date.now();
    if (book.key > 0) {
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_BOOK);
      predicates.equalTo('id', book.key);
      await store.update(this.bookValues(book), predicates);
    } else {
      const rowId: number = await store.insert(TABLE_BOOK, this.bookValues(book));
      book.key = rowId;
    }
    this.book = book;
    // 同步族谱列表中的对应项，供切换入口实时展示
    for (let i: number = 0; i < this.books.length; i++) {
      if (this.books[i].key === book.key) {
        this.books[i] = book;
        break;
      }
    }
    this.bump();
    // 切换/保存族谱后同步协作态（familyId / 角色 / 同步模式）
    FamilyService.getInstance().applyBookFamilyState();
  }

  /** 新建一部空族谱（无族人），创建后自动切换为当前族谱 */
  async createGenealogy(title: string): Promise<Genealogy> {
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const book: Genealogy = createEmptyGenealogy();
    const base: string = title.trim().length > 0 ? title.trim() : '我的族谱';
    // 多族谱下自动去重命名，避免出现多个同名族谱难以区分
    let name: string = base;
    let serial: number = 2;
    while (this.hasBookTitle(name)) {
      name = base + ' ' + serial.toString();
      serial++;
    }
    book.title = name;
    const rowId: number = await store.insert(TABLE_BOOK, this.bookValues(book));
    book.key = rowId;
    this.currentBookId = rowId;
    await this.setMeta(META_CURRENT_BOOK, rowId.toString());
    await this.reload();
    return this.book;
  }

  /**
   * 在没有族谱时，用备份文件中的「族谱信息」新建族谱并导入族人。
   * 族谱实体的 key/云协作字段不随文件恢复，避免把旧谱的云家族信息一起带回来。
   */
  async importAsNewBook(meta: Genealogy, plan: ImportPlan,
    onProgress?: (done: number, total: number) => void): Promise<ImportResult> {
    const created: Genealogy = await this.createGenealogy(meta.title);
    created.surname = meta.surname;
    created.hallName = meta.hallName;
    created.junwang = meta.junwang;
    created.ancestorName = meta.ancestorName;
    created.generationPoem = meta.generationPoem;
    created.preface = meta.preface;
    created.familyRules = meta.familyRules;
    created.editingNotes = meta.editingNotes;
    await this.saveBook(created);
    return this.applyImportPlan(plan, onProgress);
  }

  /** 是否已存在同名族谱 */
  private hasBookTitle(title: string): boolean {
    for (let i: number = 0; i < this.books.length; i++) {
      if (this.books[i].title === title) {
        return true;
      }
    }
    return false;
  }

  /**
   * 以当前族谱中的某位族人为始祖，另立一部分支族谱。
   *  - 复制该人及其全部后代（含各自的配偶），世代按“该人为第一世”重新编号；
   *  - 分支谱数据独立，原族谱不受影响；创建后自动切换到分支谱继续录入。
   */
  async createBranchFromPerson(rootUid: string): Promise<Genealogy> {
    if (this.currentBookId <= 0) {
      throw new Error('请先在「谱系」中创建族谱');
    }
    const root: Person | null = this.getPerson(rootUid);
    if (root === null) {
      throw new Error('未找到该族人');
    }
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const picked: Set<string> = new Set<string>();
    const line: Person[] = [];
    const collect = (uid: string): void => {
      const u: string = uid.trim().toUpperCase();
      if (u.length === 0 || picked.has(u)) {
        return;
      }
      const p: Person | null = this.getPerson(u);
      if (p === null) {
        return;
      }
      picked.add(u);
      line.push(p);
      this.people.forEach((c: Person): void => {
        if (c.fatherId.trim().toUpperCase() === u || c.motherId.trim().toUpperCase() === u) {
          collect(c.uid);
        }
      });
    };
    collect(root.uid);

    // 补入这支人的配偶（妻/妾 / 夫），保证夫妻在分支谱中仍成对显示
    const spouses: Person[] = [];
    line.forEach((p: Person): void => {
      this.spousesOf(p.uid).forEach((r: SpouseRelation): void => {
        const u: string = r.uid.trim().toUpperCase();
        const sp: Person | null = this.getPerson(u);
        if (sp !== null && !picked.has(u)) {
          picked.add(u);
          spouses.push(sp);
        }
      });
    });
    const all: Person[] = line.concat(spouses);

    // 新建分支族谱：命名带上母谱与始祖名，便于区分
    const baseTitle: string = (this.book.title.trim().length > 0 ? this.book.title.trim() : '我的族谱')
      + '-' + root.name + '分支';
    let title: string = baseTitle;
    let serial: number = 2;
    while (this.hasBookTitle(title)) {
      title = baseTitle + ' ' + serial.toString();
      serial++;
    }
    const branch: Genealogy = createEmptyGenealogy();
    branch.title = title;
    branch.surname = this.book.surname;
    branch.hallName = this.book.hallName;
    branch.junwang = this.book.junwang;
    branch.ancestorName = root.name;
    branch.generationPoem = this.book.generationPoem;
    branch.coverColor = this.book.coverColor;
    branch.coverPattern = this.book.coverPattern;
    branch.parentBookId = this.currentBookId;
    branch.branchRootUid = root.uid.trim().toUpperCase();
    const rowId: number = await store.insert(TABLE_BOOK, this.bookValues(branch));
    branch.key = rowId;

    // 复制族人：以始祖为第一世重排世代，剪断分支外的一切父/母与配偶引用
    const offset: number = root.generation - 1;
    const rootKey: string = root.uid.trim().toUpperCase();
    for (let i: number = 0; i < all.length; i++) {
      const src: Person = all[i];
      const p: Person = clonePerson(src);
      p.key = 0;
      p.generation = Math.max(1, src.generation - offset);
      if (p.uid.trim().toUpperCase() === rootKey) {
        p.fatherId = '';
        p.motherId = '';
        p.rank = '第一世（始祖）';
      } else {
        if (!picked.has(p.fatherId.trim().toUpperCase())) {
          p.fatherId = '';
        }
        if (!picked.has(p.motherId.trim().toUpperCase())) {
          p.motherId = '';
        }
      }
      const keptSpouses: SpouseRelation[] = [];
      p.spouses.forEach((r: SpouseRelation): void => {
        if (picked.has(r.uid.trim().toUpperCase())) {
          keptSpouses.push(r);
        }
      });
      p.spouses = keptSpouses;
      if (!picked.has(p.spouseId.trim().toUpperCase())) {
        p.spouseId = '';
      }
      this.normalizeSpouses(p);
      p.createdAt = Date.now();
      p.updatedAt = p.createdAt;
      await this.upsertRow(p, rowId);
      await this.saveSpouses(p.uid, p.spouses, rowId);
    }

    this.currentBookId = rowId;
    await this.setMeta(META_CURRENT_BOOK, rowId.toString());
    await this.reload();
    return this.book;
  }

  /** 切换当前族谱，其他页面会跟随刷新 */
  async switchGenealogy(bookId: number): Promise<void> {
    if (bookId <= 0 || bookId === this.currentBookId) {
      return;
    }
    if (AppStorage.get<boolean>('gpCloudBusy') === true) {
      throw new Error('云发布或同步进行中，请完成后再切换族谱');
    }
    let exists: boolean = false;
    for (let i: number = 0; i < this.books.length; i++) {
      if (this.books[i].key === bookId) {
        exists = true;
        break;
      }
    }
    if (!exists) {
      return;
    }
    AppStorage.setOrCreate<boolean>('gpCloudBusy', true);
    try {
      this.currentBookId = bookId;
      await this.setMeta(META_CURRENT_BOOK, bookId.toString());
      await this.reload();
    } finally {
      AppStorage.setOrCreate<boolean>('gpCloudBusy', false);
    }
  }

  /**
   * 删除指定族谱（含该族谱的族人、配偶关系与元信息）。
   * 若删除的是当前族谱，自动切换到剩余族谱；全部删除后进入“无族谱”状态。
   */
  async deleteGenealogy(bookId: number = 0): Promise<void> {
    if (this.store === null) {
      return;
    }
    const target: number = bookId > 0 ? bookId : this.currentBookId;
    if (target <= 0) {
      return;
    }
    const store: relationalStore.RdbStore = this.store;
    await store.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [target]);
    await store.executeSql(`DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ?`, [target]);
    await store.executeSql(`DELETE FROM ${TABLE_BOOK} WHERE id = ?`, [target]);
    await store.executeSql(`DELETE FROM ${TABLE_META} WHERE key = ?`,
      [META_RETIRED_PREFIX + target.toString()]);
    // 重新选定当前族谱：优先保留原来的，不存在则取第一部，全部删除则为 0
    await this.ensureCurrentBook();
    await this.setMeta(META_CURRENT_BOOK, this.currentBookId.toString());
    await this.reload();
  }

  /**
   * 从云端恢复多部族谱：先清空本地族谱数据，再按云端分组逐部重建。
   * 每部族谱及其族人、配偶关系完全独立，避免多族谱互相串数据。
   */
  async restoreFromCloud(groups: BookGroup[]): Promise<number> {
    if (this.store === null) {
      return 0;
    }
    const store: relationalStore.RdbStore = this.store;
    await store.executeSql(`DELETE FROM ${TABLE_PERSON}`);
    await store.executeSql(`DELETE FROM ${TABLE_SPOUSE}`);
    await store.executeSql(`DELETE FROM ${TABLE_BOOK}`);
    // 云端恢复是全量重建：已删除编号表来自旧本地库，恢复后不再适用
    await store.executeSql(`DELETE FROM ${TABLE_META} WHERE key LIKE 'retired_uids_%'`);
    this.retiredUids.clear();
    let firstBookId: number = 0;
    let restored: number = 0;
    // 云端族谱ID与本地新ID不一致，分支关系需按旧ID映射后回填
    const bookIdMap: Map<number, number> = new Map<number, number>();
    const restoredBooks: Genealogy[] = [];
    const sourceParentIds: number[] = [];
    for (let i: number = 0; i < groups.length; i++) {
      const group: BookGroup = groups[i];
      const book: Genealogy = group.book;
      const title: string = book.title.trim().length > 0 ? book.title.trim() : '我的族谱';
      const target: Genealogy = createEmptyGenealogy();
      target.title = title;
      target.surname = book.surname;
      target.hallName = book.hallName;
      target.junwang = book.junwang;
      target.ancestorName = book.ancestorName;
      target.generationPoem = book.generationPoem;
      target.preface = book.preface;
      target.familyRules = book.familyRules;
      target.editingNotes = book.editingNotes;
      target.coverColor = book.coverColor;
      target.coverPattern = book.coverPattern;
      target.parentBookId = 0;
      target.branchRootUid = book.branchRootUid !== undefined ? book.branchRootUid : '';
      const rowId: number = await store.insert(TABLE_BOOK, this.bookValues(target));
      target.key = rowId;
      bookIdMap.set(book.key, rowId);
      restoredBooks.push(target);
      sourceParentIds.push(book.parentBookId !== undefined ? book.parentBookId : 0);
      if (firstBookId === 0) {
        firstBookId = rowId;
      }
      for (let j: number = 0; j < group.people.length; j++) {
        const p: Person = clonePerson(group.people[j]);
        p.key = 0;
        p.uid = p.uid.trim().toUpperCase();
        this.normalizeSpouses(p);
        await this.upsertRow(p, rowId);
        await this.saveSpouses(p.uid, p.spouses, rowId);
        restored++;
      }
    }
    for (let i: number = 0; i < restoredBooks.length; i++) {
      const mapped: number | undefined = bookIdMap.get(sourceParentIds[i]);
      if (mapped === undefined || mapped <= 0) {
        continue;
      }
      restoredBooks[i].parentBookId = mapped;
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_BOOK);
      predicates.equalTo('id', restoredBooks[i].key);
      await store.update(this.bookValues(restoredBooks[i]), predicates);
    }
    this.currentBookId = firstBookId;
    await this.setMeta(META_CURRENT_BOOK, firstBookId.toString());
    await this.reload();
    return restored;
  }

  /** 直接插入一条新人物（导入批量写入用，跳过按 id/uid 的两次回查更新） */
  private async insertPerson(p: Person): Promise<void> {
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const rowId: number = await store.insert(TABLE_PERSON, this.toValues(p, this.currentBookId));
    p.key = rowId;
  }

  private async upsertRow(p: Person, bookId: number = 0): Promise<void> {
    const owner: number = bookId > 0 ? bookId : this.currentBookId;
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const values: relationalStore.ValuesBucket = this.toValues(p, owner);
    if (p.key > 0) {
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_PERSON);
      predicates.equalTo('id', p.key);
      const changed: number = await store.update(values, predicates);
      if (changed > 0) {
        return;
      }
    }
    const predicates2: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_PERSON);
    predicates2.equalTo('uid', p.uid);
    predicates2.and().equalTo('book_id', owner);
    const changed2: number = await store.update(values, predicates2);
    if (changed2 > 0) {
      return;
    }
    const rowId: number = await store.insert(TABLE_PERSON, values);
    p.key = rowId;
  }

  /**
   * 归一化配偶关系：去空值 / 去重 / 去本人，补齐名分与次序，
   * 并把 spouseId 同步为主配偶（spouses[0]）。
   */
  private normalizeSpouses(p: Person): void {
    const list: SpouseRelation[] = [];
    const seen: Set<string> = new Set<string>();
    const self: string = p.uid.trim().toUpperCase();
    p.spouses.forEach((r: SpouseRelation): void => {
      const id: string = r.uid.trim().toUpperCase();
      if (id.length === 0 || id === self || seen.has(id)) {
        return;
      }
      seen.add(id);
      const nr: SpouseRelation = new SpouseRelation();
      nr.uid = id;
      nr.relation = r.relation.trim().length > 0 ? r.relation.trim() :
        (p.gender === '女' ? '夫' : '未记');
      nr.level = spouseRelationLevel(nr.relation);
      nr.order = list.length + 1;
      list.push(nr);
    });
    const legacy: string = p.spouseId.trim().toUpperCase();
    if (list.length === 0 && legacy.length > 0 && legacy !== self) {
      const nr: SpouseRelation = new SpouseRelation();
      nr.uid = legacy;
      nr.relation = p.gender === '女' ? '夫' : '元配';
      nr.level = spouseRelationLevel(nr.relation);
      nr.order = 1;
      list.push(nr);
    }
    p.spouses = list;
    p.spouseId = list.length > 0 ? list[0].uid : '';
  }

  /**
   * 保存某人的配偶关系：
   *  - 先解除已移除的配偶（双向删除，避免另一侧的旧记录复活）；
   *  - 再重建本人名下的直接关系（按 ord 顺序）。
   */
  private async saveSpouses(ownerUid: string, list: SpouseRelation[], bookId: number = 0): Promise<void> {
    const owner: number = bookId > 0 ? bookId : this.currentBookId;
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const u: string = ownerUid.trim().toUpperCase();
    if (u.length === 0 || owner <= 0) {
      return;
    }
    const newSet: Set<string> = new Set<string>();
    list.forEach((r: SpouseRelation): void => {
      const id: string = r.uid.trim().toUpperCase();
      if (id.length > 0 && id !== u) {
        newSet.add(id);
      }
    });
    const oldSet: Set<string> = new Set<string>();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT uid, spouse_uid FROM ${TABLE_SPOUSE} WHERE book_id = ? AND (UPPER(uid) = ? OR UPPER(spouse_uid) = ?)`,
      [owner, u, u]);
    try {
      while (rs.goToNextRow()) {
        const a: string = rs.getString(rs.getColumnIndex('uid')).trim().toUpperCase();
        const b: string = rs.getString(rs.getColumnIndex('spouse_uid')).trim().toUpperCase();
        const partner: string = a === u ? b : a;
        if (partner.length > 0 && partner !== u) {
          oldSet.add(partner);
        }
      }
    } finally {
      rs.close();
    }
    const affected: Set<string> = new Set<string>();
    const olds: string[] = Array.from(oldSet);
    for (let i: number = 0; i < olds.length; i++) {
      const o: string = olds[i];
      affected.add(o);
      if (!newSet.has(o)) {
        await store.executeSql(
          `DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ? AND ((UPPER(uid) = ? AND UPPER(spouse_uid) = ?) OR (UPPER(uid) = ? AND UPPER(spouse_uid) = ?))`,
          [owner, u, o, o, u]);
      }
    }
    const news: string[] = Array.from(newSet);
    news.forEach((n: string): void => {
      affected.add(n);
    });
    await store.executeSql(`DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ? AND UPPER(uid) = ?`, [owner, u]);
    for (let i: number = 0; i < list.length; i++) {
      const id: string = list[i].uid.trim().toUpperCase();
      if (id.length === 0 || id === u) {
        continue;
      }
      const rel: string = list[i].relation.trim().length > 0 ? list[i].relation.trim() : '未记';
      await store.executeSql(
        `INSERT OR REPLACE INTO ${TABLE_SPOUSE}(book_id, uid, spouse_uid, relation, level, ord) VALUES(?, ?, ?, ?, ?, ?)`,
        [owner, u, id, rel, spouseRelationLevel(rel), i + 1]);
    }
    // 同步相关人物的 spouse_id（兼容旧字段），避免下次启动被迁移逻辑“复活”
    const partners: string[] = Array.from(affected);
    for (let i: number = 0; i < partners.length; i++) {
      const o: string = partners[i];
      if (o.length === 0 || o === u) {
        continue;
      }
      await store.executeSql(
        `UPDATE ${TABLE_PERSON} SET spouse_id = COALESCE((SELECT spouse_uid FROM ${TABLE_SPOUSE} WHERE book_id = ? AND UPPER(uid) = ? ORDER BY ord LIMIT 1), '') WHERE book_id = ? AND UPPER(uid) = ?`,
        [owner, o, owner, o]);
    }
  }

  /** 旧数据迁移：把 person.spouse_id 单值写入配偶关系表（幂等） */
  private async migrateSpouses(): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.executeSql(`INSERT INTO ${TABLE_SPOUSE} (book_id, uid, spouse_uid, relation, level, ord)
      SELECT p.book_id, UPPER(TRIM(p.uid)), UPPER(TRIM(p.spouse_id)),
        CASE WHEN p.gender = '女' THEN '夫' ELSE '元配' END,
        CASE WHEN p.gender = '女' THEN '夫' ELSE '正妻' END, 1
      FROM ${TABLE_PERSON} p
      WHERE p.spouse_id IS NOT NULL AND TRIM(p.spouse_id) <> ''
      AND NOT EXISTS (
        SELECT 1 FROM ${TABLE_SPOUSE} s
        WHERE s.book_id = p.book_id
          AND ((UPPER(s.uid) = UPPER(TRIM(p.uid)) AND UPPER(s.spouse_uid) = UPPER(TRIM(p.spouse_id)))
            OR (UPPER(s.uid) = UPPER(TRIM(p.spouse_id)) AND UPPER(s.spouse_uid) = UPPER(TRIM(p.uid))))
      )`);
  }

  /** 按称谓回填配偶名分等级（旧数据 level 为空时执行） */
  private async backfillSpouseLevels(): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.executeSql(`UPDATE ${TABLE_SPOUSE} SET level = CASE
      WHEN relation IN ('元配', '正室', '嫡妻', '发妻', '继室', '继妻', '继配', '后妻', '续弦', '填房', '正房') THEN '正妻'
      WHEN relation IN ('平妻', '并嫡', '对房', '两头大') THEN '平妻'
      WHEN relation IN ('媵', '侧室', '副室') THEN '贵妾'
      WHEN relation IN ('偏房', '二房', '姨娘', '如夫人') THEN '良妾'
      WHEN relation IN ('陪房', '侍妾', '婢妾', '通房丫头') THEN '贱妾'
      WHEN relation IN ('外室', '外妇') THEN '外室'
      WHEN relation = '夫' THEN '夫'
      ELSE '未记' END
      WHERE level IS NULL OR level = ''`);
  }

  /** 兼容旧库：表缺列时自动补充 */
  private async ensureColumn(table: string, column: string, type: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    const rs: relationalStore.ResultSet = await this.store.querySql(`PRAGMA table_info(${table})`);
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
    if (!exists) {
      await this.store.executeSql(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`);
    }
  }

  private toValues(p: Person, bookId: number = 0): relationalStore.ValuesBucket {
    const owner: number = bookId > 0 ? bookId : this.currentBookId;
    const v: relationalStore.ValuesBucket = {
      'book_id': owner,
      'uid': p.uid,
      'generation': p.generation,
      'name': p.name,
      'alias': p.alias,
      'gender': p.gender,
      'generation_char': p.generationChar,
      'life_status': p.lifeStatus,
      'child_status': p.childStatus,
      'birth_date': p.birthDate,
      'birth_calendar': p.birthCalendar,
      'death_date': p.deathDate,
      'death_calendar': p.deathCalendar,
      'birth_place': p.birthPlace,
      'residence': p.residence,
      'father_id': p.fatherId,
      'mother_id': p.motherId,
      'spouse_id': p.spouseId,
      'rank': p.rank,
      'adoption': p.adoption,
      'education': p.education,
      'occupation': p.occupation,
      'biography': p.biography,
      'grave_info': p.graveInfo,
      'grave_lng': p.graveLng,
      'grave_lat': p.graveLat,
      'grave_altitude': p.graveAltitude,
      'phone': p.phone,
      'wechat': p.wechat,
      'avatar': p.avatar,
      'videos': p.videos,
      'photos': p.photos,
      'created_at': p.createdAt,
      'updated_at': p.updatedAt,
      'rev': p.rev,
      'base_rev': p.baseRev,
      'dirty': p.dirty ? 1 : 0,
      'deleted_at': p.deletedAt
    };
    return v;
  }

  private bookValues(b: Genealogy): relationalStore.ValuesBucket {
    const v: relationalStore.ValuesBucket = {
      'title': b.title,
      'surname': b.surname,
      'hall_name': b.hallName,
      'junwang': b.junwang,
      'ancestor_name': b.ancestorName,
      'generation_poem': b.generationPoem,
      'preface': b.preface,
      'family_rules': b.familyRules,
      'editing_notes': b.editingNotes,
      'cover_color': b.coverColor,
      'cover_pattern': b.coverPattern,
      'parent_book_id': b.parentBookId,
      'branch_root_uid': b.branchRootUid,
      'family_id': b.familyId,
      'sync_mode': b.syncMode,
      'cloud_rev': b.cloudRev,
      'family_role': b.familyRole,
      'created_at': b.createdAt,
      'updated_at': b.updatedAt
    };
    return v;
  }

  /** 从数据库重新加载族谱列表与当前族谱的全部数据 */
  async reload(): Promise<void> {
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    // 1. 族谱列表（多族谱）
    const books: Genealogy[] = [];
    const bookRs: relationalStore.ResultSet = await store.querySql(`SELECT * FROM ${TABLE_BOOK} ORDER BY id`);
    try {
      while (bookRs.goToNextRow()) {
        books.push(this.rowToBook(bookRs));
      }
    } finally {
      bookRs.close();
    }
    this.books = books;
    let current: Genealogy | null = null;
    for (let i: number = 0; i < books.length; i++) {
      if (books[i].key === this.currentBookId) {
        current = books[i];
        break;
      }
    }
    if (current === null && books.length > 0) {
      this.currentBookId = books[0].key;
      await this.setMeta(META_CURRENT_BOOK, this.currentBookId.toString());
      current = books[0];
    }
    if (current === null) {
      // 无族谱记录：保持空状态，不再自动创建默认族谱
      this.currentBookId = 0;
      const empty: Genealogy = createEmptyGenealogy();
      empty.key = 0;
      empty.title = '';
      this.book = empty;
    } else {
      this.book = current;
    }

    // 2. 当前族谱的族人（按 book_id 隔离，墓碑不参与展示）
    const t0: number = Date.now();
    const list: Person[] = await this.queryPeople(this.currentBookId);
    const t1: number = Date.now();
    this.people = list;
    const map: Map<string, Person> = new Map<string, Person>();
    list.forEach((p: Person): void => {
      map.set(p.uid.trim().toUpperCase(), p);
    });
    this.peopleMap = map;
    await this.attachSpouses(this.currentBookId, list);
    const t2: number = Date.now();
    this.retiredUids = await this.loadRetired(this.currentBookId);
    const t3: number = Date.now();
    this.roots = TreeBuilder.build(this.people);
    const t4: number = Date.now();
    // 诊断：无父母孤儿 / 父母引用指向不存在 uid 的人数，用于判断谱系断链来源
    let orphan: number = 0;
    let dangling: number = 0;
    for (let i: number = 0; i < list.length; i++) {
      const p: Person = list[i];
      const f: string = p.fatherId.trim().toUpperCase();
      const m: string = p.motherId.trim().toUpperCase();
      if (f.length === 0 && m.length === 0) {
        orphan = orphan + 1;
      }
      if (f.length > 0 && !map.has(f)) {
        dangling = dangling + 1;
      }
      if (m.length > 0 && !map.has(m)) {
        dangling = dangling + 1;
      }
    }
    // 诊断：从根节点出发（子女 + 配偶）能到达多少人，与总人数对比可判断谱系是否漏人
    const reached: Set<string> = new Set<string>();
    const stack: PersonNode[] = [];
    for (let i: number = 0; i < this.roots.length; i++) {
      stack.push(this.roots[i]);
    }
    while (stack.length > 0) {
      const n: PersonNode = stack.pop() as PersonNode;
      const u: string = n.uid.trim().toUpperCase();
      if (reached.has(u)) {
        continue;
      }
      reached.add(u);
      for (let i: number = 0; i < n.children.length; i++) {
        stack.push(n.children[i]);
      }
      for (let i: number = 0; i < n.spouses.length; i++) {
        stack.push(n.spouses[i]);
      }
    }
    const unreachable: number = list.length - reached.size;
    hilog.info(0x0000, TAG,
      'reload people=%{public}d roots=%{public}d reachable=%{public}d unreachable=%{public}d orphan=%{public}d dangling=%{public}d query=%{public}dms spouse=%{public}dms retired=%{public}dms tree=%{public}dms',
      list.length, this.roots.length, reached.size, unreachable, orphan, dangling,
      t1 - t0, t2 - t1, t3 - t2, t4 - t3);
    // 切换/加载族谱后同步协作态（familyId / 角色 / 同步模式）
    FamilyService.getInstance().applyBookFamilyState();
    this.bump();
  }

  /** 读取数据库中的族谱行 */
  private rowToBook(rs: relationalStore.ResultSet): Genealogy {
    const b: Genealogy = createEmptyGenealogy();
    b.key = rs.getLong(rs.getColumnIndex('id'));
    b.title = rs.getString(rs.getColumnIndex('title'));
    b.surname = rs.getString(rs.getColumnIndex('surname'));
    b.hallName = rs.getString(rs.getColumnIndex('hall_name'));
    b.junwang = rs.getString(rs.getColumnIndex('junwang'));
    b.ancestorName = rs.getString(rs.getColumnIndex('ancestor_name'));
    b.generationPoem = rs.getString(rs.getColumnIndex('generation_poem'));
    b.preface = rs.getString(rs.getColumnIndex('preface'));
    b.familyRules = rs.getString(rs.getColumnIndex('family_rules'));
    b.editingNotes = rs.getString(rs.getColumnIndex('editing_notes'));
    b.coverColor = rs.getString(rs.getColumnIndex('cover_color'));
    b.coverPattern = rs.getString(rs.getColumnIndex('cover_pattern'));
    b.parentBookId = rs.getLong(rs.getColumnIndex('parent_book_id'));
    const rootUid: string = rs.getString(rs.getColumnIndex('branch_root_uid'));
    b.branchRootUid = rootUid === null ? '' : rootUid;
    b.familyId = readBookText(rs, 'family_id');
    b.syncMode = readBookText(rs, 'sync_mode');
    b.familyRole = readBookText(rs, 'family_role');
    const cloudRevCol: number = rs.getColumnIndex('cloud_rev');
    b.cloudRev = cloudRevCol >= 0 ? rs.getLong(cloudRevCol) : 0;
    b.createdAt = rs.getLong(rs.getColumnIndex('created_at'));
    b.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
    return b;
  }

  /** 读取指定族谱的人物行（墓碑 deleted_at > 0 的不返回） */
  private async queryPeople(bookId: number): Promise<Person[]> {
    const list: Person[] = [];
    if (this.store === null || bookId <= 0) {
      return list;
    }
    const store: relationalStore.RdbStore = this.store;
    // 族人可达数万行：按 id 递增分批读取，避免单次 ResultSet 超过共享内存块的行数/容量上限
    let lastId: number = 0;
    let more: boolean = true;
    while (more) {
      const resultSet: relationalStore.ResultSet = await store.querySql(
        `SELECT * FROM ${TABLE_PERSON} WHERE book_id = ? AND (deleted_at IS NULL OR deleted_at = 0) AND id > ? ORDER BY id LIMIT ${QUERY_PAGE_SIZE}`,
        [bookId, lastId]);
      let readRows: number = 0;
      try {
        while (resultSet.goToNextRow()) {
          const p: Person = createEmptyPerson();
          p.key = resultSet.getLong(resultSet.getColumnIndex('id'));
          p.uid = resultSet.getString(resultSet.getColumnIndex('uid'));
          p.generation = resultSet.getLong(resultSet.getColumnIndex('generation'));
          p.name = resultSet.getString(resultSet.getColumnIndex('name'));
          p.alias = resultSet.getString(resultSet.getColumnIndex('alias'));
          p.gender = resultSet.getString(resultSet.getColumnIndex('gender'));
          p.generationChar = resultSet.getString(resultSet.getColumnIndex('generation_char'));
          p.lifeStatus = resultSet.getString(resultSet.getColumnIndex('life_status'));
          const cs: string = resultSet.getString(resultSet.getColumnIndex('child_status'));
          p.childStatus = (cs === null || cs.length === 0) ? '未记' : cs;
          p.birthDate = resultSet.getString(resultSet.getColumnIndex('birth_date'));
          p.birthCalendar = resultSet.getString(resultSet.getColumnIndex('birth_calendar'));
          p.deathDate = resultSet.getString(resultSet.getColumnIndex('death_date'));
          p.deathCalendar = resultSet.getString(resultSet.getColumnIndex('death_calendar'));
          p.birthPlace = resultSet.getString(resultSet.getColumnIndex('birth_place'));
          p.residence = resultSet.getString(resultSet.getColumnIndex('residence'));
          p.fatherId = resultSet.getString(resultSet.getColumnIndex('father_id'));
          p.motherId = resultSet.getString(resultSet.getColumnIndex('mother_id'));
          p.spouseId = resultSet.getString(resultSet.getColumnIndex('spouse_id'));
          p.rank = resultSet.getString(resultSet.getColumnIndex('rank'));
          p.adoption = resultSet.getString(resultSet.getColumnIndex('adoption'));
          p.education = resultSet.getString(resultSet.getColumnIndex('education'));
          p.occupation = resultSet.getString(resultSet.getColumnIndex('occupation'));
          p.biography = resultSet.getString(resultSet.getColumnIndex('biography'));
          p.graveInfo = resultSet.getString(resultSet.getColumnIndex('grave_info'));
          p.graveLng = resultSet.getDouble(resultSet.getColumnIndex('grave_lng'));
          p.graveLat = resultSet.getDouble(resultSet.getColumnIndex('grave_lat'));
          p.graveAltitude = resultSet.getDouble(resultSet.getColumnIndex('grave_altitude'));
          p.phone = resultSet.getString(resultSet.getColumnIndex('phone'));
          p.wechat = resultSet.getString(resultSet.getColumnIndex('wechat'));
          p.avatar = resultSet.getString(resultSet.getColumnIndex('avatar'));
          p.videos = resultSet.getString(resultSet.getColumnIndex('videos'));
          p.photos = resultSet.getString(resultSet.getColumnIndex('photos'));
          p.createdAt = resultSet.getLong(resultSet.getColumnIndex('created_at'));
          p.updatedAt = resultSet.getLong(resultSet.getColumnIndex('updated_at'));
          p.rev = readColumnLong(resultSet, 'rev');
          p.baseRev = readColumnLong(resultSet, 'base_rev');
          p.deletedAt = readColumnLong(resultSet, 'deleted_at');
          p.dirty = readColumnLong(resultSet, 'dirty') > 0;
          list.push(p);
          lastId = p.key;
          readRows = readRows + 1;
        }
      } finally {
        resultSet.close();
      }
      more = readRows >= QUERY_PAGE_SIZE;
    }
    list.sort((a: Person, b: Person): number => {
      if (a.generation !== b.generation) {
        return a.generation - b.generation;
      }
      return a.uid.localeCompare(b.uid);
    });
    return list;
  }

  /**
   * 为指定族谱的人物组装配偶关系。
   * 每条记录是“某人的配偶”，加载时同时为对方补一条反向记录，
   * 从而无论在哪一侧录入，双方详情与谱系都能识别；
   * 已存在直接记录时以直接记录的名分为准。
   */
  private async attachSpouses(bookId: number, people: Person[]): Promise<void> {
    const map: Map<string, Person> = new Map<string, Person>();
    people.forEach((p: Person): void => {
      map.set(p.uid.trim().toUpperCase(), p);
    });
    if (bookId <= 0 || this.store === null) {
      people.forEach((p: Person): void => {
        p.spouses = [];
      });
      return;
    }
    const store: relationalStore.RdbStore = this.store;
    const lists: Map<string, SpouseRelation[]> = new Map<string, SpouseRelation[]>();
    const seen: Map<string, Set<string>> = new Map<string, Set<string>>();
    // 配偶关系行可达数万行：按主键 (uid, spouse_uid) 递增分批读取，避免单次 ResultSet 撑爆共享内存块
    let lastUid: string = '';
    let lastSpouseUid: string = '';
    let more: boolean = true;
    while (more) {
      const rs: relationalStore.ResultSet = await store.querySql(
        `SELECT uid, spouse_uid, relation, level, ord FROM ${TABLE_SPOUSE} WHERE book_id = ? AND (uid > ? OR (uid = ? AND spouse_uid > ?)) ORDER BY uid, spouse_uid LIMIT ${QUERY_PAGE_SIZE}`,
        [bookId, lastUid, lastUid, lastSpouseUid]);
      let readRows: number = 0;
      try {
        while (rs.goToNextRow()) {
          const rawUid: string = rs.getString(rs.getColumnIndex('uid'));
          const rawSpouseUid: string = rs.getString(rs.getColumnIndex('spouse_uid'));
          const a: string = rawUid.trim().toUpperCase();
          const b: string = rawSpouseUid.trim().toUpperCase();
          const relation: string = rs.getString(rs.getColumnIndex('relation'));
          const ord: number = rs.getLong(rs.getColumnIndex('ord'));
          // 直接记录
          this.pushRelation(lists, seen, a, b, relation, ord, true);
          // 反向记录（名分未知，用于对方详情展示）
          this.pushRelation(lists, seen, b, a, '未记', ord, false);
          lastUid = rawUid;
          lastSpouseUid = rawSpouseUid;
          readRows = readRows + 1;
        }
      } finally {
        rs.close();
      }
      more = readRows >= QUERY_PAGE_SIZE;
    }
    people.forEach((p: Person): void => {
      const u: string = p.uid.trim().toUpperCase();
      const list: SpouseRelation[] | undefined = lists.get(u);
      if (list !== undefined) {
        // 原查询按 uid, ord 排序；分批按主键取回后恢复按 ord 的顺序，保证主配偶（spouses[0]）不变
        list.sort((x: SpouseRelation, y: SpouseRelation): number => x.order - y.order);
      }
      p.spouses = list !== undefined ? list : [];
      p.spouseId = p.spouses.length > 0 ? p.spouses[0].uid : '';
    });
  }

  /** 向某人名下追加一条配偶关系（去重，直接记录优先） */
  private pushRelation(lists: Map<string, SpouseRelation[]>, seen: Map<string, Set<string>>,
    owner: string, partner: string, relation: string, ord: number, direct: boolean): void {
    if (owner.length === 0 || partner.length === 0 || owner === partner) {
      return;
    }
    let set: Set<string> | undefined = seen.get(owner);
    if (set === undefined) {
      set = new Set<string>();
      seen.set(owner, set);
    }
    if (set.has(partner) && !direct) {
      return;
    }
    // 已有直接记录时，用新名分覆盖占位记录
    let list: SpouseRelation[] | undefined = lists.get(owner);
    if (list === undefined) {
      list = [];
      lists.set(owner, list);
    }
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].uid === partner) {
        if (direct) {
          list[i].relation = relation;
          list[i].level = spouseRelationLevel(relation);
          list[i].order = ord;
        }
        return;
      }
    }
    const r: SpouseRelation = new SpouseRelation();
    r.uid = partner;
    r.relation = relation;
    r.level = spouseRelationLevel(relation);
    r.order = ord;
    list.push(r);
    set.add(partner);
  }

  private async insertSeed(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const book: Genealogy = SeedData.defaultBook();
    const people: Person[] = SeedData.people();
    for (let i: number = 0; i < people.length; i++) {
      const p: Person = clonePerson(people[i]);
      p.uid = p.uid.trim().toUpperCase();
      this.normalizeSpouses(p);
      await this.upsertRow(p, this.currentBookId);
      await this.saveSpouses(p.uid, p.spouses, this.currentBookId);
    }
    hilog.info(0x0000, TAG, 'seed inserted: %{public}s %{public}d people', book.title, people.length);
  }

  private bump(): void {
    this.version++;
  }

  // ---------------------------------------------------------------- 协作

  /** 标记某人物本地有未上传修改 */
  private async markDirty(uid: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.executeSql(
      `UPDATE ${TABLE_PERSON} SET dirty = 1 WHERE book_id = ? AND UPPER(uid) = ?`,
      [this.currentBookId, uid.trim().toUpperCase()]);
  }

  /**
   * 记录「编辑前的快照」，供字段级 diff 生成 patch（§五.5 patchJson）。
   * 由编辑页在保存前调用。
   */
  captureBefore(uid: string): void {
    const p: Person | null = this.getPerson(uid);
    if (p !== null) {
      this.beforeSnapshots.set(uid.trim().toUpperCase(), clonePerson(p));
    }
  }

  getStore(): relationalStore.RdbStore | null {
    return this.store;
  }

  /**
   * 供协作层调用的「云端回放入口」（§七 GenealogyService.applyRemoteChange）。
   * 把云侧成员行写回本地 RDB：
   *   - deleted=true 视为墓碑：仅标记，不物理删除；
   *   - 隐私字段在 VIEWER/EDITOR 侧本就拿不到，保持本地原值不动；
   *   - 回放永远不写入 outbox（它不是本地修改）。
   */
  async applyRemoteChange(uid: string, person: Person | null, rev: number, deleted: boolean): Promise<boolean> {
    if (this.store === null) {
      return false;
    }
    const u: string = uid.trim().toUpperCase();
    if (u.length === 0) {
      return false;
    }
    const bookId: number = this.currentBookId;
    if (deleted) {
      const tomb: Person | null = this.getPerson(u);
      await this.store.executeSql(
        `UPDATE ${TABLE_PERSON} SET deleted_at = ?, rev = ?, base_rev = ?, dirty = 0 WHERE book_id = ? AND UPPER(uid) = ?`,
        [Date.now(), rev, rev, bookId, u]);
      // 墓碑同样要断开引用：否则其他族人的父亲/配偶仍指向这个已删除编号，
      // 一旦该编号被新族人复用，旧关系就会挂到新人身上。
      await this.store.executeSql(`UPDATE ${TABLE_PERSON} SET father_id = '' WHERE book_id = ? AND UPPER(father_id) = ?`,
        [bookId, u]);
      await this.store.executeSql(`UPDATE ${TABLE_PERSON} SET mother_id = '' WHERE book_id = ? AND UPPER(mother_id) = ?`,
        [bookId, u]);
      await this.store.executeSql(`UPDATE ${TABLE_PERSON} SET spouse_id = '' WHERE book_id = ? AND UPPER(spouse_id) = ?`,
        [bookId, u]);
      await this.store.executeSql(
        `DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ? AND (UPPER(uid) = ? OR UPPER(spouse_uid) = ?)`,
        [bookId, u, u]);
      // 云端墓碑的编号同样封存，后续新增不得复用
      await this.recordRetired(u, tomb === null ? '' : tomb.name);
      return true;
    }
    const exist: Person | null = this.getPerson(u);
    const p: Person = person !== null ? clonePerson(person) : createEmptyPerson();
    p.uid = u;
    if (exist !== null) {
      if (p.phone.length === 0) {
        p.phone = exist.phone;
      }
      if (p.wechat.length === 0) {
        p.wechat = exist.wechat;
      }
      if (p.residence.length === 0) {
        p.residence = exist.residence;
      }
      p.key = exist.key;
      p.createdAt = exist.createdAt > 0 ? exist.createdAt : p.createdAt;
    }
    this.normalizeSpouses(p);
    await this.upsertRow(p, bookId);
    await this.saveSpouses(p.uid, p.spouses, bookId);
    await this.store.executeSql(
      `UPDATE ${TABLE_PERSON} SET rev = ?, base_rev = ?, dirty = 0, deleted_at = 0 WHERE book_id = ? AND UPPER(uid) = ?`,
      [rev, rev, bookId, u]);
    return true;
  }

  /** 回放完成后刷新内存与界面 */
  async reloadAfterReplay(): Promise<void> {
    await this.reload();
  }

  /** 本地某部族谱的云端基线 rev */
  setBookCloudState(familyId: string, mode: string, role: string, rev: number): void {
    if (this.store === null || this.currentBookId <= 0) {
      return;
    }
    this.book.familyId = familyId;
    this.book.syncMode = mode;
    this.book.familyRole = role;
    this.book.cloudRev = rev;
    this.store.executeSql(
      `UPDATE ${TABLE_BOOK} SET family_id = ?, sync_mode = ?, family_role = ?, cloud_rev = ? WHERE id = ?`,
      [familyId, mode, role, rev, this.currentBookId]);
  }

  /** 当前族谱的云端基线 rev */
  currentCloudRev(): number {
    return this.book.cloudRev;
  }

  /** 墓碑查询：某人是否已被删除 */
  isDeleted(uid: string): boolean {
    const p: Person | undefined = this.peopleMap.get(uid.trim().toUpperCase());
    return p !== undefined && p.deletedAt > 0;
  }

  /** 本地写入后把变更推给协作层（在线→云函数，离线→outbox） */
  private async notifyPersonChange(op: string, changed: Person, originalUid: string | null): Promise<void> {
    if (this.book.familyId.length === 0) {
      return;
    }
    let before: Person | null = null;
    if (originalUid !== null) {
      const snap: Person | undefined = this.beforeSnapshots.get(originalUid.trim().toUpperCase());
      before = snap !== undefined ? snap : null;
    }
    const patchJson: string = buildPersonPatch(before, changed, op);
    const baseRev: number = changed.baseRev > 0 ? changed.baseRev : this.book.cloudRev;
    try {
      const result: string = await FamilyService.getInstance()
        .afterPersonSaved(op, changed.uid, changed.name, patchJson, baseRev);
      if (result === 'queued') {
        await this.markDirty(changed.uid);
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'notify cloud change failed: %{public}s', JSON.stringify(err));
    }
  }
}

/** 读取可能不存在的文本列 */
function readBookText(rs: relationalStore.ResultSet, column: string): string {
  const idx: number = rs.getColumnIndex(column);
  if (idx < 0) {
    return '';
  }
  const v: string = rs.getString(idx);
  return v === null || v === undefined ? '' : v;
}

/** 读取可能不存在的数字列 */
function readColumnLong(rs: relationalStore.ResultSet, column: string): number {
  const idx: number = rs.getColumnIndex(column);
  if (idx < 0) {
    return 0;
  }
  return rs.getLong(idx);
}
