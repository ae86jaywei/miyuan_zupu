import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Person, SpouseRelation, clonePerson, cloneSpouseRelation, createEmptyPerson, spouseRelationLevel } from '../model/Person';
import { Genealogy, createEmptyGenealogy } from '../model/Genealogy';
import { PersonNode } from '../model/PersonNode';
import { GenerationStat, GenealogyStats } from '../model/Stats';
import { IdGenerator } from '../util/IdGenerator';
import { parseYear } from '../util/DateUtil';
import { generationLabel } from '../model/Enums';
import { TreeBuilder } from './TreeBuilder';
import { SeedData } from './SeedData';

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
  private roots: PersonNode[] = [];
  private version: number = 0;
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
      // 应用元数据表：记录首次初始化标记，避免用户删除族谱后重启时重新写入演示数据
      await this.store.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE_META} (
        key TEXT PRIMARY KEY,
        value TEXT
      )`);
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
      // 旧数据迁移：把 person.spouse_id 单值转换成配偶关系行（幂等）
      await this.migrateSpouses();
      // 回填配偶关系等级（旧行 level 为空）
      await this.backfillSpouseLevels();
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
      person.uid = IdGenerator.next(this.people, person.gender);
    }
    person.uid = person.uid.trim().toUpperCase();
    person.createdAt = Date.now();
    person.updatedAt = person.createdAt;
    this.normalizeSpouses(person);
    await this.upsertRow(person);
    await this.saveSpouses(person.uid, person.spouses);
    await this.reload();
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
    await this.reload();
    return person;
  }

  /** 删除人物（其子女自动上提为无父/无母，不删除其他人物） */
  async deletePerson(uid: string): Promise<void> {
    const u: string = uid.trim().toUpperCase();
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_PERSON);
    predicates.equalTo('uid', u);
    predicates.and().equalTo('book_id', this.currentBookId);
    await store.delete(predicates);
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
  }

  /** 批量新增（导入使用），失败信息返回 */
  async importPeople(list: Person[], mergeStrategy: string): Promise<number> {
    if (this.currentBookId <= 0) {
      throw new Error('请先在「谱系」中创建族谱');
    }
    let count: number = 0;
    for (let i: number = 0; i < list.length; i++) {
      const p: Person = clonePerson(list[i]);
      p.uid = p.uid.trim().toUpperCase();
      this.normalizeSpouses(p);
      const exist: Person | undefined = this.peopleMap.get(p.uid);
      if (exist !== undefined) {
        if (mergeStrategy === 'skip') {
          continue;
        }
        if (mergeStrategy === 'replace') {
          p.key = exist.key;
          await this.upsertRow(p);
          await this.saveSpouses(p.uid, p.spouses);
          count++;
          continue;
        }
        if (mergeStrategy === 'newId') {
          p.uid = IdGenerator.next(this.people, p.gender);
        }
      }
      await this.upsertRow(p);
      await this.saveSpouses(p.uid, p.spouses);
      count++;
      // 每 50 条刷新一次，避免内存映射未更新导致 ID 重复
      if (count % 50 === 0) {
        await this.reload();
      }
    }
    await this.reload();
    return count;
  }

  /** 全量替换当前族谱的人物（恢复备份） */
  async replaceAll(list: Person[]): Promise<void> {
    if (this.currentBookId <= 0) {
      throw new Error('请先在「谱系」中创建族谱');
    }
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    await store.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [this.currentBookId]);
    await store.executeSql(`DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ?`, [this.currentBookId]);
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
    this.currentBookId = bookId;
    await this.setMeta(META_CURRENT_BOOK, bookId.toString());
    await this.reload();
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
      'updated_at': p.updatedAt
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

    // 2. 当前族谱的族人（按 book_id 隔离）
    const list: Person[] = await this.queryPeople(this.currentBookId);
    this.people = list;
    const map: Map<string, Person> = new Map<string, Person>();
    list.forEach((p: Person): void => {
      map.set(p.uid.trim().toUpperCase(), p);
    });
    this.peopleMap = map;
    await this.attachSpouses(this.currentBookId, list);
    this.roots = TreeBuilder.build(this.people);
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
    b.createdAt = rs.getLong(rs.getColumnIndex('created_at'));
    b.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
    return b;
  }

  /** 读取指定族谱的人物行 */
  private async queryPeople(bookId: number): Promise<Person[]> {
    const list: Person[] = [];
    if (this.store === null || bookId <= 0) {
      return list;
    }
    const store: relationalStore.RdbStore = this.store;
    const resultSet: relationalStore.ResultSet = await store.querySql(
      `SELECT * FROM ${TABLE_PERSON} WHERE book_id = ?`, [bookId]);
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
        list.push(p);
      }
    } finally {
      resultSet.close();
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
   * 已存在直接记录时以直接记录的名分为准（先处理直接记录）。
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
    const edges: SpouseEdge[] = [];
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT uid, spouse_uid, relation, level, ord FROM ${TABLE_SPOUSE} WHERE book_id = ? ORDER BY uid, ord`,
      [bookId]);
    try {
      while (rs.goToNextRow()) {
        const e: SpouseEdge = new SpouseEdge();
        e.uid = rs.getString(rs.getColumnIndex('uid')).trim().toUpperCase();
        e.spouseUid = rs.getString(rs.getColumnIndex('spouse_uid')).trim().toUpperCase();
        const rel: string = rs.getString(rs.getColumnIndex('relation'));
        e.relation = rel === null ? '' : rel;
        const lv: string = rs.getString(rs.getColumnIndex('level'));
        e.level = lv === null ? '' : lv;
        e.ord = rs.getLong(rs.getColumnIndex('ord'));
        edges.push(e);
      }
    } finally {
      rs.close();
    }
    const lists: Map<string, SpouseRelation[]> = new Map<string, SpouseRelation[]>();
    const seen: Map<string, Set<string>> = new Map<string, Set<string>>();
    edges.forEach((e: SpouseEdge): void => {
      this.pushRelation(lists, seen, e.uid, e.spouseUid, e.relation, e.level, e.ord);
    });
    edges.forEach((e: SpouseEdge): void => {
      const owner: Person | undefined = map.get(e.spouseUid);
      if (owner === undefined) {
        return;
      }
      const label: string = owner.gender === '女' ? '夫' : '配偶';
      this.pushRelation(lists, seen, e.spouseUid, e.uid, label, '', e.ord);
    });
    people.forEach((p: Person): void => {
      const arr: SpouseRelation[] | undefined = lists.get(p.uid.trim().toUpperCase());
      p.spouses = arr === undefined ? [] : arr;
      p.spouseId = p.spouses.length > 0 ? p.spouses[0].uid : '';
    });
  }

  private pushRelation(lists: Map<string, SpouseRelation[]>, seen: Map<string, Set<string>>,
    owner: string, partner: string, relation: string, level: string, ord: number): void {
    if (owner.length === 0 || partner.length === 0 || owner === partner) {
      return;
    }
    let seenSet: Set<string> | undefined = seen.get(owner);
    if (seenSet === undefined) {
      seenSet = new Set<string>();
      seen.set(owner, seenSet);
    }
    if (seenSet.has(partner)) {
      return;
    }
    seenSet.add(partner);
    let arr: SpouseRelation[] | undefined = lists.get(owner);
    if (arr === undefined) {
      arr = [];
      lists.set(owner, arr);
    }
    const r: SpouseRelation = new SpouseRelation();
    r.uid = partner;
    r.relation = relation.trim().length > 0 ? relation.trim() : '未记';
    r.level = level.trim().length > 0 ? level.trim() : spouseRelationLevel(r.relation);
    r.order = ord > 0 ? ord : arr.length + 1;
    arr.push(r);
  }

  private async insertSeed(): Promise<void> {
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const seed: Person[] = SeedData.people();
    for (let i: number = 0; i < seed.length; i++) {
      await store.insert(TABLE_PERSON, this.toValues(seed[i]));
    }
  }

  private bump(): void {
    this.version = this.version + 1;
  }
}
