import { describe, it, expect } from '@ohos/hypium';
import { Person, createEmptyPerson } from 'common_base';
import { PeopleStore } from '../main/ets/service/PeopleStore';

function person(uid: string, name: string): Person {
  const p: Person = createEmptyPerson();
  p.uid = uid;
  p.name = name;
  return p;
}

export default function peopleStoreTest() {
  describe('PeopleStore', () => {
    it('rebuildMapUsesUpperUid', 0, () => {
      const store: PeopleStore = new PeopleStore();
      store.setList([person('a1', '张三'), person('B2', '李四')]);
      store.rebuildMap();
      expect(store.getMap().size).assertEqual(2);
      expect(store.getMap().get('A1')?.name).assertEqual('张三');
      expect(store.getMap().get('B2')?.name).assertEqual('李四');
    });

    it('getPersonFallsBackToTrimUpper', 0, () => {
      const store: PeopleStore = new PeopleStore();
      store.setList([person('A1', '张三')]);
      store.rebuildMap();
      expect(store.getPerson(' a1 ')?.name).assertEqual('张三');
      expect(store.getPerson('') === null).assertTrue();
      expect(store.getPerson('NOPE') === null).assertTrue();
    });

    it('setAtPushResetAndVersion', 0, () => {
      const store: PeopleStore = new PeopleStore();
      store.setList([person('A1', '张三')]);
      store.setAt(0, person('A1', '张老三'));
      expect(store.getAll()[0].name).assertEqual('张老三');
      store.push(person('C3', '王五'));
      expect(store.getAll().length).assertEqual(2);
      const before: number = store.getVersion();
      store.bump();
      expect(store.getVersion()).assertEqual(before + 1);
      store.reset();
      expect(store.getAll().length).assertEqual(0);
      expect(store.getMap().size).assertEqual(0);
      expect(store.getRoots().length).assertEqual(0);
    });

    it('rebuildRootsBuildsTree', 0, () => {
      const store: PeopleStore = new PeopleStore();
      const father: Person = person('F1', '父亲');
      const child: Person = person('C1', '儿子');
      child.fatherId = 'F1';
      store.setList([father, child]);
      store.rebuildMap();
      store.rebuildRoots();
      expect(store.getRoots().length).assertEqual(1);
      expect(store.getRoots()[0].uid).assertEqual('F1');
    });
  });
}
