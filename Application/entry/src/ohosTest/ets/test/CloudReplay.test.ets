import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { relationalStore } from '@kit.ArkData';
import { Person, createEmptyPerson } from 'common_base';
import { DatabaseSchema, TABLE_PERSON, TABLE_SPOUSE } from '../../../main/ets/service/db/DatabaseSchema';
import { CloudReplay } from '../../../main/ets/service/CloudReplay';
import { PeopleStore } from '../../../main/ets/service/PeopleStore';
import { PersonRepository } from '../../../main/ets/service/PersonRepository';
import { openTestStore } from '../testutil/TestEnv';

const BUNDLE: string = 'com.zupu.ae86jay';
const TEST_MODULE: string = 'entry_test';
const TEST_ABILITY: string = 'TestAbility';
const DB_NAME: string = 'ohos_test_cloud_replay.db';
const BOOK_ID: number = 7;

function person(uid: string, name: string): Person {
  const p: Person = createEmptyPerson();
  p.uid = uid;
  p.name = name;
  return p;
}

function replayOf(store: relationalStore.RdbStore, peopleStore: PeopleStore, retired: string[],
  onReload: () => void): CloudReplay {
  const repo: PersonRepository = new PersonRepository(
    (): relationalStore.RdbStore | null => store, (): number => BOOK_ID, peopleStore);
  return new CloudReplay((): relationalStore.RdbStore | null => store, (): number => BOOK_ID,
    peopleStore, repo,
    async (uid: string, name: string): Promise<void> => {
      retired.push(uid + ':' + name);
    },
    async (): Promise<void> => {
      onReload();
    });
}

