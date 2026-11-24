import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Person, SpouseRelation, clonePerson, createEmptyPerson, normalizeSpouseRelations, spouseRelationLevel, normalizeSpouseRelation, SPOUSE_RELATIONS } from 'common_base';
import { PersonIndex } from 'common_base';
import { TreeLayoutCache } from 'common_base';
import { Genealogy, createEmptyGenealogy } from 'common_base';
import { PersonNode } from 'common_base';
import { GenealogyStats } from 'common_base';
import { IdGenerator } from 'common_base';
import { StatsCalculator } from './StatsCalculator';
import { PeopleStore } from './PeopleStore';
import { SpouseRelations } from './SpouseRelations';
import { PersonQuery } from './PersonQuery';
import { PersonEditor } from './PersonEditor';
import { PersonRepository } from './PersonRepository';
import { CloudReplay, RemoteWrite } from './CloudReplay';
import { CloudCollaboration } from './CloudCollaboration';
import { BookManager } from './BookManager';
import { BookHost } from './BookManager';
import { ImportManager } from './ImportManager';
import { ImportHost } from './ImportManager';
import { BranchManager } from './BranchManager';
import { BranchHost } from './BranchManager';
import { RestoreManager } from './RestoreManager';
import { RestoreHost } from './RestoreManager';
import { BookGroup } from './RestoreManager';
import { PersonSearch } from './PersonSearch';

import { SeedData } from './SeedData';
import { OutboxService } from './OutboxService';
import { FamilyService } from './FamilyService';
import { IntegrityService } from './IntegrityService';
import { IntegrityReport, IntegrityIssue } from 'common_base';
import { ImportPlan, ImportOptions, ImportPlanner, ImportResult } from './ImportPlanner';
import { RelationGraph, RepairReport } from 'common_base';
import { DatabaseSchema, TABLE_BOOK, TABLE_META, TABLE_PERSON, TABLE_SPOUSE } from './db/DatabaseSchema';
import { PersonRowMapper } from './db/PersonRowMapper';
import { BookRowMapper } from './BookRowMapper';

const TAG: string = '[Genealogy][Service]';
const DB_NAME: string = 'genealogy.db';
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
/**
 * 分支建议：第 5 世左右、后代规模过大、适合另立分支谱的节点。
 * 只用于导出页提示，不自动移动数据。
 */
export class BranchSuggestion {
  uid: string = '';
  name: string = '';
  generation: number = 0;
  descendants: number = 0;
}

export class GenealogyService implements BookHost, ImportHost, BranchHost, RestoreHost {
  private static instance: GenealogyService | null = null;

