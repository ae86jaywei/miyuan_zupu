import { relationalStore } from '@kit.ArkData';
import { Person, SpouseRelation, spouseRelationLevel } from 'common_base';
import { TABLE_PERSON, TABLE_SPOUSE } from './db/DatabaseSchema';
import { PersonRowMapper } from './db/PersonRowMapper';
import { PeopleStore } from './PeopleStore';

/**
 * 人员仓储域：人员行与配偶关系的数据库读写。
 *
 * 从 `GenealogyService` 拆出，只负责 SQL 与行映射，不含业务编排与版本通知。
 * 数据库句柄与当前族谱 ID 通过提供者注入，构造时服务尚未完成初始化也能安全持有。
 */
export class PersonRepository {
  private storeProvider: () => relationalStore.RdbStore | null;
  private bookIdProvider: () => number;
  private peopleStore: PeopleStore;

  constructor(storeProvider: () => relationalStore.RdbStore | null,
    bookIdProvider: () => number, peopleStore: PeopleStore) {
    this.storeProvider = storeProvider;
    this.bookIdProvider = bookIdProvider;
    this.peopleStore = peopleStore;
  }

  private requireStore(): relationalStore.RdbStore {
    return this.storeProvider() as relationalStore.RdbStore;
  }

  private resolveBook(bookId: number): number {
    return bookId > 0 ? bookId : this.bookIdProvider();
  }

  /** 直接插入一条新人物（导入批量写入用，跳过按 id/uid 的两次回查更新） */
  async insert(p: Person): Promise<void> {
    const store: relationalStore.RdbStore = this.requireStore();
    const rowId: number = await store.insert(TABLE_PERSON, PersonRowMapper.toValues(p, this.bookIdProvider()));
    p.key = rowId;
  }

