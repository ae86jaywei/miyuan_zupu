import { describe, it, expect } from '@ohos/hypium';
import { Person, PersonIndex, createEmptyPerson } from 'common_base';

function person(uid: string, name: string): Person {
  const p: Person = createEmptyPerson();
  p.uid = uid;
  p.name = name;
  return p;
}

export default function personIndexTest() {
  describe('PersonIndex', () => {
    it('buildAndLookup', 0, () => {
      const index: PersonIndex = new PersonIndex();
      expect(index.isBuilt()).assertFalse();
      expect(index.getByUid('A1') === null).assertTrue();

      index.build([person('A1', '张三'), person('B2', '李四')]);
      expect(index.isBuilt()).assertTrue();
      expect(index.size()).assertEqual(2);
      expect(index.getByUid('a1')?.name).assertEqual('张三');
      expect(index.getByUid(' NOPE ') === null).assertTrue();
    });

    it('singleCharUsesFirstCharBucket', 0, () => {
      const index: PersonIndex = new PersonIndex();
      const people: Person[] = [];
      for (let i: number = 0; i < 50; i = i + 1) {
        people.push(person('U' + i.toString(), '张' + i.toString()));
      }
      index.build(people);
      // 单字命中首字母桶，最多返回 40 条
      expect(index.search('张').length).assertEqual(40);
      expect(index.search('  ').length).assertEqual(0);
    });

    it('searchMatchesAliasAndUid', 0, () => {
      const index: PersonIndex = new PersonIndex();
      const p: Person = person('F5601', '长泽传');
      p.alias = '小泽';
      p.courtesyName = '伯川';
      index.build([p]);
      expect(index.search('小泽').length).assertEqual(1);
      expect(index.search('伯川').length).assertEqual(1);
      expect(index.search('5601').length).assertEqual(1);
      expect(index.search('不存在').length).assertEqual(0);
    });

    it('addRemoveUpdate', 0, () => {
      const index: PersonIndex = new PersonIndex();
      index.build([]);
      index.add(person('A1', '张三'));
      expect(index.size()).assertEqual(1);
      index.update(person('A1', '张三丰'));
      expect(index.getByUid('A1')?.name).assertEqual('张三丰');
      index.remove('a1');
      expect(index.size()).assertEqual(0);
      expect(index.getByUid('A1') === null).assertTrue();
    });

    it('jumpIndexAndReset', 0, () => {
      const index: PersonIndex = new PersonIndex();
      index.build([person('A1', '张三')]);
      index.setRow('A1', 3);
      index.setDiePage('A1', 9);
      expect(index.getRow('a1')).assertEqual(3);
      expect(index.getDiePage('A1')).assertEqual(9);
      expect(index.getRow('NOPE')).assertEqual(-1);
      index.clearJumpIndex();
      expect(index.getRow('A1')).assertEqual(-1);
      expect(index.getDiePage('A1')).assertEqual(-1);
      index.reset();
      expect(index.isBuilt()).assertFalse();
      expect(index.size()).assertEqual(0);
    });
  });
}
