import { Person } from '../model/Person';
import { PersonNode } from '../model/PersonNode';
import { parseDate } from '../util/DateUtil';

/**
 * 世系树构建器：把扁平人物列表转换为可渲染的树结构，
 * 并计算分支高度 / 后代数量等排版所需数据。
 */
export class TreeBuilder {
  /**
   * 构建森林：返回所有“根节点”（无父无母，或父母未录入）。
   * @param people 全部人物
   * @param filterFn 可选过滤（不传则包含全部）
   */
  static build(people: Person[], filterFn?: (p: Person) => boolean): PersonNode[] {
    const nodeMap: Map<string, PersonNode> = new Map<string, PersonNode>();
    const ok: Person[] = filterFn === undefined ? people : people.filter(filterFn);
    ok.forEach((p: Person): void => {
      nodeMap.set(p.uid.trim().toUpperCase(), new PersonNode(p));
    });

    // 关联父子、母子、配偶
    ok.forEach((p: Person): void => {
      const node: PersonNode = nodeMap.get(p.uid.trim().toUpperCase()) as PersonNode;
      const f: PersonNode | undefined = nodeMap.get(p.fatherId.trim().toUpperCase());
      const m: PersonNode | undefined = nodeMap.get(p.motherId.trim().toUpperCase());
      if (f !== undefined && f !== node) {
        node.father = f;
        f.children.push(node);
      }
      if (m !== undefined && m !== node && m !== f) {
        node.mother = m;
        // 母亲未作为父亲子节点时，仍挂到母亲下（用于单亲展示）
        if (f === undefined) {
          m.children.push(node);
        }
      }
      const s: PersonNode | undefined = nodeMap.get(p.spouseId.trim().toUpperCase());
      if (s !== undefined && s !== node) {
        node.spouse = s;
      }
    });

    // 夫妻关系双向补全（历史数据常见单向记录）：任一方登记即可互相识别
    nodeMap.forEach((node: PersonNode): void => {
      if (node.spouse !== null && node.spouse.spouse === null) {
        node.spouse.spouse = node;
      }
    });

    // 子女的父母推断夫妻：若两个不同性别的成年人共同拥有子女，则视为配偶
    nodeMap.forEach((node: PersonNode): void => {
      if (node.spouse !== null) {
        return;
      }
      node.children.forEach((child: PersonNode): void => {
        if (node.spouse !== null) {
          return;
        }
        const other: PersonNode | null = node.uid === (child.father === null ? '' : child.father.uid) ?
          child.mother : child.father;
        if (other !== null && other !== node && other.spouse === null &&
          other.person.gender !== node.person.gender) {
          node.spouse = other;
          other.spouse = node;
        }
      });
    });

    // 子女排序：先按出生日期，再按排行，最后按 ID
    nodeMap.forEach((node: PersonNode): void => {
      node.children.sort((a: PersonNode, b: PersonNode): number => {
        const da: number = parseDate(a.person.birthDate);
        const db: number = parseDate(b.person.birthDate);
        if (da !== 0 && db !== 0 && da !== db) {
          return da - db;
        }
        if (a.person.gender !== b.person.gender) {
          return a.person.gender === '男' ? -1 : 1;
        }
        return a.person.uid.localeCompare(b.person.uid);
      });
      node.children.forEach((c: PersonNode, idx: number): void => {
        c.siblingIndex = idx;
      });
    });

    // ---------------------------------------------------------------- 夫妻合并
    // 目标：同一对夫妻只生成一个“宗支根”。
    // 做法：以夫妻为并查集分组，取组内“世代最小、UID 最小”者为代表，
    // 其余配偶成员挂为其 spouse，不再单独成根，也不参与子树计算。
    const parentOf: Map<string, string> = new Map<string, string>();
    const find = (uid: string): string => {
      let cur: string = uid;
      let guard: number = 0;
      while (guard < 1000) {
        const p: string | undefined = parentOf.get(cur);
        if (p === undefined || p === cur) {
          return cur;
        }
        cur = p;
        guard = guard + 1;
      }
      return cur;
    };
    nodeMap.forEach((n: PersonNode): void => {
      if (!parentOf.has(n.uid)) {
        parentOf.set(n.uid, n.uid);
      }
    });
    nodeMap.forEach((n: PersonNode): void => {
      const sp: PersonNode | null = n.spouse;
      if (sp === null || !parentOf.has(sp.uid)) {
        return;
      }
      const a: string = find(n.uid);
      const b: string = find(sp.uid);
      if (a !== b) {
        // 保留“次序更小”的代表，保证结果稳定
        if (a.localeCompare(b) < 0) {
          parentOf.set(b, a);
        } else {
          parentOf.set(a, b);
        }
      }
    });

    // 计算高度与后代数量（自底向上）。先找出根，再后序计算
    const roots: PersonNode[] = [];
    nodeMap.forEach((node: PersonNode): void => {
      if (node.father !== null || node.mother !== null) {
        return;
      }
      // 夫妻分组代表才作为根
      if (find(node.uid) !== node.uid) {
        return;
      }
      // 确保其配偶指向组内其他成员（已是则跳过）
      roots.push(node);
    });
    const visited: Set<string> = new Set<string>();
    // 配偶成员视为“已归入其代表根”，不单独成根
    nodeMap.forEach((node: PersonNode): void => {
      if (find(node.uid) !== node.uid) {
        visited.add(node.uid);
      }
    });
    roots.forEach((r: PersonNode): void => {
      TreeBuilder.computeMetrics(r, visited);
    });
    // 兜底：存在环或孤立节点的场景
    nodeMap.forEach((node: PersonNode): void => {
      if (!visited.has(node.uid)) {
        TreeBuilder.computeMetrics(node, visited);
        roots.push(node);
      }
    });

    // 根节点排序：按世代升序，同年份按 ID
    roots.sort((a: PersonNode, b: PersonNode): number => {
      if (a.person.generation !== b.person.generation) {
        return a.person.generation - b.person.generation;
      }
      return a.person.uid.localeCompare(b.person.uid);
    });
    roots.forEach((r: PersonNode, idx: number): void => {
      r.siblingIndex = idx;
    });
    return roots;
  }

