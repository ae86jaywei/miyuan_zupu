import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { relationalStore } from '@kit.ArkData';
import { Person, IntegrityReport, IdGenerator, createEmptyPerson } from 'common_base';
import { DatabaseSchema, TABLE_PERSON, TABLE_SPOUSE } from '../../../main/ets/service/db/DatabaseSchema';
import { ImportHost, ImportManager } from '../../../main/ets/service/ImportManager';
import { ImportPlan, ImportResult } from '../../../main/ets/service/ImportPlanner';
import { PeopleStore } from '../../../main/ets/service/PeopleStore';
import { PersonRepository } from '../../../main/ets/service/PersonRepository';
import { openTestStore } from '../testutil/TestEnv';

const BUNDLE: string = 'com.zupu.ae86jay';
const TEST_MODULE: string = 'entry_test';
const TEST_ABILITY: string = 'TestAbility';
const DB_NAME: string = 'ohos_test_import.db';
const BOOK_ID: number = 990002;

function person(uid: string, name: string): Person {
  const p: Person = createEmptyPerson();
  p.uid = uid;
  p.name = name;
  p.gender = '男';
  return p;
}

/** 最小化 ImportHost 实现：真实测试库 + 内存人员视图 */
class TestImportHost implements ImportHost {
  store: relationalStore.RdbStore;
  peopleStore: PeopleStore;
  currentId: number = BOOK_ID;

  constructor(store: relationalStore.RdbStore, peopleStore: PeopleStore) {
    this.store = store;
    this.peopleStore = peopleStore;
  }

  storeRef(): relationalStore.RdbStore | null {
    return this.store;
  }

  currentBookIdValue(): number {
    return this.currentId;
  }

  retiredMap(): Map<string, string> {
    return new Map<string, string>();
  }

  retiredNameOf(uid: string): string {
    return '';
  }

  nextUid(gender: string, extra?: Set<string>): string {
    return IdGenerator.next(this.peopleStore.getAll(), gender, extra);
  }

  clearRetired(bookId: number): Promise<void> {
    return Promise.resolve();
  }

  async reloadData(): Promise<void> {
    const list: Person[] = [];
    const rs: relationalStore.ResultSet = await this.store.querySql(
      `SELECT uid, name, father_id, mother_id FROM ${TABLE_PERSON} WHERE book_id = ?`, [this.currentId]);
    try {
      while (rs.goToNextRow()) {
        const p: Person = createEmptyPerson();
        p.uid = rs.getString(rs.getColumnIndex('uid'));
        p.name = rs.getString(rs.getColumnIndex('name'));
        p.fatherId = rs.getString(rs.getColumnIndex('father_id'));
        p.motherId = rs.getString(rs.getColumnIndex('mother_id'));
        list.push(p);
      }
    } finally {
      rs.close();
    }
    this.peopleStore.setList(list);
    this.peopleStore.rebuildMap();
  }

  checkIntegrity(): IntegrityReport {
    return new IntegrityReport();
  }
}

export default function importManagerTest() {
  describe('ImportManager', () => {
    let store: relationalStore.RdbStore | null = null;
    let peopleStore: PeopleStore = new PeopleStore();
    let manager: ImportManager | null = null;

    beforeAll(async () => {
      store = await openTestStore(BUNDLE, TEST_MODULE, TEST_ABILITY, DB_NAME);
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      await DatabaseSchema.createTables(s);
      await s.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [BOOK_ID]);
      await s.executeSql(`DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ?`, [BOOK_ID]);
      const repo: PersonRepository = new PersonRepository(
        (): relationalStore.RdbStore | null => store, (): number => BOOK_ID, peopleStore);
      manager = new ImportManager(new TestImportHost(s, peopleStore), peopleStore, repo);
    });

    afterAll(async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      await s.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [BOOK_ID]);
      await s.executeSql(`DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ?`, [BOOK_ID]);
    });

    it('importPeopleInsertsRows', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const m: ImportManager = manager as ImportManager;
      const count: number = await m.importPeople([person('I1', '导入甲'), person('I2', '导入乙')], 'auto');
      expect(count).assertEqual(2);

      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT COUNT(*) AS c FROM ${TABLE_PERSON} WHERE book_id = ?`, [BOOK_ID]);
      try {
        expect(rs.goToNextRow()).assertTrue();
        expect(rs.getLong(rs.getColumnIndex('c'))).assertEqual(2);
      } finally {
        rs.close();
      }
    });

    it('applyImportPlanWritesBatch', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const m: ImportManager = manager as ImportManager;
      await s.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [BOOK_ID]);
      await s.executeSql(`DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ?`, [BOOK_ID]);
      peopleStore.reset();

      const plan: ImportPlan = await m.planImport([person('P1', '计划甲'), person('P2', '计划乙')], 'auto', false);
      const result: ImportResult = await m.applyImportPlan(plan);
      expect(result.saved).assertEqual(2);

      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT COUNT(*) AS c FROM ${TABLE_PERSON} WHERE book_id = ?`, [BOOK_ID]);
      try {
        expect(rs.goToNextRow()).assertTrue();
        expect(rs.getLong(rs.getColumnIndex('c'))).assertEqual(2);
      } finally {
        rs.close();
      }
    });
  });
}
