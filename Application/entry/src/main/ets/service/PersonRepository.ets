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
