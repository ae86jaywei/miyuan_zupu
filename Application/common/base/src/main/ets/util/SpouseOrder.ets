import { Person } from '../model/Person';

/**
 * 夫妻排序：同一辈份内把夫妻排成一组，丈夫在前、妻子紧随。
 *
 * 名录、现代创新式、牒记式都按「世代 → 列表原始顺序」平铺展示，
 * 若妻子先于丈夫录入，就会出现妻在夫前的错序。这里只调整相对次序：
 *  - 有夫之妇让位，紧跟丈夫输出；
 *  - 一夫多妻时，诸妻保持各自原有先后；
 *  - 配偶不在当前列表（被筛选掉）时按原位置输出。
 */
export class SpouseOrder {
  /** 统一 uid 比较键 */
  private static key(p: Person): string {
    return p.uid.trim().toUpperCase();
  }

  static maleFirst(people: Person[]): Person[] {
    if (people.length < 2) {
      return people;
    }
    const inList: Map<string, Person> = new Map<string, Person>();
    for (let i: number = 0; i < people.length; i = i + 1) {
      const k: string = SpouseOrder.key(people[i]);
      if (k.length > 0 && !inList.has(k)) {
        inList.set(k, people[i]);
      }
    }
    // 妻 → 夫：任一方登记配偶即可识别
    const husbandOf: Map<string, string> = new Map<string, string>();
    for (let i: number = 0; i < people.length; i = i + 1) {
      const p: Person = people[i];
      const pk: string = SpouseOrder.key(p);
      if (pk.length === 0) {
        continue;
      }
      for (let j: number = 0; j < p.spouses.length; j = j + 1) {
        const sk: string = p.spouses[j].uid.trim().toUpperCase();
        if (sk.length === 0 || sk === pk) {
          continue;
        }
        const sp: Person | undefined = inList.get(sk);
        if (sp === undefined) {
          continue;
        }
        if (p.gender === '男' && sp.gender === '女') {
          if (!husbandOf.has(sk)) {
            husbandOf.set(sk, pk);
          }
        } else if (p.gender === '女' && sp.gender === '男') {
          if (!husbandOf.has(pk)) {
            husbandOf.set(pk, sk);
          }
        }
      }
    }
    if (husbandOf.size === 0) {
      return people;
    }
    // 夫 → 诸妻（保持原列表中的先后）
    const wivesOf: Map<string, Person[]> = new Map<string, Person[]>();
    for (let i: number = 0; i < people.length; i = i + 1) {
      const p: Person = people[i];
      const hk: string | undefined = husbandOf.get(SpouseOrder.key(p));
      if (hk === undefined) {
        continue;
      }
      const arr: Person[] | undefined = wivesOf.get(hk);
      if (arr === undefined) {
        wivesOf.set(hk, [p]);
      } else {
        arr.push(p);
      }
    }
    const emitted: Set<string> = new Set<string>();
    const out: Person[] = [];
    for (let i: number = 0; i < people.length; i = i + 1) {
      const p: Person = people[i];
      const pk: string = SpouseOrder.key(p);
      if (pk.length === 0) {
        out.push(p);
        continue;
      }
      if (emitted.has(pk)) {
        continue;
      }
      // 有夫之妇不在此处输出，等遍历到丈夫时紧随其后
      if (p.gender === '女' && husbandOf.has(pk)) {
        continue;
      }
      out.push(p);
      emitted.add(pk);
      const wives: Person[] | undefined = wivesOf.get(pk);
      if (wives !== undefined) {
        for (let w: number = 0; w < wives.length; w = w + 1) {
          const wk: string = SpouseOrder.key(wives[w]);
          if (!emitted.has(wk)) {
            out.push(wives[w]);
            emitted.add(wk);
          }
        }
      }
    }
    // 保险：环等异常数据导致漏输出时按原顺序补齐（空 uid 已在主循环输出）
    if (out.length < people.length) {
      for (let i: number = 0; i < people.length; i = i + 1) {
        const pk: string = SpouseOrder.key(people[i]);
        if (pk.length > 0 && !emitted.has(pk)) {
          out.push(people[i]);
        }
      }
    }
    return out;
  }
}
