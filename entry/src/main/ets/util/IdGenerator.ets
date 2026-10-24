import { Person } from '../model/Person';

/**
 * 唯一ID生成器。
 * 规则（可人工修改）：性别前缀 M（女）/ F（男）+ 3 位递增序号，保证族谱内不重复。
 * 示例：F001、M050。
 */
export class IdGenerator {
  /** 根据族谱中现有 ID 生成下一个唯一 ID */
  static next(people: Person[], gender: string): string {
    const used: Set<string> = new Set<string>();
    let maxNum: number = 0;
    people.forEach((p: Person): void => {
      const id: string = p.uid.trim().toUpperCase();
      used.add(id);
      const m: RegExpMatchArray | null = id.match(/^([FM])(\d+)$/);
      if (m !== null) {
        const num: number = parseInt(m[2], 10);
        if (num > maxNum) {
          maxNum = num;
        }
      }
    });
    const prefix: string = gender === '女' ? 'M' : 'F';
    let candidate: string = IdGenerator.format(prefix, maxNum + 1);
    let guard: number = 0;
    while (used.has(candidate) && guard < 10000) {
      maxNum = maxNum + 1;
      candidate = IdGenerator.format(prefix, maxNum + 1);
      guard = guard + 1;
    }
    return candidate;
  }

  static format(prefix: string, num: number): string {
    let s: string = num.toString();
    while (s.length < 3) {
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
      if (p.uid.trim().toUpperCase() === target && p.uid.trim().toUpperCase() !== excludeUid.trim().toUpperCase()) {
        return false;
      }
    }
    return true;
  }
}