  /** 按主键或 uid 更新，未命中则插入 */
  async upsert(p: Person, bookId: number = 0): Promise<void> {
    const owner: number = this.resolveBook(bookId);
    const store: relationalStore.RdbStore = this.requireStore();
    const values: relationalStore.ValuesBucket = PersonRowMapper.toValues(p, owner);
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
   * 保存某人的配偶关系：
   *  - 先解除已移除的配偶（双向删除，避免另一侧的旧记录复活）；
   *  - 再重建本人名下的直接关系（按 ord 顺序）。
   */
  async saveSpouses(ownerUid: string, list: SpouseRelation[], bookId: number = 0): Promise<void> {
    const owner: number = this.resolveBook(bookId);
    const store: relationalStore.RdbStore = this.requireStore();
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
      `SELECT uid, spouse_uid FROM ${TABLE_SPOUSE} WHERE book_id = ? AND (uid = ? OR spouse_uid = ?)`,
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
          `DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ? AND ((uid = ? AND spouse_uid = ?) OR (uid = ? AND spouse_uid = ?))`,
          [owner, u, o, o, u]);
      }
    }
    const news: string[] = Array.from(newSet);
    news.forEach((n: string): void => {
      affected.add(n);
    });
    await store.executeSql(`DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ? AND uid = ?`, [owner, u]);
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
    // 反向记录：保证对方配偶表里也有本人，双方重载后都能看到彼此。
    // 对方已有直接记录（含明确名分）时以对方为准，不用反向关系覆盖。
    for (let i: number = 0; i < list.length; i++) {
      const id: string = list[i].uid.trim().toUpperCase();
      if (id.length === 0 || id === u) {
        continue;
      }
      const partner: Person | undefined = this.peopleStore.getMap().get(id);
      if (partner === undefined) {
        continue;
      }
      const existing: string = await this.spouseRowRelation(owner, id, u);
      if (existing.length > 0 && existing !== '未记') {
        continue;
      }
      const rel: string = list[i].relation.trim().length > 0 ? list[i].relation.trim() : '未记';
      let reverseRel: string = rel;
      if (partner.gender === '女') {
        reverseRel = '夫';
      } else if (rel === '夫') {
        // 本人是女性：男方对她的称谓稍后由 syncSpouseIdentities 按本人身份回填
        reverseRel = existing.length > 0 ? existing : '未记';
      }
      const ord: number = await this.nextSpouseOrd(owner, id);
      await store.executeSql(
        `INSERT OR REPLACE INTO ${TABLE_SPOUSE}(book_id, uid, spouse_uid, relation, level, ord) VALUES(?, ?, ?, ?, ?, ?)`,
        [owner, id, u, reverseRel, spouseRelationLevel(reverseRel), ord]);
    }
    // 同步相关人物的 spouse_id（兼容旧字段），避免下次启动被迁移逻辑“复活”
    const partners: string[] = Array.from(affected);
    for (let i: number = 0; i < partners.length; i++) {
      const o: string = partners[i];
      if (o.length === 0 || o === u) {
        continue;
      }
      await store.executeSql(
        `UPDATE ${TABLE_PERSON} SET spouse_id = COALESCE((SELECT spouse_uid FROM ${TABLE_SPOUSE} WHERE book_id = ? AND uid = ? ORDER BY ord LIMIT 1), '') WHERE book_id = ? AND uid = ?`,
        [owner, o, owner, o]);
    }
  }

  /**
   * 批量写人物行：同一页数据用多行 INSERT OR REPLACE 一次提交，
   * 把逐人数千次 SQL IPC 压到几十次（云回放整页写入用）。
   */
  async upsertMany(persons: Person[], bookId: number = 0): Promise<void> {
    const store: relationalStore.RdbStore = this.requireStore();
    const owner: number = this.resolveBook(bookId);
    const withId: relationalStore.ValuesBucket[] = [];
    const withoutId: relationalStore.ValuesBucket[] = [];
    for (let i: number = 0; i < persons.length; i++) {
      const p: Person = persons[i];
      const v: relationalStore.ValuesBucket = PersonRowMapper.toValues(p, owner);
      if (p.key > 0) {
        v['id'] = p.key;
        withId.push(v);
      } else {
        withoutId.push(v);
      }
    }
    await this.insertOrReplaceRows(store, TABLE_PERSON, withoutId);
    await this.insertOrReplaceRows(store, TABLE_PERSON, withId);
  }

  /**
   * 批量重建同页人物的配偶关系。
   *
   * 先按页清空双向记录，再按各自配偶列表整页回写（含反向记录），
   * 逐人 6~8 条 SQL 变成每页十余条；对方已写下的明确名分从预取结果中保留。
   */
  async saveSpousesMany(persons: Person[], bookId: number = 0): Promise<void> {
    const store: relationalStore.RdbStore = this.requireStore();
    const owner: number = this.resolveBook(bookId);
    const ownUids: string[] = [];
    const partnerUids: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < persons.length; i++) {
      const u: string = persons[i].uid.trim().toUpperCase();
      if (u.length === 0) {
        continue;
      }
      ownUids.push(u);
      const sps: SpouseRelation[] = persons[i].spouses;
      for (let j: number = 0; j < sps.length; j++) {
        const sid: string = sps[j].uid.trim().toUpperCase();
        if (sid.length === 0 || sid === u || seen.has(sid)) {
          continue;
        }
        seen.add(sid);
        partnerUids.push(sid);
      }
    }
    if (ownUids.length === 0) {
      return;
    }
    const relationOf: Map<string, string> = new Map<string, string>();
    await this.collectSpouseRelations(store, owner, 'uid', ownUids, relationOf);
    await this.collectSpouseRelations(store, owner, 'uid', partnerUids, relationOf);
    await this.deleteSpouseRows(store, owner, 'uid', ownUids);
    await this.deleteSpouseRows(store, owner, 'spouse_uid', ownUids);
    const rows: relationalStore.ValuesBucket[] = [];
    for (let i: number = 0; i < persons.length; i++) {
      const p: Person = persons[i];
      const u: string = p.uid.trim().toUpperCase();
      if (u.length === 0) {
        continue;
      }
      for (let j: number = 0; j < p.spouses.length; j++) {
        const sid: string = p.spouses[j].uid.trim().toUpperCase();
        if (sid.length === 0 || sid === u) {
          continue;
        }
        const rel: string = p.spouses[j].relation.trim().length > 0
          ? p.spouses[j].relation.trim() : '未记';
        rows.push(this.spouseValues(owner, u, sid, rel, j + 1));
        // 反向记录：对方本地存在时才补，双方重载后都能看到彼此
        const partner: Person | undefined = this.peopleStore.getMap().get(sid);
        if (partner === undefined) {
          continue;
        }
        const existingRel: string | undefined = relationOf.get(sid + '|' + u);
        const existing: string = existingRel === undefined ? '' : existingRel;
        let reverseRel: string = rel;
        if (existing.length > 0 && existing !== '未记') {
          reverseRel = existing;
        } else if (partner.gender === '女') {
          reverseRel = '夫';
        } else if (rel === '夫') {
          reverseRel = '未记';
        }
        rows.push(this.spouseValues(owner, sid, u, reverseRel, j + 1));
      }
    }
    await this.insertOrReplaceRows(store, TABLE_SPOUSE, rows);
    await this.refreshSpouseIds(store, owner, partnerUids);
  }

  private spouseValues(bookId: number, uid: string, spouseUid: string, relation: string,
    ord: number): relationalStore.ValuesBucket {
    const v: relationalStore.ValuesBucket = {};
    v['book_id'] = bookId;
    v['uid'] = uid;
    v['spouse_uid'] = spouseUid;
    v['relation'] = relation;
    v['level'] = spouseRelationLevel(relation);
    v['ord'] = ord;
    return v;
  }

  /** 多行 INSERT OR REPLACE；按参数上限分批，避免单条 SQL 参数过多 */
  private async insertOrReplaceRows(store: relationalStore.RdbStore, table: string,
    rows: relationalStore.ValuesBucket[]): Promise<void> {
    if (rows.length === 0) {
      return;
    }
    const cols: string[] = Object.keys(rows[0]);
    const perRow: number = cols.length;
    const maxRows: number = Math.max(1, Math.floor(800 / perRow));
    const one: string = this.placeholders(perRow);
    for (let start: number = 0; start < rows.length; start += maxRows) {
      const end: number = Math.min(start + maxRows, rows.length);
      const groups: string[] = [];
      const args: relationalStore.ValueType[] = [];
      for (let r: number = start; r < end; r++) {
        groups.push(one);
        for (let c: number = 0; c < perRow; c++) {
          args.push(rows[r][cols[c]] as relationalStore.ValueType);
        }
      }
      await store.executeSql(
        `INSERT OR REPLACE INTO ${table} (${cols.join(', ')}) VALUES ${groups.join(', ')}`, args);
    }
  }

  private placeholders(n: number): string {
    let s: string = '?';
    for (let i: number = 1; i < n; i++) {
      s = s + ',?';
    }
    return '(' + s + ')';
  }

  private async collectSpouseRelations(store: relationalStore.RdbStore, bookId: number,
    column: string, uids: string[], out: Map<string, string>): Promise<void> {
    const chunk: number = 400;
    for (let start: number = 0; start < uids.length; start += chunk) {
      const end: number = Math.min(start + chunk, uids.length);
      const args: relationalStore.ValueType[] = [bookId];
      for (let i: number = start; i < end; i++) {
        args.push(uids[i]);
      }
      const rs: relationalStore.ResultSet = await store.querySql(
        `SELECT uid, spouse_uid, relation FROM ${TABLE_SPOUSE} WHERE book_id = ? AND ${column} IN (${this.placeholders(end - start).slice(1, -1)})`,
        args);
      try {
        while (rs.goToNextRow()) {
          const a: string = rs.getString(rs.getColumnIndex('uid')).trim().toUpperCase();
          const b: string = rs.getString(rs.getColumnIndex('spouse_uid')).trim().toUpperCase();
          out.set(a + '|' + b, rs.getString(rs.getColumnIndex('relation')));
        }
      } finally {
        rs.close();
      }
    }
  }

  private async deleteSpouseRows(store: relationalStore.RdbStore, bookId: number,
    column: string, uids: string[]): Promise<void> {
    const chunk: number = 400;
    for (let start: number = 0; start < uids.length; start += chunk) {
      const end: number = Math.min(start + chunk, uids.length);
      const args: relationalStore.ValueType[] = [bookId];
      for (let i: number = start; i < end; i++) {
        args.push(uids[i]);
      }
      await store.executeSql(
        `DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ? AND ${column} IN (${this.placeholders(end - start).slice(1, -1)})`,
        args);
    }
  }

  /** 一条 SQL 回填整页相关人物的 spouse_id（兼容旧字段） */
  private async refreshSpouseIds(store: relationalStore.RdbStore, bookId: number,
    uids: string[]): Promise<void> {
    const chunk: number = 400;
    for (let start: number = 0; start < uids.length; start += chunk) {
      const end: number = Math.min(start + chunk, uids.length);
      const args: relationalStore.ValueType[] = [bookId, bookId];
      for (let i: number = start; i < end; i++) {
        args.push(uids[i]);
      }
      await store.executeSql(
        `UPDATE ${TABLE_PERSON} SET spouse_id = COALESCE((SELECT s.spouse_uid FROM ${TABLE_SPOUSE} s ` +
        `WHERE s.book_id = ? AND s.uid = ${TABLE_PERSON}.uid ORDER BY s.ord LIMIT 1), '') ` +
        `WHERE book_id = ? AND uid IN (${this.placeholders(end - start).slice(1, -1)})`,
        args);
    }
  }

  /**
   * 删除人员行及其相关引用（父母/配偶外键、配偶关系表）。
   * 协作态走墓碑软删，查询时统一过滤。
   */
  async deleteRows(uid: string, cloud: boolean): Promise<void> {
    const u: string = uid.trim().toUpperCase();
    const bookId: number = this.bookIdProvider();
    const store: relationalStore.RdbStore = this.requireStore();
    if (cloud) {
      await store.executeSql(
        `UPDATE ${TABLE_PERSON} SET deleted_at = ?, updated_at = ?, dirty = 1 WHERE book_id = ? AND uid = ?`,
        [Date.now(), Date.now(), bookId, u]);
    } else {
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_PERSON);
      predicates.equalTo('uid', u);
      predicates.and().equalTo('book_id', bookId);
      await store.delete(predicates);
    }
    await store.executeSql(`UPDATE ${TABLE_PERSON} SET father_id = '' WHERE book_id = ? AND UPPER(father_id) = ?`,
      [bookId, u]);
    await store.executeSql(`UPDATE ${TABLE_PERSON} SET mother_id = '' WHERE book_id = ? AND UPPER(mother_id) = ?`,
      [bookId, u]);
    await store.executeSql(`UPDATE ${TABLE_PERSON} SET spouse_id = '' WHERE book_id = ? AND UPPER(spouse_id) = ?`,
      [bookId, u]);
    await store.executeSql(
      `DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ? AND (UPPER(uid) = ? OR UPPER(spouse_uid) = ?)`,
      [bookId, u, u]);
  }

  /** 查询某人对配偶的直接名分；不存在返回空串 */
  async spouseRowRelation(bookId: number, ownerUid: string, spouseUid: string): Promise<string> {
    const store: relationalStore.RdbStore = this.requireStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT relation FROM ${TABLE_SPOUSE} WHERE book_id = ? AND uid = ? AND spouse_uid = ?`,
      [bookId, ownerUid.trim().toUpperCase(), spouseUid.trim().toUpperCase()]);
    let relation: string = '';
    try {
      if (rs.goToNextRow()) {
        const raw: string = rs.getString(rs.getColumnIndex('relation'));
        relation = raw === null ? '' : raw;
      }
    } finally {
      rs.close();
    }
    return relation.trim();
  }

  /** 某人配偶表下一个排序号 */
  async nextSpouseOrd(bookId: number, ownerUid: string): Promise<number> {
    const store: relationalStore.RdbStore = this.requireStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COALESCE(MAX(ord), 0) AS m FROM ${TABLE_SPOUSE} WHERE book_id = ? AND uid = ?`,
      [bookId, ownerUid.trim().toUpperCase()]);
    let ord: number = 1;
    try {
      if (rs.goToNextRow()) {
        ord = rs.getLong(rs.getColumnIndex('m')) + 1;
      }
    } finally {
      rs.close();
    }
    return ord;
  }
}
