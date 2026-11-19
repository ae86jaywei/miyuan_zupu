import { Person, PersonNode, TreeBuilder } from 'common_base';

/**
 * 人员数据存储：统一持有当前族谱的人员列表、uid 映射、宗支根节点与数据版本号。
 *
 * 从 `GenealogyService` 抽出，避免服务内多处直接改写内部字段；
 * 后续按「配偶关系 → 查询 → 编辑事务」拆分子域服务时，可共享同一份数据视图。
 * 只做数据持有与派生重建，不含任何业务规则。
 */
export class PeopleStore {
  private list: Person[] = [];
  private map: Map<string, Person> = new Map<string, Person>();
  private rootNodes: PersonNode[] = [];
  private ver: number = 0;

  /** 当前族谱人员列表（内部数组，调用方只读；写入请用 setAt/push/setList） */
  getAll(): Person[] {
    return this.list;
  }

  /** uid（大写）→ Person 映射 */
  getMap(): Map<string, Person> {
    return this.map;
  }

  /** 宗支根节点 */
  getRoots(): PersonNode[] {
    return this.rootNodes;
  }

  /** 数据版本号：任何影响内存数据的变更都要递增 */
  getVersion(): number {
    return this.ver;
  }

  setList(list: Person[]): void {
    this.list = list;
  }

  setMap(map: Map<string, Person>): void {
    this.map = map;
  }

  setAt(index: number, person: Person): void {
    this.list[index] = person;
  }

  push(person: Person): void {
    this.list.push(person);
  }

  /** 按当前列表重建 uid 映射（编辑/编号变更后调用） */
  rebuildMap(): void {
    const map: Map<string, Person> = new Map<string, Person>();
    for (let i: number = 0; i < this.list.length; i = i + 1) {
      const p: Person = this.list[i];
      map.set(p.uid.trim().toUpperCase(), p);
    }
    this.map = map;
  }

  /** 按当前列表重建宗支根节点 */
  rebuildRoots(): void {
    this.rootNodes = TreeBuilder.build(this.list);
  }

  /** 清空全部数据（重新导入前重置） */
  reset(): void {
    this.list = [];
    this.map = new Map<string, Person>();
    this.rootNodes = [];
  }

  bump(): void {
    this.ver = this.ver + 1;
  }
}
