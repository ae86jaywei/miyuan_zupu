import { Person, PersonIndex, copyPersonInto } from 'common_base';
import { PeopleStore } from './PeopleStore';
import { SpouseRelations } from './SpouseRelations';

/**
 * 编辑事务的内存态刷新域。
 *
 * 从 `GenealogyService` 拆出：数据库写入由服务负责，这里只处理保存后的内存增量——
 *  - 仅普通字段变化：原地改写 Person（谱系节点持有同一引用），只递增版本号；
 *  - 编号 / 父母 / 配偶关系变化：在内存数组上打补丁，重建 uid 映射、配偶反向引用与谱系树。
 * 避免每次保存都 `reload()` 全表回读（大谱上数秒，长任务会被看门狗强杀）。
 */
export class PersonEditor {
  private store: PeopleStore;
  private spouses: SpouseRelations;
  /** 搜索索引：保存后必须同步，否则新增/改名要等切换族谱（reload）才可见 */
  private index: PersonIndex;

  constructor(store: PeopleStore, spouses: SpouseRelations, index: PersonIndex) {
    this.store = store;
    this.spouses = spouses;
    this.index = index;
  }

  /** 保存后的内存增量刷新 */
  applySaved(person: Person, originalUid: string): void {
    const prevUid: string = originalUid.trim().toUpperCase();
    const nextUid: string = person.uid.trim().toUpperCase();
    const old: Person | undefined = this.store.getMap().get(prevUid.length > 0 ? prevUid : nextUid);
    const structural: boolean = old === undefined
      || prevUid !== nextUid
      || old.fatherId.trim().toUpperCase() !== person.fatherId.trim().toUpperCase()
      || old.motherId.trim().toUpperCase() !== person.motherId.trim().toUpperCase()
      || this.spouses.linksChanged(old.spouses, person.spouses);
    if (!structural && old !== undefined) {
      // 普通字段：原地改写，谱系节点持有的对象引用不变，无需重建树
      // ⚠️ 先从搜索索引移除「旧人」——在 copyPersonInto 之前，
      // 否则 old.name 已是新值，index.remove 会从新首字母桶清理，
      // 旧首字母桶里留下 stale 条目导致搜索错乱。
      this.index.remove(old.uid);
      copyPersonInto(old, person);
      this.index.add(old);
      this.store.bump();
      return;
    }
    const oldObj: Person | null = old === undefined ? null : old;
    // 1. 在内存列表中定位并替换（新增时追加）
    let index: number = -1;
    for (let i: number = 0; i < this.store.getAll().length; i++) {
      const u: string = this.store.getAll()[i].uid.trim().toUpperCase();
      if (u === prevUid || u === nextUid) {
        index = i;
        break;
      }
    }
    if (index >= 0) {
      this.store.setAt(index, person);
    } else {
      this.store.push(person);
    }
    // 2. 编号变更：同步其他族人的父母ID / 配偶ID
    if (prevUid.length > 0 && prevUid !== nextUid) {
      for (let i: number = 0; i < this.store.getAll().length; i++) {
        const p: Person = this.store.getAll()[i];
        if (p.uid.trim().toUpperCase() === nextUid) {
          continue;
        }
        if (p.fatherId.trim().toUpperCase() === prevUid) {
          p.fatherId = nextUid;
        }
        if (p.motherId.trim().toUpperCase() === prevUid) {
          p.motherId = nextUid;
        }
        if (p.spouseId.trim().toUpperCase() === prevUid) {
          p.spouseId = nextUid;
        }
        for (let j: number = 0; j < p.spouses.length; j++) {
          if (p.spouses[j].uid.trim().toUpperCase() === prevUid) {
            p.spouses[j].uid = nextUid;
          }
        }
      }
    }
    // 3. 重建索引
    this.store.rebuildMap();
    // 4. 同步搜索索引：
    //    - 改编号：先移除旧 uid（用 prevUid 而非 person.uid，person.uid 已是新值）
    //    - 改姓名等搜索字段：index.update 会先删后加
    if (prevUid.length > 0 && prevUid !== nextUid) {
      this.index.remove(prevUid);
      this.index.add(person);
    } else {
      this.index.update(person);
    }
    // 5. 同步配偶反向引用（对方向本人的记录）
    this.spouses.syncBackRefs(person, oldObj, prevUid);
    // 6. 重建谱系树并发布新版本
    this.store.rebuildRoots();
    this.store.bump();
  }
}
