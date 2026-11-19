import { Person, SpouseRelation } from 'common_base';
import { PeopleStore } from './PeopleStore';

/**
 * 人员关系查询域：子女、兄弟姊妹、上下三代关系链。
 *
 * 从 `GenealogyService` 拆出，只依赖 `PeopleStore` 的数据视图，不涉及数据库与写入。
 * 查询结果按人员列表原有顺序返回，不做额外排序，保持与原实现一致。
 */
export class PersonQuery {
  private store: PeopleStore;

  constructor(store: PeopleStore) {
    this.store = store;
  }

  /** 子女 */
  childrenOf(uid: string): Person[] {
    const u: string = uid.trim().toUpperCase();
    return this.store.getAll().filter((p: Person): boolean => {
      return p.fatherId.trim().toUpperCase() === u || p.motherId.trim().toUpperCase() === u;
    });
  }

  /** 某人与指定配偶共同生育的子女（父母双方均匹配） */
  childrenWithSpouse(uid: string, spouseUid: string): Person[] {
    const a: string = uid.trim().toUpperCase();
    const b: string = spouseUid.trim().toUpperCase();
    if (a.length === 0 || b.length === 0) {
      return [];
    }
    return this.store.getAll().filter((p: Person): boolean => {
      const f: string = p.fatherId.trim().toUpperCase();
      const m: string = p.motherId.trim().toUpperCase();
      return (f === a && m === b) || (f === b && m === a);
    });
  }

  /** 兄弟姊妹（不含本人） */
  siblingsOf(uid: string): Person[] {
    const p: Person | null = this.store.getPerson(uid);
    if (p === null) {
      return [];
    }
    const u: string = p.uid.toUpperCase();
    const f: string = p.fatherId.trim().toUpperCase();
    const m: string = p.motherId.trim().toUpperCase();
    if (f.length === 0 && m.length === 0) {
      return [];
    }
    return this.store.getAll().filter((x: Person): boolean => {
      const xu: string = x.uid.toUpperCase();
      if (xu === u) {
        return false;
      }
      const xf: string = x.fatherId.trim().toUpperCase();
      const xm: string = x.motherId.trim().toUpperCase();
      return (f.length > 0 && xf === f) || (m.length > 0 && xm === m);
    });
  }

  /** 上下三代（含自身），用于详情页关系链 */
  relativesOf(uid: string): Person[] {
    const p: Person | null = this.store.getPerson(uid);
    const result: Person[] = [];
    if (p === null) {
      return result;
    }
    const f: Person | null = this.store.getPerson(p.fatherId);
    const m: Person | null = this.store.getPerson(p.motherId);
    if (f !== null) {
      result.push(f);
    }
    if (m !== null && m.uid !== (f === null ? '' : f.uid)) {
      result.push(m);
    }
    p.spouses.forEach((r: SpouseRelation): void => {
      const s: Person | null = this.store.getPerson(r.uid);
      if (s !== null) {
        result.push(s);
      }
    });
    this.childrenOf(uid).forEach((c: Person): void => {
      result.push(c);
    });
    this.siblingsOf(uid).forEach((c: Person): void => {
      result.push(c);
    });
    return result;
  }
}
