import { describe, it, expect } from '@ohos/hypium';
import { Person, createEmptyPerson } from 'common_base';
import { PeopleStore } from '../main/ets/service/PeopleStore';
import { SpouseRelations } from '../main/ets/service/SpouseRelations';
import { PersonEditor } from '../main/ets/service/PersonEditor';

function person(uid: string, name: string): Person {
  const p: Person = createEmptyPerson();
  p.uid = uid;
  p.name = name;
  return p;
}

function editorOf(store: PeopleStore): PersonEditor {
  return new PersonEditor(store, new SpouseRelations(store));
}

export default function personEditorTest() {
  describe('PersonEditor', () => {
    it('plainFieldChangeKeepsObjectIdentity', 0, () => {
      const store: PeopleStore = new PeopleStore();
      const origin: Person = person('A1', '张三');
      store.setList([origin]);
      store.rebuildMap();
      store.rebuildRoots();
      const rootsBefore: number = store.getRoots().length;
      const versionBefore: number = store.getVersion();

      const edited: Person = person('A1', '张三丰');
      editorOf(store).applySaved(edited, 'A1');

      expect(store.getPerson('A1')?.name).assertEqual('张三丰');
      // 普通字段走原地改写：列表仍是同一个 Person 引用
      expect(store.getAll()[0] === origin).assertTrue();
      expect(store.getRoots().length).assertEqual(rootsBefore);
      expect(store.getVersion()).assertEqual(versionBefore + 1);
    });

    it('uidChangeRebuildsMapAndReferences', 0, () => {
      const store: PeopleStore = new PeopleStore();
      const father: Person = person('F1', '父亲');
      const child: Person = person('C1', '儿子');
      child.fatherId = 'F1';
      store.setList([father, child]);
      store.rebuildMap();
      store.rebuildRoots();

      const renamed: Person = person('F2', '父亲');
      editorOf(store).applySaved(renamed, 'F1');

      expect(store.getMap().get('F1') === undefined).assertTrue();
      expect(store.getPerson('F2')?.name).assertEqual('父亲');
      // 子女的父引用同步到新编号
      expect(store.getPerson('C1')?.fatherId).assertEqual('F2');
      // 树已重建：F2 成为根，且能连到 C1
      expect(store.getRoots().length).assertEqual(1);
      expect(store.getRoots()[0].uid).assertEqual('F2');
      expect(store.getRoots()[0].children.length).assertEqual(1);
    });

    it('newPersonIsAppended', 0, () => {
      const store: PeopleStore = new PeopleStore();
      store.setList([person('A1', '张三')]);
      store.rebuildMap();
      store.rebuildRoots();

      editorOf(store).applySaved(person('N1', '新人'), '');

      expect(store.getAll().length).assertEqual(2);
      expect(store.getPerson('N1')?.name).assertEqual('新人');
      expect(store.getMap().size).assertEqual(2);
    });
  });
}
