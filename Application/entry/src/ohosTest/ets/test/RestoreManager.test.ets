import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { relationalStore } from '@kit.ArkData';
import { Genealogy, Person, createEmptyGenealogy, createEmptyPerson } from 'common_base';
import { DatabaseSchema, TABLE_BOOK, TABLE_PERSON } from '../../../main/ets/service/db/DatabaseSchema';
import { RestoreHost, RestoreManager, BookGroup } from '../../../main/ets/service/RestoreManager';
import { PeopleStore } from '../../../main/ets/service/PeopleStore';
import { PersonRepository } from '../../../main/ets/service/PersonRepository';
import { openTestStore } from '../testutil/TestEnv';

const BUNDLE: string = 'com.zupu.ae86jay';
const TEST_MODULE: string = 'entry_test';
const TEST_ABILITY: string = 'TestAbility';
const DB_NAME: string = 'ohos_test_restore.db';

function person(uid: string, name: string): Person {
  const p: Person = createEmptyPerson();
  p.uid = uid;
  p.name = name;
  p.gender = '男';
  return p;
}

class TestRestoreHost implements RestoreHost {
  store: relationalStore.RdbStore;
  currentId: number = 0;
  retiredCleared: boolean = false;

  constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  storeRef(): relationalStore.RdbStore | null {
    return this.store;
  }

  clearRetiredCache(): void {
    this.retiredCleared = true;
  }

  setCurrentBookId(id: number): void {
    this.currentId = id;
  }

  setMetaValue(key: string, value: string): Promise<void> {
    return Promise.resolve();
  }

  reloadData(): Promise<void> {
    return Promise.resolve();
  }
}

export default function restoreManagerTest() {
  describe('RestoreManager', () => {
    let store: relationalStore.RdbStore | null = null;
    let host: TestRestoreHost | null = null;
    let manager: RestoreManager | null = null;

    beforeAll(async () => {
      store = await openTestStore(BUNDLE, TEST_MODULE, TEST_ABILITY, DB_NAME);
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      await DatabaseSchema.createTables(s);
      host = new TestRestoreHost(s);
      manager = new RestoreManager(host, new PersonRepository(
        (): relationalStore.RdbStore | null => store, (): number => 0, new PeopleStore()));
    });

    afterAll(async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      await s.executeSql(`DELETE FROM ${TABLE_PERSON}`);
      await s.executeSql(`DELETE FROM ${TABLE_BOOK}`);
    });

    it('restoreRebuildsBooksAndRemapsParent', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const h: TestRestoreHost = host as TestRestoreHost;
      const m: RestoreManager = manager as RestoreManager;

      const main: BookGroup = new BookGroup();
      main.book = createEmptyGenealogy();
      main.book.key = 100;
      main.book.title = '主谱';
      main.people = [person('R1', '主谱甲'), person('R2', '主谱乙')];

      const branch: BookGroup = new BookGroup();
      branch.book = createEmptyGenealogy();
      branch.book.key = 200;
      branch.book.title = '分支谱';
      branch.book.parentBookId = 100;
      branch.people = [person('N1', '分支甲')];

      const restored: number = await m.restoreFromCloud([main, branch]);
      expect(restored).assertEqual(3);
      expect(h.retiredCleared).assertTrue();
      expect(h.currentId > 0).assertTrue();

      // 两部族谱均已重建
      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT COUNT(*) AS c FROM ${TABLE_BOOK}`);
      try {
        expect(rs.goToNextRow()).assertTrue();
        expect(rs.getLong(rs.getColumnIndex('c'))).assertEqual(2);
      } finally {
        rs.close();
      }

      // 分支谱的 parentBookId 已映射到本地新ID（非 0 且不等于旧ID 100）
      const rs2: relationalStore.ResultSet = await s.querySql(
        `SELECT id, parent_book_id FROM ${TABLE_BOOK} WHERE title = ?`, ['分支谱']);
      try {
        expect(rs2.goToNextRow()).assertTrue();
        const parent: number = rs2.getLong(rs2.getColumnIndex('parent_book_id'));
        expect(parent > 0).assertTrue();
        expect(parent !== 100).assertTrue();
      } finally {
        rs2.close();
      }
    });
  });
}
