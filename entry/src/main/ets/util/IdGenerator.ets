import { Person } from '../model/Person';

/**
 * 唯一ID生成器。
 *
 * 规则（可人工修改）：
 *  - 性别前缀：**男 F / 女 M**，两类各自独立编号；
 *  - **优先复用最小空号**：删掉 F004 后再新增男丁，会重新拿到 F004；
 *  - 编号默认 3 位（F001）；**只有当编号本身超过 999 时才增位**（F1000）。
 *    注意宽度只看「本次要用的编号」，不看历史最大值——否则删到只剩 F1000 时，
 *    复用空号会生成 F0001，与既有 F001 风格不一致。
 */
export class IdGenerator {
  /** 根据族谱中现有 ID 生成下一个可用 ID */
  static next(people: Person[], gender: string): string {
    const prefix: string = gender === '女' ? 'M' : 'F';
    const used: Set<number> = new Set<number>();
    people.forEach((p: Person): void => {
      const id: string = p.uid.trim().toUpperCase();
      const m: RegExpMatchArray | null = id.match(/^([FM])([0-9]+)$/);
      if (m === null || m[1] !== prefix) {
        return;
      }
      const num: number = parseInt(m[2], 10);
      if (isNaN(num) || num <= 0) {
        return;
      }
      used.add(num);
    });
    let num: number = 1;
    while (used.has(num)) {
      num = num + 1;
    }
    return IdGenerator.format(prefix, num);
  }

  /** 编号位数：最少 3 位，超过 999 时按实际位数 */
  static widthOf(num: number): number {
    const len: number = num.toString().length;
    return len > 3 ? len : 3;
  }

  /** 左补零到指定宽度（宽度不足时不截断） */
  static format(prefix: string, num: number): string {
    const width: number = IdGenerator.widthOf(num);
    let s: string = num.toString();
    while (s.length < width) {
      s = '0' + s;
    }
    return prefix + s;
  }

  /** 校验 ID 唯一性；excludeUid 为编辑时排除自身 */
  static isUnique(people: Person[], uid: string, excludeUid: string): boolean {
    const target: string = uid.trim().toUpperCase();
    if (target.length === 0) {
      return false;
    }
    for (let i: number = 0; i < people.length; i++) {
      const p: Person = people[i];
      const id: string = p.uid.trim().toUpperCase();
      if (id === target && id !== excludeUid.trim().toUpperCase()) {
        return false;
      }
    }
    return true;
  }
}