  private static computeMetrics(node: PersonNode, visited: Set<string>): number {
    if (visited.has(node.uid)) {
      return node.height;
    }
    visited.add(node.uid);
    let maxChildHeight: number = -1;
    let totalDesc: number = 1;
    node.children.forEach((c: PersonNode): void => {
      const h: number = TreeBuilder.computeMetrics(c, visited);
      if (h > maxChildHeight) {
        maxChildHeight = h;
      }
      totalDesc = totalDesc + c.descendants;
    });
    node.height = maxChildHeight + 1;
    node.descendants = totalDesc;
    if (node.children.length === 0) {
      node.height = 0;
    } else {
      node.height = maxChildHeight + 1;
    }
    return node.height;
  }

  /** 按 ID 索引整棵树 */
  static index(root: PersonNode): Map<string, PersonNode> {
    const map: Map<string, PersonNode> = new Map<string, PersonNode>();
    const stack: PersonNode[] = [root];
    while (stack.length > 0) {
      const cur: PersonNode = stack.pop() as PersonNode;
      if (map.has(cur.uid)) {
        continue;
      }
      map.set(cur.uid, cur);
      cur.children.forEach((c: PersonNode): void => {
        stack.push(c);
      });
    }
    return map;
  }

  /** 统计树的最大深度（世代跨度） */
  static depthOf(nodes: PersonNode[]): number {
    let d: number = 0;
    nodes.forEach((n: PersonNode): void => {
      if (n.height + 1 > d) {
        d = n.height + 1;
      }
    });
    return d;
  }
}