import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { relationalStore } from '@kit.ArkData';
import { Genealogy, Person, createEmptyGenealogy, createEmptyPerson } from 'common_base';
import { DatabaseSchema, TABLE_BOOK, TABLE_PERSON } from '../../../main/ets/service/db/DatabaseSchema';
import { PersonRowMapper } from '../../../main/ets/service/db/PersonRowMapper';
import { BranchHost, BranchManager } from '../../../main/ets/service/BranchManager';
import { PeopleStore } from '../../../main/ets/service/PeopleStore';
import { PersonRepository } from '../../../main/ets/service/PersonRepository';
import { openTestStore } from '../testutil/TestEnv';

const BUNDLE: string = 'com.zupu.ae86jay';
const TEST_MODULE: string = 'entry_test';
const TEST_ABILITY: string = 'TestAbility';
const DB_NAME: string = 'ohos_test_branch.db';
const PARENT_ID: number = 990003;

function person(uid: string, name: string, generation: number, fatherId: string): Person {
  const p: Person = createEmptyPerson();
  p.uid = uid;
  p.name = name;
  p.gender = '男';
  p.generation = generation;
  p.fatherId = fatherId;
  return p;
}

class TestBranchHost implements BranchHost {
  store: relationalStore.RdbStore;
  book: Genealogy = createEmptyGenealogy();
  books: Genealogy[] = [];
  currentId: number = PARENT_ID;
  people: Map<string, Person> = new Map<string, Person>();
  meta: Map<string, string> = new Map<string, string>();

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  storeRef(): relationalStore.RdbStore | null {
    return this.store;
  }

  currentBookIdValue(): number {
    return this.currentId;
  }

  setCurrentBookId(id: number): void {
    this.currentId = id;
  }

  currentBookValue(): Genealogy {
    return this.book;
  }

  hasBookTitle(title: string): boolean {
    for (let i: number = 0; i < this.books.length; i++) {
      if (this.books[i].title === title) {
        return true;
      }
    }
    return false;
  }

  getPerson(uid: string): Person | null {
    const p: Person | undefined = this.people.get(uid.trim().toUpperCase());
    return p === undefined ? null : p;
  }

  peopleAll(): Person[] {
    const list: Person[] = [];
    this.people.forEach((p: Person): void => {
      list.push(p);
    });
    return list;
  }

  getMetaValue(key: string): Promise<string> {
    const v: string | undefined = this.meta.get(key);
    return Promise.resolve(v === undefined ? '' : v);
  }

  setMetaValue(key: string, value: string): Promise<void> {
    this.meta.set(key, value);
    return Promise.resolve();
  }

  reloadData(): Promise<void> {
    return Promise.resolve();
  }
}

export default function branchManagerTest() {
  describe('BranchManager', () => {
    let store: relationalStore.RdbStore | null = null;
    let host: TestBranchHost | null = null;
    let manager: BranchManager | null = null;
    let parentBookId: number = 0;

    beforeAll(async () => {
      store = await openTestStore(BUNDLE, TEST_MODULE, TEST_ABILITY, DB_NAME);
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      await DatabaseSchema.createTables(s);
      await s.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [PARENT_ID]);
      await s.executeSql(`DELETE FROM ${TABLE_BOOK} WHERE id = ?`, [PARENT_ID]);

      const parent: Genealogy = createEmptyGenealogy();
      parent.title = '母谱';
      parentBookId = await s.insert(TABLE_BOOK, PersonRowMapper.bookValues(parent));
      const repo: PersonRepository = new PersonRepository(
        (): relationalStore.RdbStore | null => store, (): number => parentBookId, new PeopleStore());
      await repo.upsert(person('F1', '始祖', 1, ''), parentBookId);
      await repo.upsert(person('C1', '长子', 2, 'F1'), parentBookId);

      host = new TestBranchHost(s);
      host.book = parent;
      host.currentId = parentBookId;
      host.people.set('F1', person('F1', '始祖', 1, ''));
      host.people.set('C1', person('C1', '长子', 2, 'F1'));
      manager = new BranchManager(host);
    });

    afterAll(async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const h: TestBranchHost = host as TestBranchHost;
      await s.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [parentBookId]);
      await s.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [h.currentId]);
      await s.executeSql(`DELETE FROM ${TABLE_BOOK} WHERE id = ?`, [h.currentId]);
      await s.executeSql(`DELETE FROM ${TABLE_BOOK} WHERE id = ?`, [parentBookId]);
    });

    it('createBranchCopiesSubtreeAndCleansParent', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const h: TestBranchHost = host as TestBranchHost;
      const m: BranchManager = manager as BranchManager;

      await m.createBranchFromPerson('F1');
      expect(h.currentId > 0).assertTrue();
      expect(h.currentId !== PARENT_ID).assertTrue();

      // 分支谱人物已复制（始祖 + 后代）
      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT uid, father_id, rank FROM ${TABLE_PERSON} WHERE book_id = ? ORDER BY uid`, [h.currentId]);
      let rows: number = 0;
      let rootFather: string = 'x';
      try {
        while (rs.goToNextRow()) {
          if (rs.getString(rs.getColumnIndex('uid')) === 'F1') {
            rootFather = rs.getString(rs.getColumnIndex('father_id'));
          }
          rows = rows + 1;
        }
      } finally {
        rs.close();
      }
      expect(rows).assertEqual(2);
      // 分支始祖的父母清空
      expect(rootFather).assertEqual('');

      // 直接调用后台清理，避免依赖定时器（生产由 setTimeout 触发）
      await m.cleanupMoved(parentBookId, ['F1', 'C1'], Date.now());
      const rs2: relationalStore.ResultSet = await s.querySql(
        `SELECT COUNT(*) AS c FROM ${TABLE_PERSON} WHERE book_id = ? AND deleted_at > 0`,
        [parentBookId]);
      try {
        expect(rs2.goToNextRow()).assertTrue();
        expect(rs2.getLong(rs2.getColumnIndex('c'))).assertEqual(1);
      } finally {
        rs2.close();
      }
    });
  });
}
