import { describe, it, expect } from '@ohos/hypium';
import { Person, SpouseRelation, createEmptyPerson, spouseRelationLevel } from 'common_base';
import { PeopleStore } from '../main/ets/service/PeopleStore';
import { SpouseRelations } from '../main/ets/service/SpouseRelations';

function person(uid: string, name: string, gender: string): Person {
  const p: Person = createEmptyPerson();
  p.uid = uid;
  p.name = name;
  p.gender = gender;
  return p;
}

function relation(uid: string, relation: string, order: number): SpouseRelation {
  const r: SpouseRelation = new SpouseRelation();
  r.uid = uid;
  r.relation = relation;
  r.level = spouseRelationLevel(relation);
  r.order = order;
  return r;
}

export default function spouseRelationsTest() {
  describe('SpouseRelations', () => {
    it('spouseTextOfUsesRelationPrefix', 0, () => {
      const store: PeopleStore = new PeopleStore();
      const husband: Person = person('H1', '张公', '男');
      const wife: Person = person('W1', '李氏', '女');
      husband.spouses = [relation('W1', '元配', 1)];
      store.setList([husband, wife]);
      store.rebuildMap();
      const domain: SpouseRelations = new SpouseRelations(store);
      expect(domain.spouseTextOf('H1')).assertEqual('配 李氏');
      expect(domain.spouseOf('H1')?.uid).assertEqual('W1');
      expect(domain.spousesOf('W1').length).assertEqual(0);
    });

    it('linksChangedDetectsStructuralChange', 0, () => {
      const store: PeopleStore = new PeopleStore();
      const domain: SpouseRelations = new SpouseRelations(store);
      const a: SpouseRelation[] = [relation('W1', '元配', 1)];
      const b: SpouseRelation[] = [relation('W1', '继室', 1)];
      expect(domain.linksChanged(a, b)).assertTrue();
      expect(domain.linksChanged(a, [relation('W1', '元配', 1)])).assertFalse();
      expect(domain.linksChanged(a, [])).assertTrue();
    });

    it('syncBackRefsAddsReverseRelation', 0, () => {
      const store: PeopleStore = new PeopleStore();
      const husband: Person = person('H1', '张公', '男');
      const wife: Person = person('W1', '李氏', '女');
      husband.spouses = [relation('W1', '元配', 1)];
      store.setList([husband, wife]);
      store.rebuildMap();
      const domain: SpouseRelations = new SpouseRelations(store);
      domain.syncBackRefs(husband, null, '');
      expect(wife.spouses.length).assertEqual(1);
      expect(wife.spouses[0].uid).assertEqual('H1');
      expect(wife.spouseId).assertEqual('H1');
    });
  });
}
