import { Person, SpouseRelation } from '../model/Person';
import { PersonNode } from '../model/PersonNode';
import { TreeBuilder } from './TreeBuilder';

/**
 * 关系图修复。
 *
 * 导入 / 合并落库后统一跑一次，保证「关系图闭环」，这是防
 * 「多出宗支」「关系错挂」「世代重叠」的最后一道闸：
 *   1) 悬空引用清理：父/母/配偶指向谱内不存在的人 → 置空，避免断链成根；
 *   2) 配偶双向补齐：任一方登记即可互相识别，避免夫妻线只剩单边；
 *   3) 世代校正（可选）：按「根节点世代 + 树深度」回填，保证卡片世代与层级一致。
 *
 * 修复是就地修改 Person 内存对象，返回被改动的人员 uid，由调用方落库。
 */
export class RepairReport {
  danglingCount: number = 0;
  oneWaySpouseCount: number = 0;
  generationMismatchCount: number = 0;
  touched: string[] = [];
  details: string[] = [];

  summary(): string {
    let text: string = '';
    if (this.danglingCount > 0) {
      text = text + '清理悬空关系 ' + this.danglingCount.toString() + ' 处；';
    }
    if (this.oneWaySpouseCount > 0) {
      text = text + '补齐配偶 ' + this.oneWaySpouseCount.toString() + ' 对；';
    }
    if (this.generationMismatchCount > 0) {
      text = text + '校正世代 ' + this.generationMismatchCount.toString() + ' 人；';
    }
    if (text.length === 0) {
      text = '关系图完整，无需修复';
    }
    return text;
  }
}

export class RelationGraph {
  /**
   * 就地修复关系图。
   * @param people 全谱人物（会被直接修改）
   * @param fixGeneration 是否按树深度回填世代
   */
  static repair(people: Person[], fixGeneration: boolean): RepairReport {
    const report: RepairReport = new RepairReport();
    const map: Map<string, Person> = new Map<string, Person>();
    people.forEach((p: Person): void => {
      const u: string = RelationGraph.up(p.uid);
      if (u.length > 0 && map.get(u) === undefined) {
        map.set(u, p);
      }
    });
    const touchedSet: Set<string> = new Set<string>();

    // 1) 悬空父/母/主配偶 + 配偶数组中的悬空项
    people.forEach((p: Person): void => {
      const u: string = RelationGraph.up(p.uid);
      if (p.fatherId.trim().length > 0 && map.get(RelationGraph.up(p.fatherId)) === undefined) {
        report.details.push(p.name + '：父亲 ' + p.fatherId + ' 不在谱内，已清空');
        p.fatherId = '';
        report.danglingCount = report.danglingCount + 1;
        touchedSet.add(u);
      }
      if (p.motherId.trim().length > 0 && map.get(RelationGraph.up(p.motherId)) === undefined) {
        report.details.push(p.name + '：母亲 ' + p.motherId + ' 不在谱内，已清空');
        p.motherId = '';
        report.danglingCount = report.danglingCount + 1;
        touchedSet.add(u);
      }
      const kept: SpouseRelation[] = [];
      let spouseChanged: boolean = false;
      p.spouses.forEach((r: SpouseRelation): void => {
        const id: string = RelationGraph.up(r.uid);
        if (id.length === 0 || id === u) {
          spouseChanged = true;
          return;
        }
        if (map.get(id) === undefined) {
          report.details.push(p.name + '：配偶 ' + r.uid + ' 不在谱内，已清空');
          report.danglingCount = report.danglingCount + 1;
          spouseChanged = true;
          return;
        }
        kept.push(r);
      });
      if (spouseChanged) {
        p.spouses = kept;
        touchedSet.add(u);
      }
      const expectId: string = p.spouses.length > 0 ? p.spouses[0].uid : '';
      if (RelationGraph.up(p.spouseId) !== RelationGraph.up(expectId)) {
        p.spouseId = expectId;
        touchedSet.add(u);
      }
    });

    // 1.5) 父/母链成环清理：环会让树渲染无限递归（RangeError: Stack overflow）
    RelationGraph.breakChains(people, map, true, report, touchedSet);
    RelationGraph.breakChains(people, map, false, report, touchedSet);

    // 2) 配偶双向补齐（任一方登记即互为配偶）
    people.forEach((p: Person): void => {
      const u: string = RelationGraph.up(p.uid);
      p.spouses.forEach((r: SpouseRelation): void => {
        const partner: Person | undefined = map.get(RelationGraph.up(r.uid));
        if (partner === undefined || partner === p) {
          return;
        }
        const pu: string = RelationGraph.up(partner.uid);
        let mutual: boolean = false;
        partner.spouses.forEach((pr: SpouseRelation): void => {
          if (RelationGraph.up(pr.uid) === u) {
            mutual = true;
          }
        });
        if (mutual) {
          return;
        }
        const nr: SpouseRelation = new SpouseRelation();
        nr.uid = u;
        nr.relation = partner.gender === '女' ? '夫' : '配偶';
        nr.level = partner.gender === '女' ? '夫' : '未记';
        nr.order = partner.spouses.length + 1;
        partner.spouses.push(nr);
        partner.spouseId = partner.spouses[0].uid;
        report.oneWaySpouseCount = report.oneWaySpouseCount + 1;
        touchedSet.add(pu);
      });
    });

    // 3) 世代校正：期望世代 = 根世代 + 树深度
    if (fixGeneration) {
      const roots: PersonNode[] = TreeBuilder.build(people);
      roots.forEach((root: PersonNode): void => {
        const base: number = root.person.generation > 0 ? root.person.generation : 1;
        RelationGraph.walkGeneration(root, 0, base, report, touchedSet);
      });
    }

    touchedSet.forEach((u: string): void => {
      report.touched.push(u);
    });
    return report;
  }