  private store: relationalStore.RdbStore | null = null;
  /** 人员数据存储：统一持有列表/uid 映射/宗支根/版本，供后续子域服务共享 */
  private peopleStore: PeopleStore = new PeopleStore();
  /** 配偶关系域：查询、文案与内存态反向引用 */
  private spouseRelations: SpouseRelations = new SpouseRelations(this.peopleStore);
  /** 人员关系查询域：子女、兄弟姊妹、上下三代 */
  private personQuery: PersonQuery = new PersonQuery(this.peopleStore);
  /** 人员索引：加速搜索和跳转 */
  private index: PersonIndex = new PersonIndex();
  /** 编辑事务内存态刷新域：保存后的增量更新 */
  private personEditor: PersonEditor = new PersonEditor(this.peopleStore, this.spouseRelations, this.index);
  /** 人员仓储域：人员行与配偶关系的数据库读写 */
  private personRepository: PersonRepository = new PersonRepository(
    (): relationalStore.RdbStore | null => this.store,
    (): number => this.currentBookId,
    this.peopleStore);
  /** 云回放域：云侧成员行写回本地与回放后刷新 */
  private cloudReplay: CloudReplay = new CloudReplay(
    (): relationalStore.RdbStore | null => this.store,
    (): number => this.currentBookId,
    this.peopleStore,
    this.personRepository,
    (uid: string, name: string): Promise<void> => this.recordRetired(uid, name),
    (): Promise<void> => this.reload());
  /** 协作通知域：云端同步触发、编辑前快照与脏标记 */
  private cloudCollaboration: CloudCollaboration = new CloudCollaboration(
    this.peopleStore,
    (): Genealogy => this.book,
    (): relationalStore.RdbStore | null => this.store,
    (): number => this.currentBookId);
  /** 族谱管理域：保存、新建、切换、删除 */
  private bookManager: BookManager = new BookManager(this);
  /** 导入编排域：批量新增、导入计划与落库 */
  private importManager: ImportManager = new ImportManager(this, this.peopleStore, this.personRepository);
  /** 分支谱域：建支与原谱异步清理 */
  private branchManager: BranchManager = new BranchManager(this);
  /** 云恢复域：云端分组全量重建 */
  private restoreManager: RestoreManager = new RestoreManager(this, this.personRepository);
  private book: Genealogy = createEmptyGenealogy();
  /** 全部族谱元信息（支持多族谱管理） */
  private books: Genealogy[] = [];
  /** 当前打开的族谱ID（0 表示无族谱） */
  private currentBookId: number = 0;
  /** 当前族谱中已删除人员的编号（uid → 原姓名），新增人员时不得复用 */
  private retiredUids: Map<string, string> = new Map<string, string>();
  /** 全量统计缓存：概览页 build 内会多次调用 computeStats，8 万人单次需数百毫秒，按版本号复用 */
  private statsCache: GenealogyStats | null = null;
  private statsCacheVersion: number = -1;
  private ready: boolean = false;
  private initPromise: Promise<void> | null = null;
  /** 搜索与跳转索引域：访问门面 */
  private personSearch: PersonSearch = new PersonSearch(this.index, (): Person[] => this.peopleStore.getAll());

