import { describe, it, expect } from '@ohos/hypium';
import { Person, PersonIndex, createEmptyPerson } from 'common_base';
import { PeopleStore } from '../main/ets/service/PeopleStore';
import { PersonQuery } from '../main/ets/service/PersonQuery';
import { PersonSearch } from '../main/ets/service/PersonSearch';

function person(uid: string, name: string): Person {
  const p: Person = createEmptyPerson();
  p.uid = uid;
  p.name = name;
  return p;
}

export default function queryAndSearchTest() {
  describe('PersonQuery', () => {
    it('childrenSiblingsRelatives', 0, () => {
      const store: PeopleStore = new PeopleStore();
      const father: Person = person('F1', '父亲');
      const mother: Person = person('M1', '母亲');
      const son: Person = person('S1', '长子');
      const daughter: Person = person('D1', '长女');
      son.fatherId = 'F1';
      son.motherId = 'M1';
      daughter.fatherId = 'F1';
      daughter.motherId = 'M1';
      father.spouses = [];
      store.setList([father, mother, son, daughter]);
      store.rebuildMap();
      store.rebuildRoots();
      const query: PersonQuery = new PersonQuery(store);
      expect(query.childrenOf('F1').length).assertEqual(2);
      expect(query.childrenWithSpouse('F1', 'M1').length).assertEqual(2);
      expect(query.siblingsOf('S1').length).assertEqual(1);
      expect(query.relativesOf('S1').length).assertEqual(3);
    });
  });

  describe('PersonSearch', () => {
    it('searchAndJumpIndex', 0, () => {
      const store: PeopleStore = new PeopleStore();
      const index: PersonIndex = new PersonIndex();
      const list: Person[] = [person('A1', '张三'), person('B2', '李四'), person('C3', '张四')];
      store.setList(list);
      store.rebuildMap();
      index.build(list);
      const search: PersonSearch = new PersonSearch(index, (): Person[] => store.getAll());
      expect(search.search('').length).assertEqual(3);
      expect(search.search('张').length).assertEqual(2);
      expect(search.search('B2').length).assertEqual(1);
      expect(search.search('B2')[0].name).assertEqual('李四');
      expect(search.getByUid('c3')?.name).assertEqual('张四');
      search.setJumpRow('A1', 7);
      expect(search.getJumpRow('a1')).assertEqual(7);
      search.setDiePage('A1', 12);
      expect(search.getDiePage('A1')).assertEqual(12);
      search.clearJumpIndex();
      expect(search.getJumpRow('A1')).assertEqual(-1);
    });
  });
}
