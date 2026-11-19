import { relationalStore } from '@kit.ArkData';
import { Genealogy, Person, clonePerson, createEmptyGenealogy, normalizeSpouseRelations } from 'common_base';
import { TABLE_BOOK, TABLE_META, TABLE_PERSON, TABLE_SPOUSE } from './db/DatabaseSchema';
import { PersonRowMapper } from './db/PersonRowMapper';
import { PersonRepository } from './PersonRepository';

/** 元数据：当前打开的族谱ID（0 表示无族谱） */
const META_CURRENT_BOOK: string = 'current_book_id';

/** 云端恢复时按族谱分组的人物数据 */
export class BookGroup {
  /** 云端族谱元信息（key 为云端族谱ID） */
  book: Genealogy = createEmptyGenealogy();
  /** 该族谱下的人物 */
  people: Person[] = [];
}

/**
 * 云恢复宿主接口：由 `GenealogyService` 实现，暴露恢复所需的少量状态操作。
 */
export interface RestoreHost {
  storeRef(): relationalStore.RdbStore | null;
  clearRetiredCache(): void;
  setCurrentBookId(id: number): void;
  setMetaValue(key: string, value: string): Promise<void>;
  reloadData(): Promise<void>;
}

/**
 * 云恢复域：从云端分组数据全量重建本地族谱。
 *
 * 从 `GenealogyService` 拆出；恢复顺序、分支父ID重映射与元数据清理语义保持不变。
 */
export class RestoreManager {
  private host: RestoreHost;
  private repository: PersonRepository;

  constructor(host: RestoreHost, repository: PersonRepository) {
    this.host = host;
    this.repository = repository;
  }

  /**
   * 从云端恢复多部族谱：先清空本地族谱数据，再按云端分组逐部重建。
   * 每部族谱及其族人、配偶关系完全独立，避免多族谱互相串数据。
   */
  async restoreFromCloud(groups: BookGroup[]): Promise<number> {
    const storeRef: relationalStore.RdbStore | null = this.host.storeRef();
    if (storeRef === null) {
      return 0;
    }
    const store: relationalStore.RdbStore = storeRef;
    await store.executeSql(`DELETE FROM ${TABLE_PERSON}`);
    await store.executeSql(`DELETE FROM ${TABLE_SPOUSE}`);
    await store.executeSql(`DELETE FROM ${TABLE_BOOK}`);
    // 云端恢复是全量重建：已删除编号表来自旧本地库，恢复后不再适用
    await store.executeSql(`DELETE FROM ${TABLE_META} WHERE key LIKE 'retired_uids_%'`);
    this.host.clearRetiredCache();
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
      const rowId: number = await store.insert(TABLE_BOOK, PersonRowMapper.bookValues(target));
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
        normalizeSpouseRelations(p);
        await this.repository.upsert(p, rowId);
        await this.repository.saveSpouses(p.uid, p.spouses, rowId);
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
      await store.update(PersonRowMapper.bookValues(restoredBooks[i]), predicates);
    }
    this.host.setCurrentBookId(firstBookId);
    await this.host.setMetaValue(META_CURRENT_BOOK, firstBookId.toString());
    await this.host.reloadData();
    return restored;
  }
}