  private constructor() {
    // 布局缓存位于公共层，数据身份（族谱ID#数据版本）由本服务注入，避免公共层反向依赖业务服务
    TreeLayoutCache.getInstance().setScopeProvider((): string => {
      return this.currentBookId.toString() + '#' + this.peopleStore.getVersion().toString();
    });
  }

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
    return this.peopleStore.getVersion();
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
      await DatabaseSchema.createTables(this.store as relationalStore.RdbStore);
      // 协作变更队列（断网可编辑：写操作先落本地并在此排队，方案 §四 原则 1）
      await OutboxService.getInstance().ensureTable(this.store);
      // 注意：ResultSet.rowCount 是“游标当前行号”（初始 -1），并非行数，
      // 必须真正游标读取一次才能拿到 COUNT(*) 的值。
      const count: number = await this.countRows();
      const initialized: boolean = (await this.getMeta(META_INITIALIZED)) === '1';
      if (!initialized) {
        // 仅首次初始化时写入演示数据；已有旧库（有族人）时只补标记，不重复写入
        const hasBook: boolean = await this.hasBookRow();
        if (!hasBook) {
          try {
            // 先建族谱元信息，拿到族谱ID后再写入演示族人（带 book_id）
            const rowId: number = await this.store.insert(TABLE_BOOK, PersonRowMapper.bookValues(SeedData.defaultBook()));
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
      await DatabaseSchema.migrateSpouseBookColumn(this.store as relationalStore.RdbStore, this.currentBookId);
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
      // 旧库迁移：唯一ID 性别前缀改为「男 M / 女 F」，互换已有族人及其全部引用。
      // 迁移失败时保持旧数据可正常打开（ID 只是文本），下次启动会自动重试。
      try {
        await DatabaseSchema.migrateGenderUidPrefix(this.store as relationalStore.RdbStore);
      } catch (e) {
        const me = e as BusinessError;
        hilog.error(0x0000, TAG, 'swap uid prefix failed %{public}d %{public}s', me.code, me.message);
      }
      await this.reload();
      this.ready = true;
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
  async ensureCurrentBook(): Promise<void> {
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

  // ---------------------------------------------------------------- 查询

  getPeople(): Person[] {
    return this.peopleStore.getAll();
  }

  /** 返回副本，供编辑页使用 */
  getPeopleCopy(): Person[] {
    return this.peopleStore.getAll().map((p: Person): Person => clonePerson(p));
  }

  getPerson(uid: string): Person | null {
    return this.peopleStore.getPerson(uid);
  }

  getRoots(): PersonNode[] {
    return this.peopleStore.getRoots();
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
    return IdGenerator.next(this.peopleStore.getAll(), gender, reserved);
  }

  /** 当前族谱的数据一致性体检（重复ID、关系悬空、世代/性别/日期错位、编号复用） */
  checkIntegrity(): IntegrityReport {
    const report: IntegrityReport = IntegrityService.check(this.peopleStore.getAll(), this.book.title);
    report.merge(IntegrityService.reused(this.peopleStore.getAll(), this.retiredUids));
    report.merge(IntegrityService.reusedReferences(this.peopleStore.getAll(), this.retiredUids));
    return report;
  }

  /** 导入合并前的综合体检 */
  checkImport(list: Person[]): IntegrityReport {
    return IntegrityService.incoming(list, this.peopleStore.getAll(), this.retiredUids);
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
  async clearRetired(bookId: number): Promise<void> {
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

  /** 模糊搜索：谱名 / 曾用名 / 唯一ID / 辈分字 / 出生地 / 职业（使用索引加速） */
  search(keyword: string): Person[] {
    return this.personSearch.search(keyword);
  }

  /** 按 UID 快速查找（使用索引，O(1) 复杂度） */
  getByUid(uid: string): Person | null {
    return this.personSearch.getByUid(uid);
  }

  /** 设置跳转索引（行号） */
  setJumpRow(uid: string, row: number): void {
    this.personSearch.setJumpRow(uid, row);
  }

  /** 获取跳转索引（行号） */
  getJumpRow(uid: string): number {
    return this.personSearch.getJumpRow(uid);
  }

  /** 设置牒记式页码 */
  setDiePage(uid: string, page: number): void {
    this.personSearch.setDiePage(uid, page);
  }

  /** 获取牒记式页码 */
  getDiePage(uid: string): number {
    return this.personSearch.getDiePage(uid);
  }

  /** 清空跳转索引（谱式切换时调用） */
  clearJumpIndex(): void {
    this.personSearch.clearJumpIndex();
  }

  /** 子女 */
  childrenOf(uid: string): Person[] {
    return this.personQuery.childrenOf(uid);
  }

  /** 某人与指定配偶共同生育的子女（父母双方均匹配） */
  childrenWithSpouse(uid: string, spouseUid: string): Person[] {
    return this.personQuery.childrenWithSpouse(uid, spouseUid);
  }

  /** 兄弟姊妹（不含本人） */
  siblingsOf(uid: string): Person[] {
    return this.personQuery.siblingsOf(uid);
  }

  /** 当前人物的全部配偶关系（含元配/继室/妾等名分，按顺序排列） */
  spousesOf(uid: string): SpouseRelation[] {
    return this.spouseRelations.spousesOf(uid);
  }

  /** 主配偶（第一位） */
  spouseOf(uid: string): Person | null {
    return this.spouseRelations.spouseOf(uid);
  }

  /** 配偶展示文案，如：“配 林氏、继室 陈氏、妾 李氏” */
  spouseTextOf(uid: string): string {
    return this.spouseRelations.spouseTextOf(uid);
  }

  /** 上下三代（含自身），用于详情页关系链 */
  relativesOf(uid: string): Person[] {
    return this.personQuery.relativesOf(uid);
  }

  /** 按世代分组 */
  groupByGeneration(filterFn?: (p: Person) => boolean): Map<number, Person[]> {
    return StatsCalculator.groupByGeneration(this.peopleStore.getAll(), filterFn);
  }

  /** 全部字派（去重） */
  generationChars(): string[] {
    return StatsCalculator.generationChars(this.peopleStore.getAll());
  }

  // ---------------------------------------------------------------- 统计

  computeStats(filterFn?: (p: Person) => boolean): GenealogyStats {
    // 全量统计按版本号缓存：比例页/概览页会在 build 内反复调用，切页重建组件时也要能命中
    if (filterFn === undefined && this.statsCache !== null && this.statsCacheVersion === this.peopleStore.getVersion()) {
      return this.statsCache as GenealogyStats;
    }
    const stats: GenealogyStats = StatsCalculator.compute(this.peopleStore.getAll(), filterFn);
    if (filterFn === undefined) {
      this.statsCache = stats;
      this.statsCacheVersion = this.peopleStore.getVersion();
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
    normalizeSpouseRelations(person);
    await this.personRepository.upsert(person);
    await this.personRepository.saveSpouses(person.uid, person.spouses);
    this.personEditor.applySaved(person, '');
    try {
      await this.syncSpouseIdentities(person);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'syncSpouseIdentities failed on add: %{public}s', JSON.stringify(err));
    }
    // 协作：本机先落库（唯一真相源），再按在线/离线走「云函数 / outbox」
    await this.cloudCollaboration.notifyPersonChange('ADD', person, null);
    return person;
  }

  /** 更新人物（按 uid 定位） */
  async updatePerson(p: Person, originalUid: string): Promise<Person> {
    const person: Person = clonePerson(p);
    person.uid = person.uid.trim().toUpperCase();
    person.updatedAt = Date.now();
    normalizeSpouseRelations(person);
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_PERSON);
    if (originalUid !== person.uid) {
      predicates.equalTo('uid', originalUid.trim().toUpperCase());
      predicates.and().equalTo('book_id', this.currentBookId);
    } else {
      predicates.equalTo('id', person.key);
    }
    const values: relationalStore.ValuesBucket = PersonRowMapper.toValues(person, this.currentBookId);
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
    await this.personRepository.saveSpouses(person.uid, person.spouses);
    this.personEditor.applySaved(person, originalUid);
    try {
      await this.syncSpouseIdentities(person);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'syncSpouseIdentities failed on update: %{public}s', JSON.stringify(err));
    }
    // 协作：同一人物的多次本地修改合并成一条 outbox（diff 相对编辑前快照）
    await this.cloudCollaboration.notifyPersonChange('UPDATE', person, originalUid);
    return person;
  }

  /** 删除人物（其子女自动上提为无父/无母，不删除其他人物） */
  async deletePerson(uid: string): Promise<void> {
    const u: string = uid.trim().toUpperCase();
    const deleted: Person | null = this.getPerson(u);
    const cloud: boolean = this.book.familyId.length > 0;
    await this.personRepository.deleteRows(u, cloud);
    if (deleted !== null) {
      // 记录该编号已被使用过，后续新增人员不再复用，避免旧关系挂到新族人身上
      await this.recordRetired(u, deleted.name);
    }
    await this.reload();
    if (cloud && deleted !== null) {
      await this.cloudCollaboration.notifyPersonChange('DELETE', deleted, null);
    }
  }

  /** 批量新增（导入使用），失败信息返回 */
  async importPeople(list: Person[], mergeStrategy: string): Promise<number> {
    return this.importManager.importPeople(list, mergeStrategy);
  }

  /**
   * 生成导入计划（纯内存，不落库）：身份匹配 + 全局 ID 重映射。
   * 具体策略见 ImportManager.planImport。
   */
  async planImport(list: Person[], strategy: string, asNewBook: boolean = false,
    onProgress?: (done: number, total: number) => void): Promise<ImportPlan> {
    return this.importManager.planImport(list, strategy, asNewBook, onProgress);
  }

  /**
   * 执行导入计划（事务、分批写入与关系修复见 ImportManager）。
   */
  async applyImportPlan(plan: ImportPlan,
    onProgress?: (done: number, total: number) => void): Promise<ImportResult> {
    return this.importManager.applyImportPlan(plan, onProgress);
  }

  /** 全量替换当前族谱的人物（恢复备份） */
  async replaceAll(list: Person[]): Promise<void> {
    await this.importManager.replaceAll(list);
  }

  async saveBook(book: Genealogy): Promise<void> {
    await this.bookManager.saveBook(book);
  }

  /** 新建一部空族谱（无族人），创建后自动切换为当前族谱 */
  async createGenealogy(title: string): Promise<Genealogy> {
    return this.bookManager.createGenealogy(title);
  }

  /** 是否已存在同名族谱（分支谱命名去重使用） */
  hasBookTitle(title: string): boolean {
    for (let i: number = 0; i < this.books.length; i++) {
      if (this.books[i].title === title) {
        return true;
      }
    }
    return false;
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


  /**
   * 以当前族谱中的某位族人为始祖，另立一部分支族谱。
   * 具体复制与清理语义见 BranchManager。
   */
  async createBranchFromPerson(rootUid: string,
    onProgress?: (done: number, total: number) => void): Promise<Genealogy> {
    return this.branchManager.createBranchFromPerson(rootUid, onProgress);
  }

  /**
   * 分支建议：
   *  - 第 5/10/15… 世；
   *  - 后代 ≥ 2000 人（整谱移动端无法一次导出）；
   *  - 子树深度 ≥ 3（避免拆出「三代内无子」的支）；
   *  - 已有分支谱的始祖不重复建议。
   */
  suggestBranches(): BranchSuggestion[] {
    const out: BranchSuggestion[] = [];
    const roots: PersonNode[] = this.getRoots();
    const built: Set<string> = new Set<string>();
    for (let i: number = 0; i < this.books.length; i = i + 1) {
      const b: Genealogy = this.books[i];
      if (b.parentBookId === this.currentBookId && b.branchRootUid.length > 0) {
        built.add(b.branchRootUid.trim().toUpperCase());
      }
    }
    const stack: PersonNode[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < roots.length; i = i + 1) {
      stack.push(roots[i]);
    }
    while (stack.length > 0) {
      const n: PersonNode = stack.pop() as PersonNode;
      if (seen.has(n.uid)) {
        continue;
      }
      seen.add(n.uid);
      for (let k: number = 0; k < n.children.length; k = k + 1) {
        stack.push(n.children[k]);
      }
      const gen: number = n.person.generation;
      // 单次建支上限 5000：只建议 1000~5000 人的房支，避免用户点了一个必然失败的大支
      if (gen < 5 || n.descendants < 1000 || n.descendants > 5000 ||
        n.height < 3 || n.children.length === 0) {
        continue;
      }
      if (built.has(n.uid.trim().toUpperCase())) {
        continue;
      }
      const s: BranchSuggestion = new BranchSuggestion();
      s.uid = n.uid;
      s.name = n.person.name.length > 0 ? n.person.name : n.uid;
      s.generation = gen;
      s.descendants = n.descendants;
      out.push(s);
    }
    out.sort((a: BranchSuggestion, b: BranchSuggestion): number => b.descendants - a.descendants);
    if (out.length > 5) {
      out.splice(5, out.length - 5);
    }
    return out;
  }

  /** 切换当前族谱，其他页面会跟随刷新 */
  async switchGenealogy(bookId: number): Promise<void> {
    await this.bookManager.switchGenealogy(bookId);
  }

  /**
   * 删除指定族谱（含该族谱的族人、配偶关系与元信息）。
   * 若删除的是当前族谱，自动切换到剩余族谱；全部删除后进入“无族谱”状态。
   */
  async deleteGenealogy(bookId: number = 0): Promise<void> {
    await this.bookManager.deleteGenealogy(bookId);
  }

  /**
   * 从云端恢复多部族谱：先清空本地族谱数据，再按云端分组逐部重建。
   * 具体恢复与父ID重映射见 RestoreManager。
   */
  async restoreFromCloud(groups: BookGroup[]): Promise<number> {
    return this.restoreManager.restoreFromCloud(groups);
  }

  /** 是否为明确的妻妾/配偶名分（不含“夫 / 未记”） */
  private static isSpouseIdentity(value: string): boolean {
    const v: string = normalizeSpouseRelation(value);
    return v !== '夫' && v !== '未记' && SPOUSE_RELATIONS.indexOf(v) >= 0;
  }

  /**
   * 配偶名分 ↔ 本人身份双向同步：
   *  - 丈夫给某位妻妾设“侧室/继室…” → 对方“身份”字段自动写成同名分；
   *  - 女方“身份”改为名分（如侧室）→ 丈夫配偶表里对她的称谓同步为该名分。
   * 只同步明确名分，未记/夫/空值不会覆盖已有人工数据。
   */
  private async syncSpouseIdentities(person: Person): Promise<void> {
    if (this.store === null) {
      return;
    }
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const self: string = person.uid.trim().toUpperCase();
    let changed: boolean = false;
    // 1. 本人（男）在配偶关系里写的名分 → 同步为对方（女）的身份
    if (person.gender === '男') {
      for (let i: number = 0; i < person.spouses.length; i = i + 1) {
        const rel: string = normalizeSpouseRelation(person.spouses[i].relation);
        if (!GenealogyService.isSpouseIdentity(rel)) {
          continue;
        }
        const partner: Person | undefined = this.peopleStore.getMap().get(person.spouses[i].uid.trim().toUpperCase());
        if (partner === undefined || partner.gender !== '女') {
          continue;
        }
        if (partner.childStatus === rel) {
          continue;
        }
        // 丈夫设定的名分就是妻子在家庭中的身份：对方“身份”字段跟随更新
        partner.childStatus = rel;
        await store.executeSql(
          `UPDATE ${TABLE_PERSON} SET child_status = ?, updated_at = ? WHERE book_id = ? AND UPPER(uid) = ?`,
          [rel, Date.now(), this.currentBookId, partner.uid.trim().toUpperCase()]);
        changed = true;
      }
    }
    // 2. 本人（女）的身份是名分 → 同步到丈夫配偶表里对她的称谓
    const own: string = normalizeSpouseRelation(person.childStatus);
    if (person.gender === '女' && GenealogyService.isSpouseIdentity(own)) {
      for (let i: number = 0; i < person.spouses.length; i = i + 1) {
        const husband: Person | undefined = this.peopleStore.getMap().get(person.spouses[i].uid.trim().toUpperCase());
        if (husband === undefined || husband.gender !== '男') {
          continue;
        }
        let found: boolean = false;
        for (let j: number = 0; j < husband.spouses.length; j = j + 1) {
          if (husband.spouses[j].uid.trim().toUpperCase() === self) {
            husband.spouses[j].relation = own;
            husband.spouses[j].level = spouseRelationLevel(own);
            found = true;
            break;
          }
        }
        if (!found) {
          const nr: SpouseRelation = new SpouseRelation();
          nr.uid = self;
          nr.relation = own;
          nr.level = spouseRelationLevel(own);
          nr.order = husband.spouses.length + 1;
          husband.spouses.push(nr);
        }
        const existing: string = await this.personRepository.spouseRowRelation(this.currentBookId, husband.uid, self);
        if (existing.length > 0) {
          await store.executeSql(
            `UPDATE ${TABLE_SPOUSE} SET relation = ?, level = ? WHERE book_id = ? AND UPPER(uid) = ? AND UPPER(spouse_uid) = ?`,
            [own, spouseRelationLevel(own), this.currentBookId, husband.uid.trim().toUpperCase(), self]);
        } else {
          const ord: number = await this.personRepository.nextSpouseOrd(this.currentBookId, husband.uid);
          await store.executeSql(
            `INSERT OR REPLACE INTO ${TABLE_SPOUSE}(book_id, uid, spouse_uid, relation, level, ord) VALUES(?, ?, ?, ?, ?, ?)`,
            [this.currentBookId, husband.uid.trim().toUpperCase(), self, own, spouseRelationLevel(own), ord]);
        }
        changed = true;
      }
    }
    if (changed) {
      this.bump();
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

  /** 从数据库重新加载族谱列表与当前族谱的全部数据 */
  async reload(): Promise<void> {
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    // 1. 族谱列表（多族谱）
    const books: Genealogy[] = [];
    const bookRs: relationalStore.ResultSet = await store.querySql(`SELECT * FROM ${TABLE_BOOK} ORDER BY id`);
    try {
      while (bookRs.goToNextRow()) {
        books.push(BookRowMapper.fromRow(bookRs));
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
    const list: Person[] = await this.queryPeople(this.currentBookId);
    this.peopleStore.setList(list);
    const map: Map<string, Person> = new Map<string, Person>();
    list.forEach((p: Person): void => {
      map.set(p.uid.trim().toUpperCase(), p);
    });
    this.peopleStore.setMap(map);
    await this.attachSpouses(this.currentBookId, list);
    this.retiredUids = await this.loadRetired(this.currentBookId);
    this.peopleStore.rebuildRoots();
    // 构建人员索引：加速搜索和跳转
    this.index.build(list);
    // 切换/加载族谱后同步协作态（familyId / 角色 / 同步模式）
    FamilyService.getInstance().applyBookFamilyState();
    this.bump();
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
          p.courtesyName = resultSet.getString(resultSet.getColumnIndex('courtesy_name'));
          p.artName = resultSet.getString(resultSet.getColumnIndex('art_name'));
          p.alias = resultSet.getString(resultSet.getColumnIndex('alias'));
          p.gender = resultSet.getString(resultSet.getColumnIndex('gender'));
          p.generationChar = resultSet.getString(resultSet.getColumnIndex('generation_char'));
          p.lifeStatus = resultSet.getString(resultSet.getColumnIndex('life_status'));
          const cs: string = resultSet.getString(resultSet.getColumnIndex('child_status'));
          p.childStatus = (cs === null || cs.length === 0) ? '未记' : cs;
          const cm: string = resultSet.getString(resultSet.getColumnIndex('child_mark'));
          p.childMark = (cm === null || cm.length === 0) ? '未记' : cm;
          p.childMarkTarget = resultSet.getString(resultSet.getColumnIndex('child_mark_target'));
          p.childMarkSource = resultSet.getString(resultSet.getColumnIndex('child_mark_source'));
          p.childMarkSeq = resultSet.getLong(resultSet.getColumnIndex('child_mark_seq'));
          p.childless = resultSet.getLong(resultSet.getColumnIndex('childless')) === 1;
          p.birthDate = resultSet.getString(resultSet.getColumnIndex('birth_date'));
          p.birthCalendar = resultSet.getString(resultSet.getColumnIndex('birth_calendar'));
          p.deathDate = resultSet.getString(resultSet.getColumnIndex('death_date'));
          p.deathCalendar = resultSet.getString(resultSet.getColumnIndex('death_calendar'));
          p.birthPlace = resultSet.getString(resultSet.getColumnIndex('birth_place'));
          p.residence = resultSet.getString(resultSet.getColumnIndex('residence'));
          p.fatherId = resultSet.getString(resultSet.getColumnIndex('father_id'));
          p.fatherName = resultSet.getString(resultSet.getColumnIndex('father_name'));
          p.fatherLifeStatus = resultSet.getString(resultSet.getColumnIndex('father_life_status'));
          p.motherId = resultSet.getString(resultSet.getColumnIndex('mother_id'));
          p.motherName = resultSet.getString(resultSet.getColumnIndex('mother_name'));
          p.motherLifeStatus = resultSet.getString(resultSet.getColumnIndex('mother_life_status'));
          p.spouseId = resultSet.getString(resultSet.getColumnIndex('spouse_id'));
          p.marriageStatus = resultSet.getString(resultSet.getColumnIndex('marriage_status'));
          p.spouseFamily = resultSet.getString(resultSet.getColumnIndex('spouse_family'));
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
      normalizeSpouseRelations(p);
      await this.personRepository.upsert(p, this.currentBookId);
      await this.personRepository.saveSpouses(p.uid, p.spouses, this.currentBookId);
    }
  }

  private bump(): void {
    this.peopleStore.bump();
  }

  // ---------------------------------------------------------------- 协作

  /**
   * 记录「编辑前的快照」，供字段级 diff 生成 patch（§五.5 patchJson）。
   * 由编辑页在保存前调用。
   */
  captureBefore(uid: string): void {
    this.cloudCollaboration.captureBefore(uid);
  }

  getStore(): relationalStore.RdbStore | null {
    return this.store;
  }

  // ---------------------------------------------------------------- 族谱管理宿主

  storeRef(): relationalStore.RdbStore | null {
    return this.store;
  }

  booksRef(): Genealogy[] {
    return this.books;
  }

  currentBookIdValue(): number {
    return this.currentBookId;
  }

  currentBookValue(): Genealogy {
    return this.book;
  }

  retiredMap(): Map<string, string> {
    return this.retiredUids;
  }

  clearRetiredCache(): void {
    this.retiredUids.clear();
  }

  peopleAll(): Person[] {
    return this.peopleStore.getAll();
  }

  getMetaValue(key: string): Promise<string> {
    return this.getMeta(key);
  }

  setCurrentBookId(id: number): void {
    this.currentBookId = id;
  }

  setCurrentBook(book: Genealogy): void {
    this.book = book;
  }

  syncBookInList(book: Genealogy): void {
    for (let i: number = 0; i < this.books.length; i++) {
      if (this.books[i].key === book.key) {
        this.books[i] = book;
        break;
      }
    }
  }

  setMetaValue(key: string, value: string): Promise<void> {
    return this.setMeta(key, value);
  }

  reloadData(): Promise<void> {
    return this.reload();
  }

  bumpVersion(): void {
    this.bump();
  }

  applyBookFamilyState(): void {
    FamilyService.getInstance().applyBookFamilyState();
  }

  /**
   * 供协作层调用的「云端回放入口」（§七 GenealogyService.applyRemoteChange）。
   * 具体回放语义见 CloudReplay。
   */
  async applyRemoteChange(uid: string, person: Person | null, rev: number, deleted: boolean): Promise<boolean> {
    return this.cloudReplay.applyRemoteChange(uid, person, rev, deleted);
  }

  /** 整页批量回放（同步快路径）：一次事务内批量写入本页全部成员 */
  async applyRemoteBatch(items: RemoteWrite[]): Promise<number> {
    return this.cloudReplay.applyRemoteBatch(items);
  }

  /** 回放完成后刷新内存与界面 */
  async reloadAfterReplay(): Promise<void> {
    await this.cloudReplay.reloadAfterReplay();
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
    return this.cloudCollaboration.isDeleted(uid);
  }
}

/** 读取可能不存在的数字列 */
function readColumnLong(rs: relationalStore.ResultSet, column: string): number {
  const idx: number = rs.getColumnIndex(column);
  if (idx < 0) {
    return 0;
  }
  return rs.getLong(idx);
}


