import { Person, SpouseRelation } from '../model/Person';
import { PersonNode } from '../model/PersonNode';
import { parseDate } from '../util/DateUtil';
import { toChineseNumber } from '../util/StringUtil';

/**
 * 世系树构建器：把扁平人物列表转换为可渲染的树结构，
 * 并计算分支高度 / 后代数量等排版所需数据。
 */
export class TreeBuilder {
  /** 计算树指标时的递归深度上限：脏数据长链不应让整页栈溢出 */
  private static readonly MAX_METRICS_DEPTH: number = 256;
  /** 后代超过该规模即视为分支点：分页优先在房支起点换页 */
  private static readonly BRANCH_POINT_DESCENDANTS: number = 45;

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
      // 关联全部配偶（支持一夫多妻：元配 / 继室 / 妾）
      if (p.spouses.length > 0) {
        p.spouses.forEach((r: SpouseRelation): void => {
          const s: PersonNode | undefined = nodeMap.get(r.uid.trim().toUpperCase());
          if (s !== undefined) {
            TreeBuilder.linkSpouse(node, s, r.relation);
          }
        });
      } else {
        // 兼容旧数据：只有 spouseId 单值时也能识别
        const s: PersonNode | undefined = nodeMap.get(p.spouseId.trim().toUpperCase());
        if (s !== undefined) {
          TreeBuilder.linkSpouse(node, s, '元配');
        }
      }
    });

    // 夫妻关系双向补全（任一方登记即可互相识别）
    nodeMap.forEach((node: PersonNode): void => {
      node.spouses.forEach((sp: PersonNode): void => {
        if (sp.spouses.indexOf(node) < 0) {
          const rel: string = sp.person.gender === '女' ? '夫' : '配偶';
          TreeBuilder.linkSpouse(sp, node, rel);
        }
      });
    });

    // 随母子女挂靠：继室/妾室与前夫所生、随母改嫁而来的子女，
    // 生父不在本谱、生母已是本谱某男子的配偶时，归入该男子名下。
    // 这样他们既能随本户子女一并排行（siblingIndex），也能在谱图中随生母展示；
    // 生父信息不被篡改（Person.fatherId 仍为空），仅树结构上寄挂于继父。
    nodeMap.forEach((node: PersonNode): void => {
      if (node.father !== null || node.mother === null) {
        return;
      }
      const mother: PersonNode = node.mother;
      if (mother.children.indexOf(node) < 0 || mother.spouses.length === 0) {
        return;
      }
      let hostIdx: number = -1;
      for (let i: number = 0; i < mother.spouses.length; i = i + 1) {
        if (mother.spouses[i].person.gender === '男') {
          hostIdx = i;
          break;
        }
      }
      if (hostIdx < 0) {
        return;
      }
      const host: PersonNode = mother.spouses[hostIdx];
      if (host === node || host.children.indexOf(node) >= 0) {
        return;
      }
      node.father = host;
      host.children.push(node);
    });

    // 子女的父母推断夫妻：共同拥有子女的不同性别成年人视为配偶（妾室亦按此关联）
    nodeMap.forEach((node: PersonNode): void => {
      node.children.forEach((child: PersonNode): void => {
        const other: PersonNode | null = node.uid === (child.father === null ? '' : child.father.uid) ?
          child.mother : child.father;
        if (other !== null && other !== node && other.person.gender !== node.person.gender &&
          node.spouses.indexOf(other) < 0 && other.spouses.indexOf(node) < 0) {
          TreeBuilder.linkSpouse(node, other, '配偶');
          TreeBuilder.linkSpouse(other, node, '配偶');
        }
      });
    });

    // 统一以第一位配偶作为快捷引用 spouse
    nodeMap.forEach((node: PersonNode): void => {
      node.spouse = node.spouses.length > 0 ? node.spouses[0] : null;
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
      n.spouses.forEach((sp: PersonNode): void => {
        if (!parentOf.has(sp.uid)) {
          return;
        }
        const a: string = find(n.uid);
        const b: string = find(sp.uid);
        if (a !== b) {
          if (a.localeCompare(b) < 0) {
            parentOf.set(b, a);
          } else {
            parentOf.set(a, b);
          }
        }
      });
    });

    // 同一夫妻（含多位妻妾）分组内选代表：有子女者优先，其次男性，再按 UID
    const groups: Map<string, PersonNode[]> = new Map<string, PersonNode[]>();
    nodeMap.forEach((n: PersonNode): void => {
      const root: string = find(n.uid);
      let arr: PersonNode[] | undefined = groups.get(root);
      if (arr === undefined) {
        arr = [];
        groups.set(root, arr);
      }
      arr.push(n);
    });
    const hasParent: (n: PersonNode) => boolean =
      (n: PersonNode): boolean => n.father !== null || n.mother !== null;
    groups.forEach((members: PersonNode[]): void => {
      let rep: PersonNode = members[0];
      members.forEach((m: PersonNode): void => {
        // 「上挂父母」优先于「有子女」：本谱外来配偶往往无父母但子女多，
        // 若按子女数选它当代表，就会带着孩子单独成根，和配偶所在的家族树断开。
        // 选有父母的一方当代表，它挂在原家族树上，无父母的一方自然作为配偶卡跟随。
        const mParent: boolean = hasParent(m);
        const rParent: boolean = hasParent(rep);
        if (mParent !== rParent) {
          if (mParent) {
            rep = m;
          }
          return;
        }
        if (m.children.length > rep.children.length) {
          rep = m;
        } else if (m.children.length === rep.children.length) {
          if (m.person.gender === '男' && rep.person.gender !== '男') {
            rep = m;
          } else if (m.person.gender === rep.person.gender && m.uid.localeCompare(rep.uid) < 0) {
            rep = m;
          }
        }
      });
      // 非代表成员的子女并入代表：这些子女原本挂在配偶名下，
      // 而配偶只是代表旁边的一张卡，不会被递归遍历，子女会整条支线消失。
      members.forEach((m: PersonNode): void => {
        if (m === rep) {
          return;
        }
        for (let i: number = 0; i < m.children.length; i++) {
          const c: PersonNode = m.children[i];
          if (rep.children.indexOf(c) < 0) {
            rep.children.push(c);
          }
        }
        m.children = [];
      });
      members.forEach((m: PersonNode): void => {
        parentOf.set(m.uid, rep.uid);
      });
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
    roots.forEach((r: PersonNode): void => {
      TreeBuilder.computeMetrics(r, visited);
    });
    // 兜底：环、孤立节点，以及「非代表配偶」名下的子女。
    // 之前把所有非代表配偶预先标记为已访问，它们名下的子女就不会进任何根的子树，
    // 谱系图上整条支线会凭空消失（名录里却有人）。无子女的配偶仍随代表显示，不单独成根。
    nodeMap.forEach((node: PersonNode): void => {
      if (visited.has(node.uid)) {
        return;
      }
      if (find(node.uid) !== node.uid && node.children.length === 0) {
        return;
      }
      TreeBuilder.computeMetrics(node, visited);
      roots.push(node);
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
    // 房支标记：全览气泡聚簇、分页切页、面包屑都依赖这组派生字段
    roots.forEach((r: PersonNode): void => {
      TreeBuilder.assignBranches(r);
    });
    return roots;
  }

  /** 顶级房支名称：长房、二房、三房… */
  private static houseName(index: number): string {
    if (index <= 0) {
      return '长房';
    }
    return toChineseNumber(index + 1) + '房';
  }

  /**
   * 给一棵宗支树打房支标记。
   *
   * 规则：
   *  - 宗支根为「本支」，其后代继承本支；
   *  - 根的直接子女各自成为一个「房」，按长幼命名（长房/二房/…）；
   *  - 更深层节点继承所属房，仅记录自身是否为分支点（用于分页切页）。
   *
   * 用显式栈而不是递归：五万人谱的深链可能逼近调用栈上限。
   */
  private static assignBranches(root: PersonNode): void {
    root.branchId = root.uid;
    root.branchName = '本支';
    root.branchRootUid = root.uid;
    root.branchParentUid = '';
    root.branchLevel = 0;
    root.isBranchPoint = root.children.length >= 2 ||
      root.descendants > TreeBuilder.BRANCH_POINT_DESCENDANTS;
    TreeBuilder.inheritBranchToSpouses(root);

    const seen: Set<string> = new Set<string>();
    seen.add(root.uid);
    const stack: PersonNode[] = [];
    for (let i: number = 0; i < root.children.length; i = i + 1) {
      const child: PersonNode = root.children[i];
      child.branchId = child.uid;
      child.branchName = TreeBuilder.houseName(i);
      child.branchRootUid = child.uid;
      child.branchParentUid = root.uid;
      child.branchLevel = 1;
      child.isBranchPoint = child.children.length >= 2 ||
        child.descendants > TreeBuilder.BRANCH_POINT_DESCENDANTS;
      TreeBuilder.inheritBranchToSpouses(child);
      seen.add(child.uid);
      stack.push(child);
    }
    while (stack.length > 0) {
      const node: PersonNode = stack.pop() as PersonNode;
      for (let i: number = 0; i < node.children.length; i = i + 1) {
        const child: PersonNode = node.children[i];
        if (seen.has(child.uid)) {
          continue;
        }
        seen.add(child.uid);
        child.branchId = node.branchId;
        child.branchName = node.branchName;
        child.branchRootUid = node.branchRootUid;
        child.branchParentUid = node.branchParentUid;
        child.branchLevel = node.branchLevel;
        child.isBranchPoint = child.children.length >= 2 ||
          child.descendants > TreeBuilder.BRANCH_POINT_DESCENDANTS;
        TreeBuilder.inheritBranchToSpouses(child);
        stack.push(child);
      }
    }
  }

  /** 配偶卡跟随主卡房支：配偶若本身已有独立房支（娘家在本谱）则保持原标记 */
  private static inheritBranchToSpouses(node: PersonNode): void {
    for (let i: number = 0; i < node.spouses.length; i = i + 1) {
      const sp: PersonNode = node.spouses[i];
      if (sp.branchLevel > 0 || sp.branchId.length > 0) {
        continue;
      }
      sp.branchId = node.branchId;
      sp.branchName = node.branchName;
      sp.branchRootUid = node.branchRootUid;
      sp.branchParentUid = node.branchParentUid;
      sp.branchLevel = node.branchLevel;
      sp.isBranchPoint = false;
    }
  }

  /** 挂接配偶节点及其名分（去重，第一位即主配偶） */
  private static linkSpouse(node: PersonNode, partner: PersonNode, relation: string): void {
    if (partner === node || node.spouses.indexOf(partner) >= 0) {
      return;
    }
    node.spouses.push(partner);
    node.spouseRelations.push(relation.trim().length > 0 ? relation.trim() : '未记');
    if (node.spouse === null) {
      node.spouse = partner;
    }
  }

  private static computeMetrics(node: PersonNode, visited: Set<string>, depth: number = 0): number {
    if (visited.has(node.uid)) {
      return node.height;
    }
    // 超长父子链保护：递归超过上限就按叶子处理，避免导入脏数据时栈溢出崩溃
    if (depth > TreeBuilder.MAX_METRICS_DEPTH) {
      visited.add(node.uid);
      node.height = 0;
      node.descendants = 1;
      return 0;
    }
    visited.add(node.uid);
    let maxChildHeight: number = -1;
    let totalDesc: number = 1;
    node.children.forEach((c: PersonNode): void => {
      const h: number = TreeBuilder.computeMetrics(c, visited, depth + 1);
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