export default function cloudReplayTest() {
  describe('CloudReplay', () => {
    let store: relationalStore.RdbStore | null = null;

    beforeAll(async () => {
      store = await openTestStore(BUNDLE, TEST_MODULE, TEST_ABILITY, DB_NAME);
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      await DatabaseSchema.createTables(s);
      await s.executeSql(`DELETE FROM ${TABLE_PERSON}`);
      await s.executeSql(`DELETE FROM ${TABLE_SPOUSE}`);
    });

    afterAll(async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      await s.executeSql(`DELETE FROM ${TABLE_PERSON}`);
      await s.executeSql(`DELETE FROM ${TABLE_SPOUSE}`);
    });

    it('applyRemoteChangeUpsertsAndClearsDirty', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const peopleStore: PeopleStore = new PeopleStore();
      peopleStore.rebuildMap();
      const retired: string[] = [];
      const replay: CloudReplay = replayOf(s, peopleStore, retired, (): void => {
      });

      const changed: boolean = await replay.applyRemoteChange('c1', person('c1', '云端甲'), 5, false);
      expect(changed).assertTrue();

      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT name, rev, base_rev, dirty, deleted_at FROM ${TABLE_PERSON} WHERE book_id = ? AND UPPER(uid) = ?`,
        [BOOK_ID, 'C1']);
      try {
        expect(rs.goToNextRow()).assertTrue();
        expect(rs.getString(rs.getColumnIndex('name'))).assertEqual('云端甲');
        expect(rs.getLong(rs.getColumnIndex('rev'))).assertEqual(5);
        expect(rs.getLong(rs.getColumnIndex('base_rev'))).assertEqual(5);
        expect(rs.getLong(rs.getColumnIndex('dirty'))).assertEqual(0);
        expect(rs.getLong(rs.getColumnIndex('deleted_at'))).assertEqual(0);
        expect(rs.goToNextRow()).assertFalse();
      } finally {
        rs.close();
      }
      expect(retired.length).assertEqual(0);
    });

    it('applyRemoteChangeKeepsLocalPrivateFields', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const local: Person = person('C1', '本地旧名');
      local.phone = '13800000000';
      local.wechat = 'wx_local';
      local.residence = '深圳';
      const peopleStore: PeopleStore = new PeopleStore();
      peopleStore.setList([local]);
      peopleStore.rebuildMap();
      const replay: CloudReplay = replayOf(s, peopleStore, [], (): void => {
      });

      // 云侧 VIEWER/EDITOR 拿不到隐私字段，回放结果为空白
      const incoming: Person = person('C1', '云端乙');
      const changed: boolean = await replay.applyRemoteChange('C1', incoming, 6, false);
      expect(changed).assertTrue();

      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT name, phone, wechat, residence, rev FROM ${TABLE_PERSON} WHERE book_id = ? AND UPPER(uid) = ?`,
        [BOOK_ID, 'C1']);
      try {
        expect(rs.goToNextRow()).assertTrue();
        expect(rs.getString(rs.getColumnIndex('name'))).assertEqual('云端乙');
        expect(rs.getString(rs.getColumnIndex('phone'))).assertEqual('13800000000');
        expect(rs.getString(rs.getColumnIndex('wechat'))).assertEqual('wx_local');
        expect(rs.getString(rs.getColumnIndex('residence'))).assertEqual('深圳');
        expect(rs.getLong(rs.getColumnIndex('rev'))).assertEqual(6);
      } finally {
        rs.close();
      }
    });

    it('tombstoneMarksRowAndCutsReferences', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      await s.executeSql(
        `INSERT INTO ${TABLE_PERSON} (book_id, uid, name, father_id, mother_id, spouse_id)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [BOOK_ID, 'T1', '待删', '', '', 'B1']);
      await s.executeSql(
        `INSERT INTO ${TABLE_PERSON} (book_id, uid, name, father_id, mother_id, spouse_id)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [BOOK_ID, 'B1', '子辈', 'T1', 'T1', 'T1']);
      await s.executeSql(
        `INSERT INTO ${TABLE_SPOUSE} (book_id, uid, spouse_uid, relation, level, ord)
         VALUES (?, ?, ?, ?, ?, ?)`,
        [BOOK_ID, 'T1', 'B1', '元配', '正妻', 1]);

      const stored: Person = person('T1', '待删');
      const peopleStore: PeopleStore = new PeopleStore();
      peopleStore.setList([stored]);
      peopleStore.rebuildMap();
      const retired: string[] = [];
      const replay: CloudReplay = replayOf(s, peopleStore, retired, (): void => {
      });

      const changed: boolean = await replay.applyRemoteChange('t1', null, 9, true);
      expect(changed).assertTrue();
      // 墓碑封存编号并记录姓名
      expect(retired.length).assertEqual(1);
      expect(retired[0]).assertEqual('T1:待删');

      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT deleted_at, rev, base_rev, dirty FROM ${TABLE_PERSON} WHERE book_id = ? AND UPPER(uid) = ?`,
        [BOOK_ID, 'T1']);
      try {
        expect(rs.goToNextRow()).assertTrue();
        expect(rs.getLong(rs.getColumnIndex('deleted_at')) > 0).assertTrue();
        expect(rs.getLong(rs.getColumnIndex('rev'))).assertEqual(9);
        expect(rs.getLong(rs.getColumnIndex('base_rev'))).assertEqual(9);
        expect(rs.getLong(rs.getColumnIndex('dirty'))).assertEqual(0);
      } finally {
        rs.close();
      }

      // 其他族人的父/母/配偶引用被断开
      const rsChild: relationalStore.ResultSet = await s.querySql(
        `SELECT father_id, mother_id, spouse_id FROM ${TABLE_PERSON} WHERE book_id = ? AND UPPER(uid) = ?`,
        [BOOK_ID, 'B1']);
      try {
        expect(rsChild.goToNextRow()).assertTrue();
        expect(rsChild.getString(rsChild.getColumnIndex('father_id'))).assertEqual('');
        expect(rsChild.getString(rsChild.getColumnIndex('mother_id'))).assertEqual('');
        expect(rsChild.getString(rsChild.getColumnIndex('spouse_id'))).assertEqual('');
      } finally {
        rsChild.close();
      }

      // 配偶关系两侧记录都被清除
      const rsSpouse: relationalStore.ResultSet = await s.querySql(
        `SELECT COUNT(*) AS c FROM ${TABLE_SPOUSE} WHERE book_id = ? AND (UPPER(uid) = ? OR UPPER(spouse_uid) = ?)`,
        [BOOK_ID, 'T1', 'T1']);
      try {
        expect(rsSpouse.goToNextRow()).assertTrue();
        expect(rsSpouse.getLong(rsSpouse.getColumnIndex('c'))).assertEqual(0);
      } finally {
        rsSpouse.close();
      }
    });

    it('guardsEmptyUidAndMissingStore', 0, async () => {
      const peopleStore: PeopleStore = new PeopleStore();
      peopleStore.rebuildMap();
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const replay: CloudReplay = replayOf(s, peopleStore, [], (): void => {
      });
      expect(await replay.applyRemoteChange('', person('X1', '空号'), 1, false)).assertFalse();
      expect(await replay.applyRemoteChange('   ', person('X2', '空白'), 1, false)).assertFalse();

      const repo: PersonRepository = new PersonRepository(
        (): relationalStore.RdbStore | null => null, (): number => BOOK_ID, peopleStore);
      const noStore: CloudReplay = new CloudReplay((): relationalStore.RdbStore | null => null,
        (): number => BOOK_ID, peopleStore, repo,
        async (uid: string, name: string): Promise<void> => {
        }, async (): Promise<void> => {
        });
      expect(await noStore.applyRemoteChange('X3', person('X3', '无库'), 1, false)).assertFalse();
    });

    it('reloadAfterReplayInvokesReloader', 0, async () => {
      const peopleStore: PeopleStore = new PeopleStore();
      peopleStore.rebuildMap();
      let reloaded: boolean = false;
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const replay: CloudReplay = replayOf(s, peopleStore, [], (): void => {
        reloaded = true;
      });
      await replay.reloadAfterReplay();
      expect(reloaded).assertTrue();
    });
  });
}
