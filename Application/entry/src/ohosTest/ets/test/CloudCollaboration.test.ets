import { describe, it, expect } from '@ohos/hypium';
import { relationalStore } from '@kit.ArkData';
import { Genealogy, Person, createEmptyGenealogy, createEmptyPerson } from 'common_base';
import { CloudCollaboration } from '../../../main/ets/service/CloudCollaboration';
import { PeopleStore } from '../../../main/ets/service/PeopleStore';

function person(uid: string, name: string, deletedAt: number): Person {
  const p: Person = createEmptyPerson();
  p.uid = uid;
  p.name = name;
  p.deletedAt = deletedAt;
  return p;
}

export default function cloudCollaborationTest() {
  describe('CloudCollaboration', () => {
    it('isDeletedReadsTombstoneFlag', 0, () => {
      const peopleStore: PeopleStore = new PeopleStore();
      peopleStore.setList([person('P1', '已删', 1000), person('P2', '在世', 0)]);
      peopleStore.rebuildMap();
      const domain: CloudCollaboration = new CloudCollaboration(peopleStore,
        (): Genealogy => createEmptyGenealogy(),
        (): relationalStore.RdbStore | null => null, (): number => 0);

      expect(domain.isDeleted('P1')).assertTrue();
      // 大小写与空白不敏感
      expect(domain.isDeleted(' p1 ')).assertTrue();
      expect(domain.isDeleted('P2')).assertFalse();
      expect(domain.isDeleted('NOPE')).assertFalse();
      expect(domain.isDeleted('')).assertFalse();
    });

    it('captureBeforeToleratesMissingPerson', 0, () => {
      const peopleStore: PeopleStore = new PeopleStore();
      peopleStore.setList([person('P1', '甲', 0)]);
      peopleStore.rebuildMap();
      const domain: CloudCollaboration = new CloudCollaboration(peopleStore,
        (): Genealogy => createEmptyGenealogy(),
        (): relationalStore.RdbStore | null => null, (): number => 0);

      domain.captureBefore('p1');
      domain.captureBefore('NOPE');
      // 快照只写内存，不影响墓碑判定
      expect(domain.isDeleted('P1')).assertFalse();
    });

    it('notifySkipsWhenBookIsLocalOnly', 0, async () => {
      const peopleStore: PeopleStore = new PeopleStore();
      peopleStore.setList([person('P1', '甲', 0)]);
      peopleStore.rebuildMap();
      // 未接入云家族的谱：不应触碰数据库，更不应发起云端请求
      let storeTouched: boolean = false;
      const domain: CloudCollaboration = new CloudCollaboration(peopleStore,
        (): Genealogy => createEmptyGenealogy(),
        (): relationalStore.RdbStore | null => {
          storeTouched = true;
          return null;
        }, (): number => 0);

      domain.captureBefore('P1');
      await domain.notifyPersonChange('UPDATE', person('P1', '乙', 0), 'P1');
      expect(storeTouched).assertFalse();
    });
  });
}
