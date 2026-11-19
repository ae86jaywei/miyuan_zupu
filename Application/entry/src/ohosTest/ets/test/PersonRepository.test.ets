import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { relationalStore } from '@kit.ArkData';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { UIAbility, common, Want } from '@kit.AbilityKit';
import { Person, SpouseRelation, createEmptyPerson, spouseRelationLevel } from 'common_base';
import { DatabaseSchema, TABLE_PERSON, TABLE_SPOUSE } from '../../../main/ets/service/db/DatabaseSchema';
import { PersonRepository } from '../../../main/ets/service/PersonRepository';
import { PeopleStore } from '../../../main/ets/service/PeopleStore';

/** 测试专用族谱ID，避开真实数据 */
const BOOK_ID: number = 990001;

function person(uid: string, name: string, gender: string): Person {
  const p: Person = createEmptyPerson();
  p.uid = uid;
  p.name = name;
  p.gender = gender;
  return p;
}

function relation(uid: string, rel: string, order: number): SpouseRelation {
  const r: SpouseRelation = new SpouseRelation();
  r.uid = uid;
  r.relation = rel;
  r.level = spouseRelationLevel(rel);
  r.order = order;
  return r;
}

export default function personRepositoryTest() {
  describe('PersonRepository', () => {
    let store: relationalStore.RdbStore | null = null;
    let peopleStore: PeopleStore = new PeopleStore();
    let repo: PersonRepository | null = null;

    beforeAll(async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      // 测试进程不会自动拉起 TestAbility，先启动它再取 UIAbilityContext（RDB 需要）
      const want: Want = {
        bundleName: 'com.zupu.ae86jay',
        moduleName: 'entry_test',
        abilityName: 'TestAbility'
      };
      try {
        await delegator.startAbility(want);
      } catch (e) {
      }
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 1000);
      });
      const ability: UIAbility = await delegator.getCurrentTopAbility() as UIAbility;
      const context: common.UIAbilityContext = ability.context;
      const cfg: relationalStore.StoreConfig = {
        name: 'ohos_test_genealogy.db',
        securityLevel: relationalStore.SecurityLevel.S1
      };
      store = await relationalStore.getRdbStore(context, cfg);
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      await DatabaseSchema.createTables(s);
      await s.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [BOOK_ID]);
      await s.executeSql(`DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ?`, [BOOK_ID]);
      peopleStore = new PeopleStore();
      repo = new PersonRepository((): relationalStore.RdbStore | null => store, (): number => BOOK_ID, peopleStore);
    });

    afterAll(async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      await s.executeSql(`DELETE FROM ${TABLE_PERSON} WHERE book_id = ?`, [BOOK_ID]);
      await s.executeSql(`DELETE FROM ${TABLE_SPOUSE} WHERE book_id = ?`, [BOOK_ID]);
    });

    it('insertAndUpdateByKey', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const r: PersonRepository = repo as PersonRepository;
      const p: Person = person('T1', '测试甲', '男');
      await r.upsert(p, BOOK_ID);
      expect(p.key > 0).assertTrue();

      p.name = '测试甲改名';
      await r.upsert(p, BOOK_ID);
      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT name FROM ${TABLE_PERSON} WHERE book_id = ? AND UPPER(uid) = ?`, [BOOK_ID, 'T1']);
      try {
        expect(rs.goToNextRow()).assertTrue();
        expect(rs.getString(rs.getColumnIndex('name'))).assertEqual('测试甲改名');
      } finally {
        rs.close();
      }
    });

    it('saveSpousesWritesBothDirections', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const r: PersonRepository = repo as PersonRepository;
      const husband: Person = person('H1', '张公', '男');
      const wife: Person = person('W1', '李氏', '女');
      husband.spouses = [relation('W1', '元配', 1)];
      peopleStore.setList([husband, wife]);
      peopleStore.rebuildMap();
      await r.upsert(husband, BOOK_ID);
      await r.upsert(wife, BOOK_ID);

      await r.saveSpouses('H1', husband.spouses, BOOK_ID);

      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT uid, spouse_uid, relation FROM ${TABLE_SPOUSE} WHERE book_id = ? ORDER BY uid`, [BOOK_ID]);
      let rows: number = 0;
      let reverse: string = '';
      try {
        while (rs.goToNextRow()) {
          const owner: string = rs.getString(rs.getColumnIndex('uid'));
          if (owner === 'W1') {
            reverse = rs.getString(rs.getColumnIndex('relation'));
          }
          rows = rows + 1;
        }
      } finally {
        rs.close();
      }
      // 正向 + 反向各一条
      expect(rows).assertEqual(2);
      // 女方对男方的称谓应为「夫」
      expect(reverse).assertEqual('夫');
      // 兼容旧字段 spouse_id 同步
      const rs2: relationalStore.ResultSet = await s.querySql(
        `SELECT spouse_id FROM ${TABLE_PERSON} WHERE book_id = ? AND UPPER(uid) = ?`, [BOOK_ID, 'W1']);
      try {
        expect(rs2.goToNextRow()).assertTrue();
        expect(rs2.getString(rs2.getColumnIndex('spouse_id'))).assertEqual('H1');
      } finally {
        rs2.close();
      }
    });

    it('deleteRowsRemovesPersonAndRelations', 0, async () => {
      const s: relationalStore.RdbStore = store as relationalStore.RdbStore;
      const r: PersonRepository = repo as PersonRepository;
      await r.deleteRows('H1', false);

      const rs: relationalStore.ResultSet = await s.querySql(
        `SELECT COUNT(*) AS c FROM ${TABLE_PERSON} WHERE book_id = ? AND UPPER(uid) = ?`, [BOOK_ID, 'H1']);
      try {
        expect(rs.goToNextRow()).assertTrue();
        expect(rs.getLong(rs.getColumnIndex('c'))).assertEqual(0);
      } finally {
        rs.close();
      }
      const rs2: relationalStore.ResultSet = await s.querySql(
        `SELECT COUNT(*) AS c FROM ${TABLE_SPOUSE} WHERE book_id = ? AND (UPPER(uid) = ? OR UPPER(spouse_uid) = ?)`,
        [BOOK_ID, 'H1', 'H1']);
      try {
        expect(rs2.goToNextRow()).assertTrue();
        expect(rs2.getLong(rs2.getColumnIndex('c'))).assertEqual(0);
      } finally {
        rs2.close();
      }
    });
  });
}