  /**
   * 断环：沿父链（useFather=true）或母链向上走，
   * 若回到链上已出现过的节点，说明关系图成环，断开该处引用。
   */
  private static breakChains(people: Person[], map: Map<string, Person>, useFather: boolean,
    report: RepairReport, touchedSet: Set<string>): void {
    for (let i: number = 0; i < people.length; i++) {
      let cur: Person = people[i];
      const seen: Set<string> = new Set<string>();
      let steps: number = 0;
      while (steps < 200) {
        const cid: string = RelationGraph.up(cur.uid);
        if (cid.length > 0 && seen.has(cid)) {
          const ref: string = useFather ? cur.fatherId.trim() : cur.motherId.trim();
          if (ref.length > 0) {
            if (useFather) {
              cur.fatherId = '';
            } else {
              cur.motherId = '';
            }
            report.details.push(cur.name + '：' + (useFather ? '父系' : '母系') +
              '关系成环（' + ref + '），已断开');
            report.danglingCount = report.danglingCount + 1;
            touchedSet.add(cid);
          }
          break;
        }
        if (cid.length > 0) {
          seen.add(cid);
        }
        const nextRef: string = useFather ? cur.fatherId.trim() : cur.motherId.trim();
        const next: Person | undefined = map.get(RelationGraph.up(nextRef));
        if (next === undefined || next === cur) {
          break;
        }
        cur = next;
        steps = steps + 1;
      }
    }
  }

  /** 深度优先：校验并按需回填世代 */
  private static walkGeneration(node: PersonNode, depth: number, base: number, report: RepairReport,
    touchedSet: Set<string>): void {
    const expect: number = base + depth;
    if (node.person.generation !== expect) {
      const before: number = node.person.generation;
      node.person.generation = expect;
      report.generationMismatchCount = report.generationMismatchCount + 1;
      touchedSet.add(RelationGraph.up(node.uid));
      if (report.details.length < 200) {
        report.details.push(node.person.name + '：世代由 ' + before.toString() +
          ' 校正为 ' + expect.toString());
      }
    }
    node.children.forEach((c: PersonNode): void => {
      RelationGraph.walkGeneration(c, depth + 1, base, report, touchedSet);
    });
  }

  private static up(uid: string): string {
    return uid.trim().toUpperCase();
  }
}
