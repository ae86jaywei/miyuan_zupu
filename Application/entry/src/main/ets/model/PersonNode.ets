import { Person } from './Person';

/**
 * 渲染用的节点（人物 + 派生信息），由 GenealogyService 构建并缓存。
 */
export class PersonNode {
  person: Person = new Person();
  /** 父亲节点 */
  father: PersonNode | null = null;
  /** 母亲节点 */
  mother: PersonNode | null = null;
  /** 配偶节点（第一位，兼容单配偶调用） */
  spouse: PersonNode | null = null;
  /** 全部配偶节点（支持一夫多妻：元配 / 继室 / 妾） */
  spouses: PersonNode[] = [];
  /** 与 spouses 一一对应的名分 */
  spouseRelations: string[] = [];
  /** 子女节点（按出生日期 / 排行排序） */
  children: PersonNode[] = [];
  /** 同辈排行序号（从 0 开始） */
  siblingIndex: number = 0;
  /** 最深后代层级（叶子节点为 0） */
  height: number = 0;
  /** 后代总数（含本人） */
  descendants: number = 1;
  /** 在父节点 children 中的横向占位宽度（用于纯视图计算） */
  slotWidth: number = 1;

  constructor(person: Person) {
    this.person = person;
  }

  get uid(): string {
    return this.person.uid;
  }

  get name(): string {
    return this.person.name;
  }

  get generation(): number {
    return this.person.generation;
  }

  get gender(): string {
    return this.person.gender;
  }

  get hasChildren(): boolean {
    return this.children.length > 0;
  }

  /** 配偶展示文案，如：“配 林氏、继室 陈氏、妾 李氏” */
  spouseText(): string {
    if (this.spouses.length === 0) {
      return this.spouse === null ? '' : '配 ' + this.spouse.person.name;
    }
    const parts: string[] = [];
    this.spouses.forEach((sp: PersonNode, i: number): void => {
      const rel: string = i < this.spouseRelations.length ? this.spouseRelations[i] : '';
      const prefix: string = (rel === '元配' || rel === '未记' || rel === '配偶' || rel.length === 0) ?
        '配' : rel;
      parts.push(prefix + ' ' + sp.person.name);
    });
    return parts.join('、');
  }
}
