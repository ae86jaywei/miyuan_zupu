import { Person, SpouseRelation, cloneSpouseRelation, normalizeSpouseRelation, spouseRelationLevel } from 'common_base';
import { PeopleStore } from './PeopleStore';

/**
 * 配偶关系域：配偶查询、展示文案、关系变化判定与内存态反向引用同步。
 *
 * 从 `GenealogyService` 拆出，只依赖 `PeopleStore` 的数据视图；
 * 数据库读写仍由服务负责，避免领域类依赖存储层。
 */
export class SpouseRelations {
  private store: PeopleStore;

  constructor(store: PeopleStore) {
    this.store = store;
  }

  /** 当前人物的全部配偶关系（含元配/继室/妾等名分，按顺序排列） */
  spousesOf(uid: string): SpouseRelation[] {
    const p: Person | null = this.store.getPerson(uid);
    if (p === null) {
      return [];
    }
    return p.spouses.map((r: SpouseRelation): SpouseRelation => cloneSpouseRelation(r));
  }

  /** 主配偶（第一位） */
  spouseOf(uid: string): Person | null {
    const p: Person | null = this.store.getPerson(uid);
    if (p === null || p.spouses.length === 0) {
      return null;
    }
    return this.store.getPerson(p.spouses[0].uid);
  }

  /** 配偶展示文案，如：“配 林氏、继室 陈氏、妾 李氏” */
  spouseTextOf(uid: string): string {
    const p: Person | null = this.store.getPerson(uid);
    if (p === null || p.spouses.length === 0) {
      return '';
    }
    // 卡片渲染高频调用：字符串累加替代数组 + join
    let text: string = '';
    for (let i: number = 0; i < p.spouses.length; i++) {
      const sp: Person | null = this.store.getPerson(p.spouses[i].uid);
      if (sp === null) {
        continue;
      }
      const rel: string = normalizeSpouseRelation(p.spouses[i].relation);
      const prefix: string = (rel === '元配' || rel === '未记' || rel === '配偶') ?
        '配' : rel;
      if (text.length > 0) {
        text += '、';
      }
      text += prefix + ' ' + sp.name;
    }
    return text;
  }

  /** 配偶关系是否有变化：数量、对象编号或称谓不同都算结构变化 */
  linksChanged(a: SpouseRelation[], b: SpouseRelation[]): boolean {
    if (a.length !== b.length) {
      return true;
    }
    for (let i: number = 0; i < a.length; i++) {
      if (a[i].uid.trim().toUpperCase() !== b[i].uid.trim().toUpperCase()
        || a[i].relation !== b[i].relation) {
        return true;
      }
    }
    return false;
  }

  /**
   * 同步配偶的反向引用（仅内存态）：A 的配偶表里写了 B 时，B 的配偶表里也应写上 A。
   * 数据库侧由 saveSpouses 负责，这里避免为了这一处引用再去全表重载。
   */
  syncBackRefs(person: Person, old: Person | null, prevUid: string): void {
    const self: string = person.uid.trim().toUpperCase();
    const prev: string = prevUid.trim().toUpperCase();
    // 1. 本次保存后的配偶集合
    const next: Set<string> = new Set<string>();
    person.spouses.forEach((r: SpouseRelation): void => {
      const id: string = r.uid.trim().toUpperCase();
      if (id.length > 0 && id !== self) {
        next.add(id);
      }
    });
    // 2. 处理旧关系：仍保留的改编号，已移除的从对方配偶表里删掉本人
    if (old !== null) {
      old.spouses.forEach((r: SpouseRelation): void => {
        const partnerUid: string = r.uid.trim().toUpperCase();
        if (partnerUid.length === 0 || partnerUid === self) {
          return;
        }
        const partner: Person | null = this.store.getPerson(partnerUid);
        if (partner === null) {
          return;
        }
        if (next.has(partnerUid)) {
          if (prev.length > 0 && prev !== self) {
            partner.spouses.forEach((x: SpouseRelation): void => {
              if (x.uid.trim().toUpperCase() === prev) {
                x.uid = self;
              }
            });
            if (partner.spouseId.trim().toUpperCase() === prev) {
              partner.spouseId = self;
            }
          }
          return;
        }
        const kept: SpouseRelation[] = partner.spouses.filter((x: SpouseRelation): boolean => {
          const id: string = x.uid.trim().toUpperCase();
          return id !== prev && id !== self;
        });
        if (kept.length !== partner.spouses.length) {
          kept.forEach((x: SpouseRelation, i: number): void => {
            x.order = i + 1;
          });
          partner.spouses = kept;
          partner.spouseId = kept.length > 0 ? kept[0].uid : '';
        }
      });
    }
    // 3. 新关系：对方配偶表里没有本人时补一条
    person.spouses.forEach((r: SpouseRelation): void => {
      const partnerUid: string = r.uid.trim().toUpperCase();
      if (partnerUid.length === 0 || partnerUid === self) {
        return;
      }
      const partner: Person | null = this.store.getPerson(partnerUid);
      if (partner === null) {
        return;
      }
      let found: boolean = false;
      for (let i: number = 0; i < partner.spouses.length; i++) {
        if (partner.spouses[i].uid.trim().toUpperCase() === self) {
          found = true;
          break;
        }
      }
      if (found) {
        return;
      }
      const nr: SpouseRelation = new SpouseRelation();
      nr.uid = self;
      nr.relation = partner.gender === '女' ? '夫' : (r.relation === '夫' ? '元配' : r.relation);
      nr.level = spouseRelationLevel(nr.relation);
      nr.order = partner.spouses.length + 1;
      partner.spouses.push(nr);
      if (partner.spouseId.trim().length === 0) {
        partner.spouseId = self;
      }
    });
  }
}
