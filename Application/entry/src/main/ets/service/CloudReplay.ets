import { relationalStore } from '@kit.ArkData';
import { Person, clonePerson, createEmptyPerson, normalizeSpouseRelations } from 'common_base';
import { TABLE_PERSON, TABLE_SPOUSE } from './db/DatabaseSchema';
import { PeopleStore } from './PeopleStore';
import { PersonRepository } from './PersonRepository';

/**
 * 一条待回放的云端成员写入（整页批量回放用）。
 */
export class RemoteWrite {
  uid: string = '';
  person: Person | null = null;
  rev: number = 0;
  deleted: boolean = false;
}

/**
 * 云回放域：把云侧成员行写回本地 RDB，并在回放结束后刷新内存。
 *
 * 从 `GenealogyService` 拆出，只负责回放语义：
 *  - deleted=true 视为墓碑：仅标记，不物理删除；
 *  - 隐私字段在 VIEWER/EDITOR 侧本就拿不到，保持本地原值不动；
 *  - 回放永远不写入 outbox（它不是本地修改）。
 */
export class CloudReplay {
  private storeProvider: () => relationalStore.RdbStore | null;
  private bookIdProvider: () => number;
  private peopleStore: PeopleStore;
  private repository: PersonRepository;
  private retiredRecorder: (uid: string, name: string) => Promise<void>;
  private reloader: () => Promise<void>;

  constructor(storeProvider: () => relationalStore.RdbStore | null,
    bookIdProvider: () => number,
    peopleStore: PeopleStore,
    repository: PersonRepository,
    retiredRecorder: (uid: string, name: string) => Promise<void>,
    reloader: () => Promise<void>) {
    this.storeProvider = storeProvider;
    this.bookIdProvider = bookIdProvider;
    this.peopleStore = peopleStore;
    this.repository = repository;
    this.retiredRecorder = retiredRecorder;
    this.reloader = reloader;
  }

  /**
   * 供协作层调用的「云端回放入口」。
   * 把云侧成员行写回本地 RDB，返回是否有数据变化。
   */
  async applyRemoteChange(uid: string, person: Person | null, rev: number, deleted: boolean): Promise<boolean> {
    const store: relationalStore.RdbStore | null = this.storeProvider();
    if (store === null) {
      return false;
    }
    const u: string = uid.trim().toUpperCase();
    if (u.length === 0) {
      return false;
    }
    const bookId: number = this.bookIdProvider();
    if (deleted) {
      const tomb: Person | null = this.peopleStore.getPerson(u);
      await store.executeSql(
        `UPDATE ${TABLE_PERSON} SET deleted_at = ?, rev = ?, base_rev = ?, dirty = 0 WHERE book_id = ? AND uid = ?`,
        [Date.now(), rev, rev, bookId, u]);
      // 墓碑同样要断开引用：否则其他族人的父亲/配偶仍指向这个已删除编号，
      // 一旦该编号被新族人复用，旧关系就会挂到新人身上。
      await store.executeSql(`UPDATE ${TABLE_PERSON} SET father_id = '' WHERE book_id = ? AND UPPER(father_id) = ?`,
        [bookId, u]);
      await store.executeSql(`UPDATE ${TABLE_PERSON} SET mother_id = '' WHERE book_id = ? AND UPPER(mother_id) = ?`,
        [bookId, u]);
      await store.executeSql(`UPDATE ${TABLE_PERSON} SET spouse_id = '' WHERE book_id = ? AND UPPER(spouse_id) = ?`,
        [bookId, u]);
      await store.executeSql(
        `DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ? AND (uid = ? OR spouse_uid = ?)`,
        [bookId, u, u]);
      // 云端墓碑的编号同样封存，后续新增不得复用
      await this.retiredRecorder(u, tomb === null ? '' : tomb.name);
      return true;
    }
    const exist: Person | null = this.peopleStore.getPerson(u);
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
    normalizeSpouseRelations(p);
    await this.repository.upsert(p, bookId);
    // 双方都无配偶关系时无需再查/删/插配偶表：多数族人属于这种情况，
    // 省下的 SELECT + DELETE 在 6 万人规模下很可观。
    if (p.spouses.length > 0 || (exist !== null && exist.spouses.length > 0)) {
      await this.repository.saveSpouses(p.uid, p.spouses, bookId);
    }
    await store.executeSql(
      `UPDATE ${TABLE_PERSON} SET rev = ?, base_rev = ?, dirty = 0, deleted_at = 0 WHERE book_id = ? AND uid = ?`,
      [rev, rev, bookId, u]);
    return true;
  }

  /**
   * 整页批量回放：同页人物合并成一次批量写（人物行 + 配偶关系），
   * 把每人 6~8 条 SQL 压到整页几十条；墓碑仍走单条路径（数量极少）。
   * 返回实际写入的人物数。
   */
  async applyRemoteBatch(items: RemoteWrite[]): Promise<number> {
    const store: relationalStore.RdbStore | null = this.storeProvider();
    if (store === null) {
      return 0;
    }
    const bookId: number = this.bookIdProvider();
    const alive: Person[] = [];
    let tombstones: number = 0;
    for (let i: number = 0; i < items.length; i++) {
      const item: RemoteWrite = items[i];
      if (item.deleted) {
        await this.applyRemoteChange(item.uid, null, item.rev, true);
        tombstones++;
        continue;
      }
      const u: string = item.uid.trim().toUpperCase();
      if (u.length === 0) {
        continue;
      }
      const exist: Person | null = this.peopleStore.getPerson(u);
      const p: Person = item.person !== null ? clonePerson(item.person) : createEmptyPerson();
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
      p.rev = item.rev;
      p.baseRev = item.rev;
      p.dirty = false;
      p.deletedAt = 0;
      normalizeSpouseRelations(p);
      alive.push(p);
    }
    if (alive.length === 0) {
      return tombstones;
    }
    store.beginTransaction();
    let committed: boolean = false;
    try {
      await this.repository.upsertMany(alive, bookId);
      await this.repository.saveSpousesMany(alive, bookId);
      store.commit();
      committed = true;
    } finally {
      if (!committed) {
        store.rollBack();
      }
    }
    return alive.length + tombstones;
  }

  /** 回放完成后刷新内存与界面 */
  async reloadAfterReplay(): Promise<void> {
    await this.reloader();
  }
}
