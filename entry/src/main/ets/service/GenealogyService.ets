import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Person, clonePerson, createEmptyPerson } from '../model/Person';
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
        uid TEXT NOT NULL,
        generation INTEGER,
        name TEXT,
        alias TEXT,
        gender TEXT,
        generation_char TEXT,
        life_status TEXT,
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
      // 注意：ResultSet.rowCount 是“游标当前行号”（初始 -1），并非行数，
      // 必须真正游标读取一次才能拿到 COUNT(*) 的值。
      const count: number = await this.countRows();
      hilog.info(0x0000, TAG, 'existing rows=%{public}d', count);
      if (count === 0) {
        try {
          await this.insertSeed();
        } catch (e) {
          const se = e as BusinessError;
          hilog.error(0x0000, TAG, 'seed failed %{public}d %{public}s', se.code, se.message);
        }
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

  /** 配偶 */
  spouseOf(uid: string): Person | null {
    const p: Person | null = this.getPerson(uid);
    if (p === null || p.spouseId.length === 0) {
      return null;
    }
    return this.getPerson(p.spouseId);
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
    const s: Person | null = this.spouseOf(uid);
    if (f !== null) {
      result.push(f);
    }
    if (m !== null && m.uid !== (f === null ? '' : f.uid)) {
      result.push(m);
    }
    if (s !== null) {
      result.push(s);
    }
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
      if (p.spouseId.trim().length > 0) {
        spouseSet.add(p.spouseId.trim().toUpperCase());
      }
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
    const person: Person = clonePerson(p);
    if (person.uid.trim().length === 0) {
      person.uid = IdGenerator.next(this.people, person.gender);
    }
    person.uid = person.uid.trim().toUpperCase();
    person.createdAt = Date.now();
    person.updatedAt = person.createdAt;
    await this.upsertRow(person);
    await this.syncSpouse(person);
    await this.reload();
    return person;
  }

  /** 更新人物（按 uid 定位） */
  async updatePerson(p: Person, originalUid: string): Promise<Person> {
    const person: Person = clonePerson(p);
    person.uid = person.uid.trim().toUpperCase();
    person.updatedAt = Date.now();
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_PERSON);
    if (originalUid !== person.uid) {
      predicates.equalTo('uid', originalUid.trim().toUpperCase());
    } else {
      predicates.equalTo('id', person.key);
    }
    const values: relationalStore.ValuesBucket = this.toValues(person);
    await store.update(values, predicates);
    // 若唯一ID变化，同步更新引用
    if (originalUid.trim().toUpperCase() !== person.uid) {
      await store.executeSql(`UPDATE ${TABLE_PERSON} SET father_id = ? WHERE UPPER(father_id) = ?`,
        [person.uid, originalUid.trim().toUpperCase()]);
      await store.executeSql(`UPDATE ${TABLE_PERSON} SET mother_id = ? WHERE UPPER(mother_id) = ?`,
        [person.uid, originalUid.trim().toUpperCase()]);
      await store.executeSql(`UPDATE ${TABLE_PERSON} SET spouse_id = ? WHERE UPPER(spouse_id) = ?`,
        [person.uid, originalUid.trim().toUpperCase()]);
    }
    await this.syncSpouse(person);
    await this.reload();
    return person;
  }

  /** 删除人物（其子女自动上提为无父/无母，不删除其他人物） */
  async deletePerson(uid: string): Promise<void> {
    const u: string = uid.trim().toUpperCase();
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_PERSON);
    predicates.equalTo('uid', u);
    await store.delete(predicates);
    await store.executeSql(`UPDATE ${TABLE_PERSON} SET father_id = '' WHERE UPPER(father_id) = ?`, [u]);
    await store.executeSql(`UPDATE ${TABLE_PERSON} SET mother_id = '' WHERE UPPER(mother_id) = ?`, [u]);
    await store.executeSql(`UPDATE ${TABLE_PERSON} SET spouse_id = '' WHERE UPPER(spouse_id) = ?`, [u]);
    await this.reload();
  }

  /** 批量新增（导入使用），失败信息返回 */
  async importPeople(list: Person[], mergeStrategy: string): Promise<number> {
    let count: number = 0;
    for (let i: number = 0; i < list.length; i++) {
      const p: Person = clonePerson(list[i]);
      p.uid = p.uid.trim().toUpperCase();
      const exist: Person | undefined = this.peopleMap.get(p.uid);
      if (exist !== undefined) {
        if (mergeStrategy === 'skip') {
          continue;
        }
        if (mergeStrategy === 'replace') {
          p.key = exist.key;
          await this.upsertRow(p);
          count++;
          continue;
        }
        if (mergeStrategy === 'newId') {
          p.uid = IdGenerator.next(this.people, p.gender);
        }
      }
      await this.upsertRow(p);
      count++;
      // 每 50 条刷新一次，避免内存映射未更新导致 ID 重复
      if (count % 50 === 0) {
        await this.reload();
      }
    }
    await this.reload();
    return count;
  }

  /** 全量替换（恢复备份） */
  async replaceAll(list: Person[]): Promise<void> {
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    await store.executeSql(`DELETE FROM ${TABLE_PERSON}`);
    for (let i: number = 0; i < list.length; i++) {
      const p: Person = clonePerson(list[i]);
      p.uid = p.uid.trim().toUpperCase();
      await this.upsertRow(p);
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
    this.bump();
  }

  private async upsertRow(p: Person): Promise<void> {
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const values: relationalStore.ValuesBucket = this.toValues(p);
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
    const changed2: number = await store.update(values, predicates2);
    if (changed2 > 0) {
      return;
    }
    const rowId: number = await store.insert(TABLE_PERSON, values);
    p.key = rowId;
  }

  /** 夫妻关系双向同步 */
  private async syncSpouse(p: Person): Promise<void> {
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const spouseId: string = p.spouseId.trim().toUpperCase();
    if (spouseId.length === 0) {
      return;
    }
    await store.executeSql(`UPDATE ${TABLE_PERSON} SET spouse_id = ? WHERE uid = ? AND (spouse_id IS NULL OR spouse_id = '')`,
      [p.uid, spouseId]);
  }

  private toValues(p: Person): relationalStore.ValuesBucket {
    const v: relationalStore.ValuesBucket = {
      'uid': p.uid,
      'generation': p.generation,
      'name': p.name,
      'alias': p.alias,
      'gender': p.gender,
      'generation_char': p.generationChar,
      'life_status': p.lifeStatus,
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
      'created_at': b.createdAt,
      'updated_at': b.updatedAt
    };
    return v;
  }

  /** 从数据库重新加载全部数据 */
  async reload(): Promise<void> {
    const store: relationalStore.RdbStore = this.store as relationalStore.RdbStore;
    const resultSet: relationalStore.ResultSet = await store.querySql(`SELECT * FROM ${TABLE_PERSON}`);
    const list: Person[] = [];
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
    resultSet.close();
    list.sort((a: Person, b: Person): number => {
      if (a.generation !== b.generation) {
        return a.generation - b.generation;
      }
      return a.uid.localeCompare(b.uid);
    });
    this.people = list;
    const map: Map<string, Person> = new Map<string, Person>();
    list.forEach((p: Person): void => {
      map.set(p.uid.trim().toUpperCase(), p);
    });
    this.peopleMap = map;
    this.roots = TreeBuilder.build(this.people);

    // 加载族谱元信息
    const rs: relationalStore.ResultSet = await store.querySql(`SELECT * FROM ${TABLE_BOOK} LIMIT 1`);
    if (rs.goToNextRow()) {
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
      b.createdAt = rs.getLong(rs.getColumnIndex('created_at'));
      b.updatedAt = rs.getLong(rs.getColumnIndex('updated_at'));
      this.book = b;
    } else {
      const b: Genealogy = SeedData.defaultBook();
      const rowId: number = await store.insert(TABLE_BOOK, this.bookValues(b));
      b.key = rowId;
      this.book = b;
    }
    rs.close();
    this.bump();
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
